import 'package:flutter/material.dart';

import '../data/models.dart';
import '../data/practice_repository.dart';
import '../practice/mit_sequence.dart';
import 'caregiver_kit.dart';

/// Progress — movement up **levels**, and beneath it the genuinely useful part:
/// which steps are solid, and which one they keep backing up from.
///
/// That single row is where the work is. It is also the **only place in the app
/// a rate is shown at all**, and it is shown to the caregiver, never to the
/// patient — it is the thing worth bringing to a speech therapist.
///
/// A weak step is drawn in sand, not red. It is not a failure; it is where
/// support goes next.
class ProgressSummaryScreen extends StatefulWidget {
  const ProgressSummaryScreen({super.key, required this.repository});

  final PracticeRepository repository;

  @override
  State<ProgressSummaryScreen> createState() => _ProgressSummaryScreenState();
}

class _ProgressSummaryScreenState extends State<ProgressSummaryScreen> {
  UserProfile? _profile;
  Map<MitStep, ({int passes, int judged})> _rates = const {};
  ({int sessions, DateTime? firstAt}) _span = (sessions: 0, firstAt: null);
  List<SessionSummary> _recent = const [];
  bool _loading = true;
  String? _error;

  /// Below this a rate is noise, not a signal — a step tried twice does not have
  /// a pass rate worth drawing a bar for.
  static const _minJudged = 4;

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    try {
      final profile = await widget.repository.getProfile();
      final rates = await widget.repository.passRateByStep(profile.profileId);
      final span = await widget.repository.practiceSpan(profile.profileId);
      final recent = await widget.repository.getSessionSummaries(limit: 6);
      if (!mounted) return;
      setState(() {
        _profile = profile;
        _rates = rates;
        _span = span;
        _recent = recent;
        _loading = false;
      });
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _error = 'Could not load progress: $e';
        _loading = false;
      });
    }
  }

  String get _weeks {
    final first = _span.firstAt;
    if (first == null) return '—';
    final weeks = (DateTime.now().difference(first).inDays / 7).floor();
    return weeks < 1 ? '<1 wk' : '$weeks wk';
  }

  /// The step they back up from most: the lowest rate with enough behind it.
  MitStep? get _weakest {
    MitStep? worst;
    var lowest = 1.0;
    for (final e in _rates.entries) {
      if (e.value.judged < _minJudged) continue;
      final rate = e.value.passes / e.value.judged;
      if (rate < lowest) {
        lowest = rate;
        worst = e.key;
      }
    }
    return lowest < 0.75 ? worst : null;
  }

  @override
  Widget build(BuildContext context) {
    final profile = _profile;
    final sequence = profile == null ? <MitStep>[] : stepsFor(profile.mitLevel);
    final weakest = _weakest;
    return CaregiverScaffold(
      eyebrow: 'THE SESSION',
      title: 'Progress',
      loading: _loading,
      error: _error,
      children: profile == null
          ? const []
          : [
              CaregiverStats(
                items: [
                  (profile.mitLevel.roman, 'level now'),
                  ('${_span.sessions}', 'sessions'),
                  (_weeks, 'practising'),
                ],
              ),
              const SizedBox(height: 22),

              CaregiverFieldLabel('HOW EACH STEP IS GOING'),
              const SizedBox(height: 12),
              if (_rates.isEmpty)
                const CaregiverNote(
                  'Nothing judged yet. After a session or two this shows which '
                  'steps are solid and which one is worth talking to a speech '
                  'therapist about.',
                )
              else
                CaregiverCard(
                  child: Column(
                    children: [
                      for (final step in sequence)
                        _StepRate(
                          step: step,
                          tally: _rates[step],
                          weak: step == weakest,
                          minJudged: _minJudged,
                        ),
                    ],
                  ),
                ),
              if (weakest != null) ...[
                const SizedBox(height: 12),
                CaregiverNote(
                  'They back up from “${weakest.title}” more than anywhere else. '
                  'That is where the support is going, and it is the most useful '
                  'thing to mention at a speech therapy appointment.',
                ),
              ],

              const SizedBox(height: 26),
              if (_recent.isNotEmpty)
                CaregiverSection(
                  label: 'RECENT SESSIONS',
                  rows: [
                    for (final s in _recent)
                      CaregiverRow(
                        title: _when(s.startedAt),
                        meta: '${s.attempts} '
                            '${s.attempts == 1 ? 'attempt' : 'attempts'}',
                        tag: CaregiverTag(
                          label: profile.mitLevel.roman,
                          background: CaregiverColors.tagNowBg,
                          foreground: CaregiverColors.tagNowFg,
                        ),
                      ),
                  ],
                ),
            ],
    );
  }

  /// A date a person would recognise, not a timestamp.
  String _when(String iso) {
    final at = DateTime.tryParse(iso)?.toLocal();
    if (at == null) return iso;
    final days = DateTime.now().difference(at).inDays;
    final time =
        '${at.hour}:${at.minute.toString().padLeft(2, '0')}';
    if (days == 0) return 'Today, $time';
    if (days == 1) return 'Yesterday, $time';
    if (days < 7) {
      const names = [
        'Monday',
        'Tuesday',
        'Wednesday',
        'Thursday',
        'Friday',
        'Saturday',
        'Sunday',
      ];
      return '${names[at.weekday - 1]}, $time';
    }
    return '${at.day}/${at.month}, $time';
  }
}

/// One step's bar. Sand rather than red for a weak one, and a dash rather than
/// 0% for a step with nothing behind it — no history is not a bad score.
class _StepRate extends StatelessWidget {
  const _StepRate({
    required this.step,
    required this.tally,
    required this.weak,
    required this.minJudged,
  });

  final MitStep step;
  final ({int passes, int judged})? tally;
  final bool weak;
  final int minJudged;

  @override
  Widget build(BuildContext context) {
    // The hum is never judged, so it has no rate and should not look like a
    // step that scored zero.
    final unjudged = !step.isJudged;
    final enough = tally != null && tally!.judged >= minJudged;
    final rate = enough ? tally!.passes / tally!.judged : null;

    return Padding(
      padding: const EdgeInsets.only(bottom: 14),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Expanded(
                child: Text(
                  step.title,
                  style: const TextStyle(
                    fontSize: 15,
                    fontWeight: FontWeight.w600,
                    color: CaregiverColors.ink,
                  ),
                ),
              ),
              Text(
                unjudged
                    ? 'not judged'
                    : rate == null
                    ? '—'
                    : '${(rate * 100).round()}%',
                style: TextStyle(
                  fontSize: 15,
                  fontWeight: FontWeight.w700,
                  color: weak ? CaregiverColors.weakBar : CaregiverColors.subFg,
                  fontFeatures: const [FontFeature.tabularFigures()],
                ),
              ),
            ],
          ),
          const SizedBox(height: 6),
          ClipRRect(
            borderRadius: BorderRadius.circular(4),
            child: LinearProgressIndicator(
              value: rate ?? 0,
              minHeight: 8,
              backgroundColor: CaregiverColors.faint,
              valueColor: AlwaysStoppedAnimation(
                weak ? CaregiverColors.weakBar : CaregiverColors.green,
              ),
            ),
          ),
        ],
      ),
    );
  }
}
