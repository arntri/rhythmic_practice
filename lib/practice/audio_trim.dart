import 'dart:math' as math;
import 'dart:typed_data';

import '../analysis/audio_config.dart';

/// Trims leading and trailing silence so a guide clip starts exactly when the
/// word starts and ends when it ends (with a small pad). This fixes guides that
/// played seconds of "emptiness" because the caregiver paused before speaking
/// (therapy addendum §2). Pure + deterministic, so it's unit-testable.
///
/// Returns the original samples unchanged if nothing rises above the speech
/// threshold (e.g. an all-silent clip), so callers never get an empty buffer.
Float64List trimToSpeech(
  Float64List samples, {
  int sampleRate = AudioFormat.sampleRate,
  int frameSamples = 400,
  int hopSamples = 160,
  double floorBelowPeakDb = 30.0, // a frame is "speech" if within this of peak
  int padMs = 80,
}) {
  if (samples.length < frameSamples) return samples;

  final hops = ((samples.length - frameSamples) ~/ hopSamples) + 1;
  final env = Float64List(hops);
  var maxDb = -160.0;
  for (var h = 0; h < hops; h++) {
    final start = h * hopSamples;
    var sumSq = 0.0;
    for (var i = 0; i < frameSamples; i++) {
      final v = samples[start + i];
      sumSq += v * v;
    }
    final db = 20.0 * (math.log(math.sqrt(sumSq / frameSamples) + 1e-10) / math.ln10);
    env[h] = db;
    if (db > maxDb) maxDb = db;
  }

  final threshold = maxDb - floorBelowPeakDb;
  var first = -1;
  var last = -1;
  for (var h = 0; h < hops; h++) {
    if (env[h] >= threshold) {
      if (first < 0) first = h;
      last = h;
    }
  }
  if (first < 0) return samples; // nothing above threshold

  final pad = (padMs * sampleRate / 1000).round();
  var startSample = (first * hopSamples) - pad;
  var endSample = (last * hopSamples + frameSamples) + pad;
  if (startSample < 0) startSample = 0;
  if (endSample > samples.length) endSample = samples.length;
  if (endSample <= startSample) return samples;

  return Float64List.fromList(samples.sublist(startSample, endSample));
}
