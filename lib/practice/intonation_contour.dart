import 'dart:math' as math;
import 'dart:typed_data';

import '../analysis/audio_config.dart';
import '../analysis/pitch_detection.dart';

/// The high–low melody detected from a caregiver's sung/intoned recording
/// (therapy intonation flow, items 4–5). One entry per confirmed syllable
/// nucleus, plus which syllable carries the "high" (stressed) note and how much
/// the pitch actually moves across the phrase.
///
/// The patient copies this melody, so the guide must contain a clear, correct
/// high–low contour. We DETECT it here (machine) and the caregiver APPROVES it
/// (human) — neither fully automated nor fully dependent on the caregiver's
/// musical skill.
class IntonationContour {
  /// Per-syllable pitch in Hz (0.0 where that syllable came out unvoiced).
  final List<double> f0Hz;

  /// Per-syllable loudness in dB (relative; higher = louder).
  final List<double> energyDb;

  /// Per-syllable duration in ms (span to the neighbouring nucleus).
  final List<int> durationMs;

  /// Index of the syllable with the highest detected pitch — the produced
  /// "stressed"/high syllable. -1 when nothing was voiced.
  final int stressedIndex;

  /// Total pitch movement across the voiced syllables, in semitones (max→min).
  /// 0.0 when fewer than two syllables are voiced (nothing to move between).
  final double pitchRangeSemitones;

  const IntonationContour({
    required this.f0Hz,
    required this.energyDb,
    required this.durationMs,
    required this.stressedIndex,
    required this.pitchRangeSemitones,
  });

  int get syllableCount => f0Hz.length;

  /// A compact high/low step per syllable relative to the MEAN voiced pitch, for
  /// the visual cue on screen (true = high/up, false = low/down). Unvoiced
  /// syllables fall back to low. Mean (not median) so a two-syllable high–low
  /// splits cleanly — a median of two values is the higher one, leaving nothing
  /// "above" it.
  List<bool> get highLowSteps {
    final voiced = f0Hz.where((f) => f > 0).toList();
    if (voiced.isEmpty) return List<bool>.filled(f0Hz.length, false);
    final mean = voiced.reduce((a, b) => a + b) / voiced.length;
    return [for (final f in f0Hz) f > mean];
  }
}

/// Analyze a caregiver recording into an [IntonationContour], using the already-
/// confirmed syllable [nucleiMs] (from the syllable-nucleus flow — we do NOT add
/// a forced aligner) as the per-syllable segmentation. For each nucleus we read
/// the pitch (autocorrelation F0) and loudness in a short window centred on it,
/// each judged RELATIVE to its neighbours: the highest-pitched syllable is the
/// stressed one.
IntonationContour analyzeContour(
  Float64List samples,
  List<int> nucleiMs, {
  int sampleRate = AudioFormat.sampleRate,
  int windowMs = 60,
}) {
  final windowSamples = (windowMs * sampleRate / 1000).round();
  final half = windowSamples ~/ 2;

  final f0 = <double>[];
  final energy = <double>[];
  for (final ms in nucleiMs) {
    final centre = (ms * sampleRate / 1000).round();
    final start = math.max(0, centre - half);
    final n = math.min(windowSamples, samples.length - start);
    if (n <= 0) {
      f0.add(0.0);
      energy.add(-160.0);
      continue;
    }
    f0.add(estimatePitch(samples, start, n, sampleRate: sampleRate).f0Hz);
    var sumSq = 0.0;
    for (var i = 0; i < n; i++) {
      final v = samples[start + i];
      sumSq += v * v;
    }
    final rms = math.sqrt(sumSq / n);
    energy.add(20.0 * (math.log(rms + 1e-10) / math.ln10));
  }

  // Per-syllable duration: the span to the next nucleus (the last mirrors the
  // previous gap), so a drawn-out syllable reads as longer.
  final durations = <int>[];
  for (var i = 0; i < nucleiMs.length; i++) {
    if (nucleiMs.length == 1) {
      durations.add(0);
    } else if (i < nucleiMs.length - 1) {
      durations.add(nucleiMs[i + 1] - nucleiMs[i]);
    } else {
      durations.add(nucleiMs[i] - nucleiMs[i - 1]);
    }
  }

  // Stressed = the voiced syllable that is the strongest LOCAL PEAK across the
  // three cues, each normalised across the phrase and judged relative to its
  // neighbours: pitch (the MIT "high note", weighted most), then loudness, then
  // duration. Unvoiced syllables can't carry the high note, so they're skipped.
  final normF0 = _minMaxNorm(f0);
  final normEnergy = _minMaxNorm(energy);
  final normDur = _minMaxNorm([for (final d in durations) d.toDouble()]);
  var stressed = -1;
  var bestScore = -1.0;
  for (var i = 0; i < f0.length; i++) {
    if (f0[i] <= 0) continue; // unvoiced
    final score =
        0.60 * normF0[i] + 0.25 * normEnergy[i] + 0.15 * normDur[i];
    if (score > bestScore) {
      bestScore = score;
      stressed = i;
    }
  }

  // Movement across the voiced syllables, in semitones (12·log2(max/min)).
  final voiced = f0.where((f) => f > 0).toList();
  double range = 0.0;
  if (voiced.length >= 2) {
    final hi = voiced.reduce(math.max);
    final lo = voiced.reduce(math.min);
    if (lo > 0) range = 12.0 * (math.log(hi / lo) / math.ln2);
  }

  return IntonationContour(
    f0Hz: f0,
    energyDb: energy,
    durationMs: durations,
    stressedIndex: stressed,
    pitchRangeSemitones: range,
  );
}

/// Min–max normalise a list to 0..1 (all-equal → all 0.5, so no cue dominates by
/// accident). Used to put pitch/energy/duration on a common scale before the
/// weighted stress score.
List<double> _minMaxNorm(List<double> xs) {
  final finite = xs.where((x) => x.isFinite).toList();
  if (finite.isEmpty) return List<double>.filled(xs.length, 0.0);
  final lo = finite.reduce(math.min);
  final hi = finite.reduce(math.max);
  if (hi <= lo) return List<double>.filled(xs.length, 0.5);
  return [for (final x in xs) ((x - lo) / (hi - lo)).clamp(0.0, 1.0)];
}

/// How a detected contour measures up against the intended one (item 5,
/// "good enough" acceptance). We deliberately do NOT require a precise minor
/// third — any CLEAR movement in the right place passes. Only two things fail:
/// a flat contour (little movement) or a mis-stressed one (the high note landed
/// on the wrong syllable).
enum ContourVerdict {
  /// Clear movement, high note on the expected syllable — accept.
  good,

  /// Came out too even (movement below the threshold) — coach to lift more.
  flat,

  /// Movement is there, but the high note landed on the wrong syllable.
  misStressed,

  /// Nothing voiced to judge (silence / no pitch) — re-record.
  tooQuiet,
}

/// The outcome of checking a contour, with the syllable indices the targeted
/// feedback needs.
class ContourCheck {
  final ContourVerdict verdict;

  /// The syllable the feedback should point at: for [flat] the one to lift, for
  /// [misStressed] the one that was wrongly stressed. Null for [good]/[tooQuiet].
  final int? offendingSyllable;

  /// Where the high note SHOULD be ([misStressed] only).
  final int? expectedSyllable;

  const ContourCheck(this.verdict, {this.offendingSyllable, this.expectedSyllable});

  bool get isGood => verdict == ContourVerdict.good;
}

/// Apply the "good enough" rule to [contour], given where the high note is
/// expected ([expectedStressIndex]). [minRangeSemitones] is the movement floor —
/// default 1.5 (well under a minor third's 3 semitones) so any clear rise passes.
///
/// A single-syllable phrase has no relative contour to get wrong, so it passes
/// as long as it was voiced.
ContourCheck checkContour(
  IntonationContour contour, {
  required int expectedStressIndex,
  double minRangeSemitones = 1.5,
}) {
  if (contour.stressedIndex < 0) {
    return const ContourCheck(ContourVerdict.tooQuiet);
  }
  if (contour.syllableCount <= 1) {
    return const ContourCheck(ContourVerdict.good); // nothing to mis-stress
  }
  if (contour.pitchRangeSemitones < minRangeSemitones) {
    return ContourCheck(ContourVerdict.flat,
        offendingSyllable: expectedStressIndex);
  }
  if (contour.stressedIndex != expectedStressIndex) {
    return ContourCheck(ContourVerdict.misStressed,
        offendingSyllable: contour.stressedIndex,
        expectedSyllable: expectedStressIndex);
  }
  return const ContourCheck(ContourVerdict.good);
}
