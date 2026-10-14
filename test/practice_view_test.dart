// Widget test for the practice UI. We drive the controller by hand (no real
// metronome, no DB) and check that each state renders the right thing.

import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:rhythmic_practice/data/models.dart';
import 'package:rhythmic_practice/metronome/metronome_engine.dart';
import 'package:rhythmic_practice/practice/practice_controller.dart';
import 'package:rhythmic_practice/practice/mit_sequence.dart';
import 'package:rhythmic_practice/screens/practice_view.dart';
import 'package:rhythmic_practice/widgets/slide_to_unlock.dart';

// A tiny host that supplies the engine (which needs a vsync) and renders the
// view. The test reaches the controller through [controller].
class _Host extends StatefulWidget {
  const _Host({
    required this.controller,
    required this.text,
    this.photos = const {},
    this.targetDisplay = TargetDisplay.both,
    this.syllableCount = const {},
    this.stressIndex = const {},
    this.humPass = -1,
    this.onCaregiverUnlock,
  });
  final PracticeController controller;
  final Map<int, String> text;
  final Map<int, Uint8List> photos;
  final TargetDisplay targetDisplay;
  final Map<int, int> syllableCount;
  final Map<int, int?> stressIndex;
  final int humPass;
  final VoidCallback? onCaregiverUnlock;

  @override
  State<_Host> createState() => _HostState();
}

class _HostState extends State<_Host> with SingleTickerProviderStateMixin {
  late final MetronomeEngine engine;

  @override
  void initState() {
    super.initState();
    engine = MetronomeEngine(vsync: this, onBeat: widget.controller.onBeat);
  }

  @override
  void dispose() {
    engine.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => MaterialApp(
    home: Scaffold(
      body: PracticeView(
        engine: engine,
        controller: widget.controller,
        phraseText: widget.text,
        photoByPhrase: widget.photos,
        targetDisplay: widget.targetDisplay,
        syllableCountByPhrase: widget.syllableCount,
        stressIndexByPhrase: widget.stressIndex,
        humPass: widget.humPass,
        onCaregiverUnlock: widget.onCaregiverUnlock,
      ),
    ),
  );
}

void main() {
  testWidgets('renders each state and completes a one-item session', (
    tester,
  ) async {
    final controller = PracticeController(
      phraseHumBeats: 0, // skip the hum step in unit tests
      phraseIds: const [10],
      tapsToAdvance: 1,
      warmUpBeats: 0,
      guideBeats: 1,
      captureBeats: 1,
    );

    await tester.pumpWidget(
      _Host(controller: controller, text: const {10: 'Help'}),
    );
    controller.start();
    await tester.pump();

    // State_1: the warm-up tap arena (feel the beat).
    expect(find.text('Feel the beat'), findsOneWidget);

    // An in-time tap locks the beat; a zero-length warm-up flows straight into
    // the item's first step (State_2).
    controller.onBeat(0);
    await tester.tap(find.byType(PracticeView));
    await tester.pump();
    expect(find.text('Help'), findsOneWidget); // phrase shown large
    expect(controller.currentStep, MitStep.intoneUnison);

    // Walk the whole Level II sequence, as a real session does — every item
    // runs the lot in one sitting, and each judged step takes two clean passes.
    var beat = 1;
    var sawRecording = false;
    while (controller.state != PracticeState.sessionComplete) {
      final records = controller.currentStep.cleanCapture;
      controller.onBeat(beat++); // the guide finishes
      await tester.pump();
      if (records) {
        // Only the steps that yield a clean solo production open the mic; the
        // unison steps go straight to the verdict (the model would be recorded).
        expect(find.text('Recording — say it once'), findsOneWidget);
        sawRecording = true;
        controller.onBeat(beat++); // capture closes
        await tester.pump();
      }
      // Caregiver bar: Accept (Pass=1) / Unsure (2) / Not yet (Fail=0).
      expect(find.text('Yes'), findsOneWidget);
      expect(find.text('Maybe'), findsOneWidget);
      expect(find.text('Not yet'), findsOneWidget);
      await tester.tap(find.text('Yes'));
      await tester.pump();
    }

    expect(sawRecording, isTrue);
    expect(find.text('That\u2019s today done'), findsOneWidget);
  });

  // Drive a controller to the prompt for a given MIT step, then run [checks].
  // The step is reached with the presenter's jump rather than by producing every
  // earlier step — the view is what's under test here, not the sequence.
  Future<void> pumpAtStep(
    WidgetTester tester,
    MitStep step,
    Future<void> Function() checks,
  ) async {
    final level = stepsFor(MitLevel.two).contains(step)
        ? MitLevel.two
        : MitLevel.three;
    final controller = PracticeController(
      phraseHumBeats: 0, // skip the hum step in unit tests
      phraseIds: const [10],
      tapsToAdvance: 1,
      warmUpBeats: 0,
      guideBeats: 1,
      captureBeats: 1,
      level: level,
    );
    await tester.pumpWidget(
      _Host(controller: controller, text: const {10: 'Help'}),
    );
    controller.start();
    await tester.pump();
    controller.onBeat(0);
    await tester.tap(find.byType(PracticeView));
    controller.demoJumpToStep(step);
    await tester.pump();
    await checks();
  }

  testWidgets('warm-up TAP arena (preparation): ring + "Feel the beat", no word', (
    tester,
  ) async {
    // The element-free arena is now the session WARM-UP, keyed on STATE (not a
    // per-word rung). Preparation = the tap phase: the word is withheld and the
    // pulse ring is the only target.
    final controller = PracticeController(
      phraseHumBeats: 0, // skip the hum step in unit tests
      phraseIds: const [10],
      tapsToAdvance: 1,
      warmUpBeats: 4, // a real warm-up so we can observe its phases
    );
    await tester.pumpWidget(
      _Host(controller: controller, text: const {10: 'Help'}),
    );
    controller.start();
    await tester.pump();
    expect(find.text('Help'), findsNothing); // word withheld during warm-up
    expect(find.text('Feel the beat'), findsOneWidget); // the tap cue
    expect(find.text('Hum along'), findsNothing);
    expect(find.byKey(const Key('ef_pulse_ring')), findsOneWidget); // target
  });

  testWidgets('warm-up HUM arena (warmUpHum): ring + "Hum along", no word', (
    tester,
  ) async {
    final controller = PracticeController(
      phraseHumBeats: 0, // skip the hum step in unit tests
      phraseIds: const [10],
      tapsToAdvance: 1,
      warmUpBeats: 4,
    );
    await tester.pumpWidget(
      _Host(controller: controller, text: const {10: 'Help'}),
    );
    controller.start();
    await tester.pump();
    controller.onBeat(0);
    await tester.tap(find.byType(PracticeView)); // lock the beat → hum phase
    await tester.pump();
    expect(controller.state, PracticeState.warmUpHum);
    expect(find.text('Help'), findsNothing); // still no word
    expect(find.text('Hum along'), findsOneWidget); // the hum cue
    expect(find.text('Feel the beat'), findsNothing);
    expect(find.byKey(const Key('ef_pulse_ring')), findsOneWidget);
  });

  testWidgets('a judged step shows the word', (tester) async {
    await pumpAtStep(tester, MitStep.immediateRepeat, () async {
      expect(find.text('Help'), findsOneWidget);
      expect(find.text('Feel the beat'), findsNothing);
    });
  });

  testWidgets(
    'melody cue shows for a multi-syllable phrase with a stress index',
    (tester) async {
      final controller = PracticeController(
        phraseHumBeats: 0, // skip the hum step in unit tests
        phraseIds: const [10],
        tapsToAdvance: 1,
        warmUpBeats: 0,
        guideBeats: 1,
        captureBeats: 1,
      );
      await tester.pumpWidget(
        _Host(
          controller: controller,
          text: const {10: 'Water'},
          syllableCount: const {10: 2},
          stressIndex: const {10: 0},
        ),
      );
      controller.start();
      await tester.pump();
      controller.onBeat(0);
      await tester.tap(find.byType(PracticeView));
      await tester.pump(); // referencePrompt
      expect(find.byKey(const Key('melody_cue')), findsOneWidget);
    },
  );

  testWidgets('no staff for a single-syllable phrase — nothing to rise above', (
    tester,
  ) async {
    final controller = PracticeController(
      phraseHumBeats: 0, // skip the hum step in unit tests
      phraseIds: const [10],
      tapsToAdvance: 1,
      warmUpBeats: 0,
      guideBeats: 1,
      captureBeats: 1,
    );
    await tester.pumpWidget(
      _Host(
        controller: controller,
        text: const {10: 'Help'},
        syllableCount: const {10: 1}, // single syllable
        stressIndex: const {10: 0},
      ),
    );
    controller.start();
    await tester.pump();
    controller.onBeat(0);
    await tester.tap(find.byType(PracticeView));
    await tester.pump();
    expect(find.byKey(const Key('melody_cue')), findsNothing);
  });

  testWidgets('a phrase with no designated tune still shows its RHYTHM', (
    tester,
  ) async {
    // A caregiver's own phrase with no authored guide has a syllable count but
    // no high note. One syllable per beat is still true and still what the hand
    // is tapping, so the staff flattens rather than vanishing — which also keeps
    // its absence meaning one thing only: the melody has been withdrawn.
    final controller = PracticeController(
      phraseHumBeats: 0,
      phraseIds: const [10],
      tapsToAdvance: 1,
      warmUpBeats: 0,
      guideBeats: 1,
      captureBeats: 1,
    );
    await tester.pumpWidget(
      _Host(
        controller: controller,
        text: const {10: 'Water'},
        syllableCount: const {10: 2},
        stressIndex: const {10: null}, // no tune designated
      ),
    );
    controller.start();
    await tester.pump();
    controller.onBeat(0);
    await tester.tap(find.byType(PracticeView));
    await tester.pump();
    expect(find.byKey(const Key('melody_cue')), findsOneWidget);
  });

  testWidgets('the staff is gone for both of the steps that come off the tune', (
    tester,
  ) async {
    // The staff carries both of MIT's ingredients on one row: pitch vertically,
    // rhythm horizontally. It is withdrawn entirely at the two bridge steps —
    // "Never shows the melody contour. It is the thing being withdrawn." What
    // is left holding the phrase up there is the pulse and the tapping.
    final controller = PracticeController(
      phraseHumBeats: 0,
      phraseIds: const [10],
      level: MitLevel.three,
      tapsToAdvance: 1,
      warmUpBeats: 0,
      guideBeats: 1,
      captureBeats: 1,
    );
    await tester.pumpWidget(
      _Host(
        controller: controller,
        text: const {10: 'Water'},
        syllableCount: const {10: 2},
        stressIndex: const {10: 0},
      ),
    );
    controller.start();
    await tester.pump();
    controller.onBeat(0);
    await tester.tap(find.byType(PracticeView));
    await tester.pump();

    // Delayed repeat: still sung, so the contour is up.
    expect(controller.currentStep, MitStep.delayedRepeat);
    expect(find.byKey(const Key('melody_cue')), findsOneWidget);

    // Sprechgesang: the tune is the thing being taken away, so the element that
    // draws it goes with it.
    controller.demoJumpToStep(MitStep.sprechgesang);
    await tester.pump();
    expect(find.byKey(const Key('melody_cue')), findsNothing);

    // Spoken production: nothing left to scaffold with.
    controller.demoJumpToStep(MitStep.spokenProduction);
    await tester.pump();
    expect(find.byKey(const Key('melody_cue')), findsNothing);
  });

  testWidgets("the on-screen stage label is the current step's own title", (
    tester,
  ) async {
    // The rendered stage derives from the same step→label map everything else
    // uses, so the two can never disagree for a given step.
    await pumpAtStep(tester, MitStep.immediateRepeat, () async {
      expect(
        find.textContaining(MitStep.immediateRepeat.title),
        findsWidgets,
      ); // "Repeat after the model"
    });
    await pumpAtStep(tester, MitStep.probeQuestion, () async {
      expect(
        find.textContaining(MitStep.probeQuestion.title),
        findsWidgets,
      ); // "Answer the question"
    });
  });

  testWidgets('counter shows the item and the corner shows the STEP', (
    tester,
  ) async {
    final controller = PracticeController(
      phraseHumBeats: 0, // skip the hum step in unit tests
      phraseIds: const [10, 20], // one entry per item — reps are not in the list
      tapsToAdvance: 1,
      warmUpBeats: 0,
      guideBeats: 1,
      captureBeats: 1,
    );
    await tester.pumpWidget(
      _Host(controller: controller, text: const {10: 'Help'}),
    );
    controller.start();
    await tester.pump();
    controller.onBeat(0);
    await tester.tap(find.byType(PracticeView));
    controller.demoJumpToStep(MitStep.immediateRepeat);
    await tester.pump();

    expect(find.text('Word 1 of 2'), findsOneWidget);
    // The corner shows where in the SEQUENCE we are — a position in this item's
    // run, not a rung the word has been assigned to. Level II's sequence puts
    // the immediate repeat fourth.
    expect(
      find.textContaining('Step 4 · ${MitStep.immediateRepeat.title}'),
      findsOneWidget,
    );
  });

  testWidgets('a name card shows the photo above the name', (tester) async {
    final controller = PracticeController(
      phraseHumBeats: 0, // skip the hum step in unit tests
      phraseIds: const [10],
      tapsToAdvance: 1,
      warmUpBeats: 0,
      guideBeats: 1,
      captureBeats: 1,
    );
    await tester.pumpWidget(
      _Host(
        controller: controller,
        text: const {10: 'Sarah'},
        photos: {10: _kPng1x1},
      ),
    );
    controller.start();
    await tester.pump();
    controller.onBeat(0);
    await tester.tap(find.byType(PracticeView));
    await tester.pump();

    expect(find.byType(Image), findsOneWidget); // photo shown
    expect(find.text('Sarah'), findsOneWidget); // name still shown beneath
  });

  // Drive to the reference prompt at r4 with a display preference + photos, run [checks].
  Future<void> pumpTarget(
    WidgetTester tester, {
    required TargetDisplay display,
    Map<int, Uint8List> photos = const {},
    required Future<void> Function() checks,
  }) async {
    final controller = PracticeController(
      phraseHumBeats: 0, // skip the hum step in unit tests
      phraseIds: const [10],
      tapsToAdvance: 1,
      warmUpBeats: 0,
      guideBeats: 1,
      captureBeats: 1,
    );
    await tester.pumpWidget(
      _Host(
        controller: controller,
        text: const {10: 'Sarah'},
        photos: photos,
        targetDisplay: display,
      ),
    );
    controller.start();
    await tester.pump();
    controller.onBeat(0);
    await tester.tap(find.byType(PracticeView));
    await tester.pump();
    await checks();
  }

  testWidgets('display=picture shows the photo only (no word)', (tester) async {
    await pumpTarget(
      tester,
      display: TargetDisplay.picture,
      photos: {10: _kPng1x1},
      checks: () async {
        expect(find.byType(Image), findsOneWidget);
        expect(find.text('Sarah'), findsNothing);
      },
    );
  });

  testWidgets('display=picture falls back to the word when no photo', (
    tester,
  ) async {
    await pumpTarget(
      tester,
      display: TargetDisplay.picture,
      checks: () async {
        expect(find.byType(Image), findsNothing);
        expect(find.text('Sarah'), findsOneWidget);
      },
    );
  });

  testWidgets('display=word shows the word only (no photo)', (tester) async {
    await pumpTarget(
      tester,
      display: TargetDisplay.word,
      photos: {10: _kPng1x1},
      checks: () async {
        expect(find.byType(Image), findsNothing);
        expect(find.text('Sarah'), findsOneWidget);
      },
    );
  });

  testWidgets('display=both shows the photo and the word', (tester) async {
    await pumpTarget(
      tester,
      display: TargetDisplay.both,
      photos: {10: _kPng1x1},
      checks: () async {
        expect(find.byType(Image), findsOneWidget);
        expect(find.text('Sarah'), findsOneWidget);
      },
    );
  });

  // ---- MIT step 1: the per-phrase hum -------------------------------------

  group('the hum step', () {
    PracticeController humming() => PracticeController(
      phraseIds: const [10],
      tapsToAdvance: 1,
      warmUpBeats: 0,
      phraseHumBeats: 12,
    );

    testWidgets('shows the item so the melody has something to belong to', (
      tester,
    ) async {
      // MIT presents the target and THEN hands over its tune. What the step
      // withholds is the spoken model, not the item's identity — the person is
      // meant to hold the phrase in mind against the melody, which they cannot
      // do if they don't know which phrase it is. (An earlier version of this
      // screen hid the word and the picture both; that was ours, not MIT's.)
      final c = humming()..start();
      await tester.pumpWidget(
        _Host(
          controller: c,
          text: const {10: 'Water'},
          syllableCount: const {10: 2},
          stressIndex: const {10: 0},
        ),
      );
      c.registerTap(0.0);
      await tester.pump();

      expect(c.state, PracticeState.phraseHum);
      expect(find.byKey(const Key('phrase_hum')), findsOneWidget);
      expect(find.text('Water'), findsOneWidget);
      // The contour is on screen and enlarged — here the tune is the content,
      // not a reinforcement of a word being read.
      expect(find.byKey(const Key('melody_cue')), findsOneWidget);
    });

    testWidgets('prefers the PICTURE as the referent when there is one', (
      tester,
    ) async {
      // The picture is what MIT actually puts in front of the patient, and it
      // works for someone who cannot read. The written word is the fallback.
      final c = humming()..start();
      await tester.pumpWidget(
        _Host(
          controller: c,
          text: const {10: 'Water'},
          photos: {10: _kPng1x1},
          targetDisplay: TargetDisplay.picture,
          syllableCount: const {10: 2},
          stressIndex: const {10: 0},
        ),
      );
      c.registerTap(0.0);
      await tester.pump();

      expect(find.byType(Image), findsOneWidget);
      expect(find.text('Water'), findsNothing);
    });

    testWidgets('the second pass reads as "again", not as a stutter', (
      tester,
    ) async {
      final c = humming()..start();
      await tester.pumpWidget(
        _Host(
          controller: c,
          text: const {10: 'Water'},
          syllableCount: const {10: 2},
          stressIndex: const {10: 0},
          humPass: 0,
        ),
      );
      c.registerTap(0.0);
      await tester.pump();
      expect(find.text('Listen to the tune'), findsOneWidget);
      expect(find.text('Again'), findsNothing);

      await tester.pumpWidget(
        _Host(
          controller: c,
          text: const {10: 'Water'},
          syllableCount: const {10: 2},
          stressIndex: const {10: 0},
          humPass: 1,
        ),
      );
      await tester.pump();
      expect(find.text('Again'), findsOneWidget);
    });

    testWidgets('hands over to the first judged step when the hum ends', (
      tester,
    ) async {
      final c = humming()..start();
      await tester.pumpWidget(
        _Host(
          controller: c,
          text: const {10: 'Water'},
          syllableCount: const {10: 2},
          stressIndex: const {10: 0},
        ),
      );
      c.registerTap(0.0);
      await tester.pump();
      expect(find.byKey(const Key('phrase_hum')), findsOneWidget);

      c.endPhraseHum();
      await tester.pump();
      expect(c.state, PracticeState.referencePrompt);
      expect(c.currentStep, MitStep.intoneUnison);
      expect(find.text('Water'), findsOneWidget);
      // The referent carries across the handover unchanged; what changes is
      // that the model now says the words instead of humming them.
      expect(find.byKey(const Key('phrase_hum')), findsNothing);
      expect(find.text('Say it together'), findsOneWidget);
    });
  });

  // ---- the caregiver's way out ---------------------------------------------

  group('caregiver slide-out', () {
    PracticeController running() => PracticeController(
      phraseIds: const [10],
      tapsToAdvance: 1,
      warmUpBeats: 0,
      phraseHumBeats: 0,
      guideBeats: 1,
      captureBeats: 1,
    );

    testWidgets('is reachable from the practice layout, not just the warm-up', (
      tester,
    ) async {
      // It used to be drawn ONLY in the element-free warm-up arena, so once the
      // first word started there was no way out of the patient's screen.
      var opened = 0;
      final c = running();
      await tester.pumpWidget(
        _Host(
          controller: c,
          text: const {10: 'Water'},
          onCaregiverUnlock: () => opened++,
        ),
      );
      c.start();
      await tester.pump();
      expect(find.byType(SlideToUnlock), findsOneWidget, reason: 'warm-up');

      c.onBeat(0);
      await tester.tap(find.byType(PracticeView));
      await tester.pump();
      expect(c.state, PracticeState.referencePrompt);
      expect(find.byType(SlideToUnlock), findsOneWidget, reason: 'practice');

      // A drag most of the way across opens it; a tap must not.
      await tester.tap(find.byKey(const Key('slide_thumb')));
      await tester.pump();
      expect(opened, 0, reason: 'a tap must never open the caregiver panel');

      await tester.drag(find.byKey(const Key('slide_thumb')), const Offset(400, 0));
      await tester.pump();
      expect(opened, 1);
    });

    testWidgets('stays reachable DURING the verdict, sharing the right edge', (
      tester,
    ) async {
      // The verdict is when a caregiver is most likely to want out, and the
      // verdict dock is pinned to the same edge — so the dock is inset rather
      // than the control being hidden.
      final c = running();
      await tester.pumpWidget(
        _Host(
          controller: c,
          text: const {10: 'Water'},
          onCaregiverUnlock: () {},
        ),
      );
      c.start();
      await tester.pump();
      c.onBeat(0);
      await tester.tap(find.byType(PracticeView));
      c.endReferencePrompt();
      await tester.pump();

      expect(c.state, PracticeState.systemTransition);
      expect(find.text('Yes'), findsOneWidget);
      expect(find.byType(SlideToUnlock), findsOneWidget);

      // And they do not overlap.
      final unlock = tester.getRect(find.byType(SlideToUnlock));
      final dock = tester.getRect(find.text('Yes'));
      expect(unlock.overlaps(dock), isFalse);
    });

    testWidgets('is absent when no caregiver entry is wired', (tester) async {
      final c = running();
      await tester.pumpWidget(_Host(controller: c, text: const {10: 'Water'}));
      c.start();
      await tester.pump();
      c.onBeat(0);
      await tester.tap(find.byType(PracticeView));
      await tester.pump();
      expect(find.byType(SlideToUnlock), findsNothing);
    });
  });

  // ---- hand tapping is cued through productions, and only through them -----

  group('the hand-tapping cue', () {
    PracticeController tapping({MitLevel level = MitLevel.two}) =>
        PracticeController(
          phraseIds: const [10],
          level: level,
          tapsToAdvance: 1,
          warmUpBeats: 0,
          phraseHumBeats: 12,
        );

    const cue = 'Tap their left hand on each syllable';

    testWidgets('appears with the hum, the model and the mic', (tester) async {
      final c = tapping()..start();
      await tester.pumpWidget(_Host(controller: c, text: const {10: 'Water'}));

      c.registerTap(0.0);
      await tester.pump();
      expect(c.state, PracticeState.phraseHum);
      c.beginProduction(); // the melody starts sounding
      await tester.pump();
      expect(find.text(cue), findsOneWidget, reason: 'MIT taps through the hum');

      c.endProduction();
      c.endPhraseHum();
      c.demoJumpToStep(MitStep.immediateRepeat); // a step that opens the mic
      c.beginProduction(); // the model starts
      await tester.pump();
      expect(find.text(cue), findsOneWidget, reason: 'and under the model');

      c.endProduction();
      c.endReferencePrompt();
      await tester.pump();
      expect(c.state, PracticeState.inputCapture);
      c.beginProduction(); // she speaks
      await tester.pump();
      expect(
        find.text(cue),
        findsOneWidget,
        reason: 'and while the person produces — the one that matters most',
      );
    });

    testWidgets('is absent in the gaps between productions', (tester) async {
      // The change: the six-second retrieval silence at the delayed repeat, and
      // every other gap, must NOT ask for taps. MIT's hand rests between
      // phrases. Level III opens straight on the delayed repeat.
      final c = tapping(level: MitLevel.three)..start();
      await tester.pumpWidget(_Host(controller: c, text: const {10: 'Water'}));

      c.registerTap(0.0);
      await tester.pump();
      expect(c.currentStep, MitStep.delayedRepeat);
      expect(
        find.text(cue),
        findsNothing,
        reason: 'the prompt state alone is not the model sounding',
      );

      c.beginProduction();
      c.endProduction(); // the model has finished; the long silence begins
      await tester.pump();
      expect(c.state, PracticeState.referencePrompt);
      expect(
        find.text(cue),
        findsNothing,
        reason: 'the retrieval silence is held, not tapped',
      );
    });

    testWidgets('steps aside for the caregiver verdict', (tester) async {
      final c = tapping()..start();
      await tester.pumpWidget(_Host(controller: c, text: const {10: 'Water'}));
      c.registerTap(0.0);
      c.endPhraseHum();
      c.demoJumpToStep(MitStep.immediateRepeat);
      c.endReferencePrompt();
      c.beginProduction();
      c.endCapture();
      await tester.pump();

      expect(c.state, PracticeState.systemTransition);
      expect(
        find.text(cue),
        findsNothing,
        reason: 'the caregiver needs that hand to tap a verdict',
      );
    });

    testWidgets('is cued at the unison steps too, where nothing is recorded', (
      tester,
    ) async {
      // The step most at risk of losing the tapping: no mic, so there is no
      // recording to pace — but MIT taps here exactly as everywhere else.
      final c = tapping()..start();
      await tester.pumpWidget(_Host(controller: c, text: const {10: 'Water'}));
      c.registerTap(0.0);
      c.endPhraseHum();
      c.beginProduction();
      await tester.pump();

      expect(c.state, PracticeState.referencePrompt);
      expect(find.text(cue), findsOneWidget);
    });
  });
}

/// A minimal valid 1×1 transparent PNG, so Image.memory has real bytes to decode.
final Uint8List _kPng1x1 = Uint8List.fromList(const <int>[
  0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A, 0x00, 0x00, 0x00, 0x0D, //
  0x49, 0x48, 0x44, 0x52, 0x00, 0x00, 0x00, 0x01, 0x00, 0x00, 0x00, 0x01,
  0x08, 0x06, 0x00, 0x00, 0x00, 0x1F, 0x15, 0xC4, 0x89, 0x00, 0x00, 0x00,
  0x0A, 0x49, 0x44, 0x41, 0x54, 0x78, 0x9C, 0x63, 0x00, 0x01, 0x00, 0x00,
  0x05, 0x00, 0x01, 0x0D, 0x0A, 0x2D, 0xB4, 0x00, 0x00, 0x00, 0x00, 0x49,
  0x45, 0x4E, 0x44, 0xAE, 0x42, 0x60, 0x82,
]);
