import 'dart:math' as math;
import 'dart:typed_data';

import 'package:fftea/fftea.dart';

import '../analysis/audio_config.dart';

/// Reduces stationary background noise (e.g. a fan) from a recording so the guide
/// plays back cleanly. Classic **spectral subtraction**: estimate the noise
/// magnitude spectrum from the quietest frames, then subtract it from every
/// frame (keeping phase), with an over-subtraction factor and a spectral floor
/// to limit "musical noise" artifacts. Weighted overlap-add reconstruction.
///
/// Pure + deterministic (FFT via `fftea`), so it's unit-testable. Conservative
/// by default — it's meant to smooth, not to scrub aggressively.
Float64List reduceNoise(
  Float64List samples, {
  int sampleRate = AudioFormat.sampleRate,
  int frameSize = 512, // ~32 ms at 16 kHz
  int hop = 256, // 50% overlap
  double overSubtraction = 1.5,
  double spectralFloor = 0.08, // keep at least 8% of each bin (anti-warble)
  double noiseEnergyRatio = 0.1, // a frame is "noise" if below 10% of peak energy
}) {
  if (samples.length < frameSize) return samples;
  final frameCount = ((samples.length - frameSize) ~/ hop) + 1;
  if (frameCount < 2) return samples;

  final fft = FFT(frameSize);
  final window = _hann(frameSize);

  // Pass 1: window + FFT each frame; keep the complex spectra and frame energy.
  final spectra = <Float64x2List>[];
  final energies = Float64List(frameCount);
  final buf = Float64List(frameSize);
  for (var f = 0; f < frameCount; f++) {
    final start = f * hop;
    var e = 0.0;
    for (var i = 0; i < frameSize; i++) {
      final s = samples[start + i] * window[i];
      buf[i] = s;
      e += s * s;
    }
    energies[f] = e;
    spectra.add(fft.realFft(buf)); // allocates a fresh array per call
  }

  // Noise profile: average magnitude over genuinely-quiet frames only (those
  // well below the loudest frame). If there's no real quiet region — e.g. the
  // caregiver spoke immediately, so every frame is speech — there's nothing to
  // estimate noise from, so we leave the clip untouched rather than scrub the
  // word itself.
  var maxEnergy = 0.0;
  for (final e in energies) {
    if (e > maxEnergy) maxEnergy = e;
  }
  final threshold = maxEnergy * noiseEnergyRatio;
  final noiseFrames = <int>[
    for (var f = 0; f < frameCount; f++)
      if (energies[f] <= threshold) f,
  ];
  if (noiseFrames.length < 2) return samples;

  final noiseMag = Float64List(frameSize);
  for (final f in noiseFrames) {
    final sp = spectra[f];
    for (var i = 0; i < frameSize; i++) {
      noiseMag[i] += _abs(sp[i]);
    }
  }
  for (var i = 0; i < frameSize; i++) {
    noiseMag[i] /= noiseFrames.length;
  }

  // Pass 2: subtract, inverse FFT, weighted overlap-add.
  final out = Float64List(samples.length);
  final norm = Float64List(samples.length);
  for (var f = 0; f < frameCount; f++) {
    final sp = spectra[f];
    for (var i = 0; i < frameSize; i++) {
      final mag = _abs(sp[i]);
      if (mag > 1e-12) {
        final reduced = mag - overSubtraction * noiseMag[i];
        final newMag = math.max(reduced, spectralFloor * mag);
        final s = newMag / mag; // scales real+imag, preserving phase
        sp[i] = Float64x2(sp[i].x * s, sp[i].y * s);
      }
    }
    final y = fft.realInverseFft(sp); // length frameSize (modifies sp)
    final start = f * hop;
    for (var i = 0; i < frameSize; i++) {
      out[start + i] += y[i] * window[i];
      norm[start + i] += window[i] * window[i];
    }
  }

  // Normalize by the window overlap. At the very start/end only one (tapering)
  // frame covers each sample, so the overlap sum approaches zero there; dividing
  // by it would massively amplify edge noise into a spike. So only normalize
  // where the overlap is substantial, and pass the original (low-level) sample
  // through at the under-covered edges.
  var maxNorm = 0.0;
  for (final v in norm) {
    if (v > maxNorm) maxNorm = v;
  }
  final floor = maxNorm * 0.1;
  for (var i = 0; i < out.length; i++) {
    if (norm[i] > floor) {
      out[i] /= norm[i];
    } else {
      out[i] = samples[i];
    }
  }
  return out;
}

Float64List _hann(int n) {
  final w = Float64List(n);
  for (var i = 0; i < n; i++) {
    w[i] = 0.5 - 0.5 * math.cos(2 * math.pi * i / (n - 1));
  }
  return w;
}

double _abs(Float64x2 c) => math.sqrt(c.x * c.x + c.y * c.y);
