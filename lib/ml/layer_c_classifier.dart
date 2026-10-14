import 'dart:math' as math;

import '../data/models.dart';
import '../practice/mit_sequence.dart';

/// **Layer C** — the (future) learned verdict classifier (audit item 18).
///
/// The therapy stack is layered: Layer A = the rules/DTW acoustic score
/// (measured, displayed, never gates), Layer B = the caregiver verdict (the only
/// thing that gates today), Layer C = a learned model that *might one day* assist
/// the caregiver. This file is the **scaffold** for Layer C: the feature the
/// model would read, the prediction interface, and a deliberately-untrained
/// default that **abstains**.
///
/// "Build, don't run": there is no training here and no bundled weights. The
/// default [UntrainedLayerC] always abstains, so it produces no Pass calls, so
/// the [GraduationGate] never graduates it, so it never gates progression. When
/// a model is eventually trained offline, it slots in behind this same interface
/// and still must clear the gate before it is trusted.
abstract class LayerCClassifier {
  /// Predict whether the caregiver would Pass this attempt. Implementations that
  /// aren't confident (or aren't trained) MUST abstain rather than guess.
  LayerCPrediction predict(LayerCFeatures features);
}

/// The untrained default: always abstains. This is the ONLY implementation
/// shipped today — it exists so the rest of the pipeline (logging → features →
/// gate → dashboard) is real and testable end-to-end without a trained model.
class UntrainedLayerC implements LayerCClassifier {
  const UntrainedLayerC();

  @override
  LayerCPrediction predict(LayerCFeatures features) => LayerCPrediction.abstain;
}

/// The feature vector Layer C would consume — assembled entirely from data we
/// already log (never raw audio): the caregiver-independent acoustic scores plus
/// the motor-timing summaries plus the MIT step/level/tempo context. All fields
/// are nullable because any given attempt may be missing a channel (e.g. no
/// clean capture at a unison step, or no taps).
class LayerCFeatures {
  const LayerCFeatures({
    this.contentSimilarity,
    this.mfccDistance,
    this.durationMs,
    this.latencyMs,
    this.tapSyncScore,
    this.itiCoefficientOfVariation,
    this.meanDwellMs,
    this.onsetSteadiness,
    this.step,
    this.level,
    this.tempoBpm,
  });

  final double? contentSimilarity; // 0..1 DTW similarity vs anchor
  final double? mfccDistance; // raw normalized DTW cost
  final int? durationMs;
  final int? latencyMs;
  final double? tapSyncScore; // 0..1 tap-to-beat accuracy
  final double? itiCoefficientOfVariation; // motor steadiness (lower = steadier)
  final double? meanDwellMs;
  final double? onsetSteadiness; // 0..1, higher = more even vocal onsets
  /// The MIT step this production was made at — the difficulty context that
  /// replaced the ladder rung. Null for attempts logged before v28, whose rung
  /// numbers no longer decode to anything.
  final MitStep? step;

  /// The patient's MIT level at the time, when known.
  final MitLevel? level;
  final int? tempoBpm;

  /// Assemble features for one attempt from its logged rows (pure). [taps] is the
  /// attempt's raw tap stream; [vector] its acoustic feature row (may be null at
  /// steps that don't record).
  factory LayerCFeatures.fromLoggedAttempt({
    required ExerciseAttempt attempt,
    FeatureVector? vector,
    List<StoredTapEvent> taps = const [],
    MitLevel? level,
  }) {
    // Inter-tap-interval coefficient of variation (motor steadiness).
    final downs = ([for (final t in taps) t.downMs]..sort());
    final itis = <double>[
      for (var i = 1; i < downs.length; i++) (downs[i] - downs[i - 1]).toDouble()
    ];
    final dwells = [for (final t in taps) if (t.dwellMs != null) t.dwellMs!];

    return LayerCFeatures(
      contentSimilarity: vector?.contentSimilarityScore,
      mfccDistance: vector?.mfccDistance,
      durationMs: attempt.durationMs ?? vector?.durationMs,
      latencyMs: attempt.latencyMs,
      tapSyncScore: attempt.tappingSynchronizationScore,
      itiCoefficientOfVariation: _cov(itis),
      meanDwellMs: dwells.isEmpty
          ? null
          : dwells.reduce((a, b) => a + b) / dwells.length,
      onsetSteadiness: _onsetSteadiness(vector?.onsetMs ?? const []),
      step: attempt.step,
      level: level,
      tempoBpm: attempt.tempoBpm,
    );
  }

  static double? _cov(List<double> xs) {
    if (xs.length < 2) return null;
    final mean = xs.reduce((a, b) => a + b) / xs.length;
    if (mean == 0) return null;
    final variance =
        xs.map((x) => (x - mean) * (x - mean)).reduce((a, b) => a + b) /
            xs.length;
    return math.sqrt(variance) / mean;
  }

  /// Map onset-interval scatter to a 0..1 steadiness (1 = perfectly even). Null
  /// when fewer than 3 onsets (no interval scatter to measure).
  static double? _onsetSteadiness(List<int> onsets) {
    if (onsets.length < 3) return null;
    final sorted = [...onsets]..sort();
    final intervals = <double>[
      for (var i = 1; i < sorted.length; i++)
        (sorted[i] - sorted[i - 1]).toDouble()
    ];
    final cov = _cov(intervals);
    if (cov == null) return null;
    return (1 - cov).clamp(0.0, 1.0);
  }
}

/// A Layer C prediction. [abstained] models "not confident / not trained" — the
/// safe default that keeps the caregiver in charge.
class LayerCPrediction {
  const LayerCPrediction({
    required this.predictedPass,
    required this.confidence,
    required this.abstained,
  });

  /// The model's Pass/Fail call. Meaningless when [abstained] is true.
  final bool predictedPass;

  /// 0..1 self-reported confidence. 0 when abstaining.
  final double confidence;

  /// The model declined to call this attempt — treat as "no opinion".
  final bool abstained;

  static const LayerCPrediction abstain =
      LayerCPrediction(predictedPass: false, confidence: 0, abstained: true);
}
