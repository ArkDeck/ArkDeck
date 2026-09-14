# TASK-XPA-023 — run record (per-merge micro-benchmark lane retired)

Change: CHG-2026-074-shared-rust-runtime-core. Acceptance: XPA-AC-5. Host
measurement lanes only — not hardware, platform or conformance evidence
(POL-VERIFY-001, POL-MODE-001). No device was contacted.

The task is `done`; this record covers one change to the delivered lanes in
`.github/workflows/rust-perf.yml`, made after a review of what every CI gate
costs and what it has caught (Actions API per job and step: 1,000 Swift CI
runs from 2026-08-22 to 2026-09-14, 258 Performance-lane runs, and the
compare-step log of every `microbenchmarks` job).

## Finding

The `microbenchmarks` job could not gate on a hosted runner, and it kept
nothing.

| Measurement | Value |
| --- | --- |
| Runs, 2026-09-04 to 2026-09-14 | 205 (116 agent-branch, 89 `main`) |
| Compare step printed `skipped: no committed baseline for this host` after `note: different host — cpuCount: 8 vs 3` | 202 |
| Other runs | 3, the lane's first `pull_request` runs before the comparator repair of #1723: two failed in capture, one printed `FAIL` through a pipeline whose status `tee` swallowed |
| Harness stability verdict on the runner, in the logs read (2026-09-08, 2026-09-14) | `UNSTABLE`, `baselineEligible=False` |
| Artifacts | none; the job has no upload step |
| Cost since #1877 made it `main`-only | 18 of the 22 merges from 2026-09-12 12:00 UTC ran it, median 2.9 and p90 3.9 minutes of a macOS job (57 minutes in all), one of the five concurrent macOS jobs a Free-plan organisation has |

`bench compare` refuses a cross-host ratio by design (§I.2, note 3), and the
harness rates a shared runner unstable, so committing a baseline for the
hosted runner is not an option either. The nightly job takes the same
measurement at full sample counts, compares it under the same rule and
archives it.

## Change

- `microbenchmarks` is removed. `harness-tests` is now the only job a push
  runs, so the push filter lists only `scripts/bench/**` and the workflow
  itself.
- The nightly and soak jobs, their schedules and the harness are unchanged.
  The release SwiftPM cache is now written by the nightly run alone.
- Design §I.2 note 3 records the retirement. The +20% PR threshold stays the
  target for a lane on a runner whose own baseline is committed.

## Verification

- `ruby -ryaml` parses the workflow, and `python3 -m unittest discover -s bench
  -t .` passes locally.
- The branch push runs `harness-tests` alone.
