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

- 8 product metrics measured across 4 of the table's rows, plus a calibration
  workload that is not a product metric — 9 entries in the baseline document,
  all stable. The widest p95 movement across three runs was 5.8%, against the
  30% failure threshold.
- 10 rows recorded as `NOT_MEASURED` in the baseline document, each with a
  reason and what blocks it. The gap table below names two further legs the
  harness never declared at all — the XPC transport and the `job.events` page —
  so the document under-reports its own gaps by two.
- The captured document is `baselineEligible: true`: release build, quiet
  host, three independent runs, no unstable metric.

Section I.3 also asks SPK-1 to unblock three decisions. Most budget numbers are
proposed for finalisation in design section I.2 (change revision 2); two rows
and the other two decisions are not answerable yet and say why below. One
previously unstated conflict surfaced and is carried into the same revision.
See "What this changes".

## Environment

| Fact | Value |
| --- | --- |
| Host | Darwin 26.6.2, arm64, 8 CPUs |
| Build | `swift build -c release` (SwiftPM release, not debug) |
| Python | 3.14.6 (repository-pinned) |
| Continuous clock | `CLOCK_MONOTONIC` (Darwin: advances across sleep) |
| Awake-work clock | `CLOCK_UPTIME_RAW` (Darwin: pauses across sleep) |
| Runs | 3 independent, one-minute load average 1.57 / 1.63 / 2.76 at start |
| Seed | `ArkDeckRuntimeSoakFixture`, 6 s, 10 Jobs per cycle, `--restart-interval-seconds 1` |
| Store size at measurement | ~30 Jobs — a derived figure, not a recorded one; see the gap below |
| Sampling order per run | calibration, seed, 50 cold starts, 3,000 IPC round trips, then the 60 s resource window on the same process |

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
product ceiling)`, rounding counters up; these are the values revision 2 writes
into the design table. Row 4 is split there into 4a (constant-size replies) and
4b (paged projections), which is why the table below carries both.

| Design row | Metric | n / run | p50 | p95 | p99 | p95 spread | Design ceiling | Budget |
| --- | --- | ---: | ---: | ---: | ---: | ---: | --- | --- |
| 1 | daemon cold start | 50 | 48.53 ms | 49.93 ms | 53.45 ms | 3.0% | ≤ 500 ms p95 (拟, at 10k Jobs) | **≤ 74.9 ms p95 at this scale** |
| 4a | `health` round trip (UDS, constant-size) | 1000 | 0.0994 ms | 0.1128 ms | 0.1192 ms | 1.7% | ≤ 2/5/10 ms | **≤ 0.169 ms p95** |
| 4a | `job.status` round trip (UDS, constant-size) | 1000 | 0.3393 ms | 0.3640 ms | 0.3932 ms | 5.8% | ≤ 2/5/10 ms | **≤ 0.546 ms p95** |
| 4b | `job.list` round trip (UDS, paged projection) | 1000 | 12.55 ms | 13.57 ms | 13.64 ms | 4.5% | none — new row in r2 | **≤ 20.4 ms p95 at ~30 rows** |
| 8 | resident set, post-workload | 57 | 62.24 MB | 62.24 MB | 62.26 MB | 0.3% | ≤ 64 MiB (拟) | **not finalised — see below** |
| 8 | CPU, post-workload | 57 | 0.0% | 0.0% | 2.1% | 0.0% | ≤ 0.5% | **≤ 0.5% (at the measurement floor; ceiling stands)** |
| 8 | threads, post-workload | 57 | 5 | 5 | 5 | 0.0% | ≤ 16 | **≤ 8, hard cap 16** |
| 8 | open descriptors, post-workload | 57 | 15 | 15 | 15 | 0.0% | ≤ 64 | **≤ 23, hard cap 64** |
| — | calibration workload | 200 | 1.845 ms | 1.891 ms | 2.012 ms | 2.2% | — | ratio denominator |

Two readings of this table need care. **The row 8 samples are not cold idle.**
The harness runs 50 cold starts and then 3,000 IPC round trips against the same
daemon process before its 60-second resource window opens, so these are
"served, then quiet" figures. For threads, descriptors and CPU that is
conservative — a cold daemon will not hold more — so those budgets stand. For
resident set it is the wrong direction: using a post-workload figure to argue
that a ceiling has little headroom does not follow, which is why that row is
left provisional. **And `p99` is the maximum sample wherever `n < 100`**:
nearest-rank puts rank 99% at the last observation for n = 50 and n = 57, so
the p99 column for cold start and all four row 8 metrics is one observation,
not a tail estimate. The n = 1000 rows are genuine p99s.

The calibration row is not a product metric. It is a fixed CPU workload timed in
the same run so the PR lane can compare ratios: a runner that is uniformly
slower moves both numbers and reads as no change, while a real regression moves
only one.

## What this changes

**1. The provisional IPC budget does not survive a list projection.** Design row
4 proposed one UDS budget of `≤ 2/5/10 ms` for `health` and `job.status`. Those
two land 44x and 14x inside its p95 leg (20x and 5.9x against its tighter
p50 leg). `job.list` does not: at 13.57 ms p95 over a
store of roughly thirty Jobs it is already 2.7x past the proposed 5 ms p95
ceiling, and the mechanical rule `min(p95 x 1.5, ceiling)` would hand it a
budget below its own measured value. A constant-size reply and a per-row
projection that computes a `nextAction` for every row are not one metric.
*Revision 2 proposes*: section I.2 carries two IPC rows, and the
projection row gets `<= 20.4 ms p95` at the measured scale. What stays open, as
note 1 of that section records, is the two-part "fixed cost plus per-row cost"
budget: at roughly 0.45 ms per row, the permitted `pageSize` of 1,000
extrapolates to about 450 ms, which the History surface would feel.

**2. The idle resident-set budget has almost no headroom, before any Rust
exists.** The Swift daemon idles at 62.24 MB against a proposed 64 MiB
(67.11 MB) ceiling — 92.7% of it. The derived `p95 x 1.5` value (93.4 MB) is
above the ceiling, so the ceiling wins, and it wins by 4.9 MB. Any Rust port
that lands even slightly heavier breaches a budget the current implementation
already nearly fills. Either the ceiling was set without a baseline (section
I.2 marked it 拟, which says as much) or the target needs to be a reduction
rather than a ceiling. *Carried into revision 2* as note 2 of section I.2 and
as maintainer decision L.1 item 15 — but the argument above is weaker than it
first looks, and revision 2 says so: 62.24 MB is a post-workload reading, not
cold idle, so it cannot support a claim about how much headroom a cold daemon
has. The row therefore keeps its provisional `<= 64 MiB` and merging the
revision selects neither option. The cold-idle measurement (restart the daemon
before the sampling window) is follow-up work in this task.

**3. `min(p95 x 1.5, ceiling)` degenerates at the instrument floor.** Idle CPU
reads 0.0% in every sample — `ps` resolves to one decimal and the daemon is
genuinely idle — so the rule yields a budget of 0.0%, which nothing can satisfy.
Where a measurement sits at the instrument floor the ceiling should stand
unchanged. *Revision 2 proposes*: the section I.2 preamble states that
rule, alongside a second one the spike exposed — a budget holds only at the
data scale it was measured at, which is why the cold-start row keeps its
provisional 500 ms ceiling for the 10k-Job scale it was never measured at.

**4. Two of section I.3's three decisions are now answerable.**

- *Budget numbers finalised*: yes — section I.2 revision 2 carries them. Two
  sub-questions stay open and are marked there: the two-part projection budget
  (item 1) and whether the 64 MiB idle ceiling stands (item 2).
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
| 4 | XPC leg | `RuntimeXPCTransportCostTests` measures relative XPC cost behind `ARKDECK_XPC_COST=1` and publishes no absolute percentiles, so there is no baseline value to carry; design row 4a still budgets XPC at a provisional `<= 3/8/15 ms`. |
| 4 | named-pipe leg | No named-pipe transport exists on any platform (`TASK-XPA-002`). |
| 5 | `job.events` 1,000-row page | Budgeted at `<= 50 ms p95` in design row 5 with neither a measurement nor a fixture in this harness. |
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
- **The measured store size is not recorded.** Every per-row figure for
  `job.list` divides by a row count of roughly thirty, which is derived from
  the seed parameters rather than read back: the harness asks `job.list` for a
  page but keeps only the first `jobId`. With the fixture's own default restart
  interval the seed would produce ten Jobs, not thirty, so the number is not
  even reconstructible from the report without also knowing the harness
  override. The fix is one line — record `len(items)` as a `scale` field on the
  affected metrics — and it is why the paged-projection budget is provisional.
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

## Why the harness was not committed with this report

*Revision 2 proposes* adding `scripts/README.md` to `TASK-XPA-023`'s
Allowed paths. The harness lands in the implementation PR that follows the
merge of that revision. The contradiction it removes is recorded here because
it is the kind that reappears: **any task authorised to create a first-level
`scripts/` entry must also be authorised to edit `scripts/README.md`.**

`TASK-XPA-023` listed `scripts/bench/**` among its Allowed paths, so the
harness had an authorised home. It still could not be created there, because
these two rules could not both be satisfied:

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

The narrowest fix is the one revision 2 makes: add `scripts/README.md` to this
task's Allowed paths, and forbid every other boundary-map row so the widening
stays at the one entry this change is entitled to add.

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
