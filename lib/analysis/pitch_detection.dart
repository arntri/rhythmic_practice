import 'dart:math' as math;
import 'dart:typed_data';

import 'audio_config.dart';

/// Result of estimating the fundamental frequency (pitch) of one window.
class PitchEstimate {
  /// Fundamental frequency in Hz. 0.0 when the window is unvoiced (aperiodic or
  /// too quiet to have a pitch).
  final double f0Hz;

  /// Peak normalized autocorrelation (0 = aperiodic/noise, ~1 = strongly
  /// periodic/voiced) — the confidence behind [f0Hz].
  final double voicing;

  const PitchEstimate(this.f0Hz, this.voicing);

  bool get isVoiced => f0Hz > 0.0;

  static const unvoiced = PitchEstimate(0.0, 0.0);
}

/// Estimate the pitch (F0) of a window of samples via **normalized
/// autocorrelation** — the same periodicity measure the syllable detector uses
/// for voicing, but here we keep the winning lag and turn it into a frequency.
///
/// A voiced (vowel-like) sound repeats its waveform every 1/F0 seconds; that
/// period shows up as a strong autocorrelation peak at the matching lag. We
/// search the human-pitch lag range (75–400 Hz), take the best lag above a
/// voicing threshold, and convert `lag → F0 = sampleRate / lag`. Unvoiced or
/// quiet windows return [PitchEstimate.unvoiced].
///
/// Pure + deterministic (no FFT, no allocation beyond locals), so it's directly
/// unit-testable on synthetic tones.
PitchEstimate estimatePitch(
  Float64List samples,
  int start,
  int n, {
  int sampleRate = AudioFormat.sampleRate,
  double voicingThreshold = 0.35,
  double minHz = 75.0,
  double maxHz = 400.0,
}) {
  if (start < 0 || n <= 0 || start + n > samples.length) {
    return PitchEstimate.unvoiced;
  }
  // Energy at lag 0 normalizes the correlation to 0..1.
  var r0 = 0.0;
  for (var i = 0; i < n; i++) {
    final v = samples[start + i];
    r0 += v * v;
  }
  if (r0 <= 1e-12) return PitchEstimate.unvoiced; // silence

  final minLag = (sampleRate / maxHz).floor();
  final maxLag = math.min((sampleRate / minHz).floor(), n - 1);
  if (maxLag <= minLag) return PitchEstimate.unvoiced;

  var bestLag = -1;
  var bestNorm = 0.0;
  for (var lag = minLag; lag <= maxLag; lag++) {
    var r = 0.0;
    for (var i = 0; i + lag < n; i++) {
      r += samples[start + i] * samples[start + i + lag];
    }
    final norm = r / r0;
    if (norm > bestNorm) {
      bestNorm = norm;
      bestLag = lag;
    }
  }

  if (bestLag < 0 || bestNorm < voicingThreshold) {
    return PitchEstimate.unvoiced;
  }
  return PitchEstimate(sampleRate / bestLag, bestNorm);
}
