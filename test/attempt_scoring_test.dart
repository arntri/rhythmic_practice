import 'dart:math' as math;
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

import 'package:rhythmic_practice/analysis/wav_writer.dart';
import 'package:rhythmic_practice/data/app_database.dart';
import 'package:rhythmic_practice/data/practice_repository.dart';
import 'package:rhythmic_practice/services/attempt_scoring.dart';

void main() {
  setUpAll(sqfliteFfiInit);

  const sr = 16000;
  Uint8List tone(double seconds, double amp) {
    final n = (seconds * sr).round();
    final s = Float64List(n);
    for (var i = 0; i < n; i++) {
      s[i] = amp * math.sin(2 * math.pi * 200 * i / sr);
    }
    return WavWriter.encode(s);
  }

  late Database db;
  late PracticeRepository repo;
  late int phraseId;

  setUp(() async {
    db = await databaseFactoryFfi.openDatabase(
      inMemoryDatabasePath,
      options: OpenDatabaseOptions(
        version: 6,
        onConfigure: (db) => db.execute('PRAGMA foreign_keys = ON'),
        onCreate: (db, v) => AppDatabase.applyInitialSchema(db),
      ),
    );
    repo = PracticeRepository.withDatabase(db);
    phraseId = (await repo.getActivePhrases()).first.phraseId;
  });

  tearDown(() => db.close());

  // Insert a real attempt row (the feature vector FK-references it) and return id.
  Future<String> newAttempt(int label) async {
    final session = await repo.createSession(AppDatabase.defaultProfileId);
    return repo.insertAttempt(
      sessionId: session,
      phraseId: phraseId,
      evaluationLabel: label,
      localEncryptedAudioPath: 'attempt.wav',
    );
  }

  AttemptScoring scorer(Map<String, Uint8List> clips) => AttemptScoring(
        repo: repo,
        decryptor: (path) async => clips[path]!,
      );

  test('a Pass attempt is scored and promoted to the phrase anchor', () async {
    final id = await newAttempt(1); // Pass
    final s = scorer({'attempt.wav': tone(1, 0.3), 'guide.wav': tone(1, 0.3)});

    final stored = await s.scoreAttempt(
      attemptId: id,
      phraseId: phraseId,
      profileId: AppDatabase.defaultProfileId,
      encryptedAttemptPath: 'attempt.wav',
      guideClipPath: 'guide.wav',
      evaluationLabel: 1,
    );
    expect(stored, isTrue);

    final fv = await repo.getFeatureVector(id);
    expect(fv, isNotNull);
    expect(fv!.gatePassed, isTrue);
    expect(fv.contentSimilarityScore, isNotNull);
    expect(fv.contentSimilarityScore, inInclusiveRange(0.0, 1.0));

    // Pass + clean → anchor promoted.
    expect(await repo.getAnchor(AppDatabase.defaultProfileId, phraseId), isNotNull);
  });

  test('no guide clip → nothing scored', () async {
    final id = await newAttempt(1);
    final s = scorer({'attempt.wav': tone(1, 0.3)});
    final stored = await s.scoreAttempt(
      attemptId: id,
      phraseId: phraseId,
      profileId: AppDatabase.defaultProfileId,
      encryptedAttemptPath: 'attempt.wav',
      guideClipPath: null,
      evaluationLabel: 1,
    );
    expect(stored, isFalse);
    expect(await repo.getFeatureVector(id), isNull);
  });

  test('a silent attempt fails the gate; stored without a score, no anchor',
      () async {
    final id = await newAttempt(1);
    final silent = WavWriter.encode(Float64List(sr)); // 1 s of zeros
    final s = scorer({'attempt.wav': silent, 'guide.wav': tone(1, 0.3)});

    final stored = await s.scoreAttempt(
      attemptId: id,
      phraseId: phraseId,
      profileId: AppDatabase.defaultProfileId,
      encryptedAttemptPath: 'attempt.wav',
      guideClipPath: 'guide.wav',
      evaluationLabel: 1,
    );
    expect(stored, isTrue); // a (failed-gate) feature vector is still recorded
    final fv = await repo.getFeatureVector(id);
    expect(fv!.gatePassed, isFalse);
    expect(fv.contentSimilarityScore, isNull);
    expect(await repo.getAnchor(AppDatabase.defaultProfileId, phraseId), isNull);
  });
}
