import 'package:flutter/material.dart';

import '../data/practice_repository.dart';
import '../ml/insights_dashboard.dart';
import '../ml/solo_mode.dart';
import 'caregiver_kit.dart';

/// Insights — **experimental, and it changes nothing.**
///
/// Kept because a fatigue estimate and a solo-ready count are genuinely useful
/// to a caregiver deciding whether to run one more word. Kept *inert* because
/// neither is trustworthy enough to drive the protocol: the model has seen one
/// person's data, and none of it is a clinical measure.
///
/// The banner is not dismissible. A screen that quietly stops saying it is
/// guessing is a screen people start believing.
class InsightsScreen extends StatefulWidget {
  const InsightsScreen({super.key, required this.repository});

  final PracticeRepository repository;

  @override
  State<InsightsScreen> createState() => _InsightsScreenState();
}

class _InsightsScreenState extends State<InsightsScreen> {
  MlInsights? _insights;
  int _sessions = 0;
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
      final insights = await InsightsService(
        widget.repository,
      ).load(profile.profileId);
      final span = await widget.repository.practiceSpan(profile.profileId);
      if (!mounted) return;
      setState(() {
        _insights = insights;
        _sessions = span.sessions;
        _loading = false;
      });
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _error = 'Could not load insights: $e';
        _loading = false;
      });
    }
  }

  /// The fatigue reading in words, from the most recent session that had enough
  /// to go on. Never a number — a decimal here would look like a measurement.
  (String, String) get _fatigue {
    final sessions = _insights?.sessionFatigue ?? const [];
    for (final s in sessions.reversed) {
      if (s.estimate.lowConfidence) continue;
      return s.estimate.isFatigued
          ? (
              'Rising',
              'Later words took longer than earlier ones in the last session.',
            )
          : (
              'Steady',
              'No drift between the start and end of the last session.',
            );
    }
    return (
      'Not enough yet',
      'A session needs a good number of taps before this says anything.',
    );
  }

  @override
  Widget build(BuildContext context) {
    final i = _insights;
    final (fatigue, fatigueWhy) = _fatigue;
    return CaregiverScaffold(
      eyebrow: 'SET ONCE',
      title: 'Insights',
      loading: _loading,
      error: _error,
      children: i == null
          ? const []
          : [
              const CaregiverBanner(
                tag: 'EXPERIMENTAL',
                text:
                    'These are estimates from very little data. Nothing here '
                    'changes how the session runs, and nothing here is a '
                    'clinical measure.',
              ),
              const SizedBox(height: 20),
              CaregiverBigStat(
                tag: 'FATIGUE ESTIMATE',
                value: fatigue,
                meta: fatigueWhy,
                small: true,
              ),
              const SizedBox(height: 16),
              CaregiverStats(
                items: [
                  ('${i.soloEligibleCount}', 'words solo-ready'),
                  ('$_sessions', 'sessions seen'),
                  (
                    i.soloAuthority == SoloAuthority.mlAssisted
                        ? 'Assisting'
                        : 'Advisory',
                    'what it may do',
                  ),
                ],
              ),
              const SizedBox(height: 20),
              CaregiverNote(
                'Why none of this is wired to anything: ${i.graduation.reason}',
              ),
              const SizedBox(height: 16),
              const CaregiverNote(
                'Solo-ready means a phrase they already answer a question with, '
                'reliably. Even then a caregiver still confirms every attempt — '
                'the app will not take that over until a model has been trained '
                'and independently checked, which has not happened.',
              ),
            ],
    );
  }
}
