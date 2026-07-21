import 'dart:io';
import 'dart:typed_data';

import 'package:audioplayers/audioplayers.dart';
import 'package:flutter/material.dart';
import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';
import 'package:uuid/uuid.dart';

import '../analysis/wav_writer.dart';
import '../data/models.dart';
import '../data/practice_repository.dart';
import '../practice/intonation_contour.dart';
import '../practice/intonation_reference.dart';
import '../services/guide_recorder.dart';

// idle → recording → reviewing (confirm syllables) → stress (tap the high note)
// → result (contour verdict: good / flat / mis-stressed) → saved.
enum _Stage { idle, recording, reviewing, stress, result, saved }

/// Caregiver flow for recording each phrase's **sung/intoned** guide and its
/// high–low melody (therapy addendum §2 + the intonation flow).
///
/// The patient copies the guide's melody, so the guide must carry a clear,
/// correct high–low contour. We do NOT fully automate and we do NOT fully depend
/// on the caregiver's musical skill: the caregiver PRODUCES (sings it) and
/// APPROVES (taps which syllable is high, confirms the result); the machine
/// DETECTS (syllable nuclei, pitch contour) and CHECKS ("good enough").
///
/// Steps: hear an example → record the imitation → confirm the syllables → tap
/// the high-note syllable → the machine checks the contour → targeted feedback +
/// re-record if it's flat or mis-stressed → confirm and save. After a couple of
/// failed re-records it falls back to saving the natural recording WITH the
/// on-screen melody cue, so the patient still gets the contour (never flat-and-
/// unnoticed) — the caregiver is never trapped in a loop.
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
  final AudioPlayer _refPlayer = AudioPlayer(); // plays synthesized examples

  int _index = 0;
  _Stage _stage = _Stage.idle;
  String? _encryptedPath; // current take's encrypted clip
  List<int> _nuclei = []; // editable syllable-nucleus timings (ms)
  Float64List? _samples; // trimmed samples of the current take (for contour)
  int? _stressIndex; // caregiver-tapped high-note syllable
  ContourCheck? _check; // last contour verdict
  int _failedTakes = 0; // consecutive flat/mis-stressed takes (for the fallback)
  String? _status;

  /// After this many flat/mis-stressed takes we offer the graceful fallback
  /// (save the natural recording + rely on the on-screen melody cue) so the
  /// caregiver is never stuck re-recording.
  static const _fallbackAfter = 2;

  PracticePhrase get _current => widget.phrases[_index];

  Future<Directory> _guidesDir() async {
    final dir = await getApplicationDocumentsDirectory();
    final guides = Directory(p.join(dir.path, 'guides'));
    if (!await guides.exists()) await guides.create(recursive: true);
    return guides;
  }

  // --- Reference-melody playback (item 1) ----------------------------------
  // Synthesize a short high–low example and play it. This is a demo for the
  // caregiver to COPY — never the patient's guide (that's the recording).
  Future<void> _playSamples(Float64List samples) async {
    try {
      final bytes = WavWriter.encode(samples);
      final dir = await getTemporaryDirectory();
      final f = File(p.join(dir.path, 'ref_${const Uuid().v4()}.wav'));
      await f.writeAsBytes(bytes, flush: true);
      await _refPlayer.stop();
      await _refPlayer.play(DeviceFileSource(f.path));
    } catch (e) {
      debugPrint('Reference playback failed: $e');
    }
  }

  // The phrase-shaped example once we know the syllable count + high note; the
  // generic "naa-naa" falling shape before that.
  Future<void> _playExample() {
    final count = _nuclei.length;
    final stress = _stressIndex;
    if (count >= 1 && stress != null) {
      return _playSamples(synthesizeReferenceMelody(
          syllableCount: count, stressIndex: stress));
    }
    return _playSamples(genericTwoTone());
  }

  // Item 5: teach the tune with two contrasting two-syllable demos, no jargon —
  // "WA-ter" (high→low, strong part first) vs "a-GAIN" (low→high, strong part
  // second). The caregiver hears that the STRONG part always goes up.
  Future<void> _playTwoTone(int stressIndex) => _playSamples(
      synthesizeReferenceMelody(syllableCount: 2, stressIndex: stressIndex));

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
      _samples = result.samples;
      _check = null;
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

  // Syllables confirmed → go choose which one is the high note. Seed the stress
  // pick at the syllable the recording actually stressed (a helpful default the
  // caregiver can override), else keep any earlier choice, else the first.
  void _toStress() {
    final samples = _samples;
    var seed = _stressIndex ?? _current.stressIndex ?? 0;
    if (samples != null && samples.isNotEmpty && _nuclei.isNotEmpty) {
      final detected = analyzeContour(samples, _nuclei).stressedIndex;
      if (detected >= 0) seed = detected;
    }
    setState(() {
      _stressIndex = seed.clamp(0, _nuclei.length - 1);
      _stage = _Stage.stress;
    });
  }

  // Run the "good enough" contour check on the current take against the tapped
  // high-note syllable (items 4–5).
  void _checkContour() {
    final samples = _samples;
    final stress = _stressIndex;
    if (samples == null || samples.isEmpty || stress == null) {
      // No samples to analyze (trim/decode failed) — don't block the caregiver;
      // trust their tap and move to confirm.
      setState(() {
        _check = const ContourCheck(ContourVerdict.good);
        _stage = _Stage.result;
      });
      return;
    }
    final contour = analyzeContour(samples, _nuclei);
    setState(() {
      _check = checkContour(contour, expectedStressIndex: stress);
      if (!_check!.isGood) _failedTakes++;
      _stage = _Stage.result;
    });
  }

  Future<void> _save() async {
    final path = _encryptedPath;
    if (path == null || _nuclei.isEmpty) return;
    await _repo.setGuideClip(
      _current.phraseId,
      path,
      _nuclei.length,
      nucleiMs: _nuclei,
      stressIndex: _stressIndex,
    );
    if (!mounted) return;
    setState(() => _stage = _Stage.saved);
  }

  // Record again for a flat/mis-stressed take — KEEP the syllable count and the
  // tapped high note (the target doesn't change, only the performance).
  void _recordAgain() {
    _refPlayer.stop();
    setState(() {
      _stage = _Stage.idle;
      _encryptedPath = null;
      _samples = null;
      _check = null;
      _status = null;
    });
  }

  void _next() {
    _refPlayer.stop();
    if (_index + 1 < widget.phrases.length) {
      setState(() {
        _index++;
        _stage = _Stage.idle;
        _encryptedPath = null;
        _nuclei = [];
        _samples = null;
        _stressIndex = null;
        _check = null;
        _failedTakes = 0;
        _status = null;
      });
    } else {
      Navigator.of(context).maybePop();
    }
  }

  @override
  void dispose() {
    _recorder.dispose();
    _refPlayer.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final isLast = _index + 1 >= widget.phrases.length;
    return Scaffold(
      appBar: AppBar(
        title: Text('Record guides — ${_index + 1}/${widget.phrases.length}'),
      ),
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
            'The strong part goes up. Hear it:',
            textAlign: TextAlign.center,
            style: Theme.of(context).textTheme.bodyLarge,
          ),
          const SizedBox(height: 16),
          // Item 5: two contrasting demos — the strong part is high in both, but
          // it's the first syllable in "WA-ter" and the second in "a-GAIN".
          _teachMelody(),
          const SizedBox(height: 20),
          const Text('Now you — say it slowly, in a gentle sing-song.',
              textAlign: TextAlign.center),
          const SizedBox(height: 16),
          FilledButton.icon(
            onPressed: _startRecording,
            style: FilledButton.styleFrom(minimumSize: const Size.fromHeight(64)),
            icon: const Icon(Icons.mic),
            label: const Text('Record'),
          ),
        ];
      case _Stage.recording:
        return [
          const Text('Recording… sing the whole phrase slowly, then tap Stop.',
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
            'Adjust until it matches the syllables, then continue.',
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
            onPressed: _nuclei.isEmpty ? null : _toStress,
            style: FilledButton.styleFrom(minimumSize: const Size.fromHeight(56)),
            child: const Text('Next: choose the high note'),
          ),
          const SizedBox(height: 8),
          TextButton(onPressed: _recordAgain, child: const Text('Record again')),
        ];
      case _Stage.stress:
        return [
          Text(
            'Which part gets the HIGH note? Tap it.',
            textAlign: TextAlign.center,
            style: Theme.of(context).textTheme.bodyLarge,
          ),
          const SizedBox(height: 20),
          // Item 2: the high–low cue, with the tapped syllable raised.
          _contourCue(stressIndex: _stressIndex, tappable: true),
          const SizedBox(height: 20),
          OutlinedButton.icon(
            onPressed: _playExample,
            icon: const Icon(Icons.volume_up),
            label: const Text('Hear it this way'),
          ),
          const SizedBox(height: 16),
          FilledButton(
            onPressed: _stressIndex == null ? null : _checkContour,
            style: FilledButton.styleFrom(minimumSize: const Size.fromHeight(56)),
            child: const Text('Check my recording'),
          ),
          const SizedBox(height: 8),
          TextButton(onPressed: _recordAgain, child: const Text('Record again')),
        ];
      case _Stage.result:
        return _resultContent();
      case _Stage.saved:
        return [
          const Icon(Icons.check_circle, color: Colors.green, size: 48),
          const SizedBox(height: 8),
          Text('Saved — ${_nuclei.length} syllable(s), high on part '
              '${(_stressIndex ?? 0) + 1}.',
              textAlign: TextAlign.center,
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

  // The contour verdict + next action (items 6–8).
  List<Widget> _resultContent() {
    final check = _check;
    final stress = (_stressIndex ?? 0) + 1; // 1-based for humans
    if (check == null || check.isGood) {
      // Item 7: approve and save.
      return [
        const Icon(Icons.check_circle, color: Colors.green, size: 40),
        const SizedBox(height: 8),
        Text('Sounds good — the high note is on part $stress.',
            textAlign: TextAlign.center,
            style: Theme.of(context).textTheme.titleMedium),
        const SizedBox(height: 16),
        _contourCue(stressIndex: _stressIndex, tappable: false),
        const SizedBox(height: 24),
        FilledButton.icon(
          onPressed: _save,
          style: FilledButton.styleFrom(minimumSize: const Size.fromHeight(56)),
          icon: const Icon(Icons.check),
          label: const Text('Save this guide'),
        ),
        const SizedBox(height: 8),
        TextButton(onPressed: _recordAgain, child: const Text('Record again')),
      ];
    }

    // Item 6: one specific fix at a time.
    final String message;
    if (check.verdict == ContourVerdict.flat) {
      message = 'That came out fairly even — lift your voice more on part '
          '${(check.offendingSyllable ?? 0) + 1}, like the example.';
    } else if (check.verdict == ContourVerdict.misStressed) {
      message = 'The high note landed on part '
          '${(check.offendingSyllable ?? 0) + 1}. Try the high note on part '
          '${(check.expectedSyllable ?? 0) + 1} instead.';
    } else {
      message = 'That was very quiet — try again a little louder.';
    }

    return [
      const Icon(Icons.info_outline, color: Color(0xFF8A6D1F), size: 40),
      const SizedBox(height: 8),
      Text(message,
          textAlign: TextAlign.center,
          style: Theme.of(context).textTheme.titleMedium),
      const SizedBox(height: 16),
      _contourCue(stressIndex: _stressIndex, tappable: false),
      const SizedBox(height: 16),
      OutlinedButton.icon(
        onPressed: _playExample,
        icon: const Icon(Icons.volume_up),
        label: const Text('Hear it this way'),
      ),
      const SizedBox(height: 16),
      FilledButton.icon(
        onPressed: _recordAgain,
        style: FilledButton.styleFrom(minimumSize: const Size.fromHeight(56)),
        icon: const Icon(Icons.mic),
        label: const Text('Record again'),
      ),
      // Item 8: after a couple of tries, never trap the caregiver — offer to use
      // the recording as-is; the on-screen melody cue still carries the contour.
      if (_failedTakes >= _fallbackAfter) ...[
        const SizedBox(height: 8),
        TextButton(
          onPressed: _save,
          child: const Text(
              'Use this recording — the melody will show on screen'),
        ),
      ],
    ];
  }

  // Item 5: the two-demo teaching row. Each chip shows a tiny high–low shape and
  // plays it on tap — "WA-ter" rises on part 1, "a-GAIN" rises on part 2.
  Widget _teachMelody() {
    return Row(
      mainAxisAlignment: MainAxisAlignment.center,
      children: [
        Expanded(child: _twoToneDemo(label: 'WA-ter', stressIndex: 0)),
        const SizedBox(width: 12),
        Expanded(child: _twoToneDemo(label: 'a-GAIN', stressIndex: 1)),
      ],
    );
  }

  Widget _twoToneDemo({required String label, required int stressIndex}) {
    const raise = 10.0;
    Widget dot(bool high) => Transform.translate(
          offset: Offset(0, high ? -raise : raise),
          child: CircleAvatar(
            radius: 7,
            backgroundColor: high
                ? Theme.of(context).colorScheme.primary
                : Theme.of(context).colorScheme.surfaceContainerHighest,
          ),
        );
    return OutlinedButton(
      onPressed: () => _playTwoTone(stressIndex),
      style: OutlinedButton.styleFrom(
        padding: const EdgeInsets.symmetric(vertical: 12),
      ),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          SizedBox(
            height: 32,
            child: Row(
              mainAxisAlignment: MainAxisAlignment.center,
              children: [
                dot(stressIndex == 0),
                const SizedBox(width: 8),
                dot(stressIndex == 1),
              ],
            ),
          ),
          const SizedBox(height: 6),
          Row(
            mainAxisAlignment: MainAxisAlignment.center,
            children: [
              const Icon(Icons.volume_up, size: 16),
              const SizedBox(width: 6),
              Text(label),
            ],
          ),
        ],
      ),
    );
  }

  // Plain numbered dots for the syllable-count review.
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

  // The high–low melody cue (item 2): one dot per syllable, the stressed one
  // raised. When [tappable], tapping a dot sets it as the high note.
  Widget _contourCue({required int? stressIndex, required bool tappable}) {
    const raise = 28.0;
    return SizedBox(
      height: 80,
      child: Row(
        mainAxisAlignment: MainAxisAlignment.center,
        crossAxisAlignment: CrossAxisAlignment.center,
        children: [
          for (var i = 0; i < _nuclei.length; i++)
            Padding(
              padding: const EdgeInsets.symmetric(horizontal: 8),
              child: Transform.translate(
                offset: Offset(0, i == stressIndex ? -raise : raise),
                child: GestureDetector(
                  onTap: tappable
                      ? () => setState(() => _stressIndex = i)
                      : null,
                  child: CircleAvatar(
                    radius: 20,
                    backgroundColor: i == stressIndex
                        ? Theme.of(context).colorScheme.primary
                        : Theme.of(context).colorScheme.surfaceContainerHighest,
                    child: Text(
                      '${i + 1}',
                      style: TextStyle(
                        color: i == stressIndex
                            ? Theme.of(context).colorScheme.onPrimary
                            : Theme.of(context).colorScheme.onSurface,
                        fontWeight: FontWeight.bold,
                      ),
                    ),
                  ),
                ),
              ),
            ),
        ],
      ),
    );
  }
}
