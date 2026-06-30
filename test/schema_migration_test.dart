// Migration test (Phase 2A step 6). We build a real v1 (original Phase 1)
// database on disk, seed a row, then reopen it at the current version so the
// actual AppDatabase.migrate runs — and verify the v3 analysis schema landed
// without losing the old data. File-based (not in-memory) because the upgrade
// path requires closing and reopening the same database file.

import 'dart:io';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

import 'package:rhythmic_practice/data/app_database.dart';

/// The original Phase 1 (v1) schema: no cloud columns, no support_level, no
/// analysis tables. Kept minimal — just enough to migrate and seed.
Future<void> createV1Schema(Database db) async {
  await db.execute('''
    CREATE TABLE user_profiles (
      profile_id    TEXT PRIMARY KEY NOT NULL,
      metronome_bpm INTEGER DEFAULT 60
    )
  ''');
  await db.execute('''
    CREATE TABLE practice_phrases (
      phrase_id        INTEGER PRIMARY KEY AUTOINCREMENT,
      phrase_text      TEXT NOT NULL,
      word_count       INTEGER NOT NULL,
      syllable_count   INTEGER NOT NULL,
      complexity_level INTEGER NOT NULL,
      is_active        INTEGER DEFAULT 1
    )
  ''');
  await db.execute('''
    CREATE TABLE practice_sessions (
      session_id TEXT PRIMARY KEY NOT NULL,
      profile_id TEXT NOT NULL,
      started_at TEXT DEFAULT CURRENT_TIMESTAMP
    )
  ''');
  await db.execute('''
    CREATE TABLE exercise_attempts (
      attempt_id       TEXT PRIMARY KEY NOT NULL,
      session_id       TEXT NOT NULL,
      phrase_id        INTEGER NOT NULL,
      timestamp        TEXT DEFAULT CURRENT_TIMESTAMP,
      evaluation_label INTEGER DEFAULT 2
    )
  ''');
}

void main() {
  setUpAll(sqfliteFfiInit);

  late Directory dir;
  late String path;

  setUp(() async {
    dir = await Directory.systemTemp.createTemp('migration_test');
    path = '${dir.path}/m.db';
  });

  tearDown(() async {
    if (dir.existsSync()) await dir.delete(recursive: true);
  });

  test('v1 database migrates to v3: new tables + support_level, data preserved',
      () async {
    // 1. Create a v1 database and seed one attempt.
    final v1 = await databaseFactoryFfi.openDatabase(
      path,
      options: OpenDatabaseOptions(
        version: 1,
        onConfigure: (db) => db.execute('PRAGMA foreign_keys = ON'),
        onCreate: (db, v) => createV1Schema(db),
      ),
    );
    await v1.insert('user_profiles', {'profile_id': 'p1'});
    final phraseId = await v1.insert('practice_phrases', {
      'phrase_text': 'Help',
      'word_count': 1,
      'syllable_count': 1,
      'complexity_level': 1,
    });
    await v1.insert('practice_sessions', {
      'session_id': 's1',
      'profile_id': 'p1',
    });
    await v1.insert('exercise_attempts', {
      'attempt_id': 'a1',
      'session_id': 's1',
      'phrase_id': phraseId,
      'evaluation_label': 1,
    });
    await v1.close();

    // 2. Reopen at the current version -> the real migration runs.
    final db = await databaseFactoryFfi.openDatabase(
      path,
      options: OpenDatabaseOptions(
        version: 3,
        onConfigure: (db) => db.execute('PRAGMA foreign_keys = ON'),
        onUpgrade: AppDatabase.migrate,
      ),
    );
    addTearDown(db.close);

    // 3a. The old row survived AND picked up support_level's default of 2.
    final rows = await db.query('exercise_attempts', where: 'attempt_id = ?',
        whereArgs: ['a1']);
    expect(rows.length, 1);
    expect(rows.single['evaluation_label'], 1); // original data intact
    expect(rows.single['support_level'], 2); // new column, default applied
    // The v<2 cloud columns also exist now.
    expect(rows.single.containsKey('synced_at'), isTrue);

    // 3b. The two new analysis tables exist and accept rows.
    await db.insert('acoustic_feature_vectors', {
      'vector_id': 'v1',
      'attempt_id': 'a1',
      'gate_passed': 1,
      'gate_reason': 'ok',
      'content_similarity_score': 0.9,
      'duration_ms': 1000,
    });
    expect(
        (await db.query('acoustic_feature_vectors')).single['gate_reason'], 'ok');

    await db.insert('phrase_anchor_templates', {
      'anchor_id': 'an1',
      'profile_id': 'p1',
      'phrase_id': phraseId,
      'mfcc_frames': Uint8List.fromList([0, 1, 2, 3, 4, 5, 6, 7]), // 1 float64
      'frame_count': 0,
      'coeff_count': 0,
    });
    expect((await db.query('phrase_anchor_templates')).length, 1);

    // 3c. support_level rejects out-of-range values (CHECK survived migration).
    expect(
      () => db.insert('exercise_attempts', {
        'attempt_id': 'bad',
        'session_id': 's1',
        'phrase_id': phraseId,
        'support_level': 9,
      }),
      throwsA(isA<DatabaseException>()),
    );
  });

  test('v3 → v6 adds guide cols + capture_silence_ms, preserving phrase data',
      () async {
    // A v3-style schema (practice_phrases without guide cols, profiles without
    // capture_silence_ms).
    final v3 = await databaseFactoryFfi.openDatabase(
      path,
      options: OpenDatabaseOptions(
        version: 3,
        onCreate: (db, v) async {
          await db.execute('''
            CREATE TABLE practice_phrases (
              phrase_id        INTEGER PRIMARY KEY AUTOINCREMENT,
              phrase_text      TEXT NOT NULL,
              word_count       INTEGER NOT NULL,
              syllable_count   INTEGER NOT NULL,
              complexity_level INTEGER NOT NULL,
              audio_asset_path TEXT,
              is_active        INTEGER DEFAULT 1
            )
          ''');
          await db.execute('''
            CREATE TABLE user_profiles (
              profile_id    TEXT PRIMARY KEY NOT NULL,
              metronome_bpm INTEGER DEFAULT 60
            )
          ''');
        },
      ),
    );
    final id = await v3.insert('practice_phrases', {
      'phrase_text': 'Water',
      'word_count': 1,
      'syllable_count': 2,
      'complexity_level': 1,
    });
    await v3.insert('user_profiles', {'profile_id': 'p1'});
    await v3.close();

    // Reopen at v7 -> the real migration adds the new columns.
    final db = await databaseFactoryFfi.openDatabase(
      path,
      options: OpenDatabaseOptions(
        version: 7,
        onUpgrade: AppDatabase.migrate,
      ),
    );
    addTearDown(db.close);

    final row = (await db
            .query('practice_phrases', where: 'phrase_id = ?', whereArgs: [id]))
        .single;
    expect(row['phrase_text'], 'Water'); // data preserved
    expect(row['syllable_count'], 2);
    expect(row.containsKey('guide_clip_path'), isTrue);
    expect(row.containsKey('guide_nuclei_ms'), isTrue);
    expect(row['current_rung'], 2); // v7 rung column, default unison

    final prof = (await db.query('user_profiles')).single;
    expect(prof.containsKey('capture_silence_ms'), isTrue);
    expect(prof['capture_silence_ms'], 4500); // default applied
  });

  test('fresh install (applyInitialSchema) has the v7 columns', () async {
    final db = await databaseFactoryFfi.openDatabase(
      inMemoryDatabasePath,
      options: OpenDatabaseOptions(
        version: 7,
        onConfigure: (db) => db.execute('PRAGMA foreign_keys = ON'),
        onCreate: (db, v) => AppDatabase.applyInitialSchema(db),
      ),
    );
    addTearDown(db.close);
    expect((await db.query('user_profiles')).first['capture_silence_ms'], 4500);
    expect((await db.query('practice_phrases', limit: 1)).first['current_rung'], 2);
    final phrase = (await db.query('practice_phrases', limit: 1)).first;
    expect(phrase.containsKey('guide_clip_path'), isTrue);
    expect(phrase.containsKey('guide_nuclei_ms'), isTrue);
  });

  test('v1 → v8 adds auto-progression columns, preserving attempt data',
      () async {
    // A real v1 database (createV1Schema has exercise_attempts) with one attempt.
    final v1 = await databaseFactoryFfi.openDatabase(
      path,
      options: OpenDatabaseOptions(
        version: 1,
        onConfigure: (db) => db.execute('PRAGMA foreign_keys = ON'),
        onCreate: (db, v) => createV1Schema(db),
      ),
    );
    await v1.insert('user_profiles', {'profile_id': 'p1'});
    final phraseId = await v1.insert('practice_phrases', {
      'phrase_text': 'Help',
      'word_count': 1,
      'syllable_count': 1,
      'complexity_level': 1,
    });
    await v1.insert('practice_sessions', {'session_id': 's1', 'profile_id': 'p1'});
    await v1.insert('exercise_attempts', {
      'attempt_id': 'a1',
      'session_id': 's1',
      'phrase_id': phraseId,
      'evaluation_label': 1,
    });
    await v1.close();

    // Reopen at the current version → the real migration adds the v8 columns.
    final db = await databaseFactoryFfi.openDatabase(
      path,
      options: OpenDatabaseOptions(
        version: 8,
        onConfigure: (db) => db.execute('PRAGMA foreign_keys = ON'),
        onUpgrade: AppDatabase.migrate,
      ),
    );
    addTearDown(db.close);

    final attempt = (await db
            .query('exercise_attempts', where: 'attempt_id = ?', whereArgs: ['a1']))
        .single;
    expect(attempt['evaluation_label'], 1); // original data intact
    expect(attempt.containsKey('rung_at_attempt'), isTrue);
    expect(attempt['rung_at_attempt'], isNull); // pre-v8 attempts have no rung

    final prof = (await db.query('user_profiles')).single;
    expect(prof['auto_progress_enabled'], 1); // default on
  });

  test('v1 → v9 adds photo_path on practice_phrases', () async {
    final v1 = await databaseFactoryFfi.openDatabase(
      path,
      options: OpenDatabaseOptions(
        version: 1,
        onConfigure: (db) => db.execute('PRAGMA foreign_keys = ON'),
        onCreate: (db, v) => createV1Schema(db),
      ),
    );
    final phraseId = await v1.insert('practice_phrases', {
      'phrase_text': 'Sarah',
      'word_count': 1,
      'syllable_count': 2,
      'complexity_level': 3,
    });
    await v1.close();

    final db = await databaseFactoryFfi.openDatabase(
      path,
      options: OpenDatabaseOptions(
        version: 9,
        onConfigure: (db) => db.execute('PRAGMA foreign_keys = ON'),
        onUpgrade: AppDatabase.migrate,
      ),
    );
    addTearDown(db.close);

    final row = (await db
            .query('practice_phrases', where: 'phrase_id = ?', whereArgs: [phraseId]))
        .single;
    expect(row['phrase_text'], 'Sarah'); // data preserved
    expect(row.containsKey('photo_path'), isTrue);
    expect(row['photo_path'], isNull); // no photo until one is attached
  });

  test('v1 → v10 adds onboarding_seen on user_profiles, default 0', () async {
    final v1 = await databaseFactoryFfi.openDatabase(
      path,
      options: OpenDatabaseOptions(
        version: 1,
        onConfigure: (db) => db.execute('PRAGMA foreign_keys = ON'),
        onCreate: (db, v) => createV1Schema(db),
      ),
    );
    await v1.insert('user_profiles', {'profile_id': 'p1'});
    await v1.close();

    final db = await databaseFactoryFfi.openDatabase(
      path,
      options: OpenDatabaseOptions(
        version: 10,
        onConfigure: (db) => db.execute('PRAGMA foreign_keys = ON'),
        onUpgrade: AppDatabase.migrate,
      ),
    );
    addTearDown(db.close);

    final prof = (await db.query('user_profiles')).single;
    expect(prof.containsKey('onboarding_seen'), isTrue);
    expect(prof['onboarding_seen'], 0); // not seen until the home shows it
  });

  test('v1 → v11 adds the progression_state table', () async {
    final v1 = await databaseFactoryFfi.openDatabase(
      path,
      options: OpenDatabaseOptions(
        version: 1,
        onConfigure: (db) => db.execute('PRAGMA foreign_keys = ON'),
        onCreate: (db, v) => createV1Schema(db),
      ),
    );
    await v1.insert('user_profiles', {'profile_id': 'p1'});
    final phraseId = await v1.insert('practice_phrases', {
      'phrase_text': 'Help',
      'word_count': 1,
      'syllable_count': 1,
      'complexity_level': 1,
    });
    await v1.close();

    final db = await databaseFactoryFfi.openDatabase(
      path,
      options: OpenDatabaseOptions(
        version: 11,
        onConfigure: (db) => db.execute('PRAGMA foreign_keys = ON'),
        onUpgrade: AppDatabase.migrate,
      ),
    );
    addTearDown(db.close);

    // The table exists and accepts a row referencing the migrated phrase/profile.
    await db.insert('progression_state', {
      'profile_id': 'p1',
      'phrase_id': phraseId,
      'current_rung': 4,
      'syllable_tier': 2,
      'tempo_bpm': 50,
    });
    final row = (await db.query('progression_state')).single;
    expect(row['current_rung'], 4);
    expect(row['syllable_tier'], 2);
    expect(row['tempo_bpm'], 50);
  });

  test('v1 → v12 adds target_display defaulting to picture', () async {
    final v1 = await databaseFactoryFfi.openDatabase(
      path,
      options: OpenDatabaseOptions(
        version: 1,
        onConfigure: (db) => db.execute('PRAGMA foreign_keys = ON'),
        onCreate: (db, v) => createV1Schema(db),
      ),
    );
    await v1.insert('user_profiles', {'profile_id': 'p1'});
    await v1.close();

    final db = await databaseFactoryFfi.openDatabase(
      path,
      options: OpenDatabaseOptions(
        version: 12,
        onConfigure: (db) => db.execute('PRAGMA foreign_keys = ON'),
        onUpgrade: AppDatabase.migrate,
      ),
    );
    addTearDown(db.close);

    expect((await db.query('user_profiles')).single['target_display'], 'picture');
  });

  test('v1 → v13 adds the daily_summary table', () async {
    final v1 = await databaseFactoryFfi.openDatabase(
      path,
      options: OpenDatabaseOptions(
        version: 1,
        onConfigure: (db) => db.execute('PRAGMA foreign_keys = ON'),
        onCreate: (db, v) => createV1Schema(db),
      ),
    );
    await v1.insert('user_profiles', {'profile_id': 'p1'});
    await v1.close();

    final db = await databaseFactoryFfi.openDatabase(
      path,
      options: OpenDatabaseOptions(
        version: 13,
        onConfigure: (db) => db.execute('PRAGMA foreign_keys = ON'),
        onUpgrade: AppDatabase.migrate,
      ),
    );
    addTearDown(db.close);

    await db.insert('daily_summary', {
      'profile_id': 'p1',
      'day': '2026-06-14',
      'attempts': 3,
      'passes': 2,
      'fails': 1,
      'unsure': 0,
      'avg_similarity': 0.7,
    });
    final row = (await db.query('daily_summary')).single;
    expect(row['attempts'], 3);
    expect(row['passes'], 2);
    expect(row['synced_at'], isNull); // pending push
  });

  test('v1 → v14 adds playback_speed defaulting to 1.0', () async {
    final v1 = await databaseFactoryFfi.openDatabase(
      path,
      options: OpenDatabaseOptions(
        version: 1,
        onConfigure: (db) => db.execute('PRAGMA foreign_keys = ON'),
        onCreate: (db, v) => createV1Schema(db),
      ),
    );
    await v1.insert('user_profiles', {'profile_id': 'p1'});
    await v1.close();

    final db = await databaseFactoryFfi.openDatabase(
      path,
      options: OpenDatabaseOptions(
        version: 14,
        onConfigure: (db) => db.execute('PRAGMA foreign_keys = ON'),
        onUpgrade: AppDatabase.migrate,
      ),
    );
    addTearDown(db.close);
    expect((await db.query('user_profiles')).single['playback_speed'], 1.0);
  });

  test('fresh install (applyInitialSchema) already has the v3 tables', () async {
    final db = await databaseFactoryFfi.openDatabase(
      inMemoryDatabasePath,
      options: OpenDatabaseOptions(
        version: 3,
        onConfigure: (db) => db.execute('PRAGMA foreign_keys = ON'),
        onCreate: (db, v) => AppDatabase.applyInitialSchema(db),
      ),
    );
    addTearDown(db.close);

    // Both analysis tables queryable from a clean create.
    expect(await db.query('acoustic_feature_vectors'), isEmpty);
    expect(await db.query('phrase_anchor_templates'), isEmpty);
    // support_level present with default 2 on a freshly inserted attempt.
    final phraseId = (await db.query('practice_phrases', limit: 1))
        .first['phrase_id'] as int;
    await db.insert('practice_sessions',
        {'session_id': 's', 'profile_id': AppDatabase.defaultProfileId});
    await db.insert('exercise_attempts', {
      'attempt_id': 'a',
      'session_id': 's',
      'phrase_id': phraseId,
    });
    final a = (await db.query('exercise_attempts')).single;
    expect(a['support_level'], 2);
  });

  test('v14 → v15 resets legacy-inflated rungs but keeps controller-managed ones',
      () async {
    // Build the current schema but stamp it as v14, so reopening triggers only
    // the v15 reconcile step.
    final v14 = await databaseFactoryFfi.openDatabase(
      path,
      options: OpenDatabaseOptions(
        version: 14,
        onConfigure: (db) => db.execute('PRAGMA foreign_keys = ON'),
        onCreate: (db, v) => AppDatabase.applyInitialSchema(db),
      ),
    );
    // A word stranded at R6 by the removed per-attempt engine (NO progression
    // record) — should be reset to the unison default.
    final legacyId = await v14.insert('practice_phrases', {
      'phrase_text': 'Legacy',
      'word_count': 1,
      'syllable_count': 1,
      'complexity_level': 1,
      'current_rung': 6,
    });
    // A word the live block controller manages (HAS a progression record at R5,
    // mirrored to current_rung) — must be left untouched.
    final managedId = await v14.insert('practice_phrases', {
      'phrase_text': 'Managed',
      'word_count': 1,
      'syllable_count': 1,
      'complexity_level': 1,
      'current_rung': 5,
    });
    await v14.insert('progression_state', {
      'profile_id': AppDatabase.defaultProfileId,
      'phrase_id': managedId,
      'current_rung': 5,
      'syllable_tier': 1,
      'tempo_bpm': 60,
    });
    await v14.close();

    final db = await databaseFactoryFfi.openDatabase(
      path,
      options: OpenDatabaseOptions(
        version: 15,
        onConfigure: (db) => db.execute('PRAGMA foreign_keys = ON'),
        onUpgrade: AppDatabase.migrate,
      ),
    );
    addTearDown(db.close);

    final legacy = (await db.query('practice_phrases',
            where: 'phrase_id = ?', whereArgs: [legacyId]))
        .single;
    expect(legacy['current_rung'], 2); // legacy R6 reset to unison

    final managed = (await db.query('practice_phrases',
            where: 'phrase_id = ?', whereArgs: [managedId]))
        .single;
    expect(managed['current_rung'], 5); // controller-managed rung preserved
  });

  test('v1 → v16 adds tier_at_attempt on exercise_attempts (NULL for old rows)',
      () async {
    final v1 = await databaseFactoryFfi.openDatabase(
      path,
      options: OpenDatabaseOptions(
        version: 1,
        onConfigure: (db) => db.execute('PRAGMA foreign_keys = ON'),
        onCreate: (db, v) => createV1Schema(db),
      ),
    );
    await v1.insert('user_profiles', {'profile_id': 'p1'});
    final phraseId = await v1.insert('practice_phrases', {
      'phrase_text': 'Help',
      'word_count': 1,
      'syllable_count': 1,
      'complexity_level': 1,
    });
    await v1.insert('practice_sessions', {'session_id': 's1', 'profile_id': 'p1'});
    await v1.insert('exercise_attempts', {
      'attempt_id': 'a1',
      'session_id': 's1',
      'phrase_id': phraseId,
      'evaluation_label': 1,
    });
    await v1.close();

    final db = await databaseFactoryFfi.openDatabase(
      path,
      options: OpenDatabaseOptions(
        version: 16,
        onConfigure: (db) => db.execute('PRAGMA foreign_keys = ON'),
        onUpgrade: AppDatabase.migrate,
      ),
    );
    addTearDown(db.close);

    final attempt = (await db.query('exercise_attempts',
            where: 'attempt_id = ?', whereArgs: ['a1']))
        .single;
    expect(attempt.containsKey('tier_at_attempt'), isTrue);
    expect(attempt['tier_at_attempt'], isNull); // pre-v16 attempts have no tier
  });

  test('v1 → v17 adds session_rung_cap defaulting to NULL (no cap)', () async {
    final v1 = await databaseFactoryFfi.openDatabase(
      path,
      options: OpenDatabaseOptions(
        version: 1,
        onConfigure: (db) => db.execute('PRAGMA foreign_keys = ON'),
        onCreate: (db, v) => createV1Schema(db),
      ),
    );
    await v1.insert('user_profiles', {'profile_id': 'p1'});
    await v1.close();

    final db = await databaseFactoryFfi.openDatabase(
      path,
      options: OpenDatabaseOptions(
        version: 17,
        onConfigure: (db) => db.execute('PRAGMA foreign_keys = ON'),
        onUpgrade: AppDatabase.migrate,
      ),
    );
    addTearDown(db.close);
    final row = (await db.query('user_profiles')).single;
    expect(row.containsKey('session_rung_cap'), isTrue);
    expect(row['session_rung_cap'], isNull); // no cap by default
  });
}
