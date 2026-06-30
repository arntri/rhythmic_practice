// Phase 2A step 5: the analyzer facade.
//
// Two kinds of test here:
//  1. Facade WIRING tests, with synthesized clips — always run, prove the
//     gate→MFCC→DTW plumbing and the AnalysisResult contract.
//  2. The similarity-ordering ACCEPTANCE test (brief §6), driven by the human's
//     recorded fixtures in test/fixtures/audio/. It auto-skips until those WAVs
//     are present, then enforces that the pipeline actually discriminates words.

import 'dart:io';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:rhythmic_practice/analysis/attempt_analyzer.dart';
import 'package:rhythmic_practice/analysis/audio_config.dart';
import 'package:rhythmic_practice/analysis/dtw.dart';
import 'package:rhythmic_practice/analysis/mfcc.dart';
import 'package:rhythmic_practice/analysis/wav_reader.dart';

import 'wav_builder.dart';

void main() {
  final analyzer = AttemptAnalyzer();
  final mfcc = Mfcc();

  group('facade wiring (synthesized clips)', () {
    test('a gate-rejected clip has no MFCC and no score', () {
      final silence = Float64List(AudioFormat.sampleRate); // 1 s of zeros
      final r = analyzer.analyzeSamples(silence, anchorMfcc: const []);
      expect(r.gatePassed, isFalse);
      expect(r.gateReason, 'too_quiet');
      expect(r.contentSimilarityScore, isNull);
      expect(r.mfcc, isEmpty);
      expect(r.durationMs, closeTo(1000, 2));
    });

    test('a passing clip with no template: score null, MFCC present', () {
      final samples =
          Float64List.fromList(toneDoubles(440, 1000)); // 1 s, loud
      final r = analyzer.analyzeSamples(samples);
      expect(r.gatePassed, isTrue);
      expect(r.gateReason, 'ok');
      expect(r.contentSimilarityScore, isNull);
      expect(r.mfcc, isNotEmpty);
      expect(r.mfcc.first.length, MfccConfig.coeffCount);
    });

    test('a clip scored against its own MFCC gets similarity 1.0', () {
      final samples = Float64List.fromList(toneDoubles(440, 1000));
      final ownMfcc = mfcc.extract(samples);
      final r = analyzer.analyzeSamples(samples, anchorMfcc: ownMfcc);
      expect(r.gatePassed, isTrue);
      expect(r.contentSimilarityScore, 1.0);
    });

    test('different-sounding clips score below an identical match', () {
      final low = Float64List.fromList(toneDoubles(300, 1000));
      final high = Float64List.fromList(toneDoubles(3000, 1000));
      final lowMfcc = mfcc.extract(low);
      final crossScore =
          analyzer.analyzeSamples(high, anchorMfcc: lowMfcc).contentSimilarityScore!;
      final selfScore =
          analyzer.analyzeSamples(low, anchorMfcc: lowMfcc).contentSimilarityScore!;
      expect(crossScore, lessThan(selfScore));
      expect(selfScore, 1.0);
    });

    test('analyzeFile decodes from disk and matches analyzeSamples', () async {
      final dir = Directory.systemTemp.createTempSync('analyzer_test');
      addTearDown(() => dir.deleteSync(recursive: true));
      final samples = toneDoubles(440, 1000);
      final f = writeTempWav(dir, 'clip.wav', buildWavFromDoubles(samples));

      final fromFile = await analyzer.analyzeFile(f.path);
      final fromSamples =
          analyzer.analyzeSamples(Float64List.fromList(samples));
      expect(fromFile.gatePassed, fromSamples.gatePassed);
      expect(fromFile.mfcc.length, fromSamples.mfcc.length);
      expect(fromFile.durationMs, fromSamples.durationMs);
    });

    test('is deterministic', () {
      final samples = Float64List.fromList(toneDoubles(440, 800));
      final anchor = mfcc.extract(Float64List.fromList(toneDoubles(440, 800)));
      final a = analyzer.analyzeSamples(samples, anchorMfcc: anchor);
      final b = analyzer.analyzeSamples(samples, anchorMfcc: anchor);
      expect(a.contentSimilarityScore, b.contentSimilarityScore);
    });
  });

  // --- Acceptance test (brief §6): runs only when real fixtures are present ---

  const fixturesDir = 'test/fixtures/audio';
  final hasFixtures = Directory(fixturesDir).existsSync() &&
      File('$fixturesDir/word_a_take1.wav').existsSync();
  final skipReason = hasFixtures
      ? null
      : 'No fixtures in $fixturesDir/ yet — record & convert WAVs (see brief §6).';

  group('similarity ordering (real fixtures)', () {
    // Extract MFCCs from a fixture file.
    Future<List<Float64List>> featuresOf(String name) =>
        WavReader.readFile('$fixturesDir/$name').then(mfcc.extract);

    // Score two recordings the same way the analyzer does internally: DTW
    // similarity over their MFCC sequences.
    double score(List<Float64List> x, List<Float64List> y) =>
        Dtw.similarity(x, y);

    test(
      'min(same-word) > max(cross-word), and junk scores below all same-word',
      () async {
        final wordA = [
          await featuresOf('word_a_take1.wav'),
          await featuresOf('word_a_take2.wav'),
          await featuresOf('word_a_take3.wav'),
        ];
        final wordB = [
          await featuresOf('word_b_take1.wav'),
          await featuresOf('word_b_take2.wav'),
        ];

        // All same-word (word_a) pairings.
        final sameWord = <double>[];
        for (var i = 0; i < wordA.length; i++) {
          for (var j = i + 1; j < wordA.length; j++) {
            sameWord.add(score(wordA[i], wordA[j]));
          }
        }
        // All cross-word (word_a vs word_b) pairings.
        final crossWord = <double>[];
        for (final a in wordA) {
          for (final b in wordB) {
            crossWord.add(score(a, b));
          }
        }

        final minSame = sameWord.reduce((a, b) => a < b ? a : b);
        final maxCross = crossWord.reduce((a, b) => a > b ? a : b);
        expect(minSame, greaterThan(maxCross),
            reason: 'pipeline must discriminate same-word from cross-word');

        // Junk (cough, hum) must score below every genuine same-word similarity.
        final cough = await featuresOf('cough.wav');
        final hum = await featuresOf('hum.wav');
        for (final a in wordA) {
          expect(score(a, cough), lessThan(minSame));
          expect(score(a, hum), lessThan(minSame));
        }

        // silence.wav must be gate-rejected as too_quiet.
        final silence = await WavReader.readFile('$fixturesDir/silence.wav');
        final gated = AttemptAnalyzer().analyzeSamples(silence);
        expect(gated.gatePassed, isFalse);
        expect(gated.gateReason, 'too_quiet');

        // Determinism: same pair twice, identical score.
        expect(score(wordA[0], wordA[1]), score(wordA[0], wordA[1]));
      },
      skip: skipReason,
    );
  });
}
