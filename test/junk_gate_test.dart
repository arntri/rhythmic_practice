// Junk-gate tests (Phase 2A step 4). Synthesized signals stand in for the
// human's recorded junk fixtures (silence/cough/hum), which arrive for step 5.
// Each test targets one rejection reason with a clearly non-boundary signal.

import 'dart:math' as math;
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:rhythmic_practice/analysis/audio_config.dart';
import 'package:rhythmic_practice/analysis/junk_gate.dart';

/// A sine tone at [freq] Hz lasting [ms] milliseconds, amplitude [amp].
Float64List tone(double freq, int ms, {double amp = 0.5}) {
  final n = (AudioFormat.sampleRate * ms / 1000).round();
  final s = Float64List(n);
  for (var i = 0; i < n; i++) {
    s[i] = amp * math.sin(2 * math.pi * freq * i / AudioFormat.sampleRate);
  }
  return s;
}

void main() {
  group('rejections', () {
    test('pure silence is rejected as too_quiet', () {
      final r = JunkGate.evaluate(Float64List(AudioFormat.sampleRate)); // 1 s of 0s
      expect(r.passed, isFalse);
      expect(r.reason, 'too_quiet');
    });

    test('a very low-level signal is rejected as too_quiet', () {
      // amp 0.004 -> RMS ~0.0028, below GateConfig.minRms (0.01).
      final r = JunkGate.evaluate(tone(440, 1000, amp: 0.004));
      expect(r.reason, 'too_quiet');
    });

    test('a loud but very short clip is rejected as too_short', () {
      // 150 ms of clear tone: loud enough, but far under the 300 ms voiced floor.
      final r = JunkGate.evaluate(tone(440, 150));
      expect(r.passed, isFalse);
      expect(r.reason, 'too_short');
    });

    test('a runaway recording is rejected as too_long', () {
      final r = JunkGate.evaluate(tone(440, 11000)); // 11 s > 10 s cap
      expect(r.passed, isFalse);
      expect(r.reason, 'too_long');
    });
  });

  group('acceptance', () {
    test('a normal ~1 s spoken-length tone passes with reason ok', () {
      final r = JunkGate.evaluate(tone(440, 1000));
      expect(r.passed, isTrue);
      expect(r.reason, 'ok');
      expect(r.durationMs, closeTo(1000, 2));
    });
  });

  group('reporting & determinism', () {
    test('durationMs reflects the sample count', () {
      final r = JunkGate.evaluate(tone(300, 500));
      expect(r.durationMs, closeTo(500, 2));
    });

    test('same input gives the same verdict', () {
      final a = JunkGate.evaluate(tone(440, 800));
      final b = JunkGate.evaluate(tone(440, 800));
      expect(a.reason, b.reason);
      expect(a.durationMs, b.durationMs);
    });

    test('empty input is not "ok"', () {
      final r = JunkGate.evaluate(Float64List(0));
      expect(r.passed, isFalse);
    });
  });
}
