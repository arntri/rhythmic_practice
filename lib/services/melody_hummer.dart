import 'dart:async';
import 'dart:io';

import 'package:audioplayers/audioplayers.dart';
import 'package:flutter/foundation.dart';
import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';

import '../analysis/wav_writer.dart';
import '../practice/hum_melody.dart';

/// Plays the per-phrase hum that now opens every phrase (canonical MIT step 1:
/// the therapist hums the target melody twice before any words are sung).
///
/// The audio is synthesized on the spot from the phrase's syllable count and
/// stressed syllable — two pitches a minor third apart, one syllable per beat —
/// so no recording is involved and it works for any phrase in any language.
///
/// Completion is driven by whichever comes first, the player's completion event
/// or a timer sized to the known melody length, so the session advances even if
/// the event misfires (the same belt-and-braces the guide player uses).
class MelodyHummer {
  MelodyHummer({AudioPlayer? player}) : _player = player ?? AudioPlayer();

  final AudioPlayer _player;
  StreamSubscription<void>? _completeSub;
  Timer? _advanceTimer;
  Timer? _passTimer;
  bool _fired = false;

  /// Hum the melody for a phrase of [syllableCount] syllables (stressed syllable
  /// [stressIndex]) at [beatPeriodMs] per syllable, [passes] times.
  ///
  /// [onPass] fires as each pass begins (0-based), so the screen can show that
  /// the second hum is the same melody again rather than something new.
  /// [onComplete] fires exactly once, when the whole hum is done.
  ///
  /// Returns the melody it built, so the caller knows how long it will run.
  Future<HumMelody> hum({
    required int syllableCount,
    required int stressIndex,
    required int beatPeriodMs,
    int passes = 2,
    void Function(int pass)? onPass,
    void Function()? onComplete,
  }) async {
    await _cancelPending();
    _fired = false;

    final melody = buildHumMelody(
      syllableCount: syllableCount,
      stressIndex: stressIndex,
      beatPeriodMs: beatPeriodMs,
      passes: passes,
    );

    void fireOnce() {
      if (_fired) return;
      _fired = true;
      onComplete?.call();
    }

    // The pass cues are pure timing off the synthesized melody, so they hold
    // even if playback itself fails and we fall through to the timer.
    if (onPass != null) {
      onPass(0);
      if (melody.passes > 1) {
        var next = 1;
        _passTimer = Timer.periodic(
          Duration(milliseconds: melody.passMs + melody.restMs),
          (t) {
            if (next >= melody.passes) {
              t.cancel();
              return;
            }
            onPass(next++);
          },
        );
      }
    }

    final total = Duration(milliseconds: melody.totalMs);
    try {
      final dir = await getTemporaryDirectory();
      final tmp = File(p.join(dir.path, 'phrase_hum.wav'));
      await tmp.writeAsBytes(WavWriter.encode(melody.samples), flush: true);

      await _player.stop();
      await _player.setVolume(1.0);
      _completeSub = _player.onPlayerComplete.listen((_) => fireOnce());
      _advanceTimer = Timer(
        total + const Duration(milliseconds: 300),
        fireOnce,
      );
      await _player.play(DeviceFileSource(tmp.path));
    } catch (e) {
      // A hum that won't play must never strand the session — hold for the
      // melody's length (the person still has the beat and the tapping) and
      // then move on to the word.
      debugPrint('MelodyHummer: playback failed, holding silently: $e');
      _advanceTimer ??= Timer(total, fireOnce);
    }
    return melody;
  }

  /// Stop the hum and suppress its pending completion.
  Future<void> stop() async {
    await _cancelPending();
    try {
      await _player.stop();
    } catch (_) {}
  }

  Future<void> _cancelPending() async {
    _advanceTimer?.cancel();
    _advanceTimer = null;
    _passTimer?.cancel();
    _passTimer = null;
    await _completeSub?.cancel();
    _completeSub = null;
  }

  Future<void> dispose() async {
    await _cancelPending();
    await _player.dispose();
  }
}
