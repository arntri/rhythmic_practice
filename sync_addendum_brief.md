# Addendum: Progress Sync (Supabase) — Reconciliation & Constraints

> Paste into the `rhythmic_practice` project. This addendum
> AMENDS `phase1_build_brief.md` and `phase2a_build_brief.md`, which mandated
> "no networking of any kind." That mandate is replaced by the following:
> **local-first, with exactly one sanctioned network feature: one-way,
> audio-free progress sync to Supabase** so remote family can view practice
> progress. Everything else about the local-first design stands.

## Why this exists
The on-site caregiver is non-technical; manual "share a report" flows will not
happen in practice. Automatic background sync gives remote family visibility
with zero caregiver effort. This was a deliberate, user-confirmed decision
(project memory: cloud-sync-pivot).

## Hard invariants (violations are bugs, write tests for them)
1. **No audio ever leaves the device.** No file from the encrypted audio cache,
   no anchor MFCC blobs, no photos, no raw waveform data of any kind is ever
   uploaded. Sync payloads are scalar/text fields only. Add a test or lint-level
   guard ensuring no sync code path reads from the audio cache directory or the
   `mfcc_frames` / `local_encrypted_audio_path` columns.
2. **One-way only: device → cloud.** The phone's SQLite is the sole source of
   truth; Supabase is a read-only mirror for dashboards. No data ever flows
   cloud → device. No merge/conflict logic may exist.
3. **The app never needs the cloud.** Sync is queued locally and retried in the
   background with backoff. Network down, Supabase project paused or deleted,
   auth expired — none of it may affect a practice session in any way.
   Acceptance test: full session in airplane mode behaves identically to online.
4. **Sync is silent.** No sync UI in the practice flow, no spinners, no error
   dialogs to the user or caregiver. At most a "last synced" line inside the
   caregiver portal.

## What syncs (whitelist — anything not listed does not sync)
- `practice_sessions`: session_id, profile_id, started_at.
- `exercise_attempts`: attempt_id, session_id, phrase_id, timestamp, latency_ms,
  duration_ms, tapping_synchronization_score, evaluation_label, support_level.
  (NEVER local_encrypted_audio_path.)
- `acoustic_feature_vectors`: content_similarity_score, gate_passed, gate_reason,
  duration_ms. (NEVER any blob/path field.)
- `practice_phrases`: phrase_id, phrase_text, complexity_level (needed so the
  dashboard can show which word a score belongs to).
- A small derived `daily_summary` (date, sessions, attempts, pass_rate,
  mean_similarity) computed on-device — preferred unit for dashboard queries.

## Supabase configuration requirements
- Row Level Security ON for every table; a family-scoped key/token so only this
  family's data is readable. No public/anon read access.
- Document in the repo README-sync: the Supabase project URL config location,
  and the fact that free-tier projects pause when inactive (and that per
  invariant 3 this must be harmless).

## Sequencing (do not reorder the roadmap)
Sync implementation does NOT jump the queue. Priority remains: Phase 1 steps
4 & 5 (guide playback + mic capture, device-verified) → Phase 2B wiring. There
is little of value to sync until capture works. Acceptable now: schema setup,
sync queue skeleton, and the invariant tests. Full sync wiring lands after 2B.

## Cleanup with this addendum
- Resolve the briefs-vs-memory contradiction by treating this document as the
  single source of truth on networking.
- Confirm `pubspec.yaml` contains only the supabase client dependency needed,
  and `lib/` contains no cloud code paths violating invariants 1–3.
