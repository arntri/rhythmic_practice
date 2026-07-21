import 'dart:math' as math;

import '../data/models.dart';

/// Unsupervised, within-session **fatigue signal** (audit item 17).
///
/// This is deliberately NOT a trained model and it **never gates progression** —
/// it is an advisory signal for the caregiver dashboard (item 20) so a tired
/// session can be spotted and shortened. Because it is unsupervised (a
/// drift-over-time heuristic, no labels) it can be *computed for real* today
/// without any training data.
///
/// It reads only **motor-timing and vocal-timing regularity**:
///  - inter-tap-interval (ITI) variability — taps get more erratic when tired,
///  - tap **dwell** variability — press durations drift/scatter,
///  - **onset-vs-onset steadiness** of the voice (from the patient's detected
///    syllable onsets) — spacing gets less even.
///
/// It intentionally AVOIDS touch-area / `getSize()`: that signal is device- and
/// grip-dependent, unreliable for a one-handed post-stroke user, and not worth
/// the fragility. The detector compares the session's **late** window to its
/// **early** window; fatigue shows as rising variability. A session that is
/// erratic *throughout* (a baseline motor pattern, not fatigue) reads low,
/// because only the drift counts.
class FatigueDetector {
  const FatigueDetector({
    this.fatigueThreshold = 0.5,
    this.minSamplesPerWindow = 4,
    this.driftScale = 0.3,
  });

  /// Score at/above which [FatigueEstimate.isFatigued] is set.
  final double fatigueThreshold;

  /// Minimum samples (ITIs / dwells / onset-intervals) needed in EACH of the
  /// early and late windows for a component to count; below this the whole
  /// estimate is flagged low-confidence.
  final int minSamplesPerWindow;

  /// The drift (late CoV − early CoV) that maps to a full 1.0 on a component.
  final double driftScale;

  /// Estimate fatigue for one session. [taps] is the session's raw tap stream
  /// (any order — grouped by attempt and sorted internally). [onsetsPerAttempt]
  /// is the patient's detected syllable onsets per scored attempt, in session
  /// order (from `acoustic_feature_vectors.onset_ms`); pass `const []` when none.
  FatigueEstimate estimate({
    required List<StoredTapEvent> taps,
    List<List<int>> onsetsPerAttempt = const [],
  }) {
    // Group taps by attempt (ITIs must not span the gap between attempts) and
    // order each group by touch-down time.
    final byAttempt = <String, List<StoredTapEvent>>{};
    for (final t in taps) {
      byAttempt.putIfAbsent(t.attemptId, () => []).add(t);
    }
    // Attempts in session order (earliest first tap first).
    final attempts = byAttempt.values.toList()
      ..sort((a, b) => a
          .map((t) => t.downMs)
          .reduce(math.min)
          .compareTo(b.map((t) => t.downMs).reduce(math.min)));
    for (final g in attempts) {
      g.sort((a, b) => a.downMs.compareTo(b.downMs));
    }

    // Flatten interval samples in session order, so the early/late split is
    // chronological.
    final itis = <double>[];
    final dwells = <double>[];
    for (final g in attempts) {
      for (var i = 1; i < g.length; i++) {
        itis.add((g[i].downMs - g[i - 1].downMs).toDouble());
      }
      for (final t in g) {
        if (t.dwellMs != null) dwells.add(t.dwellMs!.toDouble());
      }
    }
    final onsetIntervals = <double>[];
    for (final onsets in onsetsPerAttempt) {
      final sorted = [...onsets]..sort();
      for (var i = 1; i < sorted.length; i++) {
        onsetIntervals.add((sorted[i] - sorted[i - 1]).toDouble());
      }
    }

    final iti = _driftComponent(itis);
    final dwell = _driftComponent(dwells);
    final steadiness = _driftComponent(onsetIntervals);

    // Weight the components that actually have data; renormalize over the rest.
    const weights = {'iti': 0.4, 'dwell': 0.3, 'steadiness': 0.3};
    final parts = <String, double?>{
      'iti': iti,
      'dwell': dwell,
      'steadiness': steadiness,
    };
    var weightSum = 0.0;
    var acc = 0.0;
    parts.forEach((k, v) {
      if (v != null) {
        weightSum += weights[k]!;
        acc += weights[k]! * v;
      }
    });
    final score = weightSum == 0 ? 0.0 : (acc / weightSum);

    final lowConfidence = weightSum == 0;
    return FatigueEstimate(
      score: score,
      isFatigued: !lowConfidence && score >= fatigueThreshold,
      itiDrift: iti,
      dwellDrift: dwell,
      steadinessDrift: steadiness,
      sampleCount: itis.length + dwells.length + onsetIntervals.length,
      lowConfidence: lowConfidence,
    );
  }

  /// One component's normalized drift in [0, 1], or null when either window has
  /// too few samples to be meaningful. Splits [samples] in half (early vs late),
  /// takes each half's coefficient of variation, and maps the RISE in scatter
  /// (late − early) through [driftScale]. A fall in scatter (improvement) → 0.
  double? _driftComponent(List<double> samples) {
    if (samples.length < 2 * minSamplesPerWindow) return null;
    final mid = samples.length ~/ 2;
    final early = samples.sublist(0, mid);
    final late = samples.sublist(samples.length - mid);
    final drift = _coefficientOfVariation(late) - _coefficientOfVariation(early);
    return (drift / driftScale).clamp(0.0, 1.0);
  }

  static double _coefficientOfVariation(List<double> xs) {
    if (xs.isEmpty) return 0;
    final mean = xs.reduce((a, b) => a + b) / xs.length;
    if (mean == 0) return 0;
    final variance =
        xs.map((x) => (x - mean) * (x - mean)).reduce((a, b) => a + b) /
            xs.length;
    return math.sqrt(variance) / mean;
  }
}

/// The advisory output of [FatigueDetector]. Sub-scores are exposed so the
/// dashboard can explain *why* (which channel drifted), and [lowConfidence]
/// guards against over-reading a tiny session.
class FatigueEstimate {
  const FatigueEstimate({
    required this.score,
    required this.isFatigued,
    required this.itiDrift,
    required this.dwellDrift,
    required this.steadinessDrift,
    required this.sampleCount,
    required this.lowConfidence,
  });

  /// 0..1 — higher means more evidence of within-session fatigue.
  final double score;

  /// [score] ≥ threshold (and enough data). Advisory only.
  final bool isFatigued;

  /// Per-channel normalized drift (0..1), or null if that channel had no data.
  final double? itiDrift;
  final double? dwellDrift;
  final double? steadinessDrift;

  /// Total interval samples considered (taps + dwells + onset intervals).
  final int sampleCount;

  /// Too little data in one or both windows to say anything — treat [score] as
  /// unknown, not "no fatigue".
  final bool lowConfidence;

  static const FatigueEstimate unknown = FatigueEstimate(
    score: 0,
    isFatigued: false,
    itiDrift: null,
    dwellDrift: null,
    steadinessDrift: null,
    sampleCount: 0,
    lowConfidence: true,
  );
}
