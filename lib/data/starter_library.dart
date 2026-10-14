/// The starter word library (Part 3).
///
/// A small set of ready-to-use phrases that ship WITH a bundled guide clip, so a
/// caregiver can start a first session without recording anything. Each entry is
/// seeded as an ordinary [PracticePhrase] with `is_starter = 1` — the flag is the
/// ONLY structural difference; it must never branch practice logic (rungs,
/// progression, judging all ignore it). The bundled clip is installed into the
/// same encrypted `guide_clip_path` store a recorded guide uses, so playback and
/// scoring treat a starter word exactly like a caregiver-recorded one.
///
/// PLACEHOLDER DATA. The bundled `.wav` files (see `assets/audio/starter/`) are
/// short synthesized tones, and the metadata below (nucleus timings, stressed
/// syllable) is illustrative. Replace both with real recordings + confirmed
/// metadata; nothing here assumes English — the caregiver can hide these and add
/// phrases in any language.
library;

/// One entry in the starter library: the phrase metadata plus the bundled clip
/// that becomes its guide.
class StarterPhrase {
  const StarterPhrase({
    required this.text,
    required this.wordCount,
    required this.syllableCount,
    required this.stressIndex,
    required this.nucleiMs,
    required this.assetPath,
    this.activeByDefault = false,
  });

  final String text;
  final int wordCount;
  final int syllableCount;

  /// 0-based high-note syllable for the melody cue (placeholder).
  final int? stressIndex;

  /// Placeholder syllable-nucleus timings (ms) for beat alignment.
  final List<int> nucleiMs;

  /// Bundled clip, relative to `assets/` (e.g. `audio/starter/water.wav`), loaded
  /// via `rootBundle` / `AssetSource`.
  final String assetPath;

  /// Whether this phrase is on in a fresh session. A few essentials are on; the
  /// rest are off so they don't crowd out the caregiver's own words.
  final bool activeByDefault;

  /// Derived level (mirrors levelForSyllableCount: 1–3→1, 4–6→2, 7+→3).
  int get complexityLevel =>
      syllableCount <= 3 ? 1 : (syllableCount <= 6 ? 2 : 3);
}

/// The ~10 starter phrases. PLACEHOLDERS — see the file header.
///
/// **Only multisyllabic entries are on by default.** MIT intones a phrase on two
/// pitches a minor third apart, one syllable per beat, so a one-syllable target
/// has no contour at all — its hum is a single note. `Yes`, `No` and `Please`
/// are shipped because a caregiver may want them, but they are off, and the
/// choice to use them is a deliberate one.
const List<StarterPhrase> starterLibrary = <StarterPhrase>[
  StarterPhrase(
    text: 'Water',
    wordCount: 1,
    syllableCount: 2,
    stressIndex: 0, // WA-ter
    nucleiMs: [150, 450],
    assetPath: 'audio/starter/water.wav',
    activeByDefault: true,
  ),
  StarterPhrase(
    text: 'Hello',
    wordCount: 1,
    syllableCount: 2,
    stressIndex: 1, // he-LLO
    nucleiMs: [150, 450],
    assetPath: 'audio/starter/hello.wav',
    activeByDefault: true,
  ),
  StarterPhrase(
    text: 'Yes',
    wordCount: 1,
    syllableCount: 1,
    stressIndex: 0,
    nucleiMs: [200],
    assetPath: 'audio/starter/yes.wav',
  ),
  StarterPhrase(
    text: 'No',
    wordCount: 1,
    syllableCount: 1,
    stressIndex: 0,
    nucleiMs: [200],
    assetPath: 'audio/starter/no.wav',
  ),
  StarterPhrase(
    text: 'Please',
    wordCount: 1,
    syllableCount: 1,
    stressIndex: 0,
    nucleiMs: [250],
    assetPath: 'audio/starter/please.wav',
  ),
  StarterPhrase(
    text: 'Thank you',
    wordCount: 2,
    syllableCount: 2,
    stressIndex: 0, // THANK-you
    nucleiMs: [150, 500],
    assetPath: 'audio/starter/thank_you.wav',
    activeByDefault: true,
  ),
  StarterPhrase(
    text: 'Help me',
    wordCount: 2,
    syllableCount: 2,
    stressIndex: 0, // HELP-me
    nucleiMs: [150, 450],
    assetPath: 'audio/starter/help_me.wav',
    activeByDefault: true,
  ),
  StarterPhrase(
    text: "I'm hungry",
    wordCount: 2,
    syllableCount: 3,
    stressIndex: 1, // I'm-HUN-gry
    nucleiMs: [150, 400, 650],
    assetPath: 'audio/starter/im_hungry.wav',
    activeByDefault: true,
  ),
  StarterPhrase(
    text: "I'm tired",
    wordCount: 2,
    syllableCount: 2,
    stressIndex: 1, // I'm-TIRED
    nucleiMs: [150, 450],
    assetPath: 'audio/starter/im_tired.wav',
    activeByDefault: true,
  ),
  StarterPhrase(
    text: 'Goodbye',
    wordCount: 1,
    syllableCount: 2,
    stressIndex: 1, // good-BYE
    nucleiMs: [150, 450],
    assetPath: 'audio/starter/goodbye.wav',
    activeByDefault: true,
  ),
];
