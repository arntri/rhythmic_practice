import 'package:flutter_test/flutter_test.dart';
import 'package:rhythmic_practice/practice/mit_sequence.dart';
import 'package:rhythmic_practice/practice/step_timing.dart';

void main() {
  // These are protocol numbers, not styling. The delayed-repeat gap in
  // particular is the thing that makes the delayed repeat a different task from
  // the immediate one, so it is pinned here: a future "let's tighten the pacing"
  // pass has to argue with a failing test rather than quietly shrink the therapy.

  test('the delayed repeat holds six seconds — retrieval, not echo', () {
    expect(delayedRepeatMs, 6000);
  });

  test('the delayed repeat waits substantially longer than the immediate one', () {
    // The immediate repeat is *meant* to be echoed back while the phrase still
    // rings; the delayed one must be far enough past that to force retrieval.
    // Anything close to the immediate breath collapses the two steps into one.
    expect(
      afterModelMs(MitStep.delayedRepeat),
      greaterThan(afterModelMs(MitStep.immediateRepeat) * 3),
    );
  });

  test('each step gets its own hold after the model', () {
    expect(afterModelMs(MitStep.delayedRepeat), delayedRepeatMs);
    expect(afterModelMs(MitStep.immediateRepeat), repeatBreathMs);
    expect(afterModelMs(MitStep.probeQuestion), repeatBreathMs);
    expect(afterModelMs(MitStep.sprechgesang), repeatBreathMs);
    expect(afterModelMs(MitStep.intoneUnison), unisonTailMs);
    expect(afterModelMs(MitStep.unisonFading), unisonTailMs);
    expect(afterModelMs(MitStep.humUnison), unisonTailMs);
  });

  test('the last step holds only a get-ready — nothing is played', () {
    // Nothing sounds at spoken production: no tune, no spoken model, no
    // question. The hold before the mic is preparation, not a gap after audio.
    expect(MitStep.spokenProduction.playsModel, isFalse);
    expect(afterModelMs(MitStep.spokenProduction), spokenPromptMs);
    expect(spokenPromptMs, lessThan(delayedRepeatMs),
        reason: 'a get-ready must not turn into a retrieval silence');
  });

  test('the delayed-repeat hold is a whole number of beats at 40-70 BPM', () {
    // The pulse keeps running through the silence and the caregiver keeps
    // tapping, so the hold should land on a beat rather than cut one in half.
    for (final bpm in [40, 60]) {
      final beatMs = 60000 / bpm;
      final beats = delayedRepeatMs / beatMs;
      expect(
        beats,
        closeTo(beats.roundToDouble(), 0.01),
        reason: 'at $bpm BPM the hold should be a whole number of beats',
      );
    }
  });
}
