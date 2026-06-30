// Anchor + feature-vector repository tests (Phase 2A step 7). In-memory database
// with the real v3 schema + seed. Drives the promotion/replacement rules from
// fixture-derived MFCCs, since live caregiver labels don't flow yet (no mic).

import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

import 'package:rhythmic_practice/analysis/attempt_analyzer.dart';
import 'package:rhythmic_practice/data/app_database.dart';
import 'package:rhythmic_practice/data/practice_repository.dart';

void main() {
  setUpAll(sqfliteFfiInit);

  late Database db;
  late PracticeRepository repo;
  late int phraseId;
  late String sessionId;
  const profileId = AppDatabase.defaultProfileId;

  setUp(() async {
    db = await databaseFactoryFfi.openDatabase(
      inMemoryDatabasePath,
      options: OpenDatabaseOptions(
        version: 3,
        onConfigure: (db) => db.execute('PRAGMA foreign_keys = ON'),
        onCreate: (db, v) => AppDatabase.applyInitialSchema(db),
      ),
    );
    repo = PracticeRepository.withDatabase(db);
    phraseId = (await repo.getActivePhrases()).first.phraseId;
    sessionId = await repo.createSession(profileId);
  });

  tearDown(() => db.close());

  List<Float64List> mfcc(List<List<double>> f) =>
      f.map((r) => Float64List.fromList(r)).toList();

  Future<String> attempt(int label) => repo.insertAttempt(
        sessionId: sessionId,
        phraseId: phraseId,
        evaluationLabel: label,
      );

  group('feature vectors', () {
    test('persists and reads back a passed clip with a score', () async {
      final attemptId = await attempt(1);
      const result = AnalysisResult(
        gatePassed: true,
        gateReason: 'ok',
        contentSimilarityScore: 0.83,
        durationMs: 1200,
        mfcc: [],
      );
      await repo.insertFeatureVector(attemptId: attemptId, result: result);

      final fv = await repo.getFeatureVector(attemptId);
      expect(fv, isNotNull);
      expect(fv!.gatePassed, isTrue);
      expect(fv.gateReason, 'ok');
      expect(fv.contentSimilarityScore, closeTo(0.83, 1e-9));
      expect(fv.durationMs, 1200);
    });

    test('a gate-rejected clip stores a null score', () async {
      final attemptId = await attempt(2);
      const result = AnalysisResult(
        gatePassed: false,
        gateReason: 'too_quiet',
        contentSimilarityScore: null,
        durationMs: 500,
        mfcc: [],
      );
      await repo.insertFeatureVector(attemptId: attemptId, result: result);

      final fv = await repo.getFeatureVector(attemptId);
      expect(fv!.gatePassed, isFalse);
      expect(fv.gateReason, 'too_quiet');
      expect(fv.contentSimilarityScore, isNull);
    });
  });

  group('anchor promotion / replacement (brief §4)', () {
    final featuresA = [
      [1.0, 2.0, 3.0],
      [4.0, 5.0, 6.0],
    ];
    final featuresB = [
      [7.0, 8.0, 9.0],
      [10.0, 11.0, 12.0],
    ];

    test('first confirmed Pass with no anchor -> promoted', () async {
      final a1 = await attempt(1);
      final action = await repo.considerAnchor(
        profileId: profileId,
        phraseId: phraseId,
        sourceAttemptId: a1,
        mfcc: mfcc(featuresA),
        scoreVsReference: 0.5,
      );
      expect(action, AnchorAction.promoted);

      final anchor = await repo.getAnchor(profileId, phraseId);
      expect(anchor, isNotNull);
      expect(anchor!.scoreVsReference, closeTo(0.5, 1e-9));
      expect(anchor.sourceAttemptId, a1);
      // MFCC decoded back intact.
      expect(anchor.mfcc.length, 2);
      expect(anchor.mfcc[1][2], 6.0);
    });

    test('a stronger confirmed Pass (higher score) -> replaced', () async {
      final a1 = await attempt(1);
      await repo.considerAnchor(
        profileId: profileId,
        phraseId: phraseId,
        sourceAttemptId: a1,
        mfcc: mfcc(featuresA),
        scoreVsReference: 0.5,
      );
      final a2 = await attempt(1);
      final action = await repo.considerAnchor(
        profileId: profileId,
        phraseId: phraseId,
        sourceAttemptId: a2,
        mfcc: mfcc(featuresB),
        scoreVsReference: 0.7, // beats the stored 0.5
      );
      expect(action, AnchorAction.replaced);

      final anchor = await repo.getAnchor(profileId, phraseId);
      expect(anchor!.scoreVsReference, closeTo(0.7, 1e-9));
      expect(anchor.sourceAttemptId, a2);
      expect(anchor.mfcc[0][0], 7.0); // now holds featuresB
    });

    test('a weaker confirmed Pass (lower score) -> kept, anchor unchanged',
        () async {
      final a1 = await attempt(1);
      await repo.considerAnchor(
        profileId: profileId,
        phraseId: phraseId,
        sourceAttemptId: a1,
        mfcc: mfcc(featuresA),
        scoreVsReference: 0.6,
      );
      final a2 = await attempt(1);
      final action = await repo.considerAnchor(
        profileId: profileId,
        phraseId: phraseId,
        sourceAttemptId: a2,
        mfcc: mfcc(featuresB),
        scoreVsReference: 0.4, // does NOT beat 0.6
      );
      expect(action, AnchorAction.kept);

      final anchor = await repo.getAnchor(profileId, phraseId);
      expect(anchor!.scoreVsReference, closeTo(0.6, 1e-9));
      expect(anchor.sourceAttemptId, a1); // still the original
      expect(anchor.mfcc[0][0], 1.0); // still featuresA
    });

    test('only one anchor exists per (profile, phrase)', () async {
      final a1 = await attempt(1);
      final a2 = await attempt(1);
      await repo.considerAnchor(
          profileId: profileId,
          phraseId: phraseId,
          sourceAttemptId: a1,
          mfcc: mfcc(featuresA),
          scoreVsReference: 0.5);
      await repo.considerAnchor(
          profileId: profileId,
          phraseId: phraseId,
          sourceAttemptId: a2,
          mfcc: mfcc(featuresB),
          scoreVsReference: 0.9);
      final count = (await db.query('phrase_anchor_templates')).length;
      expect(count, 1);
    });

    test('getAnchor returns null when no anchor exists', () async {
      expect(await repo.getAnchor(profileId, phraseId), isNull);
    });
  });

  group('cascade', () {
    test('deleting the profile removes its anchors (FK cascade)', () async {
      final a1 = await attempt(1);
      await repo.considerAnchor(
        profileId: profileId,
        phraseId: phraseId,
        sourceAttemptId: a1,
        mfcc: mfcc([
          [1, 2, 3]
        ]),
        scoreVsReference: 0.5,
      );
      expect(await repo.getAnchor(profileId, phraseId), isNotNull);

      await db.delete('user_profiles',
          where: 'profile_id = ?', whereArgs: [profileId]);

      expect(await repo.getAnchor(profileId, phraseId), isNull);
    });

    test('deleting a phrase removes its anchors (FK cascade)', () async {
      // Use a phrase that has an anchor but no attempts, so the delete isn't
      // blocked by the exercise_attempts -> phrase FK. (source_attempt_id has
      // no FK, so a placeholder id is fine.)
      final otherPhraseId = (await repo.getActivePhrases())[1].phraseId;
      await repo.considerAnchor(
        profileId: profileId,
        phraseId: otherPhraseId,
        sourceAttemptId: 'placeholder',
        mfcc: mfcc([
          [1, 2, 3]
        ]),
        scoreVsReference: 0.5,
      );
      expect(await repo.getAnchor(profileId, otherPhraseId), isNotNull);

      await db.delete('practice_phrases',
          where: 'phrase_id = ?', whereArgs: [otherPhraseId]);

      expect(await repo.getAnchor(profileId, otherPhraseId), isNull);
    });
  });
}
