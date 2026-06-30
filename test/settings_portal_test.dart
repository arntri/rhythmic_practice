// Verifies the settings portal loads current values and writes a change to the
// database, using an in-memory DB (no device).
//
// sqflite-ffi runs on the real event loop, so we wrap the waits in runAsync to
// let its futures complete, then a single pump() to render (pumpAndSettle would
// hang on the loading spinner's infinite animation).

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

import 'package:rhythmic_practice/data/app_database.dart';
import 'package:rhythmic_practice/data/practice_repository.dart';
import 'package:rhythmic_practice/screens/settings_portal.dart';

void main() {
  setUpAll(sqfliteFfiInit);

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

  tearDown(() => db.close());

  testWidgets('loads settings and persists a toggled channel', (tester) async {
    await tester.pumpWidget(MaterialApp(home: SettingsPortal(repository: repo)));

    // Interleave: runAsync lets the ffi DB futures progress, pump renders the
    // result. Loop until the loaded controls appear.
    final sound = find.widgetWithText(SwitchListTile, 'Sound');
    for (var i = 0; i < 20 && sound.evaluate().isEmpty; i++) {
      await tester.runAsync(() => Future<void>.delayed(const Duration(milliseconds: 20)));
      await tester.pump();
    }
    expect(sound, findsOneWidget);

    // Sound starts on (seeded default); turn it off.
    await tester.tap(sound);
    await tester.pump();

    // Let the write flush, then read it back (both on the real loop).
    final saved = await tester.runAsync(() async {
      await Future<void>.delayed(const Duration(milliseconds: 200));
      return repo.getProfile();
    });
    expect(saved!.soundEnabled, isFalse);
  });
}
