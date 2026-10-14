import 'dart:math' as math;
import 'dart:typed_data';

import '../analysis/audio_config.dart';
import 'intonation_reference.dart';

/// The two-pitch hum played at the START of every phrase — canonical MIT's
/// first step.
///
/// In the clinic the therapist hums the target phrase's melody **twice**, while
/// tapping the patient's left hand, *before* any words are sung. The melody
/// arrives before the language does: the person hears the tune and feels the
/// rhythm with nothing to retrieve. Only then does the word appear.
///
/// The app hummed once per SESSION (a general vocal warm-up with no phrase
/// attached), which is a different thing entirely. This builds the per-phrase
/// hum: the phrase's own melody, on the phrase's own syllable count, hummed
/// [passes] times.
///
/// It is deliberately synthetic. The hum carries no words, so nothing about it
/// is language-specific and nothing needs recording — two pitches a minor third
/// apart, one syllable per beat, is the entire content.
class HumMelody {
  const HumMelody({
    required this.samples,
    required this.passMs,
    required this.restMs,
    required this.passes,
  });

  /// The full hum — every pass, with the rests between them — as normalized
  /// mono samples ready for [WavWriter].
  final Float64List samples;

  /// Duration of ONE pass through the melody, in ms.
  final int passMs;

  /// Silence between passes, in ms.
  final int restMs;

  /// How many times the melody is hummed.
  final int passes;

  /// Total duration in ms — what the caller sizes its advance timer to.
  int get totalMs => passes * passMs + (passes - 1) * restMs;

  /// When pass [i] (0-based) begins, in ms. Lets the screen re-cue the on-screen
  /// contour for the second hum.
  int startOfPassMs(int i) => i * (passMs + restMs);
}

/// The fraction of one beat a hummed syllable actually sounds for. MIT phrases
/// are sung **legato** — continuously voiced, no gap chopped between syllables —
/// so the rest of the beat is a seam, not a silence.
const double _legatoFraction = 0.88;

/// Build the hum for a phrase of [syllableCount] syllables whose stressed
/// syllable is [stressIndex], paced at [beatPeriodMs] per syllable so it rides
/// the metronome at exactly one syllable per beat.
///
/// [restBeats] of silence separate the passes, so the second hum reads as
/// "again" rather than as one long run-on melody.
///
/// Pure and deterministic — no audio device, so the timing and pitch content are
/// unit-testable.
HumMelody buildHumMelody({
  required int syllableCount,
  required int stressIndex,
  required int beatPeriodMs,
  int passes = 2,
  int restBeats = 1,
  int sampleRate = AudioFormat.sampleRate,
}) {
  final count = math.max(1, syllableCount);
  final passCount = math.max(1, passes);
  final beatMs = math.max(1, beatPeriodMs);

  final syllableMs = math.max(1, (beatMs * _legatoFraction).round());
  final gapMs = beatMs - syllableMs;

  final one = synthesizeReferenceMelody(
    syllableCount: count,
    stressIndex: stressIndex,
    sampleRate: sampleRate,
    syllableMs: syllableMs,
    gapMs: gapMs,
  );

  // synthesizeReferenceMelody puts a gap AFTER every syllable but the last, so
  // one pass spans count beats minus that trailing gap.
  final passMs = count * beatMs - gapMs;
  final restMs = math.max(0, restBeats) * beatMs;
  final restSamples = (restMs * sampleRate / 1000).round();

  final out = Float64List(
    passCount * one.length + (passCount - 1) * restSamples,
  );
  var o = 0;
  for (var p = 0; p < passCount; p++) {
    out.setRange(o, o + one.length, one);
    o += one.length;
    if (p != passCount - 1) o += restSamples; // rest stays zeroed
  }

  return HumMelody(
    samples: out,
    passMs: passMs,
    restMs: restMs,
    passes: passCount,
  );
}
