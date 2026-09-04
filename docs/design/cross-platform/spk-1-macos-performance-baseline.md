# SPK-1 — macOS performance baseline

Task: `TASK-XPA-023` of `CHG-2026-074-shared-rust-runtime-core`.
Design input: `docs/design/cross-platform/rust-core-cross-platform-architecture.md`
sections I.1, I.2 and I.3.
Harness: a Python 3 stdlib measurement package emitting
`arkdeck-perf-baseline-1.0.0`. **It is not in the repository yet** — see
"Why the harness is not committed" below. The numbers here were produced by it
on this host and are reproducible once it lands.

> Host measurement only. Nothing here is hardware, platform or conformance
> evidence (POL-VERIFY-001, POL-MODE-001): the harness starts its own daemon on
> a private state directory, contacts no device, and seeds Jobs through a
> simulated provider that opens no transport.

## Verdict

**SPK-1 passes for the metrics a macOS host can measure today, and records the
rest as design gaps** — which is exactly the disposition section I.3 provides
for (`任何一项不可测量则记录「设计缺口」并转为对应任务的 AC`).

- 9 metrics measured, all stable: the widest p95 movement across three runs was
  5.8%, against the 30% failure threshold.
- 10 design rows recorded as `NOT_MEASURED`, each with a reason and what blocks
  it. None was dropped from the table.
- The captured document is `baselineEligible: true`: release build, quiet
  host, three independent runs, no unstable metric.

Section I.3 also asks SPK-1 to unblock three decisions. Two of them are now
answerable, one is not, and one previously unstated conflict surfaced. See
"What this changes" below.

## Environment

| Fact | Value |
| --- | --- |
| Host | Darwin 26.6.2, arm64, 8 CPUs |
| Build | `swift build -c release` (SwiftPM release, not debug) |
| Python | 3.14.6 (repository-pinned) |
| Continuous clock | `CLOCK_MONOTONIC` (Darwin: advances across sleep) |
| Awake-work clock | `CLOCK_UPTIME_RAW` (Darwin: pauses across sleep) |
| Runs | 3 independent, one-minute load average 1.57 / 1.63 / 2.76 at start |
| Seed | `ArkDeckRuntimeSoakFixture`, 6 s, 10 Jobs per cycle |

Design section I.2 pins the reference host to "Apple M3 / 8 cores / 16 GB /
macOS 26.6 / Xcode 26.6 release" and `verification.md` to "Apple silicon (8
cores, 16 GB)". This host matches the core count, architecture and OS minor;
the exact chip is not recorded in the baseline document because that document
is meant to be committed and the harness refuses host-identifying content.

One caveat the document records rather than hides: the load guard is checked at
the start of each run, and run 3's one-minute average had risen to 4.14 by the
time it finished — just above the quiet ceiling of 4.0. The p95 spread stayed
at or below 5.8% regardless, so the result stands, but a future harness change
should re-check load at the end and downgrade a run that drifted.

## Measured metrics

`p50/p95/p99` are the median across the three runs of each run's nearest-rank
percentile. `budget` applies section I.2's rule `min(baseline p95 x 1.5,
product ceiling)`, where the ceiling is the provisional (拟) number from the
design table.

| Design row | Metric | n / run | p50 | p95 | p99 | p95 spread | Design ceiling | Budget |
| --- | --- | ---: | ---: | ---: | ---: | ---: | --- | --- |
| 1 | daemon cold start | 50 | 48.53 ms | 49.93 ms | 53.45 ms | 3.0% | ≤ 500 ms p95 | **74.9 ms** |
| 4 | `health` round trip (UDS) | 1000 | 0.0994 ms | 0.1128 ms | 0.1192 ms | 1.7% | ≤ 2/5/10 ms | **0.169 ms** |
| 4 | `job.status` round trip (UDS) | 1000 | 0.3393 ms | 0.3640 ms | 0.3932 ms | 5.8% | ≤ 2/5/10 ms | **0.546 ms** |
| 4 | `job.list` round trip (UDS) | 1000 | 12.55 ms | 13.57 ms | 13.64 ms | 4.5% | ≤ 2/5/10 ms | **conflict, see below** |
| 8 | idle resident set | 57 | 62.24 MB | 62.24 MB | 62.26 MB | 0.3% | ≤ 64 MiB (67.11 MB) | **67.11 MB (ceiling wins)** |
| 8 | idle CPU | 57 | 0.0% | 0.0% | 2.1% | 0.0% | ≤ 0.5% | **0.5% (see note)** |
| 8 | idle threads | 57 | 5 | 5 | 5 | 0.0% | ≤ 16 | **7.5** |
| 8 | idle open descriptors | 57 | 15 | 15 | 15 | 0.0% | ≤ 64 | **22.5** |
| — | calibration workload | 200 | 1.845 ms | 1.891 ms | 2.012 ms | 2.2% | — | ratio denominator |

The calibration row is not a product metric. It is a fixed CPU workload timed in
the same run so the PR lane can compare ratios: a runner that is uniformly
slower moves both numbers and reads as no change, while a real regression moves
only one.

## What this changes

**1. The provisional IPC budget does not survive a list projection.** Design row
4 proposes one UDS budget of `≤ 2/5/10 ms` for `health` and `job.status`. Those
two land 44x and 14x inside it. `job.list` does not: at 13.57 ms p95 over a
store of roughly thirty Jobs it is already 2.7x past the proposed 5 ms p95
ceiling, and the mechanical rule `min(p95 x 1.5, ceiling)` would hand it a
budget below its own measured value. The two shapes are not one metric: a
constant-size reply and a per-row projection that computes a `nextAction` for
every row belong in separate budget rows. **Maintainer decision needed**;
this document does not pick a number, and no budget for `job.list` is proposed
here.

**2. The idle resident-set budget has almost no headroom, before any Rust
exists.** The Swift daemon idles at 62.24 MB against a proposed 64 MiB
(67.11 MB) ceiling — 92.7% of it. The derived `p95 x 1.5` value (93.4 MB) is
above the ceiling, so the ceiling wins, and it wins by 4.9 MB. Any Rust port
that lands even slightly heavier breaches a budget the current implementation
already nearly fills. Either the ceiling was set without a baseline (section
I.2 marks it 拟, which says as much) or the target needs to be a reduction
rather than a ceiling. **Maintainer decision needed.**

**3. `min(p95 x 1.5, ceiling)` degenerates at the instrument floor.** Idle CPU
reads 0.0% in every sample — `ps` resolves to one decimal and the daemon is
genuinely idle — so the rule yields a budget of 0.0%, which nothing can satisfy.
Where a measurement sits at the instrument floor the ceiling should stand
unchanged; the table above applies that reading. The same will apply to any
future counter metric that legitimately reads zero.

**4. Two of section I.3's three decisions are now answerable.**

- *Budget numbers finalised*: yes for rows 1 and 8 and for the two constant-size
  IPC calls, no for `job.list` (item 1) and for idle RSS (item 2).
- *Is `artifact.open` zero-copy worth building?*: **not answerable.** Section
  I.3 asks SPK-1 to baseline a path whose existence SPK-1 is meant to decide;
  `artifact.open` does not exist in any published method table. The circularity
  is recorded as a gap, not resolved.
- *Is an FFI Viewer index needed?*: **not answerable here.** It depends on the
  Viewer scroll and UI-frame rows, both of which need the UI lane.

## Design gaps

Every row of the section I.2 table that this host cannot measure, with what
blocks it. These are carried in the baseline document as `status:
NOT_MEASURED`, so a comparison reports them rather than passing over them.

| Design row | Gap | Blocked by |
| --- | --- | --- |
| 2, 7 | daemon warm start and 10k journal/history recovery | The measurement exists (`JournalRecoveryContractTests` under `ARKDECK_RUN_LONG_JOURNAL_TESTS=1`, already run nightly) but is neither archived nor comparable across runs, so no baseline value can be carried. Wiring that lane's numbers into the same document is the natural next step and needs `swift-slow-lanes.yml`, which is not in this task's Allowed paths. |
| 3 | App time to interactive | `AppShellUITests` asserts a connected device row before its 2 s budget: device window plus UI lane. |
| 4 | named-pipe leg | No named-pipe transport exists on any platform (`TASK-XPA-002`). |
| 5 | `job.events.wait` idle CPU | The method does not exist; it is a protocol 2.x proposal in design section F.2 (`TASK-XPA-001`). |
| 6 | paged `artifact.read` throughput | Measurable in principle; the 128 MiB and 1 GiB fixtures are built by the opt-in slow artifact tests rather than by this harness. |
| 6 | `artifact.open` zero-copy | The method does not exist, and whether to build it is the decision SPK-1 was meant to unblock. |
| 9 | cancel and reconcile latency | `job.cancel` and `job.reconcile` are published **only on protocol 1.x**, so a 2.x measurement client cannot reach them at all; the terminal leg additionally needs an HDC child process on a device. |
| 10 | Viewer build / search / hit-test / scroll | Build, search and hit-test are covered by the existing ratio gate, whose header explicitly refuses wall-clock budgets while design row 10 proposes four of them — an unresolved conflict. Scroll needs the UI lane. |
| 11 | UI frame response | UI lane, both platforms. |
| 12 | installer size and update delta | No DMG or MSIX producer exists in the repository, so there is no artefact to size (`TASK-XPA-022`). |

Two further gaps are properties of the lanes rather than of a metric row:

- **Data scale.** Design row 1 specifies a state directory holding 10k terminal
  Jobs. The harness seeds roughly thirty. Cold start at the real scale is
  therefore unmeasured, and the 49.93 ms figure is a floor, not the budgeted
  case. Seeding 10k Jobs needs a generator this task did not build.
- **24-hour soak.** A GitHub-hosted job is capped at six hours, so the design's
  weekly 24-hour soak cannot run on the hosted lane. `rust-perf.yml` runs a
  bounded four-hour soak; the 24-hour figure needs a long-lived runner.
- **Archiving and comparison of the percentile table.** `rust-perf.yml`
  archives the soak metrics, but the section I.2 baseline has no lane until the
  harness lands, so there is still no cross-run comparison for those rows.

## The gate that had no caller

`ArkDeckRuntimeSoakFixture` carries hard gates — resident growth ≤ 32 MiB,
descriptor growth ≤ 16, no torn journal tail, no outstanding cleanup debt — and
design section I.1 already recorded it as "硬门但零调用方". The understatement
mattered: as committed, the fixture aborted on its first cancelled Job and
reached none of its gates.

`fix(TASK-AIN-021): cancel never-started runtime jobs (#1277)` (2026-08-12) made
`requestCancel` terminalise a never-started Job inline — transition to
`cancelled`, persist the record, then release the in-memory runtime. The fixture
still followed its `job.cancel` with a `job.run` whose comment recorded the old
contract ("the following run persists the cancellation outcome"), and that run
found the released runtime missing and failed with `jobNotFound`. Nothing
noticed for 23 days because nothing ran it.

The fixture now reads the outcome back with `job.status` instead of running the
Job, which asserts the same `cancelled` terminal state and additionally proves
it survived the in-memory release. `rust-perf.yml` gives the fixture its first
caller.

## Why the harness is not committed

`TASK-XPA-023` lists `scripts/bench/**` among its Allowed paths, so the harness
has an authorised home. It still cannot be created there, because these two
rules cannot both be satisfied:

- `scripts/README.md` is a boundary map that must name every first-level entry
  under `scripts/`, and
  `test_check_pr_paths.py::AutomationConfigTests::test_readme_boundary_map_covers_every_first_level_scripts_entry`
  fails when one is missing. Adding `scripts/bench/` therefore requires editing
  `scripts/README.md`.
- `scripts/README.md` is not among the task's Allowed paths, so
  `check_pr_paths.py` refuses the diff: *declared task TASK-XPA-023 has paths
  outside Allowed paths: scripts/README.md*.

Both halves were verified mechanically on this host, the second by running the
checker against a probe commit. No other Allowed path is a plausible home:
`rust/**` is the Rust workspace root, and putting a Python package inside the
SwiftPM target directory `Packages/ArkDeckKit/Tests/ArkDeckRuntimeSoakFixture/`
would change what that target compiles. Relocating the harness to get past the
gate would be worse than naming the contradiction.

The narrowest fix is a one-line amendment adding `scripts/README.md` to this
task's Allowed paths; adding the `bench/` row to the boundary map in a separate
governance change first would work equally well. Until then this document
carries the SPK-1 result, and `rust-perf.yml` carries the soak lane, which
needs no harness.

## Reproducing

Once the harness lands, from a quiet host:

```bash
cd Packages/ArkDeckKit
swift build -c release --product arkdeck-agentd
swift build -c release --product ArkDeckRuntimeSoakFixture
cd ../../scripts
python3 -m bench capture \
  --daemon ../Packages/ArkDeckKit/.build/release/arkdeck-agentd \
  --soak ../Packages/ArkDeckKit/.build/release/ArkDeckRuntimeSoakFixture \
  --build-configuration release --out-dir /tmp/arkdeck-perf
```

The harness refuses to measure on a host whose one-minute load average exceeds
half its CPU count, because wall-clock percentiles under load are this
repository's documented flake mode. `--allow-loaded-host` records an advisory
document instead, marked not baseline-eligible.
