import 'package:flutter_test/flutter_test.dart';
import 'package:rhythmic_practice/data/models.dart';
import 'package:rhythmic_practice/ml/graduation_gate.dart';
import 'package:rhythmic_practice/ml/layer_c_classifier.dart';

void main() {
  group('Wilson lower bound', () {
    test('zero trials → 0', () {
      expect(wilsonLowerBound(0, 0), 0.0);
    });

    test('is pessimistic on tiny samples (9/10 nowhere near 0.90)', () {
      // 90% point estimate but only 10 trials → lower bound well under 0.90.
      final lb = wilsonLowerBound(9, 10);
      expect(lb, lessThan(0.90));
      expect(lb, greaterThan(0.5));
    });

    test('tightens toward the point estimate as n grows', () {
      final small = wilsonLowerBound(90, 100);
      final big = wilsonLowerBound(900, 1000);
      expect(big, greaterThan(small));
      expect(big, lessThan(0.90)); // 900/1000 still just under 0.90 lower bound
    });

    test('a strong large sample clears 0.90', () {
      final lb = wilsonLowerBound(485, 500); // 97% over 500
      expect(lb, greaterThan(0.90));
    });

    test('bound stays within [0,1]', () {
      expect(wilsonLowerBound(0, 5), inInclusiveRange(0.0, 1.0));
      expect(wilsonLowerBound(5, 5), inInclusiveRange(0.0, 1.0));
    });
  });

  group('GraduationGate', () {
    const gate = GraduationGate();

    List<LabeledPrediction> preds(int tp, int fp, {int abstain = 0}) => [
          for (var i = 0; i < tp; i++)
            const LabeledPrediction(predictedPass: true, actualPass: true),
          for (var i = 0; i < fp; i++)
            const LabeledPrediction(predictedPass: true, actualPass: false),
          for (var i = 0; i < abstain; i++)
            const LabeledPrediction(predictedPass: false, actualPass: true),
        ];

    test('no Pass predictions → not graduated, explains why', () {
      final s = gate.evaluate(preds(0, 0, abstain: 20));
      expect(s.graduated, isFalse);
      expect(s.predictedPositives, 0);
      expect(s.reason, contains('No Pass predictions'));
    });

    test('too few predictions → not graduated even at 100% point precision', () {
      final s = gate.evaluate(preds(10, 0)); // perfect but only 10
      expect(s.precisionPointEstimate, 1.0);
      expect(s.graduated, isFalse);
      expect(s.reason, contains('need 30'));
    });

    test('enough predictions but precision lower bound below floor → held back', () {
      final s = gate.evaluate(preds(45, 5)); // 90% over 50, lb < 0.90
      expect(s.predictedPositives, 50);
      expect(s.graduated, isFalse);
      expect(s.reason, contains('below'));
    });

    test('graduates only with a confidently-high precision', () {
      final s = gate.evaluate(preds(198, 2)); // 99% over 200
      expect(s.graduated, isTrue);
      expect(s.precisionLowerBound, greaterThanOrEqualTo(0.90));
    });

    test('untrained baseline never graduates', () {
      expect(GraduationStatus.untrained.graduated, isFalse);
    });
  });

  group('Layer C classifier scaffold', () {
    test('untrained classifier always abstains (build, do not run)', () {
      const clf = UntrainedLayerC();
      final f = LayerCFeatures(rung: 6, contentSimilarity: 0.95, tapSyncScore: 0.9);
      final p = clf.predict(f);
      expect(p.abstained, isTrue);
      expect(p.confidence, 0);
    });

    test('feature assembly derives ITI CoV, dwell, onset steadiness from logs', () {
      final attempt = ExerciseAttempt(
        attemptId: 'a1',
        sessionId: 's1',
        phraseId: 1,
        timestamp: 't',
        latencyMs: 200,
        durationMs: 900,
        tappingSynchronizationScore: 0.8,
        evaluationLabel: 1,
        localEncryptedAudioPath: null,
        rungAtAttempt: 6,
        tierAtAttempt: 1,
        tempoBpm: 60,
      );
      const vector = FeatureVector(
        vectorId: 'v1',
        attemptId: 'a1',
        contentSimilarityScore: 0.9,
        mfccDistance: 0.3,
        gatePassed: true,
        gateReason: 'ok',
        durationMs: 900,
        onsetMs: [0, 400, 800, 1200], // perfectly even → steadiness 1.0
      );
      final taps = <StoredTapEvent>[
        for (var i = 0; i < 4; i++)
          StoredTapEvent(
            tapId: 't$i',
            attemptId: 'a1',
            phraseId: 1,
            sessionId: 's1',
            rung: 6,
            tapIndex: i,
            downMs: i * 500, // steady → CoV 0
            dwellMs: 100,
            beatPhase: null,
          ),
      ];
      final f = LayerCFeatures.fromLoggedAttempt(
          attempt: attempt, vector: vector, taps: taps);
      expect(f.rung, 6);
      expect(f.tier, 1);
      expect(f.tempoBpm, 60);
      expect(f.contentSimilarity, 0.9);
      expect(f.mfccDistance, 0.3);
      expect(f.itiCoefficientOfVariation, closeTo(0, 1e-9));
      expect(f.meanDwellMs, 100);
      expect(f.onsetSteadiness, closeTo(1.0, 1e-9));
    });

    test('missing channels assemble to null, not a crash', () {
      const attempt = ExerciseAttempt(
        attemptId: 'a2',
        sessionId: 's1',
        phraseId: 1,
        timestamp: 't',
        latencyMs: null,
        durationMs: null,
        tappingSynchronizationScore: null,
        evaluationLabel: 2,
        localEncryptedAudioPath: null,
        rungAtAttempt: 2,
      );
      final f = LayerCFeatures.fromLoggedAttempt(attempt: attempt);
      expect(f.rung, 2);
      expect(f.contentSimilarity, isNull);
      expect(f.itiCoefficientOfVariation, isNull);
      expect(f.onsetSteadiness, isNull);
      expect(f.tier, isNull);
    });
  });
}
