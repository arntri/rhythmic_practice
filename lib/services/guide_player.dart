import 'dart:async';
import 'dart:io';

import 'package:audioplayers/audioplayers.dart';
import 'package:flutter/foundation.dart';
import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';

import '../analysis/audio_config.dart';
import '../analysis/wav_reader.dart';
import '../analysis/wav_writer.dart';
import '../practice/beat_align.dart';
import '../practice/time_stretch.dart';
import 'audio_crypto.dart';
import 'tts_guide.dart';

/// Plays the phrase guide during State_2: the **recorded** caregiver clip when one
/// exists (therapy addendum §1), otherwise the **TTS fallback**.
///
/// The recorded clip is AES-encrypted at rest. We decrypt it to a short-lived
/// temp WAV in the cache and play it from there (`DeviceFileSource`) — reliable
/// on Android. [onComplete] fires exactly once per play, driven by whichever
/// comes first: the player's completion event OR a timer sized to the clip's
/// known duration (so the flow advances even if the completion event misfires).
class GuidePlayer {
  GuidePlayer({AudioCrypto? crypto, PhraseGuide? fallback, AudioPlayer? player})
      : _crypto = crypto ?? AudioCrypto(),
        _fallback = fallback ?? TtsGuide(),
        _player = player ?? AudioPlayer();

  final AudioCrypto _crypto;
  final PhraseGuide _fallback;
  final AudioPlayer _player;
  StreamSubscription<void>? _completeSub;
  Timer? _advanceTimer;
  Timer? _fadeTimer;
  String? _tempPath;
  bool _fired = false;

  Future<void> play({
    String? clipPath,
    required String text,
    void Function()? onComplete,
    double stretch = 1.0,
    double? ttsStretch,
    List<int>? beatNucleiMs,
    int? beatPeriodMs,
    bool cutLastSyllable = false,
  }) async {
    await _cancelPending();
    _fired = false;
    void fireOnce() {
      if (_fired) return;
      _fired = true;
      onComplete?.call();
    }

    if (clipPath != null) {
      try {
        final bytes = await _crypto.decryptFile(clipPath);
        var samples = WavReader.decode(bytes);

        // Elongate the playback copy (pitch-preserving) so the user can keep
        // pace — the stored encrypted clip / DTW reference is never touched.
        // Prefer the full piecewise beat warp (one syllable per beat) when the
        // caller supplied the nuclei + beat period; otherwise a uniform stretch.
        Uint8List playBytes = bytes;
        List<int>? warpNucleiMs;
        if (beatNucleiMs != null &&
            beatPeriodMs != null &&
            beatNucleiMs.length >= 2) {
          final warp = warpGuideToBeats(
              samples, beatNucleiMs, AudioFormat.sampleRate, beatPeriodMs);
          if (warp != null) {
            samples = warp.samples;
            warpNucleiMs = warp.nucleiOutMs;
            playBytes = WavWriter.encode(samples);
          }
        }
        if (warpNucleiMs == null && (stretch - 1.0).abs() >= 0.02) {
          samples = timeStretch(samples, stretch);
          playBytes = WavWriter.encode(samples);
        }
        final dur = Duration(
            milliseconds: (samples.length * 1000 / AudioFormat.sampleRate).round());

        // R3 ("model fades"): where to drop the guide so the user finishes the
        // final syllable alone — at the midpoint of the last two nuclei, on
        // whichever timeline we actually produced (warped grid, else uniform).
        int? cutoffMs;
        if (cutLastSyllable) {
          if (warpNucleiMs != null && warpNucleiMs.length >= 2) {
            cutoffMs = ((warpNucleiMs[warpNucleiMs.length - 2] +
                        warpNucleiMs[warpNucleiMs.length - 1]) /
                    2)
                .round();
          } else if (beatNucleiMs != null) {
            cutoffMs = guideFadeCutoffMs(beatNucleiMs, stretch);
          }
        }

        final dir = await getTemporaryDirectory();
        final tmp = File(p.join(dir.path, 'guide_play.wav'));
        await tmp.writeAsBytes(playBytes, flush: true);
        _tempPath = tmp.path;

        await _player.stop();
        await _player.setVolume(1.0); // reset (a previous cut may have lowered it)
        if (onComplete != null) {
          _completeSub = _player.onPlayerComplete.listen((_) => fireOnce());
          // Safety: advance even if the completion event never arrives. Sized to
          // the FULL clip even when we cut early (R3), so the user gets the time
          // of the final syllable to produce it before the verdict.
          _advanceTimer =
              Timer(dur + const Duration(milliseconds: 700), fireOnce);
        }
        await _player.play(DeviceFileSource(tmp.path));
        // R3 syllable cut-off: drop the guide before the last syllable so the
        // user finishes the word alone (only when there's a real cut point well
        // inside the clip).
        if (cutoffMs != null &&
            cutoffMs > 0 &&
            cutoffMs < dur.inMilliseconds - 150) {
          _scheduleCutoff(cutoffMs);
        }
        return;
      } catch (e) {
        // A corrupt/missing clip must never break practice — fall back to TTS.
        debugPrint('GuidePlayer: recorded clip failed, using TTS: $e');
      }
    }
    // No recorded clip: this is a "built-in" word spoken by the device TTS.
    // These are deliberately slowed well below the recorded path — the synthetic
    // voice runs fast otherwise — in proportion to [ttsStretch] (which the caller
    // keeps larger than [stretch] so the inbuilt voice stays slower than the
    // user's own recording).
    final ttsRate = (0.30 / (ttsStretch ?? stretch)).clamp(0.1, 0.35);
    // TtsGuide.speak resolves when the utterance finishes (awaitSpeakCompletion).
    await _fallback.speak(text, rate: ttsRate);
    fireOnce();
  }

  /// Stop whichever guide is playing (suppresses its pending completion).
  Future<void> stop() async {
    await _cancelPending();
    try {
      await _player.stop();
    } catch (_) {}
    await _fallback.stop();
  }

  // R3: at [cutoffMs] into playback, quickly duck the guide to silence so the
  // FINAL syllable is left for the user. A short ~150 ms ramp (not a hard stop)
  // keeps it click-free; the player is then stopped. The completion listener is
  // detached first so the early stop does NOT advance the flow — the full-length
  // [_advanceTimer] still fires, giving the user time to finish the word.
  void _scheduleCutoff(int cutoffMs) {
    _fadeTimer?.cancel();
    _fadeTimer = Timer(Duration(milliseconds: cutoffMs), () {
      const steps = 6;
      const stepMs = 25;
      var i = 0;
      _fadeTimer = Timer.periodic(const Duration(milliseconds: stepMs), (t) {
        i++;
        _player.setVolume((1.0 - i / steps).clamp(0.0, 1.0));
        if (i >= steps) {
          t.cancel();
          // Don't let the player's completion event fire onComplete early.
          _completeSub?.cancel();
          _completeSub = null;
          _player.stop().catchError((_) {});
        }
      });
    });
  }

  Future<void> _cancelPending() async {
    await _completeSub?.cancel();
    _completeSub = null;
    _advanceTimer?.cancel();
    _advanceTimer = null;
    _fadeTimer?.cancel();
    _fadeTimer = null;
  }

  Future<void> dispose() async {
    await _cancelPending();
    try {
      await _player.dispose();
    } catch (_) {}
    await _fallback.dispose();
    if (_tempPath != null) {
      try {
        final f = File(_tempPath!);
        if (await f.exists()) await f.delete();
      } catch (_) {}
    }
  }
}
