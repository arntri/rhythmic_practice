// The hand-tapping tutorial. MIT has two active ingredients — the melody and
// the rhythmic hand tapping — and the app can only do the first one. Until this
// screen existed the second was asked for on every screen of every session and
// explained nowhere, which meant a caregiver had to infer a clinical technique
// from a one-line cue while doing everything else.
//
// What these pin down is mostly what the screen must NOT do: gate, score, or
// teach a caregiver to watch a pad instead of a person.

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:rhythmic_practice/screens/tapping_tutorial_screen.dart';

void main() {
  Future<void> pump(WidgetTester tester) async {
    // A tall surface so the whole screen is laid out at once — the content is a
    // ListView, which otherwise only builds what would be visible on a phone.
    tester.view.physicalSize = const Size(1200, 3400);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.reset);
    await tester.pumpWidget(
      const MaterialApp(home: TappingTutorialScreen(bpm: 60)),
    );
    await tester.pump();
  }

  testWidgets('says which hand, and says it unambiguously', (tester) async {
    await pump(tester);
    // The left hand is not interchangeable with the right here — it is the hand
    // this therapy uses. A caregiver reading quickly must not be able to miss it.
    expect(find.textContaining('LEFT'), findsOneWidget);
  });

  testWidgets('teaches one tap per syllable, not per beat of the session', (
    tester,
  ) async {
    await pump(tester);
    expect(find.textContaining('One tap per syllable'), findsOneWidget);
    // And that the hand rests in the gaps — the thing most likely to be got
    // wrong, because a metronome invites tapping straight through.
    expect(find.textContaining('carry no taps'), findsOneWidget);
  });

  testWidgets('says plainly that the tapping is never scored', (tester) async {
    await pump(tester);
    expect(find.textContaining('It is not a test'), findsOneWidget);
    expect(find.textContaining('tap it for them'), findsOneWidget);
  });

  testWidgets('the practice pad only responds once the beat is running', (
    tester,
  ) async {
    await pump(tester);
    expect(find.text('Start the beat first'), findsOneWidget);

    // Tapping a dead pad does nothing — there is no beat to be in time with.
    await tester.tap(find.byKey(const Key('tutorial_tap_pad')));
    await tester.pump();
    expect(find.textContaining('tap'), findsWidgets);
    expect(find.text('1 tap'), findsNothing);
  });

  testWidgets('counts taps once the beat runs, and reports no accuracy', (
    tester,
  ) async {
    await pump(tester);
    await tester.tap(find.byKey(const Key('tutorial_beat_toggle')));
    await tester.pump();
    expect(find.text('Tap here on every beat'), findsOneWidget);

    await tester.tap(find.byKey(const Key('tutorial_tap_pad')));
    await tester.pump();
    expect(find.text('1 tap'), findsOneWidget);

    await tester.tap(find.byKey(const Key('tutorial_tap_pad')));
    await tester.pump();
    expect(find.text('2 taps'), findsOneWidget);

    // A count, never a score. Teaching a caregiver to chase accuracy here would
    // teach them the wrong thing to do with their attention in a session, where
    // the person — not the pad — is what they should be watching.
    expect(find.textContaining('%'), findsNothing);
    expect(find.textContaining('accuracy'), findsNothing);

    // Stop the engine so the test's ticker is disposed cleanly.
    await tester.tap(find.byKey(const Key('tutorial_beat_toggle')));
    await tester.pump();
  });

  testWidgets('leaving is never gated on having used the pad', (tester) async {
    // Someone who already knows how to do this should not have to perform it.
    await pump(tester);
    final done = find.widgetWithText(FilledButton, 'Done');
    expect(done, findsOneWidget);
    expect(tester.widget<FilledButton>(done).onPressed, isNotNull);
  });
}
