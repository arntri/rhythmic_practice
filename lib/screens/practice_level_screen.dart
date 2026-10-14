import 'package:flutter/material.dart';

import '../data/practice_repository.dart';
import '../practice/mit_sequence.dart';
import 'caregiver_kit.dart';

/// The practice level — the most important control in the app.
///
/// Three named levels, each described in the words a caregiver would use rather
/// than a number, with **the steps that level actually runs listed underneath**
/// so the choice is concrete rather than abstract. This is a clinical judgement
/// about a person: the app states what it would do and leaves the decision here.
///
/// It is a property of the **patient**, never of a phrase. There is no per-word
/// rung any more, and this screen is the only place a level is set.
class PracticeLevelScreen extends StatefulWidget {
  const PracticeLevelScreen({
    super.key,
    required this.repository,
    this.asCapability = false,
    this.onChosen,
  });

  final PracticeRepository repository;

  /// First-run mode: the levels are described by **what the person can do**
  /// rather than by name, because asking a caregiver to pick "Level II" on day
  /// one is asking them to make a clinical judgement in a vocabulary they have
  /// not been given yet.
  final bool asCapability;

  /// Called after a choice is saved — first-run uses it to move on.
  final ValueChanged<MitLevel>? onChosen;

  @override
  State<PracticeLevelScreen> createState() => _PracticeLevelScreenState();
}

class _PracticeLevelScreenState extends State<PracticeLevelScreen> {
  MitLevel? _level;
  bool _autoAdvance = true;
  bool _loading = true;
  String? _error;

  /// What the app would pick if nobody chose: Level II, MIT's core sequence.
  static const _suggested = MitLevel.two;

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    try {
      final profile = await widget.repository.getProfile();
      if (!mounted) return;
      setState(() {
        _level = widget.asCapability ? _suggested : profile.mitLevel;
        _autoAdvance = profile.autoProgressEnabled;
        _loading = false;
      });
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _error = 'Could not load the practice level: $e';
        _loading = false;
      });
    }
  }

  Future<void> _choose(MitLevel level) async {
    setState(() => _level = level);
    await widget.repository.updateProfile(mitLevel: level);
    widget.onChosen?.call(level);
  }

  /// The capability phrasing, for first run. Same three levels, asked as what
  /// the person in front of you can manage on a normal day.
  static const _capability = {
    MitLevel.one: ('They can hum along', 'Singing with you is enough.'),
    MitLevel.two: (
      'They can finish a phrase you start',
      'You begin together, they carry the end.',
    ),
    MitLevel.three: (
      'They can start from silence',
      'No model first, then the tune comes away.',
    ),
  };

  @override
  Widget build(BuildContext context) {
    return CaregiverScaffold(
      eyebrow: widget.asCapability ? 'STEP 2 OF 4' : 'OFTEN',
      title: widget.asCapability
          ? 'What can they manage today?'
          : 'Practice level',
      subtitle: widget.asCapability
          ? 'Answer for a normal day.'
          : 'Which steps the session runs for every word.',
      loading: _loading,
      error: _error,
      footer: widget.asCapability
          ? CaregiverButton(
              label: 'Continue',
              onPressed: _level == null ? null : () => _choose(_level!),
            )
          : null,
      children: [
        for (final level in MitLevel.values) ...[
          _LevelCard(
            level: level,
            selected: _level == level,
            asCapability: widget.asCapability,
            capability: _capability[level]!,
            onTap: () => widget.asCapability
                ? setState(() => _level = level)
                : _choose(level),
          ),
          const SizedBox(height: 12),
        ],
        const SizedBox(height: 10),
        if (widget.asCapability)
          const CaregiverNote(
            'We would start here. You can change it any time.',
          )
        else
          CaregiverSection(
            rows: [
              CaregiverRow(
                title: 'Let the app advance the level',
                meta: 'About 90% over ten sessions',
                switchValue: _autoAdvance,
                onSwitch: (v) async {
                  setState(() => _autoAdvance = v);
                  await widget.repository.updateProfile(
                    autoProgressEnabled: v,
                  );
                },
              ),
            ],
          ),
      ],
    );
  }
}

/// One level: its name (or the capability it describes), a one-line description,
/// and the steps it runs — the level/step matrix, in place.
class _LevelCard extends StatelessWidget {
  const _LevelCard({
    required this.level,
    required this.selected,
    required this.asCapability,
    required this.capability,
    required this.onTap,
  });

  final MitLevel level;
  final bool selected;
  final bool asCapability;
  final (String, String) capability;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final steps = stepsFor(level);
    final (capTitle, capDesc) = capability;
    return Material(
      color: selected ? CaregiverColors.levelOnBg : CaregiverColors.surface,
      borderRadius: BorderRadius.circular(16),
      child: InkWell(
        onTap: onTap,
        borderRadius: BorderRadius.circular(16),
        child: Container(
          padding: const EdgeInsets.fromLTRB(16, 16, 16, 18),
          decoration: BoxDecoration(
            borderRadius: BorderRadius.circular(16),
            border: Border.all(
              color: selected ? CaregiverColors.accent : CaregiverColors.line,
              width: selected ? 2.5 : 1,
            ),
          ),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Row(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  _Dot(on: selected),
                  const SizedBox(width: 13),
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(
                          asCapability ? capTitle : level.title,
                          style: const TextStyle(
                            fontSize: 17.5,
                            fontWeight: FontWeight.w700,
                            color: CaregiverColors.ink,
                          ),
                        ),
                        const SizedBox(height: 3),
                        Text(
                          asCapability ? capDesc : level.description,
                          style: const TextStyle(
                            fontSize: 14,
                            height: 1.45,
                            color: CaregiverColors.subFg,
                          ),
                        ),
                      ],
                    ),
                  ),
                ],
              ),
              const SizedBox(height: 14),
              // The steps, so the choice is concrete. Expanded when selected;
              // a bare count otherwise, so the cards stay comparable.
              if (selected)
                Wrap(
                  spacing: 6,
                  runSpacing: 6,
                  children: [
                    for (final step in steps)
                      Container(
                        padding: const EdgeInsets.symmetric(
                          horizontal: 10,
                          vertical: 6,
                        ),
                        decoration: BoxDecoration(
                          color: Colors.white.withValues(alpha: 0.85),
                          borderRadius: BorderRadius.circular(8),
                        ),
                        child: Text(
                          step.title,
                          style: const TextStyle(
                            fontSize: 12.5,
                            fontWeight: FontWeight.w600,
                            color: CaregiverColors.eyebrowFg,
                          ),
                        ),
                      ),
                  ],
                )
              else
                Text(
                  '${steps.length} steps',
                  style: const TextStyle(
                    fontSize: 13,
                    fontWeight: FontWeight.w600,
                    color: CaregiverColors.dim,
                  ),
                ),
            ],
          ),
        ),
      ),
    );
  }
}

class _Dot extends StatelessWidget {
  const _Dot({required this.on});

  final bool on;

  @override
  Widget build(BuildContext context) => Container(
    width: 22,
    height: 22,
    margin: const EdgeInsets.only(top: 2),
    decoration: BoxDecoration(
      shape: BoxShape.circle,
      color: on ? CaregiverColors.accent : Colors.transparent,
      border: Border.all(
        color: on ? CaregiverColors.accent : CaregiverColors.dotOff,
        width: on ? 6 : 2.5,
      ),
    ),
  );
}
