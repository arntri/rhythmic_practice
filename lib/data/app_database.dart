import 'dart:io' show Platform;

import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';
// Importing sqflite registers the native database factory used on Android/iOS.
// The analyzer thinks it's unnecessary because sqflite_common_ffi re-exports the
// same types, but that package only covers desktop — we need both.
// ignore: unnecessary_import
import 'package:sqflite/sqflite.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

import 'starter_library.dart';

/// Opens (and, on first run, creates + seeds) the local SQLite database.
///
/// This is the lowest layer of the data stack. Nothing in here knows about the
/// UI — it just hands back an open [Database]. The [PracticeRepository] is what
/// the rest of the app actually talks to.
///
/// We use a single shared instance ("singleton") so the whole app reuses one
/// open database connection instead of opening it over and over.
class AppDatabase {
  AppDatabase._(); // private constructor — nobody can make their own copy
  static final AppDatabase instance = AppDatabase._();

  static const _fileName = 'rhythmic_practice.db';
  // v2 added cloud-sync bookkeeping columns (cloud_profile_id, synced_at).
  // v3 added the Phase 2A analysis core: the support_level column on
  // exercise_attempts plus the acoustic_feature_vectors and
  // phrase_anchor_templates tables.
  // v4 added guide_clip_path on practice_phrases: the AES-encrypted, caregiver-
  // recorded guide clip that doubles as the phrase's DTW reference (therapy
  // addendum §1/§2). Distinct from audio_asset_path (bundled fallback).
  // v5 added guide_nuclei_ms on practice_phrases: comma-separated syllable-
  // nucleus timestamps (ms) from the confirmed guide recording, used to place
  // metronome beats on the actual syllables (therapy addendum §2 revision).
  // v6 added capture_silence_ms on user_profiles: the caregiver-adjustable
  // recording window (silence-before-stop), 3000–8000 ms, default 4500.
  // v7 added current_rung on practice_phrases: the MIT support/task ladder rung
  // (0–6) the caregiver has the user on for that phrase; default 2 (unison).
  // v8 added Phase 3 auto-progression: rung_at_attempt on exercise_attempts (the
  // rung an attempt was produced at, so the engine counts success at the current
  // rung) and auto_progress_enabled on user_profiles (caregiver on/off, default
  // on).
  // v9 added photo_path on practice_phrases: an AES-encrypted photo for "name
  // cards" (therapy addendum §6 — photo + recorded-name, the hardest tier).
  // v10 added onboarding_seen on user_profiles: whether the first-run caregiver
  // instructions have been shown (UX overhaul).
  // v11 added the progression_state table: the per-(profile, phrase) MIT
  // progression record (rung, syllable tier, within-rung tempo) the Phase 3
  // rules controller drives (therapy addendum §4).
  // v12 added target_display on user_profiles: how the word is shown — picture /
  // word / both (audio is always the primary cue). The picture itself reuses the
  // existing AES-encrypted practice_phrases.photo_path.
  // v13 added the daily_summary table: a per-(profile, day) metrics rollup
  // (attempts / pass-fail / avg similarity) for the family dashboard + cloud sync
  // (display-only analytics; never audio).
  // v14 added playback_speed on user_profiles: the caregiver's overall guide
  // speed multiplier (1.0 / 0.75 / 0.5 …); lower = the words come out slower.
  // v15 reconciles the rung stores: the legacy per-attempt AutoProgression (now
  // removed) wrote practice_phrases.current_rung with a fast k-of-m climb that
  // could strand a word at R6. The live block controller seeds each session from
  // current_rung, so those stale values made every session open at R6. This
  // resets current_rung to the unison default (R2) for any phrase the new
  // controller has NOT yet recorded (no progression_state row) — i.e. words
  // carrying only legacy values — while leaving the controller-managed words
  // (which mirror their rung into progression_state) untouched.
  // v16 added tier_at_attempt on exercise_attempts: the syllable tier an attempt
  // was produced at, so the slow-loop tier gate counts top-rung (R6) mastery only
  // WITHIN the current tier — otherwise old R6 rows from a previous tier would
  // instantly re-promote the word each time it climbed back to R6.
  // v18 added demo_mode_enabled on user_profiles: a caregiver/presenter switch
  // (default off) that surfaces an in-session level picker on the practice screen
  // for live demonstrations — letting the presenter jump the current word to any
  // rung on demand. It changes only the in-session rung (never persisted to the
  // phrase's stored progression), so a demo can't disturb real therapy history.
  // v19 added the tap_events table: the RAW per-tap stream (touch-down time +
  // dwell + beat phase), one row per tap, tied to its attempt/phrase/rung. The
  // aggregate tapping_synchronization_score alone can't reconstruct dwell or
  // inter-tap-interval variance (the fatigue-detector inputs), and unlike audio
  // this derived data is NOT evicted — it must be captured at session time or
  // it's lost forever. (ML logging audit, Part 3 item 16a.)
  // v20 enriched the per-attempt acoustic log (ML logging audit items 16b/16c):
  // mfcc_distance + onset_ms on acoustic_feature_vectors (the raw DTW distance
  // behind the squashed similarity, and the PATIENT's own detected syllable
  // onsets), and tempo_bpm on exercise_attempts (the beat reference at capture
  // time). Together these let vocal-rhythm steadiness (onset-vs-beat) be computed
  // after the 48h audio eviction, which otherwise erases the only source.
  // v21 added the response-to-a-question step (R7, audit item 11): a per-phrase
  // probe_question_text and optional AES-encrypted probe_question_clip_path — the
  // intoned/spoken question the app plays for the user to answer with the target
  // phrase, solo, at the top rung.
  // v22 added stress_index on practice_phrases (intonation flow, item A): the
  // caregiver-designated syllable that carries the HIGH note. One human tap is the
  // source of truth for "correct stress" — it drives the reference demo, the
  // mis-stress check on the caregiver's recording, and the on-screen melody cue.
  // v23 reconciles level with syllable count (audit item 12): recomputes
  // practice_phrases.complexity_level from syllable_count (1–3→L1, 4–6→L2, 7+→L3),
  // retiring the old wordCount>1?3:1 heuristic, and seeds progression_state
  // .syllable_tier from the same count for words still at the default tier 1 (so
  // a longer phrase starts at a higher linguistic-load level).
  // v24 added solo_mode_enabled on user_profiles (audit item 19, scaffold): the
  // caregiver switch for scoped solo practice. Default off; the ML never gates
  // (solo mode is advisory-only until Layer C graduates — which it can't until a
  // model is trained).
  // v25 added (a) sprechgesang_clip_path on practice_phrases (audit item 15,
  // scaffold): a separate caregiver-recorded slow-spoken (speech-song) clip;
  // Level 3 stays unavailable until it exists. And (b) indexes that speed the
  // daily-summary recompute (audit item 22): exercise_attempts(session_id),
  // exercise_attempts(timestamp), practice_sessions(profile_id).
  // v26 reconciles stored rungs to the refactored active word ladder [R2, R6]:
  // tapping (R0) and humming (R1) are now the session WARM-UP (not per-word rungs)
  // and R7 (answer-the-question) is deferred/off, so any legacy phrase or
  // progression row parked at r0/r1 is bumped to unison (R2) and any at r7 clamped
  // to solo (R6). No word ever sits on a warm-up or deferred rung again.
  // v27 adds is_starter on practice_phrases (the starter word library, Part 3):
  // ~10 phrases bundled with placeholder guides, seeded idempotently. The flag is
  // presentation-only — it never branches practice logic (rungs/progression).
  static const _schemaVersion = 27;

  // We hold onto the open connection once we've opened it.
  Database? _db;

  /// Returns the open database, opening it the first time it's asked for.
  Future<Database> get database async {
    return _db ??= await _open();
  }

  Future<Database> _open() async {
    // sqflite ships native support for Android & iOS. On desktop (we're
    // developing on Linux) it needs the FFI backend, which we initialise here.
    // This block does nothing on a phone, so the same code runs everywhere.
    if (Platform.isLinux || Platform.isWindows || Platform.isMacOS) {
      sqfliteFfiInit();
      databaseFactory = databaseFactoryFfi;
    }

    // A stable, app-private folder that exists on every platform.
    final dir = await getApplicationSupportDirectory();
    final path = p.join(dir.path, _fileName);

    return databaseFactory.openDatabase(
      path,
      options: OpenDatabaseOptions(
        version: _schemaVersion,
        // SQLite has foreign keys OFF by default; turn them on every connection
        // so the ON DELETE CASCADE rules in our schema actually fire.
        onConfigure: (db) => db.execute('PRAGMA foreign_keys = ON'),
        // Runs only the very first time the database file is created.
        onCreate: (db, version) => applyInitialSchema(db),
        // Runs when an existing database is older than _schemaVersion.
        onUpgrade: migrate,
      ),
    );
  }

  /// Applies schema changes for existing databases, one version at a time.
  /// Public + static so the migration can be exercised directly in tests.
  static Future<void> migrate(Database db, int oldVersion, int newVersion) async {
    if (oldVersion < 2) {
      // Cloud-sync bookkeeping (see [_createSchema] for the same columns on
      // fresh installs).
      await db.execute('ALTER TABLE user_profiles ADD COLUMN cloud_profile_id TEXT');
      await db.execute('ALTER TABLE practice_sessions ADD COLUMN synced_at TEXT');
      await db.execute('ALTER TABLE exercise_attempts ADD COLUMN synced_at TEXT');
    }
    if (oldVersion < 3) {
      // Phase 2A analysis core. The same column + tables are created inline for
      // fresh installs in [_createSchema] / [_createAnalysisTables].
      await db.execute(
        'ALTER TABLE exercise_attempts ADD COLUMN support_level '
        'INTEGER NOT NULL DEFAULT 2 CHECK(support_level IN (1,2,3,4))',
      );
      await _createAnalysisTables(db);
    }
    if (oldVersion < 4) {
      // Caregiver-recorded guide clip per phrase (also the DTW reference). Same
      // column is created inline for fresh installs in [_createSchema].
      await db.execute(
          'ALTER TABLE practice_phrases ADD COLUMN guide_clip_path TEXT');
    }
    if (oldVersion < 5) {
      // Confirmed syllable-nucleus timestamps for the guide (CSV of ms).
      await db.execute(
          'ALTER TABLE practice_phrases ADD COLUMN guide_nuclei_ms TEXT');
    }
    if (oldVersion < 6) {
      // Caregiver-adjustable recording window (silence-before-stop), ms.
      await db.execute(
          'ALTER TABLE user_profiles ADD COLUMN capture_silence_ms INTEGER DEFAULT 4500');
    }
    if (oldVersion < 7) {
      // Per-phrase progression rung (MIT ladder), 0–6, default 2 (unison).
      await db.execute(
          'ALTER TABLE practice_phrases ADD COLUMN current_rung INTEGER NOT NULL DEFAULT 2');
    }
    if (oldVersion < 8 && newVersion >= 8) {
      // Phase 3 auto-progression. The rung an attempt was produced at (null for
      // pre-v8 attempts), and the caregiver on/off switch (default on). Same
      // columns are created inline for fresh installs in [_createSchema]. The
      // newVersion guard keeps a partial upgrade (e.g. a test opening at v7) from
      // running this step early against a table that may not exist yet.
      await db.execute(
          'ALTER TABLE exercise_attempts ADD COLUMN rung_at_attempt INTEGER');
      await db.execute('ALTER TABLE user_profiles ADD COLUMN '
          'auto_progress_enabled INTEGER NOT NULL DEFAULT 1 '
          'CHECK(auto_progress_enabled IN (0,1))');
    }
    if (oldVersion < 9 && newVersion >= 9) {
      // AES-encrypted photo for name cards (therapy addendum §6). Same column is
      // created inline for fresh installs in [_createSchema].
      await db.execute(
          'ALTER TABLE practice_phrases ADD COLUMN photo_path TEXT');
    }
    if (oldVersion < 10 && newVersion >= 10) {
      // First-run onboarding flag (UX overhaul). Same column is created inline
      // for fresh installs in [_createSchema].
      await db.execute('ALTER TABLE user_profiles ADD COLUMN '
          'onboarding_seen INTEGER NOT NULL DEFAULT 0 '
          'CHECK(onboarding_seen IN (0,1))');
    }
    if (oldVersion < 11 && newVersion >= 11) {
      // Phase 3 progression-state record (therapy addendum §4). Same table is
      // created inline for fresh installs in [_createSchema].
      await _createProgressionTable(db);
    }
    if (oldVersion < 12 && newVersion >= 12) {
      // Target-display preference (picture / word / both). Same column is created
      // inline for fresh installs in [_createSchema].
      await db.execute("ALTER TABLE user_profiles ADD COLUMN "
          "target_display TEXT NOT NULL DEFAULT 'picture' "
          "CHECK(target_display IN ('picture','word','both'))");
    }
    if (oldVersion < 13 && newVersion >= 13) {
      // Per-day metrics rollup for the family dashboard + sync. Same table is
      // created inline for fresh installs in [_createSchema].
      await _createDailySummaryTable(db);
    }
    if (oldVersion < 14 && newVersion >= 14) {
      // Caregiver guide-speed multiplier. Same column is created inline for fresh
      // installs in [_createSchema].
      await db.execute('ALTER TABLE user_profiles ADD COLUMN '
          'playback_speed REAL NOT NULL DEFAULT 1.0');
    }
    if (oldVersion < 15 && newVersion >= 15) {
      // Reset legacy-inflated rungs back to the unison default (R2). Only phrases
      // the live block controller has never recorded (no progression_state row)
      // are touched — those carry only the removed per-attempt engine's values
      // (which could be stuck at R6). Controller-managed words keep their rung.
      // No-op on a fresh install (every current_rung is already the R2 default).
      await db.execute('''
        UPDATE practice_phrases SET current_rung = 2
        WHERE phrase_id NOT IN (SELECT phrase_id FROM progression_state)
      ''');
    }
    if (oldVersion < 16 && newVersion >= 16) {
      // The syllable tier an attempt was produced at (null for pre-v16 attempts),
      // so the tier gate measures mastery within the CURRENT tier only. Same
      // column is created inline for fresh installs in [_createSchema].
      await db.execute(
          'ALTER TABLE exercise_attempts ADD COLUMN tier_at_attempt INTEGER');
    }
    if (oldVersion < 17 && newVersion >= 17) {
      // Caregiver "comfort cap" (low-energy days): the highest rung level the
      // auto-progression may advance a phrase to, or NULL for no cap. Limits
      // advancement only — never demotes. Same column inline in [_createSchema].
      await db.execute(
          'ALTER TABLE user_profiles ADD COLUMN session_rung_cap INTEGER');
    }
    if (oldVersion < 18 && newVersion >= 18) {
      // Presenter "demo mode" switch (default off): surfaces an in-session level
      // picker for live demonstrations. Same column inline in [_createSchema].
      await db.execute('ALTER TABLE user_profiles ADD COLUMN '
          'demo_mode_enabled INTEGER NOT NULL DEFAULT 0 '
          'CHECK(demo_mode_enabled IN (0,1))');
    }
    if (oldVersion < 19 && newVersion >= 19) {
      // Raw per-tap stream (ML logging audit item 16a). Same table is created
      // inline for fresh installs in [_createSchema] / [_createTapEventsTable].
      await _createTapEventsTable(db);
    }
    if (oldVersion < 20 && newVersion >= 20) {
      // Enrich the per-attempt acoustic log (ML logging audit items 16b/16c).
      // Same columns are created inline for fresh installs in [_createSchema].
      // All NULL for pre-v20 rows (they were never captured, not zero).
      //
      // `acoustic_feature_vectors` is created by [_createAnalysisTables], which
      // the v3 migration step also runs — so a v1/v2 → v20 upgrade builds the
      // table already carrying these columns, while a v3–v19 → v20 upgrade has
      // the older table and genuinely needs the ALTER. Guarding on the column's
      // existence makes both paths correct (and is a no-op when already present).
      await _addColumnIfMissing(
          db, 'acoustic_feature_vectors', 'mfcc_distance', 'mfcc_distance REAL');
      await _addColumnIfMissing(
          db, 'acoustic_feature_vectors', 'onset_ms', 'onset_ms TEXT');
      await _addColumnIfMissing(
          db, 'exercise_attempts', 'tempo_bpm', 'tempo_bpm INTEGER');
    }
    if (oldVersion < 21 && newVersion >= 21) {
      // Response-to-a-question step (R7, audit item 11): the per-phrase probe
      // question (text + optional recorded clip). Same columns inline in
      // [_createSchema]. NULL for phrases with no probe question set yet.
      await _addColumnIfMissing(db, 'practice_phrases', 'probe_question_text',
          'probe_question_text TEXT');
      await _addColumnIfMissing(db, 'practice_phrases',
          'probe_question_clip_path', 'probe_question_clip_path TEXT');
    }
    if (oldVersion < 22 && newVersion >= 22) {
      // Caregiver-designated high-note syllable (intonation flow, item A). Same
      // column inline in [_createSchema]. NULL until a guide is recorded with a
      // confirmed contour.
      await _addColumnIfMissing(
          db, 'practice_phrases', 'stress_index', 'stress_index INTEGER');
    }
    if (oldVersion < 23 && newVersion >= 23) {
      // Reconcile level with syllable count (audit item 12). The CASE mirrors
      // [levelForSyllableCount]: 1–3→1, 4–6→2, 7+→3.
      const levelExpr =
          'CASE WHEN syllable_count <= 3 THEN 1 WHEN syllable_count <= 6 THEN 2 ELSE 3 END';
      await db.execute(
          'UPDATE practice_phrases SET complexity_level = $levelExpr');
      // Seed each word's starting linguistic-load level from its syllable count,
      // but only for words the tier gate has NOT already raised (still at the
      // default tier 1) — so a longer phrase opens at a higher level while any
      // gate-earned tier is left untouched.
      await db.execute('''
        UPDATE progression_state SET syllable_tier = (
          SELECT CASE WHEN p.syllable_count <= 3 THEN 1
                      WHEN p.syllable_count <= 6 THEN 2 ELSE 3 END
          FROM practice_phrases p WHERE p.phrase_id = progression_state.phrase_id
        )
        WHERE syllable_tier = 1
          AND phrase_id IN (SELECT phrase_id FROM practice_phrases)
      ''');
    }
    if (oldVersion < 24 && newVersion >= 24) {
      // Scoped solo-mode switch (audit item 19, scaffold; default off). Same
      // column inline in [_createSchema].
      await _addColumnIfMissing(db, 'user_profiles', 'solo_mode_enabled',
          'solo_mode_enabled INTEGER NOT NULL DEFAULT 0 '
          'CHECK(solo_mode_enabled IN (0,1))');
    }
    if (oldVersion < 25 && newVersion >= 25) {
      // (a) Sprechgesang slow-spoken clip (audit item 15, scaffold). Same column
      // inline in [_createSchema]. NULL until a caregiver records one.
      await _addColumnIfMissing(db, 'practice_phrases', 'sprechgesang_clip_path',
          'sprechgesang_clip_path TEXT');
      // (b) Daily-summary read indexes (audit item 22): the per-attempt rollup
      // recompute joins attempts→sessions and filters by day; these make it a pair
      // of index lookups instead of full scans as history grows. Same indexes are
      // created for fresh installs in [_createDailySummaryReadIndexes].
      await _createDailySummaryReadIndexes(db);
    }
    if (oldVersion < 26 && newVersion >= 26) {
      // Progression refactor: clamp stored rungs to the active word ladder
      // [R2, R6]. R0/R1 are now the session warm-up and R7 is deferred, so no word
      // may sit there. Bump r0/r1 → R2 (unison entry); clamp r7 → R6 (solo).
      for (final table in ['practice_phrases', 'progression_state']) {
        await db.execute('UPDATE $table SET current_rung = 2 '
            'WHERE current_rung < 2');
        await db.execute('UPDATE $table SET current_rung = 6 '
            'WHERE current_rung > 6');
      }
    }
    if (oldVersion < 27 && newVersion >= 27) {
      // Starter word library (Part 3): the is_starter flag, then seed the library
      // for existing installs. Same column inline in [_createSchema]; the seed is
      // idempotent (guarded on the flag) so it never double-inserts.
      await _addColumnIfMissing(db, 'practice_phrases', 'is_starter',
          'is_starter INTEGER CHECK(is_starter IN (0,1)) DEFAULT 0');
      await _seedStarters(db);
    }
  }

  /// `ALTER TABLE … ADD COLUMN` only when [column] isn't already on [table].
  /// SQLite has no `ADD COLUMN IF NOT EXISTS`, and some shared table-creators run
  /// during migrations already carrying newer columns, so an unguarded ALTER can
  /// hit "duplicate column name" on certain upgrade paths. [ddl] is the column
  /// definition (e.g. `'tempo_bpm INTEGER'`).
  static Future<void> _addColumnIfMissing(
      Database db, String table, String column, String ddl) async {
    final cols = await db.rawQuery('PRAGMA table_info($table)');
    final exists = cols.any((c) => c['name'] == column);
    if (!exists) await db.execute('ALTER TABLE $table ADD COLUMN $ddl');
  }

  // --- Schema (Phase 1 subset, matching the build brief §6) ----------------

  /// Creates the four Phase-1 tables and inserts the starter data into an empty
  /// database. Called once, the first time the database file is created. It's
  /// public and static so tests can run it against an in-memory database.
  static Future<void> applyInitialSchema(Database db) async {
    await _createSchema(db);
    await _seed(db);
    await _seedStarters(db);
  }

  static Future<void> _createSchema(Database db) async {
    await db.execute('''
      CREATE TABLE user_profiles (
        profile_id               TEXT PRIMARY KEY NOT NULL,
        created_at               TEXT DEFAULT CURRENT_TIMESTAMP,
        metronome_bpm            INTEGER DEFAULT 60,
        preferred_hand           TEXT CHECK(preferred_hand IN ('LEFT','RIGHT')) DEFAULT 'LEFT',
        visual_enabled           INTEGER CHECK(visual_enabled IN (0,1)) DEFAULT 1,
        sound_enabled            INTEGER CHECK(sound_enabled IN (0,1)) DEFAULT 1,
        haptic_enabled           INTEGER CHECK(haptic_enabled IN (0,1)) DEFAULT 1,
        session_phrase_limit     INTEGER DEFAULT 10,
        guardian_consent_granted INTEGER CHECK(guardian_consent_granted IN (0,1)) DEFAULT 0,
        consent_timestamp        TEXT,
        consent_schema_version   TEXT,
        cloud_profile_id         TEXT,         -- cloud-sync: this profile's id in Supabase
        capture_silence_ms       INTEGER DEFAULT 4500,  -- recording window (silence before stop)
        auto_progress_enabled    INTEGER CHECK(auto_progress_enabled IN (0,1)) DEFAULT 1,  -- Phase 3 auto-progression on/off
        onboarding_seen          INTEGER CHECK(onboarding_seen IN (0,1)) DEFAULT 0,  -- first-run instructions shown
        target_display           TEXT CHECK(target_display IN ('picture','word','both')) DEFAULT 'picture',  -- how the word is shown
        playback_speed           REAL NOT NULL DEFAULT 1.0,  -- caregiver guide-speed multiplier (lower = slower)
        session_rung_cap         INTEGER,  -- caregiver comfort cap: max rung the auto-progression may reach (NULL = no cap)
        demo_mode_enabled        INTEGER CHECK(demo_mode_enabled IN (0,1)) DEFAULT 0,  -- presenter in-session level picker on/off
        solo_mode_enabled        INTEGER CHECK(solo_mode_enabled IN (0,1)) DEFAULT 0  -- scoped solo practice on/off (item 19, scaffold; advisory-only)
      )
    ''');

    await db.execute('''
      CREATE TABLE practice_phrases (
        phrase_id        INTEGER PRIMARY KEY AUTOINCREMENT,
        phrase_text      TEXT NOT NULL,
        word_count       INTEGER NOT NULL,
        syllable_count   INTEGER NOT NULL,
        complexity_level INTEGER NOT NULL,
        audio_asset_path TEXT,                    -- bundled fallback clip (rarely used)
        guide_clip_path  TEXT,                    -- AES-encrypted recorded guide = DTW reference
        guide_nuclei_ms  TEXT,                    -- CSV of confirmed syllable-nucleus timestamps (ms)
        current_rung     INTEGER NOT NULL DEFAULT 2,  -- MIT support/task ladder rung (0-7)
        photo_path       TEXT,                     -- AES-encrypted photo for name cards (§6)
        probe_question_text       TEXT,           -- v21: the R7 probe question the user answers with the phrase
        probe_question_clip_path  TEXT,           -- v21: AES-encrypted recorded probe question (TTS fallback on the text)
        stress_index     INTEGER,                  -- v22: caregiver-designated HIGH-note syllable (intonation flow)
        sprechgesang_clip_path    TEXT,            -- v25: slow-spoken speech-song clip (item 15, scaffold; L3 needs it)
        is_active        INTEGER CHECK(is_active IN (0,1)) DEFAULT 1,
        is_starter       INTEGER CHECK(is_starter IN (0,1)) DEFAULT 0  -- v27: starter word library (Part 3); presentation-only, never branches practice logic
      )
    ''');

    await db.execute('''
      CREATE TABLE practice_sessions (
        session_id  TEXT PRIMARY KEY NOT NULL,
        profile_id  TEXT NOT NULL,
        started_at  TEXT DEFAULT CURRENT_TIMESTAMP,
        synced_at   TEXT,                       -- cloud-sync: when pushed to Supabase (NULL = pending)
        FOREIGN KEY (profile_id) REFERENCES user_profiles(profile_id) ON DELETE CASCADE
      )
    ''');

    await db.execute('''
      CREATE TABLE exercise_attempts (
        attempt_id                    TEXT PRIMARY KEY NOT NULL,
        session_id                    TEXT NOT NULL,
        phrase_id                     INTEGER NOT NULL,
        timestamp                     TEXT DEFAULT CURRENT_TIMESTAMP,
        latency_ms                    INTEGER,
        duration_ms                   INTEGER,
        tapping_synchronization_score REAL,
        evaluation_label              INTEGER CHECK(evaluation_label IN (0,1,2)) DEFAULT 2,
        local_encrypted_audio_path    TEXT DEFAULT NULL,
        synced_at                     TEXT,     -- cloud-sync: when pushed to Supabase (NULL = pending)
        support_level                 INTEGER NOT NULL DEFAULT 2 CHECK(support_level IN (1,2,3,4)),
        rung_at_attempt               INTEGER,  -- Phase 3: MIT rung (0-6) this attempt was produced at (NULL pre-v8)
        tier_at_attempt               INTEGER,  -- Phase 3: syllable tier this attempt was produced at (NULL pre-v16)
        tempo_bpm                     INTEGER,  -- v20: metronome tempo at capture (beat reference for onset-vs-beat; NULL pre-v20)
        FOREIGN KEY (session_id) REFERENCES practice_sessions(session_id) ON DELETE CASCADE,
        FOREIGN KEY (phrase_id)  REFERENCES practice_phrases(phrase_id)
      )
    ''');

    await _createAnalysisTables(db);
    await _createProgressionTable(db);
    await _createDailySummaryTable(db);
    await _createTapEventsTable(db);
    await _createDailySummaryReadIndexes(db);
  }

  /// Indexes that speed the daily-summary recompute (audit item 22). The rollup
  /// runs after every saved attempt and joins `exercise_attempts` → `practice_
  /// sessions`, filtering by profile and a one-day timestamp range. Without these
  /// it is a full scan of every attempt ever made; with them it is a pair of
  /// index range lookups. Shared by fresh installs (above) and the v25 upgrade.
  static Future<void> _createDailySummaryReadIndexes(Database db) async {
    await db.execute('CREATE INDEX IF NOT EXISTS idx_attempts_session '
        'ON exercise_attempts(session_id)');
    await db.execute('CREATE INDEX IF NOT EXISTS idx_attempts_timestamp '
        'ON exercise_attempts(timestamp)');
    await db.execute('CREATE INDEX IF NOT EXISTS idx_sessions_profile '
        'ON practice_sessions(profile_id)');
  }

  /// The raw per-tap stream (ML logging audit item 16a): one row per tap, tied to
  /// the attempt/phrase/rung it belongs to. Stores the monotonic touch-down time,
  /// the press dwell (touch-down→up, NULL if the release was never observed), and
  /// the metronome phase at touch-down. This is the un-aggregated data the fatigue
  /// detector needs — dwell trend + inter-tap-interval variance — which the single
  /// `tapping_synchronization_score` on the attempt row cannot reconstruct.
  ///
  /// Unlike attempt audio, these are derived non-audio features, so the 48h audio
  /// eviction never touches them: the fine-grained stream is kept for later ML.
  /// Indexed by attempt (per-attempt read) and session (per-window fatigue read).
  static Future<void> _createTapEventsTable(Database db) async {
    await db.execute('''
      CREATE TABLE tap_events (
        tap_id      TEXT PRIMARY KEY NOT NULL,
        attempt_id  TEXT NOT NULL,
        phrase_id   INTEGER NOT NULL,
        session_id  TEXT NOT NULL,
        rung        INTEGER NOT NULL,   -- MIT rung (0-6) the tap was produced at
        tap_index   INTEGER NOT NULL,   -- 0-based order within the attempt
        down_ms     INTEGER NOT NULL,   -- monotonic touch-down time (ms since session start)
        dwell_ms    INTEGER,            -- press duration (touch-down→up); NULL if no release seen
        beat_phase  REAL,               -- metronome phase at touch-down (0..1); NULL if unknown
        FOREIGN KEY (attempt_id) REFERENCES exercise_attempts(attempt_id) ON DELETE CASCADE,
        FOREIGN KEY (phrase_id)  REFERENCES practice_phrases(phrase_id)
      )
    ''');
    await db.execute(
        'CREATE INDEX idx_tap_events_attempt ON tap_events(attempt_id)');
    await db.execute(
        'CREATE INDEX idx_tap_events_session ON tap_events(session_id)');
  }

  /// Per-(profile, day) metrics rollup: attempt counts, the Pass/Fail/Unsure
  /// split, and average content-similarity for the day. Display-only analytics
  /// for the caregiver/family dashboard; `synced_at` tracks the cloud push
  /// (NULL = pending). NEVER holds audio. Shared by fresh installs + upgrades.
  static Future<void> _createDailySummaryTable(Database db) async {
    await db.execute('''
      CREATE TABLE daily_summary (
        profile_id     TEXT NOT NULL,
        day            TEXT NOT NULL,            -- 'YYYY-MM-DD' (UTC)
        attempts       INTEGER NOT NULL DEFAULT 0,
        passes         INTEGER NOT NULL DEFAULT 0,
        fails          INTEGER NOT NULL DEFAULT 0,
        unsure         INTEGER NOT NULL DEFAULT 0,
        avg_similarity REAL,                     -- NULL if nothing scored that day
        synced_at      TEXT,                     -- NULL = pending cloud push
        PRIMARY KEY (profile_id, day),
        FOREIGN KEY (profile_id) REFERENCES user_profiles(profile_id) ON DELETE CASCADE
      )
    ''');
  }

  /// Phase 3 progression-state record, one row per (profile, phrase): the MIT
  /// rung, the syllable tier, and the within-rung tempo. Shared by fresh installs
  /// and upgrades so the two paths never drift (therapy addendum §4).
  static Future<void> _createProgressionTable(Database db) async {
    await db.execute('''
      CREATE TABLE progression_state (
        profile_id    TEXT NOT NULL,
        phrase_id     INTEGER NOT NULL,
        current_rung  INTEGER NOT NULL DEFAULT 2,   -- MIT support/task rung 0-6
        syllable_tier INTEGER NOT NULL DEFAULT 1,   -- linguistic load tier (1+)
        tempo_bpm     INTEGER NOT NULL DEFAULT 60,  -- within-rung tempo (40-70)
        PRIMARY KEY (profile_id, phrase_id),
        FOREIGN KEY (profile_id) REFERENCES user_profiles(profile_id) ON DELETE CASCADE,
        FOREIGN KEY (phrase_id)  REFERENCES practice_phrases(phrase_id) ON DELETE CASCADE
      )
    ''');
  }

  /// Phase 2A analysis tables (brief §4/§5). Shared by fresh installs
  /// ([_createSchema]) and upgrades ([migrate]) so the two paths never drift.
  static Future<void> _createAnalysisTables(Database db) async {
    // Per-attempt analysis output: the junk-gate verdict and (if it passed) the
    // content-similarity score. content_similarity_score is NULL when the gate
    // rejected the clip.
    await db.execute('''
      CREATE TABLE acoustic_feature_vectors (
        vector_id                TEXT PRIMARY KEY NOT NULL,
        attempt_id               TEXT NOT NULL UNIQUE,
        content_similarity_score REAL,
        mfcc_distance            REAL,     -- v20: raw normalized DTW cost behind the similarity (item 16b)
        gate_passed              INTEGER CHECK(gate_passed IN (0,1)) NOT NULL,
        gate_reason              TEXT,
        duration_ms              INTEGER,
        onset_ms                 TEXT,     -- v20: CSV of the patient's detected syllable onsets, ms (item 16c)
        FOREIGN KEY (attempt_id) REFERENCES exercise_attempts(attempt_id) ON DELETE CASCADE
      )
    ''');

    // One anchor template per (profile, phrase): the MFCC sequence of a
    // caregiver-confirmed attempt, stored as derived features — NOT raw audio,
    // so the 48h audio eviction never touches it.
    await db.execute('''
      CREATE TABLE phrase_anchor_templates (
        anchor_id          TEXT PRIMARY KEY NOT NULL,
        profile_id         TEXT NOT NULL,
        phrase_id          INTEGER NOT NULL,
        mfcc_frames        BLOB NOT NULL,
        frame_count        INTEGER NOT NULL,
        coeff_count        INTEGER NOT NULL,
        score_vs_reference REAL,
        source_attempt_id  TEXT,
        confirmed_at       TEXT DEFAULT CURRENT_TIMESTAMP,
        UNIQUE(profile_id, phrase_id),
        FOREIGN KEY (profile_id) REFERENCES user_profiles(profile_id) ON DELETE CASCADE,
        -- Deleting a phrase cascades its anchors too (brief §4.4). Phrases are
        -- normally toggled via is_active rather than deleted, but this keeps the
        -- schema matching the stated intent and avoids dangling anchors.
        FOREIGN KEY (phrase_id)  REFERENCES practice_phrases(phrase_id) ON DELETE CASCADE
      )
    ''');
  }

  // --- Seed data (brief §7 starter word list) ------------------------------

  /// The single local user. For this prototype there's exactly one profile, so
  /// we give it a fixed, well-known id instead of a random one.
  static const defaultProfileId = 'local_profile';

  static Future<void> _seed(Database db) async {
    // Create the one local profile. The schema fills in every other column with
    // its default (60 BPM, all channels on, consent = false, etc.).
    await db.insert('user_profiles', {'profile_id': defaultProfileId});

    // Starter phrases. Each tuple is:
    //   [text, word_count, syllable_count, is_active]
    // complexity_level is DERIVED from syllable_count (audit item 12,
    // levelForSyllableCount: 1–3→L1, 4–6→L2, 7+→L3) rather than hand-assigned, so
    // a phrase's level always matches its real syllable count. Most starter words
    // are short (L1); two longer phrases seed L2/L3 examples. is_active is explicit
    // (a small single-syllable starter set is on) — it's no longer tied to level,
    // since under the syllable-count mapping nearly every short word is L1.
    const seedPhrases = <List<Object>>[
      // Single-syllable core words (active by default → a short first session).
      ['Help', 1, 1, 1],
      ['Pain', 1, 1, 1],
      ['More', 1, 1, 1],
      ['Stop', 1, 1, 1],
      ['Water', 1, 2, 1],
      // Short words (L1), off by default — the caregiver enables them as ready.
      ['Bathroom', 1, 2, 0],
      ['Hungry', 1, 2, 0],
      ['Medicine', 1, 3, 0],
      ['Sleepy', 1, 2, 0],
      ['Thank you', 2, 2, 0],
      ['I want food', 3, 3, 0],
      ['Sit down', 2, 2, 0],
      ['I love you', 3, 3, 0],
      // Longer phrases so L2 / L3 exist out of the box (off by default).
      ['Can you help me', 4, 4, 0], // 4 syllables → L2
      ['I would like to go home now', 7, 7, 0], // 7 syllables → L3
    ];

    // A batch sends all inserts in one trip for speed. Only the single-syllable
    // starter words are active by default, so a first session is short and
    // intentional (~5 words); the caregiver enables more from settings.
    final batch = db.batch();
    for (final row in seedPhrases) {
      final syllables = row[2] as int;
      // Mirror levelForSyllableCount (kept inline to avoid a data→practice import).
      final level = syllables <= 3 ? 1 : (syllables <= 6 ? 2 : 3);
      batch.insert('practice_phrases', {
        'phrase_text': row[0],
        'word_count': row[1],
        'syllable_count': syllables,
        'complexity_level': level,
        'audio_asset_path': null, // filled in when we add the audio guide
        'is_active': row[3],
      });
    }
    await batch.commit(noResult: true);
  }

  /// Seeds the starter word library (Part 3) — idempotently. Only inserts when no
  /// starter rows exist yet, so it's safe on both a fresh install and the v27
  /// upgrade, and a no-op on every later launch. The bundled guide clip itself is
  /// installed at runtime by `StarterGuideInstaller` (it needs the per-install
  /// encryption key + filesystem); here we seed only the phrase metadata.
  static Future<void> _seedStarters(Database db) async {
    final rows = await db.rawQuery(
        'SELECT COUNT(*) AS n FROM practice_phrases WHERE is_starter = 1');
    final existing = (rows.first['n'] as int?) ?? 0;
    if (existing > 0) return;

    final batch = db.batch();
    for (final s in starterLibrary) {
      // Only columns guaranteed on both fresh and v1-upgraded schemas — the
      // seeder also runs from the v27 migration, where audio_asset_path (a
      // fresh-install-only column) doesn't exist. It's nullable regardless.
      batch.insert('practice_phrases', {
        'phrase_text': s.text,
        'word_count': s.wordCount,
        'syllable_count': s.syllableCount,
        'complexity_level': s.complexityLevel,
        'guide_nuclei_ms': s.nucleiMs.join(','),
        'stress_index': s.stressIndex,
        'is_active': s.activeByDefault ? 1 : 0,
        'is_starter': 1,
      });
    }
    await batch.commit(noResult: true);
  }
}
