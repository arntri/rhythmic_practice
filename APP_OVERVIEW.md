# Rhythmic Practice — App Functionality Overview

*This document describes exactly what the app does, derived from the current source code and the passing test suite (not from design intent). All thresholds, constants, and behaviors below are as written in `lib/`. Current state: **311 tests passing** (+1 skipped), `flutter analyze` clean.*

---

## 1. What the app is

A **caregiver-assisted speech-practice app** (Flutter) for people recovering speech — built on **Melodic Intonation Therapy (MIT)**: practising words slowly, on a steady beat, with graded support that fades as the person improves. The patient practice surface is **landscape** (a propped tablet, hands-free); the caregiver setup pages are **portrait**.

The person practises one word at a time; a caregiver sits alongside and, on the levels that call for it, marks how each attempt went. The app uses those caregiver judgements (not any ML model) to move each word up or down a support ladder over time.

### Core principles (enforced in code)
- **MIT support ladder** — a once-per-session **warm-up** (feel the beat, then hum), then every word climbs a 5-rung ladder (R2–R6) from "say it in unison" to "say it solo"; difficulty changes one dial at a time.
- **Audio-led, reading-optional** — the spoken model is the primary cue; a picture is the default on-screen support; the written word is optional (reading is often impaired in aphasia).
- **Caregiver-driven, rules-based progression** — the acoustic/ML scoring **never gates progression**; only the caregiver's Pass/Fail/Unsure does. The scoring is measured and displayed only.
- **Local-first & private** — everything works fully offline; raw audio is AES-encrypted on the device and auto-deleted after 48h; only anonymous metrics ever sync, and only with explicit consent.
- **Errorless, gentle** — slowing the tempo and adding support come before failure; "slowing down is support, not failure."

### Tech stack (`pubspec.yaml`)
Flutter; `sqflite` (local SQLite, schema **v25**); `audioplayers` (playback); `record` (mic); `flutter_tts` (fallback voice); `fftea` (FFT); `vibration` (haptics); `encrypt` + `flutter_secure_storage` (AES-256 at rest); `image_picker` (name-card photos); `supabase_flutter` (optional cloud); `uuid`. One bundled asset: `assets/audio/tick.wav` (metronome).

---

## 2. The MIT support ladder (`lib/practice/progression.dart`)

**Progression refactor (built-and-tested):** tapping and humming are a once-per-session **warm-up**, not per-word rungs. Each word's ladder runs **R2 → R6** (unison → solo). The rung decides what the screen asks, whether the model plays, whether the caregiver judges, and whether the mic records.

The `Rung` enum still holds all 8 values (R0–R7) so stored rung integers never need remapping, but membership is now three groups: **warm-up = R0/R1**, **active word ladder = R2–R6** (`activeLadder`, `entryRung = R2`, `topRung = R6`), **deferred = R7** (off by default, absent from the active flow).

| Rung | Group | Title (on screen) | What happens | Model plays? | Caregiver judges? | Mic records? |
|---|---|---|---|---|---|---|
| **R0** | warm-up | Feel the beat | Session warm-up: feel/tap the beat, no speech | no | no (warm-up, never judged) | no |
| **R1** | warm-up | Hum along | Session warm-up: hum/voice to the beat, no words | no | no (warm-up, never judged) | no |
| **R2** | word (entry) | Say it together | Intone the word **in unison** with the model | yes | **yes** | no |
| **R3** | word | Together, model fades | Start together; the model **fades** so she carries it | yes (fades) | **yes** | no |
| **R4** | word | Repeat after the model | Listen, then repeat | yes | yes | **yes** |
| **R5** | word | Delayed repeat | Listen, pause, then repeat | yes | yes | **yes** |
| **R6** | word (top) | Say it on your own | Solo production, prompt only | no | yes | **yes** |
| **R7** | *deferred* | Answer the question | *(scaffold, OFF)* App plays a probe question; she answers solo | no | yes | **yes** |

Membership rules in code:
- **Warm-up (R0/R1):** the session-opening tap-then-hum; **never per-word, never judged**. If one is ever fed to the engine it auto-proceeds (a safety net), it can never Fail. Tapping accuracy can therefore **never advance a word** (the bug this refactor fixes).
- **Judged (R2–R7):** `isJudged` — **every word rung is caregiver-judged**, including unison (R2). The ungraded co-production exposure now lives entirely in the warm-up.
- **Recorded/scored (R4–R7):** `cleanCapture` — only solo productions are recorded and acoustically scored. (R2/R3 are judged but *not* recorded — the model is still playing, so a mic sample would be contaminated.)
- **Active-ladder movement:** `raisedActive()` clamps at R6 (never into R7); `loweredActive()` clamps at R2 (never below unison).

**R7 — response-to-a-question (deferred scaffold):** kept as a future top rung but **OFF by default** and absent from `activeLadder`; the active ladder tops out at R6 (solo). The probe-question plumbing (`probe_question_text/_clip_path`, routing, tests) remains so it can be switched on later without a migration. The tier gate keys off top-rung = **R6** mastery, window **10** sessions @ 90%.

The four difficulty dials (only one changes per move): **support** (rung), **task demand**, **linguistic load** (syllable tier), and **tempo**.

---

## 3. A practice session, step by step

Driven by a deterministic state machine (`lib/practice/practice_controller.dart`) clocked by the metronome; rendered by `lib/screens/practice_view.dart`; assembled by `lib/screens/practice_screen.dart`.

**Session assembly** (`practice_screen._setUp`):
1. Load the profile + the **active** phrases (up to `session_phrase_limit`, default 10; the default seed has **15 phrases, 5 active** single-syllable words; two seeded longer phrases give L2/L3 examples out of the box).
2. Load each word's progression record (rung from the phrase row; tier + tempo from `progression_state`).
3. Decrypt any name-card photos for display.
4. Build the session as **each word repeated 3× consecutively** (the fixed 3-rep block, `MitProgression.repsPerBlock = 3`).
5. **Ambient calibration:** record ~2 s of room noise to set the per-session speech threshold, then a 350 ms settle so the audio session is back in playback mode.
6. Start the metronome + controller.

**States** (`PracticeState`): `preparation → warmUpHum → referencePrompt → (inputCapture) → systemTransition → … → sessionComplete`.

- **Warm-up — once per session** (fits "lock once, then flow"):
  - **Preparation ("Feel the beat").** Feel/tap the beat: **3 in-time taps** (within ±0.25 of the beat) lock it in. Tapping only ends the warm-up — it can **never advance a word**.
  - **Warm-up hum ("Hum along").** After the lock, `warmUpHum` runs for `warmUpBeats` (default 8) — hum/voice to the beat — then flows into the first word. (A zero-length warm-up, `warmUpBeats <= 0`, skips straight to the first word; used in unit tests.)
  - Both warm-up phases render the element-free arena (pulse ring, no word), keyed on **state**, not on a per-word rung.
- **Reference prompt** — shaped by the word's rung (R2–R6):
  - R2/R3: a 5-second "Get ready" countdown, then the model plays (R3 fades out); cue "Say it together" / "Carry it as it fades".
  - R4/R5: cue "Listen…", the model plays.
  - R6: "Get ready…" prompt (~2.5 s), then the mic opens.
  - *(R7, deferred/off: would play a probe question then open the mic — routing exists but is not in the active flow.)*
- **Input capture (R4–R6)** — the mic opens, the background turns a **distinct green** and a "Recording — say it once" pill shows. It auto-closes after a window of silence (caregiver-set 3–8 s, default 4.5 s).
- **Verdict (R2–R6)** — a full-height **caregiver bar pinned to the right edge** (so the left stays free for the user): **Accept** (green, =Pass), **Unsure** (blue), **Not yet** (yellow, =Fail). The warm-up has no verdict.

**On-screen indicators:** top-left pill = **"Word X of Y"** (counts words, not reps); bottom-left chip = the **current stage** ("R2 · Say it together" + a **5-dot** ladder for R2–R6, current rung filled).

---

## 4. The progression engine (`lib/practice/mit_progression.dart`)

Rules-based, label-driven, on two timescales. **The ML model never gates this.**

### Fast loop — the 3-rep block (`evaluateBlock`)
A word is always practised **exactly 3 reps** at its current rung; the decision is made **only after the block** (never mid-block). **Every word rung (R2–R6) is judged:**
- **≥ 2 Passes →** advance one rung (`raisedActive`, clamps at R6; reset tempo, clear "backed-up").
- **≥ 2 Fails →** first **lower the tempo** one step (60→50→40 BPM); at the floor, **back up one rung** (`loweredActive`, clamps at the R2 unison floor); a failed block at the already-backed-up rung **parks** the word for the session.
- **Otherwise (e.g. mostly Unsure) →** hold. **Passes never demote**; a failed block never forces an advance.
- **Caregiver cap:** advancement is clamped to a caregiver-set ceiling (low-energy sessions).

*(The warm-up rungs R0/R1 are not part of any word's block; if ever fed to `evaluateBlock` they auto-proceed as a safety net and can't Fail.)*

A rung change takes effect **the next time the word appears** (announced by a SnackBar that names the word, e.g. *"'Help': moved up to R4 · Repeat after the model"*).

### Levels by syllable count (entry rung is always unison)
A phrase's **level** is derived from its confirmed **syllable count** (`levelForSyllableCount`): **L1 = 1–3 syllables, L2 = 4–6, L3 = 7+**, capped at 3. Level seeds the word's **starting linguistic-load tier** (a longer phrase opens at a higher tier). **Every word now enters at unison (R2)** regardless of level (`entryRungForLevel` → R2) — the progression refactor's "each word's ladder starts at unison" supersedes the old level→entry-rung skip. **Level 3 still requires a caregiver-recorded slow-spoken *Sprechgesang* clip** (scaffold: `sprechgesang_clip_path` + `sprechgesangSatisfied`); until one exists, the tier gate won't raise a word into L3. The recording UI for it is not built yet.

### Slow loop — syllable tier (`shouldRaiseTier` / `raiseTier`)
Across sessions: when a word's pass rate is **≥ 90% over the last 10 sessions** (`tierPassRate = 0.9`, `tierWindow = 10`) **and it isn't already at the top level (`maxLevel = 3`)**, raise its syllable tier **and reset its rung to unison (R2)** — never raise linguistic load and drop support in the same move. (This gate-reset to unison is distinct from the *entry* rung above: the gate always restores full support after a load increase.)

### Park-and-switch, never end on failure (audit item 14)
When a word **parks** after repeated failure, the session doesn't press on with the fixed list — it **splices in a word she can currently succeed at** (the lowest-rung active word) so the next thing is a win (capped so a run of parks can't grow the session without bound). And the session **never ends on a failed verdict**: if the last word's attempt fails, a gentle low-rung **closer** is appended so the final thing she does is a light win.

### The warm-up never traps anyone on tap performance
The tap/hum warm-up runs **once per session** and is **never judged**: tap accuracy is **logged for analytics only and never gates progress** (a user with hand weakness must never be blocked). Because tapping/humming are no longer per-word rungs, tap performance can never advance — or hold back — a word.

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
Caregiver records each word **once, slowly, in a sung/intoned voice, no metronome**: **learn the tune from two demos** (see below) → **"Now you"** record → **noise reduction** (spectral subtraction) → **silence trim** → **syllable-nucleus detection** (RMS envelope + voicing gate + min-separation) → caregiver **reviews/adjusts** the syllable count (merge/split) → **taps which syllable is the HIGH note** (one human tap = the source of truth for "correct stress") → the machine **checks the melody** and coaches one fix at a time (see below) → **confirm + encrypt + save**. The recorded clip doubles as the acoustic reference. One scrolling screen, big controls, minimal text — imitation over instruction.

### Intonation flow — the melody the patient copies (`lib/analysis/pitch_detection.dart`, `lib/practice/intonation_contour.dart`, `lib/practice/intonation_reference.dart`)
The guide must carry a clear, correct **high–low contour**, so the caregiver PRODUCES + APPROVES while the machine DETECTS + CHECKS (neither fully automated nor dependent on the caregiver's musical skill):
- **Teach by two demos, no jargon** (`_teachMelody`, item 5): before recording, two contrasting tappable examples play — **"WA-ter"** (high→low, strong part first) and **"a-GAIN"** (low→high, strong part second), each a synthesized two-tone with a matching raised/lowered dot. They teach *the strong part goes up* without musical terms; then **"Now you"** invites the recording.
- **Detect** (`estimatePitch` autocorrelation F0 + RMS energy + duration, each judged **relative to neighbouring syllables**; weighted 60% pitch / 25% energy / 15% duration): the highest-scoring voiced syllable is the produced "high note"; total movement is measured in semitones.
- **"Good enough" acceptance** (`checkContour`): we do **not** require a precise minor third — any *clear* movement (≥ 1.5 semitones) on the caregiver-designated syllable passes. Only two things fail: **flat** (too even) or **mis-stressed** (high note on the wrong syllable). A single-syllable word passes if voiced.
- **Targeted feedback, one fix at a time** — flat → *"lift your voice more on part N, like the example"*; mis-stressed → *"the high note landed on part X; try it on part N instead"*, each with a replayable phrase-shaped example.
- **Graceful fallback** — after ~2 flat/mis-stressed takes the caregiver is never trapped: they can save the natural recording as-is, and the **on-screen melody cue** still carries the target contour (never flat-and-unnoticed). No pitch re-synthesis of the caregiver's voice.
- **On-screen melody cue** (`practice_view._melodyCue`, item 9): while the word is presented, a small row of dots — one per syllable, the high-note syllable raised — reinforces the intonation visually alongside the rhythm.

### Starter word library (`lib/data/starter_library.dart`, `lib/services/starter_installer.dart`, Part 3)
A small set of **~10 ready-to-use phrases that ship with a bundled guide**, so a caregiver can start a first session without recording anything. They are ordinary phrases marked `is_starter = 1` (v27) — **the flag is the only structural difference and never branches practice logic** (rungs, judging, and every progression decision ignore it); it is presentation-only (eviction-safety note below + session deprioritization). Seeded **idempotently** on first launch and on the v27 upgrade (`_seedStarters`, guarded on the flag so it never double-inserts). On launch, `StarterGuideInstaller` reads each bundled clip, **encrypts it into the same `guide_clip_path` store a recorded guide uses**, and points the phrase at it — so a starter word plays and scores through the identical path (no `is_starter` branch anywhere in practice). Guide clips live in `practice_phrases.guide_clip_path`, which the **48h eviction never touches** (it only forgets patient *attempt* audio), so starter guides are permanent by design. Caregivers **add their own phrases** (any language/script) and can **hide** a starter (`is_active = 0`) or let it sit **deprioritized** behind their own words (`getActivePhrases` orders `is_starter ASC`). Nothing assumes English. **Status: built + unit-tested (manifest, seeding/idempotence, migration, eviction-safety, deprioritize, no-branch guarantee); the bundled `.wav` clips + their metadata are clearly-marked PLACEHOLDERS (`assets/audio/starter/`) — the encrypt-and-install step is a scaffold, not device-tested. The user supplies real recordings/metadata.**

---

## 6. Speech analysis & scoring (`lib/analysis/`, `lib/services/attempt_scoring.dart`)

Pure-Dart, device-independent pipeline that **measures** a solo attempt (R4–R6) against the recorded guide:
- **Junk gate:** rejects clips that are too long (>10 s), too quiet (RMS < 0.01), or too short (<300 ms voiced).
- **MFCC:** 16 kHz mono → pre-emphasis → 25 ms/10 ms Hamming frames → 512-FFT → 26 mel filters → log → DCT-II → **13 coefficients**.
- **DTW:** Euclidean dynamic time warping; similarity = `1 / (1 + normalizedCost)` (1.0 identical).
- **Anchor templates:** on a caregiver **Pass**, the attempt's MFCC may be **promoted/replaced** as the phrase's reference (a stronger confirmed production raises the bar). Stored as derived features (MFCC blob) — **never raw audio**.

> This score is **display/measurement only** — it is stored in `acoustic_feature_vectors`, shown as a trend, and **never feeds progression**.

The heavy MFCC + DTW + onset step runs **off the UI thread in a background isolate** (`scoreClipSync` via `compute()`, audit item 21) so a long clip never janks the practice screen; only the keystore-touching decryption stays on the caller's thread. (`runInIsolate: false` runs it inline for deterministic tests.)

---

## 7. Target display & name cards

- Per-profile **target display: Picture / Word / Both** (default **Picture**). Audio always plays regardless.
- Any word can have a **photo** ("name card"): caregiver picks from the gallery → encrypted at rest (`photos/…enc`, same AES as audio) → shown above/instead of the word per the setting. Photos stay **local, never synced**.

---

## 8. Progress analytics & history (display-only)

- **Trends (`lib/analytics/trend.dart`, `progress_analytics.dart`):** per-word and overall trends for **pass rate**, **sound match (similarity)**, and **response time (latency)** — smoothed moving average + relative early-vs-late comparison (10% threshold) → **improving / plateau / declining / not-enough-data**. Latency is "lower is better." Counts only judged rungs (R4–R6). Simple statistics, **not ML**, and **never** feeds progression.
- **History screen:** "Trends over time" chips, a **by-day** rollup, **by-phrase** stats (pass %, P/F/U, avg tap-sync), and recent sessions.
- **Daily summary** (`daily_summary` table): a per-day rollup (attempts, P/F/U, avg similarity) for the dashboard and cloud sync. The per-attempt recompute is backed by indexes on `exercise_attempts(session_id)`, `exercise_attempts(timestamp)`, and `practice_sessions(profile_id)` and a sargable one-day timestamp range, so it stays a pair of index lookups rather than a full scan as history grows (audit item 22).

---

## 9. ML scaffolding (`lib/ml/`, audit items 17–20) — *scaffold-only, never gates*

Built and unit-tested, but deliberately **not trained and not in the loop**: none of this changes a phrase's rung, and the caregiver still decides every verdict. It exists so the pipeline (logging → features → model → gate → dashboard) is real end-to-end.

- **Fatigue detector (`fatigue_detector.dart`, item 17) — runs for real.** Unsupervised: compares a session's **late** window to its **early** window across three timing-regularity channels — inter-tap-interval variability, tap **dwell** variability, and **onset-vs-onset** vocal steadiness — and reports a 0–1 fatigue score with per-channel drift and a low-confidence flag. Rising scatter over the session reads as tiring; erratic-throughout does not (only drift counts). It deliberately **avoids** touch-area / `getSize()` (device-dependent, unreliable one-handed). Advisory only.
- **Layer C classifier (`layer_c_classifier.dart` + `graduation_gate.dart`, item 18) — build, don't run.** The scaffold for a future learned verdict model: a feature vector assembled from already-logged data (acoustic scores + motor-timing summaries + rung/tier/tempo), a prediction interface, and a shipped **`UntrainedLayerC` that always abstains**. It may only ever be trusted once it clears the **graduation gate**: a **Wilson score lower bound on precision ≥ 0.90** over held-out caregiver labels (precision, because the danger is a false "correct"). Since nothing is trained, it abstains → no scored Pass calls → the gate never graduates → the caregiver stays in charge, by construction.
- **Scoped solo mode (`solo_mode.dart`, item 19) — scaffold + flag.** A pure policy: a word is solo-eligible only when it's at a solo rung (≥ R6) with a strong recent top-rung pass rate over enough sessions; and even then solo mode is **advisory-only** until Layer C graduates. Wired to a `solo_mode_enabled` profile flag (off by default; caregiver toggle under Settings → *Experimental*). No dedicated solo screen yet.
- **Insights dashboard (`insights_dashboard.dart`, `screens/ml_insights_screen.dart`, item 20).** A caregiver-facing, display-only assembly of the above — per-session fatigue, the recent pass-rate trend, Layer C's "not trusted yet, and why," and the solo-ready word count — behind an **Insights (experimental)** button in History, with a banner stating it never changes levels.

---

## 10. Privacy & data

- **Audio at rest:** AES-256-CBC with a fresh random IV; the key lives in the OS keystore (`flutter_secure_storage`), never on disk/DB. Plaintext is deleted immediately after encryption.
- **48-hour audio eviction (`audio_eviction.dart`):** raw clips older than 48 h are deleted and the path nulled; **all derived, non-audio data is kept** — the attempt row + its verdict/scores, the anchor MFCC templates, the patient's onset stream, and the raw tap stream (verified by test, audit item 23). Runs on every launch.
- **Cloud is optional & consent-gated (`sync_service.dart`):** pushes **metrics only** (sessions, attempts, daily summaries) — **never audio, photos, guide clips, or keys** — and only when (a) the cloud is reachable, (b) the caregiver is signed in, and (c) `guardian_consent_granted` is on. One-way, idempotent, resilient per-row.

---

## 11. Cloud & family sharing (`cloud.dart`, `auth_service.dart`, `cloud_sharing.dart`)

- Email/password accounts via Supabase; being signed out is normal (cloud just unlocks sync + remote viewing). If unconfigured, the app is fully local.
- **Family sharing:** owners get a **share code**; family members **join with a code** to view (read-only, row-level-security filtered) the latest **metrics** (phrase, verdict, sync score, time) — no audio.

---

## 12. Screens & per-screen orientation (Part 2, item 4)

**Patient surface = landscape; caregiver pages = portrait** (`lib/app/orientation.dart`). The app starts landscape (`HomeScreen`, the patient's start surface, and `PracticeScreen`, the propped-tablet session). Caregiver setup pages flip to **portrait** (a phone held upright): `SettingsPortal`, `GuideRecordingScreen`, `HelpScreen`, `HistoryScreen`/`MlInsightsScreen`, `ProgressScreen`, `MetronomeScreen`, `AccountScreen`. Orientation is driven centrally by `OrientationRouteObserver` off the top route: caregiver pages push as a `PortraitPageRoute`, the practice surface as a `LandscapePageRoute`, and an untagged nested push inherits its parent's orientation — so caregiver→caregiver navigation never races on dispose. *(Built + unit-tested via the route→orientation classification and the observer's channel calls; the actual on-device rotation/layout is **built-not-device-tested** — no Linux GUI here.)*

`HomeScreen` (calm lavender canvas, big "Tap to start," ⓘ help, top-right menu) → `PracticeScreen`/`PracticeView` (the session) · `HelpScreen` (first-run onboarding + reopenable) · `SettingsPortal` (caregiver, behind a **slide-to-unlock**) · `GuideRecordingScreen` · `HistoryScreen` (→ **`MlInsightsScreen`**, experimental) · `ProgressScreen` (family) · `MetronomeScreen` (standalone) · `AccountScreen`.

**Caregiver settings expose:** tempo (40–70 BPM), sensory channels (visual/sound/haptic), session length (1–20), recording length (3–8 s), target display (picture/word/both), **playback speed (1×/0.75×/0.5×)**, auto-progression on/off, **solo practice on/off (experimental, item 19)**, add custom phrase (any language), and per-phrase: active toggle (hide/show, incl. **starter words**), **manual rung ◀/▶**, photo add/change/remove, record-guide; plus the **privacy/consent** toggle.

---

## 13. Data model (SQLite, schema v25)

- **user_profiles** — one local profile; all preferences (tempo, channels, session/recording length, consent + timestamp, target_display, playback_speed, auto_progress_enabled, onboarding_seen, session_rung_cap, demo_mode_enabled, **solo_mode_enabled** (item 19, scaffold), cloud_profile_id).
- **practice_phrases** — text, word/syllable counts, **complexity_level (derived from syllable_count, v23)**, current_rung, guide_clip_path (encrypted reference) + guide_nuclei_ms, photo_path, **probe_question_text/_clip_path** (R7, v21), **stress_index** (high-note syllable for the melody, v22), **sprechgesang_clip_path** (item 15, v25), is_active, **is_starter** (starter word library, v27; presentation-only).
- **practice_sessions / exercise_attempts** — each attempt's verdict, latency/duration, tap-sync score, rung_at_attempt, tier_at_attempt, **tempo_bpm** (v20: beat reference at capture, for onset-vs-beat steadiness), encrypted audio path (nulled after 48 h), synced_at.
- **tap_events** (v19, ML logging item 16a) — the **raw per-tap stream**: one row per tap (touch-down time, dwell = press duration, beat phase at touch-down), tied to attempt/phrase/rung/session. This is the un-aggregated data the fatigue detector needs (dwell trend + inter-tap-interval variance) — the single tap-sync score on the attempt row can't reconstruct it. **Derived non-audio data → never evicted** (kept beyond the 48 h audio window). Indexed by attempt and by session.
- **acoustic_feature_vectors** — per-attempt gate verdict + DTW similarity, plus (v20) **mfcc_distance** (the raw un-squashed DTW cost behind the similarity, item 16b) and **onset_ms** (the patient's own detected syllable onsets, CSV, item 16c). Written for the clean-capture rungs (r4–r6), where a solo clip exists. *(r1–r3 open no mic — model/hum would bleed — so they have a caregiver label + tap stream but no acoustic vector, by design.)*
- **phrase_anchor_templates** — per-(profile,phrase) MFCC reference (derived features, never audio).
- **progression_state** — per-(profile,phrase) rung, syllable_tier, tempo_bpm.
- **daily_summary** — per-(profile,day) metrics rollup.

*(Legacy/unused: `practice_phrases.audio_asset_path`, `exercise_attempts.support_level`.)*

**ML-logging status (audit item 16 — complete):** the raw tap stream (16a, dwell + inter-tap timing), the per-attempt acoustic vector with both DTW similarity and raw MFCC distance (16b), and the patient's own syllable onsets + beat reference (16c) are all captured and kept past the 48 h audio eviction — enough to reconstruct dwell/ITI-variance fatigue signals and onset-vs-beat vocal steadiness offline. All are logged data only; **none gates progression** (still caregiver-in-the-loop). The downstream consumers (fatigue detector 17, Layer C classifier 18, dashboard 20) are not yet built.

---

## 14. Testing

**331 tests passing** (`flutter test`, +1 skipped), covering: WAV codec, MFCC, DTW, junk gate, MFCC codec, attempt analyzer/scoring (incl. raw MFCC distance + patient-onset capture), time-stretch, syllable detection, **pitch (F0) detection + intonation-contour analysis** (relative-stress + "good enough" acceptance) + **reference-melody synthesis**, noise reduction, audio trim, AES crypto, audio eviction; the metronome/beat scheduler, tap-sync; the practice controller FSM including the **warm-up (tap→hum) state and the "tapping can never advance a word" guarantee**, the raw tap-stream capture (touch-down + dwell) and the deferred-R7 routing, progression (**warm-up vs active R2–R6 ladder**, every word rung judged, `raisedActive`/`loweredActive` clamps, MIT 3-rep block, tier gate @ 10 sessions @ top-rung R6, auto-progression, progression service); repository + anchors + tap_events + probe-question + stress-index + schema migrations (**v1→v27**, incl. v23 syllable-count→level/tier reconciliation, v24 solo-mode flag, v25 sprechgesang col + daily-summary indexes, **v26 rung-reconcile into the active [R2, R6] ladder**, **v27 is_starter + idempotent starter-library seeding**) + syllable-count→level mapping + **unison entry rung** + tier-cap + the park-and-switch/end-on-success session-queue mechanics + the **starter word library** (manifest, seeding/idempotence, structural parity, eviction-safety, deprioritize ordering, no-branch guarantee); **ML scaffolding — fatigue detector (drift over tap/dwell/onset regularity), Wilson-lower-bound graduation gate, Layer C feature assembly + untrained-abstain, scoped-solo policy, and the insights dashboard assembly**; the Sprechgesang L3 gate, the off-thread scoring isolate parity, and the eviction-keeps-derived-data guarantee; sync service; analytics/trends + capture analysis + history; **per-screen orientation** (route→orientation classification + observer channel calls, item 4) and the **two-demo melody teaching** step (item 5); and widget tests (practice view incl. the **warm-up tap/hum arenas**, melody cue, settings, metronome screen, slide-to-unlock).

The pure logic (audio DSP, progression rules, analytics, data layer) is unit-tested. **Device-gated** parts — live mic recording, audio playback/TTS, gallery photo pick, keystore — are verified on a physical device rather than in tests.

---

## 15. Status & honest caveats
- **Verified on device:** the guide audio plays; the core practice loop runs.
- **Built, awaiting device verification:** gallery photo pick + display, ambient calibration feel, the full MIT 3-rep-block progression end-to-end, the daily-summary cloud push (needs the Supabase `daily_summaries` table created).
- **Known not-yet-done:** the **full piecewise** voice-to-beat warp (each syllable landing exactly on a beat, with beat-synced playback start) — the current alignment matches *average* pacing to the beat; the family-facing cloud read of daily summaries.
