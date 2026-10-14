import 'package:flutter/material.dart';

import '../practice/mit_sequence.dart';
import '../practice/practice_controller.dart';
import 'caregiver_kit.dart';

/// What the session is doing right now — read-only.
///
/// Before the MIT revert there was almost nothing to report: a word sat at a
/// rung and ran three identical reps. Now that an item runs a whole sequence in
/// one sitting there are three things a caregiver glancing down mid-session
/// actually wants, and they want them in this order: **the word**, **the step**
/// in words, and **which go this is**.
///
/// Nothing on this screen changes the session. It is a window, not a control —
/// the panel pauses the session on the way in and the patient's screen restarts
/// its step on the way back, and a control here would fight both.
class InSessionStatusScreen extends StatelessWidget {
  const InSessionStatusScreen({
    super.key,
    required this.controller,
    this.phraseText = const {},
  });

  final PracticeController controller;
  final Map<int, String> phraseText;

  String _word(int id) => phraseText[id] ?? 'Word $id';

  static String _ordinalGo(int n) => switch (n) {
    1 => '1st',
    2 => '2nd',
    3 => '3rd',
    _ => '${n}th',
  };

  @override
  Widget build(BuildContext context) {
    // Rebuilds with the session even though nothing here drives it — a status
    // window that goes stale the moment you open it is worse than none.
    return AnimatedBuilder(
      animation: controller,
      builder: (context, _) {
        final steps = stepsFor(controller.level);
        final ordinal = steps.indexOf(controller.currentStep) + 1;
        final done = controller.state == PracticeState.sessionComplete;
        return CaregiverScaffold(
          eyebrow: 'OFTEN',
          title: 'Right now',
          children: [
            CaregiverBigStat(
              tag: 'THE WORD',
              value: _word(controller.currentPhraseId),
              meta:
                  'Word ${controller.currentWordIndex + 1} of '
                  '${controller.wordCount}',
            ),
            const SizedBox(height: 12),
            CaregiverBigStat(
              tag: 'THE STEP',
              value: done ? 'Session finished' : controller.currentStep.title,
              meta: done
                  ? null
                  : 'Step $ordinal of ${steps.length} · '
                        '${_ordinalGo(controller.repNumber)} go',
              small: true,
            ),
            const SizedBox(height: 22),
            CaregiverSection(
              label: 'THIS SESSION',
              rows: [
                for (var i = 0; i < controller.wordCount; i++)
                  _itemRow(i, controller),
              ],
            ),
            const CaregiverNote(
              'The session is paused while you are in here. It resumes where it '
              'left off, never mid-word.',
            ),
          ],
        );
      },
    );
  }

  /// One item in the session's running order.
  ///
  /// Deliberately **no verdicts** — not per item and not as a tally. The
  /// caregiver's judgements are a clinical record, and a scoreboard of them
  /// mid-session invites a different kind of attention than the one this therapy
  /// wants. What is shown is position only: finished, in progress, or still to
  /// come.
  Widget _itemRow(int index, PracticeController c) {
    final current = c.currentWordIndex;
    final id = c.phraseIdAt(index);
    final isNow = index == current && c.state != PracticeState.sessionComplete;
    final isDone = index < current || c.state == PracticeState.sessionComplete;
    return CaregiverRow(
      title: _word(id),
      meta: isNow
          ? 'in progress'
          : isDone
          ? 'finished'
          : index == current + 1
          ? 'up next'
          : null,
      tag: isNow
          ? const CaregiverTag.now()
          : isDone
          ? const CaregiverTag.done()
          : null,
    );
  }
}
