// Tap-to-beat synchronization scoring — pure arithmetic, no Flutter, fully
// unit-testable (brief §6 "Derived values").
//
// We measure how well taps land on the beat using the metronome's *phase*:
// the engine already tells us, at any instant, how far we are between beats
// (0.0 = right on a beat, rising to 1.0 just before the next). When a tap
// happens we sample that phase. This avoids mixing two different clocks (tap
// timestamps vs. audio/beat timestamps), which is fiddly and error-prone.

/// How far a tap at [phase] is from the nearest beat, as a fraction of one beat
/// interval. A beat is at phase 0.0 *and* 1.0, so the nearest-beat distance is
/// `min(phase, 1 - phase)`, giving a value in 0.0 (perfect) .. 0.5 (worst,
/// exactly halfway between beats).
double offsetFromBeat(double phase) {
  final p = phase % 1.0; // guard against accidental values outside [0,1)
  return p < 0.5 ? p : 1.0 - p;
}

/// Whether a tap at [phase] counts as "in time" — within [tolerance] of a beat.
/// Default 0.15 ≈ within 15% of the interval (150 ms at 60 BPM).
bool isInTime(double phase, {double tolerance = 0.15}) {
  return offsetFromBeat(phase) <= tolerance;
}

/// Maps a list of tap phases to a 0.0..1.0 synchronization score: 1.0 when every
/// tap was dead on the beat, 0.0 when every tap was as far off as possible
/// (halfway between beats). Returns null when there were no taps to score.
double? syncScoreFromPhases(List<double> tapPhases) {
  if (tapPhases.isEmpty) return null;
  final avgOffset =
      tapPhases.map(offsetFromBeat).reduce((a, b) => a + b) / tapPhases.length;
  // avgOffset ranges 0.0 (perfect) .. 0.5 (worst); rescale to 1.0 .. 0.0.
  return 1.0 - (avgOffset / 0.5);
}
