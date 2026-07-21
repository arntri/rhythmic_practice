import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:rhythmic_practice/analysis/audio_config.dart';
import 'package:rhythmic_practice/analysis/pitch_detection.dart';

import 'wav_builder.dart';

void main() {
  test('estimates the pitch of an in-range pure tone within 5%', () {
    for (final hz in [150.0, 220.0, 300.0]) {
      final s = Float64List.fromList(toneDoubles(hz, 200));
      final p = estimatePitch(s, 0, s.length);
      expect(p.isVoiced, isTrue, reason: '$hz should be voiced');
      expect(p.f0Hz, closeTo(hz, hz * 0.05), reason: '$hz within 5%');
      expect(p.voicing, greaterThan(0.5));
    }
  });

  test('silence is unvoiced (no pitch)', () {
    final s = Float64List(AudioFormat.sampleRate ~/ 4); // 250 ms of zeros
    final p = estimatePitch(s, 0, s.length);
    expect(p.isVoiced, isFalse);
    expect(p.f0Hz, 0.0);
    expect(p, same(PitchEstimate.unvoiced));
  });

  test('out-of-bounds window → unvoiced (never throws)', () {
    final s = Float64List.fromList(toneDoubles(200, 100));
    expect(estimatePitch(s, 0, s.length + 10).isVoiced, isFalse);
    expect(estimatePitch(s, -1, 100).isVoiced, isFalse);
    expect(estimatePitch(s, 0, 0).isVoiced, isFalse);
  });
}
