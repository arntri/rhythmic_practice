import 'dart:typed_data';

import 'dtw.dart';
import 'junk_gate.dart';
import 'mfcc.dart';
import 'wav_reader.dart';

/// The one public door into the analysis core (Phase 2A brief §2).
///
/// Everything upstream — and eventually the live capture path in Phase 2B —
/// hands this a **WAV file on disk** plus an optional comparison **template**
/// (the MFCCs of the bundled reference clip, or of the user's anchor), and gets
/// back a single [AnalysisResult]: did the clip pass the junk gate, how similar
/// is it to the template, how long was it, and the MFCC sequence we extracted
/// (so the caller can persist or promote it without recomputing).
///
/// It deliberately does NO database, UI, or microphone work — it's a pure
/// function from (samples, template) to result. That's what lets Phase 2B wire
/// the real recorded file path straight in with nothing here needing to change.
class AttemptAnalyzer {
  AttemptAnalyzer({Mfcc? mfcc}) : _mfcc = mfcc ?? Mfcc();

  final Mfcc _mfcc;

  /// Analyze a WAV file at [path]. [anchorMfcc] is the comparison template; pass
  /// null when no template exists yet (the result then has no similarity score).
  Future<AnalysisResult> analyzeFile(
    String path, {
    List<Float64List>? anchorMfcc,
  }) async {
    final samples = await WavReader.readFile(path);
    return analyzeSamples(samples, anchorMfcc: anchorMfcc);
  }

  /// Analyze already-decoded samples. Useful for tests and for callers that
  /// already hold the buffer. The pipeline is: gate → (if passed) MFCC → (if a
  /// template was given) DTW similarity.
  AnalysisResult analyzeSamples(
    Float64List samples, {
    List<Float64List>? anchorMfcc,
  }) {
    final gate = JunkGate.evaluate(samples);
    if (!gate.passed) {
      // Rejected clips get no MFCC and no similarity score, by design.
      return AnalysisResult(
        gatePassed: false,
        gateReason: gate.reason,
        contentSimilarityScore: null,
        durationMs: gate.durationMs,
        mfcc: const [],
      );
    }

    final mfcc = _mfcc.extract(samples);
    final score =
        anchorMfcc == null ? null : Dtw.similarity(mfcc, anchorMfcc);

    return AnalysisResult(
      gatePassed: true,
      gateReason: gate.reason, // 'ok'
      contentSimilarityScore: score,
      durationMs: gate.durationMs,
      mfcc: mfcc,
    );
  }
}

/// Everything the caller needs from one analyzed attempt. Maps closely onto the
/// `acoustic_feature_vectors` row (brief §5) plus the MFCC sequence used for
/// anchor promotion.
class AnalysisResult {
  const AnalysisResult({
    required this.gatePassed,
    required this.gateReason,
    required this.contentSimilarityScore,
    required this.durationMs,
    required this.mfcc,
  });

  /// Whether the junk gate accepted the clip.
  final bool gatePassed;

  /// Gate reason code: `'ok'`, `'too_quiet'`, `'too_short'`, `'too_long'`.
  final String gateReason;

  /// 0..1 similarity vs the supplied template. Null if the gate rejected the
  /// clip OR no template was supplied.
  final double? contentSimilarityScore;

  /// Clip length in milliseconds (from the sample count).
  final int durationMs;

  /// Extracted MFCC sequence (frames × coeffs). Empty when the gate rejected the
  /// clip. The caller can persist this or promote it to an anchor.
  final List<Float64List> mfcc;
}
