// Step 1 test: verify the database schema is valid and seeds the starter data.
//
// We run the real schema/seed code (AppDatabase.applyInitialSchema) against an
// in-memory SQLite database via the FFI backend, so the test needs no device,
// no files, and leaves nothing behind.

import 'package:flutter_test/flutter_test.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

import 'package:rhythmic_practice/data/app_database.dart';
import 'package:rhythmic_practice/data/starter_library.dart';

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

    // The clip-backed starter library (is_starter = 1) plus the seeded phrases
    // it doesn't ship (is_starter = 0). The two lists are disjoint by design —
    // both insert into this table, so an overlap would be a duplicate phrase in
    // the caregiver's library.
    final phrases = await db.query('practice_phrases');
    expect(phrases.length, starterLibrary.length + AppDatabase.seedPhrases.length);
    final generic =
        await db.query('practice_phrases', where: 'is_starter = 0');
    expect(generic.length, AppDatabase.seedPhrases.length);
    final starters =
        await db.query('practice_phrases', where: 'is_starter = 1');
    expect(starters.length, starterLibrary.length);

    // A first session is short and intentional, and — the thing that matters —
    // every phrase in it has a MELODIC CONTOUR to intone. The seed used to open
    // on four one-syllable words, whose hum is a single note; nothing
    // one-syllable is active now, from either list.
    final active = await db.query('practice_phrases', where: 'is_active = 1');
    expect(active, isNotEmpty);
    expect(
      active.every((r) => (r['syllable_count'] as int) >= 2),
      isTrue,
      reason: 'a one-syllable target has no contour to intone',
    );
    expect(
      active.length,
      starterLibrary.where((s) => s.activeByDefault).length +
          AppDatabase.seedPhrases.where((r) => r[3] == 1).length,
    );

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
