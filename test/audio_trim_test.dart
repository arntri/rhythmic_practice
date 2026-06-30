import 'dart:math' as math;
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:rhythmic_practice/analysis/wav_reader.dart';
import 'package:rhythmic_practice/analysis/wav_writer.dart';
import 'package:rhythmic_practice/practice/audio_trim.dart';

void main() {
  const sr = 16000;

  Float64List bursts(int totalMs, List<(int, int)> windows) {
    final n = (totalMs * sr / 1000).round();
    final s = Float64List(n);
    for (final (startMs, durMs) in windows) {
      final from = (startMs * sr / 1000).round();
      final to = ((startMs + durMs) * sr / 1000).round();
      for (var i = from; i < to && i < n; i++) {
        s[i] = 0.5 * math.sin(2 * math.pi * 200 * i / sr);
      }
    }
    return s;
  }

  test('trims long leading/trailing silence around the word', () {
    // 2 s of leading silence, a 400 ms word, then 1 s of trailing silence.
    final s = bursts(3400, [(2000, 400)]);
    final trimmed = trimToSpeech(s);
    final trimmedMs = trimmed.length * 1000 / sr;
    // Word (400) + 2×80 ms pad ≈ 560 ms; allow generous slack.
    expect(trimmedMs, lessThan(900));
    expect(trimmedMs, greaterThan(400));
    // The trimmed clip should be loud right near its start (no leading silence).
    final earlyEnergy = trimmed.take(sr ~/ 5).fold<double>(0, (a, b) => a + b * b);
    expect(earlyEnergy, greaterThan(0.1));
  });

  test('all-silence clip is returned unchanged (never empty)', () {
    final s = Float64List(sr); // 1 s of zeros
    expect(trimToSpeech(s).length, s.length);
  });

  test('trimmed samples survive a WAV encode/decode round-trip', () {
    final s = bursts(2000, [(1000, 300)]);
    final trimmed = trimToSpeech(s);
    final decoded = WavReader.decode(WavWriter.encode(trimmed));
    expect(decoded.length, trimmed.length);
    // Values preserved within PCM16 quantization.
    for (var i = 0; i < decoded.length; i += 50) {
      expect((decoded[i] - trimmed[i]).abs(), lessThan(0.001));
    }
  });
}
