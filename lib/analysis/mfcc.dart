import 'dart:math' as math;
import 'dart:typed_data';

import 'package:fftea/fftea.dart';

import 'audio_config.dart';

/// Turns a stream of audio samples into **MFCCs** — Mel-Frequency Cepstral
/// Coefficients — the compact "fingerprint of the sound's shape" that the rest
/// of the analysis core compares (Phase 2A brief §3).
///
/// ### What an MFCC is, in plain language
/// Speech changes slowly, so we chop the audio into short overlapping slices
/// called **frames** (~25 ms each). For each frame we ask: "how much energy is
/// there at each pitch?" — the *spectrum*, computed with an FFT. Human hearing
/// doesn't treat pitches evenly (we distinguish low pitches far more finely than
/// high ones), so we squash the spectrum through a **mel filterbank**: a set of
/// triangular windows, narrow at low frequencies and wide at high ones, each
/// summing the energy in its band. We take the log of those band energies
/// (loudness is perceived logarithmically), then a **DCT** to decorrelate them
/// and keep just the first 13 numbers, which capture the overall spectral shape
/// while discarding fine detail. Those 13 numbers per frame are the MFCCs.
///
/// The result is `List<Float64List>`: one `Float64List` of 13 coefficients per
/// frame. Same samples in → byte-identical numbers out (determinism matters for
/// reproducible scoring).
///
/// Everything is pure Dart (FFT via the `fftea` package). No Flutter, no device.
class Mfcc {
  Mfcc()
      : _window = _hammingWindow(MfccConfig.frameLengthSamples),
        _fft = FFT(MfccConfig.fftSize),
        _melFilters = _buildMelFilterbank(),
        _dctBasis = _buildDctBasis(MfccConfig.melFilterCount, MfccConfig.coeffCount);

  /// Hamming window, applied to each frame to soften its edges so the FFT
  /// doesn't see abrupt cut-offs (which would smear energy across the spectrum).
  final Float64List _window;

  /// Reusable FFT engine sized to [MfccConfig.fftSize]. Allocated once.
  final FFT _fft;

  /// 26 triangular mel filters, each a weight per FFT power-spectrum bin.
  final List<Float64List> _melFilters;

  /// Precomputed DCT-II basis: `_dctBasis[k][n]` is the weight of log-mel band
  /// `n` in output coefficient `k`. Orthonormal, so it matches scipy/librosa.
  final List<Float64List> _dctBasis;

  /// Number of FFT power-spectrum bins we keep: 0 Hz .. Nyquist inclusive.
  static int get _spectrumBins => MfccConfig.fftSize ~/ 2 + 1;

  /// How many frames [extract] will produce for a signal of [sampleLength]
  /// samples. Exposed (and used internally) so callers/tests can predict shape.
  ///
  /// - 0 samples → 0 frames.
  /// - shorter than one frame → 1 frame (the short signal is zero-padded).
  /// - otherwise → 1 + ceil((len - frameLen) / hop): the first frame plus one
  ///   per hop, with the final partial frame zero-padded to a full window.
  static int frameCount(int sampleLength) {
    if (sampleLength <= 0) return 0;
    if (sampleLength <= MfccConfig.frameLengthSamples) return 1;
    final extra = sampleLength - MfccConfig.frameLengthSamples;
    return 1 + (extra / MfccConfig.frameHopSamples).ceil();
  }

  /// Extract MFCCs from normalized samples (-1.0..1.0, as [WavReader] returns).
  /// Returns frames × [MfccConfig.coeffCount] coefficients.
  List<Float64List> extract(Float64List samples) {
    final frames = frameCount(samples.length);
    if (frames == 0) return const [];

    // Pre-emphasis: a one-tap filter y[n] = x[n] - a*x[n-1] that lifts the
    // quieter high frequencies so they aren't swamped by low-frequency energy.
    final emphasized = Float64List(samples.length);
    if (samples.isNotEmpty) {
      emphasized[0] = samples[0];
      for (var i = 1; i < samples.length; i++) {
        emphasized[i] = samples[i] - MfccConfig.preEmphasis * samples[i - 1];
      }
    }

    // Reused per-frame FFT input buffer: first frameLength slots get the
    // windowed samples, the rest stay zero (zero-padding up to fftSize). We only
    // ever overwrite slots 0..frameLength-1, so the tail remains zero forever.
    final fftInput = Float64List(MfccConfig.fftSize);
    final out = <Float64List>[];

    for (var f = 0; f < frames; f++) {
      final start = f * MfccConfig.frameHopSamples;

      // Window the frame into the FFT buffer; pad with zeros past the signal end.
      for (var i = 0; i < MfccConfig.frameLengthSamples; i++) {
        final idx = start + i;
        final sample = idx < emphasized.length ? emphasized[idx] : 0.0;
        fftInput[i] = sample * _window[i];
      }

      // FFT -> power spectrum (energy per frequency bin), keeping 0..Nyquist.
      final spectrum = _fft.realFft(fftInput);
      final power = Float64List(_spectrumBins);
      for (var k = 0; k < _spectrumBins; k++) {
        final re = spectrum[k].x;
        final im = spectrum[k].y;
        // |X|^2 / N — the standard power-spectrum normalization.
        power[k] = (re * re + im * im) / MfccConfig.fftSize;
      }

      // Apply each mel filter, then take the log of its summed band energy.
      final logMel = Float64List(MfccConfig.melFilterCount);
      for (var m = 0; m < MfccConfig.melFilterCount; m++) {
        final filter = _melFilters[m];
        var energy = 0.0;
        for (var k = 0; k < _spectrumBins; k++) {
          energy += power[k] * filter[k];
        }
        // Floor before log so silence (energy 0) gives a finite value, not -inf.
        logMel[m] = math.log(energy < 1e-10 ? 1e-10 : energy);
      }

      // DCT-II of the log-mel energies; keep the first 13 coefficients.
      final coeffs = Float64List(MfccConfig.coeffCount);
      for (var c = 0; c < MfccConfig.coeffCount; c++) {
        final basis = _dctBasis[c];
        var sum = 0.0;
        for (var n = 0; n < MfccConfig.melFilterCount; n++) {
          sum += logMel[n] * basis[n];
        }
        coeffs[c] = sum;
      }
      out.add(coeffs);
    }
    return out;
  }

  // --- one-time setup helpers ------------------------------------------------

  /// Hamming window of length [n]: 0.54 - 0.46·cos(2πi/(n-1)).
  static Float64List _hammingWindow(int n) {
    final w = Float64List(n);
    for (var i = 0; i < n; i++) {
      w[i] = 0.54 - 0.46 * math.cos(2 * math.pi * i / (n - 1));
    }
    return w;
  }

  /// Mel scale conversions. The mel scale is "perceived pitch": equal steps in
  /// mels sound equally spaced to a human, unlike equal steps in Hz.
  static double _hzToMel(double hz) => 2595.0 * _log10(1 + hz / 700.0);
  static double _melToHz(double mel) => 700.0 * (math.pow(10, mel / 2595.0) - 1);
  static double _log10(double x) => math.log(x) / math.ln10;

  /// Build 26 triangular mel filters over the FFT power-spectrum bins.
  ///
  /// We place [melFilterCount]+2 points evenly on the mel scale between the low
  /// and high edges, convert them back to Hz, then to FFT bin indices. Filter m
  /// is a triangle that ramps up from point m to point m+1 and back down to
  /// point m+2 — so adjacent filters overlap and tile the spectrum.
  static List<Float64List> _buildMelFilterbank() {
    final lowMel = _hzToMel(MfccConfig.melLowHz);
    final highMel = _hzToMel(MfccConfig.melHighHz);
    final pointCount = MfccConfig.melFilterCount + 2;

    // FFT bin index for each mel point.
    final bins = List<int>.generate(pointCount, (i) {
      final mel = lowMel + (highMel - lowMel) * i / (pointCount - 1);
      final hz = _melToHz(mel);
      return ((MfccConfig.fftSize + 1) * hz / AudioFormat.sampleRate).floor();
    });

    final filters = List<Float64List>.generate(
        MfccConfig.melFilterCount, (_) => Float64List(_spectrumBins));

    for (var m = 0; m < MfccConfig.melFilterCount; m++) {
      final left = bins[m];
      final center = bins[m + 1];
      final right = bins[m + 2];
      // Up-ramp left..center. Guard against collapsed bins at low frequencies.
      if (center > left) {
        for (var k = left; k < center; k++) {
          if (k >= 0 && k < _spectrumBins) {
            filters[m][k] = (k - left) / (center - left);
          }
        }
      }
      // Down-ramp center..right.
      if (right > center) {
        for (var k = center; k < right; k++) {
          if (k >= 0 && k < _spectrumBins) {
            filters[m][k] = (right - k) / (right - center);
          }
        }
      }
    }
    return filters;
  }

  /// Orthonormal DCT-II basis. Output coefficient k is a weighted sum of the N
  /// log-mel energies; this precomputes those weights. The orthonormal scaling
  /// (1/√N for k=0, √(2/N) otherwise) matches scipy's `dct(..., norm='ortho')`,
  /// so our coefficients line up with standard MFCC references.
  static List<Float64List> _buildDctBasis(int n, int k) {
    final basis = List<Float64List>.generate(k, (_) => Float64List(n));
    final scale0 = math.sqrt(1.0 / n);
    final scaleK = math.sqrt(2.0 / n);
    for (var c = 0; c < k; c++) {
      final scale = c == 0 ? scale0 : scaleK;
      for (var i = 0; i < n; i++) {
        basis[c][i] = scale * math.cos(math.pi / n * (i + 0.5) * c);
      }
    }
    return basis;
  }
}
