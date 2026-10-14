// A first guess at a written phrase's syllables, so a caregiver typing one gets
// feedback about whether it is the right shape for the therapy — without being
// asked to count syllables themselves.
//
// It is an ESTIMATE and the app says so. The authoritative count comes from the
// authored guide recording, where the nuclei are detected in the audio.

import 'package:flutter_test/flutter_test.dart';
import 'package:rhythmic_practice/practice/syllable_estimate.dart';

void main() {
  group('counts vowel groups, not vowels', () {
    test('ordinary phrases', () {
      expect(estimateSyllables('Water'), 2);
      expect(estimateSyllables('Good morning'), 3);
      expect(estimateSyllables('Hello'), 2);
      expect(estimateSyllables('I am hungry'), 4);
    });

    test('a silent trailing e is not its own syllable', () {
      expect(estimateSyllables('More'), 1);
      expect(estimateSyllables('Please'), 1);
    });

    test('…except where the word would vanish without it', () {
      // "the" and "be" have nothing left if the e is dropped.
      expect(estimateSyllables('the'), 1);
      expect(estimateSyllables('be'), 1);
    });

    test('a -le ending keeps its syllable', () {
      expect(estimateSyllables('table'), 2);
    });

    test('punctuation and contractions do not add syllables', () {
      expect(estimateSyllables('Help me!'), 2);
      expect(estimateSyllables("I'm hungry"), 3);
      expect(estimateSyllables('Thank you.'), 2);
    });

    test('it is wrong sometimes, and that is why it is labelled an estimate', () {
      // "tired" is one syllable for most speakers and two vowel groups on paper.
      // The heuristic cannot tell; the authored recording settles it. Pinned so
      // the limitation is documented rather than discovered.
      expect(estimateSyllables("I'm tired"), 3);
    });
  });

  group('nothing assumes English', () {
    test('a script it cannot read is reported as unreliable', () {
      // The vowel heuristic is meaningless for Devanagari, so the UI is expected
      // to label the number rather than present it as detected.
      expect(isReliable('शुभ प्रभात'), isFalse);
      expect(isReliable('Good morning'), isTrue);
    });

    test('but it still returns something rather than nothing', () {
      // A rough number is more use than none, and one per word is the honest
      // floor — every word is at least one syllable.
      expect(estimateSyllables('शुभ प्रभात'), 2);
      expect(estimateSyllables('早上好'), 1);
    });
  });

  group('edge cases do not produce nonsense', () {
    test('empty is zero, not one', () {
      expect(estimateSyllables(''), 0);
      expect(estimateSyllables('   '), 0);
    });

    test('every word counts at least one syllable', () {
      expect(estimateSyllables('rhythm'), greaterThanOrEqualTo(1));
      expect(estimateSyllables('shh'), 1);
    });

    test('a hyphen splits words exactly as a space does', () {
      // Tests the split itself rather than the vowel heuristic's accuracy on any
      // particular word — the two spellings must agree whatever the number is.
      expect(
        estimateSyllables('good-morning'),
        estimateSyllables('good morning'),
      );
      expect(estimateSyllables('good-morning'), 3);
    });
  });

  group('the length band describes the ITEM, not the patient', () {
    test('short, medium, sentence', () {
      expect(lengthBand(1), 1);
      expect(lengthBand(3), 1);
      expect(lengthBand(4), 2);
      expect(lengthBand(6), 2);
      expect(lengthBand(7), 3);
      expect(lengthBand(12), 3);
    });
  });
}
