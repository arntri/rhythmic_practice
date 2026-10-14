import 'dart:io';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

import 'package:rhythmic_practice/practice/mit_sequence.dart';
import 'package:rhythmic_practice/data/app_database.dart';
import 'package:rhythmic_practice/data/practice_repository.dart';
import 'package:rhythmic_practice/practice/practice_controller.dart';
import 'package:rhythmic_practice/services/audio_eviction.dart';

void main() {
  setUpAll(sqfliteFfiInit);

  late Database db;
  late PracticeRepository repo;
  late Directory tmp;

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
    tmp = await Directory.systemTemp.createTemp('evict_test');
  });

  tearDown(() async {
    await db.close();
    if (tmp.existsSync()) await tmp.delete(recursive: true);
  });

  // Inserts an attempt row with an explicit timestamp + audio file path.
  Future<File> seedAttemptWithAudio({
    required String sessionId,
    required int phraseId,
    required String name,
    required String timestampUtc,
  }) async {
    final file = File('${tmp.path}/$name.enc');
    await file.writeAsString('fake audio');
    await db.insert('exercise_attempts', {
      'attempt_id': name,
      'session_id': sessionId,
      'phrase_id': phraseId,
      'timestamp': timestampUtc,
      'evaluation_label': 1,
      'local_encrypted_audio_path': file.path,
    });
    return file;
  }

  test('evicts audio older than 48h, keeps the row, leaves recent audio', () async {
    final phraseId = (await repo.getActivePhrases()).first.phraseId;
    final sessionId = await repo.createSession(AppDatabase.defaultProfileId);

    // "now" is 2020-01-03 00:00:00 UTC -> cutoff is 2020-01-01 00:00:00.
    final now = DateTime.utc(2020, 1, 3);
    final oldFile = await seedAttemptWithAudio(
      sessionId: sessionId,
      phraseId: phraseId,
      name: 'old',
      timestampUtc: '2019-12-30 12:00:00', // > 48h ago
    );
    final recentFile = await seedAttemptWithAudio(
      sessionId: sessionId,
      phraseId: phraseId,
      name: 'recent',
      timestampUtc: '2020-01-02 18:00:00', // < 48h ago
    );

    final service = AudioEvictionService(repo);
    final evicted = await service.evictExpired(now: now);

    expect(evicted, 1);
    // Old: file gone, path nulled, but the row + its score/label remain.
    expect(oldFile.existsSync(), isFalse);
    final attempts = await repo.getAttemptsForSession(sessionId);
    final old = attempts.firstWhere((a) => a.attemptId == 'old');
    expect(old.localEncryptedAudioPath, isNull);
    expect(old.evaluationLabel, 1);
    // Recent: untouched.
    expect(recentFile.existsSync(), isTrue);
    final recent = attempts.firstWhere((a) => a.attemptId == 'recent');
    expect(recent.localEncryptedAudioPath, isNotNull);
  });

  test('eviction never deletes guide clips — starter guides survive (Part 3)',
      () async {
    // The 48h eviction forgets patient ATTEMPT audio only. A starter word's
    // bundled guide lives in practice_phrases.guide_clip_path (like any recorded
    // guide) and must never be collateral — starters stay usable forever.
    final starter = (await db.query('practice_phrases',
            where: 'is_starter = 1', limit: 1))
        .first;
    final starterId = starter['phrase_id'] as int;
    final guideFile = File('${tmp.path}/starter_guide.enc');
    await guideFile.writeAsString('encrypted starter guide');
    await repo.attachGuideClipPath(starterId, guideFile.path);

    // An old attempt (with audio) that IS eligible for eviction.
    final sessionId = await repo.createSession(AppDatabase.defaultProfileId);
    final attemptFile = await seedAttemptWithAudio(
      sessionId: sessionId,
      phraseId: starterId,
      name: 'old-attempt',
      timestampUtc: '2019-12-30 12:00:00', // > 48h ago
    );

    final evicted =
        await AudioEvictionService(repo).evictExpired(now: DateTime.utc(2020, 1, 3));

    // The attempt audio was wiped...
    expect(evicted, 1);
    expect(attemptFile.existsSync(), isFalse);
    // ...but the starter's guide clip (file + DB pointer) is fully intact.
    expect(guideFile.existsSync(), isTrue);
    final refreshed = (await db.query('practice_phrases',
            where: 'phrase_id = ?', whereArgs: [starterId]))
        .single;
    expect(refreshed['guide_clip_path'], guideFile.path);
  });

  test('a missing file does not stop the path from being cleared', () async {
    final phraseId = (await repo.getActivePhrases()).first.phraseId;
    final sessionId = await repo.createSession(AppDatabase.defaultProfileId);
    final file = await seedAttemptWithAudio(
      sessionId: sessionId,
      phraseId: phraseId,
      name: 'gone',
      timestampUtc: '2019-01-01 00:00:00',
    );
    await file.delete(); // file already gone before eviction runs

    final service = AudioEvictionService(repo);
    final evicted = await service.evictExpired(now: DateTime.utc(2020, 1, 1));

    expect(evicted, 1);
    final attempts = await repo.getAttemptsForSession(sessionId);
    expect(attempts.single.localEncryptedAudioPath, isNull);
  });

  test('eviction never touches anchor templates (derived features stay)',
      () async {
    // Brief §4.3 / §7: eviction deletes raw audio only. Anchors are derived
    // MFCC features and must survive even when the source attempt's audio is
    // wiped.
    final phraseId = (await repo.getActivePhrases()).first.phraseId;
    final sessionId = await repo.createSession(AppDatabase.defaultProfileId);

    // An old attempt with audio, promoted to an anchor.
    final oldFile = await seedAttemptWithAudio(
      sessionId: sessionId,
      phraseId: phraseId,
      name: 'anchored',
      timestampUtc: '2019-12-30 12:00:00', // > 48h ago
    );
    final mfcc = [Float64List.fromList([1, 2, 3, 4])];
    await repo.considerAnchor(
      profileId: AppDatabase.defaultProfileId,
      phraseId: phraseId,
      sourceAttemptId: 'anchored',
      mfcc: mfcc,
      scoreVsReference: 0.7,
    );

    final service = AudioEvictionService(repo);
    final evicted = await service.evictExpired(now: DateTime.utc(2020, 1, 3));

    // Audio gone...
    expect(evicted, 1);
    expect(oldFile.existsSync(), isFalse);
    // ...but the anchor (and its decoded MFCC) is fully intact.
    final anchor =
        await repo.getAnchor(AppDatabase.defaultProfileId, phraseId);
    expect(anchor, isNotNull);
    expect(anchor!.scoreVsReference, closeTo(0.7, 1e-9));
    expect(anchor.mfcc.single, orderedEquals([1.0, 2.0, 3.0, 4.0]));
  });

  test('eviction keeps derived per-attempt data — feature vector + taps (item 23)',
      () async {
    // The 48h eviction must forget ONLY the raw audio. The onset stream and the
    // raw tap stream are derived, non-audio features kept for later ML; they must
    // survive even after the source clip is wiped.
    final phraseId = (await repo.getActivePhrases()).first.phraseId;
    final sessionId = await repo.createSession(AppDatabase.defaultProfileId);

    final oldFile = await seedAttemptWithAudio(
      sessionId: sessionId,
      phraseId: phraseId,
      name: 'derived',
      timestampUtc: '2019-12-30 12:00:00', // > 48h ago
    );

    // A derived feature vector with the patient's detected onsets...
    await db.insert('acoustic_feature_vectors', {
      'vector_id': 'v-derived',
      'attempt_id': 'derived',
      'content_similarity_score': 0.82,
      'mfcc_distance': 0.4,
      'gate_passed': 1,
      'gate_reason': 'ok',
      'duration_ms': 900,
      'onset_ms': '0,410,820',
    });
    // ...and the raw tap stream.
    await repo.insertTapEvents(
      attemptId: 'derived',
      phraseId: phraseId,
      sessionId: sessionId,
      step: MitStep.immediateRepeat,
      taps: [
        TapEvent(downMs: 100, phase: 0.0, dwellMs: 80),
        TapEvent(downMs: 620, phase: 0.3, dwellMs: 75),
      ],
    );

    final service = AudioEvictionService(repo);
    final evicted = await service.evictExpired(now: DateTime.utc(2020, 1, 3));

    // Audio gone + path nulled...
    expect(evicted, 1);
    expect(oldFile.existsSync(), isFalse);
    final attempt = (await repo.getAttemptsForSession(sessionId)).single;
    expect(attempt.localEncryptedAudioPath, isNull);

    // ...but the derived data is fully intact.
    final fv = await repo.getFeatureVector('derived');
    expect(fv, isNotNull);
    expect(fv!.contentSimilarityScore, closeTo(0.82, 1e-9));
    expect(fv.onsetMs, orderedEquals([0, 410, 820]));
    final taps = await repo.getTapEvents('derived');
    expect(taps, hasLength(2));
    expect(taps.map((t) => t.downMs), orderedEquals([100, 620]));
  });
}
