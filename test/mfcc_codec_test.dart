// MFCC serialization round-trip tests (Phase 2A step 7).

import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:rhythmic_practice/analysis/mfcc_codec.dart';

List<Float64List> seq(List<List<double>> f) =>
    f.map((r) => Float64List.fromList(r)).toList();

void main() {
  test('encode/decode is a faithful round-trip', () {
    final original = seq([
      [1.5, -2.5, 3.0, 0.0],
      [4.25, 5.0, -6.75, 7.125],
      [-0.001, 1e6, -1e-6, 42.0],
    ]);
    final blob = MfccCodec.encode(original);
    final back = MfccCodec.decode(blob, 3, 4);

    expect(back.length, 3);
    for (var f = 0; f < 3; f++) {
      for (var c = 0; c < 4; c++) {
        expect(back[f][c], original[f][c]);
      }
    }
  });

  test('blob length is frames * coeffs * 8 bytes', () {
    final blob = MfccCodec.encode(seq([
      [0, 0, 0],
      [0, 0, 0],
    ]));
    expect(blob.length, 2 * 3 * 8);
  });

  test('empty sequence encodes to empty bytes and decodes to nothing', () {
    final blob = MfccCodec.encode(const []);
    expect(blob, isEmpty);
    expect(MfccCodec.decode(blob, 0, 13), isEmpty);
  });

  test('decode is alignment-safe on an offset buffer', () {
    // Place the float bytes after a 1-byte prefix, then view from offset 1, so
    // the decoded buffer is NOT 8-byte aligned — must still read correctly.
    final original = seq([
      [1.0, 2.0]
    ]);
    final core = MfccCodec.encode(original);
    final padded = Uint8List(core.length + 1)..setRange(1, core.length + 1, core);
    final offsetView = Uint8List.sublistView(padded, 1);
    final back = MfccCodec.decode(offsetView, 1, 2);
    expect(back.single[0], 1.0);
    expect(back.single[1], 2.0);
  });
}
