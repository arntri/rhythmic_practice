import 'dart:typed_data';

import 'package:sqflite/sqflite.dart';
import 'package:uuid/uuid.dart';

import '../analysis/attempt_analyzer.dart';
import '../analysis/mfcc_codec.dart';
import '../practice/practice_controller.dart' show TapEvent;
import '../practice/mit_sequence.dart';
import '../practice/syllable_estimate.dart';
import 'app_database.dart';
import 'models.dart';

/// The thin data-access layer the rest of the app talks to.
///
/// The UI never touches SQL directly — it calls these named methods, which
/// return clean Dart objects ([UserProfile], [PracticePhrase]). Keeping all the
/// queries in one small place makes them easy to find and change later (and is
/// where the cloud-sync hooks will slot in when we add Supabase).
class PracticeRepository {
  final AppDatabase _appDb;
  final Database? _explicitDb;
  static const _uuid = Uuid();

  PracticeRepository([AppDatabase? appDb])
      : _appDb = appDb ?? AppDatabase.instance,
        _explicitDb = null;

  /// For tests: build a repository against an already-open database (e.g. an
  /// in-memory one), bypassing the file/path_provider setup.
  PracticeRepository.withDatabase(Database db)
      : _appDb = AppDatabase.instance,
        _explicitDb = db;

  Future<Database> get _db async => _explicitDb ?? await _appDb.database;

  // --- Profile -------------------------------------------------------------

  /// Returns the single local user profile, creating it if somehow missing.
  Future<UserProfile> getProfile() async {
    final db = await _db;
    final rows = await db.query(
      'user_profiles',
      where: 'profile_id = ?',
      whereArgs: [AppDatabase.defaultProfileId],
      limit: 1,
    );
    return UserProfile.fromMap(rows.first);
  }

  /// Version tag stored alongside a consent grant, so we know which consent
  /// wording the user agreed to.
  static const consentSchemaVersion = 'phase1-v1';

  /// Updates the single profile's settings. Only the named fields you pass are
  /// changed. Granting consent also stamps the time + schema version.
  Future<void> updateProfile({
    int? metronomeBpm,
    bool? visualEnabled,
    bool? soundEnabled,
    bool? hapticEnabled,
    int? sessionPhraseLimit,
    bool? guardianConsentGranted,
    int? captureSilenceMs,
    bool? autoProgressEnabled,
    bool? onboardingSeen,
    TargetDisplay? targetDisplay,
    double? playbackSpeed,
    MitLevel? mitLevel,
    int? practiceTargetMinutes,
    bool? demoModeEnabled,
    bool? soloModeEnabled,
  }) async {
    final db = await _db;
    final values = <String, Object?>{
      'metronome_bpm': ?metronomeBpm,
      if (visualEnabled != null) 'visual_enabled': visualEnabled ? 1 : 0,
      if (soundEnabled != null) 'sound_enabled': soundEnabled ? 1 : 0,
      if (hapticEnabled != null) 'haptic_enabled': hapticEnabled ? 1 : 0,
      'session_phrase_limit': ?sessionPhraseLimit,
      'capture_silence_ms': ?captureSilenceMs,
      if (autoProgressEnabled != null)
        'auto_progress_enabled': autoProgressEnabled ? 1 : 0,
      if (onboardingSeen != null) 'onboarding_seen': onboardingSeen ? 1 : 0,
      if (targetDisplay != null) 'target_display': targetDisplay.name,
      'playback_speed': ?playbackSpeed,
      if (mitLevel != null) 'mit_level': mitLevel.index,
      'practice_target_minutes': ?practiceTargetMinutes,
      if (demoModeEnabled != null)
        'demo_mode_enabled': demoModeEnabled ? 1 : 0,
      if (soloModeEnabled != null)
        'solo_mode_enabled': soloModeEnabled ? 1 : 0,
      if (guardianConsentGranted != null)
        'guardian_consent_granted': guardianConsentGranted ? 1 : 0,
      // Record when/what was consented to, only when granting.
      if (guardianConsentGranted == true) ...{
        'consent_timestamp': DateTime.now().toIso8601String(),
        'consent_schema_version': consentSchemaVersion,
      },
    };
    if (values.isEmpty) return;
    await db.update(
      'user_profiles',
      values,
      where: 'profile_id = ?',
      whereArgs: [AppDatabase.defaultProfileId],
    );
  }

  // --- Phrases -------------------------------------------------------------

  /// Records a caregiver-recorded guide clip for a phrase: the encrypted file
  /// path (which doubles as the DTW reference), the caregiver-confirmed
  /// [syllableCount], the confirmed syllable-nucleus timings [nucleiMs] (therapy
  /// addendum §2 — detection pre-fills, the caregiver confirms), and the
  /// caregiver-designated high-note [stressIndex] (intonation flow, item A).
  /// [stressIndex] is written only when provided, so re-saving a clip without it
  /// leaves an existing contour choice intact.
  Future<void> setGuideClip(
    int phraseId,
    String guideClipPath,
    int syllableCount, {
    List<int> nucleiMs = const [],
    int? stressIndex,
  }) async {
    final db = await _db;
    // Confirming a guide no longer touches progression. Under the old ladder
    // this set the word's entry rung from its syllable count; a word has no
    // resting rung now — every item runs its level's whole sequence — so there
    // is nothing here to seed.
    await db.update(
      'practice_phrases',
      {
        'guide_clip_path': guideClipPath,
        'syllable_count': syllableCount,
        'guide_nuclei_ms': nucleiMs.join(','),
        'stress_index': ?stressIndex, // written only when provided (null skips)
      },
      where: 'phrase_id = ?',
      whereArgs: [phraseId],
    );
  }

  /// The encrypted guide-clip path for a phrase, or null if none recorded yet
  /// (the practice guide then falls back to TTS).
  Future<String?> getGuideClip(int phraseId) async {
    final db = await _db;
    final rows = await db.query(
      'practice_phrases',
      columns: ['guide_clip_path'],
      where: 'phrase_id = ?',
      whereArgs: [phraseId],
      limit: 1,
    );
    return rows.isEmpty ? null : rows.first['guide_clip_path'] as String?;
  }

  /// Active phrases that still need a recorded guide — drives onboarding and the
  /// "record guides" list (therapy addendum §2).
  Future<List<PracticePhrase>> getPhrasesNeedingGuide() async {
    final db = await _db;
    final rows = await db.query(
      'practice_phrases',
      where: 'guide_clip_path IS NULL AND is_active = 1',
      orderBy: 'complexity_level ASC, phrase_text ASC',
    );
    return rows.map(PracticePhrase.fromMap).toList();
  }

  /// Adds a custom phrase in any language/script (therapy addendum §3). Word
  /// count is derived from whitespace; `syllable_count` stays 0 until a guide is
  /// recorded, when it's set from the beat count (§2). `complexity_level` is a
  /// rough seed (1 for a single word, else 3). Returns the new phrase id.
  Future<int> addPhrase(String text) async {
    final db = await _db;
    final trimmed = text.trim();
    final wordCount = trimmed.isEmpty ? 0 : trimmed.split(RegExp(r'\s+')).length;
    // A first ESTIMATE of the syllable count, so a new phrase has a sensible
    // length band and a melody to hum from the moment it is added. It used to
    // sit at 0 until a guide was recorded, which meant a caregiver's own phrase
    // hummed as a single note however long it was. The authored guide still
    // overwrites this with the real count when it arrives.
    final syllables = estimateSyllables(trimmed);
    return db.insert('practice_phrases', {
      'phrase_text': trimmed,
      'word_count': wordCount,
      'syllable_count': syllables,
      'complexity_level': lengthBand(syllables),
      'is_active': 1,
    });
  }

  /// Attaches (or, with null, removes) an AES-encrypted photo for a name card
  /// (therapy addendum §6). [encryptedPhotoPath] is the stored encrypted file.
  Future<void> setPhoto(int phraseId, String? encryptedPhotoPath) async {
    final db = await _db;
    await db.update(
      'practice_phrases',
      {'photo_path': encryptedPhotoPath},
      where: 'phrase_id = ?',
      whereArgs: [phraseId],
    );
  }

  /// Set (or clear, with nulls) the R7 probe question for a phrase (audit item
  /// 11): the [text] the user answers with the phrase, and an optional recorded
  /// [clipPath] (AES-encrypted) played instead of TTS of the text.
  Future<void> setProbeQuestion(int phraseId,
      {String? text, String? clipPath}) async {
    final db = await _db;
    await db.update(
      'practice_phrases',
      {'probe_question_text': text, 'probe_question_clip_path': clipPath},
      where: 'phrase_id = ?',
      whereArgs: [phraseId],
    );
  }

  /// Records (or clears, with null) a phrase's slow-spoken Sprechgesang clip
  /// (audit item 15, scaffold). Until this is set, the phrase's Level-3 flow
  /// stays unavailable (see `sprechgesangSatisfied`).
  Future<void> setSprechgesangClip(int phraseId, String? clipPath) async {
    final db = await _db;
    await db.update(
      'practice_phrases',
      {'sprechgesang_clip_path': clipPath},
      where: 'phrase_id = ?',
      whereArgs: [phraseId],
    );
  }

  // --- Progression (the patient's MIT level) --------------------------------

  /// Per-session pass rate across judged productions, oldest → newest. Each entry
  /// is passes / (passes + fails) for that session, ignoring Unsure.
  ///
  /// This is what [LevelCriterion] reads: MIT's ~90% is a criterion for moving
  /// the PERSON up a level, so the default is every judged production of the
  /// session, not a slice of one word at one rung. (The old signature filtered by
  /// `rung_at_attempt >= minRung` and by syllable tier, because the number was
  /// being spent on a per-word tier gate — the thing the revert removes.)
  ///
  /// [phraseId] narrows it to one item, for display-only analytics; [step]
  /// narrows it to productions at one MIT step.
  Future<List<double>> sessionPassRates(String profileId,
      {int? phraseId, MitStep? step}) async {
    final db = await _db;
    final rows = await db.rawQuery('''
      SELECT SUM(CASE WHEN a.evaluation_label = 1 THEN 1 ELSE 0 END) AS passes,
             COUNT(*) AS judged
      FROM exercise_attempts a
      JOIN practice_sessions s ON a.session_id = s.session_id
      WHERE s.profile_id = ? ${phraseId != null ? 'AND a.phrase_id = ?' : ''}
        AND a.evaluation_label IN (0, 1)
        ${step != null ? 'AND a.step_at_attempt = ?' : ''}
      GROUP BY a.session_id
      ORDER BY MIN(a.rowid) ASC
    ''', [profileId, ?phraseId, ?step?.index]);
    return [
      for (final r in rows) (r['passes'] as int) / (r['judged'] as int),
    ];
  }

  /// Grow the plant, if it has not already grown today.
  ///
  /// Returns the stage after the call — the same value it was if today has
  /// already counted, or the plant is fully grown. Cumulative and one-way by
  /// construction: there is no path in the app that lowers it.
  ///
  /// [today] is injected so this is testable without waiting for midnight, and
  /// it is a **local** date: a session at 11pm belongs to the evening the family
  /// remembers, not to tomorrow.
  Future<int> growPlant(String profileId, {DateTime? today}) async {
    final db = await _db;
    final now = today ?? DateTime.now();
    final day =
        '${now.year.toString().padLeft(4, '0')}-'
        '${now.month.toString().padLeft(2, '0')}-'
        '${now.day.toString().padLeft(2, '0')}';

    final rows = await db.query(
      'user_profiles',
      columns: ['plant_stage', 'plant_grown_on'],
      where: 'profile_id = ?',
      whereArgs: [profileId],
      limit: 1,
    );
    if (rows.isEmpty) return 0;
    final stage = ((rows.first['plant_stage'] as int?) ?? 0).clamp(0, 4);
    final grownOn = rows.first['plant_grown_on'] as String?;

    if (grownOn == day || stage >= 4) return stage;
    final next = stage + 1;
    await db.update(
      'user_profiles',
      {'plant_stage': next, 'plant_grown_on': day},
      where: 'profile_id = ?',
      whereArgs: [profileId],
    );
    return next;
  }

  /// Minutes practised per day over the last [days] days, keyed 'YYYY-MM-DD'.
  ///
  /// A day's minutes are the sum of its sessions' spans — `started_at` to
  /// `ended_at`, so the warm-up and the last production are both inside it.
  /// Sessions that never recorded an attempt have no `ended_at` and contribute
  /// nothing, which is right: opening the app is not practice.
  ///
  /// Local dates, not UTC. A session at 11pm belongs to the evening the family
  /// remembers, and a dose display that quietly moved half of them to the next
  /// day would be wrong in the way that is hardest to notice.
  Future<Map<String, int>> minutesPerDay(String profileId,
      {int days = 28}) async {
    final db = await _db;
    final rows = await db.rawQuery('''
      SELECT date(started_at, 'localtime') AS day,
             SUM(MAX(0, strftime('%s', ended_at) - strftime('%s', started_at)))
               AS seconds
      FROM practice_sessions
      WHERE profile_id = ?
        AND ended_at IS NOT NULL
        AND started_at >= date('now', ?)
      GROUP BY day
    ''', [profileId, '-$days day']);
    return {
      for (final r in rows)
        r['day'] as String: (((r['seconds'] as num?) ?? 0) / 60).round(),
    };
  }

  /// Pass rate at each MIT step, across everything logged for [profileId].
  ///
  /// **The most useful number the app has for a caregiver**, and the only place
  /// a rate is shown at all — to them, never to the patient. A step sitting low
  /// is where the work is: it is the one they keep backing up from, and knowing
  /// which one it is tells them what to bring to a speech therapist.
  ///
  /// Unsure is excluded from both halves: "we could not tell" is not evidence
  /// either way. Steps with nothing logged are absent rather than zero — no
  /// history is not a bad score.
  Future<Map<MitStep, ({int passes, int judged})>> passRateByStep(
    String profileId,
  ) async {
    final db = await _db;
    final rows = await db.rawQuery('''
      SELECT a.step_at_attempt AS step,
             SUM(CASE WHEN a.evaluation_label = 1 THEN 1 ELSE 0 END) AS passes,
             COUNT(*) AS judged
      FROM exercise_attempts a
      JOIN practice_sessions s ON a.session_id = s.session_id
      WHERE s.profile_id = ?
        AND a.evaluation_label IN (0, 1)
        AND a.step_at_attempt IS NOT NULL
      GROUP BY a.step_at_attempt
    ''', [profileId]);
    return {
      for (final r in rows)
        if ((r['step'] as int) < MitStep.values.length)
          MitStep.values[r['step'] as int]: (
            passes: (r['passes'] as int?) ?? 0,
            judged: (r['judged'] as int?) ?? 0,
          ),
    };
  }

  /// How many sessions have been run, and when the first one was — for the
  /// "14 sessions · 6 weeks practising" line. Both null-safe on a fresh install.
  Future<({int sessions, DateTime? firstAt})> practiceSpan(
    String profileId,
  ) async {
    final db = await _db;
    final rows = await db.rawQuery(
      'SELECT COUNT(*) AS n, MIN(started_at) AS first FROM practice_sessions '
      'WHERE profile_id = ?',
      [profileId],
    );
    final row = rows.first;
    final first = row['first'] as String?;
    return (
      sessions: (row['n'] as int?) ?? 0,
      firstAt: first == null ? null : DateTime.tryParse(first),
    );
  }

  // --- Progress analytics (display-only — never feeds progression) ----------

  /// Per-session average content-similarity score (0–1), oldest → newest, for
  /// (profile[, phrase]). Only sessions with at least one scored attempt appear.
  Future<List<double>> sessionSimilarity(String profileId, {int? phraseId}) async {
    final db = await _db;
    final rows = await db.rawQuery('''
      SELECT AVG(f.content_similarity_score) AS sim
      FROM acoustic_feature_vectors f
      JOIN exercise_attempts a ON f.attempt_id = a.attempt_id
      JOIN practice_sessions s ON a.session_id = s.session_id
      WHERE s.profile_id = ? ${phraseId != null ? 'AND a.phrase_id = ?' : ''}
        AND f.content_similarity_score IS NOT NULL
      GROUP BY a.session_id
      ORDER BY MIN(a.rowid) ASC
    ''', [profileId, ?phraseId]);
    return [for (final r in rows) (r['sim'] as num).toDouble()];
  }

  /// Per-session average response latency (ms), oldest → newest, for
  /// (profile[, phrase]). Lower is better (faster to start speaking).
  Future<List<double>> sessionLatency(String profileId, {int? phraseId}) async {
    final db = await _db;
    final rows = await db.rawQuery('''
      SELECT AVG(a.latency_ms) AS lat
      FROM exercise_attempts a
      JOIN practice_sessions s ON a.session_id = s.session_id
      WHERE s.profile_id = ? ${phraseId != null ? 'AND a.phrase_id = ?' : ''}
        AND a.latency_ms IS NOT NULL
      GROUP BY a.session_id
      ORDER BY MIN(a.rowid) ASC
    ''', [profileId, ?phraseId]);
    return [for (final r in rows) (r['lat'] as num).toDouble()];
  }

  /// Starts the progression over: the patient goes back to MIT's first level.
  ///
  /// That is the whole of it now. Under the ladder this also had to walk every
  /// phrase back to its entry rung and clear a per-word tier and tempo; with the
  /// sequence fixed by the level, the person's level IS the progression.
  Future<void> resetProgression(String profileId) async {
    final db = await _db;
    await db.update(
      'user_profiles',
      {'mit_level': MitLevel.one.index},
      where: 'profile_id = ?',
      whereArgs: [profileId],
    );
  }

  /// Turns a built-in phrase on/off for future sessions.
  Future<void> setPhraseActive(int phraseId, bool isActive) async {
    final db = await _db;
    await db.update(
      'practice_phrases',
      {'is_active': isActive ? 1 : 0},
      where: 'phrase_id = ?',
      whereArgs: [phraseId],
    );
  }

  /// All phrases, ordered easiest-first then alphabetically. Used by the
  /// caregiver's settings portal (which shows active and inactive alike).
  Future<List<PracticePhrase>> getAllPhrases() async {
    final db = await _db;
    final rows = await db.query(
      'practice_phrases',
      orderBy: 'complexity_level ASC, phrase_text ASC',
    );
    return rows.map(PracticePhrase.fromMap).toList();
  }

  /// Only the phrases currently switched on — the ones a session will use.
  ///
  /// The caregiver's own words come first; starter-library words are
  /// **deprioritized** (`is_starter ASC`) so they fill in behind, not ahead of,
  /// what the caregiver added (Part 3, item 14). This is ordering only — it does
  /// not touch any rung/progression decision.
  Future<List<PracticePhrase>> getActivePhrases() async {
    final db = await _db;
    final rows = await db.query(
      'practice_phrases',
      where: 'is_active = 1',
      orderBy: 'is_starter ASC, complexity_level ASC, phrase_text ASC',
    );
    return rows.map(PracticePhrase.fromMap).toList();
  }

  /// Starter-library phrases whose bundled guide hasn't been installed yet
  /// (guide_clip_path still NULL). Drives `StarterGuideInstaller` on launch.
  Future<List<PracticePhrase>> getStarterPhrasesNeedingGuide() async {
    final db = await _db;
    final rows = await db.query(
      'practice_phrases',
      where: 'is_starter = 1 AND guide_clip_path IS NULL',
      orderBy: 'phrase_id ASC',
    );
    return rows.map(PracticePhrase.fromMap).toList();
  }

  /// Points a phrase at an already-installed encrypted guide clip. Used by the
  /// starter installer — the phrase's syllable/nuclei/stress metadata was already
  /// seeded, so only the clip path is written here.
  Future<void> attachGuideClipPath(int phraseId, String guideClipPath) async {
    final db = await _db;
    await db.update(
      'practice_phrases',
      {'guide_clip_path': guideClipPath},
      where: 'phrase_id = ?',
      whereArgs: [phraseId],
    );
  }

  // --- Sessions & attempts -------------------------------------------------

  /// Starts a new practice session for [profileId] and returns its generated id.
  Future<String> createSession(String profileId) async {
    final db = await _db;
    final sessionId = _uuid.v4();
    await db.insert('practice_sessions', {
      'session_id': sessionId,
      'profile_id': profileId,
    });
    return sessionId;
  }

  /// Saves one attempt and returns its generated id. [latencyMs]/[durationMs]
  /// are null until the microphone (Step 5) measures them; the audio path stays
  /// null until the mic records a clip.
  Future<String> insertAttempt({
    required String sessionId,
    required int phraseId,
    required int evaluationLabel,
    double? tappingSynchronizationScore,
    int? latencyMs,
    int? durationMs,
    String? localEncryptedAudioPath,
    int? stepAtAttempt,
    int? tempoBpm,
  }) async {
    final db = await _db;
    final attemptId = _uuid.v4();
    await db.insert('exercise_attempts', {
      'attempt_id': attemptId,
      'session_id': sessionId,
      'phrase_id': phraseId,
      'latency_ms': latencyMs,
      'duration_ms': durationMs,
      'tapping_synchronization_score': tappingSynchronizationScore,
      'evaluation_label': evaluationLabel,
      'local_encrypted_audio_path': localEncryptedAudioPath,
      'step_at_attempt': stepAtAttempt, // v28: the MIT step it was produced at
      'tempo_bpm': tempoBpm, // v20: beat reference at capture (item 16c)
    });
    // v31: stamp the session as still running. Doing it per attempt (rather than
    // once at the end) means a session that is abandoned mid-way still records
    // how long it actually ran, and the span covers the last production instead
    // of stopping at the second-to-last attempt.
    await db.rawUpdate(
      "UPDATE practice_sessions SET ended_at = datetime('now') "
      'WHERE session_id = ?',
      [sessionId],
    );
    return attemptId;
  }

  /// Persist the raw per-tap stream for one attempt (ML logging audit item 16a):
  /// one `tap_events` row per [TapEvent], carrying its touch-down time, dwell, and
  /// beat phase, tied to [attemptId]/[phraseId]/[sessionId]/[step]. A no-op when
  /// there were no taps. Batched into one round-trip. Unlike audio, these derived
  /// features are never evicted — this is the fatigue detector's future input.
  Future<void> insertTapEvents({
    required String attemptId,
    required int phraseId,
    required String sessionId,
    required MitStep? step,
    required List<TapEvent> taps,
  }) async {
    if (taps.isEmpty) return;
    final db = await _db;
    final batch = db.batch();
    for (var i = 0; i < taps.length; i++) {
      final t = taps[i];
      batch.insert('tap_events', {
        'tap_id': _uuid.v4(),
        'attempt_id': attemptId,
        'phrase_id': phraseId,
        'session_id': sessionId,
        'step': step?.index,
        'tap_index': i,
        'down_ms': t.downMs,
        'dwell_ms': t.dwellMs,
        'beat_phase': t.phase,
      });
    }
    await batch.commit(noResult: true);
  }

  /// The raw tap stream saved for [attemptId], in tap order. Used by tests and
  /// (later) the fatigue detector's per-attempt read.
  Future<List<StoredTapEvent>> getTapEvents(String attemptId) async {
    final db = await _db;
    final rows = await db.query(
      'tap_events',
      where: 'attempt_id = ?',
      whereArgs: [attemptId],
      orderBy: 'tap_index ASC',
    );
    return rows.map(StoredTapEvent.fromMap).toList();
  }

  /// Every tap made during [sessionId], in chronological order. This is the
  /// per-session window the fatigue detector reads (dwell trend + inter-tap
  /// interval variance across the session).
  Future<List<StoredTapEvent>> getTapEventsForSession(String sessionId) async {
    final db = await _db;
    final rows = await db.query(
      'tap_events',
      where: 'session_id = ?',
      whereArgs: [sessionId],
      orderBy: 'down_ms ASC',
    );
    return rows.map(StoredTapEvent.fromMap).toList();
  }

  /// Attempts that still have an audio clip recorded before [cutoffUtc] (a
  /// SQLite-format `YYYY-MM-DD HH:MM:SS` UTC string). Used by the eviction job.
  Future<List<ExerciseAttempt>> getAttemptsWithAudioBefore(
      String cutoffUtc) async {
    final db = await _db;
    final rows = await db.query(
      'exercise_attempts',
      where: 'local_encrypted_audio_path IS NOT NULL AND timestamp < ?',
      whereArgs: [cutoffUtc],
    );
    return rows.map(ExerciseAttempt.fromMap).toList();
  }

  /// Forgets an attempt's audio path (after its file is deleted). The row and
  /// all its numeric fields are kept — only the path becomes NULL.
  Future<void> clearAudioPath(String attemptId) async {
    final db = await _db;
    await db.update(
      'exercise_attempts',
      {'local_encrypted_audio_path': null},
      where: 'attempt_id = ?',
      whereArgs: [attemptId],
    );
  }

  // --- Analysis: feature vectors & anchors (Phase 2A) ----------------------

  /// Persist the analysis output for one attempt into `acoustic_feature_vectors`
  /// (brief §5). Stores the gate verdict and, if the clip passed, its similarity
  /// score (null otherwise). Returns the new vector id.
  /// [onsetMs] is the patient's own detected syllable onsets for this clip (item
  /// 16c), stored as CSV so onset-vs-beat steadiness can be recomputed after the
  /// audio is evicted; empty/absent when nothing was detected (e.g. a gate-
  /// rejected clip). The DTW distance ([AnalysisResult.mfccDistance], item 16b)
  /// is stored alongside the squashed similarity.
  Future<String> insertFeatureVector({
    required String attemptId,
    required AnalysisResult result,
    List<int> onsetMs = const [],
  }) async {
    final db = await _db;
    final vectorId = _uuid.v4();
    await db.insert('acoustic_feature_vectors', {
      'vector_id': vectorId,
      'attempt_id': attemptId,
      'content_similarity_score': result.contentSimilarityScore,
      'mfcc_distance': result.mfccDistance,
      'gate_passed': result.gatePassed ? 1 : 0,
      'gate_reason': result.gateReason,
      'duration_ms': result.durationMs,
      'onset_ms': onsetMs.isEmpty ? null : onsetMs.join(','),
    });
    return vectorId;
  }

  /// The stored feature vector for an attempt, or null if none was saved.
  Future<FeatureVector?> getFeatureVector(String attemptId) async {
    final db = await _db;
    final rows = await db.query(
      'acoustic_feature_vectors',
      where: 'attempt_id = ?',
      whereArgs: [attemptId],
      limit: 1,
    );
    return rows.isEmpty ? null : FeatureVector.fromMap(rows.first);
  }

  /// The anchor template for (profile, phrase), with its MFCC decoded, or null
  /// if this phrase has no anchor yet (scoring then uses the bundled reference).
  Future<AnchorTemplate?> getAnchor(String profileId, int phraseId) async {
    final db = await _db;
    final rows = await db.query(
      'phrase_anchor_templates',
      where: 'profile_id = ? AND phrase_id = ?',
      whereArgs: [profileId, phraseId],
      limit: 1,
    );
    if (rows.isEmpty) return null;
    final r = rows.first;
    return AnchorTemplate(
      anchorId: r['anchor_id'] as String,
      profileId: r['profile_id'] as String,
      phraseId: r['phrase_id'] as int,
      mfcc: MfccCodec.decode(
        r['mfcc_frames'] as Uint8List,
        r['frame_count'] as int,
        r['coeff_count'] as int,
      ),
      scoreVsReference: (r['score_vs_reference'] as num?)?.toDouble(),
      sourceAttemptId: r['source_attempt_id'] as String?,
      confirmedAt: r['confirmed_at'] as String,
    );
  }

  /// Apply the anchor promotion/replacement rules (brief §4) for one
  /// caregiver-confirmed (Pass) attempt. The CALLER is responsible for only
  /// invoking this on Pass attempts; this method owns the no-anchor / better /
  /// worse decision:
  ///   - no anchor exists       → promote (store this attempt's MFCC).
  ///   - [scoreVsReference] beats the stored value → replace (the "leniency
  ///     overwrite": a stronger confirmed production raises the bar).
  ///   - otherwise              → keep the existing anchor untouched.
  ///
  /// [scoreVsReference] is this attempt's similarity vs the bundled reference.
  Future<AnchorAction> considerAnchor({
    required String profileId,
    required int phraseId,
    required String sourceAttemptId,
    required List<Float64List> mfcc,
    required double scoreVsReference,
  }) async {
    final db = await _db;
    final blob = MfccCodec.encode(mfcc);
    final frameCount = mfcc.length;
    final coeffCount = mfcc.isEmpty ? 0 : mfcc.first.length;

    final existing = await db.query(
      'phrase_anchor_templates',
      where: 'profile_id = ? AND phrase_id = ?',
      whereArgs: [profileId, phraseId],
      limit: 1,
    );

    if (existing.isEmpty) {
      await db.insert('phrase_anchor_templates', {
        'anchor_id': _uuid.v4(),
        'profile_id': profileId,
        'phrase_id': phraseId,
        'mfcc_frames': blob,
        'frame_count': frameCount,
        'coeff_count': coeffCount,
        'score_vs_reference': scoreVsReference,
        'source_attempt_id': sourceAttemptId,
      });
      return AnchorAction.promoted;
    }

    final stored =
        (existing.first['score_vs_reference'] as num?)?.toDouble();
    if (stored == null || scoreVsReference > stored) {
      await db.update(
        'phrase_anchor_templates',
        {
          'mfcc_frames': blob,
          'frame_count': frameCount,
          'coeff_count': coeffCount,
          'score_vs_reference': scoreVsReference,
          'source_attempt_id': sourceAttemptId,
          'confirmed_at': DateTime.now().toIso8601String(),
        },
        where: 'anchor_id = ?',
        whereArgs: [existing.first['anchor_id']],
      );
      return AnchorAction.replaced;
    }

    return AnchorAction.kept;
  }

  // --- Daily summary (per-day metrics rollup; display-only, sync) ----------

  /// Recompute TODAY's rollup row (UTC) from the profile's attempts and mark it
  /// pending sync. Call after each saved attempt. Never holds audio.
  Future<void> touchDailySummaryForToday(String profileId) async {
    final db = await _db;
    await db.rawInsert('''
      INSERT OR REPLACE INTO daily_summary
        (profile_id, day, attempts, passes, fails, unsure, avg_similarity, synced_at)
      SELECT ?, date('now'),
        COUNT(*),
        SUM(CASE WHEN a.evaluation_label = 1 THEN 1 ELSE 0 END),
        SUM(CASE WHEN a.evaluation_label = 0 THEN 1 ELSE 0 END),
        SUM(CASE WHEN a.evaluation_label = 2 THEN 1 ELSE 0 END),
        AVG(f.content_similarity_score),
        NULL
      FROM exercise_attempts a
      JOIN practice_sessions s ON a.session_id = s.session_id
      LEFT JOIN acoustic_feature_vectors f ON f.attempt_id = a.attempt_id
      -- A half-open range on the raw timestamp (not date(a.timestamp)=…) so the
      -- idx_attempts_timestamp index is usable (item 22). Timestamps are stored
      -- 'YYYY-MM-DD HH:MM:SS' UTC, so lexical ≥/< matches date-of-today.
      WHERE s.profile_id = ?
        AND a.timestamp >= date('now')
        AND a.timestamp < date('now', '+1 day')
    ''', [profileId, profileId]);
  }

  /// Recent daily rollups, newest first (caregiver/family dashboard).
  Future<List<DailySummary>> getDailySummaries(String profileId,
      {int limit = 30}) async {
    final db = await _db;
    final rows = await db.query(
      'daily_summary',
      where: 'profile_id = ?',
      whereArgs: [profileId],
      orderBy: 'day DESC',
      limit: limit,
    );
    return rows.map(DailySummary.fromMap).toList();
  }

  /// Daily rollups not yet pushed to the cloud (synced_at IS NULL), oldest first.
  Future<List<DailySummary>> getUnsyncedDailySummaries() async {
    final db = await _db;
    final rows = await db.query(
      'daily_summary',
      where: 'synced_at IS NULL',
      orderBy: 'day ASC',
    );
    return rows.map(DailySummary.fromMap).toList();
  }

  Future<void> markDailySummarySynced(
      String profileId, String day, String syncedAtIso) async {
    final db = await _db;
    await db.update('daily_summary', {'synced_at': syncedAtIso},
        where: 'profile_id = ? AND day = ?', whereArgs: [profileId, day]);
  }

  // --- Cloud-sync bookkeeping ----------------------------------------------

  /// Remembers this local profile's id in the cloud (Supabase practice_profiles).
  Future<void> setCloudProfileId(String cloudId) async {
    final db = await _db;
    await db.update(
      'user_profiles',
      {'cloud_profile_id': cloudId},
      where: 'profile_id = ?',
      whereArgs: [AppDatabase.defaultProfileId],
    );
  }

  /// Forgets the stored cloud profile mapping (e.g. on sign-out), so the next
  /// signed-in user re-resolves their own profile rather than reusing another's.
  Future<void> clearCloudProfileId() async {
    final db = await _db;
    await db.update(
      'user_profiles',
      {'cloud_profile_id': null},
      where: 'profile_id = ?',
      whereArgs: [AppDatabase.defaultProfileId],
    );
  }

  /// The cloud profile id we've stored, or null if we haven't created one yet.
  Future<String?> getCloudProfileId() async {
    final db = await _db;
    final rows = await db.query(
      'user_profiles',
      columns: ['cloud_profile_id'],
      where: 'profile_id = ?',
      whereArgs: [AppDatabase.defaultProfileId],
      limit: 1,
    );
    return rows.first['cloud_profile_id'] as String?;
  }

  /// Sessions not yet pushed to the cloud (synced_at IS NULL), oldest first.
  Future<List<({String sessionId, String profileId, String startedAt})>>
      getUnsyncedSessions() async {
    final db = await _db;
    final rows = await db.query(
      'practice_sessions',
      where: 'synced_at IS NULL',
      orderBy: 'started_at ASC',
    );
    return [
      for (final r in rows)
        (
          sessionId: r['session_id'] as String,
          profileId: r['profile_id'] as String,
          startedAt: r['started_at'] as String,
        ),
    ];
  }

  /// Attempts not yet pushed to the cloud, joined to their phrase so we can send
  /// the (denormalized) phrase text + level. Returned as raw maps for the
  /// SyncService to shape into a Supabase row.
  Future<List<Map<String, Object?>>> getUnsyncedAttempts() async {
    final db = await _db;
    return db.rawQuery('''
      SELECT a.attempt_id, a.session_id, a.phrase_id, a.timestamp,
             a.latency_ms, a.duration_ms, a.tapping_synchronization_score,
             a.evaluation_label, p.phrase_text, p.complexity_level
      FROM exercise_attempts a
      JOIN practice_phrases p ON a.phrase_id = p.phrase_id
      WHERE a.synced_at IS NULL
      ORDER BY a.timestamp ASC
    ''');
  }

  Future<void> markSessionSynced(String sessionId, String syncedAtIso) async {
    final db = await _db;
    await db.update('practice_sessions', {'synced_at': syncedAtIso},
        where: 'session_id = ?', whereArgs: [sessionId]);
  }

  Future<void> markAttemptSynced(String attemptId, String syncedAtIso) async {
    final db = await _db;
    await db.update('exercise_attempts', {'synced_at': syncedAtIso},
        where: 'attempt_id = ?', whereArgs: [attemptId]);
  }

  // --- History & insights (local, offline) ---------------------------------

  /// Per-phrase aggregates over every recorded attempt: how many times it was
  /// practiced, the Pass/Fail/Unsure breakdown, and the average tap-sync score.
  /// Only phrases that have been attempted appear. Built from already-final data
  /// (no mic/audio fields), so it's complete now.
  Future<List<PhraseStat>> getPhraseStats() async {
    final db = await _db;
    final rows = await db.rawQuery('''
      SELECT p.phrase_id, p.phrase_text, p.complexity_level,
             COUNT(a.attempt_id) AS attempts,
             SUM(CASE WHEN a.evaluation_label = 1 THEN 1 ELSE 0 END) AS passes,
             SUM(CASE WHEN a.evaluation_label = 0 THEN 1 ELSE 0 END) AS fails,
             SUM(CASE WHEN a.evaluation_label = 2 THEN 1 ELSE 0 END) AS unsure,
             AVG(a.tapping_synchronization_score) AS avg_sync
      FROM practice_phrases p
      JOIN exercise_attempts a ON a.phrase_id = p.phrase_id
      GROUP BY p.phrase_id, p.phrase_text, p.complexity_level
      ORDER BY attempts DESC, p.phrase_text ASC
    ''');
    return [
      for (final r in rows)
        PhraseStat(
          phraseId: r['phrase_id'] as int,
          phraseText: r['phrase_text'] as String,
          complexityLevel: r['complexity_level'] as int,
          attempts: r['attempts'] as int,
          passes: (r['passes'] as int?) ?? 0,
          fails: (r['fails'] as int?) ?? 0,
          unsure: (r['unsure'] as int?) ?? 0,
          avgSyncScore: (r['avg_sync'] as num?)?.toDouble(),
        ),
    ];
  }

  /// Recent sessions, newest first, each with its attempt + pass counts.
  Future<List<SessionSummary>> getSessionSummaries({int limit = 50}) async {
    final db = await _db;
    final rows = await db.rawQuery('''
      SELECT s.session_id, s.started_at,
             COUNT(a.attempt_id) AS attempts,
             SUM(CASE WHEN a.evaluation_label = 1 THEN 1 ELSE 0 END) AS passes
      FROM practice_sessions s
      LEFT JOIN exercise_attempts a ON a.session_id = s.session_id
      GROUP BY s.session_id, s.started_at
      ORDER BY s.started_at DESC
      LIMIT ?
    ''', [limit]);
    return [
      for (final r in rows)
        SessionSummary(
          sessionId: r['session_id'] as String,
          startedAt: r['started_at'] as String,
          attempts: r['attempts'] as int,
          passes: (r['passes'] as int?) ?? 0,
        ),
    ];
  }

  /// All attempts for a session, oldest first. Handy for tests and a future
  /// progress view.
  Future<List<ExerciseAttempt>> getAttemptsForSession(String sessionId) async {
    final db = await _db;
    final rows = await db.query(
      'exercise_attempts',
      where: 'session_id = ?',
      whereArgs: [sessionId],
      orderBy: 'timestamp ASC',
    );
    return rows.map(ExerciseAttempt.fromMap).toList();
  }
}

/// What [PracticeRepository.considerAnchor] did with a confirmed attempt.
enum AnchorAction {
  /// Stored as the phrase's first anchor.
  promoted,

  /// Overwrote a weaker existing anchor.
  replaced,

  /// Left the existing (stronger) anchor in place.
  kept,
}
