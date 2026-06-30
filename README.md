# AphasiaAid

A mobile app that helps people with non-fluent aphasia rebuild speech after a
stroke, using a melody-and-rhythm-based practice method grounded in established
speech therapy.

I built AphasiaAid for a family member recovering from a stroke. It guides a
user through speaking practice phrases, analyzes their speech in real time using
audio signal processing I implemented from the ground up, and adapts the
difficulty over time based on a caregiver's feedback across sessions.

## What it does

- Guides the user through speech-practice phrases set to a steady rhythm and
  simple melody, the core of the therapy method.
- Analyzes the user's spoken audio in real time: extracts acoustic features
  (MFCCs), detects voiced speech, and aligns the user's timing to the target.
- Adapts difficulty across sessions using a progression system driven by
  caregiver pass/fail feedback.
- Works fully offline (local-first), with optional cloud sync.

## Tech

- Flutter / Dart for the cross-platform mobile app
- Audio signal processing implemented from scratch: MFCC feature extraction,
  voiced-peak detection, timing alignment
- SQLite for local-first storage
- Supabase for optional cloud sync (see Cloud setup below)

## Status

The full system is built and currently in testing ahead of release.

# rhythmic_practice

A new Flutter project.

## Cloud setup (Supabase)

The app is **local-first**: it runs fully offline with no setup. Cloud sync
(metrics only — raw audio never leaves the device) is optional and needs a
Supabase project.

Credentials are supplied at **build time** via `--dart-define`, so they are
never committed to source control. To enable the cloud:

1. Copy the template to the real (gitignored) file:

   ```sh
   cp supabase.example.json supabase.json
   ```

2. Fill in `supabase.json` with the two values from your Supabase project
   (dashboard → **Project Settings → API Keys**):

   - `SUPABASE_URL` — the **Project URL** (e.g. `https://abcdxyz.supabase.co`)
   - `SUPABASE_ANON_KEY` — the **publishable / "anon public"** client key
     (starts with `sb_publishable_`, or the long `anon public` token on older
     projects). **Never** use the `secret` / `service_role` key.

3. Build or run with the file:

   ```sh
   flutter run   --dart-define-from-file=supabase.json
   flutter build apk --release --dart-define-from-file=supabase.json
   ```

`supabase.json` is gitignored and must never be committed. If you omit the
`--dart-define-from-file` flag, the app still builds and runs — it just stays
local-only with the cloud disabled.

> The publishable key is designed to be embedded in client apps; it only grants
> the access the database's row-level-security policies allow (see
> `supabase/migrations/`).

## Getting Started

This project is a starting point for a Flutter application.

A few resources to get you started if this is your first Flutter project:

- [Learn Flutter](https://docs.flutter.dev/get-started/learn-flutter)
- [Write your first Flutter app](https://docs.flutter.dev/get-started/codelab)
- [Flutter learning resources](https://docs.flutter.dev/reference/learning-resources)

For help getting started with Flutter development, view the
[online documentation](https://docs.flutter.dev/), which offers tutorials,
samples, guidance on mobile development, and a full API reference.
