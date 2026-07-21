// Starter word library (Part 3): the manifest, idempotent seeding, structural
// parity with caregiver phrases, the installer's DB seam, and the guarantees
// that is_starter is presentation-only (hide + deprioritize) and never branches
// practice logic.

import 'package:flutter_test/flutter_test.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

import 'package:rhythmic_practice/data/app_database.dart';
import 'package:rhythmic_practice/data/models.dart';
import 'package:rhythmic_practice/data/practice_repository.dart';
import 'package:rhythmic_practice/data/starter_library.dart';
import 'package:rhythmic_practice/practice/mit_progression.dart';
import 'package:rhythmic_practice/practice/progression.dart';

void main() {
  setUpAll(sqfliteFfiInit);

  group('starter manifest', () {
    test('~10 entries, all distinct texts and asset paths', () {
      expect(starterLibrary.length, 10);
      expect(starterLibrary.map((s) => s.text).toSet().length, 10);
      expect(starterLibrary.map((s) => s.assetPath).toSet().length, 10);
    });

    test('every asset is a bundled starter WAV', () {
      for (final s in starterLibrary) {
        expect(s.assetPath, startsWith('audio/starter/'));
        expect(s.assetPath, endsWith('.wav'));
      }
    });

    test('metadata is internally consistent', () {
      for (final s in starterLibrary) {
        // One nucleus per syllable.
        expect(s.nucleiMs.length, s.syllableCount, reason: s.text);
        // Nuclei are increasing.
        for (var i = 1; i < s.nucleiMs.length; i++) {
          expect(s.nucleiMs[i], greaterThan(s.nucleiMs[i - 1]), reason: s.text);
        }
        // Stress index (if set) is a real syllable.
        if (s.stressIndex != null) {
          expect(s.stressIndex, inInclusiveRange(0, s.syllableCount - 1),
              reason: s.text);
        }
        // Derived level matches the syllable-count mapping.
        expect(s.complexityLevel, levelForSyllableCount(s.syllableCount),
            reason: s.text);
      }
    });
  });

  group('seeding + database', () {
    late Database db;
    late PracticeRepository repo;

    setUp(() async {
      db = await databaseFactoryFfi.openDatabase(
        inMemoryDatabasePath,
        options: OpenDatabaseOptions(
          version: 1,
          onConfigure: (db) => db.execute('PRAGMA foreign_keys = ON'),
          onCreate: (db, v) => AppDatabase.applyInitialSchema(db),
        ),
      );
      repo = PracticeRepository.withDatabase(db);
    });

    tearDown(() async => db.close());

    test('fresh install seeds all 10 starters with is_starter = 1', () async {
      final starters =
          await db.query('practice_phrases', where: 'is_starter = 1');
      expect(starters.length, 10);
      expect(
          starters.map((r) => r['phrase_text']).toSet(),
          starterLibrary.map((s) => s.text).toSet());
    });

    test('starter rows carry seeded metadata but no guide clip yet', () async {
      final water = PracticePhrase.fromMap((await db.query('practice_phrases',
              where: 'is_starter = 1 AND phrase_text = ?',
              whereArgs: ['Water']))
          .single);
      expect(water.isStarter, isTrue);
      expect(water.syllableCount, 2);
      expect(water.stressIndex, 0);
      expect(water.guideNucleiMs, [150, 450]);
      expect(water.guideClipPath, isNull); // installed at runtime
    });

    test('a starter phrase is structurally identical to a caregiver phrase '
        '(only is_starter differs)', () async {
      // Add a caregiver phrase with the same shape as a starter.
      await repo.addPhrase('Water');
      final rows = await db.query('practice_phrases',
          where: 'phrase_text = ?', whereArgs: ['Water']);
      final starter = rows.firstWhere((r) => (r['is_starter'] as int) == 1);
      final caregiver = rows.firstWhere((r) => (r['is_starter'] as int) == 0);
      // Same columns present; the ONLY intended difference is the flag.
      expect(starter.keys.toSet(), caregiver.keys.toSet());
      expect(starter['is_starter'], 1);
      expect(caregiver['is_starter'], 0);
    });

    test('seeding is idempotent — re-running does not duplicate', () async {
      // Simulate the v27 upgrade path calling the seeder again via migrate.
      await AppDatabase.migrate(db, 26, 27);
      final starters =
          await db.query('practice_phrases', where: 'is_starter = 1');
      expect(starters.length, 10); // still 10, not 20
    });

    test('caregiver can HIDE a starter word (is_active toggle)', () async {
      final water = (await db.query('practice_phrases',
              where: 'is_starter = 1 AND phrase_text = ?', whereArgs: ['Water']))
          .single;
      final id = water['phrase_id'] as int;
      expect(water['is_active'], 1);
      await repo.setPhraseActive(id, false);
      final active = await repo.getActivePhrases();
      expect(active.any((p) => p.phraseId == id), isFalse);
    });

    test('starters are DEPRIORITIZED below caregiver words in a session',
        () async {
      // A caregiver word and a starter word, both active, both L1.
      await repo.addPhrase('Zebra'); // sorts last alphabetically among L1
      final caregiverId = (await db.query('practice_phrases',
              where: 'phrase_text = ?', whereArgs: ['Zebra']))
          .single['phrase_id'] as int;
      await repo.setPhraseActive(caregiverId, true);

      final active = await repo.getActivePhrases();
      final firstStarter = active.indexWhere((p) => p.isStarter);
      final lastCaregiver =
          active.lastIndexWhere((p) => !p.isStarter);
      // Every caregiver (non-starter) word comes before the first starter word.
      expect(firstStarter, greaterThan(lastCaregiver));
    });

    test('the installer seam: pending → attach → not pending (idempotent)',
        () async {
      var pending = await repo.getStarterPhrasesNeedingGuide();
      expect(pending.length, 10); // none installed yet
      final first = pending.first;
      await repo.attachGuideClipPath(first.phraseId, '/guides/x.enc');
      pending = await repo.getStarterPhrasesNeedingGuide();
      expect(pending.length, 9); // the attached one drops out
      expect(pending.any((p) => p.phraseId == first.phraseId), isFalse);
    });
  });

  group('is_starter never branches practice logic', () {
    test('the progression engine advances a starter identically to any word',
        () {
      // A starter word and a plain word at the same rung with the same block get
      // the same outcome — the engine has no is_starter input at all.
      final engine = MitProgression();
      const starterState = ProgressionState(profileId: 'p', phraseId: 1);
      const plainState = ProgressionState(profileId: 'p', phraseId: 2);
      final a = engine.evaluateBlock(starterState, [1, 1, 1]);
      final b = engine.evaluateBlock(plainState, [1, 1, 1]);
      expect(a.state.rung, b.state.rung);
      expect(a.outcome, b.outcome);
    });
  });
}
