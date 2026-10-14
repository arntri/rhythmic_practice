# Phase 2A Build Brief — Analysis Core (Device-Independent)

> Paste into the `rhythmic_practice` project. Read alongside
> `phase1_build_brief.md` (project context, naming rules, schema). Phase 1 status:
> steps 1,2,3,6,7,8 are done; steps 4 (audio guide playback) and 5 (mic capture)
> are NOT built and NOT verified on a device yet.
>
> **Hard constraint for this phase:** build NOTHING that depends on steps 4 or 5.
> Everything in this brief operates on **audio files on disk** (test fixtures),
> never on live microphone input or live playback. The contract is:
> "capture (later) writes a WAV file; this layer reads WAV files."
> If capture later turns out broken, nothing built here should need to change.

---

## 1. What Phase 2A is

The on-device **analysis core**: given an audio file of a practice attempt and a
reference template, produce (a) a junk-gate decision and (b) a content-similarity
score, and manage per-phrase **anchor templates** derived from caregiver-confirmed
attempts. Pure Dart, fully unit-tested against fixture WAV files. No UI changes
except where noted. No new permissions. Still fully offline/local.

### In scope
1. WAV decoding + audio config (16 kHz mono PCM16 assumed).
2. MFCC feature extraction (pure Dart; FFT via a Dart package such as `fftea` —
   verify current packages before adding).
3. DTW similarity between two MFCC sequences → normalized 0..1 score.
4. Junk gate: reject silence / too-short / too-quiet clips before scoring.
5. Anchor template system: new table, promotion + replacement logic.
6. Persistence: `acoustic_feature_vectors` table + repository wiring.
7. Eviction interplay: prove the 48h eviction never touches anchor data.
8. Minor schema tweak: replace the boolean `assistance_setting_active` concept
   with an integer `support_level` column on `exercise_attempts` (default 2;
   levels reserved: 1=unison, 2=modeled, 3=partial cue, 4=prompt-only). No UI yet.

### Explicitly OUT of scope (do not build)
- Anything touching the microphone, `record`/`flutter_sound`, or live audio.
- Anything touching audio playback / TTS / the guide (step 4).
- Wiring scores into the live practice loop or caregiver UI.
- The caregiver in-app recording flow, photo/name cards, custom phrase entry.
- Any ML model, prediction, thresholds-as-decisions, or automation (Phase 3).
- Native/FFI code. Clips are 1–5 s and scoring is offline; pure Dart is fast
  enough. Do not prematurely optimize.

---

## 2. Module layout

Create a self-contained analysis package within `lib/analysis/`:

```
lib/analysis/
  audio_config.dart      // all constants in one place
  wav_reader.dart        // WAV PCM16 mono decode -> Float64List samples
  mfcc.dart              // samples -> List<Float64List> (frames x coeffs)
  dtw.dart               // two MFCC sequences -> normalized similarity 0..1
  junk_gate.dart         // samples -> GateResult (pass/reject + reason)
  attempt_analyzer.dart  // facade: file path + anchor -> AnalysisResult
```

`AnalysisResult` carries: gate decision + reason, content_similarity_score,
duration_ms (from sample count), and the extracted MFCC sequence (so the caller
can persist or promote it without re-computing).

**Important:** this module must have zero imports from UI code and zero
dependence on the mic. It takes file paths / byte buffers in, returns values out.

---

## 3. Signal-processing spec (put ALL constants in `audio_config.dart`)

- Sample rate: 16,000 Hz, mono, PCM16. If a fixture has a different rate, fail
  loudly with a clear message (no silent resampling in v1).
- Pre-emphasis: 0.97.
- Framing: 25 ms window (400 samples), 10 ms hop (160 samples), Hamming window.
- FFT size: 512.
- Mel filterbank: 26 filters, 0–8000 Hz.
- MFCC: 13 coefficients (c0–c12), log-mel then DCT-II.
- DTW: Euclidean distance between MFCC frames; standard dynamic-programming
  alignment; total path cost normalized by path length; map to similarity with
  `score = 1.0 / (1.0 + normalized_cost)` so output is 0..1, higher = more similar.
- Junk gate (tunable constants, conservative defaults):
  - Reject if voiced duration < 300 ms (voiced = frames with RMS above noise floor).
  - Reject if overall RMS below a minimum energy threshold.
  - Reject if duration > 10 s (runaway recording).
  - Gate runs BEFORE MFCC/DTW; rejected clips get no similarity score.

Determinism matters: same file in, exact same numbers out, every run. Write the
MFCC and DTW code with unit tests against small hand-checkable cases (e.g., DTW
of a sequence with itself = cost 0 → score 1.0; DTW symmetric; MFCC output shape
correct for a known-length input).

---

## 4. Anchor template system

New table (Phase 1 schema said this was deferred — it now lands):

```sql
CREATE TABLE phrase_anchor_templates (
  anchor_id          TEXT PRIMARY KEY NOT NULL,
  profile_id         TEXT NOT NULL,
  phrase_id          INTEGER NOT NULL,
  mfcc_frames        BLOB NOT NULL,      -- serialized MFCC sequence, NOT raw audio
  frame_count        INTEGER NOT NULL,
  coeff_count        INTEGER NOT NULL,
  score_vs_reference REAL,               -- this attempt's similarity vs the bundled reference at promotion time
  source_attempt_id  TEXT,
  confirmed_at       TEXT DEFAULT CURRENT_TIMESTAMP,
  UNIQUE(profile_id, phrase_id),
  FOREIGN KEY (profile_id) REFERENCES user_profiles(profile_id) ON DELETE CASCADE,
  FOREIGN KEY (phrase_id)  REFERENCES practice_phrases(phrase_id)
);
```

Serialize `mfcc_frames` as little-endian float64 bytes with frame/coeff counts
stored alongside (keep it boring and documented).

### Reference vs anchor
- **Bundled reference**: the recorded guide clip for a phrase (an asset WAV,
  recorded by the family; fixtures stand in for these in tests). Used as the
  comparison template only until an anchor exists.
- **Anchor**: MFCC sequence from one of the user's own caregiver-confirmed
  attempts. Once an anchor exists, all similarity scoring for that phrase
  compares against the anchor, not the bundled reference.

### Promotion & replacement rules (implement in the repository layer)
1. Attempt scored + caregiver label arrives as Pass (1) + no anchor exists for
   (profile, phrase) → promote: store the attempt's MFCC sequence as the anchor,
   recording its `score_vs_reference` (its similarity vs the bundled reference).
2. Later confirmed-Pass attempt whose similarity **vs the bundled reference** is
   higher than the stored `score_vs_reference` → replace the anchor (the
   "leniency overwrite": a stronger confirmed production raises the bar).
3. Anchors are NEVER touched by the audio eviction job. Eviction deletes raw
   audio only; anchors are derived features and exempt by design.
4. Deleting a phrase or profile cascades its anchors (FK handles this).

Since live labels don't flow yet (no mic), drive promotion/replacement entirely
from repository-level unit tests using fixture-derived MFCCs.

---

## 5. Feature persistence

New table (from the agreed design; trimmed to what exists now):

```sql
CREATE TABLE acoustic_feature_vectors (
  vector_id                TEXT PRIMARY KEY NOT NULL,
  attempt_id               TEXT NOT NULL UNIQUE,
  content_similarity_score REAL,            -- NULL if gate-rejected
  gate_passed              INTEGER CHECK(gate_passed IN (0,1)) NOT NULL,
  gate_reason              TEXT,             -- e.g. 'ok','too_short','too_quiet'
  duration_ms              INTEGER,
  FOREIGN KEY (attempt_id) REFERENCES exercise_attempts(attempt_id) ON DELETE CASCADE
);
```

(`spectral_centroid_mean` / `volume_envelope_variance` from the old draft are
deliberately dropped for now — add only if they earn their place in Phase 3.)

Repository method: given an attempt_id + AnalysisResult, persist the row.
Schema migration: bump DB version, add both new tables + `support_level` column,
with a migration test (open a v1 database, migrate, verify).

---

## 6. Test fixtures (the human will provide these — see note)

Expect fixtures in `test/fixtures/audio/` as 16 kHz mono PCM16 WAV:

```
word_a_take1.wav  word_a_take2.wav  word_a_take3.wav   // same word, 3 takes
word_b_take1.wav  word_b_take2.wav                     // a different word
cough.wav  silence.wav  hum.wav                        // junk
reference_word_a.wav                                   // stands in for bundled guide clip
```

**Note to the developer:** record these on the laptop with any
recorder, then convert each with:
`ffmpeg -i in.wav -ac 1 -ar 16000 -sample_fmt s16 out.wav`
Words can be in any language — the math doesn't care.

### Required test assertions (relative, not absolute — thresholds come later from real data)
- Gate: `silence.wav` rejected (too_quiet); a <300 ms clip rejected (too_short);
  all word takes pass.
- Similarity ordering, the core acceptance test: for every same-word pair and
  every cross-word pair,
  `min(similarity(word_a_i, word_a_j)) > max(similarity(word_a_i, word_b_k))`.
  If this fails, the pipeline is not discriminating — fix before proceeding.
- Junk vs anchor: `cough.wav` and `hum.wav` score below every genuine
  same-word similarity.
- Determinism: scoring the same pair twice yields identical results.
- Anchor lifecycle: promotion on first Pass; replacement only when the new
  confirmed attempt beats `score_vs_reference`; eviction run leaves anchors intact.
- Migration test as in §5.

---

## 7. Build order
1. `audio_config` + `wav_reader` + decode tests.
2. `mfcc` + shape/determinism tests.
3. `dtw` + identity/symmetry tests.
4. `junk_gate` + fixture tests.
5. `attempt_analyzer` facade + the similarity-ordering acceptance test.
6. Schema migration (two tables + support_level) + migration test.
7. Anchor repository logic + lifecycle tests; extend eviction tests.

Work in small runnable increments; run the test suite after each step. The
developer is still learning Dart — keep code readable and commented, and explain
the DSP steps in comments in plain language (what a frame is, what a mel filter
does), since this module is also a learning artifact.

## 8. Definition of done
`flutter test` green across all of the above with the fixtures present, on the
Linux dev machine, with no device attached and no mic/playback packages added.
When steps 4 & 5 are later built and device-verified, Phase 2B will connect the
live capture file path into `attempt_analyzer` — that wiring is the ONLY thing
that should be needed.
