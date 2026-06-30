import 'package:flutter/material.dart';

import '../analytics/trend.dart';
import '../data/models.dart';
import '../data/practice_repository.dart';
import '../services/progress_analytics.dart';

/// Offline history for the caregiver: how each phrase is going over time, and a
/// list of recent sessions. Reads only the local database, so it works with no
/// connection and shows only already-final data (verdicts + tap-sync scores).
class HistoryScreen extends StatefulWidget {
  const HistoryScreen({super.key, this.repository});

  /// Injectable for tests; defaults to the real repository.
  final PracticeRepository? repository;

  @override
  State<HistoryScreen> createState() => _HistoryScreenState();
}

class _HistoryScreenState extends State<HistoryScreen> {
  late final PracticeRepository _repo =
      widget.repository ?? PracticeRepository();

  bool _loading = true;
  String? _error;
  List<PhraseStat> _phraseStats = [];
  List<SessionSummary> _sessions = [];
  List<DailySummary> _daily = [];
  ProgressReport? _report;

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
      final stats = await _repo.getPhraseStats();
      final sessions = await _repo.getSessionSummaries();
      final profile = await _repo.getProfile();
      final daily = await _repo.getDailySummaries(profile.profileId);
      // Display-only trends — never feeds progression.
      final report = await ProgressAnalytics(_repo).compute(profile.profileId);
      setState(() {
        _phraseStats = stats;
        _sessions = sessions;
        _daily = daily;
        _report = report;
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
      appBar: AppBar(
        title: const Text('History'),
        actions: [
          IconButton(
            icon: const Icon(Icons.refresh),
            onPressed: _loading ? null : _load,
          ),
        ],
      ),
      body: _buildBody(),
    );
  }

  Widget _buildBody() {
    if (_loading) return const Center(child: CircularProgressIndicator());
    if (_error != null) {
      return Center(
        child: Padding(padding: const EdgeInsets.all(24), child: Text(_error!)),
      );
    }
    if (_phraseStats.isEmpty && _sessions.isEmpty) {
      return const Center(
        child: Padding(
          padding: EdgeInsets.all(24),
          child: Text('No practice recorded yet.', textAlign: TextAlign.center),
        ),
      );
    }

    final report = _report;
    return ListView(
      padding: const EdgeInsets.all(16),
      children: [
        if (report != null && report.perWord.isNotEmpty) ...[
          Text('Trends over time',
              style: Theme.of(context).textTheme.titleMedium),
          const SizedBox(height: 8),
          _overallTrendRow('Pass rate', report.overallPassRate),
          _overallTrendRow('Sound match', report.overallSimilarity),
          _overallTrendRow('Response time', report.overallLatency),
          const SizedBox(height: 8),
          for (final w in report.perWord) _wordTrendTile(w),
          const Divider(height: 32),
        ],
        Text('By phrase', style: Theme.of(context).textTheme.titleMedium),
        const SizedBox(height: 8),
        if (_phraseStats.isEmpty)
          const Text('No attempts yet.')
        else
          for (final s in _phraseStats) _phraseTile(s),

        const Divider(height: 32),
        Text('By day', style: Theme.of(context).textTheme.titleMedium),
        const SizedBox(height: 8),
        if (_daily.isEmpty)
          const Text('No days yet.')
        else
          for (final d in _daily) _dayTile(d),

        const Divider(height: 32),
        Text('Recent sessions', style: Theme.of(context).textTheme.titleMedium),
        const SizedBox(height: 8),
        if (_sessions.isEmpty)
          const Text('No sessions yet.')
        else
          for (final s in _sessions) _sessionTile(s),
      ],
    );
  }

  Widget _phraseTile(PhraseStat s) {
    final passPct = (s.passRate * 100).round();
    final sync =
        s.avgSyncScore == null ? '—' : '${(s.avgSyncScore! * 100).round()}%';
    return Card(
      child: Padding(
        padding: const EdgeInsets.all(12),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              mainAxisAlignment: MainAxisAlignment.spaceBetween,
              children: [
                Text(s.phraseText,
                    style: Theme.of(context).textTheme.titleSmall),
                Text('${s.attempts} attempt${s.attempts == 1 ? '' : 's'}'),
              ],
            ),
            const SizedBox(height: 8),
            // Pass-rate bar.
            ClipRRect(
              borderRadius: BorderRadius.circular(4),
              child: LinearProgressIndicator(
                value: s.passRate,
                minHeight: 8,
                backgroundColor: Colors.grey.withValues(alpha: 0.2),
                color: Colors.green,
              ),
            ),
            const SizedBox(height: 6),
            Text(
              '$passPct% pass  ·  ${s.passes}P / ${s.fails}F / ${s.unsure}U  '
              '·  avg sync $sync',
              style: Theme.of(context).textTheme.bodySmall,
            ),
          ],
        ),
      ),
    );
  }

  // A small coloured chip describing a metric's trend.
  Widget _trendChip(MetricTrend m) {
    final (icon, color, label) = switch (m.trend) {
      Trend.improving => (Icons.trending_up, Colors.green, 'Improving'),
      Trend.declining => (Icons.trending_down, Colors.orange, 'Slipping'),
      Trend.plateau => (Icons.trending_flat, Colors.blueGrey, 'Steady'),
      Trend.insufficient => (Icons.more_horiz, Colors.grey, 'Not enough yet'),
    };
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 4),
      decoration: BoxDecoration(
        color: color.withValues(alpha: 0.12),
        borderRadius: BorderRadius.circular(20),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(icon, size: 16, color: color),
          const SizedBox(width: 6),
          Text(label,
              style: TextStyle(
                  color: color, fontWeight: FontWeight.w600, fontSize: 13)),
        ],
      ),
    );
  }

  Widget _overallTrendRow(String label, MetricTrend m) {
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 4),
      child: Row(
        mainAxisAlignment: MainAxisAlignment.spaceBetween,
        children: [Text(label), _trendChip(m)],
      ),
    );
  }

  Widget _wordTrendTile(WordProgress w) {
    return ListTile(
      dense: true,
      contentPadding: EdgeInsets.zero,
      title: Text(w.phraseText),
      // The caregiver's pass-rate trend is the headline; sound-match is shown too.
      trailing: Row(
        mainAxisSize: MainAxisSize.min,
        children: [_trendChip(w.passRate)],
      ),
    );
  }

  Widget _dayTile(DailySummary d) {
    final sim = d.avgSimilarity == null
        ? ''
        : '  ·  match ${(d.avgSimilarity! * 100).round()}%';
    return ListTile(
      dense: true,
      leading: const Icon(Icons.calendar_today, size: 18),
      title: Text(d.day),
      subtitle: Text('${d.attempts} attempt${d.attempts == 1 ? '' : 's'}  ·  '
          '${d.passes}P / ${d.fails}F / ${d.unsure}U$sim'),
      trailing: Text('${(d.passRate * 100).round()}%'),
    );
  }

  Widget _sessionTile(SessionSummary s) {
    final when = s.startedAt.length >= 16
        ? s.startedAt.substring(0, 16).replaceFirst('T', ' ')
        : s.startedAt;
    return ListTile(
      dense: true,
      leading: const Icon(Icons.event_note),
      title: Text(when),
      trailing: Text('${s.passes}/${s.attempts} passed'),
    );
  }
}
