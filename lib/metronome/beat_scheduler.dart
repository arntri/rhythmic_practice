/// The timing brain of the metronome — pure Dart, no Flutter, so it can be
/// unit-tested without a device.
///
/// WHY THIS EXISTS (read the brief §4): a naive `Timer.periodic` drifts and
/// stutters, because each tick's small error accumulates. Instead we treat the
/// beats as fixed points on an absolute timeline: beat *n* happens at exactly
/// `n * beatPeriod` after start. We're handed a monotonic "elapsed" time
/// repeatedly (from a Ticker, faster than the beat) and we fire every beat
/// whose scheduled moment has passed. Because each beat time is recomputed from
/// its index — never accumulated — there is no drift.
class BeatScheduler {
  BeatScheduler({required this.onBeat, int bpm = 60})
      : assert(bpm > 0),
        _bpm = bpm;

  /// Called once per beat, with the beat number (0, 1, 2, …) and the exact
  /// scheduled time of that beat since [start]. Fire your sound/haptic here.
  final void Function(int beatIndex, Duration scheduledTime) onBeat;

  int _bpm;
  int get bpm => _bpm;

  /// Microseconds between beats. 60 BPM = 1,000,000 µs = 1 s.
  int get beatPeriodUs => (60000000 / _bpm).round();

  bool _running = false;
  bool get isRunning => _running;

  // How many beats we've already fired. The NEXT beat to fire is _beatsFired,
  // scheduled at _beatsFired * beatPeriodUs.
  int _beatsFired = 0;

  /// Begin a fresh run. Beat 0 fires on the first [update] (i.e. at elapsed ≈ 0).
  void start() {
    _beatsFired = 0;
    _running = true;
  }

  void stop() {
    _running = false;
  }

  /// Change tempo. To keep things simple and predictable we re-anchor the beat
  /// grid to "now": the caller passes the current elapsed time so the next beat
  /// lands one fresh interval later, with no sudden double-beat or long gap.
  void setBpm(int newBpm, Duration elapsed) {
    assert(newBpm > 0);
    _bpm = newBpm;
    if (_running) {
      // Pretend we've just fired the beat that's due now, so counting continues
      // smoothly from here at the new period.
      _beatsFired = (elapsed.inMicroseconds / beatPeriodUs).floor() + 1;
    }
  }

  /// Feed in the latest monotonic elapsed time since [start] (call this every
  /// Ticker frame). Fires [onBeat] for each scheduled beat now in the past —
  /// possibly more than one, if a frame was late, so we never fall behind.
  void update(Duration elapsed) {
    if (!_running) return;
    final elapsedUs = elapsed.inMicroseconds;
    while (_beatsFired * beatPeriodUs <= elapsedUs) {
      final scheduledUs = _beatsFired * beatPeriodUs;
      onBeat(_beatsFired, Duration(microseconds: scheduledUs));
      _beatsFired++;
    }
  }

  /// Fraction (0.0 → 1.0) of the way from the previous beat to the next, at the
  /// given elapsed time. Used to drive the visual ring so it peaks exactly on
  /// the beat (phase 0.0). Pure function of time — safe to call every frame.
  double phaseAt(Duration elapsed) {
    final us = elapsed.inMicroseconds;
    if (us <= 0) return 0;
    return (us % beatPeriodUs) / beatPeriodUs;
  }
}
