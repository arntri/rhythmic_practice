import 'dart:async';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:record/record.dart';

import '../practice/capture_analysis.dart';
import 'audio_crypto.dart';

/// What one capture produced. [encryptedPath] is null when nothing was kept
/// (no speech, denied permission, or an error) — the row is still saved, just
/// without audio.
class CaptureResult {
  final String? encryptedPath;
  final int? latencyMs;
  final int? durationMs;
  const CaptureResult({this.encryptedPath, this.latencyMs, this.durationMs});
}

/// Step 5: records the user's attempt during State_3 (Input_Capture), closing
/// automatically after ~4.5 s of silence, then encrypts the clip at rest.
///
/// Device-only (needs a real microphone), so this glue is not unit-tested. The
/// logic it leans on is: when to close + latency/duration ([CaptureTracker],
/// tested) and encryption ([AudioCrypto]/[AesCipher], tested).
class MicCapture {
  MicCapture({AudioRecorder? recorder, AudioCrypto? crypto})
      : _recorder = recorder ?? AudioRecorder(),
        _crypto = crypto ?? AudioCrypto();

  final AudioRecorder _recorder;
  final AudioCrypto _crypto;

  /// Caregiver-adjustable recording window: silence (after speech) before capture
  /// auto-closes. Set from the profile before a session.
  Duration silenceWindow = const Duration(milliseconds: 4500);

  /// Speech threshold (dBFS) above which a reading counts as the user speaking.
  /// Defaults to the historical fixed value; [calibrateAmbient] replaces it with
  /// a room-derived one at session start (therapy addendum §5).
  double speechThresholdDb = AmbientCalibration.defaultThresholdDb;

  StreamSubscription<Amplitude>? _ampSub;
  Stopwatch? _clock;
  CaptureTracker? _tracker;
  String? _encryptedPath;
  void Function(CaptureResult)? _onClosed;
  bool _closing = false;
  RecordConfig? _config;

  /// Begin recording to [rawPath]; on close (silence or [stop]) the clip is
  /// encrypted to [encryptedPath] and [onClosed] is fired exactly once.
  /// Returns false if mic permission was denied — caller carries on audio-free.
  Future<bool> start({
    required String rawPath,
    required String encryptedPath,
    required void Function(CaptureResult) onClosed,
  }) async {
    if (!await _recorder.hasPermission()) return false;

    _tracker = CaptureTracker(
        silenceDuration: silenceWindow, speechThresholdDb: speechThresholdDb);
    _encryptedPath = encryptedPath;
    _onClosed = onClosed;
    _closing = false;
    _clock = Stopwatch()..start();

    // WAV / PCM16 / mono / 16 kHz — the analyzer's format (therapy addendum §1).
    // Recorded clips double as DTW references, so this must match everywhere.
    const config = RecordConfig(
      encoder: AudioEncoder.wav,
      sampleRate: 16000,
      numChannels: 1,
    );
    _config = config;
    await _recorder.start(config, path: rawPath);

    _ampSub = _recorder
        .onAmplitudeChanged(const Duration(milliseconds: 200))
        .listen((amp) {
      final tracker = _tracker;
      final clock = _clock;
      if (tracker == null || clock == null) return;
      // amp.current is dBFS (negative; higher = louder).
      if (tracker.add(clock.elapsed, amp.current)) _finish();
    });
    return true;
  }

  /// Listen to the room for [window] (no audio kept) and set [speechThresholdDb]
  /// from the ambient noise floor (therapy addendum §5). Call once at session
  /// start, before any capture. Records to [rawPath] then deletes it. Returns the
  /// chosen threshold, or null if it couldn't calibrate (permission/error) — in
  /// which case the existing [speechThresholdDb] is kept.
  Future<double?> calibrateAmbient({
    required String rawPath,
    Duration window = const Duration(seconds: 2),
  }) async {
    // Use a DEDICATED recorder and dispose it as soon as we're done, so the mic
    // / audio session is fully released before the guide tries to play — sharing
    // the capture recorder (or leaving it merely stopped) left the Android audio
    // session in a recording state that silenced the guide playback.
    final recorder = AudioRecorder();
    final readings = <double>[];
    StreamSubscription<Amplitude>? sub;
    try {
      if (!await recorder.hasPermission()) return null;
      await recorder.start(
        const RecordConfig(
          encoder: AudioEncoder.wav,
          sampleRate: 16000,
          numChannels: 1,
        ),
        path: rawPath,
      );
      sub = recorder
          .onAmplitudeChanged(const Duration(milliseconds: 200))
          .listen((amp) => readings.add(amp.current));
      await Future<void>.delayed(window);
    } catch (e) {
      debugPrint('MicCapture: calibration failed: $e');
    } finally {
      await sub?.cancel();
      try {
        await recorder.stop();
      } catch (_) {}
      try {
        await recorder.dispose(); // release the audio session
      } catch (_) {}
      try {
        final f = File(rawPath);
        if (await f.exists()) await f.delete();
      } catch (_) {}
    }
    if (readings.isEmpty) return null;
    speechThresholdDb = AmbientCalibration.thresholdFrom(readings);
    debugPrint('MicCapture: calibrated speech threshold = '
        '${speechThresholdDb.toStringAsFixed(1)} dBFS '
        'from ${readings.length} ambient readings');
    return speechThresholdDb;
  }

  /// Force-close (e.g. the user left the screen mid-capture). Safe any time.
  Future<void> stop() => _finish();

  Future<void> _finish() async {
    if (_closing) return; // guard: silence-close and stop() can race
    _closing = true;
    await _ampSub?.cancel();
    _ampSub = null;
    _clock?.stop();

    String? recordedPath;
    try {
      recordedPath = await _recorder.stop();
    } catch (e) {
      debugPrint('MicCapture: stop failed: $e');
    }

    // Verify the on-disk format before encryption: confirm it's PCM16 / 16 kHz
    // / mono WAV (the analyzer's format), not m4a. Logs path, size, the actual
    // RecordConfig used, and the 44-byte WAV header as hex.
    if (recordedPath != null) {
      await _logRecording(recordedPath);
    }

    final tracker = _tracker;
    String? finalPath;
    // Only keep audio if the user actually spoke (brief: don't store silence).
    if (recordedPath != null &&
        _encryptedPath != null &&
        tracker != null &&
        tracker.heardSpeech) {
      try {
        finalPath = await _crypto.encryptFile(File(recordedPath), _encryptedPath!);
      } catch (e) {
        debugPrint('MicCapture: encrypt failed: $e');
      }
    } else if (recordedPath != null) {
      // Nothing worth keeping — remove the raw temp file.
      try {
        final f = File(recordedPath);
        if (await f.exists()) await f.delete();
      } catch (_) {}
    }

    _onClosed?.call(CaptureResult(
      encryptedPath: finalPath,
      latencyMs: tracker?.latencyMs(),
      durationMs: tracker?.durationMs(),
    ));
  }

  /// Log the freshly-recorded (pre-encryption) clip so the on-disk format can be
  /// confirmed: path, byte size, the [RecordConfig] used, and the first 44 bytes
  /// (the canonical WAV header) as hex. A real WAV starts "RIFF....WAVE" with an
  /// "fmt " chunk encoding audioFormat=1 (PCM), numChannels=1, sampleRate=16000,
  /// bitsPerSample=16; an m4a would instead show "ftyp" near the start.
  Future<void> _logRecording(String path) async {
    try {
      final file = File(path);
      final size = await file.length();
      final config = _config;
      debugPrint('MicCapture: recorded file=$path size=${size}B '
          'encoder=${config?.encoder} sampleRate=${config?.sampleRate} '
          'numChannels=${config?.numChannels}');

      final raf = await file.open();
      List<int> header;
      try {
        header = await raf.read(44);
      } finally {
        await raf.close();
      }
      final hex = header
          .map((b) => b.toRadixString(16).padLeft(2, '0'))
          .join(' ');
      debugPrint('MicCapture: WAV header (${header.length} bytes): $hex');
    } catch (e) {
      debugPrint('MicCapture: header log failed: $e');
    }
  }

  Future<void> dispose() async {
    await _ampSub?.cancel();
    await _recorder.dispose();
  }
}
