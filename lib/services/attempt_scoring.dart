import 'package:flutter/foundation.dart';

import '../analysis/attempt_analyzer.dart';
import '../analysis/mfcc.dart';
import '../analysis/wav_reader.dart';
import '../data/practice_repository.dart';
import 'audio_crypto.dart';

/// Decrypts an at-rest clip to its raw WAV bytes. Injectable so the scoring
/// pipeline can be unit-tested without the OS keystore.
typedef ClipDecryptor = Future<Uint8List> Function(String path);

/// Phase 2B: scores a captured attempt against its phrase's recorded guide.
///
/// Pipeline (all device-independent once the bytes are in hand): decrypt the
/// attempt + the guide → MFCC the guide as the DTW reference → run the analyzer
/// (junk gate + similarity) → persist the feature vector → on a caregiver Pass,
/// consider promoting the attempt's MFCC to the phrase's anchor.
///
/// Wraps everything so a failure never disrupts the practice loop.
class AttemptScoring {
  AttemptScoring({
    PracticeRepository? repo,
    ClipDecryptor? decryptor,
    AttemptAnalyzer? analyzer,
    Mfcc? mfcc,
  })  : _repo = repo ?? PracticeRepository(),
        _decrypt = decryptor ?? AudioCrypto().decryptFile,
        _analyzer = analyzer ?? AttemptAnalyzer(),
        _mfcc = mfcc ?? Mfcc();

  final PracticeRepository _repo;
  final ClipDecryptor _decrypt;
  final AttemptAnalyzer _analyzer;
  final Mfcc _mfcc;

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
      final attemptSamples = WavReader.decode(await _decrypt(encryptedAttemptPath));
      final guideSamples = WavReader.decode(await _decrypt(guideClipPath));

      // The recorded guide is the DTW reference (therapy addendum §1).
      final referenceMfcc = _mfcc.extract(guideSamples);
      final result =
          _analyzer.analyzeSamples(attemptSamples, anchorMfcc: referenceMfcc);

      await _repo.insertFeatureVector(attemptId: attemptId, result: result);

      // Promote to anchor only on a clean, caregiver-confirmed (Pass) attempt.
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
