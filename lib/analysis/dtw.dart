import 'dart:math' as math;
import 'dart:typed_data';

/// **Dynamic Time Warping** (DTW) — how we measure whether two recordings are
/// "the same word," even when one is spoken faster or slower than the other
/// (Phase 2A brief §3).
///
/// ### The problem DTW solves, in plain language
/// Two takes of the same word are never the same length: the speaker draws out a
/// vowel here, clips a consonant there. If we compared them frame-by-frame in
/// lock-step, that timing wobble alone would make them look different. DTW
/// instead finds the best *alignment* — it stretches and squeezes the time axis
/// of one sequence to match the other as closely as possible — and reports how
/// much the *shapes* still differ once timing is accounted for.
///
/// It does this with a classic dynamic-programming grid: cell (i, j) holds the
/// cheapest total cost to align the first i frames of A with the first j frames
/// of B. Each cell can come from the cell below, the left, or the diagonal
/// (which is what lets one frame stretch to match several, or vice-versa).
///
/// We normalize the final cost by the **length of the alignment path** so that
/// longer words don't automatically look "more different," then map cost to a
/// 0..1 similarity with `1 / (1 + cost)` — higher means more alike, exactly 1.0
/// means identical.
///
/// Pure Dart, deterministic: same two sequences in → same score out.
class Dtw {
  /// Align two MFCC sequences (each `frames × coeffs`) and return the normalized
  /// cost and the derived similarity.
  ///
  /// If either sequence is empty there is nothing to align, so similarity is 0.
  static DtwResult align(List<Float64List> a, List<Float64List> b) {
    if (a.isEmpty || b.isEmpty) {
      return const DtwResult(normalizedCost: double.infinity, similarity: 0.0);
    }

    final n = a.length;
    final m = b.length;

    // Accumulated-cost grid. d[i][j] = cheapest cost to align a[0..i] with
    // b[0..j]. We fill it row by row using the recurrence
    //   d[i][j] = dist(a[i], b[j]) + min(d[i-1][j], d[i][j-1], d[i-1][j-1]).
    final d = List<Float64List>.generate(n, (_) => Float64List(m));

    d[0][0] = _dist(a[0], b[0]);
    // First column: can only have come from straight above.
    for (var i = 1; i < n; i++) {
      d[i][0] = _dist(a[i], b[0]) + d[i - 1][0];
    }
    // First row: can only have come from the left.
    for (var j = 1; j < m; j++) {
      d[0][j] = _dist(a[0], b[j]) + d[0][j - 1];
    }
    // Interior cells.
    for (var i = 1; i < n; i++) {
      for (var j = 1; j < m; j++) {
        final best = math.min(
          d[i - 1][j - 1],
          math.min(d[i - 1][j], d[i][j - 1]),
        );
        d[i][j] = _dist(a[i], b[j]) + best;
      }
    }

    // Backtrack from the corner to count how many cells the optimal path uses.
    // We normalize by this so the score reflects average per-step difference,
    // not total word length. Tie-break order (diagonal, up, left) is fixed so
    // the path length — and thus the score — is fully deterministic.
    var i = n - 1;
    var j = m - 1;
    var pathLength = 1;
    while (i > 0 || j > 0) {
      if (i > 0 && j > 0) {
        final diag = d[i - 1][j - 1];
        final up = d[i - 1][j];
        final left = d[i][j - 1];
        if (diag <= up && diag <= left) {
          i--;
          j--;
        } else if (up <= left) {
          i--;
        } else {
          j--;
        }
      } else if (i > 0) {
        i--;
      } else {
        j--;
      }
      pathLength++;
    }

    final normalizedCost = d[n - 1][m - 1] / pathLength;
    return DtwResult(
      normalizedCost: normalizedCost,
      similarity: 1.0 / (1.0 + normalizedCost),
    );
  }

  /// Convenience: just the 0..1 similarity.
  static double similarity(List<Float64List> a, List<Float64List> b) =>
      align(a, b).similarity;

  /// Euclidean distance between two equal-length MFCC frames.
  static double _dist(Float64List x, Float64List y) {
    var sum = 0.0;
    for (var k = 0; k < x.length; k++) {
      final diff = x[k] - y[k];
      sum += diff * diff;
    }
    return math.sqrt(sum);
  }
}

/// The outcome of a DTW alignment.
class DtwResult {
  const DtwResult({required this.normalizedCost, required this.similarity});

  /// Total alignment cost divided by the path length. 0.0 means a perfect match;
  /// larger means more different. Infinity if a sequence was empty.
  final double normalizedCost;

  /// Normalized 0..1 score: `1 / (1 + normalizedCost)`. 1.0 = identical,
  /// approaching 0.0 = completely different.
  final double similarity;
}
