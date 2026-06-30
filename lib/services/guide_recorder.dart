import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:record/record.dart';

import '../analysis/wav_reader.dart';
import '../analysis/wav_writer.dart';
import '../practice/audio_trim.dart';
import '../practice/noise_reduction.dart';
import '../practice/syllable_detection.dart';
import 'audio_crypto.dart';

/// The product of one guide recording: the AES-encrypted clip path (which also
/// becomes the phrase's DTW reference) and the syllable-nucleus [detection] that
/// pre-fills the count for the caregiver to confirm (therapy addendum §2).
class GuideRecording {
  final String encryptedPath;
  final SyllableDetection detection;
  const GuideRecording({required this.encryptedPath, required this.detection});
}

/// Records a phrase's guide as the caregiver says it ONCE, slowly and stretched,
/// in a natural voice — **no metronome plays** (therapy addendum §2 revision).
/// On stop it runs syllable-nucleus detection on the raw recording, then saves
/// the clip AES-encrypted (WAV/PCM16/mono/16 kHz — the analyzer's format).
///
/// Device-only (needs a real mic), so this glue isn't unit-tested; the detection
/// ([detectSyllableNuclei]) and encryption ([AudioCrypto]) are tested separately.
class GuideRecorder {
  GuideRecorder({AudioRecorder? recorder, AudioCrypto? crypto})
      : _recorder = recorder ?? AudioRecorder(),
        _crypto = crypto ?? AudioCrypto();

  final AudioRecorder _recorder;
  final AudioCrypto _crypto;

  /// TEMP (dev only): keep an UNENCRYPTED copy of each recording next to the
  /// encrypted clip, so detection/playback can be diagnosed against real audio.
  /// MUST be false in production — it defeats the at-rest AES guarantee.
  static bool keepRawForDebug = false;

  bool _recording = false;
  bool get isRecording => _recording;

  /// Begin recording to [rawPath]. Returns false if mic permission was denied.
  Future<bool> start({required String rawPath}) async {
    if (_recording) return true;
    if (!await _recorder.hasPermission()) return false;
    _recording = true;
    await _recorder.start(
      const RecordConfig(
        encoder: AudioEncoder.wav,
        sampleRate: 16000,
        numChannels: 1,
      ),
      path: rawPath,
    );
    return true;
  }

  /// Stop, detect syllable nuclei on the raw recording, then encrypt the clip to
  /// [encryptedPath]. Returns null if nothing was recorded.
  Future<GuideRecording?> stop({required String encryptedPath}) async {
    if (!_recording) return null;
    _recording = false;

    String? recordedPath;
    try {
      recordedPath = await _recorder.stop();
    } catch (e) {
      debugPrint('GuideRecorder: stop failed: $e');
    }
    if (recordedPath == null) return null;

    // Trim leading/trailing silence so the stored guide starts at the word and
    // is just the word, then detect nuclei on the trimmed clip (so the timings
    // are relative to what's actually saved).
    var detection = const SyllableDetection(0, []);
    Uint8List? trimmedWav;
    try {
      final samples = await WavReader.readFile(recordedPath);
      // Remove stationary background noise (estimated from the quiet lead-in),
      // then trim silence so the clip starts at the word.
      final denoised = reduceNoise(samples);
      final trimmed = trimToSpeech(denoised);
      detection = detectSyllableNuclei(trimmed);
      trimmedWav = WavWriter.encode(trimmed);
    } catch (e) {
      debugPrint('GuideRecorder: denoise/trim/detect failed: $e');
    }

    if (keepRawForDebug) {
      try {
        await File(recordedPath).copy('$encryptedPath.debug.wav'); // raw
      } catch (_) {}
      if (trimmedWav != null) {
        try {
          // The exact bytes that get encrypted + played back.
          await File('$encryptedPath.trimmed.wav').writeAsBytes(trimmedWav, flush: true);
        } catch (_) {}
      }
    }

    String enc;
    if (trimmedWav != null) {
      enc = await _crypto.encryptBytes(trimmedWav, encryptedPath);
      try {
        final f = File(recordedPath);
        if (await f.exists()) await f.delete(); // remove the untrimmed plaintext
      } catch (_) {}
    } else {
      // Trim/encode failed — fall back to storing the original clip.
      enc = await _crypto.encryptFile(File(recordedPath), encryptedPath);
    }
    return GuideRecording(encryptedPath: enc, detection: detection);
  }

  Future<void> dispose() async => _recorder.dispose();
}
