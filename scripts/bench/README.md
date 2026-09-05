# `scripts/bench` — performance baseline and regression harness

Offline, host-only measurement tooling; Python 3 stdlib only (repository-pinned
CPython, see `.python-version`).  Delivered by `TASK-XPA-023` of
`CHG-2026-074-shared-rust-runtime-core`; the metric table, budget rule and
pass/fail criteria it implements are design sections I.2 and I.3 of
`docs/design/cross-platform/rust-core-cross-platform-architecture.md`.

## Boundary

The harness contacts no device and touches no installed Runtime.  Every number
comes from a daemon it starts itself, on a state directory it creates, seeds
and deletes:

- `arkdeck-agentd --state-dir <private dir>` with `ARKDECK_ARKFORGE_BUNDLE_PATH`
  and `ARKDECK_HDC_PATH` removed from the child environment;
- `ArkDeckRuntimeSoakFixture` to seed real terminal Jobs through the production
  engine, SQLite repository, journals and Artifact store with a simulated
  provider that opens no transport and spawns no child process.

It submits no operation, adopts no target, mints no capability and issues only
read-only control methods.  A host result is not hardware evidence
(POL-VERIFY-001, POL-MODE-001).

## Use

```bash
cd scripts
python3 -m bench capture \
  --daemon ../Packages/ArkDeckKit/.build/release/arkdeck-agentd \
  --soak ../Packages/ArkDeckKit/.build/release/ArkDeckRuntimeSoakFixture \
  --build-configuration release \
  --out-dir /tmp/arkdeck-perf
```

```bash
cd scripts
python3 -m bench compare \
  --committed bench/baselines/perf-baseline-<date>.json \
  --candidate /tmp/arkdeck-perf/perf-baseline-<date>.json \
  --mode ratio --threshold 0.20
```

Unit tests:

```bash
cd scripts
python3 -m unittest discover -s bench -t .
```

## What decides whether a run counts

A capture is only baseline-eligible when all of the following hold; otherwise
the document records why, stays advisory, and must not be committed.

| Condition | Why |
| --- | --- |
| release build | Design section I.2 pins both reference hosts to release builds; a debug build is a different program. |
| each phase on its own daemon | Cold start, IPC and the resource window each get a fresh process. Sampling resources on the daemon that just answered thousands of requests measures a served-then-quiet footprint, not an idle one. |
| quiet host (1-minute load average at most half the CPU count) | Wall-clock percentiles on a loaded host are this repository's documented flake mode (`ViewerScalePerformanceTests.swift`). `--allow-loaded-host` waives the requirement and downgrades the run to advisory instead of lying about it. It disqualifies unconditionally, not only when the guard trips: a shared runner is often quiet at the start of a run and busy during it, which the start-of-run guard cannot see. |
| at least three independent runs | Section I.3. |
| p95 spread at most 30% across those runs | Section I.3's failure criterion: a wider spread means host load is being measured, not the product. |

## Exit codes

`capture` exits 2 when a metric's p95 moved more than 30% between runs — but
only for a run that could have established a baseline. An advisory capture (a
debug build, or `--allow-loaded-host`) is expected to be noisy, so instability
is reported and the exit stays 0; failing there would kill a CI step before the
comparison that actually gates it. `compare` exits 1 on a regression, on a
metric missing from the candidate, and on a metric it cannot judge: a committed
reference of zero with no absolute budget in `compare.ABSOLUTE_BUDGETS`, or a
candidate measured at a different workload scale. A zero reference that does
have a budget (idle CPU, 0.5% from design section I.2) is judged against that
budget instead of a ratio, in both modes.

## Comparing across machines

`compare` refuses outright when the two documents disagree on OS, architecture
or CPU count. Absolute milliseconds and megabytes obviously do not transfer
between machines, and **a ratio does not either**: the calibration workload is
CPU-bound, while IPC round-trip latency is dominated by scheduling and syscall
cost, so the two sides move by different factors. Design section I.2 pins the
budgets to a named reference host for this reason.

`--on-host-mismatch skip` reports the mismatch, archives the measurement and
exits 0 without gating. Both CI lanes use it, because a GitHub-hosted runner is
not the reference host; they start gating as soon as a baseline for the
runner's own host is committed.

Within one host, `--mode ratio` divides only time-unit metrics by the
calibration workload. Byte counts and object counts are compared directly —
dividing a resident set by a duration has no interpretation, and it would move
whenever the calibration moved.

## Reading the document

`schema: arkdeck-perf-baseline-1.1.0`.  Every design row appears exactly once,
either as `status: MEASURED` with per-run p50/p95/p99 or as
`status: NOT_MEASURED` with a `reason` and a `blockedBy`.  A row is never
dropped: an omission would read as coverage.

Percentiles use nearest rank, so a later comparison computes them the same way.
`aggregate` is the median across runs, which is the reference the design's
regression thresholds are relative to.  `derivedBudget` applies the design's
rule `budget = baseline p95 x 1.5`; the published budget is that value or the
product ceiling, whichever is smaller, and that choice is a maintainer decision
recorded in the design document, not here.

Durations come from the awake-work monotonic clock and wait budgets from the
continuous one, as REQ-NFR-001 requires; the resolved clock names are recorded
in every document.  A monotonic instant is never persisted.

Every metric carries the `scale` it was measured at — the seeded Job count read
back from `job.list`, the page size, the seed parameters — because a budget only
holds at its scale and the seeded count is not reconstructible from the seed
parameters alone.  Runs that disagree on scale keep every value rather than
being averaged.  `compare` treats the workload fields of that scale
(`seedSeconds`, `seedJobsPerCycle`, `seedRestartIntervalSeconds`,
`jobListPageSize`, `jobStoreRowCount`) as part of the metric's identity: two
documents that disagree on them are not compared and the comparison fails,
because the same p95 over a smaller data set is not the same result.  The
resident-set release observations recorded alongside them are not inputs and
take no part in that check.

The resident set is reported as two metrics, not one.  An idle daemon holds its
start-up working set for tens of seconds and then returns most of it in a single
step; the release has been observed anywhere from 4 s to 82 s after start, while
the levels either side of it are flat to within a fraction of a percent.
Percentiles taken across the step describe neither level, so the series is split
at the largest qualifying drop and `daemon.residentSetPlateau` and
`daemon.residentSetSteady` are reported separately, alongside whether the
release was observed inside the window at all.

## Privacy

`baseline.assert_no_host_identity` re-scans the serialized bytes before they are
written and refuses a document carrying a home directory, a user name or any
`/Users/<name>` or `/home/<name>` prefix.  Host facts are limited to OS, OS
version, architecture, CPU count and Python version.
