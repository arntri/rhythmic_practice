import 'dart:math' as math;
import 'dart:typed_data';

/// Pitch-preserving time-stretch (WSOLA — Waveform Similarity Overlap-Add).
///
/// Used to **elongate the guide playback** at the say-it-together rungs so the
/// user can actually keep pace (therapy: the model must be slow enough to
/// produce *with*). Crucially this preserves pitch — it copies contiguous
/// windows from the original and overlap-adds them at a wider spacing, so the
/// **intonation melody is kept intact** (central to MIT). A naive playback-rate
/// slowdown would drop the pitch and flatten that melody.
///
/// [factor] > 1 makes the audio longer/slower (1.6 ≈ 60% longer). It is applied
/// only to the in-memory *playback* copy — the stored DTW reference clip is
/// never altered.
///
/// The waveform-similarity search (WSOLA) nudges each analysis frame to the
/// position that best continues the previously emitted frame, avoiding the
/// phase-discontinuity "buzz" plain overlap-add would produce on voiced speech.
///
/// Two details keep the voiced "buzz" down at the large factors the recorded
/// guide uses (up to ~2.8×): the seek window spans at least one full pitch
/// period of a low (~75 Hz) male voice, and the similarity score is a
/// **normalised** cross-correlation — it picks the offset whose waveform best
/// *matches the shape* of the natural continuation, not merely the loudest
/// region, which is what a raw dot product would drift toward.
Float64List timeStretch(
  Float64List input,
  double factor, {
  int windowSize = 512,
  int seekWindow = 200,
}) {
  // Nothing to do for ~unity factors or clips too short to window twice.
  if (input.length < windowSize * 2 || (factor - 1.0).abs() < 0.02) {
    return Float64List.fromList(input);
  }

  final w = windowSize;
  final hs = w ~/ 2; // synthesis hop (50% overlap → Hann sums to ~1)
  final ha = (hs / factor).round().clamp(1, w); // analysis hop
  final seek = seekWindow;

  // Hann window.
  final win = Float64List(w);
  for (var i = 0; i < w; i++) {
    win[i] = 0.5 - 0.5 * math.cos(2 * math.pi * i / (w - 1));
  }

  final outLen = (input.length * factor).ceil() + w;
  final out = Float64List(outLen);
  final norm = Float64List(outLen); // accumulated window weight, for OLA normalize

  var analysis = 0; // nominal read position in the input
  var synth = 0; // write position in the output
  var delta = 0; // WSOLA offset chosen by the similarity search

  while (synth + w < outLen && analysis + w < input.length) {
    final readPos = analysis + delta;

    // Overlap-add this windowed frame into the output.
    for (var i = 0; i < w; i++) {
      final s = readPos + i;
      final v = (s >= 0 && s < input.length) ? input[s] : 0.0;
      out[synth + i] += v * win[i];
      norm[synth + i] += win[i];
    }

    // The samples that *naturally* continue the frame we just wrote — the next
    // frame's leading overlap should look like this region.
    final refStart = readPos + hs;
    synth += hs;

    // Search a small window around the next nominal analysis position for the
    // offset whose frame best matches that natural continuation.
    final nominal = analysis + ha;
    var bestD = 0;
    var bestCorr = -double.infinity;
    for (var d = -seek; d <= seek; d++) {
      final cand = nominal + d;
      if (cand < 0 || cand + w >= input.length) continue;
      // Subsampled (every 2nd sample) normalised cross-correlation: dividing by
      // the candidate's energy stops the search from simply favouring louder
      // offsets, so it locks onto the best phase match and the stretched voice
      // stays clean instead of buzzy.
      var dot = 0.0;
      var energy = 0.0;
      for (var i = 0; i < w; i += 2) {
        final r = refStart + i;
        final a = (r >= 0 && r < input.length) ? input[r] : 0.0;
        final c = input[cand + i];
        dot += a * c;
        energy += c * c;
      }
      final corr = energy > 1e-9 ? dot / math.sqrt(energy) : dot;
      if (corr > bestCorr) {
        bestCorr = corr;
        bestD = d;
      }
    }
    analysis = nominal;
    delta = bestD;
  }

  // Normalize by the overlapped window weight so amplitude is preserved.
  for (var i = 0; i < outLen; i++) {
    if (norm[i] > 1e-6) out[i] /= norm[i];
  }

  // Trim to the expected stretched length (drop the window-sized tail padding).
  final expected = (input.length * factor).round();
  final end = math.min(expected, outLen);
  return out.sublist(0, end);
}
