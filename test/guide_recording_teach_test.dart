// Widget test for the caregiver "teach the melody" step (Part 2, item 5):
// the idle stage teaches the tune with two contrasting demos before recording.

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:rhythmic_practice/data/models.dart';
import 'package:rhythmic_practice/data/practice_repository.dart';
import 'package:rhythmic_practice/screens/guide_recording_screen.dart';

void main() {
  const phrase = PracticePhrase(
    phraseId: 1,
    phraseText: 'Water',
    wordCount: 1,
    syllableCount: 2,
    complexityLevel: 2,
    audioAssetPath: null,
    isActive: true,
  );

  testWidgets('idle stage teaches the tune with two contrasting demos',
      (tester) async {
    await tester.pumpWidget(MaterialApp(
      home: GuideRecordingScreen(
        phrases: const [phrase],
        repository: PracticeRepository(),
      ),
    ));
    await tester.pump();

    // Two demos that contrast where the high note falls: "WA-ter" rises on the
    // first part, "a-GAIN" on the second — imitation over jargon.
    expect(find.text('WA-ter'), findsOneWidget);
    expect(find.text('a-GAIN'), findsOneWidget);
    expect(find.text('The strong part goes up. Hear it:'), findsOneWidget);

    // "Now you" — the record affordance is present and the phrase is shown.
    expect(find.text('Record'), findsOneWidget);
    expect(find.text('Water'), findsOneWidget);
  });
}
