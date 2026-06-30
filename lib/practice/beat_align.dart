import 'dart:math' as math;
import 'dart:typed_data';

import 'time_stretch.dart';

/// Voice-to-beat alignment (therapy: align the **voice to the beat**, not the
/// beat to the voice).
///
/// Given the detected syllable-nucleus times [nucleiMs] of the recorded guide and
/// the target [beatPeriodMs] (one beat = one syllable), return the uniform
/// time-stretch factor that makes the **average** syllable spacing equal one
/// beat — so the voice and the metronome don't drift apart across the phrase.
/// The caller feeds this factor to the pitch-preserving [timeStretch].
///
/// Returns null when there are fewer than 2 nuclei (no spacing to measure), so
/// the caller falls back to the per-rung stretch.
///
/// This is the **interim** of the full piecewise warp (each nucleus landing
/// exactly on a beat): a single, click-free pass that locks the average pacing to
/// the beat. The full per-syllable warp is the target.
double? beatStretchFactor(
  List<int> nucleiMs,
  int beatPeriodMs, {
  double minFactor = 0.5,
  double maxFactor = 6.0,
}) {
  if (beatPeriodMs <= 0) return null;
  final n = [...nucleiMs]..sort();
  if (n.length < 2) return null;

  // Mean interval between consecutive nuclei in the (already slow) recording.
  var totalMs = 0;
  for (var i = 1; i < n.length; i++) {
    totalMs += n[i] - n[i - 1];
  }
  final meanIntervalMs = totalMs / (n.length - 1);
  if (meanIntervalMs <= 0) return null;

  final factor = beatPeriodMs / meanIntervalMs;
  return factor.clamp(minFactor, maxFactor);
}

/// The result of a piecewise beat warp: the elongated [samples] and where each
/// syllable nucleus ended up in that warped timeline ([nucleiOutMs], ms).
class BeatWarp {
  const BeatWarp(this.samples, this.nucleiOutMs);

  /// The warped (pitch-preserving) audio, one syllable per beat.
  final Float64List samples;

  /// Each nucleus's position in [samples], in ms — used to place the R3 cut on
  /// the warped timeline (it can't be derived from a single stretch factor any
  /// more, since every syllable gets its own factor).
  final List<int> nucleiOutMs;
}

/// **Full piecewise beat warp** (therapy §2-4b — one syllable per beat). Unlike
/// the uniform [beatStretchFactor] (which only locks the *average* spacing), this
/// stretches **each inter-nucleus interval independently** so EVERY nucleus lands
/// exactly one beat apart, then pads the lead-in with silence so the first
/// nucleus falls on a whole beat (a beat-synced start). Pitch is preserved
/// (WSOLA per segment); a short equal-power crossfade hides the segment seams —
/// which sit *at* the nuclei, where the phoneme is the same on both sides.
///
/// [input] are the original guide samples, [nucleiMs] the detected nuclei in the
/// original recording, [beatPeriodMs] = 60000/bpm. Returns null (caller falls
/// back to a uniform [timeStretch]) when there are fewer than 2 usable nuclei.
BeatWarp? warpGuideToBeats(
  Float64List input,
  List<int> nucleiMs,
  int sampleRate,
  int beatPeriodMs, {
  double minFactor = 0.5,
  double maxFactor = 6.0,
  double crossfadeMs = 8.0,
}) {
  if (sampleRate <= 0 || beatPeriodMs <= 0 || input.isEmpty) return null;
  final durMs = (input.length * 1000 / sampleRate).round();

  // Sorted, in-range, strictly increasing nuclei (positive intervals only).
  final nuc = <int>[];
  for (final m in [...nucleiMs]..sort()) {
    if (m < 0 || m > durMs) continue;
    if (nuc.isEmpty || m > nuc.last) nuc.add(m);
  }
  if (nuc.length < 2) return null;

  int sampOf(int ms) =>
      (ms * sampleRate / 1000).round().clamp(0, input.length);

  // One stretch factor per inter-nucleus interval → each becomes one beat.
  final factors = <double>[
    for (var k = 1; k < nuc.length; k++)
      (beatPeriodMs / (nuc[k] - nuc[k - 1])).clamp(minFactor, maxFactor),
  ];
  // The lead-in / tail (no beat constraint) use the mean pace so they feel of a
  // piece with the body.
  final meanF = factors.reduce((a, b) => a + b) / factors.length;

  final fade = (crossfadeMs * sampleRate / 1000).round();
  final out = <double>[];

  int outMs() => (out.length * 1000 / sampleRate).round();

  // Append [seg], equal-power crossfading its head over the current tail unless
  // [crossfade] is off (silence→audio joins need no fade).
  void appendSeg(Float64List seg, {bool crossfade = true}) {
    if (seg.isEmpty) return;
    if (!crossfade || fade <= 0 || out.length < fade || seg.length < fade) {
      out.addAll(seg);
      return;
    }
    final start = out.length - fade;
    for (var i = 0; i < fade; i++) {
      final t = (i + 1) / (fade + 1);
      out[start + i] =
          out[start + i] * math.cos(t * math.pi / 2) + seg[i] * math.sin(t * math.pi / 2);
    }
    for (var i = fade; i < seg.length; i++) {
      out.add(seg[i]);
    }
  }

  // Lead-in: stretch at the mean pace, then pad silence at the front so the
  // first nucleus lands on a whole beat (avoids over-stretching a short onset).
  final leadEnd = sampOf(nuc.first);
  if (leadEnd > 0) {
    final leadStretched =
        timeStretch(Float64List.sublistView(input, 0, leadEnd), meanF);
    final leadStretchedMs = leadStretched.length * 1000 / sampleRate;
    final leadBeats = math.max(1, (leadStretchedMs / beatPeriodMs).ceil());
    final targetSamp = (leadBeats * beatPeriodMs * sampleRate / 1000).round();
    final pad = targetSamp - leadStretched.length;
    if (pad > 0) out.addAll(Float64List(pad)); // leading silence
    appendSeg(leadStretched, crossfade: false);
  }

  final nucleiOut = <int>[outMs()]; // first nucleus is here

  // Body: each inter-nucleus interval stretched to one beat.
  for (var k = 1; k < nuc.length; k++) {
    appendSeg(timeStretch(
        Float64List.sublistView(input, sampOf(nuc[k - 1]), sampOf(nuc[k])),
        factors[k - 1]));
    nucleiOut.add(outMs());
  }

  // Tail after the last nucleus: mean pace, no beat constraint.
  final tailStart = sampOf(nuc.last);
  if (tailStart < input.length) {
    appendSeg(timeStretch(
        Float64List.sublistView(input, tailStart, input.length), meanF));
  }

  return BeatWarp(Float64List.fromList(out), nucleiOut);
}

/// R3 ("together, model fades"): the playback time (ms, in the **stretched**
/// timeline) at which to drop the recorded guide so the FINAL syllable is left
/// for the user to produce alone. This is a true syllable cut-off — NOT a volume
/// fade of the whole word.
///
/// Given the detected nuclei [nucleiMs] (original-recording timeline) and the
/// [stretch] factor playback is elongated by, it cuts at the midpoint between the
/// second-to-last and last nucleus: the second-to-last syllable is fully heard,
/// then the guide is gone before the last one. Returns null when there are fewer
/// than 2 nuclei (no "final syllable" to leave) — the caller then plays the whole
/// clip (no cut).
int? guideFadeCutoffMs(List<int> nucleiMs, double stretch) {
  if (stretch <= 0) return null;
  final n = [...nucleiMs]..sort();
  if (n.length < 2) return null;
  final secondLast = n[n.length - 2];
  final last = n[n.length - 1];
  final cutoffOriginalMs = (secondLast + last) / 2.0;
  return (cutoffOriginalMs * stretch).round();
}
