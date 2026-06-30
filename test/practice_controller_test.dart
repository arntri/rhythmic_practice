import 'package:flutter_test/flutter_test.dart';
import 'package:rhythmic_practice/practice/practice_controller.dart';
import 'package:rhythmic_practice/practice/progression.dart';

void main() {
  // Records which seams fired, with the phrase id passed to them.
  late List<String> events;

  PracticeController make() => PracticeController(
        phraseIds: const [10, 20],
        tapsToAdvance: 2,
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

  test('rung routing: r0 auto-completes, r1–r3 caregiver (no mic), r4–r6 mic',
      () {
    for (final rung in Rung.values) {
      final fired = <String>[];
      final c = PracticeController(
        phraseIds: const [10],
        tapsToAdvance: 1,
        rungOf: (_) => rung,
        onEnterInputCapture: (id) => fired.add('mic'),
      )..start();
      c.onBeat(0);
      c.registerTap(0.0); // -> referencePrompt
      c.endReferencePrompt();
      if (rung.cleanCapture) {
        // r4–r6: solo production → mic.
        expect(c.state, PracticeState.inputCapture, reason: '$rung captures');
      } else if (rung.isJudged) {
        // r1–r3: judged but NO mic → straight to the caregiver verdict.
        expect(c.state, PracticeState.systemTransition,
            reason: '$rung judged, no mic');
        expect(fired, isEmpty, reason: '$rung must not open the mic');
      } else {
        // r0: the only un-judged rung — auto-completes (single phrase → done).
        expect(c.state, PracticeState.sessionComplete,
            reason: '$rung auto-completes');
        expect(fired, isEmpty, reason: '$rung must not open the mic');
      }
    }
  });

  test('word counter groups consecutive reps (r0 = 1 visit, r1–r6 = 3)', () {
    // Session built like the screen: a r0 word (1 slot) then a 3-rep word.
    final c = PracticeController(phraseIds: const [10, 20, 20, 20])..start();
    expect(c.wordCount, 2); // two distinct words despite 4 slots
    expect(c.currentWordIndex, 0); // first word
    expect(c.phraseCount, 4); // raw slots, for contrast
  });

  test('r0 advances on exposure — poor or absent taps NEVER produce a Fail', () {
    // Invariant: an auto-judged rung must never block progress on tap performance
    // (a user with hand weakness must not be trapped on r0).
    final results = <AttemptResult>[];
    final c = PracticeController(
      phraseIds: const [10, 11, 12],
      tapsToAdvance: 1,
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
