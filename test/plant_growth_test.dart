// The home-screen plant.
//
// It is the ONLY progress the patient ever sees, and it is a record of turning
// up rather than of doing well. Every rule below exists to keep it that way: it
// grows once per day, it never goes backwards, and nothing about how a session
// went can touch it. A plant that could wilt would be a way of telling someone
// caring for a parent with aphasia that they had failed at it.

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

import 'package:rhythmic_practice/data/app_database.dart';
import 'package:rhythmic_practice/data/practice_repository.dart';
import 'package:rhythmic_practice/widgets/plant.dart';

void main() {
  setUpAll(sqfliteFfiInit);

  late Database db;
  late PracticeRepository repo;
  const profileId = AppDatabase.defaultProfileId;

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

  tearDown(() => db.close());

  final day1 = DateTime(2026, 9, 1);
  final day2 = DateTime(2026, 9, 2);

  test('starts ungrown', () async {
    expect((await repo.getProfile()).plantStage, 0);
  });

  test('grows one stage the first time practice starts', () async {
    expect(await repo.growPlant(profileId, today: day1), 1);
    expect((await repo.getProfile()).plantStage, 1);
  });

  test('a second session the same day does not grow it again', () async {
    // Otherwise a keen afternoon would race a whole week of turning up.
    await repo.growPlant(profileId, today: day1);
    expect(await repo.growPlant(profileId, today: day1), 1);
    expect(await repo.growPlant(profileId, today: day1), 1);
  });

  test('the next day does', () async {
    await repo.growPlant(profileId, today: day1);
    expect(await repo.growPlant(profileId, today: day2), 2);
  });

  test('a gap does not undo anything — it just waits', () async {
    // The single most important rule. Missing a month is a hard month, not a
    // failure, and the plant must be exactly where they left it.
    await repo.growPlant(profileId, today: day1);
    await repo.growPlant(profileId, today: day2);
    expect((await repo.getProfile()).plantStage, 2);

    final muchLater = DateTime(2026, 12, 25);
    expect((await repo.getProfile()).plantStage, 2, reason: 'still 2');
    expect(await repo.growPlant(profileId, today: muchLater), 3);
  });

  test('it stops at the last stage rather than looping', () async {
    var day = DateTime(2026, 9, 1);
    for (var i = 0; i < 10; i++) {
      await repo.growPlant(profileId, today: day);
      day = day.add(const Duration(days: 1));
    }
    expect((await repo.getProfile()).plantStage, Plant.maxStage);
    // And reaching the end is not an ending — it simply stops changing.
    expect(await repo.growPlant(profileId, today: day), Plant.maxStage);
  });

  testWidgets('every stage draws without overflowing its box', (tester) async {
    for (var stage = 0; stage <= Plant.maxStage; stage++) {
      await tester.pumpWidget(
        MaterialApp(
          home: Center(
            child: SizedBox(
              width: 280,
              height: 280,
              child: Plant(stage: stage),
            ),
          ),
        ),
      );
      await tester.pump();
      expect(tester.takeException(), isNull, reason: 'stage $stage');
    }
  });

  testWidgets('an out-of-range stage clamps instead of crashing', (
    tester,
  ) async {
    for (final stage in [-3, 99]) {
      await tester.pumpWidget(
        MaterialApp(
          home: SizedBox(width: 200, height: 200, child: Plant(stage: stage)),
        ),
      );
      await tester.pump();
      expect(tester.takeException(), isNull, reason: 'stage $stage');
    }
  });
}
