import 'package:flutter/material.dart';

import '../data/practice_repository.dart';
import '../ml/insights_dashboard.dart';
import '../ml/solo_mode.dart';

/// The caregiver-facing **ML insights dashboard** (audit item 20).
///
/// Display-only and explicitly advisory: it shows the within-session fatigue
/// signal, the recent pass-rate trend, how far the Layer C classifier is from
/// being trusted, and how many words are solo-ready — while making clear that
/// none of it changes progression. The banner up top states the invariant: the
/// caregiver is in charge; the model is not.
class MlInsightsScreen extends StatefulWidget {
  const MlInsightsScreen({super.key, this.repository});

  /// Injectable for tests; defaults to the real repository.
  final PracticeRepository? repository;

  @override
  State<MlInsightsScreen> createState() => _MlInsightsScreenState();
}

class _MlInsightsScreenState extends State<MlInsightsScreen> {
  late final PracticeRepository _repo =
      widget.repository ?? PracticeRepository();

  bool _loading = true;
  String? _error;
  MlInsights? _insights;

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    setState(() {
      _loading = true;
      _error = null;
    });
    try {
      final profile = await _repo.getProfile();
      final insights = await InsightsService(_repo).load(profile.profileId);
      setState(() {
        _insights = insights;
        _loading = false;
      });
    } catch (e) {
      setState(() {
        _error = '$e';
        _loading = false;
      });
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text('Insights (experimental)')),
      body: _loading
          ? const Center(child: CircularProgressIndicator())
          : _error != null
              ? Center(child: Text('Could not load insights:\n$_error'))
              : _body(_insights!),
    );
  }

  Widget _body(MlInsights i) {
    final theme = Theme.of(context);
    return ListView(
      padding: const EdgeInsets.all(16),
      children: [
        // The invariant, stated plainly and first.
        Card(
          color: theme.colorScheme.secondaryContainer,
          child: const Padding(
            padding: EdgeInsets.all(16),
            child: Text(
              'These signals are experimental and for your information only. '
              'They never change the practice levels — you decide every verdict.',
            ),
          ),
        ),
        const SizedBox(height: 16),
        _section('Fatigue (within each recent session)'),
        if (i.sessionFatigue.isEmpty)
          const Text('No recent sessions with tap data yet.')
        else
          ...i.sessionFatigue.map(_fatigueTile),
        const SizedBox(height: 16),
        _section('Pass-rate trend (recent days)'),
        if (i.dailyTrend.isEmpty)
          const Text('No practice recorded yet.')
        else
          ...i.dailyTrend.map((d) => ListTile(
                dense: true,
                title: Text(d.day),
                trailing: Text('${(d.passRate * 100).round()}%'
                    '  (${d.passes}/${d.attempts})'),
              )),
        const SizedBox(height: 16),
        _section('Learned assistant (Layer C)'),
        ListTile(
          leading: Icon(
            i.mlGates ? Icons.verified : Icons.school_outlined,
            color: i.mlGates ? Colors.green : theme.disabledColor,
          ),
          title: Text(i.mlGates
              ? 'Trusted — meets the precision bar'
              : 'Not trusted yet'),
          subtitle: Text(i.graduation.reason),
        ),
        const SizedBox(height: 16),
        _section('Solo-ready words'),
        ListTile(
          leading: const Icon(Icons.self_improvement),
          title: Text('${i.soloEligibleCount} word(s) mastered enough for solo'),
          subtitle: Text(i.soloAuthority == SoloAuthority.advisoryOnly
              ? 'Solo practice would be advisory-only — you still confirm.'
              : 'Solo practice may be model-assisted.'),
        ),
      ],
    );
  }

  Widget _section(String title) => Padding(
        padding: const EdgeInsets.only(bottom: 8),
        child: Text(title, style: Theme.of(context).textTheme.titleMedium),
      );

  Widget _fatigueTile(SessionFatigue s) {
    final est = s.estimate;
    final String label;
    final Color color;
    if (est.lowConfidence) {
      label = 'Not enough data';
      color = Theme.of(context).disabledColor;
    } else if (est.isFatigued) {
      label = 'Signs of tiring (${(est.score * 100).round()}%)';
      color = Colors.orange;
    } else {
      label = 'Steady (${(est.score * 100).round()}%)';
      color = Colors.green;
    }
    return ListTile(
      dense: true,
      leading: Icon(Icons.battery_alert, color: color),
      title: Text(s.startedAt),
      trailing: Text(label, style: TextStyle(color: color)),
    );
  }
}
