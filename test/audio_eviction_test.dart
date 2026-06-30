import 'dart:io';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

import 'package:rhythmic_practice/data/app_database.dart';
import 'package:rhythmic_practice/data/practice_repository.dart';
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
}
