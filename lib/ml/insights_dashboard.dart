import '../data/models.dart';
import '../data/practice_repository.dart';
import 'fatigue_detector.dart';
import 'graduation_gate.dart';
import 'solo_mode.dart';

/// Assembles the **ML insights dashboard** (audit item 20) from logged data.
///
/// Everything here is display-only and advisory. The dashboard exists so a
/// caregiver can *see* what the ML scaffolding is doing — the within-session
/// fatigue signal, the day-by-day pass-rate trend, how far the Layer C
/// classifier is from being trustworthy, and how many words are solo-ready —
/// without any of it touching progression. Its honest headline today is "the
/// model is not trusted yet; you're still in charge."
class InsightsService {
  InsightsService(this._repo, {this.fatigueDetector = const FatigueDetector()});

  final PracticeRepository _repo;
  final FatigueDetector fatigueDetector;

  static const _gate = GraduationGate();
  static const _scope = SoloScope();

  /// Load the dashboard for [profileId]. [recentSessions] bounds how many recent
  /// sessions get a fatigue estimate; [recentDays] bounds the daily trend.
  Future<MlInsights> load(
    String profileId, {
    int recentSessions = 5,
    int recentDays = 14,
  }) async {
    final days = await _repo.getDailySummaries(profileId, limit: recentDays);

    // Per-session fatigue over the most recent sessions.
    final sessions = await _repo.getSessionSummaries(limit: recentSessions);
    final fatigue = <SessionFatigue>[];
    for (final s in sessions) {
      final taps = await _repo.getTapEventsForSession(s.sessionId);
      final attempts = await _repo.getAttemptsForSession(s.sessionId);
      final onsets = <List<int>>[];
      for (final a in attempts) {
        final v = await _repo.getFeatureVector(a.attemptId);
        if (v != null && v.onsetMs.isNotEmpty) onsets.add(v.onsetMs);
      }
      final est =
          fatigueDetector.estimate(taps: taps, onsetsPerAttempt: onsets);
      fatigue.add(SessionFatigue(
        sessionId: s.sessionId,
        startedAt: s.startedAt,
        estimate: est,
      ));
    }

    // Layer C graduation: the model abstains (untrained), so there are no scored
    // Pass predictions — the gate reports exactly why it isn't trusted yet.
    final graduation = _gate.evaluate(const <LabeledPrediction>[]);

    // Scoped solo readiness: which mastered words currently qualify.
    final phrases = await _repo.getActivePhrases();
    final passRate = <int, double>{};
    final sessionCount = <int, int>{};
    for (final p in phrases) {
      // Mastery is read at MIT's most independent step, not from a stored rung —
      // a word has no resting rung to inspect any more.
      final rates = await _repo.sessionPassRates(profileId,
          phraseId: p.phraseId, step: SoloScope.soloStep);
      if (rates.isNotEmpty) {
        passRate[p.phraseId] =
            rates.reduce((a, b) => a + b) / rates.length;
        sessionCount[p.phraseId] = rates.length;
      }
    }
    final eligible = _scope.eligiblePhrases(
      recentPassRateByPhrase: passRate,
      recentSessionsByPhrase: sessionCount,
    );

    return MlInsights(
      dailyTrend: days,
      sessionFatigue: fatigue,
      graduation: graduation,
      soloEligibleCount: eligible.length,
      soloAuthority: _scope.authorityFor(layerCGraduated: graduation.graduated),
    );
  }
}

/// The assembled, display-only dashboard payload.
class MlInsights {
  const MlInsights({
    required this.dailyTrend,
    required this.sessionFatigue,
    required this.graduation,
    required this.soloEligibleCount,
    required this.soloAuthority,
  });

  /// Newest-first daily rollups for the pass-rate trend.
  final List<DailySummary> dailyTrend;

  /// Fatigue estimate per recent session (most recent first).
  final List<SessionFatigue> sessionFatigue;

  /// How close Layer C is to being trusted (never gates until [GraduationStatus
  /// .graduated] — false today).
  final GraduationStatus graduation;

  /// How many active words are currently solo-ready.
  final int soloEligibleCount;

  /// What solo mode is allowed to do (advisory-only until Layer C graduates).
  final SoloAuthority soloAuthority;

  /// The plain-language headline for the caregiver: the model is not in charge.
  bool get mlGates => graduation.graduated; // always false today
}

/// One session's fatigue estimate for the dashboard trend.
class SessionFatigue {
  const SessionFatigue({
    required this.sessionId,
    required this.startedAt,
    required this.estimate,
  });

  final String sessionId;
  final String startedAt;
  final FatigueEstimate estimate;
}
