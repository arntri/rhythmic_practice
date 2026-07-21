// Widget test for the practice UI. We drive the controller by hand (no real
// metronome, no DB) and check that each state renders the right thing.

import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:rhythmic_practice/data/models.dart';
import 'package:rhythmic_practice/metronome/metronome_engine.dart';
import 'package:rhythmic_practice/practice/practice_controller.dart';
import 'package:rhythmic_practice/practice/progression.dart';
import 'package:rhythmic_practice/screens/practice_view.dart';

// A tiny host that supplies the engine (which needs a vsync) and renders the
// view. The test reaches the controller through [controller].
class _Host extends StatefulWidget {
  const _Host(
      {required this.controller,
      required this.text,
      this.photos = const {},
      this.targetDisplay = TargetDisplay.both,
      this.repsPerBlock = 1,
      this.syllableCount = const {},
      this.stressIndex = const {}});
  final PracticeController controller;
  final Map<int, String> text;
  final Map<int, Uint8List> photos;
  final TargetDisplay targetDisplay;
  final int repsPerBlock;
  final Map<int, int> syllableCount;
  final Map<int, int?> stressIndex;

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
            repsPerBlock: widget.repsPerBlock,
            syllableCountByPhrase: widget.syllableCount,
            stressIndexByPhrase: widget.stressIndex,
          ),
        ),
      );
}

void main() {
  testWidgets('renders each state and completes a one-phrase session',
      (tester) async {
    final controller = PracticeController(
      phraseIds: const [10],
      tapsToAdvance: 1,
      warmUpBeats: 0,
      guideBeats: 1,
      captureBeats: 1,
    );

    await tester.pumpWidget(_Host(controller: controller, text: const {10: 'Help'}));
    controller.start();
    await tester.pump();

    // State_1: the warm-up tap arena (feel the beat).
    expect(find.text('Feel the beat'), findsOneWidget);

    // An in-time tap locks the beat; a zero-length warm-up flows straight into
    // the first word (State_2).
    controller.onBeat(0);
    await tester.tap(find.byType(PracticeView));
    await tester.pump();
    expect(find.text('Help'), findsOneWidget); // phrase shown large

    // Guide placeholder (1 beat) -> State_3 (recording).
    controller.onBeat(1);
    await tester.pump();
    expect(find.text('Recording — say it once'), findsOneWidget);

    // Capture placeholder (1 beat) -> State_4 (caregiver).
    controller.onBeat(2);
    await tester.pump();
    // Caregiver bar: Accept (Pass=1) / Unsure (2) / Not yet (Fail=0).
    expect(find.text('Accept'), findsOneWidget);
    expect(find.text('Unsure'), findsOneWidget);
    expect(find.text('Not yet'), findsOneWidget);

    // Caregiver taps "Accept" (Pass) -> only one phrase, so session completes.
    await tester.tap(find.text('Accept'));
    await tester.pump();
    expect(find.text('Session complete'), findsOneWidget);
  });

  // Drive a controller to the reference-prompt state at a given rung, then run
  // [checks].
  Future<void> pumpAtRung(WidgetTester tester, Rung rung,
      Future<void> Function() checks) async {
    final controller = PracticeController(
      phraseIds: const [10],
      tapsToAdvance: 1,
      warmUpBeats: 0,
      guideBeats: 1,
      captureBeats: 1,
      rungOf: (_) => rung,
    );
    await tester.pumpWidget(_Host(controller: controller, text: const {10: 'Help'}));
    controller.start();
    await tester.pump();
    controller.onBeat(0);
    await tester.tap(find.byType(PracticeView));
    await tester.pump();
    await checks();
  }

  testWidgets('warm-up TAP arena (preparation): ring + "Feel the beat", no word',
      (tester) async {
    // The element-free arena is now the session WARM-UP, keyed on STATE (not a
    // per-word rung). Preparation = the tap phase: the word is withheld and the
    // pulse ring is the only target.
    final controller = PracticeController(
      phraseIds: const [10],
      tapsToAdvance: 1,
      warmUpBeats: 4, // a real warm-up so we can observe its phases
      rungOf: (_) => Rung.r2,
    );
    await tester.pumpWidget(_Host(controller: controller, text: const {10: 'Help'}));
    controller.start();
    await tester.pump();
    expect(find.text('Help'), findsNothing); // word withheld during warm-up
    expect(find.text('Feel the beat'), findsOneWidget); // the tap cue
    expect(find.text('Hum along'), findsNothing);
    expect(find.byKey(const Key('ef_pulse_ring')), findsOneWidget); // target
  });

  testWidgets('warm-up HUM arena (warmUpHum): ring + "Hum along", no word',
      (tester) async {
    final controller = PracticeController(
      phraseIds: const [10],
      tapsToAdvance: 1,
      warmUpBeats: 4,
      rungOf: (_) => Rung.r2,
    );
    await tester.pumpWidget(_Host(controller: controller, text: const {10: 'Help'}));
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

  testWidgets('r2+ shows the word', (tester) async {
    await pumpAtRung(tester, Rung.r4, () async {
      expect(find.text('Help'), findsOneWidget);
      expect(find.text('Feel the beat'), findsNothing);
    });
  });

  testWidgets('melody cue shows for a multi-syllable phrase with a stress index',
      (tester) async {
    final controller = PracticeController(
      phraseIds: const [10],
      tapsToAdvance: 1,
      warmUpBeats: 0,
      guideBeats: 1,
      captureBeats: 1,
      rungOf: (_) => Rung.r4,
    );
    await tester.pumpWidget(_Host(
      controller: controller,
      text: const {10: 'Water'},
      syllableCount: const {10: 2},
      stressIndex: const {10: 0},
    ));
    controller.start();
    await tester.pump();
    controller.onBeat(0);
    await tester.tap(find.byType(PracticeView));
    await tester.pump(); // referencePrompt
    expect(find.byKey(const Key('melody_cue')), findsOneWidget);
  });

  testWidgets('no melody cue for a single-syllable / undesignated phrase',
      (tester) async {
    final controller = PracticeController(
      phraseIds: const [10],
      tapsToAdvance: 1,
      warmUpBeats: 0,
      guideBeats: 1,
      captureBeats: 1,
      rungOf: (_) => Rung.r4,
    );
    await tester.pumpWidget(_Host(
      controller: controller,
      text: const {10: 'Help'},
      syllableCount: const {10: 1}, // single syllable — nothing to rise above
      stressIndex: const {10: 0},
    ));
    controller.start();
    await tester.pump();
    controller.onBeat(0);
    await tester.tap(find.byType(PracticeView));
    await tester.pump();
    expect(find.byKey(const Key('melody_cue')), findsNothing);
  });

  testWidgets('the on-screen stage label is the current rung\'s own title',
      (tester) async {
    // The rendered stage derives from the same rung→label map the announcement
    // uses, so the two can never disagree for a given rung.
    await pumpAtRung(tester, Rung.r4, () async {
      expect(find.textContaining(Rung.r4.title), findsWidgets); // "Repeat after the model"
    });
    await pumpAtRung(tester, Rung.r6, () async {
      expect(find.textContaining(Rung.r6.title), findsWidgets); // "Say it on your own"
    });
  });

  testWidgets('counter shows words (÷reps) and the corner shows the STAGE',
      (tester) async {
    final controller = PracticeController(
      phraseIds: const [10, 10, 10], // one word, a 3-rep block
      tapsToAdvance: 1,
      warmUpBeats: 0,
      guideBeats: 1,
      captureBeats: 1,
      rungOf: (_) => Rung.r4,
    );
    await tester.pumpWidget(_Host(
        controller: controller, text: const {10: 'Help'}, repsPerBlock: 3));
    controller.start();
    await tester.pump();
    controller.onBeat(0);
    await tester.tap(find.byType(PracticeView));
    await tester.pump(); // referencePrompt

    // Counter shows the WORD position (3 reps / 3 = 1 word), not the rep count.
    expect(find.text('Word 1 of 1'), findsOneWidget);
    // The corner shows which STAGE of the ladder we're on (the rung), not the rep.
    expect(find.textContaining('${Rung.r4.code} · ${Rung.r4.title}'),
        findsOneWidget);
  });

  testWidgets('a name card shows the photo above the name', (tester) async {
    final controller = PracticeController(
      phraseIds: const [10],
      tapsToAdvance: 1,
      warmUpBeats: 0,
      guideBeats: 1,
      captureBeats: 1,
      rungOf: (_) => Rung.r4,
    );
    await tester.pumpWidget(_Host(
      controller: controller,
      text: const {10: 'Sarah'},
      photos: {10: _kPng1x1},
    ));
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
      phraseIds: const [10],
      tapsToAdvance: 1,
      warmUpBeats: 0,
      guideBeats: 1,
      captureBeats: 1,
      rungOf: (_) => Rung.r4,
    );
    await tester.pumpWidget(_Host(
      controller: controller,
      text: const {10: 'Sarah'},
      photos: photos,
      targetDisplay: display,
    ));
    controller.start();
    await tester.pump();
    controller.onBeat(0);
    await tester.tap(find.byType(PracticeView));
    await tester.pump();
    await checks();
  }

  testWidgets('display=picture shows the photo only (no word)', (tester) async {
    await pumpTarget(tester, display: TargetDisplay.picture, photos: {10: _kPng1x1},
        checks: () async {
      expect(find.byType(Image), findsOneWidget);
      expect(find.text('Sarah'), findsNothing);
    });
  });

  testWidgets('display=picture falls back to the word when no photo', (tester) async {
    await pumpTarget(tester, display: TargetDisplay.picture, checks: () async {
      expect(find.byType(Image), findsNothing);
      expect(find.text('Sarah'), findsOneWidget);
    });
  });

  testWidgets('display=word shows the word only (no photo)', (tester) async {
    await pumpTarget(tester, display: TargetDisplay.word, photos: {10: _kPng1x1},
        checks: () async {
      expect(find.byType(Image), findsNothing);
      expect(find.text('Sarah'), findsOneWidget);
    });
  });

  testWidgets('display=both shows the photo and the word', (tester) async {
    await pumpTarget(tester, display: TargetDisplay.both, photos: {10: _kPng1x1},
        checks: () async {
      expect(find.byType(Image), findsOneWidget);
      expect(find.text('Sarah'), findsOneWidget);
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
