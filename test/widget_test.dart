// Step 1 test: verify the database schema is valid and seeds the starter data.
//
// We run the real schema/seed code (AppDatabase.applyInitialSchema) against an
// in-memory SQLite database via the FFI backend, so the test needs no device,
// no files, and leaves nothing behind.

import 'package:flutter_test/flutter_test.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

import 'package:rhythmic_practice/data/app_database.dart';

void main() {
  setUpAll(sqfliteFfiInit);

  test('schema creates the four tables and seeds starter data', () async {
    final db = await databaseFactoryFfi.openDatabase(
      inMemoryDatabasePath,
      options: OpenDatabaseOptions(
        version: 1,
        onConfigure: (db) => db.execute('PRAGMA foreign_keys = ON'),
        onCreate: (db, version) => AppDatabase.applyInitialSchema(db),
      ),
    );

    // One default profile, set to the documented defaults.
    final profiles = await db.query('user_profiles');
    expect(profiles.length, 1);
    expect(profiles.first['profile_id'], AppDatabase.defaultProfileId);
    expect(profiles.first['metronome_bpm'], 60);

    // All 13 starter phrases were inserted; only the 5 level-1 words start
    // active, so a first session is short and intentional (UX overhaul).
    final phrases = await db.query('practice_phrases');
    expect(phrases.length, 13);

    final active = await db.query('practice_phrases', where: 'is_active = 1');
    expect(active.length, 5);

    // The other two tables exist and start empty.
    expect((await db.query('practice_sessions')).length, 0);
    expect((await db.query('exercise_attempts')).length, 0);

    await db.close();
  });
}
