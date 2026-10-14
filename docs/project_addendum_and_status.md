# Rhythmic Practice — Decisions Beyond the Briefs + Project Status

> Upload alongside `phase1_build_brief.md` and `phase2a_build_brief.md`. Where this
> document conflicts with those briefs, **this document wins** — it records the
> deliberate, user-confirmed changes made since they were written.
> **NOTE:** `therapy_design_addendum.md` further supersedes this document on the
> points it covers — most importantly: the practice guide is **recorded human audio,
> not TTS** (TTS is now only a fallback). This file has been updated to match.
> Last updated: 2026-06-08.

---

## PART A — Everything decided outside the original briefs

### 1. Cloud-sync pivot (2026-06-05) — overrides "local-only, no networking"
The briefs mandated a local-only, offline app with no networking "ever." That was
**deliberately reversed**: the app is now **local-first with one sanctioned network
feature — one-way, audio-free progress sync to Supabase** so remote family can view
practice progress (the on-site caregiver is non-technical; manual sharing won't happen).

- Local SQLite stays the **single source of truth**; the live practice loop always
  works fully offline.
- **Only metrics sync** (timings, sync scores, pass/fail labels, phrase text/level).
- **Raw audio NEVER leaves the device.**
- The `supabase/` folder and `supabase_flutter` dependency are **intentional and
  required** (≈10 files in `lib/` use them) — not dead code, do not remove.
- Cloud feature (auth, schema+RLS, sync, family sharing via share codes) was built and
  verified end-to-end in steps 2a–2e.

### 2. Sync hard invariants (from the sync addendum) — these are bugs if violated
1. **No audio ever leaves the device** — no clip, no MFCC blob, no waveform. Sync
   payloads are scalar/text only.
2. **One-way only: device → cloud.** Supabase is a read-only mirror for dashboards.
   No cloud→device merge into local SQLite. (The in-app family *viewer* reads cloud
   data for display only — it is never written back into the local DB.)
3. **The app never needs the cloud.** Sync is queued locally and retried in the
   background; network down / project paused / auth expired must never affect a
   practice session. A full session in airplane mode must behave identically.
4. **Sync is silent** — no sync UI, spinners, or error dialogs in the practice flow.
   At most a "last synced" line in the caregiver portal.
- **Supabase config:** Row-Level Security ON for every table; family-scoped by
  membership (no public/anon read). The app ships only the *publishable* client key.
- **Sequencing:** full sync wiring lands **after Phase 2B** (little to sync until
  capture works).

### 3. Phase 2A added — on-device speech analysis (was out of Phase-1 scope)
The briefs put DTW/MFCC/audio analysis explicitly out of scope; a later **Phase 2A**
adds a device-independent **WAV → MFCC → DTW** analysis core (built and tested). Local
DB bumped to **schema v3**. Dependency: `fftea`.

### 4. Beat-lock UX change (2026-06-08) — overrides brief §3 per-phrase Preparation
The brief had the user tap "in time" to lock into the beat before **every** phrase. We
had implemented this as a hard skill gate (3 accurately-timed taps, re-cleared before
every word), which was too hard for the target user. **New behaviour, confirmed:
"lock once, then flow"** — Preparation runs **once at session start** (gentle 2-tap
gate with a wider timing tolerance); after each caregiver verdict the next phrase goes
straight to the word, no re-tapping. Tap-sync scoring is unaffected (all taps during a
phrase still count). **DONE + tested.**

### 5. Audio-at-rest = real AES encryption (user-chosen)
Voice clips are saved with **AES-256 encryption**, key generated once and kept in the
OS keystore (`flutter_secure_storage`); plaintext temp is deleted after encryption.
Clips are still auto-deleted after 48 h. (Rationale: health-adjacent data about a
vulnerable adult.) **Built + roundtrip-tested.**

### 6. Metronome haptics fix
`HapticFeedback.mediumImpact()` was too weak / silently ignored on Samsung. Replaced
with the `vibration` package firing a **35 ms full-amplitude pulse** on each beat.
**Confirmed working on the Galaxy M36.**

### 7. UI/UX overhaul — agreed direction (DEFERRED until all functional steps are done)
The current boot screen is a leftover dev scaffold (`DatabaseCheckScreen`, labelled
"temporary"); the real home was never built. Agreed redesign:
- Real home: full-screen calm **lavender**, big **"tap anywhere to start"** → straight
  into practice.
- A **short swipe control, top-right corner**, holding the other destinations
  (metronome / progress & family sharing / history & insights) **and** caregiver
  settings. Replaces today's 4 buttons.
- Remove the dev clutter (seeded-phrase list + profile readout).
- Soothing lavender throughout; the **whole screen gently pulses** with the beat (not
  just the ring).
- During practice, make the **recording phase's background shift clearly visible**
  (it's currently a barely-visible 12%-opacity green).
- **First-run caregiver instructions** page + a persistent **"i" icon, top-left**, to
  reopen anytime — covering both **how to use it** (how to tap; the ~4.5 s capture
  window; *don't speak twice in that window*) **and how the app helps people**.
- **Open bug:** a pixel-overflow ("RIGHT/BOTTOM OVERFLOWED BY …") on some screen —
  exact screen + banner text still to be captured.

### 8. Working sequence (agreed)
Build all **functional** steps first → **then** the UI/UX overhaul.

### 9. Environment & gotchas
- Dev machine is **Linux**; the desktop GUI can't run the audio stack (GStreamer), so
  verify via `flutter test` + sensory checks on the physical **Android device (Galaxy
  M36, Android 16)**. The USB/adb connection has been dropping intermittently.
- **Test gotcha:** a metronome audio leak can hang `runAsync` across tests — never
  overlap test runs. Current baseline: **102 passing, 1 skipped.**

---

## PART B — Current project status (2026-06-08)

### Phase 1 build steps
| Step | Description | Status |
|------|-------------|--------|
| 1 | Project + local SQLite schema/seed | ✅ done, tested |
| 2 | Tri-sensory metronome (sound/visual/haptic) | ✅ done, tested; haptics fixed + confirmed on device |
| 3 | FSM practice loop | ✅ done, tested (+ "lock once, then flow") |
| 4 | Audio guide — **recorded human audio** (primary), TTS fallback | ⚠️ partial — TTS fallback built; **recorded-guide path + caregiver recording flow not built yet** (therapy addendum §1–§2) |
| 5 | Mic capture (silence-close, latency/duration, AES clip) | ✅ code-complete — logic tested; ⏳ live mic/permission/encryption verify pending |
| 6 | Tap layer + sync score | ✅ done, tested |
| 7 | Caregiver dock + slide-to-unlock portal (+ consent toggle) | ✅ done, tested |
| 8 | 48 h audio eviction | ✅ done, tested |

### Cloud (sync) sub-steps
2a client init, 2b schema + RLS, 2c auth, 2d local sync + push, 2e family sharing —
**all done and verified earlier** (live REST+RLS path tested). In-app sync trigger
points still want one real-device confirm.

### What's verified vs. device-gated right now
- **Verified on the dev machine (102 tests green, analyze clean):** beat-lock logic,
  silence/latency/duration math, AES encrypt↔decrypt roundtrip, silence-driven early
  close, plus all prior tests.
- **Cannot be confirmed without the phone:** live mic recording, the permission prompt,
  real-clip encryption on disk, TTS actually speaking, and any end-to-end practice run
  with audio.

### Alignment fixes already applied (therapy addendum §1, §5) — 2026-06-08
- ✅ Capture is now **WAV/PCM/mono/16 kHz** (`RecordConfig` set; was AAC/m4a default).
- ✅ Tempo slider **capped 40–70 BPM** (was 40–120).
- ✅ **Audible tick muted during the capture phase** (haptic + visual continue) so the
  metronome isn't recorded.
- Still to do for therapy-fidelity: **per-session 2 s ambient calibration** for the
  silence threshold (`CaptureTracker` currently uses a fixed −40 dB).

### Remaining functional work (sequence per therapy addendum §8)
1. **On-device verify Steps 4 & 5** — needs a stable USB connection; rebuild with
   `flutter run` (new native plugins need a full rebuild, not hot reload).
2. **Caregiver recording flow + onboarding** (therapy addendum §2) — record each guide
   clip while the metronome plays (beats = syllable count); WAV/PCM/mono/16k. This is
   now foundational: it produces the recorded guides AND the DTW references.
3. **Phase 2B** — wire the MFCC/DTW core onto captured clips (PCM/WAV) + anchor
   promotion; plus photo + recorded-name cards (AES-encrypted), names = hardest tier.
4. **Progression rungs + progression-state data model** (R0–R6, caregiver-paced).
5. **Sync wiring** — push the new metrics per the sync addendum.
6. **Phase 3** — auto-progression engine (rules-based; ML doesn't gate until graduated).
7. **Then:** the full UI/UX overhaul (Part A §7).

### Dependencies in use
`supabase_flutter`, `audioplayers`, `sqflite` + `sqflite_common_ffi`, `path` /
`path_provider`, `uuid`, `fftea`, **`vibration`**, **`flutter_tts`**, **`record`**,
**`encrypt`**, **`flutter_secure_storage`**.

### Immediate next decision
Either **(a)** stabilize the device and verify Steps 4 & 5 live (also lets us pull usage
records), or **(b)** push on into Phase 2B while the phone is down (wiring built +
unit-tested, but no audio path confirmable until the device is back).
