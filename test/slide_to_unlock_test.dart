import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:rhythmic_practice/widgets/slide_to_unlock.dart';

void main() {
  testWidgets('a tap does nothing; a full drag unlocks', (tester) async {
    var unlocked = 0;
    await tester.pumpWidget(MaterialApp(
      home: Scaffold(
        body: Padding(
          padding: const EdgeInsets.all(20),
          child: Align(
            alignment: Alignment.topCenter,
            child: SlideToUnlock(onUnlocked: () => unlocked++),
          ),
        ),
      ),
    ));

    // A plain tap must NOT unlock.
    await tester.tap(find.byKey(const Key('slide_thumb')));
    await tester.pump();
    expect(unlocked, 0);

    // Dragging the thumb all the way across unlocks once.
    await tester.drag(find.byKey(const Key('slide_thumb')), const Offset(2000, 0));
    await tester.pumpAndSettle();
    expect(unlocked, 1);
  });
}
