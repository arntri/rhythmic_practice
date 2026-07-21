import 'package:flutter_test/flutter_test.dart';
import 'package:rhythmic_practice/ml/solo_mode.dart';

void main() {
  const scope = SoloScope();

  test('only top-rung, high-pass-rate, well-sampled words are eligible', () {
    final eligible = scope.eligiblePhrases(
      rungLevelByPhrase: {1: 6, 2: 7, 3: 4, 4: 6},
      recentPassRateByPhrase: {1: 0.9, 2: 0.95, 3: 0.99, 4: 0.5},
      recentSessionsByPhrase: {1: 5, 2: 4, 3: 5, 4: 5},
    );
    // 1: rung 6, 0.9, 5 sessions → eligible.
    // 2: rung 7, 0.95, 4 sessions → eligible.
    // 3: rung 4 (below minRungLevel 6) → NOT eligible despite perfect rate.
    // 4: rung 6 but only 0.5 pass rate → NOT eligible.
    expect(eligible, {1, 2});
  });

  test('a word without enough recent sessions is held back', () {
    final eligible = scope.eligiblePhrases(
      rungLevelByPhrase: {1: 7},
      recentPassRateByPhrase: {1: 1.0},
      recentSessionsByPhrase: {1: 2}, // < minRecentSessions (3)
    );
    expect(eligible, isEmpty);
  });

  test('a word with no pass-rate data is not eligible', () {
    final eligible = scope.eligiblePhrases(
      rungLevelByPhrase: {1: 7},
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
