import 'dart:io';

// Prefixed: `Key` also names a Flutter widget key via foundation.dart.
import 'package:encrypt/encrypt.dart' as crypt;
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
/// The whole heavy path — reading the clips, AES-decrypting them, decoding the
/// WAVs, then MFCC + DTW + onsets — runs **off the UI thread** in a background
/// isolate (audit item 21). Only the keystore lookup for the AES key stays on the
/// caller's thread, because platform channels are reachable only from the root
/// isolate; the key then travels with the request so the cipher work goes with it.
/// This matters at the caregiver verdict, where scoring runs while the metronome
/// is still beating: decrypting two multi-second clips on the UI thread starved
/// the metronome's Ticker and made the beat stutter. Everything is wrapped so a
/// failure never disrupts the practice loop.
class AttemptScoring {
  AttemptScoring({
    PracticeRepository? repo,
    ClipDecryptor? decryptor,
    AudioCrypto? crypto,
    this.runInIsolate = true,
  })  : _repo = repo ?? PracticeRepository(),
        _decrypt = decryptor,
        _crypto = crypto ?? AudioCrypto();

  final PracticeRepository _repo;

  /// Test seam: when supplied, clips are resolved to plaintext WAV bytes on this
  /// thread and handed to the worker as bytes, so a test never needs the OS
  /// keystore. Left null in production, where the worker reads and decrypts the
  /// files itself (see [ClipRef]).
  final ClipDecryptor? _decrypt;
  final AudioCrypto _crypto;

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
      // Only the keystore lookup happens here (a cheap platform-channel read);
      // the file read, AES and WAV decode all travel into the worker with it.
      final decrypt = _decrypt;
      final ClipRef attemptRef;
      final ClipRef guideRef;
      if (decrypt != null) {
        attemptRef = ClipRef.wav(await decrypt(encryptedAttemptPath));
        guideRef = ClipRef.wav(await decrypt(guideClipPath));
      } else {
        final key = await _crypto.keyBytes();
        attemptRef = ClipRef.encrypted(encryptedAttemptPath, key);
        guideRef = ClipRef.encrypted(guideClipPath, key);
      }

      // Item 21: decrypt + decode + MFCC + DTW + onsets off the UI thread (or
      // inline in tests). A ClipRef is plain TypedData/String — cheap to send.
      final req = ScoreRequest(attempt: attemptRef, guide: guideRef);
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

/// How the worker gets one clip's audio: either plaintext WAV bytes we already
/// hold (the test seam), or an encrypted file it should read and decrypt itself
/// with [key] (production — this is what keeps AES off the UI thread). Both
/// shapes are plain TypedData/String, so a ClipRef crosses an isolate boundary.
class ClipRef {
  const ClipRef.wav(Uint8List wavBytes)
      : _wav = wavBytes,
        _path = null,
        _key = null;

  const ClipRef.encrypted(String path, Uint8List key)
      : _wav = null,
        _path = path,
        _key = key;

  final Uint8List? _wav;
  final String? _path;
  final Uint8List? _key;

  /// Resolve to 16 kHz mono samples. Called **inside** the worker, so the file
  /// read and the AES pass are charged to the worker, not the UI thread.
  Float64List decode() {
    final wav = _wav;
    if (wav != null) return WavReader.decode(wav);
    return WavReader.decode(
      AesCipher.decrypt(File(_path!).readAsBytesSync(), crypt.Key(_key!)),
    );
  }
}

/// Input for the off-thread scoring step (item 21) — sendable across an isolate
/// boundary.
class ScoreRequest {
  const ScoreRequest({required this.attempt, required this.guide});
  final ClipRef attempt;
  final ClipRef guide;
}

/// Output of the off-thread scoring step: the analysis result plus the patient's
/// detected syllable onsets. All fields are sendable back across the isolate.
class ScoredClip {
  const ScoredClip({required this.result, required this.onsets});
  final AnalysisResult result;
  final List<int> onsets;
}

/// The device-independent pipeline (audit item 21) — a **top-level** function so
/// it can run inside a `compute()` isolate: resolve each clip to samples
/// (reading and AES-decrypting it here, off the UI thread), MFCC the guide as
/// the DTW reference, run the analyzer (junk gate + similarity), and — only on a
/// gate-passed clip — detect the patient's own syllable onsets (item 16c; their
/// onsets on junk/silence would be noise). Device-independent, but no longer
/// I/O-free: [ClipRef.encrypted] reads its file here deliberately.
ScoredClip scoreClipSync(ScoreRequest req) {
  final attempt = req.attempt.decode();
  final guide = req.guide.decode();
  final referenceMfcc = Mfcc().extract(guide);
  final result =
      AttemptAnalyzer().analyzeSamples(attempt, anchorMfcc: referenceMfcc);
  final onsets =
      result.gatePassed ? detectSyllableNuclei(attempt).nucleiMs : const <int>[];
  return ScoredClip(result: result, onsets: onsets);
}
