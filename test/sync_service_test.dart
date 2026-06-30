// Tests the hardened sync logic with a fake gateway (no network) against an
// in-memory DB: consent gate, push + idempotency, per-row resilience, and the
// concurrency guard.

import 'package:flutter_test/flutter_test.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

import 'package:rhythmic_practice/data/app_database.dart';
import 'package:rhythmic_practice/data/practice_repository.dart';
import 'package:rhythmic_practice/services/sync_service.dart';

class FakeSyncGateway implements SyncGateway {
  FakeSyncGateway({this.ready = true});
  bool ready;
  String? profileId; // null until createProfile is called
  final List<Map<String, Object?>> sessions = [];
  final List<Map<String, Object?>> attempts = [];
  final List<Map<String, Object?>> dailySummaries = [];
  final Set<Object?> failAttemptIds = {};

  @override
  bool get isReady => ready;

  @override
  Future<String?> findOwnedProfileId() async => profileId;

  @override
  Future<void> createProfile() async => profileId = 'cloud-profile-1';

  @override
  Future<void> upsertSession(Map<String, Object?> row) async => sessions.add(row);

  @override
  Future<void> upsertAttempt(Map<String, Object?> row) async {
    if (failAttemptIds.contains(row['id'])) throw Exception('simulated failure');
    attempts.add(row);
  }

  @override
  Future<void> upsertDailySummary(Map<String, Object?> row) async =>
      dailySummaries.add(row);
}

void main() {
  setUpAll(sqfliteFfiInit);

  late Database db;
  late PracticeRepository repo;

  setUp(() async {
    db = await databaseFactoryFfi.openDatabase(
      inMemoryDatabasePath,
      options: OpenDatabaseOptions(
        version: 2,
        onConfigure: (db) => db.execute('PRAGMA foreign_keys = ON'),
        onCreate: (db, v) => AppDatabase.applyInitialSchema(db),
      ),
    );
    repo = PracticeRepository.withDatabase(db);
  });

  tearDown(() => db.close());

  Future<(String session, List<String> attempts)> seedTwoAttempts() async {
    final phraseId = (await repo.getActivePhrases()).first.phraseId;
    final session = await repo.createSession(AppDatabase.defaultProfileId);
    final a1 = await repo.insertAttempt(
        sessionId: session, phraseId: phraseId, evaluationLabel: 1);
    final a2 = await repo.insertAttempt(
        sessionId: session, phraseId: phraseId, evaluationLabel: 0);
    return (session, [a1, a2]);
  }

  test('does nothing without consent', () async {
    await seedTwoAttempts();
    final gw = FakeSyncGateway();
    final pushed = await SyncService(repo, gw).pushPending();
    expect(pushed, 0);
    expect(gw.sessions, isEmpty);
    expect(gw.attempts, isEmpty);
  });

  test('pushes pending rows once consent is granted; idempotent on re-run',
      () async {
    await seedTwoAttempts();
    await repo.updateProfile(guardianConsentGranted: true);
    final gw = FakeSyncGateway();

    final pushed = await SyncService(repo, gw).pushPending();
    expect(pushed, 3); // 1 session + 2 attempts
    expect(gw.sessions.length, 1);
    expect(gw.attempts.length, 2);
    // Profile was created and cached.
    expect(await repo.getCloudProfileId(), 'cloud-profile-1');
    // Everything is now marked synced.
    expect(await repo.getUnsyncedSessions(), isEmpty);
    expect(await repo.getUnsyncedAttempts(), isEmpty);

    // Re-running pushes nothing new.
    final again = await SyncService(repo, gw).pushPending();
    expect(again, 0);
  });

  test('pushes the daily summary rollup once consent is granted', () async {
    await seedTwoAttempts(); // 1 Pass + 1 Fail today
    await repo.touchDailySummaryForToday(AppDatabase.defaultProfileId);
    await repo.updateProfile(guardianConsentGranted: true);
    final gw = FakeSyncGateway();

    final pushed = await SyncService(repo, gw).pushPending();
    expect(pushed, 4); // 1 session + 2 attempts + 1 daily summary
    expect(gw.dailySummaries.length, 1);
    expect(gw.dailySummaries.single['profile_id'], 'cloud-profile-1');
    expect(gw.dailySummaries.single['attempts'], 2);
    expect(gw.dailySummaries.single['passes'], 1);
    expect(await repo.getUnsyncedDailySummaries(), isEmpty);
  });

  test('one failing attempt does not block the others', () async {
    final (_, attemptIds) = await seedTwoAttempts();
    await repo.updateProfile(guardianConsentGranted: true);
    final gw = FakeSyncGateway()..failAttemptIds.add(attemptIds[1]);

    final pushed = await SyncService(repo, gw).pushPending();
    expect(pushed, 2); // session + the one good attempt
    expect(gw.attempts.length, 1);
    // The failed attempt stays pending for next time.
    final pending = await repo.getUnsyncedAttempts();
    expect(pending.length, 1);
    expect(pending.single['attempt_id'], attemptIds[1]);
  });

  test('concurrency guard: a second concurrent push is skipped', () async {
    await seedTwoAttempts();
    await repo.updateProfile(guardianConsentGranted: true);
    final gw = FakeSyncGateway();
    final service = SyncService(repo, gw);

    // Start one push (it suspends at the first await with _running already set),
    // then immediately start another — the second must short-circuit to 0.
    final first = service.pushPending();
    final second = service.pushPending();
    expect(await second, 0);
    expect(await first, 3);
  });
}
