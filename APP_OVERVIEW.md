# Rhythmic Practice — App Functionality Overview

*This document describes exactly what the app does, derived from the current source code and the passing test suite (not from design intent). All thresholds, constants, and behaviors below are as written in `lib/`. Current state: **216 tests passing**, `flutter analyze` clean.*

---

## 1. What the app is

A **landscape-locked, caregiver-assisted speech-practice app** (Flutter) for people recovering speech — built on **Melodic Intonation Therapy (MIT)**: practising words slowly, on a steady beat, with graded support that fades as the person improves.

The person practises one word at a time; a caregiver sits alongside and, on the levels that call for it, marks how each attempt went. The app uses those caregiver judgements (not any ML model) to move each word up or down a support ladder over time.

### Core principles (enforced in code)
- **MIT support ladder** — every word sits on one of 7 rungs (R0–R6) from "just feel the beat" to "say it solo"; difficulty changes one dial at a time.
- **Audio-led, reading-optional** — the spoken model is the primary cue; a picture is the default on-screen support; the written word is optional (reading is often impaired in aphasia).
- **Caregiver-driven, rules-based progression** — the acoustic/ML scoring **never gates progression**; only the caregiver's Pass/Fail/Unsure does. The scoring is measured and displayed only.
- **Local-first & private** — everything works fully offline; raw audio is AES-encrypted on the device and auto-deleted after 48h; only anonymous metrics ever sync, and only with explicit consent.
- **Errorless, gentle** — slowing the tempo and adding support come before failure; "slowing down is support, not failure."

### Tech stack (`pubspec.yaml`)
Flutter; `sqflite` (local SQLite, schema **v14**); `audioplayers` (playback); `record` (mic); `flutter_tts` (fallback voice); `fftea` (FFT); `vibration` (haptics); `encrypt` + `flutter_secure_storage` (AES-256 at rest); `image_picker` (name-card photos); `supabase_flutter` (optional cloud); `uuid`. One bundled asset: `assets/audio/tick.wav` (metronome).

---

## 2. The MIT support ladder (`lib/practice/progression.dart`)

Each word has a **rung** (R0–R6). The rung decides what the screen asks, whether the model plays, whether the caregiver judges, and whether the mic records.

| Rung | Title (on screen) | What happens | Model plays? | Caregiver judges? | Mic records? |
|---|---|---|---|---|---|
| **R0** | Receive the beat | Feel the beat; optional tap, no speech | no | no — **auto-advances on exposure** (tap score logged for analytics only, never gates) | no |
| **R1** | Hum to the beat | Hum/voice to the beat (sound, no words) | no | no (auto-proceeds) | no |
| **R2** | Say it together | Intone the word **in unison** with the model | yes | no (auto-proceeds) | no |
| **R3** | Together, model fades | Start together; the model **fades** so she carries it | yes (fades) | **yes** — light check ("did she carry the faded part?") | no |
| **R4** | Repeat after the model | Listen, then repeat | yes | yes | **yes** |
| **R5** | Delayed repeat | Listen, pause, then repeat | yes | yes | **yes** |
| **R6** | Say it on your own | Solo production, prompt only | no | yes | **yes** |

Two membership rules in code:
- **Co-production (R0–R2):** produced *with* the beat/model → not Pass/Failed; they **auto-advance**.
- **Judged (R3–R6):** `isJudged`. The caregiver verdict drives progression here.
- **Recorded/scored (R4–R6):** `cleanCapture` — only solo productions are recorded and acoustically scored. (R3 is judged but *not* recorded — the model is still playing, so a mic sample would be contaminated.)

The four difficulty dials (only one changes per move): **support** (rung), **task demand**, **linguistic load** (syllable tier), and **tempo**.

---

## 3. A practice session, step by step

Driven by a deterministic state machine (`lib/practice/practice_controller.dart`) clocked by the metronome; rendered by `lib/screens/practice_view.dart`; assembled by `lib/screens/practice_screen.dart`.

**Session assembly** (`practice_screen._setUp`):
1. Load the profile + the **active** phrases (up to `session_phrase_limit`, default 10; default seed has **5 active** level-1 words).
2. Load each word's progression record (rung from the phrase row; tier + tempo from `progression_state`).
3. Decrypt any name-card photos for display.
4. Build the session as **each word repeated 3× consecutively** (the fixed 3-rep block, `MitProgression.repsPerBlock = 3`).
5. **Ambient calibration:** record ~2 s of room noise to set the per-session speech threshold, then a 350 ms settle so the audio session is back in playback mode.
6. Start the metronome + controller.

**States** (`PracticeState`): `preparation → referencePrompt → (inputCapture) → systemTransition → … → sessionComplete`.

- **Preparation ("Find the beat") — once per session.** "Tap the beat (n/3)": **3 in-time taps** (within ±0.25 of the beat) lock in. After that, words flow one into the next with no re-tap ("lock once, then flow").
- **Reference prompt** — shaped by the rung:
  - R0: "Feel the beat" for **8 s** (the tick stays audible + a stronger haptic).
  - R1: "Hum along" for **8 s** (tick audible + stronger haptic).
  - R2/R3: a 5-second "Get ready" countdown, then the model plays (R3 fades out); cue "Say it together" / "Carry it as it fades".
  - R4/R5: cue "Listen…", the model plays.
  - R6: "Get ready…" prompt (~2.5 s), then the mic opens.
- **Input capture (R4–R6 only)** — the mic opens, the background turns a **distinct green** and a "Recording — say it once" pill shows. It auto-closes after a window of silence (caregiver-set 3–8 s, default 4.5 s).
- **Verdict (R3–R6)** — a full-height **caregiver bar pinned to the right edge** (so the left stays free for the user): **Accept** (green, =Pass), **Unsure** (blue), **Not yet** (yellow, =Fail). R0–R2 skip this and auto-complete.

**On-screen indicators:** top-left pill = **"Word X of Y"** (counts words, not reps); bottom-left chip = the **current stage** ("R2 · Say it together" + a 7-dot ladder, current rung filled).

---

## 4. The progression engine (`lib/practice/mit_progression.dart`)

Rules-based, label-driven, on two timescales. **The ML model never gates this.**

### Fast loop — the 3-rep block (`evaluateBlock`)
A word is always practised **exactly 3 reps** at its current rung; the decision is made **only after the block** (never mid-block):
- **Co-production (R0–R2):** auto-proceed one rung.
- **Judged (R3–R6):**
  - **≥ 2 Passes →** advance one rung (reset tempo, clear "backed-up").
  - **≥ 2 Fails →** first **lower the tempo** one step (60→50→40 BPM); at the floor, **back up one rung** (restore support); a failed block at the already-backed-up rung **parks** the word for the session.
  - **Otherwise (e.g. mostly Unsure) →** hold. **Passes never demote**; a failed R3 never forces R4.
- **Caregiver cap:** advancement is clamped to a caregiver-set ceiling (low-energy sessions).

A rung change takes effect **the next time the word appears** (announced by a SnackBar that names the word, e.g. *"'Help': moved up to R4 · Repeat after the model"*).

### Slow loop — syllable tier (`shouldRaiseTier` / `raiseTier`)
Across sessions: when a word's pass rate is **≥ 90% over the last 10 sessions** (`tierPassRate = 0.9`, `tierWindow = 10`), raise its syllable tier **and reset its rung to unison (R2)** — never raise linguistic load and drop support in the same move.

### R0/R1 advance on exposure (never trapped on tap performance)
R0 and R1 are co-production: they **auto-advance after their full exposure window** (the ~8 s feel-the-beat / hum period across the 3-rep block), regardless of tap accuracy or no taps at all. The R0 tap-sync score is **logged for analytics only and never gates progress** (a user with hand weakness must never be trapped on R0). The caregiver can hold a word on R0/R1 longer or advance early via the manual rung control / the auto-progression toggle.

### Per-word tempo is live, and tempo drops are announced as help
The per-word tempo **is applied to the live metronome**, re-anchored only at the **word boundary** (the start of a word's block, never mid-prompt — the controller counts beats since state entry, so a tempo change can't trip a timeout). A word's tempo is capped at the caregiver's base tempo and lowered toward the 40 BPM floor on failure; advancing restores it. When the beat slows as support (e.g. 60→50), a **calm, non-punitive cue** is shown — *"Slowing the beat for 'Help' to make it easier"* — never framed as failure.

> **Constants:** `repsPerBlock = 3`, `defaultBpm = 60`, tempo range `40–70`, `tempoStep = 10`, `tierPassRate = 0.9`, `tierWindow = 10`.
> **Single source of truth:** the rung lives in one place (`_progState`, mirrored to the phrase row for the settings view); the on-screen stage, the behavior, and the announcement all read the same value.

---

## 5. Audio

### Tri-sensory metronome (`lib/metronome/`)
- Drift-free scheduling: each beat is a fixed point on an absolute timeline (`beat_scheduler.dart`), so error never accumulates.
- Three independent channels — **sound** (`tick.wav`), **visual** (a pulsing ring that peaks on the beat), **haptic** (a short pulse; **70 ms** on beat-focused phases, **40 ms** otherwise, full amplitude where supported).
- Tempo bounded **40–70 BPM** in practice (one beat ≈ one syllable; slow is support).

### Guide playback (`lib/services/guide_player.dart`)
- **Recorded guide (preferred):** decrypt → decode → **pitch-preserving time-stretch (WSOLA, `lib/practice/time_stretch.dart`)** → play (the recording stays untouched; only the playback copy is stretched). **Voice-to-beat alignment (`beat_align.dart`):** when the guide's syllable timings are known, the stretch is chosen so the **average syllable spacing equals one beat** at the word's tempo — so the voice and the metronome don't drift apart (interim of a full per-syllable warp). Otherwise it falls back to per-rung elongation (unison 2.8×, repeat 2.2×, solo 1.8×). R3 **fades** the volume (1.0 → ~0.15) so the user carries the word.
- **TTS fallback** (no recorded clip): `flutter_tts` at a rate of `0.30 / ttsStretch` (slower than the recorded path; clamped 0.1–0.35).
- **Caregiver "Playback speed" (1× / 0.75× / 0.5×):** an overall multiplier that divides into the stretch — 0.5× makes the word come out at half speed.
- Completion fires once, via the player event **or** a duration-sized safety timer.

### Recording capture (`lib/services/mic_capture.dart`, `lib/practice/capture_analysis.dart`)
- Records 16 kHz mono PCM16 WAV; closes after silence (caregiver-set window) using a speech threshold derived from the per-session ambient calibration (median ambient + 12 dB, clamped −55…−25 dBFS; default −40 dBFS).
- Measures **latency** (gap to first speech) and **duration**; encrypts the clip at rest.

### Guide recording flow (`lib/services/guide_recorder.dart`, `guide_recording_screen.dart`)
Caregiver records each word **once, slowly, no metronome**: record → **noise reduction** (spectral subtraction) → **silence trim** → **syllable-nucleus detection** (RMS envelope + voicing gate + min-separation) → caregiver **reviews/adjusts** the detected syllable count (merge/split) → **encrypt + save**. The recorded clip doubles as the acoustic reference.

---

## 6. Speech analysis & scoring (`lib/analysis/`, `lib/services/attempt_scoring.dart`)

Pure-Dart, device-independent pipeline that **measures** a solo attempt (R4–R6) against the recorded guide:
- **Junk gate:** rejects clips that are too long (>10 s), too quiet (RMS < 0.01), or too short (<300 ms voiced).
- **MFCC:** 16 kHz mono → pre-emphasis → 25 ms/10 ms Hamming frames → 512-FFT → 26 mel filters → log → DCT-II → **13 coefficients**.
- **DTW:** Euclidean dynamic time warping; similarity = `1 / (1 + normalizedCost)` (1.0 identical).
- **Anchor templates:** on a caregiver **Pass**, the attempt's MFCC may be **promoted/replaced** as the phrase's reference (a stronger confirmed production raises the bar). Stored as derived features (MFCC blob) — **never raw audio**.

> This score is **display/measurement only** — it is stored in `acoustic_feature_vectors`, shown as a trend, and **never feeds progression**.

---

## 7. Target display & name cards

- Per-profile **target display: Picture / Word / Both** (default **Picture**). Audio always plays regardless.
- Any word can have a **photo** ("name card"): caregiver picks from the gallery → encrypted at rest (`photos/…enc`, same AES as audio) → shown above/instead of the word per the setting. Photos stay **local, never synced**.

---

## 8. Progress analytics & history (display-only)

- **Trends (`lib/analytics/trend.dart`, `progress_analytics.dart`):** per-word and overall trends for **pass rate**, **sound match (similarity)**, and **response time (latency)** — smoothed moving average + relative early-vs-late comparison (10% threshold) → **improving / plateau / declining / not-enough-data**. Latency is "lower is better." Counts only judged rungs (R4–R6). Simple statistics, **not ML**, and **never** feeds progression.
- **History screen:** "Trends over time" chips, a **by-day** rollup, **by-phrase** stats (pass %, P/F/U, avg tap-sync), and recent sessions.
- **Daily summary** (`daily_summary` table): a per-day rollup (attempts, P/F/U, avg similarity) for the dashboard and cloud sync.

---

## 9. Privacy & data

- **Audio at rest:** AES-256-CBC with a fresh random IV; the key lives in the OS keystore (`flutter_secure_storage`), never on disk/DB. Plaintext is deleted immediately after encryption.
- **48-hour audio eviction (`audio_eviction.dart`):** raw clips older than 48 h are deleted and the path nulled; **all numeric metrics are kept**. Runs on every launch.
- **Cloud is optional & consent-gated (`sync_service.dart`):** pushes **metrics only** (sessions, attempts, daily summaries) — **never audio, photos, guide clips, or keys** — and only when (a) the cloud is reachable, (b) the caregiver is signed in, and (c) `guardian_consent_granted` is on. One-way, idempotent, resilient per-row.

---

## 10. Cloud & family sharing (`cloud.dart`, `auth_service.dart`, `cloud_sharing.dart`)

- Email/password accounts via Supabase; being signed out is normal (cloud just unlocks sync + remote viewing). If unconfigured, the app is fully local.
- **Family sharing:** owners get a **share code**; family members **join with a code** to view (read-only, row-level-security filtered) the latest **metrics** (phrase, verdict, sync score, time) — no audio.

---

## 11. Screens (landscape-locked)

`HomeScreen` (calm lavender canvas, big "Tap to start," ⓘ help, top-right menu) → `PracticeScreen`/`PracticeView` (the session) · `HelpScreen` (first-run onboarding + reopenable) · `SettingsPortal` (caregiver, behind a **slide-to-unlock**) · `GuideRecordingScreen` · `HistoryScreen` · `ProgressScreen` (family) · `MetronomeScreen` (standalone) · `AccountScreen`.

**Caregiver settings expose:** tempo (40–70 BPM), sensory channels (visual/sound/haptic), session length (1–20), recording length (3–8 s), target display (picture/word/both), **playback speed (1×/0.75×/0.5×)**, auto-progression on/off, add custom phrase (any language), and per-phrase: active toggle, **manual rung ◀/▶**, photo add/change/remove, record-guide; plus the **privacy/consent** toggle.

---

## 12. Data model (SQLite, schema v14)

- **user_profiles** — one local profile; all preferences (tempo, channels, session/recording length, consent + timestamp, target_display, playback_speed, auto_progress_enabled, onboarding_seen, cloud_profile_id).
- **practice_phrases** — text, word/syllable counts, complexity, current_rung, guide_clip_path (encrypted reference) + guide_nuclei_ms, photo_path, is_active.
- **practice_sessions / exercise_attempts** — each attempt's verdict, latency/duration, tap-sync score, rung_at_attempt, encrypted audio path (nulled after 48 h), synced_at.
- **acoustic_feature_vectors** — per-attempt gate verdict + similarity (display only).
- **phrase_anchor_templates** — per-(profile,phrase) MFCC reference (derived features, never audio).
- **progression_state** — per-(profile,phrase) rung, syllable_tier, tempo_bpm.
- **daily_summary** — per-(profile,day) metrics rollup.

*(Legacy/unused: `practice_phrases.audio_asset_path`, `exercise_attempts.support_level`.)*

---

## 13. Testing

**216 tests passing** (`flutter test`), covering: WAV codec, MFCC, DTW, junk gate, MFCC codec, attempt analyzer/scoring, time-stretch, syllable detection, noise reduction, audio trim, AES crypto, audio eviction; the metronome/beat scheduler, tap-sync; the practice controller FSM, progression (rung map, MIT 3-rep block, auto-progression, progression service); repository + anchors + schema migrations (v1→v14); sync service; analytics/trends + capture analysis + history; and widget tests (practice view, settings, metronome screen, slide-to-unlock).

The pure logic (audio DSP, progression rules, analytics, data layer) is unit-tested. **Device-gated** parts — live mic recording, audio playback/TTS, gallery photo pick, keystore — are verified on a physical device rather than in tests.

---

## 14. Status & honest caveats
- **Verified on device:** the guide audio plays; the core practice loop runs.
- **Built, awaiting device verification:** gallery photo pick + display, ambient calibration feel, the full MIT 3-rep-block progression end-to-end, the daily-summary cloud push (needs the Supabase `daily_summaries` table created).
- **Known not-yet-done:** the **full piecewise** voice-to-beat warp (each syllable landing exactly on a beat, with beat-synced playback start) — the current alignment matches *average* pacing to the beat; the family-facing cloud read of daily summaries.
