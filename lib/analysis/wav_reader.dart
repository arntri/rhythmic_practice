import 'dart:io';
import 'dart:typed_data';

import 'audio_config.dart';

/// Thrown when a WAV file isn't the exact format we accept. We "fail loudly"
/// (brief §3) rather than silently resampling or down-mixing, so a bad fixture
/// can never quietly corrupt the analysis numbers.
class WavFormatException implements Exception {
  WavFormatException(this.message);
  final String message;
  @override
  String toString() => 'WavFormatException: $message';
}

/// Decodes a 16 kHz / mono / PCM16 WAV file into floating-point samples.
///
/// WHY THIS EXISTS (brief §2): the analysis core operates on *audio files on
/// disk*, never on the live microphone. The contract is simply "capture writes a
/// WAV, this reads a WAV." So everything here is pure byte-parsing — no Flutter,
/// no plugins, no device — and it's fully testable with in-memory byte buffers.
///
/// ### A 30-second tour of the WAV format
/// A WAV file is a "RIFF" container: a 12-byte header (`'RIFF'`, total size,
/// `'WAVE'`) followed by a series of *chunks*. Each chunk is a 4-byte ASCII id,
/// a 4-byte little-endian size, then that many bytes of payload (padded to an
/// even length). We care about two chunks:
///   - `'fmt '` — describes the format (channels, sample rate, bit depth).
///   - `'data'` — the raw PCM samples themselves.
/// Other chunks (`'LIST'`, `'fact'`, …) may appear; we skip anything we don't
/// recognise, which is why we iterate the chunk list instead of assuming a fixed
/// layout.
///
/// All multi-byte numbers in WAV are little-endian.
class WavReader {
  /// Read and decode a WAV file from disk. Convenience wrapper around [decode].
  static Future<Float64List> readFile(String path) async {
    final bytes = await File(path).readAsBytes();
    return decode(bytes);
  }

  /// Decode WAV bytes into normalized mono samples in the range -1.0..1.0.
  ///
  /// The returned length is the number of audio samples; duration in seconds is
  /// `samples.length / AudioFormat.sampleRate`.
  static Float64List decode(Uint8List bytes) {
    // A valid file needs at least the 12-byte RIFF/WAVE header.
    if (bytes.length < 12) {
      throw WavFormatException(
          'File is too small to be a WAV (${bytes.length} bytes).');
    }

    // ByteData lets us read typed little-endian values at byte offsets.
    final data = ByteData.view(bytes.buffer, bytes.offsetInBytes, bytes.length);

    if (_tag(bytes, 0) != 'RIFF') {
      throw WavFormatException("Missing 'RIFF' marker — not a WAV file.");
    }
    if (_tag(bytes, 8) != 'WAVE') {
      throw WavFormatException("Missing 'WAVE' marker — not a WAV file.");
    }

    // Walk the chunks after the 12-byte header, collecting the two we need.
    int? numChannels;
    int? sampleRate;
    int? bitsPerSample;
    int? audioFormat;
    int? dataOffset;
    int? dataLength;

    var offset = 12;
    while (offset + 8 <= bytes.length) {
      final id = _tag(bytes, offset);
      final size = data.getUint32(offset + 4, Endian.little);
      final payload = offset + 8;

      if (id == 'fmt ') {
        if (payload + 16 > bytes.length) {
          throw WavFormatException("Truncated 'fmt ' chunk.");
        }
        audioFormat = data.getUint16(payload, Endian.little);
        numChannels = data.getUint16(payload + 2, Endian.little);
        sampleRate = data.getUint32(payload + 4, Endian.little);
        // payload+8 byteRate, payload+12 blockAlign — derived, not needed.
        bitsPerSample = data.getUint16(payload + 14, Endian.little);
      } else if (id == 'data') {
        dataOffset = payload;
        // Clamp to the real buffer in case the header over-reports.
        dataLength = size;
        if (payload + size > bytes.length) {
          dataLength = bytes.length - payload;
        }
      }

      // Chunks are padded to an even number of bytes; skip the pad byte too.
      offset = payload + size + (size.isOdd ? 1 : 0);
    }

    if (audioFormat == null) {
      throw WavFormatException("No 'fmt ' chunk found.");
    }
    if (dataOffset == null || dataLength == null) {
      throw WavFormatException("No 'data' chunk found.");
    }

    // Enforce the one format we accept — loudly, with the actual value, so a
    // mismatched fixture is easy to diagnose and fix (re-run the ffmpeg convert).
    if (audioFormat != 1) {
      throw WavFormatException(
          'Unsupported WAV encoding (format code $audioFormat); only '
          'uncompressed PCM (1) is supported.');
    }
    if (numChannels != AudioFormat.channels) {
      throw WavFormatException(
          'Expected mono (${AudioFormat.channels} channel) audio but found '
          '$numChannels channels. Re-encode to mono.');
    }
    if (sampleRate != AudioFormat.sampleRate) {
      throw WavFormatException(
          'Expected ${AudioFormat.sampleRate} Hz but found $sampleRate Hz. '
          'Re-encode to ${AudioFormat.sampleRate} Hz (no resampling is done).');
    }
    if (bitsPerSample != AudioFormat.bitsPerSample) {
      throw WavFormatException(
          'Expected ${AudioFormat.bitsPerSample}-bit samples but found '
          '$bitsPerSample-bit. Re-encode to PCM16.');
    }

    // Each PCM16 sample is 2 bytes; ignore a stray trailing odd byte if present.
    final sampleCount = dataLength ~/ 2;
    final samples = Float64List(sampleCount);
    for (var i = 0; i < sampleCount; i++) {
      // Signed 16-bit little-endian -> normalized double in -1.0..1.0.
      final raw = data.getInt16(dataOffset + i * 2, Endian.little);
      samples[i] = raw / AudioFormat.pcm16FullScale;
    }
    return samples;
  }

  /// Read a 4-byte ASCII chunk/marker tag at [offset].
  static String _tag(Uint8List bytes, int offset) =>
      String.fromCharCodes(bytes.sublist(offset, offset + 4));
}
