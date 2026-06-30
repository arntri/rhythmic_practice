import 'dart:math' as math;

/// Direction of a smoothed metric over time. **Display-only** progress analytics
/// (caregiver/family dashboard) — deliberately simple statistics (moving average
/// + basic trend), NOT ML, and it must never feed progression or any success
/// signal.
enum Trend { improving, plateau, declining, insufficient }

/// Trailing moving average over [window] points, to damp day-to-day noise.
List<double> movingAverage(List<double> xs, int window) {
  if (window <= 1 || xs.length <= 1) return List<double>.from(xs);
  final out = <double>[];
  for (var i = 0; i < xs.length; i++) {
    final start = math.max(0, i - window + 1);
    var sum = 0.0;
    for (var j = start; j <= i; j++) {
      sum += xs[j];
    }
    out.add(sum / (i - start + 1));
  }
  return out;
}

/// Classify a time-ordered [series] (oldest → newest) as improving / plateau /
/// declining. Smooths first, then compares the later half's average to the
/// earlier half's by a **relative** [threshold] — scale-invariant, so the same
/// call works for pass rates (0–1), similarity (0–1), or latency (ms). Set
/// [higherIsBetter] false where lower is better (latency). Too few points →
/// [Trend.insufficient] (don't claim a trend from noise).
Trend classifyTrend(
  List<double> series, {
  int window = 3,
  int minPoints = 4,
  double threshold = 0.1,
  bool higherIsBetter = true,
}) {
  if (series.length < minPoints) return Trend.insufficient;
  final smoothed = movingAverage(series, window);
  final half = smoothed.length ~/ 2;
  final early = _mean(smoothed.sublist(0, half));
  final late = _mean(smoothed.sublist(half));
  final base = math.max(early.abs(), 1e-6);
  var relative = (late - early) / base;
  if (!higherIsBetter) relative = -relative;
  if (relative > threshold) return Trend.improving;
  if (relative < -threshold) return Trend.declining;
  return Trend.plateau;
}

double _mean(List<double> xs) =>
    xs.isEmpty ? 0.0 : xs.reduce((a, b) => a + b) / xs.length;
