/// **Scoped solo mode** (audit item 19) — scaffold.
///
/// The long-term idea: once a word is genuinely mastered, the patient could
/// practise it *on their own* — without a caregiver marking every single rep —
/// with the app giving light feedback. Two things make that safe, and both are
/// enforced here:
///
///  1. **Scope by mastery.** Only words that are already at the top of the ladder
///     with a strong recent pass rate are eligible ([eligiblePhrases]). A word
///     still being learned always keeps the caregiver in the loop.
///  2. **Scope by authority.** Even for eligible words, solo mode may only *stand
///     in* for the caregiver once Layer C has graduated ([authorityFor]). Until
///     then (today's reality — the model is untrained) solo mode is
///     **advisory-only**: it presents the word and collects the attempt, but a
///     caregiver still confirms the verdict. The ML never gates.
///
/// This file is the pure policy. There is no dedicated solo-practice screen yet;
/// the engine + the `solo_mode_enabled` profile flag are the wired scaffold.
class SoloScope {
  const SoloScope({
    this.minRungLevel = 6,
    this.minRecentPassRate = 0.8,
    this.minRecentSessions = 3,
  });

  /// Minimum rung level (0–7) a word must be at to be solo-eligible — solo means
  /// no model and no per-rep caregiver check, so only the solo rungs qualify.
  final int minRungLevel;

  /// Minimum recent pass rate (at the top rung) for eligibility.
  final double minRecentPassRate;

  /// Minimum recent judged sessions that pass rate must be based on — so a word
  /// isn't declared "mastered" off one lucky session.
  final int minRecentSessions;

  /// The active phrases mastered enough to practise solo. A phrase qualifies when
  /// it is at/above [minRungLevel] AND its recent top-rung pass rate is
  /// ≥ [minRecentPassRate] over at least [minRecentSessions] sessions.
  Set<int> eligiblePhrases({
    required Map<int, int> rungLevelByPhrase,
    required Map<int, double> recentPassRateByPhrase,
    required Map<int, int> recentSessionsByPhrase,
  }) {
    final out = <int>{};
    for (final entry in rungLevelByPhrase.entries) {
      final id = entry.key;
      final rung = entry.value;
      final rate = recentPassRateByPhrase[id];
      final sessions = recentSessionsByPhrase[id] ?? 0;
      if (rung >= minRungLevel &&
          rate != null &&
          rate >= minRecentPassRate &&
          sessions >= minRecentSessions) {
        out.add(id);
      }
    }
    return out;
  }

  /// What solo mode is permitted to do, given Layer C's graduation state. This is
  /// the hard guardrail that keeps the caregiver in charge until the model is
  /// proven (see the Layer C graduation gate).
  SoloAuthority authorityFor({required bool layerCGraduated}) =>
      layerCGraduated ? SoloAuthority.mlAssisted : SoloAuthority.advisoryOnly;

  /// Whether solo mode should be offered at all right now: the caregiver has
  /// switched it on AND at least one word is currently eligible.
  bool available({
    required bool soloModeEnabled,
    required Set<int> eligible,
  }) =>
      soloModeEnabled && eligible.isNotEmpty;
}

/// What a solo session may do.
enum SoloAuthority {
  /// Today's reality (Layer C ungraduated): collect the attempt and give advisory
  /// feedback, but a caregiver still confirms every verdict — ML never gates.
  advisoryOnly,

  /// Layer C has graduated: it may stand in for the caregiver on eligible words.
  /// Unreachable until a model is trained AND clears the graduation gate.
  mlAssisted,
}
