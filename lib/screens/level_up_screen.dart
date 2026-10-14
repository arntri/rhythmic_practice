import 'package:flutter/material.dart';

import '../practice/mit_sequence.dart';
import 'practice_palette.dart';

/// A19 — the patient has met the criterion to move up a level.
///
/// A screen rather than a passing message, for two reasons. It **changes the
/// whole step sequence** from the next session on, which is the largest thing
/// the app ever decides. And it is addressed to the **caregiver**, not the
/// patient: it names the level and says plainly what will be different, because
/// that is the only part that affects what they do tomorrow.
///
/// **They can decline.** The 90%-over-ten-sessions criterion is evidence, not a
/// verdict — the person sitting beside the patient knows things it does not, and
/// an app that moves someone up over their objection is wrong more often than a
/// caregiver who says "not this week".
class LevelUpScreen extends StatelessWidget {
  const LevelUpScreen({
    super.key,
    required this.from,
    required this.to,
    required this.onAccept,
    required this.onDecline,
  });

  final MitLevel from;
  final MitLevel to;
  final VoidCallback onAccept;
  final VoidCallback onDecline;

  /// Both answers are this tall, whatever their text. The design asks for them
  /// to be the same size and the same distance from the thumb; pinning the
  /// height is what keeps that true when a level name is longer than "Got it".
  static const double _answerHeight = 74;

  /// What actually changes tomorrow, in the caregiver's terms.
  String get _whatChanges {
    final steps = stepsFor(to).length;
    final was = stepsFor(from).length;
    final count =
        '$steps ${steps == 1 ? 'step' : 'steps'} per word '
        'instead of $was.';
    return switch (to) {
      MitLevel.two =>
        'Phrases now start together and they finish alone, and there is a '
            'question at the end to answer. $count',
      MitLevel.three =>
        'Phrases now start from silence, and we begin bringing the tune back '
            'down to ordinary speech. $count',
      MitLevel.one =>
        'Back to humming and saying words together, never alone. $count',
    };
  }

  @override
  Widget build(BuildContext context) {
    // The stage the patient will be starting at, so the screen already looks
    // like where they are going.
    final tint = PracticePalette.of(stepsFor(to).first);
    return Scaffold(
      body: Container(
        decoration: BoxDecoration(gradient: tint.field),
        child: SafeArea(
          child: Center(
            child: ConstrainedBox(
              constraints: const BoxConstraints(maxWidth: 680),
              child: SingleChildScrollView(
                padding: const EdgeInsets.all(36),
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    // Said out loud, because everything else on the patient's
                    // screen is for the patient and this one thing is not.
                    Text(
                      'FOR THE CAREGIVER',
                      style: TextStyle(
                        fontSize: 13.5,
                        fontWeight: FontWeight.w700,
                        letterSpacing: 1.3,
                        color: tint.stepFg,
                      ),
                    ),
                    const SizedBox(height: 16),
                    Text(
                      '${to.title} from tomorrow',
                      textAlign: TextAlign.center,
                      style: TextStyle(
                        fontSize: 46,
                        height: 1.08,
                        fontWeight: FontWeight.w800,
                        letterSpacing: -1,
                        color: tint.ink,
                      ),
                    ),
                    const SizedBox(height: 16),
                    Text(
                      _whatChanges,
                      textAlign: TextAlign.center,
                      style: TextStyle(
                        fontSize: 21,
                        height: 1.45,
                        fontWeight: FontWeight.w500,
                        color: tint.stepFg,
                      ),
                    ),
                    const SizedBox(height: 30),
                    // A Row, not a Wrap: the design asks for the two answers to
                    // be the same size and the same distance from the thumb, and
                    // a Wrap quietly breaks that as soon as a level name gets
                    // long. Sharing the width makes it structural.
                    Row(
                      children: [
                        Expanded(
                          child: FilledButton(
                            key: const Key('level_up_accept'),
                            onPressed: onAccept,
                            style: FilledButton.styleFrom(
                              backgroundColor: tint.accent,
                              minimumSize: const Size.fromHeight(_answerHeight),
                              padding: const EdgeInsets.symmetric(
                                horizontal: 26,
                              ),
                              textStyle: const TextStyle(fontSize: 22),
                            ),
                            child: const Text('Got it'),
                          ),
                        ),
                        const SizedBox(width: 14),
                        // Declining is a real option, in the same row and the
                        // same size — not a link tucked underneath.
                        Expanded(
                          child: OutlinedButton(
                            key: const Key('level_up_decline'),
                            onPressed: onDecline,
                            style: OutlinedButton.styleFrom(
                              foregroundColor: tint.ink,
                              side: BorderSide(color: tint.edge, width: 2),
                              minimumSize: const Size.fromHeight(_answerHeight),
                              padding: const EdgeInsets.symmetric(
                                horizontal: 26,
                              ),
                              textStyle: const TextStyle(fontSize: 22),
                            ),
                            child: FittedBox(
                              fit: BoxFit.scaleDown,
                              child: Text('Stay at ${from.title}'),
                            ),
                          ),
                        ),
                      ],
                    ),
                    const SizedBox(height: 20),
                    Text(
                      'You can change the level any time from your controls.',
                      textAlign: TextAlign.center,
                      style: TextStyle(fontSize: 15, color: tint.stepFg),
                    ),
                  ],
                ),
              ),
            ),
          ),
        ),
      ),
    );
  }
}
