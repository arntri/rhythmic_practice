# Rhythmic Practice — Therapy & Design Addendum
> Upload alongside `phase1_build_brief.md`, `phase2a_build_brief.md`,
> `sync_addendum_brief.md`, and `project_addendum_and_status.md`.
> This document ADDS to those and, on the points below, CORRECTS them — where it
> conflicts, this document wins. Everything in `project_addendum_and_status.md`
> not contradicted here still stands (cloud sync, AES, haptics fix, beat-lock
> "lock once then flow", Phase 2A core — all kept).
> Date: 2026-06-08.

---

## 1. CORRECTION — the guide is RECORDED audio, not TTS

The status doc lists Step 4 as "device TTS" with `flutter_tts`. Decision: **the
primary guide is recorded human audio, not synthesized speech.** Reasons: TTS
cannot *chant* on the beat (the whole mechanism is slow intoning, one syllable per
beat), it mispronounces names and non-English words, and a synthetic clip is a poor
comparison reference for the analyzer.

- **Primary path:** each phrase's guide is a recorded clip (family-recorded for the
  starter set; caregiver-recorded for custom phrases), intoned slowly on the beat.
- **TTS demoted to optional fallback** only for a phrase that has no recording yet.
  Do not delete `flutter_tts`, but it is no longer the main path.
- Recorded guide clips double as the **DTW reference** for that phrase, so they MUST
  be saved as **WAV / PCM16 / mono / 16 kHz** — the analyzer's format. (Same fix as
  the `record`-package AAC/m4a gotcha already flagged: force PCM/WAV everywhere audio
  is captured, including caregiver recordings.)

## 2. NEW — caregiver recording flow (guide + onboarding)

Build a flow where the caregiver records a phrase's guide **while the metronome
plays**, so the clip is beat-aligned. Two payoffs:
- The number of beats used = the **syllable count** (no text-based syllable counting
  needed, in any language).
- This same flow is the **onboarding**: first run walks the caregiver through
  recording the starter words in their own language. (At scale there is no developer
  to pre-bundle audio; recording is the front door.)
- Make it onboarding-grade: guided, retry-able, simple. Records to WAV/PCM16/mono/16k.

## 3. NEW — multi-language by design (no transcription)

Because nothing is transcribed, the engine is **language-agnostic**: the on-screen
word can be **any language/any script**; the caregiver records how it actually
sounds; the caregiver judges correctness in their language; DTW compares acoustics.
- Difficulty axes stay language-agnostic: **syllable count** (from beats-at-recording)
  and **caregiver-tagged familiarity**. Do NOT build an articulatory-complexity axis
  (language-specific, needs phonetics we don't have).
- UI must render arbitrary scripts (Unicode) and right-to-left text correctly — test
  it, don't assume.

## 4. NEW — the full MIT progression ladder (the "full cycle")

The app must support the whole MIT cycle, easiest→hardest, not just the final
tap+speak stage. **Difficulty is four independent dials — change ONE at a time.**

Dials: (a) **support/autonomy**, (b) **task demand**, (c) **linguistic load**
(syllables; familiarity), (d) **tempo** (slower = easier).

**The rungs** (support + task combined, the MIT hierarchy):
- R0 — receive the beat; optional tap. No speech.
- R1 — hum / voice to the beat. Sound, no words.
- R2 — intone the word **in unison** with the recorded model.
- R3 — unison with the model **fading** out partway.
- R4 — listen, then **repeat** after the model.
- R5 — listen, pause, then repeat (**delayed**).
- R6 — produce on own (prompt only); tap+speak solo is the top.

**Linguistic tiers:** 1 syllable → 2 → short phrase. Familiarity: automatic/high-
frequency words first; **names are the HARDEST tier** (proper-noun retrieval is
disproportionately hard in aphasia — set caregiver expectations, don't start there).

**The grid rule:** support and syllables are a 2D grid. Climb the support rungs at a
given syllable tier; when you raise syllable count, **reset support back to high
(unison)**. Never raise linguistic load and drop support in the same move.

**Build now vs later:**
- **NOW (buildable, no capture needed):** the rungs as selectable states + a per-user,
  per-phrase **progression-state record** (current syllable tier, current rung, recent
  success history). The **caregiver manually sets the rung** (and can ease/regress).
- **LATER (Phase 3):** the auto-progression engine. It advances on **consistent**
  caregiver-confirmed success (e.g. k of last m passes), **regresses quickly** on
  sustained failure (repeated failure can entrench errors), is **rules-based and
  transparent**, and the ML model **does not gate progression until it has graduated**
  — early progression runs on caregiver labels + simple rules only.
- Bias toward **success (errorless-leaning)** early, especially given severity, but
  **fade support deliberately** so it doesn't become a sing-along (prompt dependency).

## 5. NEW — therapy-fidelity decisions to fold into Steps 4/5

- **Mute the audible metronome tick during the capture phase** (keep haptic + visual)
  so the tick isn't recorded.
- **Per-session 2-second ambient calibration** at session start sets the silence /
  noise-floor threshold (we chose this over spectral subtraction). Used for
  silence-close, latency, and duration.
- **Tapping is decoupled from the beat cues and is optional.** The user always
  *receives* the beat (sound/visual/haptic); producing taps is itself a rung element,
  not a mandatory simultaneous demand during capture. The caregiver may physically
  tap the user's hand (hand-over-hand). (The "lock once, then flow" change already
  reduced tap burden — consistent with this.)
- **Tempo control is bounded:** caregiver BPM dial limited to **~40–70 BPM**, default
  60, and **one beat = one syllable**. Slowing down is a *support* move, not a failure.
  Do not allow the dial to reach conversational speed (it erases the slow-rate
  mechanism).
- **Sensory channels independently toggleable** (already tri-sensory). Distinguish two
  overload types: **input overload** → channel toggles; **motor overload** → optional
  tapping. A sensitive user may run on one channel only.

## 6. NEW — names + photo cards (Phase 2B)

Personally meaningful targets (family members' names) are high-value but the **hardest
tier**. Support **photo + recorded-name cards**: caregiver adds a photo (stored
local + AES-encrypted, like clips) and records the name. Place names in the top
difficulty tier; set expectation that they come last.

## 7. STANDING NOTES (deferred, do not act now)

- **Regulatory is deferred to pre-launch**, but neutral naming is for *positioning
  flexibility only* — it does NOT make the app not-a-medical-device. Don't treat
  compliance as solved by renaming.
- **Efficacy honesty:** MIT is modestly effective, mostly on practiced items, and the
  app form is unproven; component value (tapping, tempo, channels) varies per person.
  This is *why* every component is optional and measured — the app is a practice aid
  alongside real therapy, not a treatment.

## 8. SEQUENCING (unchanged intent)

1. On-device verify Steps 4 & 5 (now with the recorded-guide correction in mind).
2. Phase 2B — wire analyzer onto captured clips (confirm PCM/WAV); anchor promotion.
3. Build the **progression rungs + progression-state data model** (caregiver-paced).
4. Sync wiring (per sync addendum).
5. Phase 3 — the auto-progression engine.
6. UI/UX overhaul (Part A §7 of the status doc) last.
