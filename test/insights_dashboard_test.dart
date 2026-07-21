import 'package:flutter_test/flutter_test.dart';
import 'package:rhythmic_practice/data/app_database.dart';
import 'package:rhythmic_practice/data/practice_repository.dart';
import 'package:rhythmic_practice/ml/insights_dashboard.dart';
import 'package:rhythmic_practice/ml/solo_mode.dart';
import 'package:rhythmic_practice/practice/practice_controller.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

void main() {
  setUpAll(sqfliteFfiInit);

  late PracticeRepository repo;

  setUp(() async {
    final db = await databaseFactoryFfi.openDatabase(
      inMemoryDatabasePath,
      options: OpenDatabaseOptions(
        version: 1,
        onConfigure: (db) => db.execute('PRAGMA foreign_keys = ON'),
        onCreate: (db, v) => AppDatabase.applyInitialSchema(db),
      ),
    );
    repo = PracticeRepository.withDatabase(db);
  });

  test('assembles fatigue, an untrusted classifier, and a solo count', () async {
    final phrases = await repo.getActivePhrases();
    final phraseId = phrases.first.phraseId;
    final sessionId = await repo.createSession(AppDatabase.defaultProfileId);

    // Two attempts with tap streams so the fatigue detector has data.
    for (var a = 0; a < 2; a++) {
      final attemptId = await repo.insertAttempt(
        sessionId: sessionId,
        phraseId: phraseId,
        evaluationLabel: 1,
        rungAtAttempt: 4,
      );
      await repo.insertTapEvents(
        attemptId: attemptId,
        phraseId: phraseId,
        sessionId: sessionId,
        rung: 4,
        taps: [
          for (var i = 0; i < 5; i++)
            TapEvent(downMs: a * 5000 + i * 500, phase: 0.0, dwellMs: 90),
        ],
      );
    }

    // The daily rollup is refreshed per attempt in the app; do it here too.
    await repo.touchDailySummaryForToday(AppDatabase.defaultProfileId);

    final insights =
        await InsightsService(repo).load(AppDatabase.defaultProfileId);

    // Fatigue computed for the session.
    expect(insights.sessionFatigue, hasLength(1));
    expect(insights.sessionFatigue.first.sessionId, sessionId);

    // Layer C is untrained → never trusted, never gates.
    expect(insights.graduation.graduated, isFalse);
    expect(insights.mlGates, isFalse);
    expect(insights.soloAuthority, SoloAuthority.advisoryOnly);

    // Nothing is mastered yet → no solo-ready words.
    expect(insights.soloEligibleCount, 0);

    // Daily trend reflects the recorded attempts.
    expect(insights.dailyTrend, isNotEmpty);
  });

  test('solo_mode_enabled round-trips through the profile', () async {
    var profile = await repo.getProfile();
    expect(profile.soloModeEnabled, isFalse); // default off

    await repo.updateProfile(soloModeEnabled: true);
    profile = await repo.getProfile();
    expect(profile.soloModeEnabled, isTrue);
  });
}
