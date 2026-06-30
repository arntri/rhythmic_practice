import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:image_picker/image_picker.dart';
import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';

import 'audio_crypto.dart';

/// Stores name-card photos (therapy addendum §6): pick one from the gallery,
/// encrypt it at rest with the same AES key as the audio clips, and decrypt it
/// for display. Device-gated (image picker + secure-storage key), so not
/// unit-tested; both calls degrade to null rather than throwing.
class PhotoStore {
  PhotoStore({AudioCrypto? crypto, ImagePicker? picker})
      : _crypto = crypto ?? AudioCrypto(),
        _picker = picker ?? ImagePicker();

  final AudioCrypto _crypto;
  final ImagePicker _picker;

  /// Pick a photo from the gallery and save it AES-encrypted under `photos/`.
  /// Returns the encrypted file path, or null if the user cancelled or it failed.
  Future<String?> pickFromGallery(int phraseId) async {
    try {
      final picked = await _picker.pickImage(
        source: ImageSource.gallery,
        maxWidth: 1280, // downscale — a name card needs no more
        imageQuality: 85,
      );
      if (picked == null) return null; // cancelled
      final bytes = await File(picked.path).readAsBytes();
      final dir = await getApplicationDocumentsDirectory();
      final photos = Directory(p.join(dir.path, 'photos'));
      if (!await photos.exists()) await photos.create(recursive: true);
      final dest = p.join(photos.path, 'phrase_$phraseId.enc');
      return await _crypto.encryptBytes(bytes, dest);
    } catch (e) {
      debugPrint('PhotoStore: pick/save failed: $e');
      return null;
    }
  }

  /// Decrypt a stored photo to image bytes, or null on any failure (so a missing
  /// or corrupt photo never breaks practice — the card just shows text).
  Future<Uint8List?> decrypt(String encryptedPath) async {
    try {
      return await _crypto.decryptFile(encryptedPath);
    } catch (e) {
      debugPrint('PhotoStore: decrypt failed: $e');
      return null;
    }
  }
}
