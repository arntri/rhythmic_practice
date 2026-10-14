// Guards the caregiver panel's job as the ONLY way into the caregiver screens.
//
// This exists because of a real regression: the home-screen rewrite replaced a
// top-right menu with the slide-to-unlock, and five screens — History, Help,
// Metronome, Account and the family-progress reader — silently lost their only
// entry point. Three were cut; History and Help were rewired here. Nothing
// failed at the time, because no test asserted that a screen was reachable at
// all. This one does, so the next unlinked screen is a red test rather than a
// feature nobody can open.
//
// sqflite-ffi runs on the real event loop, so the waits are wrapped in runAsync
// to let its futures complete, then a single pump() to render (pumpAndSettle
// would hang on the loading spinner's infinite animation).

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

import 'package:rhythmic_practice/data/app_database.dart';
import 'package:rhythmic_practice/data/practice_repository.dart';
import 'package:rhythmic_practice/screens/caregiver_panel.dart';
import 'package:rhythmic_practice/screens/help_screen.dart';
import 'package:rhythmic_practice/screens/history_screen.dart';

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

  /// Pumps until [target] renders, letting the ffi DB futures progress between
  /// frames. Returns whether it appeared.
  Future<bool> settleUntil(WidgetTester tester, Finder target) async {
    for (var i = 0; i < 30 && target.evaluate().isEmpty; i++) {
      await tester.runAsync(
        () => Future<void>.delayed(const Duration(milliseconds: 20)),
      );
      await tester.pump();
    }
    return target.evaluate().isNotEmpty;
  }

  Future<void> openPanel(WidgetTester tester) async {
    tester.view.physicalSize = const Size(1200, 2600);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.reset);
    await tester.pumpWidget(MaterialApp(home: CaregiverPanel(repository: repo)));
    expect(
      await settleUntil(tester, find.byKey(const Key('panel_level'))),
      isTrue,
      reason: 'the panel never finished loading',
    );
  }

  testWidgets('every caregiver screen has a row pointing at it', (tester) async {
    await openPanel(tester);

    // The set a caregiver can reach from home. Rows that only exist mid-session
    // (rest, "right now") are deliberately absent here — no controller is
    // attached — and the internal tools sit behind demo mode, which is off.
    for (final key in const [
      'panel_level',
      'panel_phrases',
      'panel_sensory',
      'panel_dose',
      'panel_progress',
      'panel_history',
      'panel_tapping',
      'panel_help',
      'panel_privacy',
      'panel_insights',
    ]) {
      expect(
        find.byKey(Key(key)),
        findsOneWidget,
        reason: '$key is missing — a caregiver screen with no way in',
      );
    }
  });

  testWidgets('History opens the history screen', (tester) async {
    await openPanel(tester);

    await tester.scrollUntilVisible(find.byKey(const Key('panel_history')), 120);
    await tester.tap(find.byKey(const Key('panel_history')));
    await tester.pump();

    expect(await settleUntil(tester, find.byType(HistoryScreen)), isTrue);
  });

  testWidgets('Help opens the help screen', (tester) async {
    await openPanel(tester);

    await tester.scrollUntilVisible(find.byKey(const Key('panel_help')), 120);
    await tester.tap(find.byKey(const Key('panel_help')));
    await tester.pump();

    expect(await settleUntil(tester, find.byType(HelpScreen)), isTrue);
  });

  testWidgets('the internal tools stay behind demo mode', (tester) async {
    await openPanel(tester);
    expect(find.byKey(const Key('panel_clip_qa')), findsNothing);
    expect(find.byKey(const Key('panel_manifest')), findsNothing);

    // Turn demo mode on and mount a FRESH panel — a distinct key, so Flutter
    // builds new State and re-reads the profile instead of reusing the old one.
    await tester.runAsync(() => repo.updateProfile(demoModeEnabled: true));
    await tester.pumpWidget(
      MaterialApp(
        home: CaregiverPanel(key: const Key('reopened'), repository: repo),
      ),
    );
    expect(
      await settleUntil(tester, find.byKey(const Key('panel_clip_qa'))),
      isTrue,
    );
  });
}
