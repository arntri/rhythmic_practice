// Persistence tests for sessions/attempts, run against an in-memory database
// (the real schema + seed, no files, no device).

import 'package:flutter_test/flutter_test.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

import 'package:rhythmic_practice/data/app_database.dart';
import 'package:rhythmic_practice/data/models.dart';
import 'package:rhythmic_practice/data/practice_repository.dart';
import 'package:rhythmic_practice/practice/practice_controller.dart';
import 'package:rhythmic_practice/practice/mit_sequence.dart';

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
      step: MitStep.immediateRepeat,
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
    expect(taps[0].step, MitStep.immediateRepeat);
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
      step: MitStep.intoneUnison,
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

  test('recording a guide no longer touches progression', () async {
    // Under the ladder, confirming a guide seeded the word's entry rung from its
    // syllable count — and had to be careful not to reset a word already
    // climbing. There is no resting rung to seed or protect now: every item runs
    // the patient's level sequence in full, so this write is purely about the
    // clip, the syllable count and the contour.
    final phrase = (await repo.getActivePhrases()).first;
    await repo.setGuideClip(phrase.phraseId, 'guides/g.enc', 5,
        nucleiMs: const [100, 300, 500, 700, 900], stressIndex: 2);
    final after = (await repo.getAllPhrases())
        .firstWhere((p) => p.phraseId == phrase.phraseId);
    expect(after.guideClipPath, 'guides/g.enc');
    expect(after.syllableCount, 5);
    expect(after.guideNucleiMs, const [100, 300, 500, 700, 900]);
    expect(after.stressIndex, 2);
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
    // A phrase with no authored contour yet — the starter library ships its
    // own stress indices, so pick one of the seeded phrases instead.
    final phrase = (await repo.getAllPhrases())
        .firstWhere((p) => !p.isStarter && p.stressIndex == null);
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

  test('the MIT level defaults to II, round-trips, and survives other writes',
      () async {
    // Level II is MIT's core sequence, so a fresh profile opens there.
    expect((await repo.getProfile()).mitLevel, MitLevel.two);

    await repo.updateProfile(mitLevel: MitLevel.one);
    expect((await repo.getProfile()).mitLevel, MitLevel.one);

    // Updating an unrelated field leaves the level alone.
    await repo.updateProfile(metronomeBpm: 55);
    expect((await repo.getProfile()).mitLevel, MitLevel.one);

    await repo.updateProfile(mitLevel: MitLevel.three);
    expect((await repo.getProfile()).mitLevel, MitLevel.three);
  });

  test('the practice goal defaults to an hour a day and round-trips', () async {
    // Minutes a day — the shape of what the research protocols asked for, and
    // stated on screen rather than implied. See PracticeDose.
    expect((await repo.getProfile()).practiceTargetMinutes, 60);
    await repo.updateProfile(practiceTargetMinutes: 30);
    expect((await repo.getProfile()).practiceTargetMinutes, 30);
    // An unrelated write leaves it alone.
    await repo.updateProfile(metronomeBpm: 55);
    expect((await repo.getProfile()).practiceTargetMinutes, 30);
  });

  test('a session records how long it ran, from its attempts', () async {
    // Practice dose is measured in minutes, and sessions used to record only
    // when they STARTED — there was no way to know how long one lasted.
    const profileId = AppDatabase.defaultProfileId;
    final phraseId = (await repo.getActivePhrases()).first.phraseId;
    final sid = await repo.createSession(profileId);

    // Before any attempt, the session has no end and contributes nothing:
    // opening the app is not practice.
    expect(await repo.minutesPerDay(profileId), isEmpty);

    await repo.insertAttempt(
        sessionId: sid, phraseId: phraseId, evaluationLabel: 1);
    final minutes = await repo.minutesPerDay(profileId);
    expect(minutes, isNotEmpty, reason: 'the session now has an end');
    expect(minutes.values.first, greaterThanOrEqualTo(0));
  });

  test('resetProgression puts the patient back at Level I', () async {
    const profileId = AppDatabase.defaultProfileId;
    await repo.updateProfile(mitLevel: MitLevel.three);

    await repo.resetProgression(profileId);

    // The level IS the progression now — there is no per-word rung, tier or
    // tempo left to clear alongside it.
    expect((await repo.getProfile()).mitLevel, MitLevel.one);
  });

  test('sessionPassRates: judged attempts only, per session, oldest→newest',
      () async {
    final phraseId = (await repo.getActivePhrases()).first.phraseId;
    const profileId = AppDatabase.defaultProfileId;

    // Session 1: one Pass + one Fail = 0.5. The Unsure is ignored — "we could
    // not tell" is not evidence either way.
    final s1 = await repo.createSession(profileId);
    await repo.insertAttempt(
        sessionId: s1,
        phraseId: phraseId,
        evaluationLabel: 1,
        stepAtAttempt: MitStep.immediateRepeat.index);
    await repo.insertAttempt(
        sessionId: s1,
        phraseId: phraseId,
        evaluationLabel: 0,
        stepAtAttempt: MitStep.immediateRepeat.index);
    await repo.insertAttempt(
        sessionId: s1,
        phraseId: phraseId,
        evaluationLabel: 2,
        stepAtAttempt: MitStep.immediateRepeat.index);

    // Session 2: two Passes = 1.0.
    final s2 = await repo.createSession(profileId);
    await repo.insertAttempt(
        sessionId: s2,
        phraseId: phraseId,
        evaluationLabel: 1,
        stepAtAttempt: MitStep.probeQuestion.index);
    await repo.insertAttempt(
        sessionId: s2,
        phraseId: phraseId,
        evaluationLabel: 1,
        stepAtAttempt: MitStep.intoneUnison.index);

    final rates = await repo.sessionPassRates(profileId, phraseId: phraseId);
    expect(rates, [0.5, 1.0]);
  });

  test('sessionPassRates: the step filter narrows to one MIT step', () async {
    final phraseId = (await repo.getActivePhrases()).first.phraseId;
    const profileId = AppDatabase.defaultProfileId;

    // Session A: a Pass at the probe question, and a Fail at the unison step.
    final a = await repo.createSession(profileId);
    await repo.insertAttempt(
        sessionId: a,
        phraseId: phraseId,
        evaluationLabel: 1,
        stepAtAttempt: MitStep.probeQuestion.index);
    await repo.insertAttempt(
        sessionId: a,
        phraseId: phraseId,
        evaluationLabel: 0,
        stepAtAttempt: MitStep.intoneUnison.index);

    // Session B: a Pass at the probe question only.
    final b = await repo.createSession(profileId);
    await repo.insertAttempt(
        sessionId: b,
        phraseId: phraseId,
        evaluationLabel: 1,
        stepAtAttempt: MitStep.probeQuestion.index);

    // Unfiltered, session A mixes both steps → 0.5.
    expect(await repo.sessionPassRates(profileId, phraseId: phraseId),
        [0.5, 1.0]);

    // Narrowed to the probe question — which is how solo-mode eligibility is
    // measured — the unison Fail drops out and both sessions read 1.0.
    final probeOnly = await repo.sessionPassRates(profileId,
        phraseId: phraseId, step: MitStep.probeQuestion);
    expect(probeOnly, [1.0, 1.0]);
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
