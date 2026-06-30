// Tests the history aggregates (repository) against an in-memory DB. Offline,
// no device. (The screen itself is simple presentational glue over these
// queries; we don't widget-test it because a self-loading-from-ffi widget needs
// runAsync, which is unreliable across the shared test isolate.)

import 'package:flutter_test/flutter_test.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

import 'package:rhythmic_practice/data/app_database.dart';
import 'package:rhythmic_practice/data/practice_repository.dart';

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

  test('getPhraseStats aggregates verdicts and average sync per phrase',
      () async {
    final phraseId = (await repo.getActivePhrases()).first.phraseId;
    final sessionId = await repo.createSession(AppDatabase.defaultProfileId);

    // 3 attempts on the same phrase: Pass(0.8), Pass(0.6), Fail(1.0).
    await repo.insertAttempt(
        sessionId: sessionId, phraseId: phraseId, evaluationLabel: 1,
        tappingSynchronizationScore: 0.8);
    await repo.insertAttempt(
        sessionId: sessionId, phraseId: phraseId, evaluationLabel: 1,
        tappingSynchronizationScore: 0.6);
    await repo.insertAttempt(
        sessionId: sessionId, phraseId: phraseId, evaluationLabel: 0,
        tappingSynchronizationScore: 1.0);

    final stats = await repo.getPhraseStats();
    expect(stats.length, 1);
    final s = stats.single;
    expect(s.attempts, 3);
    expect(s.passes, 2);
    expect(s.fails, 1);
    expect(s.unsure, 0);
    expect(s.passRate, closeTo(2 / 3, 1e-9));
    expect(s.avgSyncScore, closeTo((0.8 + 0.6 + 1.0) / 3, 1e-9));
  });

  test('getSessionSummaries reports attempt + pass counts, newest first',
      () async {
    final phraseId = (await repo.getActivePhrases()).first.phraseId;
    final session = await repo.createSession(AppDatabase.defaultProfileId);
    await repo.insertAttempt(
        sessionId: session, phraseId: phraseId, evaluationLabel: 1);
    await repo.insertAttempt(
        sessionId: session, phraseId: phraseId, evaluationLabel: 2);

    final summaries = await repo.getSessionSummaries();
    expect(summaries.length, 1);
    expect(summaries.single.attempts, 2);
    expect(summaries.single.passes, 1);
  });
}
