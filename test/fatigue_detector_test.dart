import 'package:flutter_test/flutter_test.dart';
import 'package:rhythmic_practice/data/models.dart';
import 'package:rhythmic_practice/ml/fatigue_detector.dart';

/// Build one attempt's worth of taps from inter-tap intervals [itis] (ms),
/// starting at [startMs], with an optional constant [dwell].
List<StoredTapEvent> _attemptTaps(
  String attemptId,
  List<int> itis, {
  int startMs = 0,
  int? dwell,
}) {
  final taps = <StoredTapEvent>[];
  var t = startMs;
  for (var i = 0; i <= itis.length; i++) {
    taps.add(StoredTapEvent(
      tapId: '$attemptId-$i',
      attemptId: attemptId,
      phraseId: 1,
      sessionId: 's1',
      rung: 4,
      tapIndex: i,
      downMs: t,
      dwellMs: dwell,
      beatPhase: null,
    ));
    if (i < itis.length) t += itis[i];
  }
  return taps;
}

void main() {
  const detector = FatigueDetector();

  test('steady early → erratic late reads as fatigue', () {
    // Early attempts: metronome-steady 500 ms taps. Late attempts: scattered.
    final taps = <StoredTapEvent>[
      ..._attemptTaps('a1', const [500, 500, 500, 500], startMs: 0),
      ..._attemptTaps('a2', const [500, 500, 500, 500], startMs: 5000),
      ..._attemptTaps('a3', const [300, 780, 250, 820], startMs: 10000),
      ..._attemptTaps('a4', const [820, 260, 760, 300], startMs: 15000),
    ];
    final est = detector.estimate(taps: taps);
    expect(est.lowConfidence, isFalse);
    expect(est.isFatigued, isTrue);
    expect(est.score, greaterThan(0.5));
    expect(est.itiDrift, greaterThan(0));
  });

  test('steady throughout reads as no fatigue', () {
    final taps = <StoredTapEvent>[
      ..._attemptTaps('a1', const [500, 500, 500, 500], startMs: 0),
      ..._attemptTaps('a2', const [500, 500, 500, 500], startMs: 5000),
      ..._attemptTaps('a3', const [500, 500, 500, 500], startMs: 10000),
      ..._attemptTaps('a4', const [500, 500, 500, 500], startMs: 15000),
    ];
    final est = detector.estimate(taps: taps);
    expect(est.isFatigued, isFalse);
    expect(est.score, lessThan(0.2));
  });

  test('erratic throughout (baseline, no DRIFT) is not called fatigue', () {
    final taps = <StoredTapEvent>[
      ..._attemptTaps('a1', const [300, 780, 250, 820], startMs: 0),
      ..._attemptTaps('a2', const [820, 260, 760, 300], startMs: 5000),
      ..._attemptTaps('a3', const [300, 780, 250, 820], startMs: 10000),
      ..._attemptTaps('a4', const [820, 260, 760, 300], startMs: 15000),
    ];
    final est = detector.estimate(taps: taps);
    expect(est.isFatigued, isFalse); // scatter is constant → drift ~0
    expect(est.score, lessThan(0.3));
  });

  test('too few samples → low confidence, not a false "no fatigue"', () {
    final taps = _attemptTaps('a1', const [500, 500], startMs: 0);
    final est = detector.estimate(taps: taps);
    expect(est.lowConfidence, isTrue);
    expect(est.isFatigued, isFalse);
    expect(est.itiDrift, isNull);
  });

  test('vocal-onset steadiness drift contributes on its own', () {
    // No usable tap ITIs (one tap per attempt), but onset spacing degrades.
    final taps = <StoredTapEvent>[
      StoredTapEvent(
          tapId: 't', attemptId: 'a1', phraseId: 1, sessionId: 's1',
          rung: 6, tapIndex: 0, downMs: 0, dwellMs: null, beatPhase: null),
    ];
    final onsets = <List<int>>[
      [0, 400, 800, 1200], // steady
      [0, 400, 800, 1200],
      [0, 250, 900, 1150], // scattered
      [0, 850, 1000, 1500],
    ];
    final est = detector.estimate(taps: taps, onsetsPerAttempt: onsets);
    expect(est.steadinessDrift, isNotNull);
    expect(est.steadinessDrift, greaterThan(0));
    expect(est.itiDrift, isNull); // no multi-tap attempts
    expect(est.score, greaterThan(0));
  });

  test('dwell scatter drift is picked up', () {
    // Constant ITI so itiDrift ~0; dwell scatter rises late.
    final taps = <StoredTapEvent>[
      ..._attemptTaps('a1', const [500, 500, 500, 500], startMs: 0, dwell: 120),
      ..._attemptTaps('a2', const [500, 500, 500, 500], startMs: 5000, dwell: 120),
    ];
    // Late attempts: same ITI, but wildly varying dwell.
    final lateA = _attemptTaps('a3', const [500, 500, 500, 500], startMs: 10000);
    final lateB = _attemptTaps('a4', const [500, 500, 500, 500], startMs: 15000);
    final scatter = [60, 220, 70, 240, 65];
    for (var i = 0; i < lateA.length; i++) {
      taps.add(_withDwell(lateA[i], scatter[i]));
    }
    for (var i = 0; i < lateB.length; i++) {
      taps.add(_withDwell(lateB[i], scatter[(i + 2) % scatter.length]));
    }
    final est = detector.estimate(taps: taps);
    expect(est.dwellDrift, isNotNull);
    expect(est.dwellDrift, greaterThan(0));
  });
}

StoredTapEvent _withDwell(StoredTapEvent t, int dwell) => StoredTapEvent(
      tapId: t.tapId,
      attemptId: t.attemptId,
      phraseId: t.phraseId,
      sessionId: t.sessionId,
      rung: t.rung,
      tapIndex: t.tapIndex,
      downMs: t.downMs,
      dwellMs: dwell,
      beatPhase: t.beatPhase,
    );
