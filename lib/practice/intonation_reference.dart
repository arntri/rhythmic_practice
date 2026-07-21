import 'dart:math' as math;
import 'dart:typed_data';

import '../analysis/audio_config.dart';

/// Synthesizes a simple two-note reference melody for the CAREGIVER to imitate
/// (therapy intonation flow, item 1 — "like this…"). This is a demo the caregiver
/// copies; it is **never** the patient's guide (that is always the caregiver's
/// own recording), so synthetic quality doesn't matter — only that the high–low
/// contour is unambiguous.
///
/// The stressed syllable gets the HIGH note; the rest get the LOW note, a **minor
/// third** apart (the classic MIT interval). Each syllable is a short tone with a
/// tiny fade in/out to avoid clicks, separated by a little silence.
///
/// Pure + deterministic → unit-testable (no audio device needed to check the
/// pitch content).
Float64List synthesizeReferenceMelody({
  required int syllableCount,
  required int stressIndex,
  int sampleRate = AudioFormat.sampleRate,
  int syllableMs = 450,
  int gapMs = 90,
  double lowHz = 196.0, // ~G3, a comfortable low note
  double amplitude = 0.35,
}) {
  final count = math.max(1, syllableCount);
  final stress = stressIndex.clamp(0, count - 1);
  // A minor third up = 3 semitones = ×2^(3/12).
  final highHz = lowHz * math.pow(2, 3 / 12).toDouble();

  final toneSamples = (syllableMs * sampleRate / 1000).round();
  final gapSamples = (gapMs * sampleRate / 1000).round();
  final fade = math.min(toneSamples ~/ 10, (0.01 * sampleRate).round()); // ~10 ms

  final out = <double>[];
  for (var s = 0; s < count; s++) {
    final hz = s == stress ? highHz : lowHz;
    for (var i = 0; i < toneSamples; i++) {
      var env = 1.0;
      if (i < fade) {
        env = i / fade;
      } else if (i > toneSamples - fade) {
        env = (toneSamples - i) / fade;
      }
      out.add(amplitude * env * math.sin(2 * math.pi * hz * i / sampleRate));
    }
    if (s != count - 1) {
      for (var i = 0; i < gapSamples; i++) {
        out.add(0.0);
      }
    }
  }
  return Float64List.fromList(out);
}

/// A generic, phrase-independent two-tone pattern ("naa-naa" / "uh-oh") — a
/// falling high→low the caregiver can use as a reference for the *shape* of an
/// intoned contour, when a phrase-shaped template isn't wanted.
Float64List genericTwoTone({int sampleRate = AudioFormat.sampleRate}) =>
    synthesizeReferenceMelody(
      syllableCount: 2,
      stressIndex: 0, // high then low = a falling "uh-oh"
      sampleRate: sampleRate,
    );
