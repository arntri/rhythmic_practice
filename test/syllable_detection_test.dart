import 'dart:math' as math;
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:rhythmic_practice/practice/syllable_detection.dart';

void main() {
  const sr = 16000;

  /// Builds a signal of [totalMs] with a 200 Hz tone burst (amp 0.5) over each
  /// [bursts] window [startMs, startMs+durMs); everything else is silence.
  Float64List bursts(int totalMs, List<(int, int)> windows) {
    final n = (totalMs * sr / 1000).round();
    final s = Float64List(n);
    for (final (startMs, durMs) in windows) {
      final from = (startMs * sr / 1000).round();
      final to = ((startMs + durMs) * sr / 1000).round();
      for (var i = from; i < to && i < n; i++) {
        s[i] = 0.5 * math.sin(2 * math.pi * 200 * i / sr);
      }
    }
    return s;
  }

  test('three well-separated bursts → 3 nuclei near the burst centers', () {
    final s = bursts(1200, [(0, 200), (400, 200), (800, 200)]);
    final d = detectSyllableNuclei(s);
    expect(d.count, 3);
    expect(d.nucleiMs.length, 3);
    // Nuclei land within ~120 ms of each burst's center (100/500/900 ms).
    expect((d.nucleiMs[0] - 100).abs(), lessThan(120));
    expect((d.nucleiMs[1] - 500).abs(), lessThan(120));
    expect((d.nucleiMs[2] - 900).abs(), lessThan(120));
  });

  test('one long stretched burst → a single nucleus', () {
    final s = bursts(800, [(100, 600)]);
    expect(detectSyllableNuclei(s).count, 1);
  });

  test('silence → no nuclei', () {
    final s = Float64List((1000 * sr / 1000).round()); // all zeros
    expect(detectSyllableNuclei(s).count, 0);
  });

  test('two syllables → 2 nuclei (water-like)', () {
    final s = bursts(700, [(50, 220), (380, 250)]);
    expect(detectSyllableNuclei(s).count, 2);
  });

  test('a clip shorter than one frame → 0', () {
    expect(detectSyllableNuclei(Float64List(100)).count, 0);
  });

  /// Fills [windows] with band-unlimited white noise (aperiodic = unvoiced),
  /// e.g. a fricative/plosive burst or background noise.
  Float64List noiseBursts(int totalMs, List<(int, int)> windows) {
    final rng = math.Random(7); // deterministic
    final n = (totalMs * sr / 1000).round();
    final s = Float64List(n);
    for (final (startMs, durMs) in windows) {
      final from = (startMs * sr / 1000).round();
      final to = ((startMs + durMs) * sr / 1000).round();
      for (var i = from; i < to && i < n; i++) {
        s[i] = (rng.nextDouble() * 2 - 1) * 0.5;
      }
    }
    return s;
  }

  test('unvoiced noise burst alone → 0 nuclei (voicing gate rejects it)', () {
    expect(detectSyllableNuclei(noiseBursts(600, [(100, 300)])).count, 0);
  });

  test('one voiced syllable + an equally loud noise burst → 1 (only the vowel)',
      () {
    // Voiced tone, then silence, then a loud noise burst (like a trailing "ssss").
    final s = bursts(900, [(50, 250)]);
    final noise = noiseBursts(900, [(550, 250)]);
    for (var i = 0; i < s.length; i++) {
      s[i] += noise[i];
    }
    expect(detectSyllableNuclei(s).count, 1);
  });
}
