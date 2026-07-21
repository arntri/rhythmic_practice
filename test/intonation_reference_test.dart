import 'package:flutter_test/flutter_test.dart';
import 'package:rhythmic_practice/practice/intonation_contour.dart';
import 'package:rhythmic_practice/practice/intonation_reference.dart';

void main() {
  // Syllable centres for the default template (450 ms tone + 90 ms gap): syllable
  // s spans [s*540, s*540+450] ms, so its centre is s*540 + 225.
  List<int> centres(int count) => [for (var s = 0; s < count; s++) s * 540 + 225];

  test('the synthesized melody puts the HIGH note on the stressed syllable', () {
    for (final stress in [0, 1, 2]) {
      final samples =
          synthesizeReferenceMelody(syllableCount: 3, stressIndex: stress);
      final contour = analyzeContour(samples, centres(3));
      expect(contour.stressedIndex, stress,
          reason: 'high note should be on syllable $stress');
      // A minor third of movement (~3 semitones) — clearly not flat.
      expect(contour.pitchRangeSemitones, greaterThan(2.0));
      // And it passes the "good enough" check against that same syllable.
      expect(checkContour(contour, expectedStressIndex: stress).isGood, isTrue);
    }
  });

  test('the generic two-tone is a clear high→low (falling) shape', () {
    final contour = analyzeContour(genericTwoTone(), centres(2));
    expect(contour.stressedIndex, 0); // high first
    expect(contour.highLowSteps, [true, false]);
  });

  test('stressIndex is clamped into range (never throws)', () {
    final samples =
        synthesizeReferenceMelody(syllableCount: 2, stressIndex: 9);
    final contour = analyzeContour(samples, centres(2));
    expect(contour.stressedIndex, 1); // clamped to the last syllable
  });
}
