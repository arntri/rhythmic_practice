// Microphone capture analysis — pure logic, no Flutter or plugins, fully
// unit-testable (brief §5, §6 "Derived values"). The mic glue (Step 5) feeds
// amplitude readings in; this decides when to stop and derives latency/duration.

/// Derives a per-session speech threshold from a short ambient listen at session
/// start (therapy addendum §5: "2 s ambient calibration … sets the silence/
/// noise-floor threshold"), so silence-detection adapts to the room instead of
/// using one fixed level. Pure logic — the mic glue feeds it the sampled
/// readings; [CaptureTracker] then uses the result as its [speechThresholdDb].
class AmbientCalibration {
  /// Fallback when calibration produced no usable readings (the historical
  /// fixed value, also [CaptureTracker]'s own default).
  static const defaultThresholdDb = -40.0;

  /// Speech threshold (dBFS) = the ambient floor + [marginDb], clamped to a sane
  /// band. The floor is the **median** of [ambientDb] (robust to a stray cough or
  /// click during the calibration window). Empty input → [defaultThresholdDb].
  static double thresholdFrom(
    List<double> ambientDb, {
    double marginDb = 12,
    double minDb = -55,
    double maxDb = -25,
  }) {
    if (ambientDb.isEmpty) return defaultThresholdDb;
    final sorted = [...ambientDb]..sort();
    final mid = sorted.length ~/ 2;
    final median = sorted.length.isOdd
        ? sorted[mid]
        : (sorted[mid - 1] + sorted[mid]) / 2;
    return (median + marginDb).clamp(minDb, maxDb);
  }
}

/// Tracks amplitude readings during State_3 (Input_Capture) to:
///   - detect when the user starts speaking (→ latency),
///   - detect when they've finished (≈ [silenceDuration] of quiet after speech),
///   - measure how long they spoke (→ duration).
///
/// Readings are in dBFS (decibels relative to full scale): roughly -160 (silent)
/// up to 0 (loudest). Anything at or above [speechThresholdDb] counts as speech.
class CaptureTracker {
  CaptureTracker({
    this.speechThresholdDb = -40.0,
    this.silenceDuration = const Duration(milliseconds: 4500),
  });

  /// Amplitude (dBFS) at or above which a reading counts as the user speaking.
  final double speechThresholdDb;

  /// How long the input must stay quiet, *after speech has begun*, before we
  /// consider the attempt finished (brief §5: "~4.5 seconds of silence").
  final Duration silenceDuration;

  Duration? _firstSpeechAt;
  Duration? _lastSpeechAt;

  /// Feed one reading: [elapsed] since capture started, [db] its amplitude.
  /// Returns true when capture should close.
  bool add(Duration elapsed, double db) {
    if (db >= speechThresholdDb) {
      _firstSpeechAt ??= elapsed;
      _lastSpeechAt = elapsed;
      return false;
    }
    // Silence only counts toward closing once the user has actually spoken —
    // otherwise we'd never wait for a slow starter.
    final last = _lastSpeechAt;
    if (last == null) return false;
    return elapsed - last >= silenceDuration;
  }

  /// Whether any speech was heard at all.
  bool get heardSpeech => _firstSpeechAt != null;

  /// Gap from capture start to the first vocalization, in ms (brief: latency_ms).
  /// Null if the user never spoke.
  int? latencyMs() => _firstSpeechAt?.inMilliseconds;

  /// Length of the vocalization (first to last speech), in ms (brief:
  /// duration_ms). Null if the user never spoke.
  int? durationMs() {
    final first = _firstSpeechAt;
    final last = _lastSpeechAt;
    if (first == null || last == null) return null;
    return (last - first).inMilliseconds;
  }
}
