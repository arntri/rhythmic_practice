import 'dart:math' as math;
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:rhythmic_practice/practice/time_stretch.dart';

// Estimate the dominant period (in samples) of a roughly-periodic signal via
// autocorrelation. We use this to assert that time-stretching preserves PITCH:
// a 200 Hz tone must still be 200 Hz after being slowed down.
int _dominantPeriod(Float64List x, {int minLag = 20, int maxLag = 400}) {
  var bestLag = minLag;
  var best = -double.infinity;
  for (var lag = minLag; lag <= maxLag; lag++) {
    var c = 0.0;
    for (var i = 0; i + lag < x.length; i++) {
      c += x[i] * x[i + lag];
    }
    if (c > best) {
      best = c;
      bestLag = lag;
    }
  }
  return bestLag;
}

Float64List _sine(double freq, int samples, {int sr = 16000}) {
  final out = Float64List(samples);
  for (var i = 0; i < samples; i++) {
    out[i] = math.sin(2 * math.pi * freq * i / sr);
  }
  return out;
}

void main() {
  group('timeStretch', () {
    test('output length scales by the factor', () {
      final x = _sine(200, 16000); // 1 s
      final y = timeStretch(x, 1.5);
      // Allow a small tolerance for windowing/rounding at the edges.
      expect(y.length, closeTo(24000, 800));
    });

    test('preserves pitch (period unchanged) when slowed', () {
      final x = _sine(200, 16000); // period = 16000/200 = 80 samples
      final y = timeStretch(x, 1.6);
      final px = _dominantPeriod(x);
      final py = _dominantPeriod(y);
      expect(px, closeTo(80, 3));
      // A naive playback-rate slowdown would lengthen the period (~128); WSOLA
      // must keep it near 80.
      expect(py, closeTo(80, 4));
    });

    test('near-unity factor returns the input unchanged', () {
      final x = _sine(200, 16000);
      final y = timeStretch(x, 1.0);
      expect(y.length, x.length);
    });

    test('clips too short to window are passed through', () {
      final x = _sine(200, 100);
      final y = timeStretch(x, 1.6);
      expect(y.length, x.length);
    });

    test('does not blow up the amplitude', () {
      final x = _sine(200, 16000);
      final y = timeStretch(x, 1.6);
      var peak = 0.0;
      for (final v in y) {
        peak = math.max(peak, v.abs());
      }
      expect(peak, lessThan(1.2)); // OLA normalization keeps it near unity
    });
  });
}
