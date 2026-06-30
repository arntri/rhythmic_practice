import 'package:flutter_test/flutter_test.dart';
import 'package:rhythmic_practice/practice/tap_sync.dart';

void main() {
  test('offsetFromBeat is 0 on the beat and 0.5 halfway between', () {
    expect(offsetFromBeat(0.0), 0.0);
    expect(offsetFromBeat(0.5), 0.5);
    expect(offsetFromBeat(0.9), closeTo(0.1, 1e-9)); // 0.1 before next beat
    expect(offsetFromBeat(0.1), closeTo(0.1, 1e-9)); // 0.1 after a beat
  });

  test('isInTime accepts near-beat taps and rejects off-beat ones', () {
    expect(isInTime(0.02), isTrue);
    expect(isInTime(0.98), isTrue); // just before the beat
    expect(isInTime(0.5), isFalse); // dead between beats
    expect(isInTime(0.3), isFalse);
  });

  test('syncScoreFromPhases: perfect taps score 1.0', () {
    expect(syncScoreFromPhases([0.0, 1.0, 0.0]), 1.0);
  });

  test('syncScoreFromPhases: worst taps score 0.0', () {
    expect(syncScoreFromPhases([0.5, 0.5]), 0.0);
  });

  test('syncScoreFromPhases: mixed taps score in between', () {
    // offsets: 0.1, 0.1 -> avg 0.1 -> score 1 - 0.2 = 0.8
    expect(syncScoreFromPhases([0.1, 0.9]), closeTo(0.8, 1e-9));
  });

  test('syncScoreFromPhases: no taps -> null', () {
    expect(syncScoreFromPhases([]), isNull);
  });
}
