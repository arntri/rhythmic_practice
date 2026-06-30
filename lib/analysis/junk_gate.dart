import 'dart:math' as math;
import 'dart:typed_data';

import 'audio_config.dart';

/// The **junk gate**: a cheap quality check that runs *before* any MFCC/DTW work
/// (Phase 2A brief §3). Its job is to throw out clips that can't carry a real
/// spoken attempt — silence, a stray cough that's too short, a recorder left
/// running — so we never waste effort scoring them or, worse, report a
/// meaningless similarity number.
///
/// A rejected clip gets **no similarity score** (the caller skips scoring and
/// persists `gate_passed = 0` with the reason). All thresholds live in
/// [GateConfig] and are deliberately conservative; they'll be tuned later from
/// real recordings.
class JunkGate {
  /// Evaluate normalized samples (-1.0..1.0, as [WavReader] returns).
  ///
  /// Checks run in order of "most obviously unusable" first, so the reported
  /// reason is the most meaningful one:
  ///   1. too long  — a runaway recording.
  ///   2. too quiet — overall loudness below the speech floor (this is how pure
  ///      silence is caught).
  ///   3. too short — not enough *voiced* audio to be a real attempt.
  static GateResult evaluate(Float64List samples) {
    final durationMs =
        (samples.length / AudioFormat.sampleRate * 1000).round();

    // 1. Runaway recording.
    if (durationMs > GateConfig.maxDurationMs) {
      return GateResult._('too_long', durationMs);
    }

    // 2. Overall loudness. RMS = root-mean-square, the standard measure of
    // signal level; near-zero means effectively silence.
    final overallRms = _rms(samples, 0, samples.length);
    if (overallRms < GateConfig.minRms) {
      return GateResult._('too_quiet', durationMs);
    }

    // 3. Voiced duration: frame the clip and count frames whose energy rises
    // above the noise floor. Each frame advances by one hop (10 ms), so the
    // voiced-frame count times the hop is roughly how long the speaker was
    // actually producing sound. (This is an estimate; thresholds are relative.)
    final hopMs =
        MfccConfig.frameHopSamples / AudioFormat.sampleRate * 1000.0;
    final n = samples.length;
    var voicedFrames = 0;
    for (var start = 0; start < n; start += MfccConfig.frameHopSamples) {
      final end = math.min(start + MfccConfig.frameLengthSamples, n);
      if (_rms(samples, start, end) > GateConfig.noiseFloorRms) {
        voicedFrames++;
      }
      if (end >= n) break; // this frame reached the end of the clip
    }
    final voicedMs = voicedFrames * hopMs;
    if (voicedMs < GateConfig.minVoicedMs) {
      return GateResult._('too_short', durationMs);
    }

    return GateResult._('ok', durationMs);
  }

  /// Root-mean-square level of samples[from..to).
  static double _rms(Float64List samples, int from, int to) {
    if (to <= from) return 0.0;
    var sumSq = 0.0;
    for (var i = from; i < to; i++) {
      sumSq += samples[i] * samples[i];
    }
    return math.sqrt(sumSq / (to - from));
  }
}

/// The gate's verdict for one clip.
class GateResult {
  const GateResult._(this.reason, this.durationMs);

  /// Machine-readable reason, stored directly in
  /// `acoustic_feature_vectors.gate_reason`:
  /// `'ok'`, `'too_quiet'`, `'too_short'`, or `'too_long'`.
  final String reason;

  /// Clip length in milliseconds, derived from the sample count.
  final int durationMs;

  /// True only when the clip passed every check and is worth scoring.
  bool get passed => reason == 'ok';
}
