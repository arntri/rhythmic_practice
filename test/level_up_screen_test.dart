// A19 — the level advance, put to the caregiver rather than taken.
//
// The 90%-over-ten-sessions criterion is evidence, not a verdict. It changes the
// whole step sequence from the next session on, and the person sitting beside
// the patient knows things the app does not.

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:rhythmic_practice/practice/mit_sequence.dart';
import 'package:rhythmic_practice/screens/level_up_screen.dart';

void main() {
  Future<void> pump(
    WidgetTester tester, {
    MitLevel from = MitLevel.two,
    MitLevel to = MitLevel.three,
    VoidCallback? onAccept,
    VoidCallback? onDecline,
  }) async {
    tester.view.physicalSize = const Size(1400, 900);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.reset);
    await tester.pumpWidget(
      MaterialApp(
        home: LevelUpScreen(
          from: from,
          to: to,
          onAccept: onAccept ?? () {},
          onDecline: onDecline ?? () {},
        ),
      ),
    );
    await tester.pump();
  }

  testWidgets('is addressed to the caregiver, and says so', (tester) async {
    // Everything else on this screen is the patient's. This one thing is not,
    // and a caregiver glancing over needs to know it is for them.
    await pump(tester);
    expect(find.text('FOR THE CAREGIVER'), findsOneWidget);
  });

  testWidgets('names the level and what actually changes tomorrow', (
    tester,
  ) async {
    await pump(tester, from: MitLevel.two, to: MitLevel.three);
    expect(find.text('Level III from tomorrow'), findsOneWidget);
    // The part that affects what they do: phrases start from silence, and the
    // step count changes.
    expect(find.textContaining('start from silence'), findsOneWidget);
    expect(find.textContaining('4 steps per word instead of 5'), findsOneWidget);
  });

  testWidgets('declining is a real option, not a link underneath', (
    tester,
  ) async {
    var accepted = 0;
    var declined = 0;
    await pump(
      tester,
      onAccept: () => accepted++,
      onDecline: () => declined++,
    );

    final accept = find.byKey(const Key('level_up_accept'));
    final decline = find.byKey(const Key('level_up_decline'));
    expect(accept, findsOneWidget);
    expect(decline, findsOneWidget);
    expect(find.text('Stay at Level II'), findsOneWidget);

    // Same row, comparable size — the app is asking, not announcing.
    final a = tester.getRect(accept);
    final d = tester.getRect(decline);
    expect((a.center.dy - d.center.dy).abs(), lessThan(2));
    expect(a.height, d.height);

    await tester.tap(decline);
    await tester.pump();
    expect(declined, 1);
    expect(accepted, 0);

    await tester.tap(accept);
    await tester.pump();
    expect(accepted, 1);
  });

  testWidgets('says the choice can be changed later, because it can', (
    tester,
  ) async {
    // What makes the question safe to answer either way.
    await pump(tester);
    expect(find.textContaining('change the level any time'), findsOneWidget);
  });

  testWidgets('never shows a number, a code, or a score', (tester) async {
    await pump(tester);
    expect(find.textContaining('90%'), findsNothing);
    expect(find.textContaining('%'), findsNothing);
    expect(find.textContaining('rung'), findsNothing);
  });
}
