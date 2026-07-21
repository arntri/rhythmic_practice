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

    // 15 generic seed phrases (is_starter = 0) + the 10-word starter library
    // (is_starter = 1, Part 3) = 25 rows.
    final phrases = await db.query('practice_phrases');
    expect(phrases.length, 25);
    final generic =
        await db.query('practice_phrases', where: 'is_starter = 0');
    expect(generic.length, 15);
    final starters =
        await db.query('practice_phrases', where: 'is_starter = 1');
    expect(starters.length, 10);

    // 5 single-syllable generic words start active + 4 starter essentials
    // (Water/Hello/Yes/No) = 9, so a first session is short and intentional.
    final active = await db.query('practice_phrases', where: 'is_active = 1');
    expect(active.length, 9);

    // complexity_level is derived from syllable_count (item 12): the seeded
    // longer phrases are L2 (4–6 syllables) and L3 (7+).
    final l2 = await db.query('practice_phrases',
        where: 'phrase_text = ?', whereArgs: ['Can you help me']);
    expect(l2.single['complexity_level'], 2);
    final l3 = await db.query('practice_phrases',
        where: 'phrase_text = ?', whereArgs: ['I would like to go home now']);
    expect(l3.single['complexity_level'], 3);

    // The other two tables exist and start empty.
    expect((await db.query('practice_sessions')).length, 0);
    expect((await db.query('exercise_attempts')).length, 0);

    await db.close();
  });
}
