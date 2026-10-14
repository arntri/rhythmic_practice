# Rhythmic Practice — App Functionality Overview

*This document describes exactly what the app does, derived from the current source code and the passing test suite (not from design intent). All thresholds, constants, and behaviors below are as written in `lib/`. Current state: **429 tests passing** (+1 skipped), `flutter analyze` clean.*

---

## 1. What the app is

A **caregiver-assisted speech-practice app** (Flutter) for people recovering speech — built on **Melodic Intonation Therapy (MIT)**: practising words slowly, on a steady beat, with graded support that fades as the person improves. The patient practice surface is **landscape** (a propped tablet, hands-free); the caregiver setup pages are **portrait**.

The person practises one word or phrase at a time; a caregiver sits alongside and marks how each attempt went. The app uses those caregiver judgements (not any ML model) to decide what happens next — within the session, and to move the person up MIT's levels over time.

### Core principles (enforced in code)
- **MIT's own structure** — a once-per-session **warm-up** (feel the beat, then hum), then **every item runs the whole step sequence for the patient's level, in one sitting**, from humming the tune to answering a question with the phrase. A failed step backs up immediately; two failures set the item aside.
- **Both MIT ingredients run on every trial** — the melody *and* the rhythmic hand tapping. Each phrase opens with its own melody **hummed twice** before any words appear, and the caregiver is cued to tap the person's **left hand once per syllable** through the whole of every phrase — hum, model, and their own production alike. Tapping is a support, never a gate: it is recorded, but it can never move the sequence.
- **Audio-led, reading-optional** — the spoken model is the primary cue; a picture is the default on-screen support; the written word is optional (reading is often impaired in aphasia).
- **Caregiver-driven, rules-based progression** — the acoustic/ML scoring **never gates progression**; only the caregiver's Pass/Fail/Unsure does. The scoring is measured and displayed only.
- **Local-first & private** — everything works fully offline; raw audio is AES-encrypted on the device and auto-deleted after 48h; only anonymous metrics ever sync, and only with explicit consent.
- **Errorless, gentle** — slowing the tempo and adding support come before failure; "slowing down is support, not failure."

### Tech stack (`pubspec.yaml`)
Flutter; `sqflite` (local SQLite, schema **v32**); `audioplayers` (playback); `record` (mic); `flutter_tts` (fallback voice); `fftea` (FFT); `vibration` (haptics); `encrypt` + `flutter_secure_storage` (AES-256 at rest); `image_picker` (name-card photos); `supabase_flutter` (optional cloud); `uuid`. Bundled assets: `assets/audio/tick.wav` (metronome) and the starter library's guide clips under `assets/audio/starter/`.

---

## 2. MIT's levels and steps (`lib/practice/mit_sequence.dart`)

**The revert to canonical MIT (2026-09-01, DB v28).** The app used to run a
support **ladder**: a word *sat* at a rung, ran three reps there, and an engine
moved it up or down **between sessions** — so a word could take weeks to travel
from unison to solo. MIT does not work that way. The clinician runs **the whole
step sequence on every item, every session**, and backs up a step the instant one
fails. The sequence *is* the therapy; the ladder was our re-engineering of it.

**A level belongs to the PATIENT, not to a word.** MIT's three levels are three
step sequences chosen for the person's severity. (Our old "level" meant a
phrase's syllable count, which confused *how long an item is* with *how much
support the person needs*. That is gone.)

| Level | Sequence | For |
|---|---|---|
| **I** | hum melody → hum in unison → intone in unison | Most severe. Never asked to produce independently, so nothing here can be failed for not speaking. |
| **II** | hum melody → intone in unison → unison fading → immediate repeat → **probe question** | MIT's core. The default. |
| **III** | delayed repeat → **probe question** → **Sprechgesang** → **spoken production** | Established items: retrieval, use, then the bridge back out of song. |

**The steps** (`MitStep`):

| Step | Model plays | Judged | Mic |
|---|---|---|---|
| **hum melody** | yes (synthesized) | **no** — the melody is being *given* | no |
| **hum unison** | yes | yes | no |
| **intone unison** | yes | yes | no |
| **unison fading** | yes, cut short | yes | no |
| **immediate repeat** | yes | yes | **yes** |
| **delayed repeat** | yes, then 6 s silence | yes | **yes** |
| **probe question** | the question only | yes | **yes** |
| **Sprechgesang** | the phrase *spoken*, rhythm intact | yes | **yes** |
| **spoken production** | nothing at all | yes | **yes** |

- **`isJudged`** — everything but the opening hum. A unison step is judged *but
  not recorded*: the model sounding aloud would contaminate the mic.
- **`cleanCapture`** — only the three steps that yield a solo production are
  recorded and acoustically scored.
- **The probe question is ON.** MIT's actual step 5 — the only step that asks the
  person to *use* the phrase rather than reproduce it. (The old ladder's R6 "say
  it on your own, prompt only" is **retired**: it is not a MIT step, and the
  probe question is the independent production.)
- **`isIntoned`** — the last two steps of Level III are deliberately not sung.
  **Sprechgesang** keeps MIT's rhythm and the hand-tapping but drops the pitch
  contour: the phrase is *spoken* with exaggerated prosody. **Spoken production**
  drops even that. This is MIT's exit ramp and it is not optional — a patient who
  can produce a phrase only while singing it has not generalised. The withdrawal
  is staged, so there is always something left to hold onto.

### The one deliberate departure — 2-of-3 reps (`RepRule`)

Not MIT's; the caregiver's. A trained clinician judges a production once and is
right; an untrained caregiver watching their parent is not so sure, and a wrong
verdict here costs a step wrongly failed and a person wrongly backed up. So each
judged step is produced **twice, or three times at worst**:

- **Pass, Pass** → passed. No third.
- **Fail, Fail** → failed. No third either — a third try after two clear failures
  is the opposite of errorless practice.
- **Anything else** (any Unsure, or one of each) → a deciding third, simple
  majority; three Unsures fail safe.

The asymmetry is deliberate: certainty in either direction stops at two, and only
doubt costs a third rep.

### Back-up and set-aside (`MitItemRun`)

- **A failed step backs up to the previous step and re-runs it — immediately**,
  in the same sitting. Support is restored in the moment, not at the word's next
  appearance. At Level II, failing the first *judged* step backs up to **the
  hum**: the person who cannot intone it in unison needs the melody again.
- **Two step failures in a row** — or a failure with nowhere lower to go — **sets
  the item aside** for today and the session moves on. Drilling a failure is not
  what MIT does. (This replaced the old park-and-switch, which spliced in an
  easier word.)

### Level advancement (`LevelCriterion`) — the only automatic decision left

**≥ 90% of judged productions across the last 10 sessions** moves the **person**
up a level. Evaluated once, at session end. Caregiver-toggleable
(`auto_progress_enabled`), and the level is settable by hand in the caregiver
portal at any time.

### What is gone

No per-word rung. No syllable tier. **No tempo dial** — MIT intones slowly and
stays there, so there is one caregiver-set session tempo (40–70 BPM, a comfort
setting) and nothing lowers it on failure. No comfort cap. `progression.dart` and
`mit_progression.dart` are deleted; see `DEPRECATIONS.md` §2–§4.

---

## 3. A practice session, step by step

Driven by a deterministic state machine (`lib/practice/practice_controller.dart`) clocked by the metronome; rendered by `lib/screens/practice_view.dart`; assembled by `lib/screens/practice_screen.dart`.

**Session assembly** (`practice_screen._setUp`):
1. Load the profile — including the **patient's MIT level**, which selects the sequence every item will run — and the **active** phrases (up to `session_phrase_limit`, default 10).
2. Decrypt any name-card photos for display.
3. Build the session as **one entry per item** (reps are no longer baked into the list — how many productions a step takes is decided step by step by `RepRule`).
4. **Ambient calibration:** record ~2 s of room noise to set the per-session speech threshold, then a 350 ms settle so the audio session is back in playback mode.
5. Start the metronome + controller.

**States** (`PracticeState`): `preparation → warmUpHum → phraseHum → referencePrompt → (inputCapture) → systemTransition → … → sessionComplete`. The controller translates the current **MIT step** into these states; a verdict feeds the step's `MitItemRun`, and whatever step the run lands on next is re-entered — which is why *another rep*, *the next step* and *an immediate back-up* are all one code path.

- **Warm-up — once per session** (fits "lock once, then flow"). Not a MIT step:
  - **Preparation ("Feel the beat").** Feel/tap the beat: **3 in-time taps** (within ±0.25 of the beat) lock it in. Tapping only ends the warm-up — it can **never move the sequence**.
  - **Warm-up hum ("Hum along").** After the lock, `warmUpHum` runs for `warmUpBeats` (default 8) — hum/voice to the beat — then flows into the first item.
  - Both render the element-free arena (pulse ring, no word), keyed on **state**.
- **Hum step** (`phraseHum`, MIT step 1). The item's **own melody is hummed twice** while **the item itself stays on screen** (the picture, or the word when there is no picture). What this step withholds is the **spoken model** — the app hums rather than says the words — not the item's identity: the person is meant to hold the phrase in mind against the tune, which they cannot do if they don't yet know which phrase it is. Two pitches a minor third apart, one syllable per beat, synthesized on the spot from the phrase's syllable count + stressed syllable (`lib/practice/hum_melody.dart`, played by `lib/services/melody_hummer.dart`). The melody contour is enlarged here — the tune is the content, not a reinforcement. Nothing is recorded and **nothing is judged**. The screen ends the state when the melody finishes; `phraseHumBeats` (default 12) is only a safety cap, and `0` disables the step (used by unit tests).
- **Reference prompt** — shaped by the current **step**:
  - **hum unison:** the melody plays again and she hums with it; then the verdict. Level I only.
  - **intone unison / unison fading:** a 5-second "Get ready" countdown, then the model (the fading step drops the final syllable so she carries the end alone); cue "Say it together" / "Carry it as it fades".
  - **immediate repeat:** cue "Listen…", the model plays, a 1.2 s breath, then the mic.
  - **delayed repeat:** the model, then **six seconds of silence** before the mic (`delayedRepeatMs`, `lib/practice/step_timing.dart`) — the delay is the point: a short gap lets the phrase be echoed while it still rings, a long one forces genuine retrieval. The beat keeps running and the caregiver keeps tapping through it.
  - **probe question:** the caregiver's recorded/typed question plays (a gentle generic prompt if none is set — it never blocks), a breath, then the mic.
  - **Sprechgesang:** the phrase's slow-**spoken** clip plays, deliberately *not* beat-warped onto the melody — the pulse is carried by the metronome and the tapping hand instead, which is the whole content of the step. The tick stays audible until the model ends. Then a breath, then the mic. Falls back to the built-in voice when no slow-spoken clip has been authored.
  - **spoken production:** nothing plays. A brief get-ready (2.5 s), then the mic.
- **Input capture** — at the three recording steps, the mic opens, the background turns a **distinct green** and a "Recording — say it once" pill shows. Auto-closes after a window of silence (caregiver-set 3–8 s, default 4.5 s).
- **Verdict** — a full-height **caregiver bar pinned to the right edge** (so the left stays free for the user): **Yes** (pale green, =Pass), **Maybe** (pale lavender, =Unsure), **Not yet** (pale amber, =Fail). The question is per step ("Did they carry it as the model faded?", "Did they answer with the word?"). The warm-up and the hum step have no verdict.

**Hand tapping (on screen):** through the hum, the model and the person's own production, a tap cue sits along the bottom — a dot that swells on the beat (so the caregiver has something to tap in time with even when the tick is off) beside *"Tap their left hand on each syllable"*. Every tap that lands lights it. It shows **no accuracy**: an off-beat tap looks exactly like an on-beat one. It is hidden in the gaps — the count-in, the six-second retrieval silence, the verdict.

**On-screen indicators:** top-left pill = **"Word X of Y"** (one item per entry now); bottom-left chip = the **current step** ("Step 4 · Repeat after the model") with one dot per step of the level's sequence, current filled — a position in this item's run, not a rung the word has been assigned to.

---

## 4. Tapping, and what it does not do

Canonical MIT taps the patient's **left hand once per syllable through every
production at every step** — it is one of the therapy's two active ingredients,
not a readiness drill. So tapping is cued for the whole of every production
(`PracticeController.tappingExpected`, opened and closed by the screen via
`beginProduction`/`endProduction`), including the unison steps where nothing is
recorded.

It is **completely non-gating**. Tap accuracy is logged for analytics only; the
once-per-session tap/hum warm-up is never judged; and nothing about the taps
moves the sequence — only the caregiver's verdict does. A user with hand weakness
must never be blocked, and the caregiver may tap hand-over-hand on their behalf.

**Phrase-locked, not clock-locked.** The tapping starts and stops **with the
phrase**, so a three-syllable phrase gets three taps and then the hand rests. Any
state change closes the window, so it can never leak past the production that
opened it.

---

## 5. Audio

### Tri-sensory metronome (`lib/metronome/`)
- Drift-free scheduling: each beat is a fixed point on an absolute timeline (`beat_scheduler.dart`), so error never accumulates.
- **Missed beats are counted but not replayed.** A stalled frame leaves several beats overdue at once; `update()` still fires them all so the FSM's beat counting stays on the grid, but `shouldSoundBeat` lets the engine **sound only the beat we're still nearer to than to the next one**. Without this a stall dumped five or six ticks into one frame — heard on device as a stutter burst during the caregiver verdict. A stall now costs a beat of silence, never a burst.
- Three independent channels — **sound** (`tick.wav`), **visual** (a pulsing ring that peaks on the beat), **haptic** (a short pulse; **70 ms** on beat-focused phases, **40 ms** otherwise, full amplitude where supported).
- Tempo bounded **40–70 BPM** in practice (one beat ≈ one syllable; slow is support).

### Guide playback (`lib/services/guide_player.dart`)
- **Recorded guide (preferred):** decrypt → decode → **pitch-preserving time-stretch (WSOLA, `lib/practice/time_stretch.dart`)** → play (the recording stays untouched; only the playback copy is stretched). **Voice-to-beat alignment (`beat_align.dart`):** when the guide's syllable timings are known, the stretch is chosen so the **average syllable spacing equals one beat** at the word's tempo — so the voice and the metronome don't drift apart (interim of a full per-syllable warp). Otherwise it falls back to per-step elongation (unison 2.8×, repeat 2.2×, probe 1.8×). The **unison-fading** step drops the final syllable and fades the volume (1.0 → ~0.15) so the user carries the end alone.
- **TTS fallback** (no recorded clip): `flutter_tts` at a rate of `0.30 / ttsStretch` (slower than the recorded path; clamped 0.1–0.35).
- **Caregiver "Playback speed" (1× / 0.75× / 0.5×):** an overall multiplier that divides into the stretch — 0.5× makes the word come out at half speed.
- Completion fires once, via the player event **or** a duration-sized safety timer.

### Recording capture (`lib/services/mic_capture.dart`, `lib/practice/capture_analysis.dart`)
- Records 16 kHz mono PCM16 WAV; closes after silence (caregiver-set window) using a speech threshold derived from the per-session ambient calibration (median ambient + 12 dB, clamped −55…−25 dBFS; default −40 dBFS).
- Measures **latency** (gap to first speech) and **duration**; encrypts the clip at rest.

### Guide clips are authored, not recorded in-app
**Caregivers never record.** The owner authors every guide clip and ships it with the app; the in-app caregiver recording flow (`guide_recording_screen.dart`, `guide_recorder.dart`) has been **removed**. Each phrase needs **two** authored clips — the sung guide (`guide_clip_path`, which doubles as the DTW acoustic reference) and the slow-spoken Sprechgesang clip (`sprechgesang_clip_path`) the last steps of Level III play. With either missing the app falls back to the built-in voice: it runs, but it is not the therapy.

**Clip QA** (`clip_qa_screen.dart`, internal, behind demo mode): reports which authored clips exist and which phrases carry the metadata the melody is built from (syllable count, stress index). It deliberately does **not** show acoustic green ticks it hasn't earned — tempo, the minor third, one-syllable-per-beat and stress placement are **not** machine-checked.

**Retained but currently uncalled:** `lib/analysis/pitch_detection.dart`, `lib/practice/intonation_contour.dart`, `lib/practice/noise_reduction.dart` and `lib/practice/audio_trim.dart` were the recording flow's DSP (F0 detection, contour check, spectral subtraction, silence trim). They are pure, unit-tested functions with **no production caller** now that the flow is gone — kept for owner-side authoring rather than deleted. `intonation_reference.dart` is still live: `hum_melody.dart` builds the synthesized melody from it.

### Intonation — the melody the patient copies (`lib/practice/intonation_reference.dart`, `lib/practice/hum_melody.dart`)
The melody the patient hears is **synthesized on the spot**, not extracted from a recording: two pitches a minor third apart, one syllable per beat, built from the phrase's syllable count and its caregiver/author-designated high-note syllable (`stress_index`, v22). So a phrase carries a correct contour whether or not an authored clip exists.

- **On-screen melody cue** (`practice_view._phraseStaff`, item 9): while the word is presented, one node per syllable with the high-note syllable **raised** — the vertical axis is pitch, the horizontal is the rhythm (one syllable per beat, exactly what the hand taps). A phrase with no designated tune yet degrades to the **flat** form (every node on one line) rather than vanishing: the rhythm is true even when the melody isn't.
- **Per-beat illumination:** the node for the syllable sounding **right now** glows as the beat reaches it. It is anchored to `PracticeController.beatsIntoProduction` — the production window opens on the model's *real* start (after the beat-sync wait), so beat 0 of the count really is the first syllable. Never lit during the "Get ready" count-in (nothing is sounding yet) and never while the mic is open (the staff is hidden there — it would become a thing to chase).
- **Withdrawal is staged:** the staff collapses to one line at **Sprechgesang** and is **absent** at **spoken production**. The scaffold coming away is the content of those two steps, and the staff is where it can be seen coming away.

### Starter word library (`lib/data/starter_library.dart`, `lib/services/starter_installer.dart`, Part 3)
A small set of **~10 ready-to-use phrases that ship with a bundled guide**, so a caregiver can start a first session with no setup at all. They are ordinary phrases marked `is_starter = 1` (v27) — **the flag is the only structural difference and never branches practice logic** (the step sequence, judging, and level advancement all ignore it); it is presentation-only (eviction-safety note below + session deprioritization). Seeded **idempotently** on first launch and on the v27 upgrade (`_seedStarters`, guarded on the flag so it never double-inserts). On launch, `StarterGuideInstaller` reads each bundled clip, **encrypts it into the same `guide_clip_path` store every authored guide uses**, and points the phrase at it — so a starter word plays and scores through the identical path (no `is_starter` branch anywhere in practice). Guide clips live in `practice_phrases.guide_clip_path`, which the **48h eviction never touches** (it only forgets patient *attempt* audio), so starter guides are permanent by design. Caregivers **add their own phrases** (any language/script) and can **hide** a starter (`is_active = 0`) or let it sit **deprioritized** behind their own words (`getActivePhrases` orders `is_starter ASC`). Nothing assumes English. **Status: built + unit-tested (manifest, seeding/idempotence, migration, eviction-safety, deprioritize, no-branch guarantee); the bundled `.wav` clips + their metadata are clearly-marked PLACEHOLDERS (`assets/audio/starter/`) — the encrypt-and-install step is a scaffold, not device-tested. The user supplies real recordings/metadata.**

---

## 6. Speech analysis & scoring (`lib/analysis/`, `lib/services/attempt_scoring.dart`)

Pure-Dart, device-independent pipeline that **measures** a solo production (the three clean-capture steps) against the recorded guide:
- **Junk gate:** rejects clips that are too long (>10 s), too quiet (RMS < 0.01), or too short (<300 ms voiced).
- **MFCC:** 16 kHz mono → pre-emphasis → 25 ms/10 ms Hamming frames → 512-FFT → 26 mel filters → log → DCT-II → **13 coefficients**.
- **DTW:** Euclidean dynamic time warping; similarity = `1 / (1 + normalizedCost)` (1.0 identical).
- **Anchor templates:** on a caregiver **Pass**, the attempt's MFCC may be **promoted/replaced** as the phrase's reference (a stronger confirmed production raises the bar). Stored as derived features (MFCC blob) — **never raw audio**.

> This score is **display/measurement only** — it is stored in `acoustic_feature_vectors`, shown as a trend, and **never feeds progression**.

The whole heavy path — **reading the clips, AES-decrypting them, decoding the WAVs, then MFCC + DTW + onsets** — runs **off the UI thread in a background isolate** (`scoreClipSync` via `compute()`, audit item 21). Only the **keystore lookup for the AES key** stays on the caller's thread (platform channels are reachable only from the root isolate); the key then travels into the worker inside a `ClipRef`, so the cipher pass goes with it. This matters because scoring runs at the caregiver verdict *while the metronome is still beating* — decrypting two multi-second clips on the UI thread starved the metronome's `Ticker` and made the beat stutter. (`runInIsolate: false` runs it inline for deterministic tests; an injected `decryptor` hands the worker plaintext bytes so tests never touch the keystore.)

---

## 7. Target display & name cards

- Per-profile **target display: Picture / Word / Both** (default **Picture**). Audio always plays regardless.
- Any word can have a **photo** ("name card"): caregiver picks from the gallery → encrypted at rest (`photos/…enc`, same AES as audio) → shown above/instead of the word per the setting. Photos stay **local, never synced**.

---

## 8. Progress analytics & history (display-only)

- **Trends (`lib/analytics/trend.dart`, `progress_analytics.dart`):** per-word and overall trends for **pass rate**, **sound match (similarity)**, and **response time (latency)** — smoothed moving average + relative early-vs-late comparison (10% threshold) → **improving / plateau / declining / not-enough-data**. Latency is "lower is better." Counts only the recorded steps. Simple statistics, **not ML**, and **never** feeds progression.
- **History screen:** "Trends over time" chips, a **by-day** rollup, **by-phrase** stats (pass %, P/F/U, avg tap-sync), and recent sessions.
- **Daily summary** (`daily_summary` table): a per-day rollup (attempts, P/F/U, avg similarity) for the dashboard and cloud sync. The per-attempt recompute is backed by indexes on `exercise_attempts(session_id)`, `exercise_attempts(timestamp)`, and `practice_sessions(profile_id)` and a sargable one-day timestamp range, so it stays a pair of index lookups rather than a full scan as history grows (audit item 22).

---

## 9. ML scaffolding (`lib/ml/`, audit items 17–20) — *scaffold-only, never gates*

Built and unit-tested, but deliberately **not trained and not in the loop**: none of this changes what the sequence does or what level the patient is on, and the caregiver still decides every verdict. It exists so the pipeline (logging → features → model → gate → dashboard) is real end-to-end.

- **Fatigue detector (`fatigue_detector.dart`, item 17) — runs for real.** Unsupervised: compares a session's **late** window to its **early** window across three timing-regularity channels — inter-tap-interval variability, tap **dwell** variability, and **onset-vs-onset** vocal steadiness — and reports a 0–1 fatigue score with per-channel drift and a low-confidence flag. Rising scatter over the session reads as tiring; erratic-throughout does not (only drift counts). It deliberately **avoids** touch-area / `getSize()` (device-dependent, unreliable one-handed). Advisory only.
- **Layer C classifier (`layer_c_classifier.dart` + `graduation_gate.dart`, item 18) — build, don't run.** The scaffold for a future learned verdict model: a feature vector assembled from already-logged data (acoustic scores + motor-timing summaries + the MIT step/level/tempo context), a prediction interface, and a shipped **`UntrainedLayerC` that always abstains**. It may only ever be trusted once it clears the **graduation gate**: a **Wilson score lower bound on precision ≥ 0.90** over held-out caregiver labels (precision, because the danger is a false "correct"). Since nothing is trained, it abstains → no scored Pass calls → the gate never graduates → the caregiver stays in charge, by construction.
- **Scoped solo mode (`solo_mode.dart`, item 19) — scaffold + flag.** A pure policy: a word is solo-eligible only when its recent pass rate **at the probe question** — MIT's most independent step — is strong over enough sessions; and even then solo mode is **advisory-only** until Layer C graduates. (This was keyed on "rung ≥ R6" before the revert; with the sequence run in full every session there is no resting rung to compare, so the honest question is how the person does at the hardest step when they get there.) Wired to a `solo_mode_enabled` profile flag (off by default; caregiver toggle under Settings → *Experimental*). No dedicated solo screen yet.
- **Insights dashboard (`insights_dashboard.dart`, `screens/insights_screen.dart`, item 20).** A caregiver-facing, display-only assembly of the above — per-session fatigue, the recent pass-rate trend, Layer C's "not trusted yet, and why," and the solo-ready word count — reachable as **Insights (experimental)** from the caregiver panel (and from History), with a banner stating it never changes levels.

---

## 10. Privacy & data

- **Audio at rest:** AES-256-CBC with a fresh random IV; the key lives in the OS keystore (`flutter_secure_storage`), never on disk/DB. Plaintext is deleted immediately after encryption.
- **48-hour audio eviction (`audio_eviction.dart`):** raw clips older than 48 h are deleted and the path nulled; **all derived, non-audio data is kept** — the attempt row + its verdict/scores, the anchor MFCC templates, the patient's onset stream, and the raw tap stream (verified by test, audit item 23). Runs on every launch.
- **Cloud is optional & consent-gated (`sync_service.dart`):** pushes **metrics only** (sessions, attempts, daily summaries) — **never audio, photos, guide clips, or keys** — and only when (a) the cloud is reachable, (b) the caregiver is signed in, and (c) `guardian_consent_granted` is on. One-way, idempotent, resilient per-row.

---

## 11. Cloud (`cloud.dart`, `sync_service.dart`) — plumbing only, no surface

The Supabase connection and the one-way metrics push are intact and still run on launch (`Cloud.initialize()`, `SyncService().pushPending()`), and if the cloud is unconfigured or unreachable the app is fully local — unchanged.

**But there is no cloud UI any more.** The sign-in screen (`account_screen.dart`) and the family-sharing reader (`progress_screen.dart`, share codes + join-with-code), along with `auth_service.dart` and `cloud_sharing.dart`, were **removed** — they had been left unreachable by the home-screen rewrite and were cut rather than rewired. The consequence, stated plainly: `SyncService` gates on being signed in, and **nothing in the app can sign in**, so the push is dormant in practice. The caregiver's consent switch (`guardianConsentGranted`, in **Privacy**) still records intent and still gates the push, so re-adding a sign-in entry point is all that would be needed to make it live again.

---

## 12. Screens & per-screen orientation (Part 2, item 4)

**Patient surface = landscape; caregiver pages = portrait** (`lib/app/orientation.dart`). The app starts landscape: `HomeScreen` (the patient's start surface) and `PracticeScreen`/`LevelUpScreen` (the propped-tablet session). Everything caregiver-facing flips to **portrait** (a phone held upright). Orientation is driven centrally by `OrientationRouteObserver` off the top route: caregiver pages push as a `PortraitPageRoute`, the practice surface as a `LandscapePageRoute`, and an untagged nested push inherits its parent's orientation — so caregiver→caregiver navigation never races on dispose. *(Built + unit-tested via the route→orientation classification and the observer's channel calls; the actual on-device rotation/layout is **built-not-device-tested** — no Linux GUI here.)*

**The patient's side — two screens, no menu.** `HomeScreen` is a calm canvas whose **whole surface is the button**: tapping it waters the **plant** (`widgets/plant.dart`, one growth stage per day practice happens, cumulative, never backwards) and then opens the session. The only other control is a **slide-to-unlock vine** (`widgets/vine_slide_control.dart`) to the caregiver panel — deliberately not a tappable menu. → `PracticeScreen`/`PracticeView` (the session) · `LevelUpScreen` (the level-up offer, accept/decline) · `FirstRunScreen` (first launch only, until `onboarding_seen`).

**The caregiver's side — one panel with sections, not ten screens.** `CaregiverPanel` is the single landing screen, reached by the slide-to-unlock from home **or mid-session** (where arriving pauses the session on the spot — the rotation into portrait is the privacy boundary). Rows carry their current value *in the row*, so the usual question is answered without opening anything:

| Section | Rows → screen |
|---|---|
| **OFTEN** | Practice level → `PracticeLevelScreen` · *Take a rest* (mid-session; no screen) · *Right now* → `InSessionStatusScreen` (mid-session) · Phrases → `PhraseLibraryScreen` → `AddPhraseScreen` |
| **THE SESSION** | Session and sensory → `SessionSensoryScreen` · Practice dose → `PracticeDoseScreen` · Progress → `ProgressSummaryScreen` · History → `HistoryScreen` → `InsightsScreen` |
| **SET ONCE** | Hand-tapping tutorial → `TappingTutorialScreen` · Help → `HelpScreen` → `TappingTutorialScreen` · Privacy and sharing → `PrivacyScreen` · Insights → `InsightsScreen` (experimental) |
| **INTERNAL — NOT SHIPPED** *(only when `demo_mode_enabled`)* | Clip QA → `ClipQaScreen` · Library manifest → `LibraryManifestScreen` |

**Caregiver controls expose:** tempo (40–70 BPM), sensory channels (visual/sound/haptic), session length (1–20), recording length (3–8 s), target display (picture/word/both), **playback speed (1×/0.75×/0.5×)**, **the patient's MIT level (I/II/III)** and automatic level advancement on/off, **solo practice on/off (experimental, item 19)**, practice-dose target (minutes a day), add custom phrase (any language), and per-phrase: active toggle (hide/show, incl. **starter words**), probe question, photo add/change/remove; plus the **privacy/consent** toggle. *(The per-phrase rung ◀/▶ control and the comfort cap are gone — there is no per-word level to set. The in-app guide recorder is gone too — clips are authored and shipped.)*

---

## 13. Data model (SQLite, schema v32)

- **user_profiles** — one local profile; all preferences (tempo, channels, session/recording length, consent + timestamp, target_display, playback_speed, auto_progress_enabled, onboarding_seen, demo_mode_enabled, solo_mode_enabled, cloud_profile_id), **mit_level** (v28: the PATIENT's Level I/II/III — the only thing progression carries between sessions), **practice_target_minutes** (v30: the caregiver's dose goal, minutes a day), and the home-screen plant's **plant_stage** + **plant_grown_on** (v32: how grown it is, and the last local day it grew, so a second session the same afternoon can't count twice).
- **practice_phrases** — text, word/syllable counts, complexity_level, guide_clip_path (encrypted reference) + guide_nuclei_ms, photo_path, **probe_question_text/_clip_path** (v21), **stress_index** (high-note syllable for the melody, v22), sprechgesang_clip_path (v25), is_active, **is_starter** (v27; presentation-only).
- **practice_sessions / exercise_attempts** — each production's verdict, latency/duration, tap-sync score, **step_at_attempt** (v28: the `MitStep` index), **tempo_bpm** (v20: beat reference at capture), encrypted audio path (nulled after 48 h), synced_at; plus **practice_sessions.ended_at** (v31: stamped on every attempt save, so practice dose can be measured in minutes a day rather than inferred from the second-to-last attempt).
- **tap_events** (v19, ML logging item 16a) — the **raw per-tap stream**: one row per tap (touch-down time, dwell = press duration, beat phase at touch-down), tied to attempt/phrase/**step**/session. This is the un-aggregated data the fatigue detector needs (dwell trend + inter-tap-interval variance) — the single tap-sync score on the attempt row can't reconstruct it. **Derived non-audio data → never evicted.** Indexed by attempt and by session.
- **acoustic_feature_vectors** — per-attempt gate verdict + DTW similarity, plus (v20) **mfcc_distance** and **onset_ms** (the patient's own detected syllable onsets, CSV). Written for the three clean-capture steps. *(Unison steps open no mic — the model would bleed — so they have a caregiver label + tap stream but no acoustic vector, by design.)*
- **phrase_anchor_templates** — per-(profile,phrase) MFCC reference (derived features, never audio).
- **daily_summary** — per-(profile,day) metrics rollup.

**v28, the MIT revert.** `progression_state` (per-word rung, syllable tier, per-word tempo) is **dropped** — all three concepts are gone. `tap_events.rung` is **rebuilt** as a nullable `step` (the column was `NOT NULL`, so it could not simply stop being written); existing taps are preserved with a NULL step. `exercise_attempts.rung_at_attempt` was **not** reinterpreted as a step — a new `step_at_attempt` column was added instead, because relabelling old rung integers would write wrong data into the very history the level criterion reads. The other dead columns (`practice_phrases.current_rung`, `rung_at_attempt`, `tier_at_attempt`, `user_profiles.session_rung_cap`) are gone from the fresh-install schema and read nowhere, but are **left in place on upgraded databases**: SQLite only learned `DROP COLUMN` in 3.35 and Android ships what it ships.

*(Legacy/unused: `practice_phrases.audio_asset_path`, `exercise_attempts.support_level`, and — on upgraded databases only — the v28 leftovers above.)*

**ML-logging status (audit item 16 — complete):** the raw tap stream (16a, dwell + inter-tap timing), the per-attempt acoustic vector with both DTW similarity and raw MFCC distance (16b), and the patient's own syllable onsets + beat reference (16c) are all captured and kept past the 48 h audio eviction. All are logged data only; **none gates anything** (still caregiver-in-the-loop).

---

## 14. Testing

**429 tests passing** (`flutter test`, +1 skipped), `flutter analyze` clean.

Covering: WAV codec, MFCC, DTW, junk gate, MFCC codec, attempt analyzer/scoring (incl. raw MFCC distance + patient-onset capture), time-stretch, syllable detection, **pitch (F0) detection + intonation-contour analysis** + **reference-melody synthesis**, noise reduction, audio trim, AES crypto, audio eviction; the metronome/beat scheduler (incl. **stale-beat suppression** so a stalled frame never replays overdue ticks), tap-sync. *(The pitch/contour/noise-reduction/trim tests now outlive their production caller — see §5: the libs are retained for owner-side authoring, and their tests are what keeps them honest.)*

**The MIT sequence** (`mit_sequence_test.dart`, `practice_controller_test.dart`): the step tables per level, the **2-of-3 `RepRule`** (two passes stop at two; two fails stop at two; doubt costs a third; three Unsures fail safe), `MitItemRun`'s **immediate back-up** and **set-aside**, `LevelCriterion`, and the controller FSM driving all of it — Level I never opening a mic, Level II's five steps walked in one sitting, Level III's retrieval-only pair, the step→state routing, the unjudged hum step (once per **item**, safety-cap release, skippable), the warm-up's "tapping can never move the sequence" guarantee, the raw tap-stream capture (touch-down + dwell) resetting **per production**, the attempt carrying its **own** step + rep number, the phrase-locked tapping window, and the presenter's step jump leaving no record.

Plus: `step_timing_test.dart` pinning the **six-second** delayed repeat as a protocol constant; repository + anchors + tap_events + probe-question + stress-index; **schema migrations v1→v30**, including a real **v27→v28** test (mit_level added and defaulting to Level II, `progression_state` dropped, old attempts keeping a NULL step rather than a relabelled rung) and the **tap_events rebuild** (every tap preserved, step NULL, cascade + indexes intact); the **starter word library**; **ML scaffolding** — fatigue detector, Wilson-lower-bound graduation gate, Layer C feature assembly + untrained-abstain, scoped-solo policy keyed on the probe step, insights dashboard; the off-thread scoring isolate parity and the eviction-keeps-derived-data guarantee; sync service; analytics/trends + capture analysis + history; **per-screen orientation**; the **practice dose** rollup and the **plant**'s growth/clamp rules; and widget tests (practice view incl. the warm-up tap/hum arenas, the word withheld during the hum, the per-step stage chip, melody cue, slide-to-unlock, session/sensory settings, the tapping tutorial, the level-up offer). `caregiver_panel_test.dart` asserts **every caregiver screen still has a row pointing at it** — the guard that was missing when five screens lost their entry points (see `DEPRECATIONS.md` §7).

**Known test gaps:** **v31 and v32 have no dedicated migration test** (the per-version convention stops at v30) — both are `_addColumnIfMissing` column adds, which is the lowest-risk migration shape, but the convention is otherwise unbroken. The deleted screens took `metronome_screen_test.dart` and `guide_recording_teach_test.dart` (the two-demo melody teaching step) with them; `mit_progression_test.dart`, `progression_test.dart` and `progression_log_sim_test.dart` — 526 lines testing the deleted ladder — went at the v28 revert.

The pure logic (audio DSP, MIT rules, analytics, data layer) is unit-tested. **Device-gated** parts — live mic recording, audio playback/TTS, gallery photo pick, keystore — are verified on a physical device rather than in tests.

---

## 15. Status & honest caveats
- **Verified on device:** the guide audio plays; the core practice loop runs. **Nothing since the MIT fidelity pass is device-verified** — that includes the whole v28 revert, the new home screen/plant, the caregiver panel and every screen imported with it.
- **Built, awaiting device verification:** the full MIT sequence end-to-end (back-up, set-aside, level advancement), gallery photo pick + display, ambient calibration feel, the per-beat syllable illumination on the staff (the beat anchor is exact in code but has never been watched against real audio), the daily-summary cloud push (needs the Supabase `daily_summaries` table created).
- **Known not-yet-done:** the **full piecewise** voice-to-beat warp (each syllable landing exactly on a beat, with beat-synced playback start) — the current alignment matches *average* pacing to the beat; the authored Sprechgesang clips (the fallback voice stands in); real starter-library audio (the bundled `.wav`s are marked placeholders).
- **No cloud surface:** sync + Supabase plumbing is live but **nothing can sign in** since `account_screen.dart` was removed, so the metrics push is dormant (§11). Consent is still recorded and still gates it.
- **Retained-but-uncalled code:** the guide-recording DSP (`pitch_detection`, `intonation_contour`, `noise_reduction`, `audio_trim`) has no production caller now that the in-app recorder is gone (§5). Kept deliberately, with its tests.
