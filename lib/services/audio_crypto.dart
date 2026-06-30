import 'dart:io';
import 'dart:typed_data';

import 'package:encrypt/encrypt.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';

/// Pure AES-CBC encrypt/decrypt with a fresh random IV prepended to the output.
/// No platform channels — unit-testable on its own with a fixed key.
class AesCipher {
  /// Returns `IV (16 bytes) || ciphertext`.
  static Uint8List encrypt(List<int> plain, Key key) {
    final iv = IV.fromSecureRandom(16);
    final encrypter = Encrypter(AES(key, mode: AESMode.cbc));
    final encrypted = encrypter.encryptBytes(plain, iv: iv);
    return Uint8List.fromList([...iv.bytes, ...encrypted.bytes]);
  }

  /// Inverse of [encrypt]: reads the leading IV, then decrypts the remainder.
  static Uint8List decrypt(Uint8List ivAndCipher, Key key) {
    final iv = IV(Uint8List.fromList(ivAndCipher.sublist(0, 16)));
    final encrypter = Encrypter(AES(key, mode: AESMode.cbc));
    final plain =
        encrypter.decryptBytes(Encrypted(ivAndCipher.sublist(16)), iv: iv);
    return Uint8List.fromList(plain);
  }
}

/// Encrypts raw voice clips at rest (brief §6). A single AES key is generated
/// once and kept in the OS keystore (Keychain / Keystore) via
/// [FlutterSecureStorage] — it never sits in plaintext on disk or in the DB.
class AudioCrypto {
  AudioCrypto([FlutterSecureStorage? storage])
      : _storage = storage ?? const FlutterSecureStorage();

  final FlutterSecureStorage _storage;
  static const _keyName = 'audio_aes_key_v1';

  /// The per-install key, created on first use and reused thereafter.
  Future<Key> _key() async {
    final existing = await _storage.read(key: _keyName);
    if (existing != null) return Key.fromBase64(existing);
    final key = Key.fromSecureRandom(32); // AES-256
    await _storage.write(key: _keyName, value: key.base64);
    return key;
  }

  /// Encrypt [plainFile] to [destPath], then delete the plaintext source.
  /// Returns the encrypted file's path (what we store in the DB).
  Future<String> encryptFile(File plainFile, String destPath) async {
    final key = await _key();
    final bytes = await plainFile.readAsBytes();
    final out = AesCipher.encrypt(bytes, key);
    await File(destPath).writeAsBytes(out, flush: true);
    if (await plainFile.exists()) await plainFile.delete();
    return destPath;
  }

  /// Encrypt in-memory [plainBytes] to [destPath] (no plaintext ever hits disk).
  /// Returns the encrypted file's path.
  Future<String> encryptBytes(List<int> plainBytes, String destPath) async {
    final key = await _key();
    final out = AesCipher.encrypt(plainBytes, key);
    await File(destPath).writeAsBytes(out, flush: true);
    return destPath;
  }

  /// Decrypt an at-rest clip back to raw bytes (e.g. for a future review step).
  Future<Uint8List> decryptFile(String path) async {
    final key = await _key();
    final data = await File(path).readAsBytes();
    return AesCipher.decrypt(data, key);
  }
}
