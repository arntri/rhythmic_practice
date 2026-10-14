import 'package:flutter/material.dart';

import '../analytics/practice_dose.dart';
import '../data/practice_repository.dart';
import 'caregiver_kit.dart';

/// Practice dose — minutes a day, against a stated target.
///
/// The hard part of this screen is tone. A dose display is one wrong sentence
/// away from being a device for making a tired family feel worse, and the people
/// looking at it are usually already doing more than they can. So the target is
/// **named** rather than implied by a bar that happens to look full, days below
/// it are drawn in the neutral colour rather than flagged, and there is no
/// streak — a streak turns a therapy into a thing you can break, and the person
/// most likely to break it is the one having the worst week.
class PracticeDoseScreen extends StatefulWidget {
  const PracticeDoseScreen({super.key, required this.repository});

  final PracticeRepository repository;

  @override
  State<PracticeDoseScreen> createState() => _PracticeDoseScreenState();
}

class _PracticeDoseScreenState extends State<PracticeDoseScreen> {
  PracticeDose? _dose;
  int _target = PracticeDose.defaultTargetMinutesPerDay;
  bool _loading = true;
  String? _error;

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    try {
      final profile = await widget.repository.getProfile();
      final minutes = await widget.repository.minutesPerDay(profile.profileId);
      if (!mounted) return;
      setState(() {
        _target = profile.practiceTargetMinutes;
        _dose = PracticeDose.from(
          minutes,
          today: DateTime.now(),
          targetMinutesPerDay: profile.practiceTargetMinutes,
        );
        _loading = false;
      });
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _error = 'Could not load practice history: $e';
        _loading = false;
      });
    }
  }

  Future<void> _setTarget(int minutes) async {
    setState(() => _target = minutes);
    await widget.repository.updateProfile(practiceTargetMinutes: minutes);
    await _load();
  }

  @override
  Widget build(BuildContext context) {
    final dose = _dose;
    return CaregiverScaffold(
      eyebrow: 'THE SESSION',
      title: 'Practice dose',
      // The target, said out loud. A caregiver deciding how hard to push
      // deserves to know what the number is measured against.
      subtitle:
          'MIT asks for about ${PracticeDose.defaultTargetMinutesPerDay} '
          'minutes a day, five days a week.',
      loading: _loading,
      error: _error,
      children: dose == null
          ? const []
          : [
              CaregiverBigStat(
                tag: 'YOU ARE AT',
                value: '${dose.averageMinutesPerDay} min / day',
                meta: _standing(dose),
              ),
              const SizedBox(height: 20),
              _WeekBars(dose: dose),
              const SizedBox(height: 20),
              const CaregiverNote(
                'Shorter sessions more often beat one long session. Two '
                'twenty-minute blocks count the same as one forty.',
              ),
              const SizedBox(height: 28),
              CaregiverFieldLabel('YOUR DAILY TARGET'),
              const SizedBox(height: 10),
              _TargetPicker(value: _target, onChanged: _setTarget),
            ],
    );
  }

  /// A plain reading of where they are. Never a percentage — "you are 63% of a
  /// person this week" is not a thing anyone needs told about caring for family.
  String _standing(PracticeDose dose) {
    if (!dose.hasEnoughHistory) {
      return 'Not much history yet — this will settle down over a week or two.';
    }
    final f = dose.fractionOfTarget;
    if (f >= 0.95) return 'At the target.';
    if (f >= 0.6) return 'Around two thirds of the target.';
    if (f > 0) return 'Below the target, but the days are there.';
    return 'Nothing recorded this week.';
  }
}

/// The last seven days as bars. Days that met the target are green; the rest are
/// the accent colour; empty days are a faint stub rather than nothing at all, so
/// the week reads as seven days rather than as however many went well.
class _WeekBars extends StatelessWidget {
  const _WeekBars({required this.dose});

  final PracticeDose dose;

  @override
  Widget build(BuildContext context) {
    final peak = [
      dose.targetMinutesPerDay,
      ...dose.days.map((d) => d.minutes),
    ].reduce((a, b) => a > b ? a : b);

    return CaregiverCard(
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          CaregiverFieldLabel('LAST SEVEN DAYS'),
          const SizedBox(height: 18),
          SizedBox(
            height: 118,
            child: Row(
              crossAxisAlignment: CrossAxisAlignment.end,
              children: [
                for (final day in dose.days)
                  Expanded(
                    child: _Bar(day: day, peak: peak),
                  ),
              ],
            ),
          ),
          const SizedBox(height: 12),
          Text(
            dose.daysMetTarget == 0
                // No reproach. The target simply hasn't been hit yet.
                ? 'Green days reach the target.'
                : '${dose.daysMetTarget} of the last seven reached the target.',
            style: TextStyle(fontSize: 13.5, color: CaregiverColors.dim),
          ),
        ],
      ),
    );
  }
}

class _Bar extends StatelessWidget {
  const _Bar({required this.day, required this.peak});

  final DoseDay day;
  final int peak;

  @override
  Widget build(BuildContext context) {
    // Empty days keep a visible stub so the week reads as seven days.
    const stub = 4.0;
    final h = peak <= 0 ? stub : (day.minutes / peak) * 88;
    return Column(
      mainAxisAlignment: MainAxisAlignment.end,
      children: [
        if (day.minutes > 0)
          Text(
            '${day.minutes}',
            style: TextStyle(
              fontSize: 11,
              fontWeight: FontWeight.w600,
              color: CaregiverColors.dim,
              fontFeatures: const [FontFeature.tabularFigures()],
            ),
          ),
        const SizedBox(height: 4),
        Container(
          height: h < stub ? stub : h,
          margin: const EdgeInsets.symmetric(horizontal: 5),
          decoration: BoxDecoration(
            color: day.minutes == 0
                ? CaregiverColors.faint
                : day.metTarget
                ? CaregiverColors.green
                : CaregiverColors.accent,
            borderRadius: const BorderRadius.vertical(top: Radius.circular(5)),
          ),
        ),
        const SizedBox(height: 7),
        Text(
          day.initial,
          style: TextStyle(fontSize: 12.5, color: CaregiverColors.dim),
        ),
      ],
    );
  }
}

class _TargetPicker extends StatelessWidget {
  const _TargetPicker({required this.value, required this.onChanged});

  final int value;
  final ValueChanged<int> onChanged;

  @override
  Widget build(BuildContext context) {
    final options = [
      for (
        var m = PracticeDose.minTargetMinutesPerDay;
        m <= PracticeDose.maxTargetMinutesPerDay;
        m += PracticeDose.targetStepMinutes
      )
        m,
    ];
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Wrap(
          spacing: 8,
          runSpacing: 8,
          children: [
            for (final m in options)
              CaregiverChoiceChip(
                label: '$m min',
                selected: m == value,
                onTap: () => onChanged(m),
              ),
          ],
        ),
        const SizedBox(height: 10),
        Text(
          'Change it whenever it stops fitting. A target nobody can reach is '
          'the wrong target, not a wrong week.',
          style: TextStyle(fontSize: 13.5, height: 1.5, color: CaregiverColors.dim),
        ),
      ],
    );
  }
}
