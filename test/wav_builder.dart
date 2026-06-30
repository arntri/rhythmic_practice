// Shared test helper (NOT a test file — flutter test ignores non-_test.dart).
// Builds in-memory WAV byte buffers and temp WAV files so analysis tests don't
// depend on external fixtures.

import 'dart:io';
import 'dart:math' as math;
import 'dart:typed_data';

import 'package:rhythmic_practice/analysis/audio_config.dart';

/// Encode signed-16-bit samples as a canonical PCM16 mono WAV byte buffer.
Uint8List buildWavBytes(
  List<int> samples, {
  int sampleRate = AudioFormat.sampleRate,
  int channels = AudioFormat.channels,
  int bitsPerSample = AudioFormat.bitsPerSample,
  int audioFormat = 1,
}) {
  final data = ByteData(samples.length * 2);
  for (var i = 0; i < samples.length; i++) {
    data.setInt16(i * 2, samples[i], Endian.little);
  }

  final body = BytesBuilder();
  void tag(String t) => body.add(t.codeUnits);
  void u32(int v) =>
      body.add((ByteData(4)..setUint32(0, v, Endian.little)).buffer.asUint8List());
  void u16(int v) =>
      body.add((ByteData(2)..setUint16(0, v, Endian.little)).buffer.asUint8List());

  final blockAlign = channels * (bitsPerSample ~/ 8);
  tag('fmt ');
  u32(16);
  u16(audioFormat);
  u16(channels);
  u32(sampleRate);
  u32(sampleRate * blockAlign);
  u16(blockAlign);
  u16(bitsPerSample);
  tag('data');
  u32(data.lengthInBytes);
  body.add(data.buffer.asUint8List());

  final bodyBytes = body.toBytes();
  final out = BytesBuilder();
  out.add('RIFF'.codeUnits);
  out.add((ByteData(4)..setUint32(0, 4 + bodyBytes.length, Endian.little))
      .buffer
      .asUint8List());
  out.add('WAVE'.codeUnits);
  out.add(bodyBytes);
  return out.toBytes();
}

/// Convert normalized doubles (-1.0..1.0) to int16 and encode as WAV bytes.
Uint8List buildWavFromDoubles(List<double> samples) {
  final ints = samples
      .map((d) => (d * AudioFormat.pcm16FullScale)
          .round()
          .clamp(-32768, 32767))
      .toList();
  return buildWavBytes(ints);
}

/// A sine tone: [freq] Hz, [ms] long, amplitude [amp], as normalized doubles.
List<double> toneDoubles(double freq, int ms, {double amp = 0.5}) {
  final n = (AudioFormat.sampleRate * ms / 1000).round();
  return List<double>.generate(
      n, (i) => amp * math.sin(2 * math.pi * freq * i / AudioFormat.sampleRate));
}

/// Write WAV bytes to a temp file and return its path. Caller deletes the dir.
File writeTempWav(Directory dir, String name, Uint8List bytes) {
  final f = File('${dir.path}/$name');
  f.writeAsBytesSync(bytes);
  return f;
}
