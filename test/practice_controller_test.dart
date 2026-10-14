import 'package:flutter_test/flutter_test.dart';
import 'package:rhythmic_practice/practice/mit_sequence.dart';
import 'package:rhythmic_practice/practice/practice_controller.dart';

void main() {
  // Records which seams fired, with the phrase id passed to them.
  late List<String> events;

  PracticeController make({
    List<int> phraseIds = const [10, 20],
    MitLevel level = MitLevel.two,
    int humBeats = 0, // skip the hum step in unit tests unless a test wants it
  }) => PracticeController(
    phraseIds: phraseIds,
    level: level,
    phraseHumBeats: humBeats,
    messageBeats: 0, // skip the held moments unless a test is testing them
    tapsToAdvance: 2,
    warmUpBeats: 0, // skip the hum warm-up in unit tests
    guideBeats: 2,
    captureBeats: 2,
    onEnterReferencePrompt: (id) => events.add('guide:$id'),
    onEnterPhraseHum: (id) => events.add('hum:$id'),
    onEnterInputCapture: (id) => events.add('mic-open:$id'),
    onLeaveInputCapture: (id) => events.add('mic-close:$id'),
  );

  setUp(() => events = []);

  /// Drive the current step from its prompt through to a verdict of [label],
  /// taking the mic on the way if the step records one. The screen normally does
  /// this with real audio; here it is instantaneous.
  void produce(PracticeController c, int label) {
    expect(c.state, PracticeState.referencePrompt);
    final capture = c.currentStep.cleanCapture;
    c.endReferencePrompt();
    if (capture) {
      expect(c.state, PracticeState.inputCapture);
      c.endCapture();
    }
    expect(c.state, PracticeState.systemTransition);
    c.setEvaluation(label);
  }

  /// Two clean passes — enough to clear a step outright under [RepRule].
  void passStep(PracticeController c) {
    produce(c, 1);
    produce(c, 1);
  }

  test('starts in Preparation on the first phrase', () {
    final c = make()..start();
    expect(c.state, PracticeState.preparation);
    expect(c.currentIndex, 0);
    expect(c.currentPhraseId, 10);
  });

  test('off-beat taps do not advance; in-time taps do', () {
    final c = make()..start();
    c.onBeat(0);
    c.registerTap(0.5); // off-beat, ignored for advancing
    c.registerTap(0.5);
    expect(c.state, PracticeState.preparation);
    expect(c.inTimeTaps, 0);

    c.registerTap(0.0); // in-time
    c.registerTap(1.0); // in-time (phase 1.0 == on the beat)
    expect(c.state, PracticeState.referencePrompt);
    expect(events, ['guide:10']);
  });

  test('taps land within the wider lock tolerance', () {
    final c = make()..start();
    c.onBeat(0);
    // 0.2 is off-beat for scoring (>0.15) but within the 0.25 lock window.
    c.registerTap(0.2);
    c.registerTap(0.2);
    expect(c.state, PracticeState.referencePrompt);
  });

  test('warm-up: lock the beat → hum phase → the first item', () {
    final c = PracticeController(
      phraseIds: const [10, 20],
      phraseHumBeats: 0,
      messageBeats: 0,
      tapsToAdvance: 1,
      warmUpBeats: 3,
      guideBeats: 2,
      captureBeats: 2,
      onEnterReferencePrompt: (id) => events.add('guide:$id'),
      onEnterWarmUpHum: () => events.add('hum'),
    )..start();
    expect(c.state, PracticeState.preparation);
    c.onBeat(0);
    c.registerTap(0.0); // lock the beat → the hum phase (NOT the word yet)
    expect(c.state, PracticeState.warmUpHum);
    expect(events, ['hum']); // the first item's guide has not fired
    c.onBeat(1);
    c.onBeat(2);
    expect(c.state, PracticeState.warmUpHum); // still warming up
    c.onBeat(3); // warmUpBeats reached → flow into the first item
    expect(c.state, PracticeState.referencePrompt);
    expect(events, ['hum', 'guide:10']);
  });

  test('tapping can NEVER advance the sequence — it only ends the warm-up', () {
    // The bug this guards: tap accuracy used to move a word along. Tapping is a
    // support; only the caregiver's verdict moves the sequence.
    final c = make(phraseIds: const [10])..start();
    c.onBeat(0);
    c.registerTap(0.0);
    c.registerTap(0.0); // ends the warm-up → the first item's first step
    expect(c.state, PracticeState.referencePrompt);
    final step = c.currentStep;

    for (var i = 0; i < 8; i++) {
      c.registerTap(0.0); // perfectly in time, all through the phrase
    }
    expect(c.state, PracticeState.referencePrompt);
    expect(c.currentStep, step, reason: 'taps must not move the sequence');
    expect(c.tapCount, 10,
        reason: 'but every tap is recorded — the two lock taps included');
  });

  test('guide then mic advance after their placeholder beats', () {
    // At Level II the sequence opens on a unison step (no mic), so drive to a
    // step that does record before checking the beat fallbacks.
    final c = make(phraseIds: const [10])..start();
    c.onBeat(0);
    c.registerTap(0.0);
    c.registerTap(0.0); // -> intoneUnison prompt
    passStep(c); // -> unisonFading
    passStep(c); // -> immediateRepeat, which records
    expect(c.currentStep, MitStep.immediateRepeat);

    c.onBeat(1); // 1 beat in guide
    expect(c.state, PracticeState.referencePrompt);
    c.onBeat(2); // 2 beats -> inputCapture
    expect(c.state, PracticeState.inputCapture);

    c.onBeat(3);
    c.onBeat(4); // 2 beats of capture -> systemTransition
    expect(c.state, PracticeState.systemTransition);
    expect(events.last, 'mic-close:10');
  });

  test('endCapture closes Input_Capture early on silence', () {
    final c = make(phraseIds: const [10])..start();
    c.onBeat(0);
    c.registerTap(0.0);
    c.registerTap(0.0);
    passStep(c);
    passStep(c); // -> immediateRepeat
    c.endReferencePrompt();
    expect(c.state, PracticeState.inputCapture);

    c.endCapture(); // mic auto-closed before the beat safety timeout
    expect(c.state, PracticeState.systemTransition);
    expect(events.last, 'mic-close:10');

    // A stray second call must not double-fire a transition.
    c.endCapture();
    expect(c.state, PracticeState.systemTransition);
  });

  // ---- The MIT sequence ----------------------------------------------------
  // The core of the revert. A word no longer SITS at a rung with an engine
  // moving it between sessions; every item runs its level's whole step sequence
  // in one sitting, backs up the moment a step fails, and is set aside rather
  // than drilled after two failures.

  group('the item runs its level sequence', () {
    test('Level II walks its five steps in order, in one sitting', () {
      final c = make(phraseIds: const [10])..start();
      c.onBeat(0);
      c.registerTap(0.0);
      c.registerTap(0.0);

      // The hum is disabled here, so the sequence opens at the first judged step.
      final walked = <MitStep>[];
      while (c.state != PracticeState.sessionComplete) {
        walked.add(c.currentStep);
        passStep(c);
      }
      expect(walked, [
        MitStep.intoneUnison,
        MitStep.unisonFading,
        MitStep.immediateRepeat,
        MitStep.probeQuestion,
      ]);
    });

    test('Level I never asks for an independent production', () {
      final c = make(phraseIds: const [10], level: MitLevel.one)..start();
      c.onBeat(0);
      c.registerTap(0.0);
      c.registerTap(0.0);

      final micOpened = <String>[];
      while (c.state != PracticeState.sessionComplete) {
        expect(c.currentStep.cleanCapture, isFalse,
            reason: '${c.currentStep} would record a solo production');
        passStep(c);
      }
      expect(events.where((e) => e.startsWith('mic-open')), micOpened);
    });

    test('Level III ends by coming off the melody', () {
      final c = make(phraseIds: const [10], level: MitLevel.three)..start();
      c.onBeat(0);
      c.registerTap(0.0);
      c.registerTap(0.0);

      final walked = <MitStep>[];
      while (c.state != PracticeState.sessionComplete) {
        walked.add(c.currentStep);
        passStep(c);
      }
      expect(walked, [
        MitStep.delayedRepeat,
        MitStep.probeQuestion,
        MitStep.sprechgesang,
        MitStep.spokenProduction,
      ]);
      // Every one of them records: by Level III there is no unison left to
      // contaminate the mic.
      expect(walked.every((s) => s.cleanCapture), isTrue);
    });

    test('a step passes on two passes — no needless third production', () {
      final c = make(phraseIds: const [10])..start();
      c.onBeat(0);
      c.registerTap(0.0);
      c.registerTap(0.0);
      expect(c.currentStep, MitStep.intoneUnison);
      expect(c.repNumber, 1);

      produce(c, 1);
      expect(c.currentStep, MitStep.intoneUnison, reason: 'same step, rep 2');
      expect(c.repNumber, 2);

      produce(c, 1);
      expect(c.currentStep, MitStep.unisonFading, reason: 'two passes is enough');
      expect(c.repNumber, 1);
    });

    test('doubt costs a deciding third production; certainty does not', () {
      final c = make(phraseIds: const [10])..start();
      c.onBeat(0);
      c.registerTap(0.0);
      c.registerTap(0.0);

      produce(c, 1); // Pass
      produce(c, 2); // Unsure → the pair is not decisive
      expect(c.currentStep, MitStep.intoneUnison);
      expect(c.repNumber, 3, reason: 'a third production decides it');

      produce(c, 1); // Pass, Unsure, Pass → majority passes
      expect(c.currentStep, MitStep.unisonFading);
    });

    test('a failed step backs up IMMEDIATELY, in the same sitting', () {
      final c = make(phraseIds: const [10])..start();
      c.onBeat(0);
      c.registerTap(0.0);
      c.registerTap(0.0);

      passStep(c); // intoneUnison passed
      expect(c.currentStep, MitStep.unisonFading);

      produce(c, 0);
      produce(c, 0); // two clear failures → the step is failed
      expect(
        c.currentStep,
        MitStep.intoneUnison,
        reason: 'support is restored in the moment, not next session',
      );
      expect(c.state, PracticeState.referencePrompt);
    });

    test('two step failures in a row set the item aside', () {
      final c = make(phraseIds: const [10, 20])..start();
      c.onBeat(0);
      c.registerTap(0.0);
      c.registerTap(0.0);

      passStep(c); // -> unisonFading
      produce(c, 0);
      produce(c, 0); // failure 1 → back up to intoneUnison
      expect(c.currentStep, MitStep.intoneUnison);

      produce(c, 0);
      produce(c, 0); // failure 2 → drilling a failure is not what MIT does
      expect(c.currentPhraseId, 20, reason: 'the session moved on');
      expect(c.itemOutcome, ItemOutcome.running, reason: 'a fresh run for 20');
    });

    test('failing the first JUDGED step backs up to the hum — the melody is '
        'handed over again', () {
      // Level II's sequence opens with the hum, so there IS somewhere lower to
      // go from the first judged step: back to being given the tune. That is the
      // right answer therapeutically — the person who cannot intone it in unison
      // needs the melody again, not to be dropped.
      final c = make(phraseIds: const [10, 20], humBeats: 12)..start();
      c.onBeat(0);
      c.registerTap(0.0);
      c.registerTap(0.0);
      c.endPhraseHum();
      expect(c.currentStep, MitStep.intoneUnison);

      produce(c, 0);
      produce(c, 0);
      expect(c.currentStep, MitStep.humMelody);
      expect(c.state, PracticeState.phraseHum);
      expect(c.currentPhraseId, 10, reason: 'still the same item');
    });

    test('failing the first step with nowhere lower sets the item aside', () {
      // Level III opens on the delayed repeat — there is no easier step in that
      // sequence to fall back to, so a failure ends the item for today.
      final c = make(phraseIds: const [10, 20], level: MitLevel.three)..start();
      c.onBeat(0);
      c.registerTap(0.0);
      c.registerTap(0.0);
      expect(c.currentStep, MitStep.delayedRepeat);

      produce(c, 0);
      produce(c, 0);
      expect(c.currentPhraseId, 20);
    });

    test('the last item completing ends the session', () {
      final c = make(phraseIds: const [10])..start();
      c.onBeat(0);
      c.registerTap(0.0);
      c.registerTap(0.0);
      passStep(c);
      passStep(c);
      passStep(c);
      passStep(c);
      expect(c.state, PracticeState.sessionComplete);
    });

    test('lock once, then flow: the second item skips Preparation', () {
      final c = make()..start();
      c.onBeat(0);
      c.registerTap(0.0);
      c.registerTap(0.0);
      passStep(c);
      passStep(c);
      passStep(c);
      passStep(c); // item 10 complete

      expect(c.state, PracticeState.referencePrompt);
      expect(c.currentIndex, 1);
      expect(c.currentPhraseId, 20);
      expect(c.currentStep, MitStep.intoneUnison, reason: 'a fresh sequence');
    });

    test('the word counter is one entry per item', () {
      final c = make(phraseIds: const [10, 20, 30])..start();
      expect(c.wordCount, 3);
      expect(c.phraseCount, 3);
      expect(c.currentWordIndex, 0);
    });
  });

  // ---- The unjudged hum step ----------------------------------------------

  group('the hum step (MIT step 1)', () {
    test('an item hums its melody before its word is presented', () {
      final c = make(phraseIds: const [10], humBeats: 12)..start();
      c.onBeat(0);
      c.registerTap(0.0);
      c.registerTap(0.0);

      expect(c.state, PracticeState.phraseHum);
      expect(c.currentStep, MitStep.humMelody);
      expect(events, ['hum:10']);
    });

    test('endPhraseHum hands over to the first judged step', () {
      final c = make(phraseIds: const [10], humBeats: 12)..start();
      c.onBeat(0);
      c.registerTap(0.0);
      c.registerTap(0.0);
      c.endPhraseHum();

      expect(c.state, PracticeState.referencePrompt);
      expect(c.currentStep, MitStep.intoneUnison);
      expect(events, ['hum:10', 'guide:10']);
    });

    test('endPhraseHum is inert outside the hum', () {
      final c = make(phraseIds: const [10], humBeats: 12)..start();
      c.onBeat(0);
      c.registerTap(0.0);
      c.registerTap(0.0);
      c.endPhraseHum();
      c.endPhraseHum(); // late/duplicate callback must not cut the word short

      expect(c.state, PracticeState.referencePrompt);
      expect(events, ['hum:10', 'guide:10']);
    });

    test('the beat cap releases a hum whose completion never arrives', () {
      final c = make(phraseIds: const [10], humBeats: 3)..start();
      c.onBeat(0);
      c.registerTap(0.0);
      c.registerTap(0.0);
      expect(c.state, PracticeState.phraseHum);

      c.onBeat(1);
      c.onBeat(2);
      expect(c.state, PracticeState.phraseHum, reason: 'not yet at the cap');
      c.onBeat(3);
      expect(c.state, PracticeState.referencePrompt);
    });

    test('hums once per ITEM, not before every production', () {
      final c = make(phraseIds: const [10, 20], humBeats: 12)..start();
      c.onBeat(0);
      c.registerTap(0.0);
      c.registerTap(0.0);
      expect(events, ['hum:10']);
      c.endPhraseHum();

      // Every judged step of item 10 — two productions each — with no re-hum.
      passStep(c);
      passStep(c);
      passStep(c);
      passStep(c);

      // A NEW item hums again.
      expect(c.state, PracticeState.phraseHum);
      expect(c.currentPhraseId, 20);
      expect(events.where((e) => e.startsWith('hum:')), ['hum:10', 'hum:20']);
    });

    test('the hum is never judged — it produces no attempt', () {
      final results = <AttemptResult>[];
      final c = PracticeController(
        phraseIds: const [10],
        tapsToAdvance: 1,
        warmUpBeats: 0,
        phraseHumBeats: 12,
        messageBeats: 0,
        onAttemptComplete: results.add,
      )..start();
      c.registerTap(0.0);

      expect(c.state, PracticeState.phraseHum);
      expect(results, isEmpty);
      // A verdict tapped during the hum is ignored; only productions are judged.
      c.setEvaluation(1);
      expect(results, isEmpty);
      expect(c.state, PracticeState.phraseHum);
    });

    test('phraseHumBeats: 0 skips the step entirely', () {
      final c = make(phraseIds: const [10])..start();
      c.onBeat(0);
      c.registerTap(0.0);
      c.registerTap(0.0);

      expect(c.state, PracticeState.referencePrompt);
      expect(c.currentStep, MitStep.intoneUnison);
      expect(c.phraseHumEnabled, isFalse);
      expect(events, ['guide:10']);
    });

    test("the warm-up flows into the first item's hum", () {
      final c = PracticeController(
        phraseIds: const [10],
        tapsToAdvance: 1,
        warmUpBeats: 2,
        phraseHumBeats: 12,
        onEnterPhraseHum: (id) => events.add('hum:$id'),
      )..start();
      c.registerTap(0.0);

      expect(c.state, PracticeState.warmUpHum);
      c.onBeat(0);
      c.onBeat(1);
      expect(c.state, PracticeState.phraseHum);
      expect(events, ['hum:10']);
    });
  });

  // ---- Step routing --------------------------------------------------------

  test('a step that records opens the mic; a unison step goes to the verdict',
      () {
    for (final step in MitStep.values) {
      if (step == MitStep.humMelody) continue; // has its own state
      // Pick a level whose sequence contains this step, then jump to it.
      final level = stepsFor(MitLevel.two).contains(step)
          ? MitLevel.two
          : (stepsFor(MitLevel.three).contains(step)
              ? MitLevel.three
              : MitLevel.one);
      final fired = <String>[];
      final c = PracticeController(
        phraseIds: const [10],
        level: level,
        tapsToAdvance: 1,
        warmUpBeats: 0,
        phraseHumBeats: 0,
        onEnterInputCapture: (_) => fired.add('mic'),
      )..start();
      c.registerTap(0.0);
      c.demoJumpToStep(step);
      expect(c.currentStep, step, reason: '$step should exist in $level');

      c.endReferencePrompt();
      if (step.cleanCapture) {
        expect(c.state, PracticeState.inputCapture, reason: '$step records');
      } else {
        expect(c.state, PracticeState.systemTransition,
            reason: '$step is judged but not recorded');
        expect(fired, isEmpty, reason: '$step must not open the mic');
      }
    }
  });

  test('the probe question opens the mic like the other solo steps', () {
    final c = make(phraseIds: const [10])..start();
    c.onBeat(0);
    c.registerTap(0.0);
    c.registerTap(0.0);
    passStep(c);
    passStep(c);
    passStep(c);
    expect(c.currentStep, MitStep.probeQuestion);

    c.endReferencePrompt(); // the question finished → a clean solo answer
    expect(c.state, PracticeState.inputCapture);
    expect(events.last, 'mic-open:10');
  });

  test('endReferencePrompt is inert on a stray second call', () {
    final c = make(phraseIds: const [10])..start();
    c.onBeat(0);
    c.registerTap(0.0);
    c.registerTap(0.0);
    passStep(c);
    passStep(c); // -> immediateRepeat

    c.endReferencePrompt();
    expect(c.state, PracticeState.inputCapture);
    c.endReferencePrompt();
    expect(c.state, PracticeState.inputCapture);
  });

  // ---- The attempt record --------------------------------------------------

  test('onAttemptComplete carries the phrase, the STEP, and the rep number', () {
    final results = <AttemptResult>[];
    final c = PracticeController(
      phraseIds: const [10],
      tapsToAdvance: 1,
      warmUpBeats: 0,
      phraseHumBeats: 0,
      messageBeats: 0,
      guideBeats: 1,
      captureBeats: 1,
      onAttemptComplete: results.add,
    )..start();

    c.onBeat(0);
    c.registerTap(0.0); // perfect tap -> the first step's prompt
    c.endReferencePrompt();
    c.setEvaluation(1);

    expect(results.single.phraseId, 10);
    expect(results.single.evaluationLabel, 1);
    expect(results.single.syncScore, 1.0);
    expect(results.single.latencyMs, isNull); // mic not driven here
    // The step travels WITH the production: by the time the screen saves this,
    // the run may already have advanced past it.
    expect(results.single.step, MitStep.intoneUnison);
    expect(results.single.repNumber, 1);
    expect(c.repNumber, 2, reason: 'the run has moved on to rep 2');
  });

  test('captures the raw tap stream (with dwell) into the AttemptResult', () {
    final results = <AttemptResult>[];
    final c = PracticeController(
      phraseIds: const [10],
      tapsToAdvance: 1,
      warmUpBeats: 0,
      phraseHumBeats: 0,
      messageBeats: 0,
      onAttemptComplete: results.add,
    )..start();

    c.onBeat(0);
    c.registerTap(0.10); // tap 1 (down)
    c.registerTapRelease(); // …its release → dwell recorded
    // A second tap whose release is never seen → dwell stays null.
    c.registerTap(0.20);
    c.endReferencePrompt();
    c.setEvaluation(1);

    final taps = results.single.taps;
    expect(taps.length, 2);
    expect(taps[0].phase, closeTo(0.10, 1e-9));
    expect(taps[0].dwellMs, isNotNull); // release observed
    expect(taps[0].dwellMs! >= 0, isTrue);
    expect(taps[1].phase, closeTo(0.20, 1e-9));
    expect(taps[1].dwellMs, isNull); // no release → not measured
    // Down times are monotonic (ms since the session's controller started).
    expect(taps[0].downMs <= taps[1].downMs, isTrue);
  });

  test('the tap stream resets per PRODUCTION, not per item', () {
    // A step can be produced two or three times, and each production is its own
    // attempt row — so its taps must not carry over from the last one.
    final results = <AttemptResult>[];
    final c = PracticeController(
      phraseIds: const [10],
      tapsToAdvance: 1,
      warmUpBeats: 0,
      phraseHumBeats: 0,
      messageBeats: 0,
      onAttemptComplete: results.add,
    )..start();

    c.onBeat(0);
    c.registerTap(0.0); // this tap locks the beat AND counts for production 1
    c.registerTap(0.1);
    c.endReferencePrompt();
    c.setEvaluation(1); // production 1 of intoneUnison

    c.registerTap(0.3);
    c.endReferencePrompt();
    c.setEvaluation(1); // production 2 of the same step

    expect(results.length, 2);
    expect(results[0].taps.length, 2);
    expect(results[1].taps.length, 1);
    expect(results[1].taps.single.phase, closeTo(0.3, 1e-9));
  });

  test('sync score reflects tap accuracy and resets per production', () {
    final c = make(phraseIds: const [10])..start();
    c.onBeat(0);
    c.registerTap(0.0);
    c.registerTap(0.0); // perfect taps -> the first step's prompt
    expect(c.currentSyncScore, 1.0);

    c.endReferencePrompt();
    c.setEvaluation(2);
    expect(c.currentSyncScore, isNull, reason: 'no taps in the new production');
  });

  // ---- Hand tapping is phrase-locked, not clock-locked ----------------------
  // In canonical MIT the caregiver taps the patient's left hand once per
  // syllable, starting and stopping WITH the phrase — a three-syllable phrase
  // gets three taps and then the hand rests. The gaps (the count-in, the
  // six-second delayed-repeat silence, the pause before a verdict) carry no
  // taps. These pin down that the cue follows productions rather than the clock,
  // and that a window can't leak past the production that opened it.

  group('hand tapping is phrase-locked', () {
    test('the window follows productions, not the beat', () {
      final c = PracticeController(
        phraseIds: const [10],
        level: MitLevel.three, // opens on the delayed repeat, which records
        tapsToAdvance: 1,
        warmUpBeats: 0,
        phraseHumBeats: 12,
      )..start();

      expect(c.tappingExpected, isFalse,
          reason: 'nothing is being produced yet');

      c.registerTap(0.0);
      expect(c.state, PracticeState.referencePrompt,
          reason: 'Level III has no hum step');

      c.beginProduction(); // the model starts playing
      expect(c.tappingExpected, isTrue);

      c.endProduction(); // model over — this gap is the six-second silence
      expect(c.tappingExpected, isFalse,
          reason: 'the retrieval silence is held, not tapped');

      c.endReferencePrompt();
      expect(c.state, PracticeState.inputCapture);
      c.beginProduction(); // the mic is open and she speaks
      expect(c.tappingExpected, isTrue);

      c.endCapture();
      expect(c.state, PracticeState.systemTransition);
      expect(c.tappingExpected, isFalse,
          reason: 'the caregiver needs their hand for the verdict');
    });

    test('MIT taps through the hum step too', () {
      final c = make(phraseIds: const [10], humBeats: 12)..start();
      c.onBeat(0);
      c.registerTap(0.0);
      c.registerTap(0.0);
      expect(c.state, PracticeState.phraseHum);
      expect(c.tappingExpected, isFalse,
          reason: 'the hum STATE is not the hum sounding');

      c.beginProduction(); // the screen starts the melody
      expect(c.tappingExpected, isTrue);
    });

    test('nothing can reopen the window once the session is over', () {
      final c = make(phraseIds: const [10])..start();
      c.onBeat(0);
      c.registerTap(0.0);
      c.registerTap(0.0);
      passStep(c);
      passStep(c);
      passStep(c);
      passStep(c);
      expect(c.state, PracticeState.sessionComplete);

      c.beginProduction();
      expect(c.tappingExpected, isFalse);
    });

    test('a state change closes an open window', () {
      final c = make(phraseIds: const [10])..start();
      c.onBeat(0);
      c.registerTap(0.0);
      c.registerTap(0.0);
      passStep(c);
      passStep(c); // -> immediateRepeat
      expect(c.state, PracticeState.referencePrompt);

      c.beginProduction();
      expect(c.tappingExpected, isTrue);

      // The model never reported completion (a dropped callback); moving on must
      // still stop asking for taps, so a stale window can't run into the mic.
      c.endReferencePrompt();
      expect(c.state, PracticeState.inputCapture);
      expect(c.tappingExpected, isFalse);
    });

    test('tapCount resets with the production', () {
      final c = make(phraseIds: const [10])..start();
      c.onBeat(0);
      c.registerTap(0.0);
      c.registerTap(0.0);
      expect(c.tapCount, greaterThan(0));

      c.endReferencePrompt();
      c.setEvaluation(1);
      expect(c.tapCount, 0);
    });
  });

  // ---- Breaks --------------------------------------------------------------
  // **The app never interrupts to suggest one.** It used to, after a set number
  // of items and after two set-asides in a row. That is now the caregiver's call
  // and theirs only, reached from the slide-out: the person sitting beside the
  // patient can see whether they are tiring, and an app deciding that from item
  // counts gets it wrong in both directions.

  group('the break offer', () {
    PracticeController resting() => PracticeController(
      phraseIds: const [10, 20, 30],
      phraseHumBeats: 0,
      messageBeats: 0,
      tapsToAdvance: 1,
      warmUpBeats: 0,
      onEnterRest: () => events.add('rest'),
    );

    void completeItem(PracticeController c) {
      for (var i = 0; i < 4; i++) {
        passStep(c);
      }
    }

    test('never fires by itself, however long the session runs', () {
      final c = resting()..start();
      c.registerTap(0.0);
      completeItem(c);
      completeItem(c);
      expect(c.state, PracticeState.referencePrompt);
      expect(events, isEmpty, reason: 'the app does not decide this');
    });

    test('nor after items are set aside', () {
      final c = resting()..start();
      c.registerTap(0.0);
      void setAsideItem() {
        produce(c, 0);
        produce(c, 0); // failure 1 → back up
        produce(c, 0);
        produce(c, 0); // failure 2 → set aside
      }

      setAsideItem();
      setAsideItem();
      expect(c.state, isNot(PracticeState.rest));
      expect(events, isEmpty);
    });

    test('the caregiver opens it, from the panel', () {
      final c = resting()..start();
      c.registerTap(0.0);
      completeItem(c);

      c.offerRest();
      expect(c.state, PracticeState.rest);
      expect(events, ['rest']);
      expect(c.itemsFinished, 1, reason: 'reported, not used to decide');
    });

    test('keeping going returns to where the session was, not the next item', () {
      final c = resting()..start();
      c.registerTap(0.0);
      passStep(c); // part way through item 10
      expect(c.currentStep, MitStep.unisonFading);

      c.offerRest();
      c.resumeFromRest();
      expect(c.state, PracticeState.referencePrompt);
      expect(c.currentPhraseId, 10, reason: 'the same word');
      expect(c.currentStep, MitStep.unisonFading, reason: 'the same step');
    });

    test('resting stops the session for today', () {
      final c = resting()..start();
      c.registerTap(0.0);
      c.offerRest();
      c.finishSessionEarly();
      expect(c.state, PracticeState.sessionComplete);
    });

    test('nothing is offered once the session is over', () {
      final c = PracticeController(
        phraseIds: const [10],
        phraseHumBeats: 0,
        messageBeats: 0,
        tapsToAdvance: 1,
        warmUpBeats: 0,
      )..start();
      c.registerTap(0.0);
      for (var i = 0; i < 4; i++) {
        passStep(c);
      }
      expect(c.state, PracticeState.sessionComplete);
      c.offerRest();
      expect(c.state, PracticeState.sessionComplete);
    });
  });

  // ---- The two held moments ------------------------------------------------
  // Backing up and setting an item aside are the transitions most likely to be
  // read as losing ground, so each gets a moment of its own rather than a toast
  // over whatever comes next.

  group('held moments', () {
    PracticeController held({List<int> ids = const [10, 20]}) =>
        PracticeController(
          phraseIds: ids,
          phraseHumBeats: 0,
          messageBeats: 2,
          tapsToAdvance: 1,
          warmUpBeats: 0,
        );

    test('a back-up is held, then the easier step runs', () {
      final c = held()..start();
      c.registerTap(0.0);
      passStep(c); // -> unisonFading
      produce(c, 0);
      produce(c, 0); // failed

      expect(c.state, PracticeState.backingUp);
      expect(c.backedUpFrom, MitStep.unisonFading,
          reason: 'the screen names where they came from');
      expect(c.currentStep, MitStep.intoneUnison,
          reason: 'the field has ALREADY moved back');

      c.onBeat(0);
      expect(c.state, PracticeState.backingUp, reason: 'not yet');
      c.onBeat(1);
      expect(c.state, PracticeState.referencePrompt);
      expect(c.currentStep, MitStep.intoneUnison);
      expect(c.backedUpFrom, isNull);
    });

    test('a set-aside is held, then the session moves on', () {
      final c = held()..start();
      c.registerTap(0.0);
      // Fail the first judged step twice over — back up, then fail again.
      produce(c, 0);
      produce(c, 0);
      c.onBeat(0);
      c.onBeat(1); // through the back-up hold
      produce(c, 0);
      produce(c, 0);

      expect(c.state, PracticeState.itemSetAside);
      expect(c.currentPhraseId, 10, reason: 'still naming the item held back');
      expect(c.nextPhraseId, 20, reason: 'and what comes next');

      c.onBeat(2);
      c.onBeat(3);
      expect(c.currentPhraseId, 20);
      expect(c.state, PracticeState.referencePrompt);
    });

    test('the last item being set aside still ends the session', () {
      final c = held(ids: const [10])..start();
      c.registerTap(0.0);
      produce(c, 0);
      produce(c, 0);
      c.onBeat(0);
      c.onBeat(1);
      produce(c, 0);
      produce(c, 0);
      expect(c.state, PracticeState.itemSetAside);
      expect(c.nextPhraseId, isNull);
      c.onBeat(2);
      c.onBeat(3);
      expect(c.state, PracticeState.sessionComplete);
    });

    test('messageBeats: 0 skips them entirely', () {
      final c = make(phraseIds: const [10, 20])..start();
      c.onBeat(0);
      c.registerTap(0.0);
      c.registerTap(0.0);
      passStep(c);
      produce(c, 0);
      produce(c, 0);
      expect(c.state, PracticeState.referencePrompt);
    });
  });

  // ---- The caregiver boundary ----------------------------------------------
  // Turning the phone to portrait is the privacy boundary, and this is its other
  // half: nothing runs while a caregiver reads notes about the person sitting in
  // front of the screen, and coming back never drops them into the middle of a
  // phrase they were halfway through singing.

  group('pausing for the caregiver', () {
    PracticeController paused() => PracticeController(
      phraseIds: const [10, 20],
      phraseHumBeats: 0,
      messageBeats: 0,
      tapsToAdvance: 1,
      warmUpBeats: 0,
      onEnterPaused: () => events.add('paused'),
    );

    test('stops the session where it stands', () {
      final c = paused()..start();
      c.registerTap(0.0);
      passStep(c); // part way through the sequence
      expect(c.currentStep, MitStep.unisonFading);

      c.pauseForCaregiver();
      expect(c.state, PracticeState.paused);
      expect(c.caregiverAway, isTrue);
      expect(events, contains('paused'));
    });

    test('coming back does not start anything by itself', () {
      final c = paused()..start();
      c.registerTap(0.0);
      c.pauseForCaregiver();

      c.caregiverReturned();
      expect(c.caregiverAway, isFalse);
      expect(c.state, PracticeState.paused,
          reason: 'it waits for a tap rather than resuming itself');
    });

    test('resuming restarts the step from its beginning, never mid-word', () {
      final c = paused()..start();
      c.registerTap(0.0);
      passStep(c);
      expect(c.currentStep, MitStep.unisonFading);
      produce(c, 1); // one production in — halfway through this step

      c.pauseForCaregiver();
      c.caregiverReturned();
      c.resumeAfterCaregiver();

      expect(c.state, PracticeState.referencePrompt);
      expect(c.currentStep, MitStep.unisonFading, reason: 'the same step');
      expect(c.currentPhraseId, 10, reason: 'the same word');
    });

    test('a break offer that was open is still owed an answer', () {
      final c = PracticeController(
        phraseIds: const [10, 20, 30],
        phraseHumBeats: 0,
        messageBeats: 0,
        tapsToAdvance: 1,
        warmUpBeats: 0,
      )..start();
      c.registerTap(0.0);
      c.offerRest();
      expect(c.state, PracticeState.rest);

      c.pauseForCaregiver();
      c.caregiverReturned();
      c.resumeAfterCaregiver();
      expect(c.state, PracticeState.rest,
          reason: 'the break was not silently skipped');
    });

    test('pausing during the warm-up returns to the warm-up', () {
      final c = PracticeController(
        phraseIds: const [10],
        phraseHumBeats: 0,
        tapsToAdvance: 3,
        warmUpBeats: 4,
      )..start();
      expect(c.state, PracticeState.preparation);

      c.pauseForCaregiver();
      c.caregiverReturned();
      c.resumeAfterCaregiver();
      expect(c.state, PracticeState.preparation,
          reason: 'the beat lock has to be done again, not skipped');
    });

    test('a second pause does not lose where we were', () {
      // Re-entering the panel from a sub-screen must not overwrite the state to
      // come back to with "paused".
      final c = paused()..start();
      c.registerTap(0.0);
      passStep(c);

      c.pauseForCaregiver();
      c.pauseForCaregiver();
      c.caregiverReturned();
      c.resumeAfterCaregiver();
      expect(c.state, PracticeState.referencePrompt);
      expect(c.currentStep, MitStep.unisonFading);
    });

    test('nothing pauses once the session is over', () {
      final c = paused()..start();
      c.registerTap(0.0);
      for (var i = 0; i < 8; i++) {
        passStep(c);
      }
      expect(c.state, PracticeState.sessionComplete);
      c.pauseForCaregiver();
      expect(c.state, PracticeState.sessionComplete);
    });
  });

  // ---- Demonstration -------------------------------------------------------

  group('demo jump', () {
    test('jumps to any step of the level and re-runs it, judging nothing', () {
      final c = make(phraseIds: const [10])..start();
      c.onBeat(0);
      c.registerTap(0.0);
      c.registerTap(0.0);

      c.demoJumpToStep(MitStep.probeQuestion);
      expect(c.currentStep, MitStep.probeQuestion);
      expect(c.state, PracticeState.referencePrompt);
      expect(c.run.history, isEmpty, reason: 'a demo leaves no record');

      c.demoJumpToStep(MitStep.intoneUnison);
      expect(c.currentStep, MitStep.intoneUnison);
      expect(c.run.history, isEmpty);
    });

    test('a step outside this level is refused', () {
      final c = make(phraseIds: const [10])..start();
      c.onBeat(0);
      c.registerTap(0.0);
      c.registerTap(0.0);

      // The delayed repeat is Level III's; Level II has no such step to show.
      c.demoJumpToStep(MitStep.delayedRepeat);
      expect(c.currentStep, MitStep.intoneUnison);
    });

    test('restartCurrentStep re-runs without recording an attempt', () {
      final results = <AttemptResult>[];
      final c = PracticeController(
        phraseIds: const [10],
        tapsToAdvance: 1,
        warmUpBeats: 0,
        phraseHumBeats: 0,
        messageBeats: 0,
        onAttemptComplete: results.add,
      )..start();
      c.registerTap(0.0);
      final step = c.currentStep;

      c.restartCurrentStep();
      expect(c.currentStep, step);
      expect(c.state, PracticeState.referencePrompt);
      expect(results, isEmpty);
    });
  });
}
