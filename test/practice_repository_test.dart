// Persistence tests for sessions/attempts, run against an in-memory database
// (the real schema + seed, no files, no device).

import 'package:flutter_test/flutter_test.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

import 'package:rhythmic_practice/data/app_database.dart';
import 'package:rhythmic_practice/data/models.dart';
import 'package:rhythmic_practice/data/practice_repository.dart';
import 'package:rhythmic_practice/practice/mit_progression.dart';
import 'package:rhythmic_practice/practice/progression.dart';

void main() {
  setUpAll(sqfliteFfiInit);

  late Database db;
  late PracticeRepository repo;

  setUp(() async {
    db = await databaseFactoryFfi.openDatabase(
      inMemoryDatabasePath,
      options: OpenDatabaseOptions(
        version: 1,
        onConfigure: (db) => db.execute('PRAGMA foreign_keys = ON'),
        onCreate: (db, v) => AppDatabase.applyInitialSchema(db),
      ),
    );
    repo = PracticeRepository.withDatabase(db);
  });

  tearDown(() => db.close());

  test('saves a session and its attempt, and reads it back', () async {
    final phraseId = (await repo.getActivePhrases()).first.phraseId;

    final sessionId = await repo.createSession(AppDatabase.defaultProfileId);
    expect(sessionId, isNotEmpty);

    await repo.insertAttempt(
      sessionId: sessionId,
      phraseId: phraseId,
      evaluationLabel: 1, // Pass
      tappingSynchronizationScore: 0.8,
    );

    final attempts = await repo.getAttemptsForSession(sessionId);
    expect(attempts.length, 1);
    final a = attempts.single;
    expect(a.phraseId, phraseId);
    expect(a.evaluationLabel, 1);
    expect(a.tappingSynchronizationScore, closeTo(0.8, 1e-9));
    // Mic-derived fields and audio path are null until Step 5 / unless recorded.
    expect(a.latencyMs, isNull);
    expect(a.durationMs, isNull);
    expect(a.localEncryptedAudioPath, isNull);
  });

  test('setRung persists the progression rung; phrases default to unison', () async {
    final phrase = (await repo.getActivePhrases()).first;
    expect(phrase.rung, Rung.r2); // default unison
    await repo.setRung(phrase.phraseId, Rung.r4);
    final updated =
        (await repo.getAllPhrases()).firstWhere((p) => p.phraseId == phrase.phraseId);
    expect(updated.rung, Rung.r4);
  });

  test('daily summary rolls up today\'s attempts and tracks sync', () async {
    const profileId = AppDatabase.defaultProfileId;
    final phraseId = (await repo.getActivePhrases()).first.phraseId;
    final sid = await repo.createSession(profileId);
    await repo.insertAttempt(
        sessionId: sid, phraseId: phraseId, evaluationLabel: 1);
    await repo.insertAttempt(
        sessionId: sid, phraseId: phraseId, evaluationLabel: 0);
    await repo.insertAttempt(
        sessionId: sid, phraseId: phraseId, evaluationLabel: 2);

    await repo.touchDailySummaryForToday(profileId);
    final d = (await repo.getDailySummaries(profileId)).single;
    expect(d.attempts, 3);
    expect(d.passes, 1);
    expect(d.fails, 1);
    expect(d.unsure, 1);

    // Pending until synced, then clears.
    expect((await repo.getUnsyncedDailySummaries()).length, 1);
    await repo.markDailySummarySynced(profileId, d.day, 'now');
    expect(await repo.getUnsyncedDailySummaries(), isEmpty);

    // A new attempt + re-touch makes the day pending again (today keeps growing).
    await repo.insertAttempt(
        sessionId: sid, phraseId: phraseId, evaluationLabel: 1);
    await repo.touchDailySummaryForToday(profileId);
    expect((await repo.getDailySummaries(profileId)).single.attempts, 4);
    expect((await repo.getUnsyncedDailySummaries()).length, 1);
  });

  test('target display preference defaults to picture and round-trips', () async {
    expect((await repo.getProfile()).targetDisplay, TargetDisplay.picture);
    await repo.updateProfile(targetDisplay: TargetDisplay.both);
    expect((await repo.getProfile()).targetDisplay, TargetDisplay.both);
  });

  test('playback speed defaults to 1.0 and round-trips', () async {
    expect((await repo.getProfile()).playbackSpeed, 1.0);
    await repo.updateProfile(playbackSpeed: 0.5);
    expect((await repo.getProfile()).playbackSpeed, 0.5);
  });

  test('comfort cap (session rung cap) defaults off, sets, and clears', () async {
    // Off by default.
    expect((await repo.getProfile()).sessionRungCap, isNull);

    // Setting a cap round-trips.
    await repo.updateProfile(sessionRungCap: Rung.r3.level);
    expect((await repo.getProfile()).sessionRungCap, Rung.r3.level);

    // The _unset default leaves it unchanged when other fields update.
    await repo.updateProfile(metronomeBpm: 55);
    expect((await repo.getProfile()).sessionRungCap, Rung.r3.level);

    // Passing null explicitly clears the cap.
    await repo.updateProfile(sessionRungCap: null);
    expect((await repo.getProfile()).sessionRungCap, isNull);
  });

  test('progression state round-trips (default → upsert → read)', () async {
    final phraseId = (await repo.getActivePhrases()).first.phraseId;
    const profileId = AppDatabase.defaultProfileId;

    // No row yet → sensible defaults.
    var s = await repo.getProgressionState(profileId, phraseId);
    expect(s.rung, Rung.r2);
    expect(s.syllableTier, 1);
    expect(s.bpm, MitProgression.defaultBpm);

    await repo.upsertProgressionState(
        s.copyWith(rung: Rung.r5, syllableTier: 2, bpm: 50));
    s = await repo.getProgressionState(profileId, phraseId);
    expect(s.rung, Rung.r5);
    expect(s.syllableTier, 2);
    expect(s.bpm, 50);
  });

  test('resetProgression sends every phrase back to R0 and clears tier/tempo',
      () async {
    const profileId = AppDatabase.defaultProfileId;
    final phrases = await repo.getAllPhrases();
    final phraseId = phrases.first.phraseId;

    // Advance a phrase up the ladder with a non-default tier/tempo.
    await repo.setRung(phraseId, Rung.r6);
    await repo.upsertProgressionState(
        ProgressionState(profileId: profileId, phraseId: phraseId)
            .copyWith(rung: Rung.r6, syllableTier: 3, bpm: 40));

    await repo.resetProgression(profileId);

    // Every phrase row is back at R0…
    for (final p in await repo.getAllPhrases()) {
      expect(p.rung, Rung.r0, reason: 'phrase ${p.phraseId} reset to R0');
    }
    // …and the progression record is gone, so reads fall back to defaults.
    final s = await repo.getProgressionState(profileId, phraseId);
    expect(s.syllableTier, 1);
    expect(s.bpm, MitProgression.defaultBpm);
  });

  test('sessionPassRates: judged attempts only, per session, oldest→newest',
      () async {
    final phraseId = (await repo.getActivePhrases()).first.phraseId;
    const profileId = AppDatabase.defaultProfileId;

    // Session 1: one Pass + one Fail at judged rungs = 0.5; an Unsure and a
    // co-production (rung < 4) attempt are ignored.
    final s1 = await repo.createSession(profileId);
    await repo.insertAttempt(
        sessionId: s1, phraseId: phraseId, evaluationLabel: 1, rungAtAttempt: 5);
    await repo.insertAttempt(
        sessionId: s1, phraseId: phraseId, evaluationLabel: 0, rungAtAttempt: 5);
    await repo.insertAttempt(
        sessionId: s1, phraseId: phraseId, evaluationLabel: 2, rungAtAttempt: 5);
    await repo.insertAttempt(
        sessionId: s1, phraseId: phraseId, evaluationLabel: 1, rungAtAttempt: 1);

    // Session 2: two Passes at judged rungs = 1.0.
    final s2 = await repo.createSession(profileId);
    await repo.insertAttempt(
        sessionId: s2, phraseId: phraseId, evaluationLabel: 1, rungAtAttempt: 6);
    await repo.insertAttempt(
        sessionId: s2, phraseId: phraseId, evaluationLabel: 1, rungAtAttempt: 4);

    final rates = await repo.sessionPassRates(profileId, phraseId: phraseId);
    expect(rates, [0.5, 1.0]);
  });

  test('sessionPassRates: minRung (top-rung) and tier filters for the tier gate',
      () async {
    final phraseId = (await repo.getActivePhrases()).first.phraseId;
    const profileId = AppDatabase.defaultProfileId;

    // Session A: an R6 Pass at tier 1, and an R4 Pass (below the top rung).
    final a = await repo.createSession(profileId);
    await repo.insertAttempt(
        sessionId: a,
        phraseId: phraseId,
        evaluationLabel: 1,
        rungAtAttempt: 6,
        tierAtAttempt: 1);
    await repo.insertAttempt(
        sessionId: a,
        phraseId: phraseId,
        evaluationLabel: 0,
        rungAtAttempt: 4,
        tierAtAttempt: 1);

    // Session B: an R6 Pass at tier 2 (a later tier).
    final b = await repo.createSession(profileId);
    await repo.insertAttempt(
        sessionId: b,
        phraseId: phraseId,
        evaluationLabel: 1,
        rungAtAttempt: 6,
        tierAtAttempt: 2);

    // Top-rung only (minRung 6): the R4 attempt drops out → A is 1.0 (R6 pass).
    final topRung = await repo.sessionPassRates(profileId,
        phraseId: phraseId, minRung: 6);
    expect(topRung, [1.0, 1.0]); // session A (R6) and session B (R6)

    // Scoped to tier 1: only session A's R6 attempt counts; session B (tier 2)
    // is excluded — so old top-rung mastery can't re-trigger a later tier.
    final tier1 = await repo.sessionPassRates(profileId,
        phraseId: phraseId, minRung: 6, tier: 1);
    expect(tier1, [1.0]); // just session A
  });

  test('setPhoto attaches and clears a name-card photo', () async {
    final phrase = (await repo.getActivePhrases()).first;
    expect(phrase.hasPhoto, isFalse);

    await repo.setPhoto(phrase.phraseId, '/photos/phrase_x.enc');
    var updated = (await repo.getAllPhrases())
        .firstWhere((p) => p.phraseId == phrase.phraseId);
    expect(updated.photoPath, '/photos/phrase_x.enc');
    expect(updated.hasPhoto, isTrue);

    await repo.setPhoto(phrase.phraseId, null); // remove it
    updated = (await repo.getAllPhrases())
        .firstWhere((p) => p.phraseId == phrase.phraseId);
    expect(updated.photoPath, isNull);
    expect(updated.hasPhoto, isFalse);
  });

  test('addPhrase inserts a custom (Unicode) phrase, active + needing a guide',
      () async {
    final id = await repo.addPhrase('Mañana'); // non-ASCII, multi-language
    final added =
        (await repo.getAllPhrases()).firstWhere((p) => p.phraseId == id);
    expect(added.phraseText, 'Mañana');
    expect(added.isActive, isTrue);
    expect(added.hasRecordedGuide, isFalse);
    expect((await repo.getPhrasesNeedingGuide()).any((p) => p.phraseId == id),
        isTrue);

    // Recording its guide over 3 beats sets the syllable count.
    await repo.setGuideClip(id, '/guides/x.enc', 3);
    final updated =
        (await repo.getAllPhrases()).firstWhere((p) => p.phraseId == id);
    expect(updated.syllableCount, 3);
    expect(updated.hasRecordedGuide, isTrue);
  });

  test('setGuideClip stores path + syllable count; needs-guide list updates',
      () async {
    final phrase = (await repo.getActivePhrases()).first;
    // Initially no recorded guide; it shows up in the needs-guide list.
    expect(await repo.getGuideClip(phrase.phraseId), isNull);
    expect(phrase.hasRecordedGuide, isFalse);
    expect((await repo.getPhrasesNeedingGuide()).any((p) => p.phraseId == phrase.phraseId), isTrue);

    // 3 confirmed syllable nuclei (therapy addendum §2 revision).
    await repo.setGuideClip(phrase.phraseId, '/clips/guide_x.enc', 3,
        nucleiMs: const [100, 500, 900]);

    expect(await repo.getGuideClip(phrase.phraseId), '/clips/guide_x.enc');
    final updated =
        (await repo.getAllPhrases()).firstWhere((p) => p.phraseId == phrase.phraseId);
    expect(updated.guideClipPath, '/clips/guide_x.enc');
    expect(updated.hasRecordedGuide, isTrue);
    expect(updated.syllableCount, 3);
    expect(updated.guideNucleiMs, const [100, 500, 900]); // timings round-trip
    expect((await repo.getPhrasesNeedingGuide()).any((p) => p.phraseId == phrase.phraseId), isFalse);
  });

  test('updateProfile changes settings; granting consent stamps time+version',
      () async {
    await repo.updateProfile(
      metronomeBpm: 72,
      soundEnabled: false,
      sessionPhraseLimit: 5,
      guardianConsentGranted: true,
    );

    final p = await repo.getProfile();
    expect(p.metronomeBpm, 72);
    expect(p.soundEnabled, isFalse);
    expect(p.sessionPhraseLimit, 5);
    expect(p.guardianConsentGranted, isTrue);

    final row = (await db.query('user_profiles')).single;
    expect(row['consent_timestamp'], isNotNull);
    expect(row['consent_schema_version'],
        PracticeRepository.consentSchemaVersion);
  });

  test('setPhraseActive removes a phrase from the active set', () async {
    final id = (await repo.getAllPhrases()).first.phraseId;
    await repo.setPhraseActive(id, false);
    final active = await repo.getActivePhrases();
    expect(active.any((p) => p.phraseId == id), isFalse);
  });

  test('foreign key rejects an attempt for a non-existent session', () async {
    final phraseId = (await repo.getActivePhrases()).first.phraseId;
    await expectLater(
      repo.insertAttempt(
        sessionId: 'does-not-exist',
        phraseId: phraseId,
        evaluationLabel: 2,
      ),
      throwsA(isA<DatabaseException>()),
    );
  });

  test('sync bookkeeping: unsynced lists, marking synced, cloud profile id',
      () async {
    final phraseId = (await repo.getActivePhrases()).first.phraseId;
    final sessionId = await repo.createSession(AppDatabase.defaultProfileId);
    final attemptId = await repo.insertAttempt(
      sessionId: sessionId,
      phraseId: phraseId,
      evaluationLabel: 1,
      tappingSynchronizationScore: 0.9,
    );

    // Both start unsynced; the attempt carries its phrase text for the cloud.
    expect((await repo.getUnsyncedSessions()).single.sessionId, sessionId);
    final unsyncedAttempts = await repo.getUnsyncedAttempts();
    expect(unsyncedAttempts.single['attempt_id'], attemptId);
    expect(unsyncedAttempts.single['phrase_text'], isA<String>());

    // After marking, they drop out of the unsynced lists.
    await repo.markSessionSynced(sessionId, '2026-06-05T00:00:00Z');
    await repo.markAttemptSynced(attemptId, '2026-06-05T00:00:00Z');
    expect(await repo.getUnsyncedSessions(), isEmpty);
    expect(await repo.getUnsyncedAttempts(), isEmpty);

    // Cloud profile id round-trips.
    expect(await repo.getCloudProfileId(), isNull);
    await repo.setCloudProfileId('cloud-uuid-123');
    expect(await repo.getCloudProfileId(), 'cloud-uuid-123');
  });
}
