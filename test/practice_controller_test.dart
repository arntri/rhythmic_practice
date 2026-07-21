import 'package:flutter_test/flutter_test.dart';
import 'package:rhythmic_practice/practice/practice_controller.dart';
import 'package:rhythmic_practice/practice/progression.dart';

void main() {
  // Records which seams fired, with the phrase id passed to them.
  late List<String> events;

  PracticeController make() => PracticeController(
        phraseIds: const [10, 20],
        tapsToAdvance: 2,
        warmUpBeats: 0, // skip the hum warm-up in unit tests
        guideBeats: 2,
        captureBeats: 2,
        onEnterReferencePrompt: (id) => events.add('guide:$id'),
        onEnterInputCapture: (id) => events.add('mic-open:$id'),
        onLeaveInputCapture: (id) => events.add('mic-close:$id'),
      );

  setUp(() => events = []);

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

  test('warm-up: lock the beat → hum phase → first word (once per session)', () {
    final c = PracticeController(
      phraseIds: const [10, 20],
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
    expect(events, ['hum']); // the first word's guide has not fired
    c.onBeat(1);
    c.onBeat(2);
    expect(c.state, PracticeState.warmUpHum); // still warming up
    c.onBeat(3); // warmUpBeats reached → flow into the first word
    expect(c.state, PracticeState.referencePrompt);
    expect(events, ['hum', 'guide:10']);
  });

  test('tapping can NEVER advance a word — it only ends the warm-up', () {
    // The bug this refactor fixes: tap accuracy used to advance a word into the
    // humming rung. Now tapping/humming are the warm-up; word rungs start at r2.
    final c = PracticeController(
      phraseIds: const [10],
      tapsToAdvance: 1,
      warmUpBeats: 0,
      rungOf: (_) => Rung.r2,
    )..start();
    c.onBeat(0);
    c.registerTap(0.0); // ends the warm-up → the first word, at unison (r2)
    expect(c.state, PracticeState.referencePrompt);
    expect(c.currentRung, Rung.r2);
    // Further taps during the word change nothing — no rung/word advance.
    c.registerTap(0.0);
    c.registerTap(0.0);
    expect(c.state, PracticeState.referencePrompt);
    expect(c.currentRung, Rung.r2);
  });

  test('guide then mic advance after their placeholder beats', () {
    final c = make()..start();
    c.onBeat(0);
    c.registerTap(0.0);
    c.registerTap(0.0); // -> referencePrompt at beat 0

    c.onBeat(1); // 1 beat in guide
    expect(c.state, PracticeState.referencePrompt);
    c.onBeat(2); // 2 beats -> inputCapture
    expect(c.state, PracticeState.inputCapture);
    expect(events, ['guide:10', 'mic-open:10']);

    c.onBeat(3);
    c.onBeat(4); // 2 beats of capture -> systemTransition
    expect(c.state, PracticeState.systemTransition);
    expect(events.last, 'mic-close:10');
  });

  test('lock once, then flow: phrase 2 skips Preparation', () {
    final c = make()..start();

    // Phrase 1: lock into the beat (the only time we tap to advance), then run.
    c.onBeat(0);
    c.registerTap(0.0);
    c.registerTap(0.0); // -> referencePrompt
    c.onBeat(1);
    c.onBeat(2); // -> inputCapture
    c.onBeat(3);
    c.onBeat(4); // -> systemTransition
    expect(c.state, PracticeState.systemTransition);

    // Verdict advances straight to the next phrase's guide — NO re-lock.
    c.setEvaluation(1); // Pass
    expect(c.state, PracticeState.referencePrompt);
    expect(c.currentIndex, 1);
    expect(c.currentPhraseId, 20);
    expect(events, ['guide:10', 'mic-open:10', 'mic-close:10', 'guide:20']);

    // Phrase 2 flows guide -> mic -> verdict with no taps at all.
    c.onBeat(5);
    c.onBeat(6); // 2 guide beats -> inputCapture
    expect(c.state, PracticeState.inputCapture);
    c.onBeat(7);
    c.onBeat(8); // 2 capture beats -> systemTransition
    expect(c.state, PracticeState.systemTransition);

    c.setEvaluation(0); // Fail on last phrase -> done
    expect(c.state, PracticeState.sessionComplete);
  });

  test('taps land within the wider lock tolerance', () {
    final c = make()..start();
    c.onBeat(0);
    // 0.2 is off-beat for scoring (>0.15) but within the 0.25 lock window.
    c.registerTap(0.2);
    c.registerTap(0.2);
    expect(c.state, PracticeState.referencePrompt);
  });

  test('rung routing: r2/r3 → caregiver (no mic), r4–r6 → mic, warm-up → neutral',
      () {
    for (final rung in Rung.values) {
      final fired = <String>[];
      final c = PracticeController(
        phraseIds: const [10],
        tapsToAdvance: 1,
        warmUpBeats: 0, // skip the hum warm-up in unit tests
        rungOf: (_) => rung,
        onEnterInputCapture: (id) => fired.add('mic'),
      )..start();
      c.onBeat(0);
      c.registerTap(0.0); // -> referencePrompt
      c.endReferencePrompt();
      if (rung.cleanCapture) {
        // r4–r7: solo production → mic.
        expect(c.state, PracticeState.inputCapture, reason: '$rung captures');
      } else if (rung.isJudged) {
        // r2/r3: judged but NO mic → straight to the caregiver verdict.
        expect(c.state, PracticeState.systemTransition,
            reason: '$rung judged, no mic');
        expect(fired, isEmpty, reason: '$rung must not open the mic');
      } else {
        // r0/r1 warm-up (never real words): the neutral auto-complete safety net.
        expect(c.state, PracticeState.sessionComplete,
            reason: '$rung auto-completes');
        expect(fired, isEmpty, reason: '$rung must not open the mic');
      }
    }
  });

  test('word counter groups consecutive reps by word (not by rep)', () {
    // Session built like the screen: one word (1 slot) then a 3-rep word.
    final c = PracticeController(phraseIds: const [10, 20, 20, 20])..start();
    expect(c.wordCount, 2); // two distinct words despite 4 slots
    expect(c.currentWordIndex, 0); // first word
    expect(c.phraseCount, 4); // raw slots, for contrast
  });

  test('a non-judged rung auto-completes neutral — never a blocking Fail', () {
    // Safety net: if a non-judged rung is ever reached it advances on exposure
    // with a neutral label, so poor/absent taps can't produce a Fail.
    final results = <AttemptResult>[];
    final c = PracticeController(
      phraseIds: const [10, 11, 12],
      tapsToAdvance: 1,
      warmUpBeats: 0, // skip the hum warm-up in unit tests
      rungOf: (_) => Rung.r0,
      onAttemptComplete: (r) => results.add(r),
    )..start();

    // Phrase 0: a single in-time tap leaves prep; r0 auto-completes on exposure.
    c.onBeat(0);
    c.registerTap(0.0);
    c.endReferencePrompt();

    // Phrase 1: only off-beat taps this round.
    c.registerTap(0.5);
    c.registerTap(0.5);
    c.endReferencePrompt();

    // Phrase 2: no taps at all.
    c.endReferencePrompt();

    // All three advanced (session ended) and NONE is a Fail/"Not yet".
    expect(results.length, 3);
    expect(results.every((r) => r.evaluationLabel != 0), isTrue,
        reason: 'r0 must never produce a Fail that blocks progress');
    expect(c.state, PracticeState.sessionComplete);
    // The tap-sync score is still captured for analytics (just never gates).
    expect(results.first.syncScore, isNotNull); // phrase 0 had a tap
    expect(results.last.syncScore, isNull); // phrase 2 had none
  });

  test('endReferencePrompt opens capture when the guide finishes', () {
    final c = make()..start();
    c.onBeat(0);
    c.registerTap(0.0);
    c.registerTap(0.0); // -> referencePrompt
    expect(c.state, PracticeState.referencePrompt);

    c.endReferencePrompt(); // guide finished before the beat fallback
    expect(c.state, PracticeState.inputCapture);
    expect(events, ['guide:10', 'mic-open:10']);

    // A stray second call must not transition again.
    c.endReferencePrompt();
    expect(c.state, PracticeState.inputCapture);
  });

  test('endCapture closes Input_Capture early on silence', () {
    final c = make()..start();
    c.onBeat(0);
    c.registerTap(0.0);
    c.registerTap(0.0); // -> referencePrompt
    c.onBeat(1);
    c.onBeat(2); // -> inputCapture
    expect(c.state, PracticeState.inputCapture);

    c.endCapture(); // mic auto-closed before the beat safety timeout
    expect(c.state, PracticeState.systemTransition);
    expect(events.last, 'mic-close:10');

    // A stray second call must not double-fire a transition.
    c.endCapture();
    expect(c.state, PracticeState.systemTransition);
  });

  test('onAttemptComplete fires with the phrase, sync score, and verdict', () {
    AttemptResult? result;
    final c = PracticeController(
      phraseIds: const [10],
      tapsToAdvance: 1,
      warmUpBeats: 0, // skip the hum warm-up in unit tests
      guideBeats: 1,
      captureBeats: 1,
      onAttemptComplete: (r) => result = r,
    )..start();

    c.onBeat(0);
    c.registerTap(0.0); // perfect tap -> referencePrompt
    c.onBeat(1); // -> inputCapture
    c.onBeat(2); // -> systemTransition
    c.setEvaluation(1); // Pass

    expect(result, isNotNull);
    expect(result!.phraseId, 10);
    expect(result!.evaluationLabel, 1);
    expect(result!.syncScore, 1.0);
    expect(result!.latencyMs, isNull); // mic not implemented yet
  });

  group('item 14 — park-and-switch / end-on-success queue mechanics', () {
    test('insertAfterCurrent splices a word in to be practiced next', () {
      final c = PracticeController(
        phraseIds: const [10, 20],
        tapsToAdvance: 1,
        warmUpBeats: 0, // skip the hum warm-up in unit tests
        guideBeats: 1,
        captureBeats: 1,
      )..start();
      expect(c.wordCount, 2);
      c.insertAfterCurrent([30, 30, 30]); // a 3-rep block of word 30
      expect(c.wordCount, 3);

      // Lock in and finish word 10 → the spliced word 30 comes BEFORE 20.
      c.onBeat(0);
      c.registerTap(0.0);
      c.onBeat(1);
      c.onBeat(2);
      c.setEvaluation(1); // finish 10
      expect(c.currentPhraseId, 30);
    });

    test('appendPhrases extends the session so it does not complete yet', () {
      var completed = false;
      final c = PracticeController(
        phraseIds: const [10],
        tapsToAdvance: 1,
        warmUpBeats: 0, // skip the hum warm-up in unit tests
        guideBeats: 1,
        captureBeats: 1,
        onEnterReferencePrompt: (_) {},
      )..start();
      expect(c.isOnLastWord, isTrue);

      // Before finishing the only word, append a closer (as end-on-success does).
      c.appendPhrases([20]);
      c.onBeat(0);
      c.registerTap(0.0);
      c.onBeat(1);
      c.onBeat(2);
      c.setEvaluation(0); // Fail on what WAS the last word
      // The session moved to the closer instead of completing.
      expect(c.state, isNot(PracticeState.sessionComplete));
      expect(c.currentPhraseId, 20);
      expect(completed, isFalse);
    });

    test('queue mutators are no-ops once the session is complete', () {
      final c = PracticeController(
        phraseIds: const [10],
        tapsToAdvance: 1,
        warmUpBeats: 0, // skip the hum warm-up in unit tests
        guideBeats: 1,
        captureBeats: 1,
      )..start();
      c.onBeat(0);
      c.registerTap(0.0);
      c.onBeat(1);
      c.onBeat(2);
      c.setEvaluation(1); // complete
      expect(c.state, PracticeState.sessionComplete);
      c.appendPhrases([20]);
      c.insertAfterCurrent([30]);
      expect(c.state, PracticeState.sessionComplete); // unchanged
    });
  });

  test('r7 (answer-the-question) opens the mic like the other solo rungs', () {
    final events = <String>[];
    final c = PracticeController(
      phraseIds: const [10],
      tapsToAdvance: 1,
      warmUpBeats: 0, // skip the hum warm-up in unit tests
      guideBeats: 1,
      captureBeats: 1,
      rungOf: (_) => Rung.r7, // top rung — a clean solo capture
      onEnterInputCapture: (id) => events.add('mic-open:$id'),
    )..start();

    c.onBeat(0);
    c.registerTap(0.0); // -> referencePrompt
    c.endReferencePrompt(); // probe finished → r7 is cleanCapture → inputCapture
    expect(c.state, PracticeState.inputCapture);
    expect(events, ['mic-open:10']);
  });

  test('captures the raw tap stream (with dwell) into the AttemptResult', () {
    AttemptResult? result;
    final c = PracticeController(
      phraseIds: const [10],
      tapsToAdvance: 1,
      warmUpBeats: 0, // skip the hum warm-up in unit tests
      guideBeats: 1,
      captureBeats: 1,
      onAttemptComplete: (r) => result = r,
    )..start();

    c.onBeat(0);
    c.registerTap(0.10); // tap 1 (down)
    c.registerTapRelease(); // …its release → dwell recorded
    // A second tap whose release is never seen → dwell stays null.
    c.registerTap(0.20);
    c.onBeat(1); // -> inputCapture
    c.onBeat(2); // -> systemTransition
    c.setEvaluation(1);

    expect(result, isNotNull);
    expect(result!.taps.length, 2);
    expect(result!.taps[0].phase, closeTo(0.10, 1e-9));
    expect(result!.taps[0].dwellMs, isNotNull); // release observed
    expect(result!.taps[0].dwellMs! >= 0, isTrue);
    expect(result!.taps[1].phase, closeTo(0.20, 1e-9));
    expect(result!.taps[1].dwellMs, isNull); // no release → not measured
    // Down times are monotonic (ms since the session's controller started).
    expect(result!.taps[0].downMs <= result!.taps[1].downMs, isTrue);
  });

  test('tap stream resets per phrase', () {
    final results = <AttemptResult>[];
    final c = PracticeController(
      phraseIds: const [10, 20],
      tapsToAdvance: 1,
      warmUpBeats: 0, // skip the hum warm-up in unit tests
      guideBeats: 1,
      captureBeats: 1,
      onAttemptComplete: results.add,
    )..start();

    // Phrase 1: two taps.
    c.onBeat(0);
    c.registerTap(0.0);
    c.registerTap(0.1);
    c.onBeat(1);
    c.onBeat(2);
    c.setEvaluation(1); // finish phrase 1 -> phrase 2 (skips Preparation)

    // Phrase 2: one tap. It must NOT carry phrase 1's taps.
    c.registerTap(0.3);
    c.onBeat(3);
    c.onBeat(4);
    c.setEvaluation(1);

    expect(results.length, 2);
    expect(results[0].taps.length, 2);
    expect(results[1].taps.length, 1);
    expect(results[1].taps.single.phase, closeTo(0.3, 1e-9));
  });

  test('sync score reflects tap accuracy and resets per phrase', () {
    final c = make()..start();
    c.onBeat(0);
    c.registerTap(0.0);
    c.registerTap(0.0); // perfect taps -> referencePrompt
    expect(c.currentSyncScore, 1.0);

    // Advance through to next phrase; score should reset (no taps yet -> null).
    c.onBeat(1);
    c.onBeat(2);
    c.onBeat(3);
    c.onBeat(4);
    c.setEvaluation(2);
    expect(c.currentIndex, 1);
    expect(c.currentSyncScore, isNull);
  });
}
