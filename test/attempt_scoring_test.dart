import 'dart:io';
import 'dart:math' as math;
import 'dart:typed_data';

import 'package:encrypt/encrypt.dart' as crypt;
import 'package:flutter_test/flutter_test.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

import 'package:rhythmic_practice/analysis/wav_writer.dart';
import 'package:rhythmic_practice/services/audio_crypto.dart';
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
        runInIsolate: false, // inline + deterministic for tests
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
    // Item 16b: the raw DTW distance is stored alongside the similarity.
    expect(fv.mfccDistance, isNotNull);
    expect(fv.mfccDistance, greaterThanOrEqualTo(0.0));
    // Item 16c: patient onsets are a (possibly empty) list, never null-crashing.
    expect(fv.onsetMs, isA<List<int>>());

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

  test('the off-thread isolate path (item 21) scores the same as inline',
      () async {
    final id = await newAttempt(1);
    // runInIsolate defaults to true → the CPU pipeline runs via compute().
    final s = AttemptScoring(
      repo: repo,
      decryptor: (path) async =>
          {'attempt.wav': tone(1, 0.3), 'guide.wav': tone(1, 0.3)}[path]!,
    );
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
    expect(fv.contentSimilarityScore, inInclusiveRange(0.0, 1.0));
  });

  // The production shape: no injected decryptor, so the worker reads the .enc
  // files and AES-decrypts them ITSELF. This is what keeps the cipher pass off
  // the UI thread — decrypting two clips there was starving the metronome's
  // Ticker at the caregiver verdict and making the beat stutter.
  test('with no injected decryptor the worker reads and decrypts the clips',
      () async {
    final id = await newAttempt(1);
    final dir = await Directory.systemTemp.createTemp('scoring_enc');
    addTearDown(() => dir.delete(recursive: true));

    // A fixed key, so the test never touches the OS keystore — AesCipher is pure.
    final key = crypt.Key.fromLength(32);
    Future<String> writeEnc(String name, Uint8List wav) async {
      final path = '${dir.path}/$name';
      await File(path).writeAsBytes(AesCipher.encrypt(wav, key), flush: true);
      return path;
    }

    final attemptPath = await writeEnc('attempt.enc', tone(1, 0.3));
    final guidePath = await writeEnc('guide.enc', tone(1, 0.3));

    final s = AttemptScoring(
      repo: repo,
      crypto: _FixedKeyCrypto(key.bytes),
      runInIsolate: false, // deterministic; the decode path is what's under test
    );

    final stored = await s.scoreAttempt(
      attemptId: id,
      phraseId: phraseId,
      profileId: AppDatabase.defaultProfileId,
      encryptedAttemptPath: attemptPath,
      guideClipPath: guidePath,
      evaluationLabel: 1,
    );

    expect(stored, isTrue);
    final fv = await repo.getFeatureVector(id);
    expect(fv, isNotNull);
    expect(fv!.gatePassed, isTrue);
    expect(fv.contentSimilarityScore, inInclusiveRange(0.0, 1.0));
  });

  test('an unreadable clip fails softly rather than breaking the session',
      () async {
    final id = await newAttempt(1);
    final s = AttemptScoring(
      repo: repo,
      crypto: _FixedKeyCrypto(crypt.Key.fromLength(32).bytes),
      runInIsolate: false,
    );
    final stored = await s.scoreAttempt(
      attemptId: id,
      phraseId: phraseId,
      profileId: AppDatabase.defaultProfileId,
      encryptedAttemptPath: '/nonexistent/attempt.enc',
      guideClipPath: '/nonexistent/guide.enc',
      evaluationLabel: 1,
    );
    expect(stored, isFalse);
    expect(await repo.getFeatureVector(id), isNull);
  });
}

/// Hands the scorer a known key instead of one from the OS keystore.
class _FixedKeyCrypto implements AudioCrypto {
  _FixedKeyCrypto(this._bytes);
  final Uint8List _bytes;

  @override
  Future<Uint8List> keyBytes() async => _bytes;

  @override
  noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}
