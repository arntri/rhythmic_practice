import 'dart:typed_data';

import 'audio_config.dart';

/// Encodes normalized mono samples (-1.0..1.0) into a 16 kHz / mono / PCM16 WAV
/// byte buffer — the inverse of [WavReader.decode], and the same format the
/// analyzer reads. Used to write back a trimmed guide clip.
class WavWriter {
  /// Returns a complete WAV file (44-byte header + PCM16 little-endian data).
  static Uint8List encode(
    Float64List samples, {
    int sampleRate = AudioFormat.sampleRate,
  }) {
    const channels = AudioFormat.channels;
    const bitsPerSample = AudioFormat.bitsPerSample;
    final dataLen = samples.length * 2; // 2 bytes per PCM16 sample
    final byteRate = sampleRate * channels * (bitsPerSample ~/ 8);
    final blockAlign = channels * (bitsPerSample ~/ 8);

    final out = ByteData(44 + dataLen);
    var o = 0;
    void str(String s) {
      for (final c in s.codeUnits) {
        out.setUint8(o++, c);
      }
    }

    str('RIFF');
    out.setUint32(o, 36 + dataLen, Endian.little);
    o += 4;
    str('WAVE');
    str('fmt ');
    out.setUint32(o, 16, Endian.little); // fmt chunk size
    o += 4;
    out.setUint16(o, 1, Endian.little); // PCM
    o += 2;
    out.setUint16(o, channels, Endian.little);
    o += 2;
    out.setUint32(o, sampleRate, Endian.little);
    o += 4;
    out.setUint32(o, byteRate, Endian.little);
    o += 4;
    out.setUint16(o, blockAlign, Endian.little);
    o += 2;
    out.setUint16(o, bitsPerSample, Endian.little);
    o += 2;
    str('data');
    out.setUint32(o, dataLen, Endian.little);
    o += 4;

    for (var i = 0; i < samples.length; i++) {
      // Clamp to the int16 range, then write little-endian.
      var v = (samples[i] * AudioFormat.pcm16FullScale).round();
      if (v > 32767) v = 32767;
      if (v < -32768) v = -32768;
      out.setInt16(o, v, Endian.little);
      o += 2;
    }
    return out.buffer.asUint8List();
  }
}
