// DTW alignment tests (Phase 2A step 3). Pure hand-built MFCC-like sequences,
// so every expected number is checkable on paper.

import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:rhythmic_practice/analysis/dtw.dart';

/// Build a sequence of frames from plain lists, e.g. seq([[0,0],[1,1]]).
List<Float64List> seq(List<List<double>> frames) =>
    frames.map((f) => Float64List.fromList(f)).toList();

void main() {
  group('identity', () {
    test('a sequence aligned with itself has cost 0 and similarity 1.0', () {
      final a = seq([
        [0, 0, 0],
        [1, 2, 3],
        [-1, 4, 2],
        [5, 5, 5],
      ]);
      final r = Dtw.align(a, a);
      expect(r.normalizedCost, 0.0);
      expect(r.similarity, 1.0);
    });
  });

  group('hand-checkable cost', () {
    test('single-frame sequences: euclidean 5 -> similarity 1/6', () {
      // dist([0,0],[3,4]) = 5; path length 1; normalizedCost = 5/1 = 5.
      // similarity = 1/(1+5) = 1/6.
      final r = Dtw.align(seq([
        [0, 0]
      ]), seq([
        [3, 4]
      ]));
      expect(r.normalizedCost, closeTo(5.0, 1e-12));
      expect(r.similarity, closeTo(1 / 6, 1e-12));
    });
  });

  group('symmetry', () {
    test('align(a,b) equals align(b,a)', () {
      final a = seq([
        [0, 0],
        [1, 1],
        [2, 0],
      ]);
      final b = seq([
        [0, 1],
        [1, 2],
      ]);
      final ab = Dtw.align(a, b);
      final ba = Dtw.align(b, a);
      expect(ab.normalizedCost, closeTo(ba.normalizedCost, 1e-12));
      expect(ab.similarity, closeTo(ba.similarity, 1e-12));
    });
  });

  group('ordering / monotonicity', () {
    test('more similar sequences score higher', () {
      final base = seq([
        [0, 0],
        [1, 1],
        [2, 2],
        [3, 3],
      ]);
      final near = seq([
        [0.1, 0.0],
        [1.0, 1.1],
        [2.1, 2.0],
        [3.0, 2.9],
      ]);
      final far = seq([
        [9, 9],
        [8, 7],
        [1, 0],
        [4, 6],
      ]);
      final simNear = Dtw.similarity(base, near);
      final simFar = Dtw.similarity(base, far);
      expect(simNear, greaterThan(simFar));
      // Sanity on the range.
      expect(simNear, inInclusiveRange(0.0, 1.0));
      expect(simFar, inInclusiveRange(0.0, 1.0));
    });

    test('time-warp tolerance: a stretched copy still scores very high', () {
      // Same "shape," but the middle frame is held for two steps.
      final a = seq([
        [0, 0],
        [5, 5],
        [10, 10],
      ]);
      final stretched = seq([
        [0, 0],
        [5, 5],
        [5, 5],
        [10, 10],
      ]);
      // The repeated frame aligns onto the original at zero extra cost.
      expect(Dtw.similarity(a, stretched), 1.0);
    });
  });

  group('edges & determinism', () {
    test('empty input gives similarity 0', () {
      expect(Dtw.similarity(seq([]), seq([
            [1, 1]
          ])), 0.0);
      expect(Dtw.align(seq([]), seq([])).normalizedCost, double.infinity);
    });

    test('repeated calls are identical', () {
      final a = seq([
        [0, 1],
        [2, 3],
        [4, 5]
      ]);
      final b = seq([
        [0, 0],
        [2, 2],
        [5, 5]
      ]);
      expect(Dtw.align(a, b).similarity, Dtw.align(a, b).similarity);
      expect(Dtw.align(a, b).normalizedCost, Dtw.align(a, b).normalizedCost);
    });
  });
}
