import 'dart:convert';

import 'package:encrypt/encrypt.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:rhythmic_practice/services/audio_crypto.dart';

void main() {
  final key = Key.fromLength(32); // fixed all-zero key for a deterministic test

  test('encrypt then decrypt round-trips the original bytes', () {
    final plain = utf8.encode('a pretend voice clip — raw audio bytes here');
    final cipher = AesCipher.encrypt(plain, key);
    final back = AesCipher.decrypt(cipher, key);
    expect(back, equals(plain));
  });

  test('ciphertext differs from plaintext and carries the 16-byte IV', () {
    final plain = utf8.encode('hello hello hello');
    final cipher = AesCipher.encrypt(plain, key);
    expect(cipher.sublist(16), isNot(equals(plain))); // body is encrypted
    expect(cipher.length, greaterThan(plain.length + 16)); // IV + padding
  });

  test('same plaintext encrypts differently each time (random IV)', () {
    final plain = utf8.encode('repeatable input');
    final a = AesCipher.encrypt(plain, key);
    final b = AesCipher.encrypt(plain, key);
    expect(a, isNot(equals(b))); // IVs differ -> ciphertexts differ
    expect(AesCipher.decrypt(a, key), equals(AesCipher.decrypt(b, key)));
  });

  test('a larger binary payload round-trips (realistic clip size)', () {
    // Stand-in for raw audio bytes: not block-aligned, full 0..255 range.
    final plain = List<int>.generate(5000, (i) => (i * 7 + 3) % 256);
    final cipher = AesCipher.encrypt(plain, key);
    expect(AesCipher.decrypt(cipher, key), equals(plain));
  });
}
