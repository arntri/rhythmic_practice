import 'dart:math' as math;

import 'package:flutter_test/flutter_test.dart';
import 'package:rhythmic_practice/analysis/audio_config.dart';
import 'package:rhythmic_practice/practice/hum_melody.dart';

// Dominant frequency of a slice, by a coarse autocorrelation peak search over
// the plausible hum range. Enough to tell the high note from the low one.
double _dominantHz(List<double> x, int sampleRate) {
  var bestLag = 0;
  var best = -1.0;
  final minLag = sampleRate ~/ 400; // 400 Hz ceiling
  final maxLag = sampleRate ~/ 100; // 100 Hz floor
  for (var lag = minLag; lag <= maxLag && lag < x.length; lag++) {
    var sum = 0.0;
    for (var i = 0; i + lag < x.length; i++) {
      sum += x[i] * x[i + lag];
    }
    if (sum > best) {
      best = sum;
      bestLag = lag;
    }
  }
  return bestLag == 0 ? 0 : sampleRate / bestLag;
}

// The samples of syllable [i], taken from the middle of its beat so the fades
// at each end don't muddy the pitch reading.
List<double> _syllable(HumMelody m, int i, int beatMs, int sampleRate) {
  final centreMs = i * beatMs + beatMs ~/ 2;
  final centre = (centreMs * sampleRate / 1000).round();
  final half = (0.12 * sampleRate).round();
  return m.samples.sublist(
    math.max(0, centre - half),
    math.min(m.samples.length, centre + half),
  );
}

void main() {
  const sr = AudioFormat.sampleRate;
  const beatMs = 1000; // 60 BPM — one syllable per second

  test('hums the melody twice by default, with a rest between the passes', () {
    final m = buildHumMelody(
      syllableCount: 3,
      stressIndex: 1,
      beatPeriodMs: beatMs,
    );

    expect(m.passes, 2, reason: 'MIT hums the target melody twice');
    // One pass spans one beat per syllable (less the trailing inter-syllable
    // seam), so three syllables at 60 BPM is just under three seconds.
    expect(m.passMs, closeTo(3 * beatMs, 200));
    expect(m.restMs, beatMs);
    expect(m.totalMs, m.passes * m.passMs + m.restMs);

    // The audio is as long as the melody claims.
    final actualMs = (m.samples.length * 1000 / sr).round();
    expect(actualMs, closeTo(m.totalMs, 30));
  });

  test('one syllable per beat — the hum rides the metronome', () {
    for (final bpm in [40, 60, 70]) {
      final beat = (60000 / bpm).round();
      final m = buildHumMelody(
        syllableCount: 4,
        stressIndex: 0,
        beatPeriodMs: beat,
        passes: 1,
      );
      // Four syllables = four beats (minus the one trailing seam).
      expect(m.passMs, closeTo(4 * beat, beat * 0.2),
          reason: 'at $bpm BPM a 4-syllable hum should span 4 beats');
    }
  });

  test('the stressed syllable is sung a minor third above the others', () {
    final m = buildHumMelody(
      syllableCount: 3,
      stressIndex: 1,
      beatPeriodMs: beatMs,
      passes: 1,
    );

    final low = _dominantHz(_syllable(m, 0, beatMs, sr), sr);
    final high = _dominantHz(_syllable(m, 1, beatMs, sr), sr);
    final low2 = _dominantHz(_syllable(m, 2, beatMs, sr), sr);

    expect(high, greaterThan(low));
    expect(high, greaterThan(low2));
    // Exactly two pitch levels: the unstressed syllables share a note.
    expect(low, closeTo(low2, 4));
    // ...and the step between them is a minor third (3 semitones).
    final semitones = 12 * (math.log(high / low) / math.ln2);
    expect(semitones, closeTo(3.0, 0.6));
  });

  test('legato — no silent gap is chopped between syllables', () {
    final m = buildHumMelody(
      syllableCount: 3,
      stressIndex: 0,
      beatPeriodMs: beatMs,
      passes: 1,
    );
    // Sample right on a syllable boundary; MIT phrases are continuously voiced,
    // so the seam must be brief rather than a real silence.
    final seam = _syllable(m, 0, beatMs, sr);
    final voiced = seam.where((v) => v.abs() > 0.01).length;
    expect(voiced / seam.length, greaterThan(0.9));
  });

  test('the rest between passes really is silent', () {
    final m = buildHumMelody(
      syllableCount: 2,
      stressIndex: 0,
      beatPeriodMs: beatMs,
    );
    final restStart = ((m.passMs + 60) * sr / 1000).round();
    final restEnd = ((m.passMs + m.restMs - 60) * sr / 1000).round();
    final rest = m.samples.sublist(restStart, restEnd);
    expect(rest.every((v) => v.abs() < 1e-9), isTrue);
  });

  test('a one-syllable phrase still gets a hum (a single note is a melody)', () {
    final m = buildHumMelody(
      syllableCount: 1,
      stressIndex: 0,
      beatPeriodMs: beatMs,
    );
    expect(m.samples.length, greaterThan(0));
    expect(m.passes, 2);
  });

  test('startOfPassMs locates each pass for the on-screen cue', () {
    final m = buildHumMelody(
      syllableCount: 2,
      stressIndex: 0,
      beatPeriodMs: beatMs,
      passes: 3,
    );
    expect(m.startOfPassMs(0), 0);
    expect(m.startOfPassMs(1), m.passMs + m.restMs);
    expect(m.startOfPassMs(2), 2 * (m.passMs + m.restMs));
  });
}
