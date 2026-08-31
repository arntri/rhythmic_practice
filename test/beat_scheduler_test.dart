// Deterministic tests for the metronome's timing brain. No device, no real
// clock — we feed in "elapsed" times by hand and check exactly which beats fire.

import 'package:flutter_test/flutter_test.dart';
import 'package:rhythmic_practice/metronome/beat_scheduler.dart';

void main() {
  // Collect (beatIndex, scheduledMicros) for assertions.
  late List<(int, int)> fired;
  BeatScheduler make(int bpm) => BeatScheduler(
        bpm: bpm,
        onBeat: (i, t) => fired.add((i, t.inMicroseconds)),
      );

  setUp(() => fired = []);

  test('60 BPM fires one beat per second, on the second', () {
    final s = make(60)..start();
    // Poll every 100ms for 2.05s, like a Ticker would.
    for (var ms = 0; ms <= 2050; ms += 100) {
      s.update(Duration(milliseconds: ms));
    }
    expect(fired.map((e) => e.$1), [0, 1, 2]);
    // Scheduled times are exact multiples of 1,000,000 µs — no drift.
    expect(fired.map((e) => e.$2), [0, 1000000, 2000000]);
  });

  test('scheduled beat times never drift, even with jittery polling', () {
    final s = make(120)..start(); // 500ms period
    // Deliberately uneven poll times.
    for (final ms in [0, 137, 260, 499, 501, 700, 999, 1001, 1500]) {
      s.update(Duration(milliseconds: ms));
    }
    // Beats at exactly 0, 500ms, 1000ms, 1500ms regardless of when we polled.
    expect(fired.map((e) => e.$2), [0, 500000, 1000000, 1500000]);
  });

  test('a late frame catches up by firing every missed beat in order', () {
    final s = make(60)..start();
    s.update(const Duration(milliseconds: 0)); // beat 0
    // Big stall, then one update at 3.2s — beats 1,2,3 are all overdue.
    s.update(const Duration(milliseconds: 3200));
    expect(fired.map((e) => e.$1), [0, 1, 2, 3]);
  });

  test('stop() halts beat firing', () {
    final s = make(60)..start();
    s.update(const Duration(milliseconds: 0));
    s.stop();
    s.update(const Duration(milliseconds: 5000));
    expect(fired.length, 1); // only beat 0
  });

  test('phaseAt peaks (0.0) on the beat and rises toward the next', () {
    final s = make(60); // 1s period
    expect(s.phaseAt(const Duration(milliseconds: 0)), 0.0);
    expect(s.phaseAt(const Duration(milliseconds: 250)), closeTo(0.25, 1e-9));
    expect(s.phaseAt(const Duration(milliseconds: 500)), closeTo(0.5, 1e-9));
    // Just before the next beat, phase is near 1.0; on it, back to 0.0.
    expect(s.phaseAt(const Duration(milliseconds: 999)), closeTo(0.999, 1e-9));
    expect(s.phaseAt(const Duration(milliseconds: 1000)), 0.0);
  });

  // The catch-up above keeps beat COUNTING right (the practice FSM counts beats
  // since entering a state). Sounding those replayed beats is a different
  // question: on a stalled frame they'd all fire at once and be heard as a
  // stutter burst — the bug seen on device during the caregiver verdict.
  group('shouldSoundBeat drops beats a stalled frame delivers too late', () {
    const period = 1000000; // 60 BPM

    bool sound(int scheduledMs, int nowMs) => shouldSoundBeat(
          scheduled: Duration(milliseconds: scheduledMs),
          now: Duration(milliseconds: nowMs),
          beatPeriodUs: period,
        );

    test('a beat delivered on time is sounded', () {
      expect(sound(1000, 1000), isTrue);
      expect(sound(1000, 1016), isTrue); // one frame late
    });

    test('a beat still nearer to itself than to the next one is sounded', () {
      expect(sound(1000, 1499), isTrue);
    });

    test('a beat overtaken by the next one is dropped', () {
      expect(sound(1000, 1500), isFalse);
      expect(sound(1000, 4200), isFalse);
    });

    test('a 3.2s stall sounds only the newest of the overdue beats', () {
      // Exactly the burst from the device report: beats 1,2,3 all come due in
      // the single frame at 3.2s. Only beat 3 is still current.
      final sounded = [
        for (final beat in [1, 2, 3])
          if (sound(beat * 1000, 3200)) beat
      ];
      expect(sounded, [3]);
    });

    test('the window scales with tempo', () {
      // At 120 BPM (500ms) the same 400ms lateness is past the halfway point.
      expect(
        shouldSoundBeat(
          scheduled: const Duration(milliseconds: 1000),
          now: const Duration(milliseconds: 1400),
          beatPeriodUs: 500000,
        ),
        isFalse,
      );
    });
  });

  test('changing BPM mid-run re-anchors without a double-beat', () {
    final s = make(60)..start();
    s.update(const Duration(milliseconds: 0)); // beat 0
    s.update(const Duration(milliseconds: 1000)); // beat 1
    // At 1.0s switch to 120 BPM (500ms). Next beat should be ~1.5s, not instant.
    s.setBpm(120, const Duration(milliseconds: 1000));
    s.update(const Duration(milliseconds: 1100));
    expect(fired.length, 2); // no extra beat yet
    s.update(const Duration(milliseconds: 1500));
    expect(fired.length, 3); // beat at 1.5s
  });
}
