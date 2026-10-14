import 'package:flutter_test/flutter_test.dart';
import 'package:rhythmic_practice/ml/solo_mode.dart';
import 'package:rhythmic_practice/practice/mit_sequence.dart';

void main() {
  const scope = SoloScope();

  test('mastery is measured at the probe question, not at a stored rung', () {
    // The scope reads pass rates that the dashboard has already narrowed to
    // SoloScope.soloStep — the step that already asks for the phrase unaided.
    expect(SoloScope.soloStep, MitStep.probeQuestion);
  });

  test('high-pass-rate, well-sampled words are eligible', () {
    final eligible = scope.eligiblePhrases(
      recentPassRateByPhrase: {1: 0.9, 2: 0.95, 3: 0.79, 4: 0.5},
      recentSessionsByPhrase: {1: 5, 2: 4, 3: 5, 4: 5},
    );
    // 1: 0.9 over 5 sessions → eligible.
    // 2: 0.95 over 4 sessions → eligible.
    // 3: 0.79, just under the 0.8 bar → NOT eligible.
    // 4: 0.5 → NOT eligible.
    expect(eligible, {1, 2});
  });

  test('a word without enough recent sessions is held back', () {
    final eligible = scope.eligiblePhrases(
      recentPassRateByPhrase: {1: 1.0},
      recentSessionsByPhrase: {1: 2}, // < minRecentSessions (3)
    );
    expect(eligible, isEmpty);
  });

  test('a word never asked to stand on its own is not eligible', () {
    final eligible = scope.eligiblePhrases(
      recentPassRateByPhrase: {}, // no data
      recentSessionsByPhrase: {},
    );
    expect(eligible, isEmpty);
  });

  test('authority is advisory-only until Layer C graduates', () {
    expect(scope.authorityFor(layerCGraduated: false),
        SoloAuthority.advisoryOnly);
    expect(scope.authorityFor(layerCGraduated: true), SoloAuthority.mlAssisted);
  });

  test('available needs BOTH the caregiver switch and an eligible word', () {
    expect(scope.available(soloModeEnabled: false, eligible: {1}), isFalse);
    expect(scope.available(soloModeEnabled: true, eligible: <int>{}), isFalse);
    expect(scope.available(soloModeEnabled: true, eligible: {1}), isTrue);
  });
}
