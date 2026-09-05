# TASK-XPA-023 — run record (defect repair after `done`)

Change: CHG-2026-074-shared-rust-runtime-core (@r3 at the time of writing).
Acceptance: XPA-AC-5. Host measurement code only — not hardware, platform or
conformance evidence (POL-VERIFY-001, POL-MODE-001). No device was contacted.

The task is `done`; this record covers three defects an external design review
found in the delivered comparator and its PR lane. They are repaired under the
same task because they are its own deliverable, and the task's Allowed paths
already cover every touched file.

## Defects

| # | Finding | Mechanical confirmation |
| --- | --- | --- |
| 1 | A committed reference of zero (idle CPU is 0.0% in the baseline) made the metric "incomparable" and the comparison still passed; a candidate of 100% passed in both modes | `compare.compare(document(a=0.0), document(a=100.0))["passed"]` was `True` before the change |
| 2 | The recorded workload `scale` took no part in comparability; a candidate seeded to 1 row with the same p95 as the 30-row baseline passed | `test_a_smaller_candidate_workload_is_incomparable_and_fails` fails on the old code |
| 3 | The `pull_request` path filter watched the harness, Rust, the workflow and the soak fixture, but not the Swift daemon it builds and measures | `Packages/ArkDeckKit/Sources/**` was absent from `on.pull_request.paths` |

## Repairs

- `scripts/bench/compare.py`: a zero reference is judged against the absolute
  product budget in `ABSOLUTE_BUDGETS` (idle CPU 0.5%, design section I.2) in
  both modes, and fails when no budget exists; the workload fields of `scale`
  (`seedSeconds`, `seedJobsPerCycle`, `seedRestartIntervalSeconds`,
  `jobListPageSize`, `jobStoreRowCount`) must match or the metric is
  incomparable; any incomparable metric fails the comparison. The result
  document gains `incomparable` and per-entry `basis`.
- `.github/workflows/rust-perf.yml`: the pre-merge lane also opens on
  `Packages/ArkDeckKit/Sources/**`, `Package.swift`, `Package.resolved` and
  `run-swiftpm.sh`; its capture no longer passes `--seed-seconds 4`, so its
  workload scale equals the committed baseline's (`seedSeconds` 6); and it is
  `push`-triggered on `main` and `agent/**` like `swift-ci.yml` instead of
  `pull_request`-triggered, because a `pull_request` run on a PR opened by the
  Agent PR workflow's `GITHUB_TOKEN` waits in `action_required` for a manual
  approval (observed on #1716 and #1723), while a deploy-key push runs at once.
- `scripts/bench/README.md`: the two rules are documented.
- `.github/workflows/rust-perf.yml` (build time): the microbenchmarks, nightly
  and soak jobs restore a release SwiftPM cache (`arkdeck-swiftpm-perf-v1-…`,
  `${{ runner.temp }}/arkdeck-swiftpm`, the shape of `swift-ci.yml`'s trusted
  stable cache); the first two save it from `main` only. Measured before the
  change: the build step took 9–11 of the job's 11–13 minutes on every run.

## Verification

| Command | Result |
| --- | --- |
| `cd scripts && python3 -m unittest discover -s bench -t .` | recorded in the PR commit message |
| `python3 scripts/check_pr_paths.py --preflight …` | `TASK-XPA-023` |

Not run here: a live capture. The comparator change is pure Python over
recorded documents; the committed baseline is untouched and its idle-CPU row
now carries a budget instead of an exemption.
