// Decode tests for the WAV reader (Phase 2A brief, build order step 1).
//
// These need NO fixture files: we build valid (and deliberately invalid) WAV
// byte buffers by hand, so the tests are fully self-contained and deterministic.
// The human's real recorded fixtures only come into play for the similarity
// steps later.

import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:rhythmic_practice/analysis/audio_config.dart';
import 'package:rhythmic_practice/analysis/wav_reader.dart';

/// Builds a minimal canonical WAV byte buffer (RIFF / fmt / data) from a list of
/// signed 16-bit samples. Lets tests vary format fields to probe the validator.
Uint8List buildWav(
  List<int> samples, {
  int sampleRate = AudioFormat.sampleRate,
  int channels = AudioFormat.channels,
  int bitsPerSample = AudioFormat.bitsPerSample,
  int audioFormat = 1, // 1 = PCM
  List<({String id, List<int> bytes})> extraChunks = const [],
}) {
  final dataBytes = ByteData(samples.length * 2);
  for (var i = 0; i < samples.length; i++) {
    dataBytes.setInt16(i * 2, samples[i], Endian.little);
  }

  final out = BytesBuilder();

  void putTag(String tag) => out.add(tag.codeUnits);
  void putU32(int v) {
    final b = ByteData(4)..setUint32(0, v, Endian.little);
    out.add(b.buffer.asUint8List());
  }

  // --- fmt chunk payload (16 bytes for PCM) ---
  final fmt = BytesBuilder();
  void fmtU16(int v) {
    final b = ByteData(2)..setUint16(0, v, Endian.little);
    fmt.add(b.buffer.asUint8List());
  }

  void fmtU32(int v) {
    final b = ByteData(4)..setUint32(0, v, Endian.little);
    fmt.add(b.buffer.asUint8List());
  }

  final blockAlign = channels * (bitsPerSample ~/ 8);
  fmtU16(audioFormat);
  fmtU16(channels);
  fmtU32(sampleRate);
  fmtU32(sampleRate * blockAlign); // byteRate
  fmtU16(blockAlign);
  fmtU16(bitsPerSample);
  final fmtBytes = fmt.toBytes();

  // --- assemble body (everything after the 12-byte RIFF/WAVE header) ---
  final body = BytesBuilder();
  void bodyTag(String t) => body.add(t.codeUnits);
  void bodyU32(int v) {
    final b = ByteData(4)..setUint32(0, v, Endian.little);
    body.add(b.buffer.asUint8List());
  }

  bodyTag('fmt ');
  bodyU32(fmtBytes.length);
  body.add(fmtBytes);

  // Any extra chunks (e.g. a 'LIST') placed before 'data' to exercise skipping.
  for (final c in extraChunks) {
    bodyTag(c.id);
    bodyU32(c.bytes.length);
    body.add(c.bytes);
    if (c.bytes.length.isOdd) body.addByte(0); // pad to even
  }

  bodyTag('data');
  bodyU32(dataBytes.lengthInBytes);
  body.add(dataBytes.buffer.asUint8List());

  final bodyBytes = body.toBytes();

  // --- RIFF/WAVE header wrapping the body ---
  putTag('RIFF');
  putU32(4 + bodyBytes.length); // 'WAVE' + body
  putTag('WAVE');
  out.add(bodyBytes);

  return out.toBytes();
}

void main() {
  group('WavReader.decode — happy path', () {
    test('decodes samples and normalizes int16 to -1.0..1.0', () {
      // 0 -> 0.0, 16384 -> 0.5, -16384 -> -0.5, full scale endpoints.
      final wav = buildWav([0, 16384, -16384, 32767, -32768]);
      final s = WavReader.decode(wav);

      expect(s.length, 5);
      expect(s[0], 0.0);
      expect(s[1], closeTo(0.5, 1e-12));
      expect(s[2], closeTo(-0.5, 1e-12));
      expect(s[3], closeTo(32767 / 32768.0, 1e-12)); // ~0.99997
      expect(s[4], -1.0); // -32768 / 32768
    });

    test('sample count matches the data chunk', () {
      final wav = buildWav(List<int>.filled(1600, 100)); // 100 ms at 16 kHz
      final s = WavReader.decode(wav);
      expect(s.length, 1600);
      // Duration helper the analyzer will use later.
      expect(s.length / AudioFormat.sampleRate, closeTo(0.1, 1e-12));
    });

    test('decodes an empty data chunk to zero samples', () {
      final s = WavReader.decode(buildWav([]));
      expect(s, isEmpty);
    });

    test('skips unknown chunks placed before data', () {
      final wav = buildWav(
        [1000, -1000],
        extraChunks: [
          (id: 'LIST', bytes: List<int>.filled(7, 0xAB)), // odd length -> padded
          (id: 'fact', bytes: [1, 0, 0, 0]),
        ],
      );
      final s = WavReader.decode(wav);
      expect(s.length, 2);
      expect(s[0], closeTo(1000 / 32768.0, 1e-12));
    });

    test('is deterministic — same bytes give identical samples', () {
      final wav = buildWav([5, -5, 12345, -12345]);
      expect(WavReader.decode(wav), WavReader.decode(wav));
    });
  });

  group('WavReader.decode — rejects bad input loudly', () {
    test('non-RIFF data', () {
      expect(() => WavReader.decode(Uint8List.fromList(List.filled(64, 0))),
          throwsA(isA<WavFormatException>()));
    });

    test('too small to be a WAV', () {
      expect(() => WavReader.decode(Uint8List.fromList([1, 2, 3])),
          throwsA(isA<WavFormatException>()));
    });

    test('wrong sample rate', () {
      final wav = buildWav([0, 0], sampleRate: 44100);
      expect(
        () => WavReader.decode(wav),
        throwsA(isA<WavFormatException>()
            .having((e) => e.message, 'message', contains('44100'))),
      );
    });

    test('stereo (wrong channel count)', () {
      final wav = buildWav([0, 0], channels: 2);
      expect(
        () => WavReader.decode(wav),
        throwsA(isA<WavFormatException>()
            .having((e) => e.message, 'message', contains('channels'))),
      );
    });

    test('wrong bit depth', () {
      final wav = buildWav([0, 0], bitsPerSample: 8);
      expect(
        () => WavReader.decode(wav),
        throwsA(isA<WavFormatException>()
            .having((e) => e.message, 'message', contains('PCM16'))),
      );
    });

    test('non-PCM encoding', () {
      final wav = buildWav([0, 0], audioFormat: 3); // 3 = IEEE float
      expect(
        () => WavReader.decode(wav),
        throwsA(isA<WavFormatException>()
            .having((e) => e.message, 'message', contains('PCM'))),
      );
    });
  });
}
