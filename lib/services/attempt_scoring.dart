import 'package:flutter/foundation.dart';

import '../analysis/attempt_analyzer.dart';
import '../analysis/mfcc.dart';
import '../analysis/wav_reader.dart';
import '../data/practice_repository.dart';
import '../practice/syllable_detection.dart';
import 'audio_crypto.dart';

/// Decrypts an at-rest clip to its raw WAV bytes. Injectable so the scoring
/// pipeline can be unit-tested without the OS keystore.
typedef ClipDecryptor = Future<Uint8List> Function(String path);

/// Phase 2B: scores a captured attempt against its phrase's recorded guide.
///
/// Pipeline (all device-independent once the bytes are in hand): decrypt the
/// attempt + the guide → MFCC the guide as the DTW reference → run the analyzer
/// (junk gate + similarity) → detect the patient's onsets → persist the feature
/// vector → on a caregiver Pass, consider promoting the attempt's MFCC to the
/// phrase's anchor.
///
/// The heavy MFCC + DTW + onset step runs **off the UI thread** in a background
/// isolate (audit item 21) so a long clip never janks the practice screen; only
/// the keystore-touching decryption stays on the caller's thread. Everything is
/// wrapped so a failure never disrupts the practice loop.
class AttemptScoring {
  AttemptScoring({
    PracticeRepository? repo,
    ClipDecryptor? decryptor,
    this.runInIsolate = true,
  })  : _repo = repo ?? PracticeRepository(),
        _decrypt = decryptor ?? AudioCrypto().decryptFile;

  final PracticeRepository _repo;
  final ClipDecryptor _decrypt;

  /// Run the CPU pipeline in a background isolate (default). Tests set this false
  /// to run inline — deterministic and without spawning an isolate.
  final bool runInIsolate;

  /// Score [attemptId] for [phraseId]. No-op (returns false) when there's no
  /// attempt clip or no recorded guide to compare against. Returns true once a
  /// feature vector was stored. Never throws.
  Future<bool> scoreAttempt({
    required String attemptId,
    required int phraseId,
    required String profileId,
    required String? encryptedAttemptPath,
    required String? guideClipPath,
    required int evaluationLabel,
  }) async {
    if (encryptedAttemptPath == null || guideClipPath == null) return false;
    try {
      // Decryption touches the OS keystore, so it stays on this thread.
      final attemptSamples =
          WavReader.decode(await _decrypt(encryptedAttemptPath));
      final guideSamples = WavReader.decode(await _decrypt(guideClipPath));

      // Item 21: MFCC + DTW + onset detection off the UI thread (or inline in
      // tests). The samples are plain TypedData, cheap to hand to the isolate.
      final req = ScoreRequest(attempt: attemptSamples, guide: guideSamples);
      final scored =
          runInIsolate ? await compute(scoreClipSync, req) : scoreClipSync(req);

      await _repo.insertFeatureVector(
          attemptId: attemptId, result: scored.result, onsetMs: scored.onsets);

      // Promote to anchor only on a clean, caregiver-confirmed (Pass) attempt.
      final result = scored.result;
      if (result.gatePassed &&
          evaluationLabel == 1 &&
          result.contentSimilarityScore != null) {
        await _repo.considerAnchor(
          profileId: profileId,
          phraseId: phraseId,
          sourceAttemptId: attemptId,
          mfcc: result.mfcc,
          scoreVsReference: result.contentSimilarityScore!,
        );
      }
      return true;
    } catch (e) {
      debugPrint('AttemptScoring failed for $attemptId: $e');
      return false;
    }
  }
}

/// Input for the off-thread scoring step (item 21): the attempt and guide as raw
/// 16 kHz mono samples — sendable across an isolate boundary.
class ScoreRequest {
  const ScoreRequest({required this.attempt, required this.guide});
  final Float64List attempt;
  final Float64List guide;
}

/// Output of the off-thread scoring step: the analysis result plus the patient's
/// detected syllable onsets. All fields are sendable back across the isolate.
class ScoredClip {
  const ScoredClip({required this.result, required this.onsets});
  final AnalysisResult result;
  final List<int> onsets;
}

/// The device-independent CPU pipeline (audit item 21) — a **top-level** function
/// so it can run inside a `compute()` isolate: MFCC the guide as the DTW
/// reference, run the analyzer (junk gate + similarity), and — only on a
/// gate-passed clip — detect the patient's own syllable onsets (item 16c; their
/// onsets on junk/silence would be noise). Pure, no I/O.
ScoredClip scoreClipSync(ScoreRequest req) {
  final referenceMfcc = Mfcc().extract(req.guide);
  final result =
      AttemptAnalyzer().analyzeSamples(req.attempt, anchorMfcc: referenceMfcc);
  final onsets = result.gatePassed
      ? detectSyllableNuclei(req.attempt).nucleiMs
      : const <int>[];
  return ScoredClip(result: result, onsets: onsets);
}
