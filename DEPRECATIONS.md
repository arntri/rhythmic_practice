# Deprecations & change tracking

*Running record of what we are removing or changing as the app is brought to MIT
standard, and — the point of this file — **what else depends on each thing**, so
dependants can be deleted in the same sweep instead of rotting in the tree.*

**Rules for this file**
- Nothing is deleted silently. It gets an entry here first.
- Every entry lists its **dependants** — the code that only exists to serve it.
- Status is one of **DONE** (change made), **PENDING** (agreed, not yet built),
  **DEAD** (unreferenced, safe to delete on your word).
- Line counts are a rough weight, to answer "how much does this cost us?"

---

## 1 · Tapping cue: clock-locked → phrase-locked — **DONE** (2026-09-01)

MIT taps the left hand once per syllable, starting and stopping **with the
phrase**. We were cueing a tap on every beat of the session, which turns a
phrase-shaped gesture into a metronome.

**Changed**
- `PracticeController.tappingExpected` — was `state != verdict && != complete`
  (i.e. nearly always true). Now gated on an explicit production window:
  `beginProduction()` / `endProduction()`, closed automatically by any state
  change so a window can never leak past the production that opened it.
- `practice_screen` opens the window on the hum, on the model, and on the mic;
  closes it when the model ends — so the R4 breath and the **six-second R5
  retrieval silence** carry no taps.
- `practice_view._TapCue` copy: "on each beat" → **"on each syllable"**.
  Wrapped in `Flexible` (the longer string overflowed its row by 17 px).

**Dependants** — none removed. `_TapCue` reads `tappingExpected`; that is the
only consumer.

**Knock-on to decide later:** the metronome still ticks continuously underneath.
MIT has **no click track at all** — the tapping hand *is* the pulse. If we follow
that through, the continuous audible tick becomes a deviation in its own right
and `MetronomeEngine`'s sound channel is a candidate for going quiet outside
productions. Not touched yet.

---

## 2 · The progression core: between-block ladder → MIT within-item sequence — **DONE** (2026-09-01)

The largest change on the list, and it is made. A word no longer **sits** at a
rung; every item runs **its level's whole step sequence, every session**, backs
up a step the instant one fails, and is set aside after two failures.

**Built**
- `PracticeController` drives a `MitItemRun` instead of a rung. One list entry =
  one item (the 3-rep block is gone from the session list), `currentStep`
  replaces `currentRung`, and `_finishAttempt` records the verdict into the run
  and re-enters whatever step the run is now on — which is how `again`,
  `passed` and **immediate back-up** all become the same code path.
- `practice_screen` routes audio per **step**; `practice_view` tints, cues,
  labels and asks its verdict question per **step**; `settings_portal` sets the
  **patient's level** instead of per-word rungs *(that portal has since been
  replaced by `CaregiverPanel` → `PracticeLevelScreen` — see §7)*.
- `lib/practice/rung_timing.dart` → **`step_timing.dart`**, keyed on `MitStep`.
- DB **v28** (below). `progression.dart` and `mit_progression.dart` **deleted**,
  with `test/mit_progression_test.dart`, `test/progression_test.dart` and
  `test/progression_log_sim_test.dart` (526 lines of tests for an engine that no
  longer exists).

**Four decisions that departed from the plan above — flagged, not silent**

1. **`rung_at_attempt` was NOT repurposed.** The plan said reinterpret it as the
   step. A new `step_at_attempt` column was added instead, and old rows keep a
   NULL step. Relabelling old rung integers as step indices would have written
   wrong data into the exact history `LevelCriterion` reads — the same reason
   this file already said to *drop* rungs rather than reinterpret them.
2. **The demo picker was retargeted, not deleted.** §2a listed it as dying with
   the rung it picks. It now picks a **step of the current level's sequence**
   (`MitItemRun.jumpTo`, `PracticeController.demoJumpToStep`) — the same
   presenter gesture aimed at the real structure. Deleting a tool you asked for
   because its target was renamed seemed like the wrong trade; say the word and
   it goes.
3. **Dead columns stay on upgraded databases.** `practice_phrases.current_rung`,
   `exercise_attempts.rung_at_attempt` / `.tier_at_attempt` and
   `user_profiles.session_rung_cap` are gone from the fresh-install schema and
   read nowhere, but are left in place on upgrade: SQLite only learned
   `DROP COLUMN` in 3.35 and Android ships what it ships. Rebuilding two tables
   to reclaim four unread columns is a worse trade than leaving them.
   `tap_events` **is** rebuilt, because its column was `NOT NULL` and so could
   not simply stop being written.
4. **The auto-progression toggle survived, retargeted.** §2a listed it as dying.
   It now means "move up **levels** automatically" — the 90% criterion — which is
   the only automatic decision left in the app.

**Also removed, as planned:** park-and-switch (`insertAfterCurrent`,
`appendPhrases`, `isOnLastWord`, `_easiestActiveWord`, `_blockFor`,
`_maxSwitches`) — superseded by MIT's own set-aside; the end-on-success closer;
the session rung cap; `setRung`; `getProgressionState` / `upsertProgressionState`.

**Reshaped, not deleted:** `solo_mode.dart` now measures mastery at
`MitStep.probeQuestion` instead of "rung ≥ R6"; `insights_dashboard.dart` reads
the same; `layer_c_classifier.dart`'s feature vector carries `step` + `level` in
place of `rung`/`tier`.

### 2b · Data model — **DONE** (DB v28)

| Change | Fate |
|---|---|
| `user_profiles.mit_level` | **Added.** 0/1/2 = Level I/II/III, default II. The patient's level — the only thing progression carries between sessions. |
| `exercise_attempts.step_at_attempt` | **Added.** The `MitStep` index. NULL for pre-v28 rows (see decision 1). |
| `progression_state` | **Dropped** (table). |
| `tap_events.rung` | **Rebuilt** → `tap_events.step` (nullable). Every logged tap preserved with a NULL step. |
| `practice_phrases.current_rung` | Gone from the fresh schema; vestigial on upgrades (decision 3). |
| `exercise_attempts.rung_at_attempt` / `.tier_at_attempt` | Same. |
| `user_profiles.session_rung_cap` | Same. |

`sessionPassRates` lost `minRung` and `tier` and gained an optional `step`: MIT's
90% is a criterion for the **person's level**, so the default is every judged
production of a session, not a slice of one word at one rung.

### 2c · R7 is ON

The probe question is now the last step of **both** Level II and Level III, and
the step solo-mode eligibility is measured at. No new code was needed — it had
been fully built and merely excluded.

---

## 3 · Tempo as a support dial — **DONE** (removed)

One caregiver-set session tempo, and it stays there. The per-word tempo, the
60→50→40 lowering on a failed block, `slowedTempo` and `_showTempoEased` all went
with `progression_state`. The 40–70 BPM bound stays — it is a comfort setting.

---

## 4 · Syllable tiers → MIT Levels I/II/III — **DONE**

`levelForSyllableCount`, `maxLevel`, `sprechgesangLevel`, the `sprechgesangSatisfied`
gate and `syllable_tier` are all gone. The patient holds a `MitLevel`; `stepsFor`
gives its sequence; `LevelCriterion` (90% over 10 sessions) moves them up.

**Knock-on — RESOLVED (2026-09-01).** The Sprechgesang clip used to be a *gate*
on the old Level 3, and that gate went with the tiers. But Sprechgesang was never
a **step** in any sequence, which was the real gap: canonical MIT ends by coming
**off** the melody, and leaving that out is the method's known failure mode — a
patient who can produce a phrase only while singing it has generalised nothing.

**Added:** `MitStep.sprechgesang` (same rhythm and tapping, tune dropped, spoken
model) and `MitStep.spokenProduction` (nothing played at all) as the **tail of
Level III**: delayed repeat → probe question → Sprechgesang → spoken production.
Both are judged and both record. The enum values are **appended**, so stored
`step_at_attempt` integers keep their meaning and no migration was needed.
`sprechgesang_clip_path` has a consumer again; with no clip the step falls back to
the built-in voice, so it never blocks. The clip is **owner-authored and shipped**
like every other guide (see [[guide-audio-authored-by-owner]]) — no caregiver
recording UI.

---

## 5 · Single words only → words **and** phrases, graded — **DONE** (2026-09-01)

The seed opened on five active phrases, **four of them one syllable**
(`Help, Pain, More, Stop`). A one-syllable target has no contour to intone — its
hum is a single note — so the default starting set barely engaged the melodic
half of the therapy at all. There was also nothing longer than three syllables
anywhere in the app, which left **Level III with nothing appropriate to
practise**: its delayed repeat and Sprechgesang steps are for established,
sentence-length material.

**Changed**
- The two lists are now **disjoint and graded**. The **starter library** (which
  ships bundled clips) owns the short functional phrases; `AppDatabase.seedPhrases`
  owns what has no clip yet — medium phrases, sentences, and the bare single
  words. A test pins the disjointness.
- **Nothing one-syllable is active by default**, in either list. The single words
  are still shipped, because a caregiver may genuinely want "Stop", but the
  choice is now theirs to make deliberately.
- **DB v29** tops up an existing install with the phrases it was missing.
  Insert-only, matched on exact text, so a caregiver's own words and their
  choices about what is active are untouched.

**Fixed on the way:** `_seed` and the starter library both inserted **"Water"**,
so every fresh install had a duplicate. And the v29 top-up initially wrote
`audio_asset_path`, a fresh-install-only column — it would have crashed the
migration on every real device. Both caught by tests.

**Still placeholder:** the bundled `.wav` clips. The longer phrases have no
authored guide at all and fall back to the built-in voice, which works but does
not sound like the therapy should.

---

## 6 · Already dead — **DELETED** (2026-10-14)

Not part of the MIT work — pre-existing weight found during the audit, cleared on
your word.

| Thing | Lines | Fate |
|---|---:|---|
| `lib/screens/guide_recording_screen.dart` | 632 | **Deleted.** Superseded by your 31 Aug decision that you author all guide audio ([[guide-audio-authored-by-owner]]). |
| `lib/services/guide_recorder.dart` | 132 | **Deleted.** Only consumer was the screen above. |
| `test/guide_recording_teach_test.dart` | — | **Deleted** with it (the two-demo melody teaching step). |
| `practice_phrases.audio_asset_path` | — | Legacy column, never read. Still there. |
| `exercise_attempts.support_level` | — | Legacy column, never read. Still there. |
| `AutoProgression` / `ProgressionService` | — | Already deleted 19 Jun 2026. Listed so the v15 migration comment stays explicable. |
| `lib/practice/karaoke.dart` | — | Already deleted (highlight removed 14 Jun 2026). |

**The predicted knock-on, as written above, is now real.** `syllable_detection`
is still used by attempt scoring (**kept**, as called). But `noise_reduction`,
`audio_trim`, `pitch_detection` and `intonation_contour` have **no production
caller left** — they were the recorder's DSP. They are **kept with their tests**
rather than deleted: they are pure functions, and they are what you would reach
for in an owner-side authoring tool. `intonation_reference` is unaffected —
`hum_melody` still builds the synthesized melody from it.

---

## 7 · Orphaned by the home-screen rewrite — **DELETED** (2026-10-14)

The "Build pass 2026-09-01" replaced the old `HomeScreen` (which had a top-right
menu) with the plant canvas + slide-to-unlock, and replaced `SettingsPortal` with
`CaregiverPanel`. Five screens lost their only entry point in the process and sat
unreachable in the tree — not deprecated, just unlinked. Caught by tracing the
nav graph; **two were rewired, three were cut.**

**Rewired into `CaregiverPanel`**

| Screen | Where it went |
|---|---|
| `history_screen.dart` | **THE SESSION → History.** Per-phrase trends, daily rollup, past sessions — a whole feature area, and the only path to it had vanished. |
| `help_screen.dart` | **SET ONCE → Help.** Also had its copy corrected: it still described the deleted per-word ladder and verdict buttons labelled *Accept/Unsure/Not yet* (they read **Yes/Maybe/Not yet**). |

**Deleted**

| Thing | Lines | Why not rewired |
|---|---:|---|
| `lib/screens/metronome_screen.dart` | — | A standalone metronome is not part of the therapy loop; the session has its own. |
| `lib/screens/account_screen.dart` | — | Cloud sign-in UI. Cut on your word; see the consequence below. |
| `lib/screens/progress_screen.dart` | — | The family-sharing reader (share code, join-with-code). Same call. |
| `lib/services/auth_service.dart` | — | **Dependant.** Only consumers were the two screens above. |
| `lib/services/cloud_sharing.dart` | — | **Dependant.** Same. |
| `test/metronome_screen_test.dart` | — | Went with its screen. |

**Consequence, stated rather than buried:** `SyncService` gates its push on being
signed in, and **nothing in the app can sign in any more**, so the metrics push is
dormant. The plumbing (`cloud.dart`, `sync_service.dart`) and the consent switch
in **Privacy** are untouched, so re-adding a sign-in entry point is all it would
take to make it live. The Privacy row's copy was corrected — it used to read
"Counts and timings, if you sign in", which promised a flow that no longer exists.

---

## 8 · Not deviations, not going anywhere

Listed so nobody deletes them looking for weight: AES-at-rest + 48 h eviction,
consent-gated metrics sync (dormant but intact — §7), photo name cards, ambient
calibration, per-screen orientation, trends/history. None of these are MIT
concerns; all are yours and current. *(Family sharing was on this list and has
been removed — see §7.)*
