import 'package:flutter_test/flutter_test.dart';
import 'package:rhythmic_practice/practice/progression.dart';

void main() {
  test('rung ordering and codes', () {
    expect(Rung.values.length, 7);
    expect(Rung.r0.level, 0);
    expect(Rung.r6.level, 6);
    expect(Rung.r2.code, 'R2');
  });

  test('behavioral flags match the ladder', () {
    // No model on receive/hum and on solo.
    expect(Rung.r0.playsModel, isFalse);
    expect(Rung.r1.playsModel, isFalse);
    expect(Rung.r6.playsModel, isFalse);
    // Model plays r2..r5.
    expect(Rung.r2.playsModel, isTrue);
    expect(Rung.r5.playsModel, isTrue);
    // Unison only r2/r3.
    expect(Rung.r2.isUnison, isTrue);
    expect(Rung.r3.isUnison, isTrue);
    expect(Rung.r4.isUnison, isFalse);
    // Word expected from r2 up.
    expect(Rung.r1.expectsWord, isFalse);
    expect(Rung.r2.expectsWord, isTrue);
  });

  test('raise/lower clamp at the ends', () {
    expect(Rung.r2.raised(), Rung.r3);
    expect(Rung.r2.lowered(), Rung.r1);
    expect(Rung.r6.raised(), Rung.r6); // clamped top
    expect(Rung.r0.lowered(), Rung.r0); // clamped bottom
  });

  test('rungFromLevel clamps out-of-range values', () {
    expect(rungFromLevel(3), Rung.r3);
    expect(rungFromLevel(-5), Rung.r0);
    expect(rungFromLevel(99), Rung.r6);
  });

  test('raising linguistic tier resets support to unison', () {
    expect(supportForNewTier(), Rung.r2);
  });

  test('rung → label map matches the documented stages', () {
    expect([for (final r in Rung.values) r.code],
        ['R0', 'R1', 'R2', 'R3', 'R4', 'R5', 'R6']);
    expect(Rung.r0.title, 'Receive the beat');
    expect(Rung.r1.title, 'Hum to the beat');
    expect(Rung.r2.title, 'Say it together');
    expect(Rung.r3.title, 'Together, model fades'); // unison-fade
    expect(Rung.r4.title, 'Repeat after the model');
    expect(Rung.r5.title, 'Delayed repeat');
    expect(Rung.r6.title, 'Say it on your own'); // solo
  });

  test('judged = R1–R6 (R0 is the only un-judged rung); recorded = R4–R6', () {
    expect(Rung.values.where((r) => r.isJudged).toList(),
        [Rung.r1, Rung.r2, Rung.r3, Rung.r4, Rung.r5, Rung.r6]);
    expect(Rung.r0.isJudged, isFalse); // r0 auto-promotes, never judged
    expect(Rung.values.where((r) => r.cleanCapture).toList(),
        [Rung.r4, Rung.r5, Rung.r6]);
    // R1–R3 are judged but NOT recorded (model/hum makes the mic useless).
    expect(Rung.r1.isJudged, isTrue);
    expect(Rung.r2.isJudged, isTrue);
    expect(Rung.r3.isJudged, isTrue);
    expect(Rung.r3.cleanCapture, isFalse);
  });
}
