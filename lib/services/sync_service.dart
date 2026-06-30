import 'package:flutter/foundation.dart';

import '../data/practice_repository.dart';
import 'cloud.dart';

/// The minimal set of cloud operations [SyncService] needs. Abstracting them
/// lets us unit-test the sync logic with a fake, while the real implementation
/// ([SupabaseSyncGateway]) was verified end-to-end against the live project.
abstract class SyncGateway {
  /// True when the cloud is reachable AND a caregiver is signed in.
  bool get isReady;

  /// The id of a profile the CURRENT user owns, or null if they have none.
  /// (Filtered to owned — never a profile merely shared with them.)
  Future<String?> findOwnedProfileId();

  /// Creates a profile owned by the current user (minimal insert).
  Future<void> createProfile();

  Future<void> upsertSession(Map<String, Object?> row);
  Future<void> upsertAttempt(Map<String, Object?> row);
  Future<void> upsertDailySummary(Map<String, Object?> row);
}

/// Real gateway backed by the Supabase client.
class SupabaseSyncGateway implements SyncGateway {
  @override
  bool get isReady =>
      Cloud.status == CloudStatus.ready &&
      Cloud.client.auth.currentUser != null;

  @override
  Future<String?> findOwnedProfileId() async {
    final uid = Cloud.client.auth.currentUser?.id;
    if (uid == null) return null;
    final rows = await Cloud.client
        .from('practice_profiles')
        .select('id')
        .eq('owner_id', uid) // only profiles WE own
        .limit(1);
    return rows.isEmpty ? null : rows.first['id'] as String;
  }

  @override
  Future<void> createProfile() async {
    await Cloud.client.from('practice_profiles').insert({'display_name': 'Practice'});
  }

  @override
  Future<void> upsertSession(Map<String, Object?> row) async {
    await Cloud.client.from('practice_sessions').upsert(row);
  }

  @override
  Future<void> upsertAttempt(Map<String, Object?> row) async {
    await Cloud.client.from('exercise_attempts').upsert(row);
  }

  @override
  Future<void> upsertDailySummary(Map<String, Object?> row) async {
    // Upsert on (profile_id, day) so re-pushing a day (e.g. today as it grows)
    // overwrites rather than duplicating.
    await Cloud.client
        .from('daily_summaries')
        .upsert(row, onConflict: 'profile_id,day');
  }
}

/// Pushes local practice data up to Supabase so invited family can view it.
///
/// Local-first, one-way, metrics-only (NEVER audio). Gated on cloud-ready +
/// signed-in + local consent. Hardened so it's safe to call from several places
/// at once and resilient to a single row failing.
class SyncService {
  SyncService([PracticeRepository? repo, SyncGateway? gateway])
      : _repo = repo ?? PracticeRepository(),
        _gateway = gateway ?? SupabaseSyncGateway();

  final PracticeRepository _repo;
  final SyncGateway _gateway;

  // Shared across all instances: sync targets one place, so we never want two
  // pushes interleaving and racing on the "mark synced" step.
  static bool _running = false;

  /// Pushes pending sessions + attempts. Returns how many rows were pushed
  /// (0 if skipped for any gating reason, or if a sync is already running).
  /// Never throws — a failing row is left pending for next time.
  Future<int> pushPending() async {
    if (!_gateway.isReady) return 0;
    if (_running) return 0; // concurrency guard
    _running = true;
    try {
      final profile = await _repo.getProfile();
      if (!profile.guardianConsentGranted) return 0; // consent gate

      final cloudProfileId = await _ensureCloudProfile();
      final stamp = DateTime.now().toUtc().toIso8601String();
      var pushed = 0;

      // Sessions first — attempts reference them by foreign key in the cloud.
      for (final s in await _repo.getUnsyncedSessions()) {
        try {
          await _gateway.upsertSession({
            'id': s.sessionId,
            'profile_id': cloudProfileId,
            'started_at': s.startedAt,
          });
          await _repo.markSessionSynced(s.sessionId, stamp);
          pushed++;
        } catch (e) {
          // Leave this session (and its attempts) pending; keep going.
          debugPrint('Sync: session ${s.sessionId} failed: $e');
        }
      }

      for (final a in await _repo.getUnsyncedAttempts()) {
        try {
          await _gateway.upsertAttempt({
            'id': a['attempt_id'],
            'session_id': a['session_id'],
            'phrase_id': a['phrase_id'],
            'phrase_text': a['phrase_text'],
            'complexity_level': a['complexity_level'],
            'latency_ms': a['latency_ms'],
            'duration_ms': a['duration_ms'],
            'tapping_synchronization_score': a['tapping_synchronization_score'],
            'evaluation_label': a['evaluation_label'],
            'attempted_at': a['timestamp'],
          });
          await _repo.markAttemptSynced(a['attempt_id'] as String, stamp);
          pushed++;
        } catch (e) {
          debugPrint('Sync: attempt ${a['attempt_id']} failed: $e');
        }
      }

      // Per-day metrics rollups for the family dashboard (display-only, no audio).
      for (final d in await _repo.getUnsyncedDailySummaries()) {
        try {
          await _gateway.upsertDailySummary({
            'profile_id': cloudProfileId,
            'day': d.day,
            'attempts': d.attempts,
            'passes': d.passes,
            'fails': d.fails,
            'unsure': d.unsure,
            'avg_similarity': d.avgSimilarity,
          });
          await _repo.markDailySummarySynced(d.profileId, d.day, stamp);
          pushed++;
        } catch (e) {
          debugPrint('Sync: daily summary ${d.day} failed: $e');
        }
      }
      return pushed;
    } catch (e) {
      debugPrint('Sync failed: $e');
      return 0;
    } finally {
      _running = false;
    }
  }

  /// Finds (or creates) this user's cloud profile and remembers its id locally.
  /// We insert minimally (no RETURNING) because the owner's membership — which
  /// the read policy needs — is added by an AFTER-INSERT trigger not visible
  /// during the same statement; so we create, then read the id back.
  Future<String> _ensureCloudProfile() async {
    final cached = await _repo.getCloudProfileId();
    if (cached != null) return cached;

    var id = await _gateway.findOwnedProfileId();
    if (id == null) {
      await _gateway.createProfile();
      id = await _gateway.findOwnedProfileId();
      if (id == null) {
        throw StateError('Cloud profile not found after creation');
      }
    }
    await _repo.setCloudProfileId(id);
    return id;
  }
}
