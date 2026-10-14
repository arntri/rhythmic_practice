# AphasiaAid

**A caregiver-assisted speech-practice app for people recovering from
non-fluent aphasia after a stroke, built on Melodic Intonation Therapy.**

[![CI](https://github.com/arntri/rhythmic_practice/actions/workflows/ci.yml/badge.svg)](https://github.com/arntri/rhythmic_practice/actions/workflows/ci.yml)

Flutter · Dart · SQLite · from-scratch audio DSP · 429 passing tests

---

I built this for a family member recovering from a stroke.

Non-fluent aphasia leaves people unable to produce speech they can often still
*sing*. Melodic Intonation Therapy (MIT) exploits that: the patient intones
short phrases slowly, on a steady beat, while the clinician taps their left hand
once per syllable and withdraws support step by step until the phrase can be
spoken alone. It is one of the few aphasia therapies with real evidence behind
it, and it is delivered by a clinician, intensively, for months.

AphasiaAid puts that protocol in the hands of a family member sitting beside the
patient. The app is the clinician's *structure.* The beat, the melody, the step
sequence, the record of what happened. The caregiver remains the one who judges
every attempt.

## What it does

- **Runs MIT's actual step sequence.** Each phrase goes through the whole
  sequence for the patient's level in one sitting. Hum the melody, intone in
  unison, carry it as the model fades, repeat after a delay, answer a question
  with it, then speak it without the tune. A failed step backs up to an easier
  one *immediately*; two failures set the phrase aside for the day.
- **Keeps both of MIT's active ingredients.** The melody *and* the rhythmic hand
  tapping — the app cues the caregiver to tap the patient's left hand once per
  syllable through every production, and never gates anything on how well they do it.
- **Measures the speech without judging it.** Every solo production is recorded,
  scored against the guide clip (MFCC + DTW), and shown as a trend. The score
  **never** decides anything; see [Where the judgement lives](#where-the-judgement-lives).
- **Adapts at the level of the person, not the word.** Clearing 90% of judged
  productions across ten sessions *offers* the caregiver a move up to a longer
  step sequence, which they can decline.
- **Works fully offline.** Raw audio is AES-encrypted on the device and deleted
  after 48 hours. Only anonymous counts can ever sync, and only with consent.

## Where the judgement lives

The most consequential decision in this codebase is a refusal.

The app extracts real acoustic features and computes a real similarity score for
every attempt. It would be easy — and would demo well — to let that score decide
whether the patient passes a step. It does not, anywhere. Progression is driven
**only** by the caregiver's Yes / Maybe / Not yet.

That constraint is enforced structurally rather than by good intentions. The
machine-learning layer (`lib/ml/`) is built end to end — feature assembly,
classifier interface, a fatigue detector that genuinely runs — but the shipped
classifier always abstains, and it may only ever be trusted after clearing a
**Wilson score lower bound on precision ≥ 0.90** against held-out caregiver
labels. Nothing is trained, so it abstains, so the gate never opens, so the
caregiver stays in charge by construction rather than by policy.

A wrong "correct" told to someone relearning their own name is not a rounding
error, and an untrained model is not entitled to that call.

## Engineering highlights

| | |
|---|---|
| **Audio DSP, from scratch** | WAV codec, pre-emphasis → 25 ms Hamming frames → 512-point FFT → 26 mel filters → DCT-II → 13 MFCCs; Euclidean DTW for similarity; autocorrelation F0 detection; WSOLA pitch-preserving time-stretch; spectral-subtraction noise reduction; RMS-envelope syllable-nucleus detection. No ML libraries, no cloud inference — pure Dart, so it is device-independent and unit-testable. |
| **Drift-free beat scheduling** | Each beat is a fixed point on an absolute timeline, so error never accumulates. Overdue beats after a stalled frame are *counted but not replayed* — without that, a stall dumped six ticks into one frame and was audible on-device as a stutter. |
| **Off-thread scoring** | Decrypting and scoring two multi-second clips on the UI thread starved the metronome's `Ticker` and made the beat limp at the exact moment the caregiver was judging. The whole path now runs in a background isolate; only the keystore lookup stays on the root isolate, and the key travels into the worker. |
| **Local-first data** | SQLite at **schema v32**, with every migration written as an idempotent step and the chain tested from v1 forward. AES-256-CBC at rest with the key in the OS keystore; a 48-hour eviction sweep that deletes raw audio but provably keeps every derived measurement. |
| **Tests as the spec** | 429 tests. The DSP is pinned numerically, the therapy rules are pinned as rules (two passes stop at two; three "maybe"s fail safe), and the migration chain is exercised against real pre-upgrade databases rather than mocks. |

## Architecture

```
lib/
  analysis/    WAV codec, MFCC, DTW, pitch detection, junk gate
  practice/    the therapy model: MIT step sequences, rep rules, level
               criterion, the beat-driven session state machine
  metronome/   drift-free beat scheduler; sound/visual/haptic channels
  services/    guide playback, mic capture, scoring, crypto, eviction, sync
  analytics/   trends, practice dose  (display only — never feeds progression)
  ml/          scaffolding, deliberately not in the loop
  data/        SQLite schema, migrations, repository
  screens/     patient surface (landscape) + caregiver panel (portrait)
```

The patient's surface is **landscape** — a propped tablet, hands free. Every
caregiver page is **portrait**, a phone held upright; rotating into it pauses the
session on the spot, which makes the orientation change a real privacy boundary
rather than a layout preference.

**Deeper reading:** [`APP_OVERVIEW.md`](APP_OVERVIEW.md) documents what the app
does now, derived from the source and the passing tests rather than from intent.
[`DEPRECATIONS.md`](DEPRECATIONS.md) records what was removed and why — including
the largest change in the project's history, replacing a between-session
difficulty ladder with MIT's actual within-session sequence, and the reasoning
for each place the implementation departed from the plan.

## Running it

```sh
flutter pub get
flutter test        # 429 tests, no device needed
flutter analyze
flutter run         # local-only; no setup required
```

Built against Flutter 3.44 (stable) / Dart SDK `^3.12.1`.

<details>
<summary><strong>Optional: cloud sync setup (Supabase)</strong></summary>

The app is local-first and needs none of this. Sync pushes **metrics only** —
never audio, photos, guide clips or keys.

Credentials are supplied at **build time** via `--dart-define`, so they are never
committed. To enable it:

1. Copy the template to the real (gitignored) file:

   ```sh
   cp supabase.example.json supabase.json
   ```

2. Fill in `supabase.json` from your Supabase project (dashboard → **Project
   Settings → API Keys**):

   - `SUPABASE_URL` — the **Project URL** (e.g. `https://abcdxyz.supabase.co`)
   - `SUPABASE_ANON_KEY` — the **publishable / "anon public"** client key
     (starts with `sb_publishable_`, or the long `anon public` token on older
     projects). **Never** the `secret` / `service_role` key.

3. Build or run with the file:

   ```sh
   flutter run --dart-define-from-file=supabase.json
   flutter build apk --release --dart-define-from-file=supabase.json
   ```

Omit the flag and the app still builds and runs — it just stays local-only. The
publishable key is designed to be embedded in client apps; it grants only what
the row-level-security policies in `supabase/migrations/` allow.

**Note:** the sync plumbing is intact but currently has no sign-in surface, so
the push is dormant. See `DEPRECATIONS.md` §7.

</details>

## Status

The system is built and in testing. Being honest about what that means:

- **Verified on a physical device:** guide audio playback and the core practice
  loop.
- **Built and unit-tested, not yet device-verified:** the full step sequence
  end-to-end, the new caregiver panel, the per-beat syllable cue, photo name
  cards. Device-gated paths (live mic, playback, keystore, gallery) are
  necessarily verified by hand rather than in tests.
- **Known gaps:** guide audio for the longer phrases is not yet authored, so
  those phrases fall back to the device's built-in voice — it works, but it does
  not sound like the therapy should. The per-syllable voice-to-beat warp
  currently matches *average* pacing rather than placing each syllable exactly.

`APP_OVERVIEW.md` §15 keeps the full caveat list, and it is deliberately
pessimistic.

## A note on scope

This is **not a medical device** and not a replacement for a speech-language
pathologist. It is a practice tool for use alongside real therapy, built for one
family's situation and shared because the engineering may be useful to others.

## Development

Claude Code was used during development for syntax-level coding assistance —
writing and refactoring Dart against decisions already made. The therapy model,
the architecture, the progression logic, and every design and clinical-fidelity
decision in this project are my own, and are documented with their reasoning in
`APP_OVERVIEW.md` and `DEPRECATIONS.md`.

## License

[MIT](LICENSE).
