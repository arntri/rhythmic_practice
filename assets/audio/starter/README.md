# Starter word library — PLACEHOLDER audio

These `.wav` files are **placeholders** (short synthesized tones), bundled so the
starter-library seeding + install pipeline is real end-to-end. They are **not**
real spoken/intoned guides.

**Replace each file with a real recording** (same filename), and update the
matching metadata (syllable count, nucleus timings, stressed syllable) in
`lib/data/starter_library.dart`. Format required: **WAV, PCM16, mono, 16 kHz**
(matches `AudioFormat` and the recorded-guide pipeline).

Files map 1:1 to the entries in `lib/data/starter_library.dart` by `assetPath`.
