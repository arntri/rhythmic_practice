import 'dart:math' as math;

import 'progression.dart';

/// The per-(profile, phrase) progression-state record (therapy addendum §4): the
/// durable rung + syllable tier + within-rung tempo, plus two **session-scoped**
/// flags ([backedUp], [parked]) the fast loop uses and that reset each session.
///
/// This is the richer record the rules controller drives; it supersedes the lone
/// `practice_phrases.current_rung` once wired into live sessions.
class ProgressionState {
  const ProgressionState({
    required this.profileId,
    required this.phraseId,
    this.rung = Rung.r2,
    this.syllableTier = 1,
    this.bpm = MitProgression.defaultBpm,
    this.backedUp = false,
    this.parked = false,
  });

  final String profileId;
  final int phraseId;

  /// MIT support/task rung R0–R6.
  final Rung rung;

  /// Linguistic load tier (1 = single syllable, 2 = two-syllable, 3 = phrase…).
  final int syllableTier;

  /// Within-rung tempo knob (bounded to the metronome's 40–70 BPM range). Lowered
  /// before backing up a rung when the word is failing.
  final int bpm;

  /// Session-scoped: the last fail backed the rung up (so the *next* fail parks).
  final bool backedUp;

  /// Session-scoped: paused for the rest of this session after repeated failure.
  final bool parked;

  /// Build from a `progression_state` row (session flags default to false).
  factory ProgressionState.fromMap(Map<String, Object?> row) => ProgressionState(
        profileId: row['profile_id'] as String,
        phraseId: row['phrase_id'] as int,
        rung: rungFromLevel(row['current_rung'] as int),
        syllableTier: row['syllable_tier'] as int,
        bpm: row['tempo_bpm'] as int,
      );

  ProgressionState copyWith({
    Rung? rung,
    int? syllableTier,
    int? bpm,
    bool? backedUp,
    bool? parked,
  }) =>
      ProgressionState(
        profileId: profileId,
        phraseId: phraseId,
        rung: rung ?? this.rung,
        syllableTier: syllableTier ?? this.syllableTier,
        bpm: bpm ?? this.bpm,
        backedUp: backedUp ?? this.backedUp,
        parked: parked ?? this.parked,
      );

  /// Drop the session-scoped flags (call at the start of a new session).
  ProgressionState freshSession() => copyWith(backedUp: false, parked: false);

  @override
  bool operator ==(Object other) =>
      other is ProgressionState &&
      other.profileId == profileId &&
      other.phraseId == phraseId &&
      other.rung == rung &&
      other.syllableTier == syllableTier &&
      other.bpm == bpm &&
      other.backedUp == backedUp &&
      other.parked == parked;

  @override
  int get hashCode =>
      Object.hash(profileId, phraseId, rung, syllableTier, bpm, backedUp, parked);
}

/// What the fast loop did with one attempt (for transparency / logging / tests).
enum RungOutcome {
  /// Co-production rung (R0–R3): auto-proceeded one rung toward the judged rungs.
  autoProceeded,

  /// Caregiver Pass at a judged rung → moved up one rung.
  advanced,

  /// Caregiver Fail → tempo lowered one step first (still same rung).
  slowedTempo,

  /// Caregiver Fail at the slowest tempo → backed up one rung (restore support).
  backedUp,

  /// Caregiver Fail again after a back-up → parked for the rest of the session.
  parked,

  /// Unsure, or already parked → no change.
  held,
}

/// One fast-loop result: the new [state] and what [outcome] happened.
class ProgressionResult {
  const ProgressionResult(this.state, this.outcome);
  final ProgressionState state;
  final RungOutcome outcome;
}

/// Rules-based MIT progression controller (therapy addendum §4, Phase 3).
///
/// Driven ONLY by the caregiver's Pass/Fail/Unsure label — the ML model never
/// gates progression (it automates *judging* later, separately). Two loops on
/// two timescales:
///
/// **Fast loop** ([evaluateBlock], per 3-rep block) — rung movement. A word is
/// practiced exactly [repsPerBlock] consecutive reps at its current rung (always
/// all 3, no early exit, no mid-block change); the **block** is the progression
/// unit, evaluated only after the 3 reps:
///   - Pure co-production rungs (R0 receive-beat, R1 hum, R2 unison) aren't
///     Pass/Failed: the block just **auto-proceeds** one rung.
///   - At judged rungs — R3 (unison-fade, the first independent production) and
///     R4–R6 (repeat / delayed / solo): **≥2 Passes → up one rung**; **mostly
///     Fails (≥2) → lower the tempo first, then (at the floor) back up one rung**
///     (errorless restore-support); a **failed block at the backed-up rung →
///     park** the word for the session; **Unsure counts toward neither**. A
///     failed R3 therefore never forces R4 — it holds or backs up.
///
/// **Slow loop** ([shouldRaiseTier]/[raiseTier], across sessions) — tier movement:
///   - Raise the syllable tier ONLY when the pass rate is ≥ [tierPassRate] across
///     the last [tierWindow] sessions; raising the tier **resets the rung to full
///     support (unison)** — never raise load and drop support in the same move.
class MitProgression {
  const MitProgression({
    this.minBpm = 40,
    this.maxBpm = 70,
    this.tempoStep = 10,
    this.tierPassRate = 0.9,
    this.tierWindow = 5,
  });

  // Tempo bounds (therapy addendum §5: 40–70 BPM). [defaultBpm] is the tempo a
  // rung starts at; failing lowers it toward [minBpm] before backing up.
  static const defaultBpm = 60;
  final int minBpm;
  final int maxBpm;
  final int tempoStep;

  /// Reps in one fixed practice block — always run all of them, decide after.
  static const repsPerBlock = 3;

  // Slow-loop (tier) gate — tunable.
  final double tierPassRate;
  final int tierWindow;

  // Caregiver labels (2 = Unsure counts toward neither, so it isn't referenced).
  static const _fail = 0;
  static const _pass = 1;

  /// Whether a rung is Pass/Failed by the caregiver. R0 is the only un-judged
  /// rung — a tap-along exposure window that always promotes — so it auto-
  /// proceeds; judging (and so the 3-rep block) runs at R1–R6.
  bool isJudged(Rung rung) => rung.isJudged; // r1–r6

  /// Fast loop: fold one completed 3-rep **block** into the state. [labels] are
  /// the caregiver verdicts (0 Fail / 1 Pass / 2 Unsure) for the reps — normally
  /// [repsPerBlock] of them — ignored at co-production rungs. Decisions happen
  /// ONLY here (post-block), never mid-block. [rungCap] optionally limits how
  /// high the rung may go (a caregiver's "cap the rung for a low-energy session").
  ProgressionResult evaluateBlock(ProgressionState s, List<int> labels,
      {Rung? rungCap}) {
    if (s.parked) return ProgressionResult(s, RungOutcome.held);

    // Co-production rungs aren't judged — the block just proceeds toward the
    // judged rungs.
    if (!isJudged(s.rung)) {
      return ProgressionResult(
        s.copyWith(
            rung: _advance(s.rung, rungCap), bpm: defaultBpm, backedUp: false),
        RungOutcome.autoProceeded,
      );
    }

    final passes = labels.where((l) => l == _pass).length;
    final fails = labels.where((l) => l == _fail).length;

    // ≥2 Passes in the block → advance one rung.
    if (passes >= 2) {
      return ProgressionResult(
        s.copyWith(
            rung: _advance(s.rung, rungCap), bpm: defaultBpm, backedUp: false),
        RungOutcome.advanced,
      );
    }

    // Mostly Fails → lower the tempo first; at the floor back up one rung; a
    // failed block at the already-backed-up rung parks the word for the session.
    if (fails >= 2) {
      if (s.backedUp) {
        return ProgressionResult(s.copyWith(parked: true), RungOutcome.parked);
      }
      if (s.bpm > minBpm) {
        final slower = math.max(minBpm, s.bpm - tempoStep);
        return ProgressionResult(
            s.copyWith(bpm: slower), RungOutcome.slowedTempo);
      }
      return ProgressionResult(
        s.copyWith(rung: s.rung.lowered(), bpm: defaultBpm, backedUp: true),
        RungOutcome.backedUp,
      );
    }

    // Neither a clear pass nor a clear fail (e.g. mostly Unsure) → hold.
    return ProgressionResult(s, RungOutcome.held);
  }

  /// Defensive invariant (therapy: support must never punish success): a block
  /// whose caregiver verdicts are **pass-majority** must NEVER lower the rung.
  /// The fast loop already guarantees this, but the live wiring also folds in the
  /// slow-loop tier gate and reads state across two stores — this clamp makes a
  /// pass-block demotion impossible regardless of any upstream glitch. A genuine
  /// tier raise (which intentionally resets the rung to unison) is exempt.
  /// Returns [after] unchanged unless it would demote a pass-majority block.
  ProgressionState guardPassNeverDemotes(
      ProgressionState before, ProgressionState after, List<int> labels) {
    final passes = labels.where((l) => l == _pass).length;
    final fails = labels.where((l) => l == _fail).length;
    final tierRaised = after.syllableTier > before.syllableTier;
    if (!tierRaised && passes > fails && after.rung.level < before.rung.level) {
      return after.copyWith(rung: before.rung);
    }
    return after;
  }

  /// Slow loop (the MIT-grounded criterion): whether the word has earned a harder
  /// syllable tier — sustained mastery, not one good block. True only when its
  /// pass rate is ≥ [tierPassRate] (default 0.9) across the last [tierWindow]
  /// (default 5) sessions. [sessionPassRates] is the per-session pass-rate
  /// history at the word's TOP rung (R6 solo), oldest → newest — the caller
  /// supplies a top-rung-only history so tier load only rises after solo mastery.
  bool shouldRaiseTier(List<double> sessionPassRates) {
    if (sessionPassRates.length < tierWindow) return false;
    final window = sessionPassRates.sublist(sessionPassRates.length - tierWindow);
    final avg = window.reduce((a, b) => a + b) / window.length;
    return avg >= tierPassRate;
  }

  /// Apply a tier raise: +1 tier and RESET the rung to full support (unison) and
  /// the tempo to default — one dial at a time (never raise load and drop support
  /// together).
  ProgressionState raiseTier(ProgressionState s) => s.copyWith(
        syllableTier: s.syllableTier + 1,
        rung: supportForNewTier(), // R2
        bpm: defaultBpm,
        backedUp: false,
        parked: false,
      );

  // Advance one rung, clamped to [rungCap] when the caregiver capped the session.
  Rung _advance(Rung rung, Rung? cap) {
    final next = rung.raised();
    if (cap != null && next.index > cap.index) return cap;
    return next;
  }
}
