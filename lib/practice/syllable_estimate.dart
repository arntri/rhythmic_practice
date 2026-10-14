/// A first guess at how many syllables a written phrase has.
///
/// **This is an estimate, and the app treats it as one.** The authoritative
/// count comes from the authored guide recording, where the syllable nuclei are
/// detected in the audio and confirmed — see `syllable_detection.dart`. This
/// exists only so a caregiver typing a new phrase gets immediate feedback about
/// whether it is the right shape for the therapy, without being asked to count
/// syllables themselves.
///
/// It is a heuristic and it is wrong sometimes — "tired" counts as two — which
/// is exactly why the number is labelled as an estimate on screen and is
/// overwritten the moment a real recording exists.
///
/// **Nothing here assumes English, and it does not pretend otherwise.** The
/// vowel-group heuristic works for Latin-script languages and is meaningless for
/// Devanagari, Arabic, Han and much else, so text with no Latin vowels falls back
/// to the word count and [isReliable] reports false. The UI is expected to say so
/// rather than present a confident wrong number.
library;

const _vowels = 'aeiouyàáâãäåèéêëìíîïòóôõöùúûüýÿæœø';

/// Whether a Latin-vowel count is meaningful for [text].
///
/// False for scripts the heuristic cannot read — the estimate is still returned,
/// because a rough number is more use than none, but it should be labelled.
bool isReliable(String text) {
  final lower = text.toLowerCase();
  return lower.split('').any(_vowels.contains);
}

/// Estimated syllables in [text]. Never negative, and never zero for a phrase
/// that has any words in it — every word is at least one syllable.
int estimateSyllables(String text) {
  final words = text
      .trim()
      .split(RegExp(r'[\s -⁯　]+'))
      .where((w) => w.isNotEmpty)
      .toList();
  if (words.isEmpty) return 0;
  if (!isReliable(text)) return words.length;

  var total = 0;
  for (final raw in words) {
    // Strip punctuation, keeping letters and the apostrophes inside contractions.
    final word = raw.toLowerCase().replaceAll(RegExp(r"[^a-zà-öø-ÿ']"), '');
    if (word.isEmpty) continue;
    total += _syllablesInWord(word);
  }
  return total == 0 ? words.length : total;
}

int _syllablesInWord(String word) {
  // Count vowel GROUPS, not vowels: "morning" is mor-ning, two groups, not
  // three letters.
  var groups = 0;
  var inVowel = false;
  for (final ch in word.split('')) {
    final isVowel = _vowels.contains(ch);
    if (isVowel && !inVowel) groups++;
    inVowel = isVowel;
  }

  // A trailing "e" is usually silent ("more", "please") — but not when it is the
  // only vowel group in the word ("the", "be"), and not after "le" ("table").
  if (groups > 1 &&
      word.endsWith('e') &&
      !word.endsWith('le') &&
      !word.endsWith('ee') &&
      !word.endsWith('ye')) {
    groups--;
  }

  return groups < 1 ? 1 : groups;
}

/// The length band a phrase falls in: 1 = short (1–3 syllables), 2 = medium
/// (4–6), 3 = a sentence (7+).
///
/// A descriptor of the item, **not** a therapy level — the patient's MIT level
/// lives on their profile and has nothing to do with how long a phrase is.
int lengthBand(int syllables) =>
    syllables <= 3 ? 1 : (syllables <= 6 ? 2 : 3);
