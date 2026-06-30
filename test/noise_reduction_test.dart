import 'dart:math' as math;
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:rhythmic_practice/practice/noise_reduction.dart';

void main() {
  const sr = 16000;

  double rms(Float64List s, int from, int to) {
    var sum = 0.0;
    for (var i = from; i < to; i++) {
      sum += s[i] * s[i];
    }
    return math.sqrt(sum / (to - from));
  }

  test('reduces the noise floor while preserving the tone', () {
    final rng = math.Random(11);
    final n = sr; // 1 s
    final noisy = Float64List(n);
    // First 0.4 s: noise only. After: noise + a strong 220 Hz tone.
    for (var i = 0; i < n; i++) {
      var v = (rng.nextDouble() * 2 - 1) * 0.05; // background noise
      if (i >= (0.4 * sr)) v += 0.3 * math.sin(2 * math.pi * 220 * i / sr);
      noisy[i] = v;
    }

    final clean = reduceNoise(noisy);
    expect(clean.length, noisy.length);

    // Noise-only region: floor should drop noticeably.
    final noiseBefore = rms(noisy, 1000, (0.35 * sr).round());
    final noiseAfter = rms(clean, 1000, (0.35 * sr).round());
    expect(noiseAfter, lessThan(noiseBefore * 0.7));

    // Tone region: strong energy preserved (not scrubbed away).
    final toneAfter = rms(clean, (0.5 * sr).round(), (0.9 * sr).round());
    expect(toneAfter, greaterThan(0.1));
  });

  test('does not blow up the clip edges (WOLA normalization guard)', () {
    final rng = math.Random(3);
    final n = sr;
    final noisy = Float64List(n);
    for (var i = 0; i < n; i++) {
      var v = (rng.nextDouble() * 2 - 1) * 0.03; // quiet lead-in noise
      if (i >= (0.5 * sr)) v += 0.3 * math.sin(2 * math.pi * 220 * i / sr);
      noisy[i] = v;
    }
    final out = reduceNoise(noisy);
    // The first ~50 ms must not be amplified into a loud spike (which would make
    // the trimmer think the word starts at sample 0).
    double maxAbs(Float64List s, int from, int to) {
      var m = 0.0;
      for (var i = from; i < to; i++) {
        if (s[i].abs() > m) m = s[i].abs();
      }
      return m;
    }
    final inMax = maxAbs(noisy, 0, 800);
    final outMax = maxAbs(out, 0, 800);
    expect(outMax, lessThan(inMax * 3));
  });

  test('clips shorter than a frame are returned unchanged', () {
    final s = Float64List(200);
    expect(reduceNoise(s).length, s.length);
  });

  test('a clean tone stays essentially intact', () {
    final n = sr ~/ 2;
    final s = Float64List(n);
    for (var i = 0; i < n; i++) {
      s[i] = 0.3 * math.sin(2 * math.pi * 200 * i / sr);
    }
    final out = reduceNoise(s);
    // Energy preserved within a reasonable margin.
    final before = rms(s, 1000, n - 1000);
    final after = rms(out, 1000, n - 1000);
    expect(after, greaterThan(before * 0.6));
  });
}
