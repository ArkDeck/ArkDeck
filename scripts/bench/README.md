# `scripts/bench` — performance baseline and regression harness

The control harness uses the current registry in
`Packages/ArkDeckKit/Contracts/control-protocol.json`. It verifies the exact
health/contract identity on the same connection before each business request;
old peers are refused without fallback or replay.

Offline, host-only measurement tooling; Python 3 stdlib only (repository-pinned
CPython, see `.python-version`).  Delivered by `TASK-XPA-023` of
`CHG-2026-074-shared-rust-runtime-core`; the metric table, budget rule and
pass/fail criteria it implements are design sections I.2 and I.3 of
`docs/design/cross-platform/rust-core-cross-platform-architecture.md`.

## Boundary

The harness contacts no device and touches no installed Runtime.  Every number
comes from a daemon it starts itself, on a state directory it creates, seeds
and deletes:

- Rust `arkdeck-agentd` with an explicit private development root and endpoint,
  clearing inherited `ARKDECK_*` configuration;
- Rust `arkdeck-soak` to seed real terminal Jobs through the production
  engine, SQLite repository, journals and Artifact store with a simulated
  provider that opens no transport and spawns no child process.

It submits no operation, adopts no target, mints no capability and issues only
read-only control methods.  A host result is not hardware evidence
(POL-VERIFY-001, POL-MODE-001).

## Use

```bash
cd scripts
python3 -m bench capture \
  --daemon ../rust/target/release/arkdeck-agentd \
  --soak ../rust/target/release/arkdeck-soak \
  --runtime-kind rust \
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

```bash
cd scripts
python3 -m bench select-baseline \
  --candidate /tmp/arkdeck-perf/perf-baseline-<date>.json \
  --directory bench/baselines
```

`select-baseline` prints the committed baseline that measured the same daemon
as the capture, which is what the scheduled lane compares against. A Rust
capture judged against the Swift baseline reports every metric as not
comparable, because the two soaks seed different Job counts, so picking the
reference by filename order would read as a red lane rather than as a
regression. With no baseline for that daemon it exits 1 and says so; the lane
then archives the measurement instead of comparing. A document written before
`toolchain.runtimeKind` existed measured the Swift daemon.

Unit tests:

```bash
cd scripts
python3 -m unittest discover -s bench -t .
```

The reusable launcher also accepts `IsolatedRuntime(binary, directory,
runtime_kind="rust")` for the standalone Rust owner. It launches without Swift
arguments, sets only the private development root and endpoint, and clears
inherited `ARKDECK_*` configuration so a measurement cannot select the paired
facade or a device provider. Use `temporary_state_directory()` for a canonical
macOS path. Contract verification and process stop/restart use the same harness.
`bench capture --runtime-kind rust` carries that selection through cold starts,
seeded Job list/status reads and the idle resource window, and records it in
`toolchain.runtimeKind`. Connections are renewed and verified between batches
of 32 iterations, within the Rust daemon's 128-frame budget; requests are never
replayed after a transport failure. An unreadable or empty seeded Job store
fails the capture. The scheduled lanes build both Rust executables using
Cargo; no SwiftPM product or ArkForge package credential is required. Historical
Swift captures remain available with `--runtime-kind swift` (the compatibility
default) and a matching Swift soak executable. The committed Swift baseline is
preserved; a Rust reference-host baseline still requires three qualifying runs.

A capture document names the task and spike of the daemon it measured: a Swift
capture keeps `TASK-XPA-023`/`SPK-1`, the identity of the committed Swift
baseline, and a Rust capture carries `TASK-XPA-025`/`SPK-11`. The rows the
harness cannot measure are declared per daemon, each with the reason that holds
for that daemon (`metrics.gap_definitions(runtime_kind)`). Rust recovery and
`job.reconcile` are implemented. Recovery is measured only when explicitly
enabled as described below; `job.reconcile` remains a measurement gap. The first quiet-host Rust capture is
recorded beside its run record,
`openspec/changes/chg-2026-074-shared-rust-runtime-core/evidence/runs/TASK-XPA-025/spk-11-run.md`,
not in `baselines/`. A document in `baselines/` becomes the nightly lane's
comparison reference (the lane takes the last file by name), and whether this
host's newer macOS and Xcode can stand in for the reference host of design
section I.2 is a maintainer decision.

## What decides whether a run counts

A capture is only baseline-eligible when all of the following hold; otherwise
the document records why, stays advisory, and must not be committed.

| Condition | Why |
| --- | --- |
| release build | Design section I.2 pins both reference hosts to release builds; a debug build is a different program. |
| each phase on its own daemon | Cold start, IPC and the resource window each get a fresh process. Sampling resources on the daemon that just answered thousands of requests measures a served-then-quiet footprint, not an idle one. |
| quiet host (1-minute load average at most half the CPU count) | Wall-clock percentiles on a loaded host are this repository's documented flake mode (`ViewerScalePerformanceTests.swift`). The guard runs at the start of every run. `--quiet-wait-seconds N` lets a run wait up to N seconds for a loaded host to go quiet instead of refusing the whole capture at once; the run still starts only on a quiet host, and each run records its wait (`quietWaitSeconds`). `--allow-loaded-host` waives the requirement and downgrades the run to advisory instead of lying about it. It disqualifies unconditionally, not only when the guard trips: a shared runner is often quiet at the start of a run and busy during it, which the start-of-run guard cannot see. |
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

## Rust recovery capture (TASK-XPA-025)

Recovery is opt-in so the existing cold-start/RSS capture keeps its workload:

```sh
cd scripts
python3 -m bench capture --runtime-kind rust --build-configuration release \
  --daemon /private/tmp/task-target/release/arkdeck-agentd \
  --soak /private/tmp/task-target/release/arkdeck-soak \
  --recovery-samples 5 --recovery-only --runs 3 \
  --out-dir /private/tmp/arkdeck-recovery
```

Omit `--recovery-only` to add the two recovery legs to the normal capture. Each
independent run generates one pristine seed per workload. Each sample copies it
to a new private root and verifies its input digest before daemon launch; the
daemon never opens the template. All roots are deleted. Seed/copy preparation and validation
are outside the timer. `arkdeck-soak --seed-recovery journal|history COUNT ROOT`
requires an empty, absolute directory and bounds COUNT to 2..10000 (small counts
are for tests; the measurement always uses 10000). It uses production JobStore
and JournalWriter, never a device provider, Keychain, installed Runtime or CLI.
The deterministic timestamp, IDs and warning contents are versioned as
`rust-recovery-fixture-v1`; the digest of actual record/journal bytes and actual
counts are captured before starting the real daemon.

- `daemon.warmStartRecovery`: one active `preflight` Job, exactly 10000 journal
  events: creation, queued-to-preflight transition and 9998 warnings. The daemon
  must persist `recovered: journal clean`, return the exact Job/state and leave
  journal bytes unchanged. This is clean replay, not unknown-intent recovery.
- `daemon.warmStartRecovery.history`: 10000 terminal `succeeded` Job snapshots
  and zero journal events/active Jobs. Like the existing terminal History test,
  the seed goes directly through the repository, not 10000 provider executions.
  All 10000 distinct IDs/states must be read back in pages of 250; every durable
  snapshot must remain terminal without a recovery marker. This checks that
  terminal history does not expand the startup recovery set.

Both timers run from process spawn through **completion verification** using
awake-work time, with a continuous-clock deadline. The reported total includes
contract handshakes, pagination and durable snapshot readback. Each raw sample
also records `spawnThroughHealthMilliseconds` and
`completionVerificationMilliseconds` so History read cost is visible. These
are end-to-end upper bounds, **not pure replay time**, and must not be declared
passes against the old in-process replay budget. A successful health call alone
never produces a recovery sample; the daemon's current startup order runs
recovery before serving, and the workload-specific checks prove its effects.

Before seed preparation and immediately before/after each formal sample the harness requires load < 4 and no cargo, rustc,
xcodebuild or Python plan.py process. Coordinate the window with other sessions;
`--allow-loaded-host` is advisory only. Each attempt is appended immediately to
`recovery-samples-<unique-id>.jsonl`, including failed attempts, so a later error
cannot discard earlier samples. The final baseline-format JSON also contains
all measured recovery samples, both executable SHA-256s, declared build
configuration, workload and completion counts. Timeouts, seed/recovery failures
and missing/duplicate Jobs fail the capture; the owned daemon is stopped and the
root removed even on failure. A subsequent attempt always starts a fresh root.

The comparison identity includes fixture version, seed strategy, both 10k workload scales,
page size and timing boundary. Recovery-only documents explicitly mark other
legs unmeasured and are not replacements for full reference baselines. The
existing three-run/30% spread rules and reference-host approval still apply;
old cold-start/RSS instability and committed baselines are retained unchanged.
