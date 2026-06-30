import 'dart:math' as math;
import 'dart:typed_data';

import '../analysis/audio_config.dart';

/// Result of syllable-nucleus detection: a [count] and each nucleus' timestamp
/// ([nucleiMs], milliseconds from the start of the clip).
class SyllableDetection {
  final int count;
  final List<int> nucleiMs;
  const SyllableDetection(this.count, this.nucleiMs);
}

/// Detects syllable nuclei from a recording (therapy addendum §2). Pure +
/// deterministic, so it's unit-testable. It only PRE-FILLS a count for the
/// caregiver to confirm/adjust — never trusted blindly.
///
/// Syllable nuclei are **voiced** (vowel-like, periodic). A pure intensity
/// peak-picker over-counts because unvoiced consonants (s, t, p, k…), plosive
/// bursts, and background noise also make energy peaks. So we:
///   1. build a short-time RMS envelope (dB) and smooth it;
///   2. set the level threshold from BOTH the peak and an adaptive noise floor;
///   3. take envelope peaks above that threshold;
///   4. keep only peaks that are **voiced** (normalized autocorrelation in the
///      human-pitch lag range), then enforce an intensity dip + min time gap.
SyllableDetection detectSyllableNuclei(
  Float64List samples, {
  int sampleRate = AudioFormat.sampleRate,
  int frameSamples = 400, // 25 ms at 16 kHz
  int hopSamples = 160, // 10 ms
  double floorBelowPeakDb = 20.0, // ignore frames quieter than peak − this
  double noiseMarginDb = 8.0, // …and quieter than (noise floor + this)
  double dipDb = 4.0, // required dip between adjacent nuclei
  int minSeparationMs = 150, // ~max ~6 syllables/sec
  double minPeakDb = -45.0, // below this the clip is treated as silence
  double voicingThreshold = 0.45, // min normalized autocorrelation to be "voiced"
}) {
  if (samples.length < frameSamples) return const SyllableDetection(0, []);

  // 1. RMS envelope in dB, lightly smoothed (~50 ms).
  final hops = ((samples.length - frameSamples) ~/ hopSamples) + 1;
  final env = List<double>.filled(hops, -160.0);
  for (var h = 0; h < hops; h++) {
    final start = h * hopSamples;
    var sumSq = 0.0;
    for (var i = 0; i < frameSamples; i++) {
      final v = samples[start + i];
      sumSq += v * v;
    }
    final rms = math.sqrt(sumSq / frameSamples);
    env[h] = 20.0 * (math.log(rms + 1e-10) / math.ln10);
  }
  final sm = _movingAverage(env, 5);

  final maxDb = sm.reduce(math.max);
  if (maxDb < minPeakDb) return const SyllableDetection(0, []); // silence

  // 2. Threshold from the peak AND an adaptive noise floor (10th percentile).
  final sorted = [...sm]..sort();
  final noiseFloor = sorted[(sorted.length * 0.10).floor().clamp(0, sorted.length - 1)];
  final threshold =
      math.max(maxDb - floorBelowPeakDb, noiseFloor + noiseMarginDb);

  // 3. Candidate local maxima above the threshold.
  final candidates = <int>[];
  for (var h = 1; h < hops - 1; h++) {
    if (sm[h] >= threshold && sm[h] >= sm[h - 1] && sm[h] > sm[h + 1]) {
      candidates.add(h);
    }
  }
  if (candidates.isEmpty) candidates.add(sm.indexOf(maxDb));

  // 4. Voicing gate: keep only periodic (vowel-like) peaks.
  final minLag = (sampleRate / 400).floor(); // 400 Hz (high pitch)
  final maxLag = (sampleRate / 75).floor(); // 75 Hz (low pitch)
  final voiced = <int>[];
  for (final h in candidates) {
    final start = h * hopSamples;
    if (_voicing(samples, start, frameSamples, minLag, maxLag) >=
        voicingThreshold) {
      voiced.add(h);
    }
  }
  if (voiced.isEmpty) return const SyllableDetection(0, []);

  // 5. Accept peaks separated by an intensity dip + a minimum time gap.
  final minSepFrames =
      (minSeparationMs * sampleRate / 1000 / hopSamples).round();
  final accepted = <int>[];
  for (final h in voiced) {
    if (accepted.isEmpty) {
      accepted.add(h);
      continue;
    }
    final last = accepted.last;
    var valley = double.infinity;
    for (var k = last; k <= h; k++) {
      if (sm[k] < valley) valley = sm[k];
    }
    final lower = math.min(sm[last], sm[h]);
    if ((h - last) >= minSepFrames && (lower - valley) >= dipDb) {
      accepted.add(h);
    } else if (sm[h] > sm[last]) {
      accepted[accepted.length - 1] = h; // same syllable — keep the louder peak
    }
  }

  final nucleiMs = [
    for (final h in accepted)
      (((h * hopSamples) + frameSamples ~/ 2) * 1000 / sampleRate).round(),
  ];
  return SyllableDetection(nucleiMs.length, nucleiMs);
}

List<double> _movingAverage(List<double> x, int window) {
  final half = window ~/ 2;
  final out = List<double>.filled(x.length, 0);
  for (var i = 0; i < x.length; i++) {
    var sum = 0.0;
    var c = 0;
    for (var k = i - half; k <= i + half; k++) {
      if (k >= 0 && k < x.length) {
        sum += x[k];
        c++;
      }
    }
    out[i] = sum / c;
  }
  return out;
}

/// Voicing strength of one frame: the max normalized autocorrelation over the
/// human-pitch lag range (0 = aperiodic/noise, ~1 = strongly periodic/voiced).
double _voicing(Float64List x, int start, int n, int minLag, int maxLag) {
  var r0 = 0.0;
  for (var i = 0; i < n; i++) {
    final v = x[start + i];
    r0 += v * v;
  }
  if (r0 <= 1e-12) return 0.0;
  var best = 0.0;
  final hi = math.min(maxLag, n - 1);
  for (var lag = minLag; lag <= hi; lag++) {
    var r = 0.0;
    for (var i = 0; i + lag < n; i++) {
      r += x[start + i] * x[start + i + lag];
    }
    final norm = r / r0;
    if (norm > best) best = norm;
  }
  return best;
}
