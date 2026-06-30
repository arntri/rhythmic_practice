// Widget test for the metronome screen: confirms the controls wire up and the
// engine runs without throwing. Audio/haptic are platform features with no test
// implementation — the engine swallows those errors, so this still passes.

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:rhythmic_practice/screens/metronome_screen.dart';

void main() {
  testWidgets('start/stop toggles and channel switches work', (tester) async {
    await tester.pumpWidget(const MaterialApp(home: MetronomeScreen()));

    // Starts stopped.
    expect(find.text('Start'), findsOneWidget);
    expect(find.text('Stop'), findsNothing);

    // Press Start → engine runs, button flips to Stop.
    await tester.tap(find.text('Start'));
    await tester.pump();
    expect(find.text('Stop'), findsOneWidget);

    // Advance ~1.2s of frames so at least one beat fires (no exceptions).
    await tester.pump(const Duration(milliseconds: 600));
    await tester.pump(const Duration(milliseconds: 600));

    // Toggle each channel off and on again.
    for (final label in ['Visual', 'Sound', 'Haptic']) {
      await tester.tap(find.text(label));
      await tester.pump();
    }

    // Stop so the Ticker is cleanly inactive before teardown.
    await tester.tap(find.text('Stop'));
    await tester.pump();
    expect(find.text('Start'), findsOneWidget);
  });
}
