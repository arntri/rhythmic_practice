// Integration test for the display-only progress analytics: real attempt rows
// in an in-memory database → smoothed trends.

import 'package:flutter_test/flutter_test.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

import 'package:rhythmic_practice/practice/mit_sequence.dart';
import 'package:rhythmic_practice/analytics/trend.dart';
import 'package:rhythmic_practice/data/app_database.dart';
import 'package:rhythmic_practice/data/practice_repository.dart';
import 'package:rhythmic_practice/services/progress_analytics.dart';

void main() {
  setUpAll(sqfliteFfiInit);

  late Database db;
  late PracticeRepository repo;
  late int phraseId;
  const profileId = AppDatabase.defaultProfileId;

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
    phraseId = (await repo.getActivePhrases()).first.phraseId;
  });

  tearDown(() => db.close());

  // A session with [passes] passes out of [total] judged attempts.
  Future<void> sessionWith(int passes, int total) async {
    final sid = await repo.createSession(profileId);
    for (var i = 0; i < total; i++) {
      await repo.insertAttempt(
        sessionId: sid,
        phraseId: phraseId,
        evaluationLabel: i < passes ? 1 : 0,
        stepAtAttempt: MitStep.delayedRepeat.index,
      );
    }
  }

  test('overall pass-rate trend rises as sessions improve', () async {
    // 6 sessions, pass rate climbing 0 → 1.
    await sessionWith(0, 2);
    await sessionWith(0, 2);
    await sessionWith(1, 2);
    await sessionWith(1, 2);
    await sessionWith(2, 2);
    await sessionWith(2, 2);

    final report = await ProgressAnalytics(repo).compute(profileId);
    expect(report.overallPassRate.series, [0.0, 0.0, 0.5, 0.5, 1.0, 1.0]);
    expect(report.overallPassRate.trend, Trend.improving);

    // The practiced word shows up with the same improving pass-rate trend.
    final word = report.perWord.firstWhere((w) => w.phraseId == phraseId);
    expect(word.passRate.trend, Trend.improving);
  });

  test('words with no recorded data are omitted', () async {
    await sessionWith(2, 2); // only `phraseId` gets data
    final report = await ProgressAnalytics(repo).compute(profileId);
    expect(report.perWord.length, 1);
    expect(report.perWord.single.phraseId, phraseId);
  });

  test('similarity trend reads from stored feature vectors', () async {
    // Four sessions, each one judged attempt with a rising similarity score.
    const sims = [0.40, 0.55, 0.70, 0.85];
    for (final sim in sims) {
      final sid = await repo.createSession(profileId);
      final attemptId = await repo.insertAttempt(
        sessionId: sid,
        phraseId: phraseId,
        evaluationLabel: 1,
        stepAtAttempt: MitStep.delayedRepeat.index,
      );
      await db.insert('acoustic_feature_vectors', {
        'vector_id': 'v_$sim',
        'attempt_id': attemptId,
        'content_similarity_score': sim,
        'gate_passed': 1,
        'duration_ms': 1000,
      });
    }
    final report = await ProgressAnalytics(repo).compute(profileId);
    expect(report.overallSimilarity.series, sims);
    expect(report.overallSimilarity.trend, Trend.improving);
  });
}
