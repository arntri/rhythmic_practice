# docs/ — historical build briefs

These are the **working briefs the app was built from**, kept for provenance.
They are *not* maintained, and where they disagree with the code, the code wins.

| Document | What it covers | Still accurate? |
|---|---|---|
| `phase1_build_brief.md` | The original practice loop, metronome and data model. | Mostly — the progression model it describes was later replaced. |
| `phase2a_build_brief.md` | The speech-analysis core: WAV → MFCC → DTW, device-independent. | Yes. Still how scoring works. |
| `sync_addendum_brief.md` | Optional cloud sync of metrics only. | Partly — the sync plumbing is intact, but the sign-in UI has been removed. |
| `therapy_design_addendum.md` | Therapy-fidelity rules, recorded guides, multi-language. | Partly — superseded on who records guide audio (the author does, not caregivers). |
| `project_addendum_and_status.md` | Mid-project status snapshot. | Historical only. |

**For the current state, read these instead:**

- [`../APP_OVERVIEW.md`](../APP_OVERVIEW.md) — what the app does now, derived from
  the source and the passing test suite rather than from intent. The single
  source of truth.
- [`../DEPRECATIONS.md`](../DEPRECATIONS.md) — what has been removed or changed
  and why, with each entry's dependants, so dead code gets deleted in the same
  sweep instead of rotting in the tree.
