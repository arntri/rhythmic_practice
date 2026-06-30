import 'dart:io';

import '../data/practice_repository.dart';

/// Deletes a single audio file. Injectable so tests can avoid touching real
/// files (and so the policy of "missing file is fine" lives in one place).
typedef FileDeleter = Future<void> Function(String path);

/// The 48-hour audio eviction job (brief §6 Privacy).
///
/// Raw audio clips live only briefly in a local, sandboxed cache. This routine
/// deletes any clip older than [maxAge] and sets its `local_encrypted_audio_path`
/// to NULL — but KEEPS the attempt row and all its numeric fields. No data
/// leaves the device; this only forgets the audio.
///
/// Pure and testable: the clock ([evictExpired]'s `now`) and the file deleter
/// are both injectable, so a test can create old/recent rows and temp files and
/// check exactly what gets removed.
class AudioEvictionService {
  AudioEvictionService(
    this._repo, {
    FileDeleter? fileDeleter,
    this._maxAge = const Duration(hours: 48),
  }) : _delete = fileDeleter ?? _defaultDelete;

  final PracticeRepository _repo;
  final FileDeleter _delete;
  final Duration _maxAge;

  static Future<void> _defaultDelete(String path) async {
    final file = File(path);
    if (await file.exists()) await file.delete();
  }

  /// Removes audio older than [maxAge]. Returns how many clips were evicted.
  /// Pass [now] in tests for deterministic results; defaults to the real time.
  Future<int> evictExpired({DateTime? now}) async {
    final cutoff = (now ?? DateTime.now()).toUtc().subtract(_maxAge);
    final stale = await _repo.getAttemptsWithAudioBefore(_sqliteUtc(cutoff));

    for (final attempt in stale) {
      final path = attempt.localEncryptedAudioPath;
      if (path != null) {
        // A missing/already-deleted file is fine — keep going and null the path.
        try {
          await _delete(path);
        } catch (_) {/* ignore: we still want to forget the path */}
      }
      await _repo.clearAudioPath(attempt.attemptId);
    }
    return stale.length;
  }

  // Formats a UTC time the way SQLite's CURRENT_TIMESTAMP stores it, so string
  // comparison against the `timestamp` column is correct.
  static String _sqliteUtc(DateTime utc) {
    String two(int n) => n.toString().padLeft(2, '0');
    final y = utc.year.toString().padLeft(4, '0');
    return '$y-${two(utc.month)}-${two(utc.day)} '
        '${two(utc.hour)}:${two(utc.minute)}:${two(utc.second)}';
  }
}
