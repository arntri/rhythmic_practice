import '../practice/mit_sequence.dart';

/// **Scoped solo mode** (audit item 19) — scaffold.
///
/// The long-term idea: once a word is genuinely mastered, the patient could
/// practise it *on their own* — without a caregiver marking every single rep —
/// with the app giving light feedback. Two things make that safe, and both are
/// enforced here:
///
///  1. **Scope by mastery.** Only words the person already carries at MIT's most
///     independent step — answering a question with the phrase, no model — with
///     a strong recent pass rate there, are eligible ([eligiblePhrases]). A word
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
    this.minRecentPassRate = 0.8,
    this.minRecentSessions = 3,
  });

  /// The MIT step mastery is measured at. Solo practice means no model and no
  /// per-production caregiver check, so the only fair evidence for it is the
  /// step that already asks for the phrase unaided: the probe question.
  ///
  /// This replaced a `minRungLevel` threshold. Under the ladder a word *sat* at
  /// a rung, so "is it at R6 or above" was a question you could ask of the word;
  /// with the sequence run in full every session there is no resting rung to
  /// compare, and the honest question is how the person does at the hardest step
  /// when they get there.
  static const MitStep soloStep = MitStep.probeQuestion;

  /// Minimum recent pass rate at [soloStep] for eligibility.
  final double minRecentPassRate;

  /// Minimum recent judged sessions that pass rate must be based on — so a word
  /// isn't declared "mastered" off one lucky session.
  final int minRecentSessions;

  /// The active phrases mastered enough to practise solo: those whose recent
  /// pass rate at [soloStep] is ≥ [minRecentPassRate] over at least
  /// [minRecentSessions] sessions. A phrase with no history at that step has
  /// never been asked to stand on its own, so it never qualifies.
  Set<int> eligiblePhrases({
    required Map<int, double> recentPassRateByPhrase,
    required Map<int, int> recentSessionsByPhrase,
  }) {
    final out = <int>{};
    for (final entry in recentPassRateByPhrase.entries) {
      final id = entry.key;
      final rate = entry.value;
      final sessions = recentSessionsByPhrase[id] ?? 0;
      if (rate >= minRecentPassRate && sessions >= minRecentSessions) {
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
