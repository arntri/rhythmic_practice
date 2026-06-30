/// One home for every number the analysis core uses (Phase 2A brief §3).
///
/// Keeping all the signal-processing constants in a single file means the DSP
/// is *tunable in one place* and the rest of the code never hard-codes a magic
/// number. Nothing here depends on Flutter, the microphone, or audio playback —
/// it's just plain constants, so it's trivially testable and reusable.
///
/// A quick mental model of the audio we expect: a short (1–5 s) recording of one
/// spoken word, captured as **16,000 samples per second**, **one channel**
/// (mono), each sample a **16-bit signed integer** (PCM16). The [WavReader]
/// turns those integers into floating-point samples in the range -1.0..1.0.
library;

/// Audio format we accept. We do NOT resample or down-mix in v1 — a file that
/// doesn't match these is rejected loudly (see [WavReader]). This keeps the
/// numbers deterministic: there's exactly one path through the math.
class AudioFormat {
  /// Samples per second. 16 kHz is plenty for speech (captures up to 8 kHz,
  /// above the energy that matters for distinguishing words) and keeps the math
  /// cheap.
  static const int sampleRate = 16000;

  /// Mono. One microphone, one channel of samples.
  static const int channels = 1;

  /// 16-bit signed PCM. Each sample is an integer in -32768..32767.
  static const int bitsPerSample = 16;

  /// The divisor that maps a 16-bit integer sample onto the floating-point
  /// range -1.0..1.0 (32768 = 2^15). We divide by this on decode so every later
  /// stage (energy, MFCC) works in normalized units independent of bit depth.
  static const double pcm16FullScale = 32768.0;
}

/// MFCC / framing constants (brief §3). Defined here now so step 1 keeps them in
/// one place; the MFCC code (step 2) reads them. A "frame" is a short slice of
/// audio we analyse on its own; speech changes slowly enough that ~25 ms looks
/// roughly steady, so we chop the signal into overlapping 25 ms frames.
class MfccConfig {
  /// Pre-emphasis coefficient: a simple filter that lifts the quieter high
  /// frequencies before analysis, which helps speech features stand out.
  static const double preEmphasis = 0.97;

  /// Frame (window) length in samples: 25 ms at 16 kHz = 400 samples.
  static const int frameLengthSamples = 400;

  /// Hop (step) between consecutive frames: 10 ms at 16 kHz = 160 samples.
  /// Frames overlap (400 > 160) so we don't miss transitions between them.
  static const int frameHopSamples = 160;

  /// FFT size. A power of two ≥ frame length; the 400-sample frame is zero-padded
  /// to 512 before the transform.
  static const int fftSize = 512;

  /// Number of mel filters. The "mel" scale spaces frequency bands the way human
  /// hearing does (finer at low pitches, coarser at high), so the filterbank
  /// summarizes the spectrum into 26 perceptually-shaped energy bands.
  static const int melFilterCount = 26;

  /// Low/high edge of the mel filterbank, in Hz. Upper edge is the Nyquist
  /// frequency (half the sample rate).
  static const double melLowHz = 0.0;
  static const double melHighHz = 8000.0;

  /// Number of MFCC coefficients kept per frame (c0..c12). After taking the log
  /// of the mel energies and a DCT, the first 13 numbers capture the spectral
  /// shape compactly.
  static const int coeffCount = 13;
}

/// Junk-gate thresholds (brief §3). These reject unusable clips (silence, a
/// cough, a runaway recording) *before* we spend effort scoring them. Defaults
/// are deliberately conservative; real thresholds get tuned later from real
/// data, so they live here for easy adjustment.
class GateConfig {
  /// Reject if the voiced portion is shorter than this. "Voiced" = frames whose
  /// energy rises above the noise floor; too little voiced audio means there's
  /// no real attempt to score.
  static const int minVoicedMs = 300;

  /// Reject if the whole clip is longer than this (a recorder left running).
  static const int maxDurationMs = 10000;

  /// Minimum overall loudness (RMS, in the normalized -1..1 units) for a clip to
  /// count as containing speech at all. Below this it's effectively silence.
  static const double minRms = 0.01;

  /// Energy below this (RMS per frame) is treated as background noise, not voice,
  /// when measuring voiced duration.
  static const double noiseFloorRms = 0.02;
}
