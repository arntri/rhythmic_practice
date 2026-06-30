import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../services/cloud_sharing.dart';

/// Shows practice progress from the cloud: your own and anything family has
/// shared with you. Also where you find your share code and redeem someone
/// else's (Step 2e).
class ProgressScreen extends StatefulWidget {
  const ProgressScreen({super.key});

  @override
  State<ProgressScreen> createState() => _ProgressScreenState();
}

class _ProgressScreenState extends State<ProgressScreen> {
  final _sharing = CloudSharing.instance;
  final _codeController = TextEditingController();

  bool _loading = true;
  String? _error;
  List<CloudProfileSummary> _profiles = [];
  List<CloudAttempt> _attempts = [];

  @override
  void initState() {
    super.initState();
    if (_sharing.isReady) {
      _load();
    } else {
      _loading = false;
    }
  }

  @override
  void dispose() {
    _codeController.dispose();
    super.dispose();
  }

  Future<void> _load() async {
    setState(() {
      _loading = true;
      _error = null;
    });
    try {
      final profiles = await _sharing.accessibleProfiles();
      final attempts = await _sharing.recentAttempts();
      setState(() {
        _profiles = profiles;
        _attempts = attempts;
        _loading = false;
      });
    } catch (e) {
      setState(() {
        _error = '$e';
        _loading = false;
      });
    }
  }

  Future<void> _join() async {
    final code = _codeController.text.trim();
    if (code.isEmpty) return;
    try {
      await _sharing.joinWithCode(code);
      _codeController.clear();
      if (mounted) {
        ScaffoldMessenger.of(context)
            .showSnackBar(const SnackBar(content: Text('Joined! Loading…')));
      }
      await _load();
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context)
            .showSnackBar(SnackBar(content: Text('Could not join: $e')));
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: const Text('Progress'),
        actions: [
          if (_sharing.isReady)
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
    if (!_sharing.isReady) {
      return const Center(
        child: Padding(
          padding: EdgeInsets.all(24),
          child: Text(
            'Sign in (tap the account icon on the home screen) to see and share '
            'progress with family.',
            textAlign: TextAlign.center,
          ),
        ),
      );
    }
    if (_loading) return const Center(child: CircularProgressIndicator());
    if (_error != null) {
      return Center(
        child: Padding(padding: const EdgeInsets.all(24), child: Text(_error!)),
      );
    }

    return ListView(
      padding: const EdgeInsets.all(16),
      children: [
        Text('Share codes', style: Theme.of(context).textTheme.titleMedium),
        const SizedBox(height: 4),
        if (_profiles.isEmpty)
          const Text('No profiles yet. Practice once with sharing enabled to '
              'create one.')
        else
          for (final p in _profiles) _shareCodeTile(p),

        const Divider(height: 32),
        Text('Join a family member', style: Theme.of(context).textTheme.titleMedium),
        const SizedBox(height: 8),
        Row(
          children: [
            Expanded(
              child: TextField(
                controller: _codeController,
                textCapitalization: TextCapitalization.characters,
                decoration: const InputDecoration(
                  labelText: 'Enter share code',
                  border: OutlineInputBorder(),
                ),
              ),
            ),
            const SizedBox(width: 8),
            FilledButton(onPressed: _join, child: const Text('Join')),
          ],
        ),

        const Divider(height: 32),
        Text('Recent attempts (${_attempts.length})',
            style: Theme.of(context).textTheme.titleMedium),
        const SizedBox(height: 8),
        if (_attempts.isEmpty)
          const Text('No attempts to show yet.')
        else
          for (final a in _attempts) _attemptTile(a),
      ],
    );
  }

  Widget _shareCodeTile(CloudProfileSummary p) {
    final code = p.shareCode ?? '—';
    return Card(
      child: ListTile(
        title: Text(p.displayName ?? 'Practice profile'),
        subtitle: Text('Code: $code'),
        trailing: IconButton(
          icon: const Icon(Icons.copy),
          tooltip: 'Copy code',
          onPressed: p.shareCode == null
              ? null
              : () {
                  Clipboard.setData(ClipboardData(text: p.shareCode!));
                  ScaffoldMessenger.of(context).showSnackBar(
                      const SnackBar(content: Text('Code copied')));
                },
        ),
      ),
    );
  }

  Widget _attemptTile(CloudAttempt a) {
    final (label, color) = switch (a.evaluationLabel) {
      0 => ('Fail', Colors.red),
      1 => ('Pass', Colors.green),
      _ => ('Unsure', Colors.orange),
    };
    final score =
        a.syncScore == null ? '' : '  ·  sync ${(a.syncScore! * 100).round()}%';
    final when = a.attemptedAt.length >= 16
        ? a.attemptedAt.substring(0, 16).replaceFirst('T', ' ')
        : a.attemptedAt;
    return ListTile(
      dense: true,
      leading: CircleAvatar(
        backgroundColor: color,
        radius: 6,
      ),
      title: Text(a.phraseText),
      subtitle: Text('$label$score'),
      trailing: Text(when, style: Theme.of(context).textTheme.bodySmall),
    );
  }
}
