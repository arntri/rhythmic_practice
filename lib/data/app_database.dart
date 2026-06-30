import 'dart:io' show Platform;

import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';
// Importing sqflite registers the native database factory used on Android/iOS.
// The analyzer thinks it's unnecessary because sqflite_common_ffi re-exports the
// same types, but that package only covers desktop — we need both.
// ignore: unnecessary_import
import 'package:sqflite/sqflite.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

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
  static const _schemaVersion = 18;

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
  }

  // --- Schema (Phase 1 subset, matching the build brief §6) ----------------

  /// Creates the four Phase-1 tables and inserts the starter data into an empty
  /// database. Called once, the first time the database file is created. It's
  /// public and static so tests can run it against an in-memory database.
  static Future<void> applyInitialSchema(Database db) async {
    await _createSchema(db);
    await _seed(db);
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
        demo_mode_enabled        INTEGER CHECK(demo_mode_enabled IN (0,1)) DEFAULT 0  -- presenter in-session level picker on/off
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
        current_rung     INTEGER NOT NULL DEFAULT 2,  -- MIT support/task ladder rung (0-6)
        photo_path       TEXT,                     -- AES-encrypted photo for name cards (§6)
        is_active        INTEGER CHECK(is_active IN (0,1)) DEFAULT 1
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
        FOREIGN KEY (session_id) REFERENCES practice_sessions(session_id) ON DELETE CASCADE,
        FOREIGN KEY (phrase_id)  REFERENCES practice_phrases(phrase_id)
      )
    ''');

    await _createAnalysisTables(db);
    await _createProgressionTable(db);
    await _createDailySummaryTable(db);
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
        gate_passed              INTEGER CHECK(gate_passed IN (0,1)) NOT NULL,
        gate_reason              TEXT,
        duration_ms              INTEGER,
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
    //   [text, word_count, syllable_count, complexity_level]
    // complexity_level follows the brief's grouping (1/2/3). Note: a couple of
    // the brief's level-1/level-2 words actually have an extra spoken syllable
    // (e.g. "Water" = 2, "Medicine" = 3), so syllable_count reflects the true
    // count while complexity_level keeps the brief's intended grouping.
    const seedPhrases = <List<Object>>[
      // Level 1 — single-syllable words
      ['Help', 1, 1, 1],
      ['Pain', 1, 1, 1],
      ['More', 1, 1, 1],
      ['Stop', 1, 1, 1],
      ['Water', 1, 2, 1],
      // Level 2 — two-syllable words
      ['Bathroom', 1, 2, 2],
      ['Hungry', 1, 2, 2],
      ['Medicine', 1, 3, 2],
      ['Sleepy', 1, 2, 2],
      ['Thank you', 2, 2, 2],
      // Level 3 — short phrases
      ['I want food', 3, 3, 3],
      ['Sit down', 2, 2, 3],
      ['I love you', 3, 3, 3],
    ];

    // A batch sends all inserts in one trip for speed. Only the level-1 starter
    // words are active by default, so a first session is short and intentional
    // (~5 words); the caregiver enables more from settings as the user is ready.
    final batch = db.batch();
    for (final row in seedPhrases) {
      final level = row[3] as int;
      batch.insert('practice_phrases', {
        'phrase_text': row[0],
        'word_count': row[1],
        'syllable_count': row[2],
        'complexity_level': level,
        'audio_asset_path': null, // filled in when we add the audio guide
        'is_active': level == 1 ? 1 : 0,
      });
    }
    await batch.commit(noResult: true);
  }
}
