import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:rhythmic_practice/app/orientation.dart';

void main() {
  MaterialPageRoute<void> plain() =>
      MaterialPageRoute<void>(builder: (_) => const SizedBox());
  PortraitPageRoute<void> portrait() =>
      PortraitPageRoute<void>(builder: (_) => const SizedBox());
  LandscapePageRoute<void> landscape() =>
      LandscapePageRoute<void>(builder: (_) => const SizedBox());

  group('orientationsFor (Part 2 item 4 — per-screen orientation)', () {
    test('a caregiver (portrait) route asks for portraitUp', () {
      expect(orientationsFor(portrait()), kPortraitOrientations);
    });

    test('a patient-practice (landscape) route asks for both landscapes', () {
      expect(orientationsFor(landscape()), kLandscapeOrientations);
    });

    test('an untagged route returns null → inherit the active orientation', () {
      expect(orientationsFor(plain()), isNull);
      expect(orientationsFor(null), isNull);
    });
  });

  group('OrientationRouteObserver drives the platform channel', () {
    late List<Object?> requested; // each SystemChrome.setPreferredOrientations arg

    setUp(() {
      TestWidgetsFlutterBinding.ensureInitialized();
      requested = [];
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockMethodCallHandler(SystemChannels.platform, (call) async {
        if (call.method == 'SystemChrome.setPreferredOrientations') {
          requested.add(call.arguments);
        }
        return null;
      });
    });

    tearDown(() {
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockMethodCallHandler(SystemChannels.platform, null);
    });

    test('pushing a caregiver page requests portrait', () async {
      OrientationRouteObserver().didPush(portrait(), plain());
      await Future<void>.delayed(Duration.zero);
      expect(requested.last, ['DeviceOrientation.portraitUp']);
    });

    test('popping a caregiver page back onto practice requests landscape',
        () async {
      OrientationRouteObserver().didPop(portrait(), landscape());
      await Future<void>.delayed(Duration.zero);
      expect(requested.last, [
        'DeviceOrientation.landscapeLeft',
        'DeviceOrientation.landscapeRight',
      ]);
    });

    test('caregiver→caregiver: popping onto an untagged parent stays portrait '
        '(no channel call → inherit)', () async {
      // The nested child is untagged (inherits the parent portrait); popping it
      // must NOT force landscape — orientationsFor(parent) is null, so nothing
      // is requested and the active portrait is kept.
      OrientationRouteObserver().didPop(plain(), plain());
      await Future<void>.delayed(Duration.zero);
      expect(requested, isEmpty);
    });
  });
}
