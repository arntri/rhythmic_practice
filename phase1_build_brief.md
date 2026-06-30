# Phase 1 Build Brief — Rhythmic Practice App (Flutter)

> Paste this whole document in as the project brief. It is self-contained.
> The person you are helping is a **beginner who does not know Dart or Flutter**. Favor clear,
> well-commented, simple code. Build in **small runnable increments** — the app should compile
> and run after each step. Avoid premature abstraction and clever patterns. Explain what you do.

---

## 1. What this is

A **rhythm-paced speaking-practice app** for an adult who has lost fluent speech after a stroke.
The user knows what they want to say but struggles to produce words; a steady beat and a spoken
model help the words come out. A **caregiver** sits with them and judges whether each attempt was
correct.

**This build is a personal-use prototype for one family member. It is local-only and offline.
It is NOT a medical product and makes NO treatment or recovery claims.** Do not add analytics,
crash reporting, cloud sync, ads, accounts, or any network calls. Everything stays on the device.

**Stack:** Flutter + Dart, targeting both iOS and Android, local-only.

**Naming rule:** Use neutral, non-clinical names everywhere (code, tables, UI text). Use
*practice, exercise, attempt, session, user, profile*. Do NOT use *therapy, treatment, patient,
diagnosis, aphasia, stroke* in code identifiers or user-facing text.

---

## 2. Phase 1 scope

Phase 1 is the **core practice loop with a human judging correctness**. No machine learning, no
speech scoring, no mouth animation, no custom phrases.

### In scope
1. Landscape-locked, hands-free UI with a **tap-anywhere base layer** (no small buttons for the user).
2. A **tri-sensory metronome**: visual pulse + sound + haptic, each **independently toggleable**,
   slow default tempo (60 BPM).
3. One phrase shown at a time, large and high-contrast, from a small built-in word list.
4. An **audio guide** that plays (intones) the phrase on the beat — single fixed support level.
5. **Microphone capture**: opens automatically, closes after ~4.5 seconds of silence, saves the clip.
6. A **caregiver control**: three choices — Pass / Fail / Unsure — in an isolated screen zone.
7. A **slide-to-unlock caregiver portal** with only these settings: which phrases are active,
   tempo (BPM), which sensory channels are on, and session length (number of phrases).
8. **Local SQLite** logging of every attempt: latency, duration, tap-sync score, and the
   caregiver's label.
9. **Privacy basics**: encrypted local storage, raw audio auto-deleted after 48 hours, a consent
   field stub.

### Explicitly OUT of scope (do NOT build these in Phase 1)
- Any speech scoring, DTW, MFCC, content-similarity, or audio analysis beyond simple
  silence/amplitude detection for the mic.
- Any machine-learning model, prediction, automation, or "graduation" logic.
- Mouth / lip / viseme animation.
- Custom phrase entry or automatic syllable counting.
- Batch-review screen.
- Cloud, accounts, analytics, networking of any kind.

---

## 3. The practice loop (finite state machine)

Four states per phrase, advancing automatically. Use these exact neutral state names:

```
[State_1: Preparation] -> [State_2: Reference_Prompt] -> [State_3: Input_Capture] -> [State_4: System_Transition]
```

- **State_1: Preparation** — The metronome runs. The user taps anywhere on screen, with one hand,
  to lock into the beat. After a few taps in time, advance. No phrase text shown yet.
- **State_2: Reference_Prompt** — The app plays the audio guide intoning the phrase on the beat,
  while the metronome continues and the phrase text is shown large on screen.
- **State_3: Input_Capture** — The audio guide stops. The microphone opens automatically on the
  next beat (show a calm visual cue, e.g. a soft green glow, that recording is live). The user
  says the phrase along to the beat. Close the mic after ~4.5 seconds of silence.
- **State_4: System_Transition** — Save the attempt to the database. Wait for the caregiver's
  Pass / Fail / Unsure tap (see §5). Then slide to the next phrase, or end the session if the
  session phrase limit is reached.

---

## 4. The tri-sensory metronome (the hardest part — do this carefully)

Three beat cues that should feel simultaneous:
- **Visual:** a soft ring that expands/contracts, peaking exactly on the beat.
- **Sound:** a short, dry, soft percussive "tick" (woodblock-style). Pre-load the audio clip at
  startup so the first play isn't delayed. No harsh/high-pitched sounds.
- **Haptic:** a short vibration pulse on the beat.

**Each channel must be independently switchable** (some users tolerate only one channel — sensory
overload is a real concern). Default tempo 60 BPM, adjustable.

### Critical technical guidance
- **Do NOT drive the beat with a naive periodic `Timer`** — it drifts and stutters. Instead,
  compute absolute beat timestamps from a monotonic clock (`Stopwatch`) and schedule each beat
  against that, correcting for drift each tick. A `Ticker` running faster than the beat, firing
  cues when the next scheduled beat time is reached, works well.
- Fire the visual and haptic cues off the **scheduled beat time**, not off the audio playback
  callback (audio has variable latency).
- Audio/haptic timing is wrong on emulators — **test the metronome on a real physical device.**
- Perfect millisecond sync is unnecessary; humans perceive cues within ~40–80 ms as simultaneous.
  Aim for "feels locked together," not literal zero jitter.

---

## 5. Caregiver control & portal

- During a session, after each attempt, the caregiver taps one of three: **Pass / Fail / Unsure**.
  Store as `evaluation_label`: 0 = Fail, 1 = Pass, 2 = Unsure (default 2 if unanswered).
- This control lives in an **isolated zone** (e.g. a corner dock) so the user can't trigger it by
  tapping the base layer.
- The **settings portal** opens with a deliberate **slide-to-unlock** gesture (ignore plain taps),
  so the user can't open it accidentally. Portal settings for Phase 1:
  - Toggle which built-in phrases are active.
  - Tempo (BPM).
  - Which sensory channels are enabled (visual / sound / haptic).
  - Session length (number of phrases per session).

---

## 6. Local data — SQLite schema (Phase 1 subset)

Use a local SQLite database. Prefer encrypted-at-rest if straightforward (e.g. an SQLCipher-backed
SQLite); otherwise plain SQLite is acceptable for this personal prototype, but still encrypt the
raw audio files on disk. Keep a thin, readable data-access layer.

```sql
CREATE TABLE user_profiles (
  profile_id              TEXT PRIMARY KEY NOT NULL,
  created_at              TEXT DEFAULT CURRENT_TIMESTAMP,
  metronome_bpm           INTEGER DEFAULT 60,
  preferred_hand          TEXT CHECK(preferred_hand IN ('LEFT','RIGHT')) DEFAULT 'LEFT',
  visual_enabled          INTEGER CHECK(visual_enabled IN (0,1)) DEFAULT 1,
  sound_enabled           INTEGER CHECK(sound_enabled IN (0,1)) DEFAULT 1,
  haptic_enabled          INTEGER CHECK(haptic_enabled IN (0,1)) DEFAULT 1,
  session_phrase_limit    INTEGER DEFAULT 10,
  guardian_consent_granted INTEGER CHECK(guardian_consent_granted IN (0,1)) DEFAULT 0,
  consent_timestamp       TEXT,
  consent_schema_version  TEXT
);

CREATE TABLE practice_phrases (
  phrase_id        INTEGER PRIMARY KEY AUTOINCREMENT,
  phrase_text      TEXT NOT NULL,
  word_count       INTEGER NOT NULL,
  syllable_count   INTEGER NOT NULL,
  complexity_level INTEGER NOT NULL,         -- 1=single syllable, 2=two-syllable, 3=short phrase
  audio_asset_path TEXT,                      -- bundled intoned clip for the guide
  is_active        INTEGER CHECK(is_active IN (0,1)) DEFAULT 1
);

CREATE TABLE practice_sessions (
  session_id  TEXT PRIMARY KEY NOT NULL,
  profile_id  TEXT NOT NULL,
  started_at  TEXT DEFAULT CURRENT_TIMESTAMP,
  FOREIGN KEY (profile_id) REFERENCES user_profiles(profile_id) ON DELETE CASCADE
);

CREATE TABLE exercise_attempts (
  attempt_id                  TEXT PRIMARY KEY NOT NULL,
  session_id                  TEXT NOT NULL,
  phrase_id                   INTEGER NOT NULL,
  timestamp                   TEXT DEFAULT CURRENT_TIMESTAMP,
  latency_ms                  INTEGER,         -- gap from guide-end to first vocalization
  duration_ms                 INTEGER,         -- length of the user's vocalization
  tapping_synchronization_score REAL,          -- 0.0..1.0, computed from tap vs beat times
  evaluation_label            INTEGER CHECK(evaluation_label IN (0,1,2)) DEFAULT 2,
  local_encrypted_audio_path  TEXT DEFAULT NULL, -- wiped by the 48h eviction job
  FOREIGN KEY (session_id) REFERENCES practice_sessions(session_id) ON DELETE CASCADE,
  FOREIGN KEY (phrase_id)  REFERENCES practice_phrases(phrase_id)
);
```

> Tables deferred to later phases (do NOT create now): `acoustic_feature_vectors`,
> `phrase_anchor_templates`, `model_state`. The schema above is forward-compatible with them.

### Derived values (Phase 1 — pure arithmetic, no ML)
- `tapping_synchronization_score`: for each tap during a phrase, find the offset to the nearest
  scheduled beat; average the absolute offsets and map to a 0–1 score (smaller offset = higher
  score). Store per attempt.
- `latency_ms` / `duration_ms`: from simple microphone amplitude thresholding during Input_Capture.

### Privacy
- Raw audio clips live only in a local, encrypted, sandboxed cache.
- A background eviction routine deletes any audio file **48 hours after recording** (or immediately
  after a future review step) and sets `local_encrypted_audio_path` to NULL. Keep the row and its
  numeric fields.
- No data leaves the device.

---

## 7. Starter built-in word list

Seed `practice_phrases` with these (set syllable_count and complexity_level accordingly):

- **Level 1 (single syllable):** Help, Pain, More, Stop, Water
- **Level 2 (two syllables):** Bathroom, Hungry, Medicine, Sleepy, Thank you
- **Level 3 (short phrases):** I want food, Sit down, I love you

You'll need a bundled intoned audio clip per phrase for the guide. For the first build you may use
the device text-to-speech to generate the guide on the fly if recording clips is not yet practical;
note this as a temporary stand-in.

---

## 8. Suggested build order

Build and run after each step. (Verify current package versions when you add them — names below
are common choices, not pinned versions.)

1. **Project + DB.** Flutter project; lock to landscape; create the SQLite schema and a simple
   data-access layer; seed the starter word list. (SQLite via `sqflite`, or `sqflite_sqlcipher`
   for encryption.)
2. **Metronome engine.** Drift-corrected beat scheduler. Get the **sound** channel solid first,
   then add **visual** ring, then **haptic** — each behind its own on/off flag. Test on a real
   device.
3. **FSM.** Wire State_1 → State_4 with automatic transitions.
4. **Phrase display + guide.** Show the phrase; play the intoned guide on the beat in
   Reference_Prompt. (Playback via `just_audio` or `audioplayers`; haptics via Flutter's
   `HapticFeedback` or a vibration package.)
5. **Mic capture.** Auto-open in Input_Capture, amplitude-based silence detection, auto-close
   after ~4.5 s, save encrypted clip, record latency/duration. (Recording via `record` or
   `flutter_sound`.)
6. **Tap layer + sync score.** Full-screen tap listener under the visual layer; compute and store
   `tapping_synchronization_score`.
7. **Caregiver control + portal.** Pass/Fail/Unsure dock; slide-to-unlock settings (active phrases,
   BPM, channel toggles, session length).
8. **Eviction job.** 48-hour audio cleanup that nulls the path and keeps the row.

When all eight run on a real device, Phase 1 is done: the user can practice the word list to an
adjustable beat, speak each phrase, and the caregiver can mark each attempt — all logged locally.

---

## 9. Working style for this project
- Keep it simple and readable; comment generously; the maintainer is learning Dart.
- One runnable increment at a time; don't scaffold everything at once.
- No networking, no third-party analytics, no cloud — ever, in this phase.
- Flag anything that needs a real device to test (metronome timing, haptics, mic).
