# TASK-XPA-022 / WM6 — Windows GJ conformance rows (2026-09-30)

- **Kind:** governance proposal, host-only. No hdc was run and the DAYU200 was not touched.
- **Base:** protected `main` `2fd7d206`.
- **Merge:** by the maintainer. The PR edits `openspec/platforms/windows/conformance-cases.yaml`.

## What changed

The PR adds five cases to `openspec/platforms/windows/conformance-cases.yaml`, one per Golden
Journey: `WIN-GJ1-001` … `WIN-GJ5-001`. Every one is `NOT_RUN`.

Each case has the following fields:

- **`method`:** the headless runbook section, run through the installed Rust daemon, following
  `docs/design/cross-platform/windows-phase-a-runbook.md` §4.N (#2398).
- **`expected_result`:** the headless runbook's criteria on the current Catalog digest, and the
  owning task's `REAL_DEVICE_PASS` (XPA-006, 008, 009, 010 and 011).
- **`minimum_evidence`:** `realHardware`.
- **`hardware_capability`:**
  - `hdcConnectivity` for GJ-1, GJ-2, GJ-3 and GJ-5;
  - `flash` for GJ-4, as `AC-FLASH-014-01` uses.
- **`preconditions`:** the Windows gates the runbook names for that Journey.

The PR also updates the `scope` line and adds one sentence to the notes. No status, support cell,
lock entry or profile changed.

## Delegated minor decisions (pending the next rulings batch)

1. **Suite version.** The suite version stays `0.2.0`, so `PLATFORM-PROFILES.lock.yaml` and
   `profile.md` are untouched. Only `NOT_RUN` rows are added and no status moves. If the
   maintainer wants the added rows to be a version bump (`0.3.0`, with the lock and profile), that
   is a follow-up in the same governance lane.
2. **Row granularity.** There is one row per Journey. The GJ-1 HAR crash-resume (headless §2.1)
   sits inside `WIN-GJ1-001`, as the macOS GJ-1 pass includes it.

## Rule conflict (flagged)

The phase-S common rules forbid agent edits under `openspec/platforms`, but the lead asked for
these rows. They are therefore delivered as a separate governance PR for the maintainer to review
and merge, and not merged by the agent.

## Checks

- `PYTHONUTF8=1 sh scripts/check-sdd.sh`: 0 errors, 0 warnings.
- The YAML parses; it has 17 cases, all `NOT_RUN`.
- `git diff --check`: clean.
