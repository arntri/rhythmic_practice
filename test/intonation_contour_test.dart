import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:rhythmic_practice/analysis/audio_config.dart';
import 'package:rhythmic_practice/practice/intonation_contour.dart';

import 'wav_builder.dart';

void main() {
  // A two-syllable clip: tone [f1] (200 ms), 100 ms gap, tone [f2] (200 ms).
  // Nuclei sit at the centre of each tone (100 ms and 400 ms).
  Float64List twoSyllable(double f1, double f2) {
    final gap = List<double>.filled(AudioFormat.sampleRate ~/ 10, 0.0); // 100 ms
    return Float64List.fromList([
      ...toneDoubles(f1, 200),
      ...gap,
      ...toneDoubles(f2, 200),
    ]);
  }

  const nuclei = [100, 400];

  test('detects the higher-pitched syllable as stressed, with real movement', () {
    final c = analyzeContour(twoSyllable(260, 180), nuclei);
    expect(c.syllableCount, 2);
    expect(c.stressedIndex, 0); // 260 Hz > 180 Hz
    expect(c.pitchRangeSemitones, greaterThan(3.0)); // clear rise (~6 semitones)
    // High/low steps: first up, second down.
    expect(c.highLowSteps, [true, false]);
  });

  test('good-enough passes when the high note is on the expected syllable', () {
    final c = analyzeContour(twoSyllable(260, 180), nuclei);
    final ok = checkContour(c, expectedStressIndex: 0);
    expect(ok.verdict, ContourVerdict.good);
    expect(ok.isGood, isTrue);
  });

  test('mis-stress is flagged when the high note is on the wrong syllable', () {
    final c = analyzeContour(twoSyllable(260, 180), nuclei); // high on #0
    final check = checkContour(c, expectedStressIndex: 1); // expected on #1
    expect(check.verdict, ContourVerdict.misStressed);
    expect(check.offendingSyllable, 0); // where it actually landed
    expect(check.expectedSyllable, 1);
  });

  test('a flat (even) contour is flagged, pointing at the syllable to lift', () {
    final c = analyzeContour(twoSyllable(200, 200), nuclei); // no movement
    expect(c.pitchRangeSemitones, lessThan(1.5));
    final check = checkContour(c, expectedStressIndex: 0);
    expect(check.verdict, ContourVerdict.flat);
    expect(check.offendingSyllable, 0);
  });

  test('with equal pitch, the louder syllable is picked as stressed', () {
    // Same 220 Hz on both syllables, but the second is much louder — energy
    // breaks the pitch tie (item 4: pitch + energy + duration).
    final loudSecond = Float64List.fromList([
      ...toneDoubles(220, 200, amp: 0.15),
      ...List<double>.filled(AudioFormat.sampleRate ~/ 10, 0.0),
      ...toneDoubles(220, 200, amp: 0.6),
    ]);
    final c = analyzeContour(loudSecond, nuclei);
    expect(c.stressedIndex, 1);
  });

  test('silence → tooQuiet (nothing voiced to judge)', () {
    final silent = Float64List(AudioFormat.sampleRate); // 1 s of zeros
    final c = analyzeContour(silent, nuclei);
    expect(c.stressedIndex, -1);
    final check = checkContour(c, expectedStressIndex: 0);
    expect(check.verdict, ContourVerdict.tooQuiet);
  });

  test('a single-syllable phrase passes when voiced (no relative contour)', () {
    final one = Float64List.fromList(toneDoubles(220, 200));
    final c = analyzeContour(one, const [100]);
    expect(c.syllableCount, 1);
    final check = checkContour(c, expectedStressIndex: 0);
    expect(check.verdict, ContourVerdict.good);
  });
}
