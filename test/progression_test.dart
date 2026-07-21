import 'package:flutter_test/flutter_test.dart';
import 'package:rhythmic_practice/practice/progression.dart';

void main() {
  test('rung ordering and codes', () {
    expect(Rung.values.length, 8); // enum unchanged (stable stored integers)
    expect(Rung.r0.level, 0);
    expect(Rung.r7.level, 7);
    expect(Rung.r2.code, 'R2');
    // Active top is R6 (solo); R7 is deferred/off, not the ladder top.
    expect(topRung, Rung.r6);
    expect(entryRung, Rung.r2); // every word starts at unison
    expect(activeLadder,
        [Rung.r2, Rung.r3, Rung.r4, Rung.r5, Rung.r6]); // r0/r1 warm-up, r7 off
  });

  test('active-ladder raise/lower clamps at unison floor and solo top', () {
    expect(Rung.r2.loweredActive(), Rung.r2); // floor: never below unison
    expect(Rung.r3.loweredActive(), Rung.r2);
    expect(Rung.r5.raisedActive(), Rung.r6);
    expect(Rung.r6.raisedActive(), Rung.r6); // top: never into the deferred R7
  });

  test('behavioral flags match the ladder', () {
    // No model on receive/hum, on solo, and on answer-the-question (r7 plays a
    // probe question, not the target-word model).
    expect(Rung.r0.playsModel, isFalse);
    expect(Rung.r1.playsModel, isFalse);
    expect(Rung.r6.playsModel, isFalse);
    expect(Rung.r7.playsModel, isFalse);
    // Model plays r2..r5.
    expect(Rung.r2.playsModel, isTrue);
    expect(Rung.r5.playsModel, isTrue);
    // Unison only r2/r3.
    expect(Rung.r2.isUnison, isTrue);
    expect(Rung.r3.isUnison, isTrue);
    expect(Rung.r4.isUnison, isFalse);
    // Word expected from r2 up (incl. the r7 answer).
    expect(Rung.r1.expectsWord, isFalse);
    expect(Rung.r2.expectsWord, isTrue);
    expect(Rung.r7.expectsWord, isTrue);
  });

  test('raise/lower clamp at the ends', () {
    expect(Rung.r2.raised(), Rung.r3);
    expect(Rung.r2.lowered(), Rung.r1);
    expect(Rung.r6.raised(), Rung.r7); // r6 now steps up to r7
    expect(Rung.r7.raised(), Rung.r7); // clamped top
    expect(Rung.r0.lowered(), Rung.r0); // clamped bottom
  });

  test('rungFromLevel clamps out-of-range values', () {
    expect(rungFromLevel(3), Rung.r3);
    expect(rungFromLevel(-5), Rung.r0);
    expect(rungFromLevel(99), Rung.r7);
  });

  test('raising linguistic tier resets support to unison', () {
    expect(supportForNewTier(), Rung.r2);
  });

  test('levelForSyllableCount maps count → level (item 12): 1-3/4-6/7+', () {
    expect(levelForSyllableCount(0), 1); // no guide yet → L1
    expect(levelForSyllableCount(1), 1);
    expect(levelForSyllableCount(3), 1);
    expect(levelForSyllableCount(4), 2);
    expect(levelForSyllableCount(6), 2);
    expect(levelForSyllableCount(7), 3);
    expect(levelForSyllableCount(20), 3);
    expect(maxLevel, 3);
  });

  test('every word starts at unison regardless of level (progression refactor)',
      () {
    // "Each word's ladder starts at unison" supersedes the old level→entry skip.
    expect(entryRungForLevel(1), Rung.r2);
    expect(entryRungForLevel(2), Rung.r2);
    expect(entryRungForLevel(3), Rung.r2);
  });

  test('sprechgesangSatisfied: L3 needs a slow-spoken clip (item 15)', () {
    expect(sprechgesangLevel, 3);
    // Levels 1–2 never need a Sprechgesang clip.
    expect(sprechgesangSatisfied(level: 1, hasSprechgesangClip: false), isTrue);
    expect(sprechgesangSatisfied(level: 2, hasSprechgesangClip: false), isTrue);
    // Level 3 is unavailable without one, available with it.
    expect(sprechgesangSatisfied(level: 3, hasSprechgesangClip: false), isFalse);
    expect(sprechgesangSatisfied(level: 3, hasSprechgesangClip: true), isTrue);
  });

  test('rung → label map matches the documented stages', () {
    expect([for (final r in Rung.values) r.code],
        ['R0', 'R1', 'R2', 'R3', 'R4', 'R5', 'R6', 'R7']);
    expect(Rung.r0.title, 'Feel the beat'); // warm-up
    expect(Rung.r1.title, 'Hum along'); // warm-up
    expect(Rung.r2.title, 'Say it together');
    expect(Rung.r3.title, 'Together, model fades'); // unison-fade
    expect(Rung.r4.title, 'Repeat after the model');
    expect(Rung.r5.title, 'Delayed repeat');
    expect(Rung.r6.title, 'Say it on your own'); // solo
    expect(Rung.r7.title, 'Answer the question'); // response-to-a-question
  });

  test('judged = every WORD rung (R2–R7); warm-up R0/R1 not judged; recorded R4–R7',
      () {
    expect(Rung.values.where((r) => r.isJudged).toList(),
        [Rung.r2, Rung.r3, Rung.r4, Rung.r5, Rung.r6, Rung.r7]);
    // R0/R1 are the session warm-up — not per-word, never judged.
    expect(Rung.r0.isJudged, isFalse);
    expect(Rung.r1.isJudged, isFalse);
    expect(Rung.values.where((r) => r.cleanCapture).toList(),
        [Rung.r4, Rung.r5, Rung.r6, Rung.r7]);
    // R2–R3 are judged but NOT recorded (the model playing makes the mic useless).
    expect(Rung.r2.isJudged, isTrue);
    expect(Rung.r3.isJudged, isTrue);
    expect(Rung.r3.cleanCapture, isFalse);
    // R7 is judged AND recorded (scaffold) — the answer is a clean solo.
    expect(Rung.r7.isJudged, isTrue);
    expect(Rung.r7.cleanCapture, isTrue);
  });
}
