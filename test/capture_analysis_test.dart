import 'package:flutter_test/flutter_test.dart';
import 'package:rhythmic_practice/practice/capture_analysis.dart';

void main() {
  Duration ms(int v) => Duration(milliseconds: v);

  group('AmbientCalibration.thresholdFrom', () {
    test('quiet room → threshold sits a margin above the floor', () {
      // Median ≈ -60, +12 margin = -48, within band.
      final t = AmbientCalibration.thresholdFrom(const [-60, -61, -59, -60]);
      expect(t, closeTo(-48, 0.001));
    });

    test('uses the median, ignoring a stray loud reading', () {
      // A single -20 transient must not drag the floor up.
      final t = AmbientCalibration.thresholdFrom(const [-60, -60, -60, -20]);
      expect(t, closeTo(-48, 0.001)); // median -60 → -48
    });

    test('noisy room clamps to the max threshold', () {
      final t = AmbientCalibration.thresholdFrom(const [-30, -30, -30]);
      expect(t, -25); // -30 + 12 = -18, clamped to maxDb -25
    });

    test('very quiet room clamps to the min threshold', () {
      final t = AmbientCalibration.thresholdFrom(const [-90, -90, -90]);
      expect(t, -55); // -90 + 12 = -78, clamped to minDb -55
    });

    test('empty input falls back to the default', () {
      expect(AmbientCalibration.thresholdFrom(const []),
          AmbientCalibration.defaultThresholdDb);
    });
  });

  test('silence before any speech never closes (waits for a slow starter)', () {
    final t = CaptureTracker(silenceDuration: ms(4500));
    expect(t.add(ms(0), -80), isFalse);
    expect(t.add(ms(4000), -80), isFalse);
    expect(t.add(ms(10000), -80), isFalse); // still waiting; no speech yet
    expect(t.heardSpeech, isFalse);
    expect(t.latencyMs(), isNull);
    expect(t.durationMs(), isNull);
  });

  test('closes after the silence window once speech has occurred', () {
    final t = CaptureTracker(speechThresholdDb: -40, silenceDuration: ms(4500));
    expect(t.add(ms(500), -80), isFalse); // quiet
    expect(t.add(ms(1000), -20), isFalse); // speech starts at 1000
    expect(t.add(ms(1500), -15), isFalse); // still speaking at 1500
    expect(t.add(ms(3000), -80), isFalse); // silence, 1500ms in -> not yet
    expect(t.add(ms(6000), -80), isTrue); // 4500ms after last speech -> close
  });

  test('latency = first speech, duration = first..last speech', () {
    final t = CaptureTracker(speechThresholdDb: -40, silenceDuration: ms(4500));
    t.add(ms(0), -90);
    t.add(ms(800), -30); // first speech at 800
    t.add(ms(900), -25);
    t.add(ms(2300), -28); // last speech at 2300
    expect(t.heardSpeech, isTrue);
    expect(t.latencyMs(), 800);
    expect(t.durationMs(), 1500); // 2300 - 800
  });

  test('a brief gap shorter than the window does not close', () {
    final t = CaptureTracker(speechThresholdDb: -40, silenceDuration: ms(4500));
    t.add(ms(1000), -20); // speech
    expect(t.add(ms(3000), -80), isFalse); // 2s gap
    expect(t.add(ms(4000), -20), isFalse); // speech resumes -> resets the clock
    expect(t.add(ms(6000), -80), isFalse); // 2s gap again -> still open
    expect(t.durationMs(), 3000); // 4000 - 1000
  });
}
