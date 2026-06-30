import 'package:flutter/foundation.dart';
import 'package:flutter_tts/flutter_tts.dart';

/// The "audio guide" (brief §4): speaks the practice phrase aloud during
/// State_2 (Reference_Prompt) so the user has a spoken model to follow.
///
/// Phase 1 uses the device's text-to-speech as a temporary stand-in for bundled
/// intoned clips (brief §7, explicitly sanctioned). Abstracted behind
/// [PhraseGuide] so the practice flow can be driven with a fake in tests; the
/// real implementation talks to the platform TTS engine.
abstract class PhraseGuide {
  /// Speak [text] now, interrupting anything already speaking. [rate] overrides
  /// the default speech rate for this utterance (lower = slower) so the guide
  /// can be elongated at the say-it-together rungs.
  Future<void> speak(String text, {double? rate});

  /// Stop speaking immediately (called when the guide phase ends).
  Future<void> stop();

  /// Release the engine.
  Future<void> dispose();
}

/// Real guide backed by `flutter_tts`. Every call is wrapped so a missing or
/// failing TTS engine (e.g. on desktop or in tests) degrades to a silent no-op
/// rather than throwing into the practice loop.
class TtsGuide implements PhraseGuide {
  TtsGuide() {
    _configure();
  }

  final FlutterTts _tts = FlutterTts();

  Future<void> _configure() async {
    try {
      // Calm and slow, to match the gentle default tempo.
      await _tts.setSpeechRate(0.4);
      await _tts.setPitch(1.0);
      await _tts.setVolume(1.0);
      // Make speak() resolve only when the utterance finishes, so callers can
      // advance the practice flow when the guide is actually done.
      await _tts.awaitSpeakCompletion(true);
    } catch (e) {
      debugPrint('TtsGuide: configure failed (normal off-device): $e');
    }
  }

  @override
  Future<void> speak(String text, {double? rate}) async {
    if (text.isEmpty) return;
    try {
      await _tts.stop();
      if (rate != null) {
        await _tts.setSpeechRate(rate.clamp(0.1, 1.0));
      }
      await _tts.speak(text);
    } catch (e) {
      debugPrint('TtsGuide: speak failed: $e');
    }
  }

  @override
  Future<void> stop() async {
    try {
      await _tts.stop();
    } catch (_) {}
  }

  @override
  Future<void> dispose() async {
    try {
      await _tts.stop();
    } catch (_) {}
  }
}
