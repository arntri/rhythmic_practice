// Plain data classes that mirror the SQLite tables.
//
// These are deliberately simple "value objects": they just hold the fields of a
// row, with no logic. Each has a `fromMap` constructor that builds the object
// from a raw database row (sqflite returns each row as a `Map<String, Object?>`).
//
// SQLite has no real boolean type, so on-disk we store 0 / 1 integers. We
// convert those to real Dart `bool`s here so the rest of the app reads nicely.

import 'dart:typed_data';

import '../practice/progression.dart';

/// One row of the `practice_phrases` table: a phrase the user practices saying.
class PracticePhrase {
  final int phraseId;
  final String phraseText;
  final int wordCount;
  final int syllableCount;

  /// 1 = single syllable, 2 = two-syllable, 3 = short phrase.
  final int complexityLevel;

  /// Path to a bundled intoned audio clip for the guide. Rarely used now that the
  /// primary guide is a caregiver recording (see [guideClipPath]).
  final String? audioAssetPath;

  /// AES-encrypted, caregiver-recorded guide clip for this phrase (also its DTW
  /// reference). Null until the caregiver records one; when null the practice
  /// guide falls back to TTS.
  final String? guideClipPath;

  /// Confirmed syllable-nucleus timestamps (ms) for the recorded guide, used to
  /// place metronome beats on the actual syllables. Empty until a guide is
  /// recorded + confirmed.
  final List<int> guideNucleiMs;

  /// The MIT support/task ladder rung (therapy addendum §4) the caregiver has
  /// this phrase on. Defaults to unison (R2).
  final Rung rung;

  /// Path to an AES-encrypted photo for a "name card" (therapy addendum §6 —
  /// photo + recorded name). Null for an ordinary word/phrase.
  final String? photoPath;

  /// The R7 probe question (audit item 11): the intoned/spoken question the app
  /// plays for the user to answer with [phraseText], solo, at the top rung. Null
  /// until the caregiver sets one — R7 then degrades to a gentle generic prompt.
  final String? probeQuestionText;

  /// AES-encrypted recorded probe question for R7. Null → the guide falls back to
  /// TTS of [probeQuestionText] (or, absent that, a gentle generic prompt).
  final String? probeQuestionClipPath;

  /// The caregiver-designated syllable that carries the HIGH note (intonation
  /// flow, item A) — 0-based index into the confirmed syllables. Null until a
  /// guide with a confirmed contour is recorded. Drives the reference demo, the
  /// mis-stress check, and the on-screen melody cue.
  final int? stressIndex;

  /// AES-encrypted, caregiver-recorded **slow-spoken (Sprechgesang) clip** (audit
  /// item 15, scaffold): the speech-song bridge between full intonation and normal
  /// speech used at Level 3. Null until recorded — while null, a phrase cannot use
  /// its L3 flow ([sprechgesangSatisfied]).
  final String? sprechgesangClipPath;

  /// Whether this phrase is included in practice sessions. The caregiver can
  /// toggle phrases on/off from the settings portal later.
  final bool isActive;

  /// True for a bundled **starter-library** phrase (Part 3). Presentation-only —
  /// it exempts the guide clip from mention in eviction and deprioritizes the
  /// phrase below the caregiver's own words; it MUST NOT affect rungs, judging,
  /// or any progression decision.
  final bool isStarter;

  const PracticePhrase({
    required this.phraseId,
    required this.phraseText,
    required this.wordCount,
    required this.syllableCount,
    required this.complexityLevel,
    required this.audioAssetPath,
    this.guideClipPath,
    this.guideNucleiMs = const [],
    this.rung = Rung.r2,
    this.photoPath,
    this.probeQuestionText,
    this.probeQuestionClipPath,
    this.stressIndex,
    this.sprechgesangClipPath,
    required this.isActive,
    this.isStarter = false,
  });

  /// True once a recorded guide exists for this phrase.
  bool get hasRecordedGuide => guideClipPath != null;

  /// True once a slow-spoken Sprechgesang clip exists (audit item 15).
  bool get hasSprechgesangClip => sprechgesangClipPath != null;

  /// True when this is a name card with a photo attached.
  bool get hasPhoto => photoPath != null;

  factory PracticePhrase.fromMap(Map<String, Object?> row) {
    final nucleiCsv = row['guide_nuclei_ms'] as String?;
    return PracticePhrase(
      phraseId: row['phrase_id'] as int,
      phraseText: row['phrase_text'] as String,
      wordCount: row['word_count'] as int,
      syllableCount: row['syllable_count'] as int,
      complexityLevel: row['complexity_level'] as int,
      audioAssetPath: row['audio_asset_path'] as String?,
      guideClipPath: row['guide_clip_path'] as String?,
      guideNucleiMs: (nucleiCsv == null || nucleiCsv.isEmpty)
          ? const []
          : nucleiCsv.split(',').map(int.parse).toList(),
      rung: rungFromLevel((row['current_rung'] as int?) ?? 2),
      photoPath: row['photo_path'] as String?,
      probeQuestionText: row['probe_question_text'] as String?,
      probeQuestionClipPath: row['probe_question_clip_path'] as String?,
      stressIndex: row['stress_index'] as int?,
      sprechgesangClipPath: row['sprechgesang_clip_path'] as String?,
      isActive: (row['is_active'] as int) == 1,
      isStarter: (row['is_starter'] as int? ?? 0) == 1,
    );
  }
}

/// Aggregated practice stats for one phrase (history view). Computed from
/// recorded attempts — all final, non-audio data.
class PhraseStat {
  final int phraseId;
  final String phraseText;
  final int complexityLevel;
  final int attempts;
  final int passes;
  final int fails;
  final int unsure;
  final double? avgSyncScore; // 0..1, null if no scored taps

  const PhraseStat({
    required this.phraseId,
    required this.phraseText,
    required this.complexityLevel,
    required this.attempts,
    required this.passes,
    required this.fails,
    required this.unsure,
    required this.avgSyncScore,
  });

  /// Fraction of attempts marked Pass (0..1).
  double get passRate => attempts == 0 ? 0 : passes / attempts;
}

/// A single past session's summary (history view).
class SessionSummary {
  final String sessionId;
  final String startedAt;
  final int attempts;
  final int passes;

  const SessionSummary({
    required this.sessionId,
    required this.startedAt,
    required this.attempts,
    required this.passes,
  });
}

/// One row of the `exercise_attempts` table: a single recorded attempt at a
/// phrase, with its metrics and the caregiver's verdict.
class ExerciseAttempt {
  final String attemptId;
  final String sessionId;
  final int phraseId;
  final String timestamp;

  /// Gap from guide-end to first vocalization. Null until the mic (Step 5) fills
  /// it in.
  final int? latencyMs;

  /// Length of the user's vocalization. Null until the mic (Step 5) fills it in.
  final int? durationMs;

  /// 0.0..1.0 tap-vs-beat synchronization score; null if there were no taps.
  final double? tappingSynchronizationScore;

  /// 0 = Fail, 1 = Pass, 2 = Unsure (default 2 if unanswered).
  final int evaluationLabel;

  /// Path to the encrypted audio clip; null once wiped by the 48h eviction job
  /// (Step 8), or until the mic (Step 5) records one.
  final String? localEncryptedAudioPath;

  /// MIT rung this attempt was produced at (0–7); null pre-v8. Context for the
  /// Layer C feature assembly (audit item 18).
  final int? rungAtAttempt;

  /// Syllable tier at attempt time; null pre-v16.
  final int? tierAtAttempt;

  /// Metronome tempo (BPM) this attempt was produced at; null pre-v20.
  final int? tempoBpm;

  const ExerciseAttempt({
    required this.attemptId,
    required this.sessionId,
    required this.phraseId,
    required this.timestamp,
    required this.latencyMs,
    required this.durationMs,
    required this.tappingSynchronizationScore,
    required this.evaluationLabel,
    required this.localEncryptedAudioPath,
    this.rungAtAttempt,
    this.tierAtAttempt,
    this.tempoBpm,
  });

  factory ExerciseAttempt.fromMap(Map<String, Object?> row) {
    return ExerciseAttempt(
      attemptId: row['attempt_id'] as String,
      sessionId: row['session_id'] as String,
      phraseId: row['phrase_id'] as int,
      timestamp: row['timestamp'] as String,
      latencyMs: row['latency_ms'] as int?,
      durationMs: row['duration_ms'] as int?,
      tappingSynchronizationScore:
          (row['tapping_synchronization_score'] as num?)?.toDouble(),
      evaluationLabel: row['evaluation_label'] as int,
      localEncryptedAudioPath: row['local_encrypted_audio_path'] as String?,
      rungAtAttempt: row['rung_at_attempt'] as int?,
      tierAtAttempt: row['tier_at_attempt'] as int?,
      tempoBpm: row['tempo_bpm'] as int?,
    );
  }
}

/// How the practice target is shown on screen (therapy: audio is always the
/// primary cue; this controls the supporting *visual*). [picture] leans on the
/// caregiver-attached photo (most accessible, language-agnostic); [word] shows
/// the written text; [both] shows the picture with the word beneath.
enum TargetDisplay {
  picture,
  word,
  both;

  static TargetDisplay fromName(String? name) => TargetDisplay.values.firstWhere(
        (t) => t.name == name,
        orElse: () => TargetDisplay.picture,
      );
}

/// One row of the `daily_summary` table: a per-(profile, day) metrics rollup for
/// the family dashboard + cloud sync. Display-only — never audio.
class DailySummary {
  final String profileId;

  /// The day, 'YYYY-MM-DD' (UTC).
  final String day;
  final int attempts;
  final int passes;
  final int fails;
  final int unsure;

  /// Average content-similarity (0..1) for the day, or null if nothing scored.
  final double? avgSimilarity;

  const DailySummary({
    required this.profileId,
    required this.day,
    required this.attempts,
    required this.passes,
    required this.fails,
    required this.unsure,
    required this.avgSimilarity,
  });

  /// Fraction of the day's attempts marked Pass (0..1).
  double get passRate => attempts == 0 ? 0 : passes / attempts;

  factory DailySummary.fromMap(Map<String, Object?> row) => DailySummary(
        profileId: row['profile_id'] as String,
        day: row['day'] as String,
        attempts: row['attempts'] as int,
        passes: row['passes'] as int,
        fails: row['fails'] as int,
        unsure: row['unsure'] as int,
        avgSimilarity: (row['avg_similarity'] as num?)?.toDouble(),
      );
}

/// One row of the `user_profiles` table: the single local user's preferences.
/// For this personal prototype there is exactly one profile.
class UserProfile {
  final String profileId;
  final int metronomeBpm;

  /// 'LEFT' or 'RIGHT' — which hand the user taps with.
  final String preferredHand;

  // Each sensory channel of the metronome can be toggled independently.
  final bool visualEnabled;
  final bool soundEnabled;
  final bool hapticEnabled;

  /// How many phrases make up one session.
  final int sessionPhraseLimit;

  /// Consent flag (brief §6 Privacy). Defaults to false until granted. This
  /// becomes a real gate before any data is uploaded once cloud sync is added.
  final bool guardianConsentGranted;

  /// Recording window for a practice attempt: how long of silence (after the
  /// user speaks) before capture auto-closes. Caregiver-adjustable 3000–8000 ms.
  final int captureSilenceMs;

  /// Whether the Phase 3 auto-progression engine may move phrases' rungs on
  /// confirmed success/failure. When off, only the caregiver changes rungs.
  final bool autoProgressEnabled;

  /// Whether the first-run caregiver instructions have been shown.
  final bool onboardingSeen;

  /// How the practice target's visual is shown (audio is always primary).
  final TargetDisplay targetDisplay;

  /// Caregiver guide-speed multiplier (1.0 = normal, 0.75, 0.5 …). Lower makes
  /// the spoken word come out slower (more elongation).
  final double playbackSpeed;

  /// Caregiver "comfort cap" for low-energy days: the highest rung level (0–6)
  /// the auto-progression may push a phrase to, or null for no cap. It only
  /// limits *advancement* — it never demotes a phrase already above it — so it
  /// can't trap the user lower. Cleared (back to null) when the caregiver lifts
  /// the cap.
  final int? sessionRungCap;

  /// Presenter "demo mode": when on, the practice screen shows an in-session
  /// level picker so a live demo can jump the current word to any rung on demand.
  /// Off by default; it only affects the in-session rung, never the stored
  /// progression — so demonstrating can't disturb real therapy history.
  final bool demoModeEnabled;

  /// Scoped solo practice (audit item 19, scaffold). Off by default. Even when
  /// on, solo mode is advisory-only — the ML never gates progression until the
  /// Layer C classifier graduates (which it can't until a model is trained).
  final bool soloModeEnabled;

  const UserProfile({
    required this.profileId,
    required this.metronomeBpm,
    required this.preferredHand,
    required this.visualEnabled,
    required this.soundEnabled,
    required this.hapticEnabled,
    required this.sessionPhraseLimit,
    required this.guardianConsentGranted,
    this.captureSilenceMs = 4500,
    this.autoProgressEnabled = true,
    this.onboardingSeen = false,
    this.targetDisplay = TargetDisplay.picture,
    this.playbackSpeed = 1.0,
    this.sessionRungCap,
    this.demoModeEnabled = false,
    this.soloModeEnabled = false,
  });

  factory UserProfile.fromMap(Map<String, Object?> row) {
    return UserProfile(
      profileId: row['profile_id'] as String,
      metronomeBpm: row['metronome_bpm'] as int,
      preferredHand: row['preferred_hand'] as String,
      visualEnabled: (row['visual_enabled'] as int) == 1,
      soundEnabled: (row['sound_enabled'] as int) == 1,
      hapticEnabled: (row['haptic_enabled'] as int) == 1,
      sessionPhraseLimit: row['session_phrase_limit'] as int,
      guardianConsentGranted: (row['guardian_consent_granted'] as int) == 1,
      captureSilenceMs: (row['capture_silence_ms'] as int?) ?? 4500,
      autoProgressEnabled: ((row['auto_progress_enabled'] as int?) ?? 1) == 1,
      onboardingSeen: ((row['onboarding_seen'] as int?) ?? 0) == 1,
      targetDisplay: TargetDisplay.fromName(row['target_display'] as String?),
      playbackSpeed: (row['playback_speed'] as num?)?.toDouble() ?? 1.0,
      sessionRungCap: row['session_rung_cap'] as int?,
      demoModeEnabled: ((row['demo_mode_enabled'] as int?) ?? 0) == 1,
      soloModeEnabled: ((row['solo_mode_enabled'] as int?) ?? 0) == 1,
    );
  }
}

/// One row of `acoustic_feature_vectors` (Phase 2A §5): the analysis output for
/// a single attempt. [contentSimilarityScore] is null when the junk gate
/// rejected the clip.
class FeatureVector {
  final String vectorId;
  final String attemptId;
  final double? contentSimilarityScore;

  /// Raw normalized DTW cost behind [contentSimilarityScore] (item 16b); null
  /// when the gate rejected the clip or no template existed.
  final double? mfccDistance;

  final bool gatePassed;
  final String? gateReason;
  final int? durationMs;

  /// The patient's own detected syllable onsets (ms from clip start) for this
  /// attempt (item 16c) — the material for onset-vs-beat vocal steadiness, kept
  /// past audio eviction. Empty when none were detected.
  final List<int> onsetMs;

  const FeatureVector({
    required this.vectorId,
    required this.attemptId,
    required this.contentSimilarityScore,
    required this.mfccDistance,
    required this.gatePassed,
    required this.gateReason,
    required this.durationMs,
    this.onsetMs = const [],
  });

  factory FeatureVector.fromMap(Map<String, Object?> row) {
    final onsetCsv = row['onset_ms'] as String?;
    return FeatureVector(
      vectorId: row['vector_id'] as String,
      attemptId: row['attempt_id'] as String,
      contentSimilarityScore:
          (row['content_similarity_score'] as num?)?.toDouble(),
      mfccDistance: (row['mfcc_distance'] as num?)?.toDouble(),
      gatePassed: (row['gate_passed'] as int) == 1,
      gateReason: row['gate_reason'] as String?,
      durationMs: row['duration_ms'] as int?,
      onsetMs: (onsetCsv == null || onsetCsv.isEmpty)
          ? const []
          : onsetCsv.split(',').map(int.parse).toList(),
    );
  }
}

/// One row of `phrase_anchor_templates` (Phase 2A §4): the caregiver-confirmed
/// MFCC template a phrase's similarity is scored against once it exists. The
/// [mfcc] sequence is already decoded from the stored BLOB.
class AnchorTemplate {
  final String anchorId;
  final String profileId;
  final int phraseId;

  /// Decoded MFCC sequence (frames × coeffs) — derived features, never raw audio.
  final List<Float64List> mfcc;

  /// This template's similarity vs the bundled reference at promotion time. A
  /// later confirmed attempt must beat this to replace the anchor.
  final double? scoreVsReference;

  final String? sourceAttemptId;
  final String confirmedAt;

  const AnchorTemplate({
    required this.anchorId,
    required this.profileId,
    required this.phraseId,
    required this.mfcc,
    required this.scoreVsReference,
    required this.sourceAttemptId,
    required this.confirmedAt,
  });
}

/// One stored row of `tap_events` (ML logging audit item 16a): a single raw tap,
/// tied to the attempt/phrase/rung it was made at. [downMs] is the monotonic
/// touch-down time (ms since the session's controller started), [dwellMs] the
/// press duration (null if the finger-up was never observed), [beatPhase] the
/// metronome phase at touch-down. The read side for the fatigue detector and
/// tests; the write side takes the controller's lightweight `TapEvent`.
class StoredTapEvent {
  final String tapId;
  final String attemptId;
  final int phraseId;
  final String sessionId;
  final int rung;
  final int tapIndex;
  final int downMs;
  final int? dwellMs;
  final double? beatPhase;

  const StoredTapEvent({
    required this.tapId,
    required this.attemptId,
    required this.phraseId,
    required this.sessionId,
    required this.rung,
    required this.tapIndex,
    required this.downMs,
    required this.dwellMs,
    required this.beatPhase,
  });

  factory StoredTapEvent.fromMap(Map<String, Object?> row) => StoredTapEvent(
        tapId: row['tap_id'] as String,
        attemptId: row['attempt_id'] as String,
        phraseId: row['phrase_id'] as int,
        sessionId: row['session_id'] as String,
        rung: row['rung'] as int,
        tapIndex: row['tap_index'] as int,
        downMs: row['down_ms'] as int,
        dwellMs: row['dwell_ms'] as int?,
        beatPhase: (row['beat_phase'] as num?)?.toDouble(),
      );
}
