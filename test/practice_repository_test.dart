// Persistence tests for sessions/attempts, run against an in-memory database
// (the real schema + seed, no files, no device).

import 'package:flutter_test/flutter_test.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

import 'package:rhythmic_practice/data/app_database.dart';
import 'package:rhythmic_practice/data/models.dart';
import 'package:rhythmic_practice/data/practice_repository.dart';
import 'package:rhythmic_practice/practice/mit_progression.dart';
import 'package:rhythmic_practice/practice/practice_controller.dart';
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

  test('persists and reads back the raw tap stream for an attempt', () async {
    final phraseId = (await repo.getActivePhrases()).first.phraseId;
    final sessionId = await repo.createSession(AppDatabase.defaultProfileId);
    final attemptId = await repo.insertAttempt(
      sessionId: sessionId,
      phraseId: phraseId,
      evaluationLabel: 1,
    );

    await repo.insertTapEvents(
      attemptId: attemptId,
      phraseId: phraseId,
      sessionId: sessionId,
      rung: 4,
      taps: [
        TapEvent(downMs: 100, phase: 0.02, dwellMs: 55),
        TapEvent(downMs: 640, phase: 0.30, dwellMs: 80),
        TapEvent(downMs: 1180, phase: 0.10), // no release observed → dwell null
      ],
    );

    final taps = await repo.getTapEvents(attemptId);
    expect(taps.length, 3);
    // Preserved order + fields, including the dwell that was never measured.
    expect(taps.map((t) => t.tapIndex), [0, 1, 2]);
    expect(taps[0].downMs, 100);
    expect(taps[0].dwellMs, 55);
    expect(taps[0].beatPhase, closeTo(0.02, 1e-9));
    expect(taps[0].rung, 4);
    expect(taps[2].dwellMs, isNull);

    // The session read returns the same taps in chronological order.
    final bySession = await repo.getTapEventsForSession(sessionId);
    expect(bySession.map((t) => t.downMs), [100, 640, 1180]);
  });

  test('insertAttempt persists tempo_bpm as the beat reference (item 16c)',
      () async {
    final phraseId = (await repo.getActivePhrases()).first.phraseId;
    final sessionId = await repo.createSession(AppDatabase.defaultProfileId);
    final attemptId = await repo.insertAttempt(
      sessionId: sessionId,
      phraseId: phraseId,
      evaluationLabel: 1,
      tempoBpm: 50,
    );
    final row = (await db.query('exercise_attempts',
            where: 'attempt_id = ?', whereArgs: [attemptId]))
        .single;
    expect(row['tempo_bpm'], 50);
  });

  test('insertTapEvents is a no-op for an empty stream', () async {
    final phraseId = (await repo.getActivePhrases()).first.phraseId;
    final sessionId = await repo.createSession(AppDatabase.defaultProfileId);
    final attemptId = await repo.insertAttempt(
        sessionId: sessionId, phraseId: phraseId, evaluationLabel: 2);
    await repo.insertTapEvents(
      attemptId: attemptId,
      phraseId: phraseId,
      sessionId: sessionId,
      rung: 0,
      taps: const [],
    );
    expect(await repo.getTapEvents(attemptId), isEmpty);
  });

  test('setProbeQuestion round-trips on a phrase (R7, item 11)', () async {
    final phrase = (await repo.getActivePhrases()).first;
    expect(phrase.probeQuestionText, isNull); // none by default
    await repo.setProbeQuestion(phrase.phraseId,
        text: 'How are you feeling?', clipPath: 'clips/probe.enc');
    final updated = (await repo.getAllPhrases())
        .firstWhere((p) => p.phraseId == phrase.phraseId);
    expect(updated.probeQuestionText, 'How are you feeling?');
    expect(updated.probeQuestionClipPath, 'clips/probe.enc');
    // Clearing sets both back to null.
    await repo.setProbeQuestion(phrase.phraseId);
    final cleared = (await repo.getAllPhrases())
        .firstWhere((p) => p.phraseId == phrase.phraseId);
    expect(cleared.probeQuestionText, isNull);
    expect(cleared.probeQuestionClipPath, isNull);
  });

  test('default progression tier is seeded from syllable count (item 12)',
      () async {
    final all = await repo.getAllPhrases();
    // A single-syllable starter word → Level 1.
    final short = all.firstWhere((p) => p.phraseText == 'Help');
    final shortState =
        await repo.getProgressionState(AppDatabase.defaultProfileId, short.phraseId);
    expect(shortState.syllableTier, 1);
    // The seeded 7-syllable phrase → Level 3 by default (no stored row yet).
    final long = all.firstWhere((p) => p.syllableCount >= 7);
    final longState =
        await repo.getProgressionState(AppDatabase.defaultProfileId, long.phraseId);
    expect(longState.syllableTier, 3);
    // A seeded 4-syllable phrase → Level 2.
    final mid = all.firstWhere((p) => p.syllableCount == 4);
    final midState =
        await repo.getProgressionState(AppDatabase.defaultProfileId, mid.phraseId);
    expect(midState.syllableTier, 2);
  });

  test('recording a guide starts an un-practised word at unison (R2)', () async {
    final phrase = (await repo.getActivePhrases()).first; // an un-practised word
    // Every word now enters at unison regardless of level (progression refactor).
    await repo.setGuideClip(phrase.phraseId, 'guides/g.enc', 5,
        nucleiMs: const [100, 300, 500, 700, 900]);
    final l2 = (await repo.getAllPhrases())
        .firstWhere((p) => p.phraseId == phrase.phraseId);
    expect(l2.rung, Rung.r2);
  });

  test('re-recording a PROGRESSED word never resets its rung (item 13)',
      () async {
    final phrase = (await repo.getActivePhrases()).first;
    // The word has been practised: a progression_state row exists at R6.
    await repo.upsertProgressionState(ProgressionState(
      profileId: AppDatabase.defaultProfileId,
      phraseId: phrase.phraseId,
      rung: Rung.r6,
    ));
    await repo.setRung(phrase.phraseId, Rung.r6);
    // Re-recording a (now Level-2) guide must NOT drag it back to the entry rung.
    await repo.setGuideClip(phrase.phraseId, 'guides/g2.enc', 5,
        nucleiMs: const [100, 300, 500, 700, 900]);
    final after = (await repo.getAllPhrases())
        .firstWhere((p) => p.phraseId == phrase.phraseId);
    expect(after.rung, Rung.r6); // progress preserved
  });

  test('setSprechgesangClip round-trips (item 15) and null clears it', () async {
    final phrase = (await repo.getActivePhrases()).first;
    expect(phrase.hasSprechgesangClip, isFalse); // none by default

    await repo.setSprechgesangClip(phrase.phraseId, 'guides/slow.enc');
    var after = (await repo.getAllPhrases())
        .firstWhere((p) => p.phraseId == phrase.phraseId);
    expect(after.sprechgesangClipPath, 'guides/slow.enc');
    expect(after.hasSprechgesangClip, isTrue);

    await repo.setSprechgesangClip(phrase.phraseId, null);
    after = (await repo.getAllPhrases())
        .firstWhere((p) => p.phraseId == phrase.phraseId);
    expect(after.sprechgesangClipPath, isNull);
  });

  test('setGuideClip stores the caregiver-designated stress index (item A)',
      () async {
    final phrase = (await repo.getActivePhrases()).first;
    expect(phrase.stressIndex, isNull); // none until a contour is confirmed
    await repo.setGuideClip(
      phrase.phraseId,
      'guides/clip.enc',
      2,
      nucleiMs: const [120, 480],
      stressIndex: 0,
    );
    final updated = (await repo.getAllPhrases())
        .firstWhere((p) => p.phraseId == phrase.phraseId);
    expect(updated.stressIndex, 0);
    expect(updated.guideNucleiMs, [120, 480]);
    // Re-saving without a stress index leaves the existing choice intact.
    await repo.setGuideClip(phrase.phraseId, 'guides/clip2.enc', 2,
        nucleiMs: const [120, 480]);
    final again = (await repo.getAllPhrases())
        .firstWhere((p) => p.phraseId == phrase.phraseId);
    expect(again.stressIndex, 0);
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

  test('resetProgression sends every phrase back to unison and clears tier/tempo',
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

    // Every phrase row is back at the unison entry (R2 — tap/hum are the warm-up)…
    for (final p in await repo.getAllPhrases()) {
      expect(p.rung, Rung.r2, reason: 'phrase ${p.phraseId} reset to unison');
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
