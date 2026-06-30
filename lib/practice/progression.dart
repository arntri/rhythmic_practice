import 'dart:math' as math;

/// The MIT-style support/task ladder (therapy addendum §4), easiest → hardest.
/// Each rung combines how much support the model gives with how much the user
/// must produce. The caregiver sets a rung per phrase and eases/regresses it;
/// the auto-progression engine (Phase 3) will move it later.
enum Rung {
  /// R0 — receive the beat; optional tap. No speech.
  r0,

  /// R1 — hum / voice to the beat. Sound, no words.
  r1,

  /// R2 — intone the word in unison with the recorded model.
  r2,

  /// R3 — unison with the model fading out partway.
  r3,

  /// R4 — listen, then repeat after the model.
  r4,

  /// R5 — listen, pause, then repeat (delayed).
  r5,

  /// R6 — produce on own (prompt only); tap + speak solo is the top.
  r6,
}

extension RungInfo on Rung {
  /// 0..6 difficulty order.
  int get level => index;

  /// Short code, e.g. 'R2'.
  String get code => 'R$index';

  String get title => switch (this) {
        Rung.r0 => 'Receive the beat',
        Rung.r1 => 'Hum to the beat',
        Rung.r2 => 'Say it together',
        Rung.r3 => 'Together, model fades',
        Rung.r4 => 'Repeat after the model',
        Rung.r5 => 'Delayed repeat',
        Rung.r6 => 'Say it on your own',
      };

  String get description => switch (this) {
        Rung.r0 => 'Just feel the beat — tap if you like. No speaking yet.',
        Rung.r1 => 'Hum or voice along to the beat. Sound, not words.',
        Rung.r2 => 'Say the word at the same time as the recording.',
        Rung.r3 => 'Start together; the recording fades so you carry it.',
        Rung.r4 => 'Listen to the recording, then say it back.',
        Rung.r5 => 'Listen, pause a moment, then say it.',
        Rung.r6 => 'Say it on your own — just the prompt, no model.',
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

  /// Whether the caregiver judges (Pass/Fail/Unsure) this rung. R0 is the ONLY
  /// un-judged rung: it's a tap-along exposure window that always promotes (the
  /// no-trap floor), so it has no verdict. Judging starts at R1 and the bar gets
  /// stricter as support drops: R1 participation (hum along) → R2 unison (said the
  /// word with the app) → R3 fade (carried the faded part) → R4–R6 solo.
  bool get isJudged => index >= Rung.r1.index;

  /// Whether capture yields a clean solo production worth scoring against the
  /// guide. Unison rungs (r2/r3) are contaminated by the model playing aloud, and
  /// r0/r1 aren't the word — so only r4–r6 are recorded/scored. (R3 is judged but
  /// NOT recorded — the caregiver watches the faded part rather than the mic.)
  bool get cleanCapture =>
      this == Rung.r4 || this == Rung.r5 || this == Rung.r6;

  /// One step harder (clamped at the top).
  Rung raised() => Rung.values[math.min(index + 1, Rung.values.length - 1)];

  /// One step easier (clamped at the bottom).
  Rung lowered() => Rung.values[math.max(index - 1, 0)];
}

/// Decode a stored rung level, clamped to the valid range.
Rung rungFromLevel(int level) =>
    Rung.values[level.clamp(0, Rung.values.length - 1)];

/// Support to use when the linguistic load increases (more syllables): reset to
/// unison (the grid rule, therapy addendum §4 — never raise load AND drop
/// support in the same move).
Rung supportForNewTier() => Rung.r2;
