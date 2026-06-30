// Shape, determinism and sanity tests for the MFCC extractor (Phase 2A step 2).
//
// No fixtures needed: we synthesize samples (silence, sine tones) in code, so
// the math is checkable by hand. Exact-value acceptance (word discrimination)
// comes later in step 5 with the human's recorded fixtures.

import 'dart:math' as math;
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:rhythmic_practice/analysis/audio_config.dart';
import 'package:rhythmic_practice/analysis/mfcc.dart';

/// A pure sine tone at [freq] Hz, [n] samples long, amplitude 0.5, at the
/// project sample rate. Deterministic — no randomness.
Float64List sine(double freq, int n, {double amp = 0.5}) {
  final s = Float64List(n);
  for (var i = 0; i < n; i++) {
    s[i] = amp * math.sin(2 * math.pi * freq * i / AudioFormat.sampleRate);
  }
  return s;
}

/// Total absolute difference between two equally-shaped MFCC sequences.
double totalAbsDiff(List<Float64List> a, List<Float64List> b) {
  var sum = 0.0;
  for (var f = 0; f < a.length; f++) {
    for (var c = 0; c < a[f].length; c++) {
      sum += (a[f][c] - b[f][c]).abs();
    }
  }
  return sum;
}

void main() {
  final mfcc = Mfcc();

  group('frameCount', () {
    test('matches the documented formula', () {
      expect(Mfcc.frameCount(0), 0);
      expect(Mfcc.frameCount(200), 1); // shorter than one frame -> padded to 1
      expect(Mfcc.frameCount(400), 1); // exactly one frame
      expect(Mfcc.frameCount(560), 2); // one extra hop
      expect(Mfcc.frameCount(1600), 9); // 1 + ceil(1200/160)
      expect(Mfcc.frameCount(8000), 49); // 1 + ceil(7600/160)
    });
  });

  group('extract — shape', () {
    test('returns frameCount frames of coeffCount coefficients', () {
      for (final n in [400, 560, 1600, 8000]) {
        final frames = mfcc.extract(sine(440, n));
        expect(frames.length, Mfcc.frameCount(n), reason: 'len=$n frame count');
        for (final frame in frames) {
          expect(frame.length, MfccConfig.coeffCount);
        }
      }
    });

    test('empty input gives no frames', () {
      expect(mfcc.extract(Float64List(0)), isEmpty);
    });
  });

  group('extract — determinism', () {
    test('identical samples produce byte-identical coefficients', () {
      final a = mfcc.extract(sine(440, 4000));
      final b = mfcc.extract(sine(440, 4000));
      expect(a.length, b.length);
      expect(totalAbsDiff(a, b), 0.0);
    });

    test('a second Mfcc instance gives the same numbers', () {
      final other = Mfcc();
      final a = mfcc.extract(sine(440, 4000));
      final b = other.extract(sine(440, 4000));
      expect(totalAbsDiff(a, b), 0.0);
    });
  });

  group('extract — sanity properties', () {
    test('silence: c1..c12 are ~0 (DCT of a constant log-mel spectrum)', () {
      // All-zero audio -> every mel band has the same floored energy -> the
      // log-mel vector is constant -> DCT-II zeroes every coefficient but c0.
      final frames = mfcc.extract(Float64List(400)); // one frame of silence
      expect(frames.length, 1);
      final coeffs = frames.first;
      expect(coeffs[0].abs(), greaterThan(1.0)); // c0 carries the (constant) level
      for (var c = 1; c < coeffs.length; c++) {
        expect(coeffs[c].abs(), lessThan(1e-9), reason: 'c$c should be ~0');
      }
    });

    test('different pitches give clearly different MFCCs', () {
      final low = mfcc.extract(sine(300, 8000));
      final high = mfcc.extract(sine(3000, 8000));
      // Same shape, but the spectral fingerprints must diverge substantially.
      expect(low.length, high.length);
      expect(totalAbsDiff(low, high), greaterThan(10.0));
    });

    test('same pitch is identical to itself (sensitivity is not noise)', () {
      final a = mfcc.extract(sine(300, 8000));
      final b = mfcc.extract(sine(300, 8000));
      expect(totalAbsDiff(a, b), 0.0);
    });
  });
}
