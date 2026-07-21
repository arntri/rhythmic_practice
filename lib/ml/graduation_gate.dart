import 'dart:math' as math;

/// The **graduation gate** for the Layer C classifier (audit item 18).
///
/// The single most important guardrail in the ML stack: a learned classifier may
/// only ever be *trusted* (allowed to stand in for a caregiver verdict) once it
/// has demonstrably earned it. The bar is a **Wilson score lower bound on
/// precision ≥ 0.90** over held-out caregiver-labelled predictions — i.e. we are
/// 95% confident the model's true precision on "Pass" calls is at least 90%,
/// not merely that it looked good on a lucky handful.
///
/// Precision (not accuracy/recall) because the failure we must avoid is a
/// FALSE PASS — telling a patient/caregiver "correct" when it wasn't. Recall
/// mistakes (missing a good attempt) are safe here: the caregiver still judges.
///
/// Because the master plan is **build, don't run** (no model is trained on real
/// data), the trained classifier abstains and never produces the scored
/// predictions this gate needs — so [GraduationStatus.graduated] stays false and
/// the caregiver stays in the loop. This gate is what *keeps it that way* by
/// construction.
class GraduationGate {
  const GraduationGate({
    this.precisionFloor = 0.90,
    this.minPredictions = 30,
    this.z = 1.96, // 95% confidence
  });

  /// The Wilson lower bound on precision the model must clear to graduate.
  final double precisionFloor;

  /// Minimum scored positive ("Pass") predictions before graduation is even
  /// considered — a second guard against graduating on a tiny sample.
  final int minPredictions;

  /// Standard-normal quantile for the confidence level (1.96 ≈ 95%).
  final double z;

  /// Evaluate graduation from held-out (predicted, actual) caregiver labels.
  /// Only predictions where the model said **Pass** count toward precision (a
  /// TP when the caregiver also passed it, an FP when they didn't); abstentions
  /// and non-Pass predictions are ignored — precision is about the Pass calls.
  GraduationStatus evaluate(Iterable<LabeledPrediction> scored) {
    var truePositives = 0;
    var predictedPositives = 0;
    for (final p in scored) {
      if (p.predictedPass) {
        predictedPositives++;
        if (p.actualPass) truePositives++;
      }
    }
    final point =
        predictedPositives == 0 ? 0.0 : truePositives / predictedPositives;
    final lower = wilsonLowerBound(truePositives, predictedPositives, z: z);
    final enough = predictedPositives >= minPredictions;
    final graduated = enough && lower >= precisionFloor;

    final String reason;
    if (predictedPositives == 0) {
      reason = 'No Pass predictions scored yet (model untrained / abstaining).';
    } else if (!enough) {
      reason = 'Only $predictedPositives Pass predictions scored; '
          'need $minPredictions before trusting the model.';
    } else if (!graduated) {
      reason = 'Precision lower bound ${(lower * 100).toStringAsFixed(1)}% '
          'is below the ${(precisionFloor * 100).toStringAsFixed(0)}% floor.';
    } else {
      reason = 'Graduated: precision ≥ ${(precisionFloor * 100).toStringAsFixed(0)}% '
          'with 95% confidence.';
    }

    return GraduationStatus(
      truePositives: truePositives,
      predictedPositives: predictedPositives,
      precisionPointEstimate: point,
      precisionLowerBound: lower,
      graduated: graduated,
      reason: reason,
    );
  }
}

/// Wilson score-interval **lower bound** for a binomial proportion [successes] /
/// [trials] at confidence set by [z] (1.96 ≈ 95%). Returns 0 for zero trials.
/// Unlike the naïve `p̂ ± z·√(p̂(1−p̂)/n)`, the Wilson bound stays inside [0, 1]
/// and is sharply pessimistic for small [trials], which is exactly the small-
/// sample safety we want on a "can we trust this model" decision.
double wilsonLowerBound(int successes, int trials, {double z = 1.96}) {
  if (trials <= 0) return 0.0;
  final n = trials.toDouble();
  final pHat = successes / n;
  final z2 = z * z;
  final denom = 1 + z2 / n;
  final centre = pHat + z2 / (2 * n);
  final margin = z * math.sqrt((pHat * (1 - pHat) + z2 / (4 * n)) / n);
  final lower = (centre - margin) / denom;
  return lower.clamp(0.0, 1.0);
}

/// One held-out prediction paired with the caregiver's actual verdict, used to
/// score the model for graduation.
class LabeledPrediction {
  const LabeledPrediction(
      {required this.predictedPass, required this.actualPass});

  /// The model called this attempt a Pass.
  final bool predictedPass;

  /// The caregiver actually passed it.
  final bool actualPass;
}

/// The result of a graduation evaluation. [graduated] is the only thing callers
/// should gate on; the rest is for the dashboard's "why not yet" explanation.
class GraduationStatus {
  const GraduationStatus({
    required this.truePositives,
    required this.predictedPositives,
    required this.precisionPointEstimate,
    required this.precisionLowerBound,
    required this.graduated,
    required this.reason,
  });

  final int truePositives;
  final int predictedPositives;
  final double precisionPointEstimate;
  final double precisionLowerBound;
  final bool graduated;
  final String reason;

  /// The untrained baseline: nothing scored, not graduated.
  static const GraduationStatus untrained = GraduationStatus(
    truePositives: 0,
    predictedPositives: 0,
    precisionPointEstimate: 0,
    precisionLowerBound: 0,
    graduated: false,
    reason: 'Model untrained — abstaining; the caregiver decides every verdict.',
  );
}
