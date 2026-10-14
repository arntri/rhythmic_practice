import 'package:flutter/material.dart';

import '../app/orientation.dart';
import '../data/practice_repository.dart';
import 'caregiver_kit.dart';
import 'phrase_library_screen.dart';
import 'practice_level_screen.dart';
import 'tapping_tutorial_screen.dart';

/// First run — four steps, and the level question is the one that needs care.
///
/// Picking a level is a real clinical judgement, and it is being put to a family
/// member on day one. So it is asked in terms of **what the person can do**
/// rather than what the app calls it, the app states which answer it would pick,
/// and it says the choice can change any time — which is true, and is what makes
/// it safe to answer.
class FirstRunScreen extends StatefulWidget {
  const FirstRunScreen({super.key, required this.repository});

  final PracticeRepository repository;

  @override
  State<FirstRunScreen> createState() => _FirstRunScreenState();
}

class _FirstRunScreenState extends State<FirstRunScreen> {
  int _step = 0;

  static const _total = 4;

  Future<void> _finish() async {
    await widget.repository.updateProfile(onboardingSeen: true);
    if (mounted) Navigator.of(context).maybePop();
  }

  @override
  Widget build(BuildContext context) => switch (_step) {
    0 => _Welcome(onNext: () => setState(() => _step = 1)),
    1 => PracticeLevelScreen(
      repository: widget.repository,
      asCapability: true,
      onChosen: (_) => setState(() => _step = 2),
    ),
    2 => _LearnTapping(
      repository: widget.repository,
      onNext: () => setState(() => _step = 3),
    ),
    _ => _PickPhrases(repository: widget.repository, onDone: _finish),
  };
}

class _Welcome extends StatelessWidget {
  const _Welcome({required this.onNext});

  final VoidCallback onNext;

  @override
  Widget build(BuildContext context) => CaregiverScaffold(
    eyebrow: 'STEP 1 OF ${_FirstRunScreenState._total}',
    title: 'Singing before speaking',
    subtitle:
        'For someone with non-fluent aphasia who can still sing. You will sing '
        'and tap along with them — both of those are the therapy, not '
        'encouragement.',
    footer: CaregiverButton(label: 'Start', onPressed: onNext),
    children: const [
      _NumberedStep(
        n: 1,
        text: 'Pick three or four short phrases they actually need every day.',
      ),
      _NumberedStep(
        n: 2,
        text: 'Learn the hand tapping. It is the part that matters most.',
      ),
      _NumberedStep(
        n: 3,
        text: 'Practise in short blocks, most days of the week.',
      ),
      SizedBox(height: 8),
      CaregiverNote(
        'Nothing here needs a clinician present, but bring the progress screen '
        'to your next appointment — the per-step figures are the useful part.',
      ),
    ],
  );
}

class _LearnTapping extends StatelessWidget {
  const _LearnTapping({required this.repository, required this.onNext});

  final PracticeRepository repository;
  final VoidCallback onNext;

  @override
  Widget build(BuildContext context) => CaregiverScaffold(
    eyebrow: 'STEP 3 OF ${_FirstRunScreenState._total}',
    title: 'The tapping is half of it',
    subtitle:
        'Melodic intonation therapy works through two things at once: the tune, '
        'which the app plays, and the rhythm, which you tap into their hand. The '
        'app cannot do the second one.',
    footer: CaregiverButton(label: 'Next', onPressed: onNext),
    children: [
      CaregiverCard(
        onTap: () => Navigator.of(context).push(
          PortraitPageRoute<void>(
            builder: (_) => const TappingTutorialScreen(),
          ),
        ),
        child: const Row(
          children: [
            Icon(Icons.back_hand_outlined, color: CaregiverColors.accent),
            SizedBox(width: 14),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    'Learn the hand tapping',
                    style: TextStyle(
                      fontSize: 17,
                      fontWeight: FontWeight.w700,
                      color: CaregiverColors.ink,
                    ),
                  ),
                  SizedBox(height: 3),
                  Text(
                    'Two minutes, with a beat to practise to',
                    style: TextStyle(
                      fontSize: 13.5,
                      color: CaregiverColors.dim,
                    ),
                  ),
                ],
              ),
            ),
            Icon(Icons.chevron_right, color: CaregiverColors.dim),
          ],
        ),
      ),
      const SizedBox(height: 16),
      // Offered, not forced — but said plainly, because a caregiver who skips
      // this is doing half the therapy.
      const CaregiverNote(
        'You can come back to this any time from your controls. It is worth the '
        'two minutes before the first session.',
      ),
    ],
  );
}

class _PickPhrases extends StatelessWidget {
  const _PickPhrases({required this.repository, required this.onDone});

  final PracticeRepository repository;
  final VoidCallback onDone;

  @override
  Widget build(BuildContext context) => CaregiverScaffold(
    eyebrow: 'STEP 4 OF ${_FirstRunScreenState._total}',
    title: 'What will they practise?',
    subtitle:
        'A few phrases are switched on already. Change them for things they '
        'actually need to say — that is what makes this work.',
    footer: CaregiverButton(label: 'Start practising', onPressed: onDone),
    children: [
      CaregiverCard(
        onTap: () => Navigator.of(context).push(
          PortraitPageRoute<void>(
            builder: (_) => PhraseLibraryScreen(repository: repository),
          ),
        ),
        child: const Row(
          children: [
            Icon(Icons.list_alt_outlined, color: CaregiverColors.accent),
            SizedBox(width: 14),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    'Choose the phrases',
                    style: TextStyle(
                      fontSize: 17,
                      fontWeight: FontWeight.w700,
                      color: CaregiverColors.ink,
                    ),
                  ),
                  SizedBox(height: 3),
                  Text(
                    'Switch some on, add your own in any language',
                    style: TextStyle(
                      fontSize: 13.5,
                      color: CaregiverColors.dim,
                    ),
                  ),
                ],
              ),
            ),
            Icon(Icons.chevron_right, color: CaregiverColors.dim),
          ],
        ),
      ),
      const SizedBox(height: 16),
      const CaregiverNote(
        'Two to five syllables works best. A one-word phrase has no tune to '
        'sing, which is most of what this therapy relies on.',
      ),
    ],
  );
}

class _NumberedStep extends StatelessWidget {
  const _NumberedStep({required this.n, required this.text});

  final int n;
  final String text;

  @override
  Widget build(BuildContext context) => Padding(
    padding: const EdgeInsets.only(bottom: 16),
    child: Row(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Container(
          width: 30,
          height: 30,
          alignment: Alignment.center,
          decoration: const BoxDecoration(
            color: CaregiverColors.accent,
            shape: BoxShape.circle,
          ),
          child: Text(
            '$n',
            style: const TextStyle(
              color: Colors.white,
              fontWeight: FontWeight.w700,
            ),
          ),
        ),
        const SizedBox(width: 14),
        Expanded(
          child: Padding(
            padding: const EdgeInsets.only(top: 3),
            child: Text(
              text,
              style: const TextStyle(
                fontSize: 16.5,
                height: 1.45,
                color: CaregiverColors.ink,
              ),
            ),
          ),
        ),
      ],
    ),
  );
}
