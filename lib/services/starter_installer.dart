import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart' show rootBundle;
import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';

import '../data/practice_repository.dart';
import '../data/starter_library.dart';
import 'audio_crypto.dart';

/// Installs the starter library's bundled guide clips into the encrypted guides
/// store on first launch (Part 3, item 13).
///
/// For each seeded starter phrase that has no guide yet, this reads its bundled
/// WAV asset, encrypts it with the per-install key (exactly like a recorded
/// guide) into the app's `guides/` dir, and points the phrase at it — so a
/// starter word plays and scores through the very same path as a caregiver
/// recording (no branching on `is_starter`). Idempotent (a phrase already
/// carrying a guide is skipped) and best-effort (any failure is logged and never
/// blocks startup).
///
/// SCAFFOLD: the bundled clips and their metadata are PLACEHOLDERS — see
/// `assets/audio/starter/README.md` and `lib/data/starter_library.dart`. The
/// user supplies real recordings + metadata later; this pipeline installs
/// whatever is bundled.
class StarterGuideInstaller {
  StarterGuideInstaller({PracticeRepository? repository, AudioCrypto? crypto})
      : _repo = repository ?? PracticeRepository(),
        _crypto = crypto ?? AudioCrypto();

  final PracticeRepository _repo;
  final AudioCrypto _crypto;

  /// Installs any not-yet-installed starter guides. Returns how many were
  /// installed this call (0 when there's nothing to do).
  Future<int> installMissing() async {
    final pending = await _repo.getStarterPhrasesNeedingGuide();
    if (pending.isEmpty) return 0;

    final guidesDir = await _guidesDir();
    var installed = 0;
    for (final phrase in pending) {
      final starter = _starterFor(phrase.phraseText);
      if (starter == null) continue; // a starter row with no bundled asset
      try {
        final data = await rootBundle.load('assets/${starter.assetPath}');
        final wav = data.buffer
            .asUint8List(data.offsetInBytes, data.lengthInBytes);
        final dest = p.join(guidesDir.path, 'starter_${phrase.phraseId}.enc');
        final encPath = await _crypto.encryptBytes(wav, dest);
        await _repo.attachGuideClipPath(phrase.phraseId, encPath);
        installed++;
      } catch (e) {
        // Best-effort: a failed install just leaves the phrase needing a guide.
        debugPrint('Starter install failed for "${phrase.phraseText}": $e');
      }
    }
    return installed;
  }

  StarterPhrase? _starterFor(String phraseText) {
    for (final s in starterLibrary) {
      if (s.text == phraseText) return s;
    }
    return null;
  }

  Future<Directory> _guidesDir() async {
    final dir = await getApplicationDocumentsDirectory();
    final guides = Directory(p.join(dir.path, 'guides'));
    if (!await guides.exists()) await guides.create(recursive: true);
    return guides;
  }
}
