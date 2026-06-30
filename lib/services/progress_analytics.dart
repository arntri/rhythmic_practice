import '../analytics/trend.dart';
import '../data/practice_repository.dart';

/// One metric's smoothed trend over time, with the raw per-session [series] it
/// came from (oldest → newest) for any sparkline display.
class MetricTrend {
  const MetricTrend(this.trend, this.series);
  final Trend trend;
  final List<double> series;
  int get sessions => series.length;
}

/// Progress for a single word: how its caregiver pass rate, acoustic similarity,
/// and response latency are trending.
class WordProgress {
  const WordProgress({
    required this.phraseId,
    required this.phraseText,
    required this.passRate,
    required this.similarity,
    required this.latency,
  });
  final int phraseId;
  final String phraseText;
  final MetricTrend passRate;
  final MetricTrend similarity;
  final MetricTrend latency;
}

/// The whole progress report — per word and overall.
class ProgressReport {
  const ProgressReport({
    required this.perWord,
    required this.overallPassRate,
    required this.overallSimilarity,
    required this.overallLatency,
  });
  final List<WordProgress> perWord;
  final MetricTrend overallPassRate;
  final MetricTrend overallSimilarity;
  final MetricTrend overallLatency;
}

/// Computes display-only progress trends from accumulated attempt data
/// (similarity, latency, pass/fail) using simple smoothed statistics.
///
/// IMPORTANT: this is **display-only**. It feeds the caregiver/family dashboard
/// (and, later, the daily-summary sync) and must NEVER influence progression —
/// it deliberately has no dependency on, and is never read by, the progression
/// controller.
class ProgressAnalytics {
  ProgressAnalytics(this._repo);

  final PracticeRepository _repo;

  // Latency trends "improve" as it gets smaller; the others as they get larger.
  MetricTrend _passTrend(List<double> s) => MetricTrend(classifyTrend(s), s);
  MetricTrend _simTrend(List<double> s) => MetricTrend(classifyTrend(s), s);
  MetricTrend _latTrend(List<double> s) =>
      MetricTrend(classifyTrend(s, higherIsBetter: false), s);

  /// Build the report for [profileId] across all the user's words.
  Future<ProgressReport> compute(String profileId) async {
    final phrases = await _repo.getAllPhrases();
    final perWord = <WordProgress>[];
    for (final p in phrases) {
      final pass = await _repo.sessionPassRates(profileId, phraseId: p.phraseId);
      final sim = await _repo.sessionSimilarity(profileId, phraseId: p.phraseId);
      final lat = await _repo.sessionLatency(profileId, phraseId: p.phraseId);
      // Skip words with no recorded data at all.
      if (pass.isEmpty && sim.isEmpty && lat.isEmpty) continue;
      perWord.add(WordProgress(
        phraseId: p.phraseId,
        phraseText: p.phraseText,
        passRate: _passTrend(pass),
        similarity: _simTrend(sim),
        latency: _latTrend(lat),
      ));
    }
    return ProgressReport(
      perWord: perWord,
      overallPassRate: _passTrend(await _repo.sessionPassRates(profileId)),
      overallSimilarity: _simTrend(await _repo.sessionSimilarity(profileId)),
      overallLatency: _latTrend(await _repo.sessionLatency(profileId)),
    );
  }
}
