# TASK-XPA-025 — the scheduled lane picks its reference by daemon

Change: CHG-2026-074-shared-rust-runtime-core@r11. Slice: after SPK-11
([`spk-11-run.md`](spk-11-run.md), #2070), the remaining TASK-XPA-025 work is the three lanes of
`.github/workflows/rust-perf.yml` running green on the Rust daemon. This slice records where those
lanes stand and repairs what the Rust switch left behind in the nightly job.

Host and repository reading only. No daemon was started here, no device was contacted, and no budget,
ceiling or baseline is approved.

## 1. Where the three lanes stand on the Rust daemon

| Lane | Trigger | Last run on the Rust daemon | Conclusion |
| --- | --- | --- | --- |
| `harness-tests` | push touching `scripts/bench/**` or the workflow | run `35496107734`, 2026-09-20T07:09Z, the #2070 push | success; it runs the harness unit tests only |
| `nightly` | schedule `0 17 * * *` | run `35463686568`, 2026-09-19T19:14–19:22Z | success: activated the toolchain, built `arkdeck-agentd` and `arkdeck-soak` with Cargo, captured with `--runtime-kind rust --allow-loaded-host`, archived the document, and its comparison step skipped on host mismatch |
| `soak` | schedule `0 3 * * 0` and `workflow_dispatch` | **never** | the last soak run is `34746531597`, Sunday 2026-09-13T07:59–12:00Z, four hours, success — but on the Swift fixture, with the ArkForge credential and SwiftPM cache steps that #1979 removed |

So two of the three lanes are green on Rust today, and the soak lane is unproven on it. The weekly
schedule is the next occasion: the 2026-09-13 soak started at 07:59Z against a 03:00Z cron, so the
schedule runs hours late. This session cannot start it, because an agent may not use `gh` to write.
A maintainer dispatch of the workflow, or the next Sunday schedule, closes this.

One expectation to set for that first Rust soak run. The 30-minute local soak recorded in
[`spk-11-run.md`](spk-11-run.md) §7 grew its lifetime maximum resident set by 9.76 MB over 25 cycles,
against the fixture's 32 MiB gate, and that figure is a lifetime maximum with no per-cycle series
behind it. The hosted lane runs four hours at a 300-second restart interval, roughly 48 cycles, and
ends with one pass that reads back every Job and Artifact. Whether the gate holds at that scale is
not known from any run so far.

## 2. What this slice repairs

**The nightly job chose its reference by filename order.** The step took
`ls bench/baselines/perf-baseline-*.json | tail -1`, which is the Swift baseline of 2026-09-04, while
the capture above it is Rust. Comparing those two reports "not comparable, workload scale differs:
jobStoreRowCount: 30 vs 20" for every metric and fails, because the Swift soak seeds 30 Jobs and the
Rust soak 20 (SPK-11 §4). Today the hosted runner's host mismatch short-circuits the comparison
before the scale check, so the lane is green and prints "skipped". On a runner whose host does match,
the same step would turn the lane red without any regression behind it.

The step now asks `bench select-baseline` for the committed baseline that measured the same daemon as
the capture, and when there is none it archives and says so in the job summary instead of comparing.
Nothing else about the comparison changes: the same `--mode ratio --threshold 0.10` and the same
`--on-host-mismatch skip`.

- `baseline.runtime_kind(document)` reads `toolchain.runtimeKind`. A document written before that
  field existed measured the Swift daemon, so its absence is that answer rather than an unknown.
- `bench select-baseline --candidate <file> --directory <dir>` prints the last matching baseline by
  name. With no match it exits 1 with the reason. A committed baseline that cannot be parsed is an
  error rather than a file to select past: a repository defect should not read as a missing
  reference.

**Both macOS jobs pinned `DEVELOPER_DIR` to `Xcode_26.6`.** That pin is left from when the jobs built
SwiftPM products; since #1979 they build only Cargo products, which need the runner's default
toolchain. Removing it drops an image-specific path that the jobs no longer depend on.

## 3. Local targeted checks

Under the 2026-09-19 verification policy (#2015) the PR's CI is the unified gate.

| Check | Command | Result |
| --- | --- | --- |
| Harness unit tests | `cd scripts && python3 -m unittest discover -s bench -t .` | exit 0, 151 tests (146 before this slice) |
| Selection against the repository's own baselines | `python3 -m bench select-baseline --candidate bench/baselines/perf-baseline-2026-09-04.json --directory bench/baselines` | exit 0, prints that Swift baseline |
| The same for the SPK-11 Rust capture | `python3 -m bench select-baseline --candidate <SPK-11 capture> --directory bench/baselines` | exit 1, "no committed baseline measures a rust daemon" |
| Workflow parses, and the job graph and `env` blocks are as intended | `python3 -c "import yaml; …"` with the SDD virtual environment | exit 0, jobs `harness-tests`, `nightly`, `soak`, neither macOS job carrying a job-level `env` |
| SDD consistency | `ARKDECK_PYTHON=<repo>/.venv-sdd/bin/python sh scripts/check-sdd.sh` | exit 0, 0 errors, 0 warnings |

No crate changes, so no `cargo` check was needed.

## 4. CI

Pushed to `agent/xpa-025-perf-lane-baseline-20260920` after #2070 merged as `65b2a073`; the Agent PR
workflow opens the pull request. This slice also fills the CI section of [`spk-11-run.md`](spk-11-run.md),
which #2070 left for the next slice: that PR merged with every check green.

The PR number, run ids and conclusion for this slice are appended by the slice that follows it.

## 5. Not done here, and why

- The soak lane is not started: `workflow_dispatch` is a `gh` write operation, which this session may
  not perform. It needs a maintainer dispatch or the Sunday schedule.
- No Rust baseline is committed to `scripts/bench/baselines/`, so the nightly comparison still
  archives without comparing. That waits on the reference-host decision in
  [`spk-11-run.md`](spk-11-run.md) §13, decision 3. This slice only makes the choice well defined for
  the moment such a baseline lands.
- The retired per-push micro-benchmark lane (#1902) stays retired; design §I.2 note 3 keeps it out
  until a runner with its own committed baseline exists.
- Nothing here measures: the lane evidence above comes from existing runs.
