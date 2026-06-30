import 'dart:typed_data';

/// Converts an MFCC sequence to/from the raw bytes we store in the
/// `phrase_anchor_templates.mfcc_frames` BLOB (Phase 2A brief §4).
///
/// We keep the format deliberately boring and explicit: every coefficient is a
/// **little-endian float64 (8 bytes)**, written frame by frame, row-major. The
/// frame and coefficient counts are NOT in the blob — they're stored in their
/// own columns next to it, and passed back in on [decode]. Being explicit about
/// endianness means a database file is portable across devices regardless of the
/// CPU's native byte order.
class MfccCodec {
  /// Flatten `frames × coeffs` into little-endian float64 bytes. Returns empty
  /// bytes for an empty sequence.
  static Uint8List encode(List<Float64List> frames) {
    if (frames.isEmpty) return Uint8List(0);
    final coeffCount = frames.first.length;
    final data = ByteData(frames.length * coeffCount * 8);
    var offset = 0;
    for (final frame in frames) {
      for (var c = 0; c < coeffCount; c++) {
        data.setFloat64(offset, frame[c], Endian.little);
        offset += 8;
      }
    }
    return data.buffer.asUint8List();
  }

  /// Rebuild the `frameCount × coeffCount` sequence from stored bytes. Uses
  /// [ByteData.sublistView] + explicit little-endian reads, so it works even if
  /// the blob isn't 8-byte aligned and regardless of host endianness.
  static List<Float64List> decode(
    Uint8List blob,
    int frameCount,
    int coeffCount,
  ) {
    final data = ByteData.sublistView(blob);
    return List<Float64List>.generate(frameCount, (fr) {
      final row = Float64List(coeffCount);
      for (var c = 0; c < coeffCount; c++) {
        row[c] = data.getFloat64((fr * coeffCount + c) * 8, Endian.little);
      }
      return row;
    });
  }
}
