import 'dart:io';

import 'package:flutter/material.dart';
import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';
import 'package:uuid/uuid.dart';

import '../data/models.dart';
import '../data/practice_repository.dart';
import '../services/guide_recorder.dart';

enum _Stage { idle, recording, reviewing, saved }

/// Caregiver flow for recording each phrase's spoken guide (therapy addendum §2,
/// revised). The caregiver says the phrase ONCE, slowly and stretched, in a
/// natural voice — **no metronome plays**. Syllable-nucleus detection pre-fills a
/// count from the recording's envelope; the caregiver then confirms or adjusts
/// it (merge/split) — detection is never trusted blindly. The clip is saved
/// AES-encrypted (also the DTW reference). This same flow is the onboarding.
class GuideRecordingScreen extends StatefulWidget {
  const GuideRecordingScreen({
    super.key,
    required this.phrases,
    this.repository,
  });

  /// The phrases to record, walked through in order.
  final List<PracticePhrase> phrases;

  /// Injectable for tests; defaults to the real repository.
  final PracticeRepository? repository;

  @override
  State<GuideRecordingScreen> createState() => _GuideRecordingScreenState();
}

class _GuideRecordingScreenState extends State<GuideRecordingScreen> {
  late final PracticeRepository _repo = widget.repository ?? PracticeRepository();
  final GuideRecorder _recorder = GuideRecorder();

  int _index = 0;
  _Stage _stage = _Stage.idle;
  String? _encryptedPath; // current take's encrypted clip
  List<int> _nuclei = []; // editable syllable-nucleus timings (ms)
  String? _status;

  PracticePhrase get _current => widget.phrases[_index];

  Future<Directory> _guidesDir() async {
    final dir = await getApplicationDocumentsDirectory();
    final guides = Directory(p.join(dir.path, 'guides'));
    if (!await guides.exists()) await guides.create(recursive: true);
    return guides;
  }

  Future<void> _startRecording() async {
    final guides = await _guidesDir();
    final raw = p.join(guides.path, '${const Uuid().v4()}.wav');
    final ok = await _recorder.start(rawPath: raw);
    if (!mounted) return;
    if (!ok) {
      setState(() => _status = 'Microphone permission denied.');
      return;
    }
    setState(() {
      _stage = _Stage.recording;
      _status = null;
    });
  }

  Future<void> _stopRecording() async {
    final guides = await _guidesDir();
    final enc =
        p.join(guides.path, '${_current.phraseId}_${const Uuid().v4()}.enc');
    final result = await _recorder.stop(encryptedPath: enc);
    if (!mounted) return;
    if (result == null) {
      setState(() {
        _stage = _Stage.idle;
        _status = 'Nothing recorded — try again.';
      });
      return;
    }
    setState(() {
      _encryptedPath = result.encryptedPath;
      _nuclei = List<int>.from(result.detection.nucleiMs);
      _stage = _Stage.reviewing;
      _status = null;
    });
  }

  // Merge the two closest nuclei into one (over-detected a syllable).
  void _merge() {
    if (_nuclei.length < 2) return;
    var bestI = 0;
    var bestGap = 1 << 30;
    for (var i = 0; i < _nuclei.length - 1; i++) {
      final g = _nuclei[i + 1] - _nuclei[i];
      if (g < bestGap) {
        bestGap = g;
        bestI = i;
      }
    }
    final mid = ((_nuclei[bestI] + _nuclei[bestI + 1]) / 2).round();
    setState(() {
      _nuclei.removeRange(bestI, bestI + 2);
      _nuclei.insert(bestI, mid);
    });
  }

  // Split: add a nucleus in the largest gap (under-detected a syllable).
  void _split() {
    setState(() {
      if (_nuclei.isEmpty) {
        _nuclei = [0];
        return;
      }
      if (_nuclei.length == 1) {
        final n = _nuclei.first;
        _nuclei = [(n - 150).clamp(0, 1 << 30), n + 150];
        return;
      }
      var bestI = 0;
      var bestGap = -1;
      for (var i = 0; i < _nuclei.length - 1; i++) {
        final g = _nuclei[i + 1] - _nuclei[i];
        if (g > bestGap) {
          bestGap = g;
          bestI = i;
        }
      }
      final mid = ((_nuclei[bestI] + _nuclei[bestI + 1]) / 2).round();
      _nuclei.insert(bestI + 1, mid);
    });
  }

  Future<void> _confirm() async {
    final path = _encryptedPath;
    if (path == null || _nuclei.isEmpty) return;
    await _repo.setGuideClip(
      _current.phraseId,
      path,
      _nuclei.length,
      nucleiMs: _nuclei,
    );
    if (!mounted) return;
    setState(() => _stage = _Stage.saved);
  }

  void _recordAgain() {
    setState(() {
      _stage = _Stage.idle;
      _encryptedPath = null;
      _nuclei = [];
      _status = null;
    });
  }

  void _next() {
    if (_index + 1 < widget.phrases.length) {
      setState(() {
        _index++;
        _stage = _Stage.idle;
        _encryptedPath = null;
        _nuclei = [];
        _status = null;
      });
    } else {
      Navigator.of(context).maybePop();
    }
  }

  @override
  void dispose() {
    _recorder.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final isLast = _index + 1 >= widget.phrases.length;
    return Scaffold(
      appBar: AppBar(
        title: Text('Record guides — ${_index + 1}/${widget.phrases.length}'),
      ),
      // Scrollable + stretched so every control (esp. Confirm/Save) stays
      // reachable in landscape, where vertical space is tight.
      body: SafeArea(
        child: SingleChildScrollView(
          padding: const EdgeInsets.symmetric(horizontal: 24, vertical: 16),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Text(
                _current.phraseText,
                textAlign: TextAlign.center,
                style:
                    const TextStyle(fontSize: 40, fontWeight: FontWeight.bold),
              ),
              const SizedBox(height: 16),
              ..._stageContent(isLast),
              if (_status != null) ...[
                const SizedBox(height: 12),
                Text(_status!,
                    textAlign: TextAlign.center,
                    style: Theme.of(context).textTheme.bodyMedium),
              ],
            ],
          ),
        ),
      ),
    );
  }

  List<Widget> _stageContent(bool isLast) {
    switch (_stage) {
      case _Stage.idle:
        return [
          Text(
            'Say it once — slowly and stretched — in your natural voice.',
            textAlign: TextAlign.center,
            style: Theme.of(context).textTheme.bodyLarge,
          ),
          const SizedBox(height: 24),
          FilledButton.icon(
            onPressed: _startRecording,
            style: FilledButton.styleFrom(minimumSize: const Size.fromHeight(64)),
            icon: const Icon(Icons.mic),
            label: const Text('Record'),
          ),
        ];
      case _Stage.recording:
        return [
          const Text('Recording… say the whole phrase slowly, then tap Stop.',
              textAlign: TextAlign.center),
          const SizedBox(height: 24),
          FilledButton.icon(
            onPressed: _stopRecording,
            style: FilledButton.styleFrom(
              backgroundColor: Colors.red,
              minimumSize: const Size.fromHeight(64),
            ),
            icon: const Icon(Icons.stop),
            label: const Text('Stop'),
          ),
        ];
      case _Stage.reviewing:
        return [
          Text(
            'Detected ${_nuclei.length} part${_nuclei.length == 1 ? '' : 's'}. '
            'Adjust until it matches the syllables, then confirm.',
            textAlign: TextAlign.center,
            style: Theme.of(context).textTheme.bodyLarge,
          ),
          const SizedBox(height: 16),
          _partsDots(),
          const SizedBox(height: 16),
          Row(
            mainAxisAlignment: MainAxisAlignment.center,
            children: [
              OutlinedButton.icon(
                onPressed: _nuclei.length < 2 ? null : _merge,
                icon: const Icon(Icons.remove),
                label: const Text('Merge'),
              ),
              const SizedBox(width: 16),
              Text('${_nuclei.length}',
                  style: Theme.of(context).textTheme.headlineMedium),
              const SizedBox(width: 16),
              OutlinedButton.icon(
                onPressed: _split,
                icon: const Icon(Icons.add),
                label: const Text('Split'),
              ),
            ],
          ),
          const SizedBox(height: 24),
          FilledButton(
            onPressed: _nuclei.isEmpty ? null : _confirm,
            style: FilledButton.styleFrom(minimumSize: const Size.fromHeight(56)),
            child: Text('Confirm ${_nuclei.length} syllable(s)'),
          ),
          const SizedBox(height: 8),
          TextButton(onPressed: _recordAgain, child: const Text('Record again')),
        ];
      case _Stage.saved:
        return [
          Icon(Icons.check_circle, color: Colors.green, size: 48),
          const SizedBox(height: 8),
          Text('Saved — ${_nuclei.length} syllable(s).',
              style: Theme.of(context).textTheme.titleMedium),
          const SizedBox(height: 24),
          FilledButton(
            onPressed: _next,
            style: FilledButton.styleFrom(minimumSize: const Size.fromHeight(56)),
            child: Text(isLast ? 'Done' : 'Next phrase'),
          ),
          const SizedBox(height: 8),
          TextButton(onPressed: _recordAgain, child: const Text('Record again')),
        ];
    }
  }

  Widget _partsDots() {
    return Wrap(
      spacing: 12,
      alignment: WrapAlignment.center,
      children: [
        for (var i = 0; i < _nuclei.length; i++)
          CircleAvatar(radius: 16, child: Text('${i + 1}')),
      ],
    );
  }
}
