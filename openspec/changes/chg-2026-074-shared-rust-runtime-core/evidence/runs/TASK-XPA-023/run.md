# TASK-XPA-023 — run record

Change: CHG-2026-074-shared-rust-runtime-core (@r3 at the time of writing).
Acceptance: XPA-AC-5. Spike recorded here: SPK-1.
Host measurement only — not hardware, platform or conformance evidence
(POL-VERIFY-001, POL-MODE-001). No device was contacted; the harness starts its
own daemon on a private state directory it creates, seeds and deletes.

## Environment

| Fact | Value |
| --- | --- |
| Host | Darwin 26.6.2, arm64, 8 CPUs |
| Build | `swift build -c release` |
| Python | 3.14.6 (repository-pinned) |
| Catalog digest | unchanged; this task publishes no operation and dispatches none |
| Device | none — `Hardware required:no` |

## Artefacts

| File | SHA-256 |
| --- | --- |
| `scripts/bench/baselines/perf-baseline-2026-09-04.json` | `607617350591b92842a010414e9b2e6cde3373ca29986e811a38ee9d22ad0a93` |

## SPK-1 result

`PASS`. Three independent runs on a quiet host, release build. 9 product
metrics across 4 rows of the design section I.2 table, plus a calibration
workload; all stable. Widest p95 movement 23.6% (cold start) against the 30%
failure threshold. 10 rows recorded as `NOT_MEASURED` with a reason and an
owner. `baselineEligible: true`.

The full report, including the two rows deliberately left unfinalised and the
resident-set finding behind design section L.1 item 15, is
`docs/design/cross-platform/spk-1-macos-performance-baseline.md`.

## Commands run, and their results

| Command | Result |
| --- | --- |
| `python3 -m bench capture --build-configuration release --out-dir <tmp>` (x3 during development, plus the committed run) | `verdict=PASS measured=10 gaps=10 baselineEligible=True`; exit 0 |
| the same, twice, on a host above the quiet ceiling | refused with exit 1 — the load guard working as designed, which is why the committed run is clean |
| `python3 -m bench compare --mode ratio --threshold 0.20` (committed vs itself) | `PASS`, exit 0 |
| `python3 -m bench compare --mode absolute --threshold 0.10` (release baseline vs a debug capture) | `FAIL`, exit 1, flagging +23.9% cold start, +67.3% resident set, +113.4% `health` — the gate detects real regressions, not only synthetic fixtures |
| `python3 -m bench compare` with a candidate whose latencies were tripled, under `set -euo pipefail` | pipeline exit 1 |
| `python3 -m bench compare` with a cross-host candidate | refused, exit 1; with `--on-host-mismatch skip`, exit 0 and reported as not gating |
| `cd scripts && python3 -m unittest discover -s bench -t .` | 110 tests, OK |
| `sh scripts/check-sdd.sh` | 0 error(s), 0 warning(s), 121 acceptance IDs |
| `cd scripts && python3 -m unittest discover -s host_loop -t .` | 585 tests, OK (1 expected failure, as designed) |
| `python3 scripts/test_check_pr_paths.py` | 70 tests, OK |
| `python3 scripts/check_pr_paths.py --preflight` | `TASK-XPA-023` |
| `python3 scripts/ci/plan.py --run-local` | exit 0 |
| `ArkDeckRuntimeSoakFixture --duration-seconds 5` on merged `main` | exit 0; 24 terminal Jobs, resident growth 1.34 MB, descriptor growth 0, cleanup debt 0 |

## CI

The first two executions of `rust-perf.yml` found three defects in what this
task shipped; all three are fixed and recorded in the PR body. The lane now
captures, archives, and reports that it does not gate, because a GitHub-hosted
runner is not the reference host design section I.2 pins the budgets to.

## AC conclusion

XPA-AC-5 is **partially satisfied and the remainder is bounded**:

- The macOS baseline exists, is committed, is reproducible, and is compared by
  a tool with tests that prove it detects real regressions.
- Archiving exists for the first time in this repository.
- Budgets are met where they are finalised; two rows carry §L.1 items 15–16.
- "every budget met on both platforms" and "regression thresholds respected for
  30 days" remain open: Windows has no lane yet, and the 30-day window has not
  elapsed. Neither is claimed here.

## Golden Journey

Not applicable. This task advances no Golden Journey hop and claims no
`REAL_DEVICE_PASS`; `Hardware required:no`, and the device-bound metrics in the
design table are recorded as gaps rather than measured.

## Stop condition

Not triggered.
