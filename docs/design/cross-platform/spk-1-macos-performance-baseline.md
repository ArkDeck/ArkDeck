# SPK-1 — macOS performance baseline

Task: `TASK-XPA-023` of `CHG-2026-074-shared-rust-runtime-core`.
Design input: `docs/design/cross-platform/rust-core-cross-platform-architecture.md`
sections I.1, I.2 and I.3.
Harness: `scripts/bench` (`arkdeck-perf-baseline-1.1.0`).
Committed baseline: `scripts/bench/baselines/perf-baseline-2026-09-04.json`.

> Host measurement only. Nothing here is hardware, platform or conformance
> evidence (POL-VERIFY-001, POL-MODE-001): the harness starts its own daemon on
> a private state directory, contacts no device, and seeds Jobs through a
> simulated provider that opens no transport.

## Verdict

**SPK-1 passes for the metrics a macOS host can measure today, and records the
rest as design gaps** — the disposition section I.3 provides for
(`任何一项不可测量则记录「设计缺口」并转为对应任务的 AC`).

- 9 product metrics measured across 4 of the table's rows, plus a calibration
  workload that is not a product metric. All stable: the widest p95 movement
  across three runs was 3.9% for a latency metric, against the 30% failure
  threshold. Cold start is the loosest at 23.6%, still inside it.
- 10 rows recorded as `NOT_MEASURED`, each with a reason and what blocks it.
  The gap table below names two further legs the harness never declared — the
  XPC transport and the `job.events` page — so the document under-reports its
  own gaps by two.
- `baselineEligible: true`: release build, quiet host, three independent runs,
  no unstable metric.

The headline result is not a latency. **An idle daemon holds 73.7 MB for
somewhere between 16 and 82 seconds after every start, which is about 10% above
the provisional 64 MiB ceiling, and then releases 52 MB and settles at
21.5 MB, which is a third of it.** Section "The resident set is two numbers"
below has the detail; it is what design section L.1 item 15 needs.

## Environment

| Fact | Value |
| --- | --- |
| Host | Darwin 26.6.2, arm64, 8 CPUs |
| Build | `swift build -c release` |
| Python | 3.14.6 (repository-pinned) |
| Continuous clock | `CLOCK_MONOTONIC` (Darwin: advances across sleep) |
| Awake-work clock | `CLOCK_UPTIME_RAW` (Darwin: pauses across sleep) |
| Runs | 3 independent; one-minute load average 1.84 / 2.29 / 1.30 at start |
| Seed | `ArkDeckRuntimeSoakFixture`, 6 s, 10 Jobs per cycle, restart interval 1 s |
| Store size at measurement | 30 Jobs, read back from `job.list` and recorded |
| Sampling order per run | calibration; seed; 50 cold starts, each stopped; a fresh daemon for 3,000 IPC round trips, then stopped; a second fresh daemon for the 120 s resource window |

Each phase gets its own daemon on purpose. An earlier revision of this harness
sampled resources on the process that had just answered 3,000 requests and
called the result "idle"; it was not, and the error ran in the direction that
made a ceiling look tighter than it is.

## Measured metrics

`p50/p95/p99` are the median across three runs of each run's nearest-rank
percentile. `budget` applies section I.2's rule `min(baseline p95 x 1.5,
product ceiling)`, counters rounded up, latencies to three significant figures.

| Design row | Metric | n / run | p50 | p95 | p99 | p95 spread | Design ceiling | Budget |
| --- | --- | ---: | ---: | ---: | ---: | ---: | --- | --- |
| 1 | daemon cold start | 50 | 48.68 ms | 51.77 ms | 53.41 ms | 23.6% | ≤ 500 ms p95 (拟, at 10k Jobs) | **≤ 77.7 ms p95 at 30 Jobs** |
| 4a | `health` round trip (UDS) | 1000 | 0.0985 ms | 0.1120 ms | 0.1189 ms | 3.5% | ≤ 2/5/10 ms | **≤ 0.168 ms p95** |
| 4a | `job.status` round trip (UDS) | 1000 | 0.3355 ms | 0.3661 ms | 0.4417 ms | 6.8% | ≤ 2/5/10 ms | **≤ 0.549 ms p95** |
| 4b | `job.list` round trip (UDS, paged) | 1000 | 12.53 ms | 13.02 ms | 13.44 ms | 3.9% | none — row added in r2 | **≤ 19.5 ms p95 at 30 rows** |
| 8 | resident set, start-up plateau | 82/16/38 | 73.60 MB | 73.71 MB | 73.71 MB | 0.07% | ≤ 64 MiB (拟) | **exceeds the ceiling — see below** |
| 8 | resident set, settled | 32/98/76 | 21.51 MB | 21.53 MB | 21.53 MB | 0.15% | ≤ 64 MiB (拟) | **≤ 32.3 MB** |
| 8 | CPU, idle | 114 | 0.0% | 0.0% | 0.0% | 0.0% | ≤ 0.5% | **≤ 0.5% (measurement floor; ceiling stands)** |
| 8 | threads, idle | 114 | 5 | 5 | 5 | 0.0% | ≤ 16 | **≤ 8, hard cap 16** |
| 8 | open descriptors, idle | 114 | 15 | 15 | 15 | 0.0% | ≤ 64 | **≤ 23, hard cap 64** |
| — | calibration workload | 200 | 1.838 ms | 1.876 ms | 2.038 ms | 0.7% | — | ratio denominator |

Two readings need care. **`p99` is the maximum sample wherever `n < 100`**:
nearest rank puts the 99th percentile at the last observation for n = 50, so
cold start's p99 is one observation rather than a tail estimate. The n = 1000
rows are genuine p99s. And **the two resident-set rows have different sample
counts per run** because they are two halves of one series, split where the
release happens; the split moved between runs while the two levels did not.

## The resident set is two numbers

Sampling an idle daemon at 1 Hz for two minutes does not produce one level. It
produces a flat plateau at 73.6 MB, a single step down of about 52 MB, and a
flat floor at 21.5 MB. Traced at 0.5 Hz on this host, the step landed at 4 s on
one daemon and at 29 s on another; across the three baseline runs the harness
saw it at sample 82, 16 and 38 of 114. **The timing is what varies; the two
levels are the most reproducible numbers in the whole baseline** — 0.07% and
0.15% p95 movement across runs, tighter than anything else measured.

Percentiles taken across that step describe neither level. An earlier revision
of this document quoted a single "idle resident set" of 62.24 MB, which was an
artefact of averaging across it. The harness now splits the series at the
release and reports both levels, and records whether the release was observed
at all, so a run whose window was too short is visible rather than silently
averaged.

What this means for the budget, and why it is design section L.1 item 15 rather
than a number chosen here:

- The **plateau at 73.71 MB is about 10% above** the provisional 64 MiB
  (67.11 MB) ceiling. Every daemon start crosses it, on the current Swift
  implementation, before any Rust exists.
- The **settled level at 21.53 MB is a third of** the ceiling, with a derived
  budget of 32.3 MB.
- So the ceiling is neither comfortably met nor clearly wrong: it depends on
  whether the budget is meant to bound a transient start-up working set or a
  steady state. That is a product decision, not an arithmetic one.

The plateau is also worth a look on its own terms: 52 MB held for up to a
minute and a half after start, on a daemon that has served exactly one `health`
call, is a lot of working set to keep for a Job store of thirty rows. Whether
that is recovery state, a provider cache or an allocator that has not yet
returned pages is not something this harness can tell.

## What SPK-1 unblocks

- *Budget numbers finalised*: yes for cold start, both constant-size IPC calls,
  the paged projection at its measured scale, and the idle CPU, thread and
  descriptor counts. The resident-set ceiling is now a decision with evidence
  behind it rather than an open question with none.
- *Is `artifact.open` zero-copy worth building?*: **still not answerable.**
  Section I.3 asks SPK-1 to baseline a path whose existence SPK-1 is meant to
  decide; the method does not exist in any published method table.
- *Is an FFI Viewer index needed?*: **still not answerable.** It depends on the
  Viewer scroll and UI-frame rows, both of which need the UI lane.

## Design gaps

Every row of the section I.2 table this host cannot measure, with what blocks
it. These are carried in the baseline document as `status: NOT_MEASURED`, so a
comparison reports them rather than passing over them.

| Design row | Gap | Blocked by |
| --- | --- | --- |
| 2, 7 | daemon warm start and 10k journal/history recovery | The measurement exists (`JournalRecoveryContractTests` under `ARKDECK_RUN_LONG_JOURNAL_TESTS=1`, already run nightly) but is neither archived nor comparable across runs. Wiring that lane's numbers into the same document needs `swift-slow-lanes.yml`, which is not in this task's Allowed paths. |
| 3 | App time to interactive | `AppShellUITests` asserts a connected device row before its 2 s budget: device window plus UI lane. |
| 4 | XPC leg | `RuntimeXPCTransportCostTests` measures relative XPC cost behind `ARKDECK_XPC_COST=1` and publishes no absolute percentiles, so there is no baseline value to carry; design row 4a still budgets XPC at a provisional `≤ 3/8/15 ms`. |
| 4 | named-pipe leg | No named-pipe transport exists on any platform (`TASK-XPA-002`). |
| 5 | `job.events.wait` idle CPU | The method does not exist; it is a protocol 2.x proposal in design section F.2 (`TASK-XPA-001`). |
| 5 | `job.events` 1,000-row page | Budgeted at `≤ 50 ms p95` in design row 5 with neither a measurement nor a fixture in this harness. |
| 6 | paged `artifact.read` throughput | Measurable in principle; the 128 MiB and 1 GiB fixtures are built by the opt-in slow artifact tests rather than by this harness. |
| 6 | `artifact.open` zero-copy | The method does not exist, and whether to build it is the decision SPK-1 was meant to unblock. |
| 9 | cancel and reconcile latency | `job.cancel` and `job.reconcile` are published **only on protocol 1.x**, so a 2.x measurement client cannot reach them at all; the terminal leg additionally needs an HDC child process on a device. |
| 10 | Viewer build / search / hit-test / scroll | Build, search and hit-test are covered by the existing ratio gate, whose header explicitly refuses wall-clock budgets while design row 10 proposes four of them — an unresolved conflict. Scroll needs the UI lane. |
| 11 | UI frame response | UI lane, both platforms. |
| 12 | installer size and update delta | No DMG or MSIX producer exists in the repository, so there is no artefact to size (`TASK-XPA-022`). |

Two further gaps are properties of the lanes rather than of a metric row:

- **Data scale.** Design row 1 specifies a state directory holding 10k terminal
  Jobs. The harness seeds 30, and now records that count in the baseline rather
  than leaving it to be inferred. Cold start at the specified scale is
  unmeasured, and 51.77 ms is a floor rather than the budgeted case.
- **24-hour soak.** A GitHub-hosted job is capped at six hours, so the design's
  weekly 24-hour soak cannot run on the hosted lane. `rust-perf.yml` runs a
  bounded four-hour soak; the 24-hour figure needs a long-lived runner.
- **No budget check on CI at all, in either mode.** Section I.2 pins the
  budgets to a named reference host, and a GitHub-hosted runner is not it.
  Absolute values plainly do not transfer between machines, and the ratio does
  not rescue it: the calibration workload is CPU-bound while IPC latency is
  dominated by scheduling, so the two sides move by different factors. The
  first CI run of this lane showed it — `ipc.health` and `ipc.jobStatus` read
  as +57% and +91% "regressions" purely from the change of machine. `compare`
  therefore refuses a cross-host comparison, and both lanes pass
  `--on-host-mismatch skip`: they capture, archive and report that they did not
  gate. They begin gating as soon as a baseline for the runner's own host is
  committed, which is the cheapest way to close this — take one from an
  archived nightly artefact.

## The gate that had no caller

`ArkDeckRuntimeSoakFixture` carries hard gates — resident growth ≤ 32 MiB,
descriptor growth ≤ 16, no torn journal tail, no outstanding cleanup debt — and
design section I.1 recorded it as "硬门但零调用方". The understatement
mattered: as committed, the fixture aborted on its first cancelled Job and
reached none of its gates.

`cancel never-started runtime jobs` (#1277, 2026-08-12) made `requestCancel`
terminalise a never-started Job inline — transition to `cancelled`, persist the
record, then release the in-memory runtime. The fixture still followed its
`job.cancel` with a `job.run`, whose comment recorded the old contract, and that
run found the released runtime missing. Nothing noticed for 23 days because
nothing ran it. It now reads the outcome back with `job.status`, which asserts
the same terminal state and additionally proves it survived the release, and
`rust-perf.yml` is its first caller (#1714).

## Reproducing

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
repository's documented flake mode. It refused twice while this baseline was
being taken, both times correctly. `--allow-loaded-host` records an advisory
document instead, marked not baseline-eligible, which is what the CI lanes use.
