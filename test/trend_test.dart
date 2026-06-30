import 'package:flutter_test/flutter_test.dart';
import 'package:rhythmic_practice/analytics/trend.dart';

void main() {
  group('classifyTrend', () {
    test('a clear upward series is improving', () {
      expect(classifyTrend([0.2, 0.3, 0.4, 0.6, 0.7, 0.85]), Trend.improving);
    });

    test('a clear downward series is declining', () {
      expect(classifyTrend([0.85, 0.7, 0.6, 0.4, 0.3, 0.2]), Trend.declining);
    });

    test('a noisy-but-flat series is a plateau', () {
      expect(classifyTrend([0.5, 0.52, 0.48, 0.5, 0.51, 0.49]), Trend.plateau);
    });

    test('too few points is insufficient (no trend from noise)', () {
      expect(classifyTrend([0.2, 0.9]), Trend.insufficient);
      expect(classifyTrend([]), Trend.insufficient);
    });

    test('lower-is-better metric (latency) improves as it falls', () {
      final falling = [900.0, 820.0, 760.0, 600.0, 520.0, 480.0];
      expect(classifyTrend(falling, higherIsBetter: false), Trend.improving);
      // The same series read as higher-is-better would be declining.
      expect(classifyTrend(falling), Trend.declining);
    });
  });

  group('movingAverage', () {
    test('smooths a spike toward its neighbours', () {
      final sm = movingAverage([0.0, 0.0, 9.0, 0.0, 0.0], 3);
      expect(sm.length, 5);
      expect(sm[2], closeTo(3.0, 1e-9)); // (0+0+9)/3
      expect(sm[4], closeTo(3.0, 1e-9)); // (9+0+0)/3
    });

    test('window <= 1 returns the series unchanged', () {
      expect(movingAverage([1.0, 2.0, 3.0], 1), [1.0, 2.0, 3.0]);
    });
  });
}
