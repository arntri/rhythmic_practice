import 'dart:math' as math;

/// The MIT-style support/task ladder (therapy addendum §4), easiest → hardest.
///
/// **Tapping and humming are a session WARM-UP, not per-word rungs** (progression
/// refactor). R0 (feel/tap the beat) and R1 (hum) are general readiness skills run
/// once at the start of a session — they are NOT assigned to any word, so tapping
/// accuracy can never advance a word. The **active per-word ladder is r2..r6**
/// ([activeLadder]): unison → unison-with-fading → immediate repeat → delayed
/// repeat → solo. R7 (answer-the-question) is a **deferred** future top rung, OFF
/// by default and excluded from the active ladder (it overwhelms early patients).
/// The enum keeps all eight values (stable stored integers + the R7 scaffold);
/// membership is what changed.
enum Rung {
  /// R0 — WARM-UP ONLY: feel/tap the beat. No speech. Not a per-word rung.
  r0,

  /// R1 — WARM-UP ONLY: hum / voice to the beat. Sound, no words. Not a per-word
  /// rung.
  r1,

  /// R2 — intone the word in unison with the recorded model. The word ladder's
  /// entry (its floor).
  r2,

  /// R3 — unison with the model fading out partway.
  r3,

  /// R4 — listen, then repeat after the model.
  r4,

  /// R5 — listen, pause, then repeat (delayed).
  r5,

  /// R6 — produce on own (prompt only); tap + speak solo.
  r6,

  /// R7 — DEFERRED (off by default, not in [activeLadder]): response to a
  /// question — the app plays a probe question and the user answers with the
  /// phrase, solo. Scaffolded as a future top rung; the active ladder tops out at
  /// R6 because responding-to-a-question overwhelms early patients and no
  /// near-term user reaches it.
  r7,
}

extension RungInfo on Rung {
  /// 0..6 difficulty order.
  int get level => index;

  /// Short code, e.g. 'R2'.
  String get code => 'R$index';

  String get title => switch (this) {
        Rung.r0 => 'Feel the beat', // warm-up
        Rung.r1 => 'Hum along', // warm-up
        Rung.r2 => 'Say it together',
        Rung.r3 => 'Together, model fades',
        Rung.r4 => 'Repeat after the model',
        Rung.r5 => 'Delayed repeat',
        Rung.r6 => 'Say it on your own',
        Rung.r7 => 'Answer the question',
      };

  String get description => switch (this) {
        Rung.r0 => 'Just feel the beat — tap if you like. No speaking yet.',
        Rung.r1 => 'Hum or voice along to the beat. Sound, not words.',
        Rung.r2 => 'Say the word at the same time as the recording.',
        Rung.r3 => 'Start together; the recording fades so you carry it.',
        Rung.r4 => 'Listen to the recording, then say it back.',
        Rung.r5 => 'Listen, pause a moment, then say it.',
        Rung.r6 => 'Say it on your own — just the prompt, no model.',
        Rung.r7 => 'Hear a question and answer it with the word — no model.',
      };

  /// Whether the recorded model plays at this rung (r0/r1 have no model; r6 is
  /// solo, so also none).
  bool get playsModel =>
      this == Rung.r2 ||
      this == Rung.r3 ||
      this == Rung.r4 ||
      this == Rung.r5;

  /// Whether the model keeps playing while the user produces (unison rungs).
  bool get isUnison => this == Rung.r2 || this == Rung.r3;

  /// Whether the user is expected to produce the actual word (vs beat-only/hum).
  bool get expectsWord => index >= Rung.r2.index;

  /// Whether the caregiver judges (Pass/Fail/Unsure) this rung. Every **word**
  /// rung is judged: the ungraded exposure (tap/hum) now lives in the session
  /// warm-up (r0/r1), so judging spans the whole word ladder — r2 unison (said the
  /// word with the app) → r3 fade (carried the faded part) → r4–r6 solo. r0/r1 are
  /// warm-up (never words, never judged).
  bool get isJudged => index >= Rung.r2.index;

  /// Whether capture yields a clean solo production worth scoring against the
  /// guide. Unison rungs (r2/r3) are contaminated by the model playing aloud, and
  /// r0/r1 aren't the word — so only r4–r7 are recorded/scored. (R3 is judged but
  /// NOT recorded — the caregiver watches the faded part rather than the mic.)
  bool get cleanCapture =>
      this == Rung.r4 ||
      this == Rung.r5 ||
      this == Rung.r6 ||
      this == Rung.r7;

  /// One step harder (clamped at the enum top). Prefer [raisedActive] for word
  /// progression, which stops at the active top R6.
  Rung raised() => Rung.values[math.min(index + 1, Rung.values.length - 1)];

  /// One step easier (clamped at the enum bottom). Prefer [loweredActive] for word
  /// progression, which stops at the active floor R2.
  Rung lowered() => Rung.values[math.max(index - 1, 0)];

  /// One step harder WITHIN the active word ladder — clamped at the active top
  /// [topRung] (R6), never into the deferred R7.
  Rung raisedActive() => Rung.values[math.min(index + 1, topRung.index)];

  /// One step easier WITHIN the active word ladder — clamped at the active floor
  /// [entryRung] (R2); r0/r1 are warm-up, not word rungs to fall back to.
  Rung loweredActive() => Rung.values[math.max(index - 1, entryRung.index)];
}

/// Decode a stored rung level, clamped to the valid range.
Rung rungFromLevel(int level) =>
    Rung.values[level.clamp(0, Rung.values.length - 1)];

/// The active per-word ladder, easiest → hardest (progression refactor): unison →
/// unison-with-fading → immediate repeat → delayed repeat → solo. R0/R1 are the
/// session warm-up and R7 is deferred, so both sit OUTSIDE this list. UI that
/// enumerates word rungs (manual rung control, demo picker) iterates this.
const List<Rung> activeLadder = [
  Rung.r2,
  Rung.r3,
  Rung.r4,
  Rung.r5,
  Rung.r6,
];

/// Where every word's ladder STARTS — unison (R2), its floor. Tapping/humming are
/// the warm-up, so a word never enters below unison.
Rung get entryRung => Rung.r2;

/// The active top of the ladder (hardest reachable step) — **R6 (solo)**. R7 is a
/// deferred future top rung (off by default), so the tier-gate and manual-rung
/// code stop here. A single source so those callers don't hard-code a rung.
Rung get topRung => Rung.r6;

/// The three MIT difficulty levels (audit item 12), capped at [maxLevel]. The
/// slow-loop tier gate never raises load past this.
const int maxLevel = 3;

/// Classify a phrase into its MIT level by **syllable count** (audit item 12):
/// L1 = 1–3 syllables, L2 = 4–6, L3 = 7+. This is the phrase's starting
/// linguistic-load level, seeded from its confirmed syllable count; the tier gate
/// can raise it (up to [maxLevel]) after sustained top-rung mastery. A count of 0
/// (phrase typed but no guide recorded yet) reads as L1 until a guide sets the
/// real count.
int levelForSyllableCount(int syllableCount) =>
    syllableCount <= 3 ? 1 : (syllableCount <= 6 ? 2 : 3);

/// The rung a phrase enters the ladder at. **Every word now starts at unison
/// ([entryRung] = R2)** regardless of level (progression refactor: "each word's
/// ladder starts at unison" supersedes the earlier level→entry-rung skip). The
/// level still governs the slow-loop tier gate (linguistic load) and starter-word
/// seeding — it just no longer changes where a word enters the support ladder.
Rung entryRungForLevel(int level) => entryRung;

/// Support to use when the linguistic load increases (more syllables): reset to
/// unison (the grid rule, therapy addendum §4 — never raise load AND drop
/// support in the same move).
Rung supportForNewTier() => Rung.r2;

/// The level at/above which a phrase needs a Sprechgesang (slow-spoken) clip
/// before it can be used (audit item 15) — Level 3, the speech-song bridge.
const int sprechgesangLevel = 3;

/// Whether a phrase at [level] is allowed to run given whether it has a
/// caregiver-recorded slow-spoken clip (audit item 15, scaffold). Levels 1–2 are
/// always fine; **Level 3 is unavailable until a Sprechgesang clip exists**. This
/// is the hook that keeps the auto-progression tier gate from pushing a word into
/// L3 before the caregiver has recorded the clip it needs.
bool sprechgesangSatisfied(
        {required int level, required bool hasSprechgesangClip}) =>
    level < sprechgesangLevel || hasSprechgesangClip;
