import 'dart:math' as math;
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:rhythmic_practice/practice/beat_align.dart';

void main() {
  group('beatStretchFactor', () {
    test('stretches so the average syllable spacing equals one beat', () {
      // Nuclei 400 ms apart; beat = 1000 ms → factor 2.5 (slow it to the beat).
      expect(beatStretchFactor([100, 500, 900], 1000), closeTo(2.5, 1e-9));
    });

    test('compresses when the syllables are slower than the beat', () {
      // Nuclei 1000 ms apart; beat = 500 ms → factor 0.5.
      expect(beatStretchFactor([0, 1000, 2000], 500), closeTo(0.5, 1e-9));
    });

    test('fewer than 2 nuclei → null (caller falls back to per-rung stretch)', () {
      expect(beatStretchFactor(const [], 1000), isNull);
      expect(beatStretchFactor(const [300], 1000), isNull);
    });

    test('clamps to a sane range (never extreme stretch/compress)', () {
      expect(beatStretchFactor([0, 50], 1000), 6.0); // would be 20×, clamped
      expect(beatStretchFactor([0, 5000], 500), 0.5); // would be 0.1×, clamped
    });

    test('handles unsorted nuclei', () {
      expect(beatStretchFactor([900, 100, 500], 1000), closeTo(2.5, 1e-9));
    });

    test('a faster beat (higher BPM) stretches less than a slower beat', () {
      final fast = beatStretchFactor([0, 600], 857)!; // ~70 BPM
      final slow = beatStretchFactor([0, 600], 1500)!; // 40 BPM
      expect(slow, greaterThan(fast));
    });
  });

  group('guideFadeCutoffMs (R3 syllable cut-off)', () {
    test('cuts at the midpoint of the last two nuclei, in the stretched timeline', () {
      // Nuclei at 100/500/900 ms; last two midpoint = 700 ms; ×2 stretch = 1400.
      expect(guideFadeCutoffMs([100, 500, 900], 2.0), 1400);
    });

    test('leaves the final syllable: cut-off is before the last nucleus', () {
      final nuclei = [0, 400, 800];
      final cut = guideFadeCutoffMs(nuclei, 1.0)!;
      expect(cut, 600); // between 400 and 800
      expect(cut, lessThan(800)); // strictly before the last syllable
      expect(cut, greaterThan(400)); // after the second-to-last is fully heard
    });

    test('fewer than 2 nuclei → null (play the whole clip, no cut)', () {
      expect(guideFadeCutoffMs(const [], 2.0), isNull);
      expect(guideFadeCutoffMs(const [300], 2.0), isNull);
    });

    test('handles unsorted nuclei', () {
      expect(guideFadeCutoffMs([900, 100, 500], 2.0), 1400);
    });

    test('a non-positive stretch → null', () {
      expect(guideFadeCutoffMs([0, 400], 0), isNull);
    });
  });

  group('warpGuideToBeats (full piecewise beat warp)', () {
    const sr = 16000;
    const beat = 1000; // 60 BPM → 1000 ms / beat

    // A voiced-like test tone, [ms] long, so WSOLA has real waveform to work on.
    Float64List tone(int ms) {
      final n = (ms * sr / 1000).round();
      final out = Float64List(n);
      for (var i = 0; i < n; i++) {
        out[i] = 0.5 * math.sin(2 * math.pi * 120 * i / sr); // ~120 Hz
      }
      return out;
    }

    test('places each nucleus one beat apart, first nucleus on a whole beat', () {
      // Nuclei 300 ms apart in the original; the warp should spread them to one
      // beat (1000 ms) apart in the output.
      final w = warpGuideToBeats(tone(900), [100, 400, 700], sr, beat)!;
      expect(w.nucleiOutMs.length, 3);
      // First nucleus lands exactly on a beat (lead padded with silence).
      expect(w.nucleiOutMs.first % beat, 0);
      // Consecutive nuclei are ~one beat apart (small slack for WSOLA length
      // granularity + the seam crossfade).
      for (var k = 1; k < w.nucleiOutMs.length; k++) {
        expect((w.nucleiOutMs[k] - w.nucleiOutMs[k - 1]).toDouble(),
            closeTo(beat.toDouble(), 60));
      }
    });

    test('compresses when the syllables are slower than the beat', () {
      // 1500 ms apart, beat 1000 → should be pulled CLOSER together.
      final w = warpGuideToBeats(tone(3500), [500, 2000, 3500], sr, beat)!;
      final spacing = w.nucleiOutMs[1] - w.nucleiOutMs[0];
      expect(spacing.toDouble(), closeTo(beat.toDouble(), 80));
    });

    test('warped output is longer than the lead-pad alone (body present)', () {
      final w = warpGuideToBeats(tone(900), [100, 400, 700], sr, beat)!;
      final outMs = w.samples.length * 1000 / sr;
      // 3 nuclei → ~2 beats of body after the first; comfortably > 2000 ms.
      expect(outMs, greaterThan(2000));
    });

    test('fewer than 2 usable nuclei → null (caller falls back to uniform)', () {
      expect(warpGuideToBeats(tone(500), const [], sr, beat), isNull);
      expect(warpGuideToBeats(tone(500), const [200], sr, beat), isNull);
    });

    test('handles unsorted, duplicate and out-of-range nuclei', () {
      // Duplicates collapse, out-of-range (> duration) is dropped, order fixed.
      final w = warpGuideToBeats(tone(900), [400, 100, 400, 5000], sr, beat);
      expect(w, isNotNull);
      expect(w!.nucleiOutMs.length, 2); // 100 and 400 only
    });

    test('non-positive beat period or empty input → null', () {
      expect(warpGuideToBeats(tone(900), [100, 400], sr, 0), isNull);
      expect(warpGuideToBeats(Float64List(0), [100, 400], sr, beat), isNull);
    });
  });
}
