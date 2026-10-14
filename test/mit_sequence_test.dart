import 'package:flutter_test/flutter_test.dart';
import 'package:rhythmic_practice/practice/mit_sequence.dart';

void main() {
  group('the level step tables are MIT\'s', () {
    test('Level I never asks for independent production', () {
      final steps = stepsFor(MitLevel.one);
      expect(steps, [
        MitStep.humMelody,
        MitStep.humUnison,
        MitStep.intoneUnison,
      ]);
      expect(
        steps.every((s) => !s.cleanCapture),
        isTrue,
        reason: 'nothing at Level I is a solo production',
      );
    });

    test('Level II is the canonical five steps, ending on the question', () {
      expect(stepsFor(MitLevel.two), [
        MitStep.humMelody,
        MitStep.intoneUnison,
        MitStep.unisonFading,
        MitStep.immediateRepeat,
        MitStep.probeQuestion,
      ]);
    });

    test('Level III is retrieval, use, then the bridge out of song', () {
      expect(stepsFor(MitLevel.three), [
        MitStep.delayedRepeat,
        MitStep.probeQuestion,
        MitStep.sprechgesang,
        MitStep.spokenProduction,
      ]);
    });

    test('only Level III comes off the melody, and it comes off last', () {
      // MIT's exit ramp, and the part most often left out. A patient who can
      // produce a phrase only while singing it has generalised nothing, so the
      // last two steps drop the tune — first keeping the rhythm (Sprechgesang),
      // then keeping nothing.
      for (final level in [MitLevel.one, MitLevel.two]) {
        expect(
          stepsFor(level).every((s) => s.isIntoned),
          isTrue,
          reason: '\$level should be intoned throughout',
        );
      }
      final three = stepsFor(MitLevel.three);
      expect(three.where((s) => !s.isIntoned).toList(), [
        MitStep.sprechgesang,
        MitStep.spokenProduction,
      ]);
      // …and they are the tail, not scattered through the sequence.
      expect(three.sublist(three.length - 2).every((s) => !s.isIntoned), isTrue);
    });

    test('the bridge steps are judged solo productions', () {
      for (final s in [MitStep.sprechgesang, MitStep.spokenProduction]) {
        expect(s.isJudged, isTrue);
        expect(s.cleanCapture, isTrue, reason: '\$s is recorded and scored');
        expect(s.isUnison, isFalse);
      }
      // Sprechgesang still plays a model — the phrase SPOKEN. The last step
      // plays nothing at all: that is what makes it the last step.
      expect(MitStep.sprechgesang.playsModel, isTrue);
      expect(MitStep.spokenProduction.playsModel, isFalse);
    });

    test('only the hum is unjudged; unison steps are never recorded', () {
      expect(MitStep.humMelody.isJudged, isFalse);
      for (final s in MitStep.values.where((s) => s != MitStep.humMelody)) {
        expect(s.isJudged, isTrue, reason: '$s is a production');
      }
      for (final s in MitStep.values.where((s) => s.isUnison)) {
        expect(
          s.cleanCapture,
          isFalse,
          reason: '$s has the model sounding over the mic',
        );
      }
    });
  });

  // The one deliberate departure from MIT — two productions per step, a third
  // only when the first two leave doubt.
  group('the 2-of-3 rep rule', () {
    test('two Passes end the step — no third production', () {
      expect(
        RepRule.decide([Verdict.pass, Verdict.pass]),
        RepDecision.passed,
      );
    });

    test('two Fails end the step — no third production either', () {
      expect(
        RepRule.decide([Verdict.fail, Verdict.fail]),
        RepDecision.failed,
        reason: 'a third try after two clear failures is not errorless practice',
      );
    });

    test('doubt buys a third production', () {
      for (final pair in [
        [Verdict.pass, Verdict.fail],
        [Verdict.fail, Verdict.pass],
        [Verdict.pass, Verdict.unsure],
        [Verdict.unsure, Verdict.unsure],
        [Verdict.fail, Verdict.unsure],
      ]) {
        expect(RepRule.decide(pair), RepDecision.again, reason: '$pair');
      }
    });

    test('the third production decides on a majority', () {
      expect(
        RepRule.decide([Verdict.pass, Verdict.unsure, Verdict.pass]),
        RepDecision.passed,
      );
      expect(
        RepRule.decide([Verdict.pass, Verdict.fail, Verdict.fail]),
        RepDecision.failed,
      );
    });

    test('three unsures fail safe — we could not tell is not a pass', () {
      expect(
        RepRule.decide([Verdict.unsure, Verdict.unsure, Verdict.unsure]),
        RepDecision.failed,
      );
    });

    test('a step never asks for more than three', () {
      expect(RepRule.maxReps, 3);
    });
  });

  group('an item runs its whole sequence in one sitting', () {
    // The heart of the revert: all of Level II's steps, on this item, now —
    // not one rung this session and the next one a week later.
    test('clean run walks every step and completes', () {
      final run = MitItemRun(level: MitLevel.two);

      expect(run.currentStep, MitStep.humMelody);
      expect(run.isJudged, isFalse);
      run.completeUnjudgedStep();

      for (final step in const [
        MitStep.intoneUnison,
        MitStep.unisonFading,
        MitStep.immediateRepeat,
        MitStep.probeQuestion,
      ]) {
        expect(run.currentStep, step);
        expect(run.repNumber, 1);
        run.recordVerdict(Verdict.pass);
        expect(run.repNumber, 2, reason: 'the second production of $step');
        run.recordVerdict(Verdict.pass);
      }

      expect(run.outcome, ItemOutcome.completed);
      expect(run.passRate, 1.0);
      expect(run.history.length, 8, reason: '4 judged steps × 2 productions');
    });

    test('a failed step backs up one step, immediately', () {
      final run = MitItemRun(level: MitLevel.two)..completeUnjudgedStep();
      expect(run.currentStep, MitStep.intoneUnison);

      // Climb to immediateRepeat.
      run.recordVerdict(Verdict.pass);
      run.recordVerdict(Verdict.pass);
      expect(run.currentStep, MitStep.unisonFading);
      run.recordVerdict(Verdict.pass);
      run.recordVerdict(Verdict.pass);
      expect(run.currentStep, MitStep.immediateRepeat);

      // Fail it.
      run.recordVerdict(Verdict.fail);
      expect(run.recordVerdict(Verdict.fail), RepDecision.failed);

      expect(
        run.currentStep,
        MitStep.unisonFading,
        reason: 'support is restored in the moment, not next session',
      );
      expect(run.outcome, ItemOutcome.running);
      expect(run.repNumber, 1, reason: 'the backed-up step starts fresh');
    });

    test('recovering after a back-up clears the failure streak', () {
      final run = MitItemRun(level: MitLevel.two)..completeUnjudgedStep();
      run.recordVerdict(Verdict.pass);
      run.recordVerdict(Verdict.pass); // → unisonFading
      run.recordVerdict(Verdict.fail);
      run.recordVerdict(Verdict.fail); // → back to intoneUnison
      expect(run.currentStep, MitStep.intoneUnison);

      run.recordVerdict(Verdict.pass);
      run.recordVerdict(Verdict.pass); // recovered → unisonFading
      run.recordVerdict(Verdict.fail);
      run.recordVerdict(Verdict.fail); // fails again, but not consecutively

      expect(
        run.outcome,
        ItemOutcome.running,
        reason: 'a success between failures resets the streak',
      );
      expect(run.currentStep, MitStep.intoneUnison);
    });

    test('two step failures in a row set the item aside', () {
      final run = MitItemRun(level: MitLevel.two)..completeUnjudgedStep();
      run.recordVerdict(Verdict.pass);
      run.recordVerdict(Verdict.pass); // → unisonFading

      run.recordVerdict(Verdict.fail);
      run.recordVerdict(Verdict.fail); // fail 1 → back to intoneUnison
      expect(run.outcome, ItemOutcome.running);

      run.recordVerdict(Verdict.fail);
      run.recordVerdict(Verdict.fail); // fail 2 → set aside

      expect(
        run.outcome,
        ItemOutcome.setAside,
        reason: 'MIT moves on rather than drilling a failure',
      );
    });

    test('failing the first unison backs up to the hum, and re-hums', () {
      // The melody is the support underneath unison, so backing up from a failed
      // unison means hearing the tune again — exactly what the clinician does.
      final run = MitItemRun(level: MitLevel.two)..completeUnjudgedStep();
      expect(run.currentStep, MitStep.intoneUnison);
      run.recordVerdict(Verdict.fail);
      run.recordVerdict(Verdict.fail);

      expect(run.currentStep, MitStep.humMelody);
      expect(run.outcome, ItemOutcome.running);
      expect(run.isJudged, isFalse, reason: 'the re-hum is not judged');

      run.completeUnjudgedStep();
      expect(run.currentStep, MitStep.intoneUnison, reason: 'and try again');
    });

    test('failing where there is nothing lower sets the item aside', () {
      // Level III opens on a judged step, so a failure there has nowhere to back
      // up to.
      final run = MitItemRun(level: MitLevel.three);
      expect(run.currentStep, MitStep.delayedRepeat);
      run.recordVerdict(Verdict.fail);
      run.recordVerdict(Verdict.fail);
      expect(run.outcome, ItemOutcome.setAside);
    });

    test('a set-aside item accepts no further verdicts', () {
      final run = MitItemRun(level: MitLevel.three);
      run.recordVerdict(Verdict.fail);
      run.recordVerdict(Verdict.fail);
      expect(run.outcome, ItemOutcome.setAside);

      final before = run.history.length;
      run.recordVerdict(Verdict.pass);
      expect(run.history.length, before);
    });

    test('Level I completes without ever asking her to speak the word', () {
      final run = MitItemRun(level: MitLevel.one)..completeUnjudgedStep();
      expect(run.currentStep, MitStep.humUnison);
      run.recordVerdict(Verdict.pass);
      run.recordVerdict(Verdict.pass);
      expect(run.currentStep, MitStep.intoneUnison);
      run.recordVerdict(Verdict.pass);
      run.recordVerdict(Verdict.pass);
      expect(run.outcome, ItemOutcome.completed);
    });
  });

  group('the 90% criterion advances the PERSON\'s level', () {
    test('ten strong sessions move a level', () {
      expect(
        LevelCriterion.shouldAdvance(
          List.filled(10, 0.95),
          current: MitLevel.two,
        ),
        isTrue,
      );
    });

    test('a short history never advances', () {
      expect(
        LevelCriterion.shouldAdvance(
          List.filled(9, 1.0),
          current: MitLevel.one,
        ),
        isFalse,
      );
    });

    test('only the last ten sessions count', () {
      // A strong old run cannot carry a weak recent one.
      final rates = [...List.filled(10, 1.0), ...List.filled(10, 0.5)];
      expect(
        LevelCriterion.shouldAdvance(rates, current: MitLevel.two),
        isFalse,
      );
    });

    test('below the bar holds', () {
      expect(
        LevelCriterion.shouldAdvance(
          List.filled(10, 0.85),
          current: MitLevel.two,
        ),
        isFalse,
      );
    });

    test('Level III is the top', () {
      expect(
        LevelCriterion.shouldAdvance(
          List.filled(10, 1.0),
          current: MitLevel.three,
        ),
        isFalse,
      );
      expect(LevelCriterion.raised(MitLevel.three), MitLevel.three);
      expect(LevelCriterion.lowered(MitLevel.one), MitLevel.one);
    });
  });
}
