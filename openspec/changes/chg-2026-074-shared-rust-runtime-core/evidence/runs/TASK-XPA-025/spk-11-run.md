# TASK-XPA-025 — SPK-11 run record: performance and soak on the isolated Rust daemon

Change: CHG-2026-074-shared-rust-runtime-core@r11. Spike recorded here: SPK-11 (the Spikes table of
`tasks.md`): "`scripts/bench` against the cargo-built isolated daemon for the 13 metrics;
`arkdeck-soak` reproducing `ArkDeckRuntimeSoakFixture`". Pass: "three runs on the reference host with
p95 spread < 30%; the two resident-set levels recorded separately". Fail: "the harness cannot drive the
Rust daemon". It supplies data for design §L.1 items 15 and 16.

Host measurement only. The harness starts its own daemon on a private state root that it creates and
deletes. It contacts no device and submits no operation (POL-VERIFY-001, POL-MODE-001). The installed
Runtime, its LaunchAgent and `~/Library/Application Support/ArkDeck` were not touched. Nothing here
approves a budget, raises a ceiling or commits a reference baseline. §L.1 items 15 and 16 remain
maintainer decisions. The capture document's `derivedBudget` fields are the harness's formula output,
not budgets.

Times are local (UTC+8) unless marked UTC.

## Verdict

**SPK-11 passes on this host for every leg the harness measures on the Rust daemon, and records the
other legs as gaps.** The harness drives the Rust daemon for every leg it drives on Swift, so the
spike's failure condition does not hold.

- Three independent release runs on a quiet host. The document reports `spikeVerdict: PASS` and
  `baselineEligible: true`, and the capture exited 0.
- All ten measured metrics are stable: nine product metrics and the calibration workload. Cold start
  has the widest p95 spread at 13.6%. Every other metric is under 4%, against the 30% failure line.
- The two resident-set levels are recorded as separate metrics, and the split found no release step.
  The idle Rust daemon held one level, 16.20–16.30 MB, flat for every run's 173-second window. So
  `daemon.residentSetPlateau` and `daemon.residentSetSteady` carry the same value in each run, and each
  run records `residentSetReleaseObserved: false`. Two supplementary traces (§5) show the daemon does release that
  working set, at 28 s in one and at 229 s in a control that used the capture's own sampler. Both
  metrics therefore describe the start-up level here. The settled levels, about 8.1 MB and then about
  4.9 MB, come from the traces.
- 14 legs of the design table are gaps on the Rust daemon, each with the reason that holds for it (§6).
- "The reference host" is qualified: the hardware matches design §I.2, but macOS 27.0 and Xcode 27.0
  are newer than the pinned 26.6. Whether this capture may stand for the reference host is a
  maintainer decision (§13, decision 3).
- `arkdeck-soak` reproduces the Swift workload apart from the socket leg (#1977). A bounded 30-minute
  soak on the same release binary passed every gate (§7).

## 1. Base, binaries and harness

- The binaries were built at protected main `9c58e484` (#2012) with
  `cargo build --offline --locked --release --jobs 2 -p arkdeck-agentd -p arkdeck-soak` (rustc 1.98.1,
  exit 0, 2 min 08 s). SHA-256: `arkdeck-agentd`
  `74d94541fcfce64af2b7885ec1edbbcb075f42858e54feb5d6bf0785f357974a`, `arkdeck-soak`
  `71ce635ff1206bae761b1bc9003928b57fec3b47de0aa14c222da6b68e1b0e78`. The capture document records
  the same digests. **The numbers describe that build.** The branch is rebased onto `28d2016c`
  (#2050), and main gained 53 commits between the two. They changed the measured crates
  substantially: 104 files across `arkdeck-agentd`, `arkdeck-hoststore`, `arkdeck-platform` and
  `arkdeck-control`, plus one line in `arkdeck-soak` (#2020). So this capture certifies the
  `9c58e484` daemon, the way SPK-1's certifies the Swift daemon of 2026-09-04, and not today's main.
  Nothing in `scripts/bench` changed on main over that range.
- Harness: `scripts/bench` at tree `ceaadf30`, this PR's final harness. It was committed and clean at
  the start and at the end of the capture; the driver logged the tree and `git status` both times.
- Readiness pins of TASK-XPA-025, instantiated at `6cf99fb6`, compared with their values at the base:
  - `.github/workflows/rust-perf.yml`: pinned `c4c5f85e`, now `9201f1a3`, moved by this task's #1979.
  - `scripts/bench/harness.py`: pinned `1a8d6587`, now `9ddb49e8`, moved by this task's #1972 and #1979.
  - `Packages/ArkDeckKit/Tests/ArkDeckRuntimeSoakFixture/main.swift`: `9784cf7a`, unchanged.

## 2. Already on main, delivered here, remaining

| Already on protected main | Delivered by this record and PR | Still remaining (owner) |
| --- | --- | --- |
| #1972 starts the standalone Rust owner from the benchmark harness. #1977 adds `arkdeck-soak`, which reproduces the Swift soak workload on production Rust owners. #1979 adds `bench capture --runtime-kind rust`, renews the connection every 32 iterations within the 128-frame budget, and makes `rust-perf.yml` build only Cargo products. | The first quiet-host, release, three-run capture of the isolated Rust daemon, committed beside this record. Harness fixes: a Rust capture names its own task and spike; gap reasons are stated per daemon; four undeclared legs are now declared; a bounded quiet-host wait before each run. A 30-minute bounded soak, a ten-minute idle resident-set trace and a five-minute control with the capture's own sampler. The soak paragraph of `rust/README.md` and `scripts/bench/README.md`. | Committing a Rust reference baseline in `scripts/bench/baselines/` once the reference host is ruled (maintainer, then TASK-XPA-025). The 14 gap legs (owners in §6). The soak's socket leg, a per-cycle resident-set line and the 24-hour soak on a long-lived runner (TASK-XPA-025, design §I.2 note 3). PR, nightly and soak lanes green on Rust before TASK-XPA-017. The Windows half of TASK-XPA-025, after G5 (r8). §L.1 items 15 and 16 (maintainer). |

## 3. Host and conditions

- Host: Apple M3, 8 cores (4 performance, 4 efficiency), 16 GiB, macOS 27.0 (26A428), with Xcode 27.0
  (27A266a) as the only Xcode. Design §I.2 names Apple M3, 8 cores, 16 GB, macOS 26.6 and Xcode 26.6.
- Python 3.14.7 (Homebrew). The repository pins 3.14.6, which is not installed on this host. The
  harness uses only the standard library.
- Start condition, from the task: no `plan.py`, `cargo test|build` or `xcodebuild` process, and a
  one-minute load average below 4 (cores × 0.5). The harness then checks for load ≤ 4.00 at the start
  of every run. It refuses the whole capture otherwise and writes no document.
- The driver held the shared gate lock from before its quiet wait to the end of every attempt. That
  lock is the `lockf` on the `gate.lock` other sessions queue their repository gates on. Under the
  2026-09-19 verification policy (#2015), targeted checks no longer take that lock. Holding it
  therefore did not stop other sessions' `cargo test` runs, Swift test builds or test binaries. The
  coordinating session arranged the quiet window for attempt 4.
- Background load that was not stopped:
  - Dropbox, 0.25–1.8 cores. The repository, every worktree and every `target/` directory live in the
    Dropbox folder.
  - `dasd`, about one core during attempt 4.
  - WindowServer, `launchd`, PerfPowerServices, Chrome and the Claude desktop app.

## 4. Attempts

The capture needs a quiet host at the start of each of its three runs, which are several minutes
apart.

| Attempt | Judged quiet | Capture started | Outcome |
| --- | --- | --- | --- |
| 1 (2026-09-19) | 21:15:24, load 3.96 | 21:15:38 | Refused at run 0: load 4.10 > 4.00. When the driver judged the host quiet, a test binary under another worktree's `target/debug/deps/` was using 98% of a core. Its command line had no `cargo test`, so the task's process pattern did not see it. |
| 2 | 21:15:54, load 3.80 | 21:16:12 | Refused at run 0: load 10.85. During the 14-second seed preflight, another session started a Swift test build (`run-swiftpm.sh test --filter …`) and a third ran Rust test binaries. |
| 3 | never, 21:17:57–22:30:13 | — | No quiet window. Over 288 load samples 15 s apart, the one-minute load never fell below 4 (minimum 4.23 at 21:30:10). The two-minute checks found no build or test process only three times, at loads of 5.60, 13.61 and 7.43. The driver released the lock at 22:30 as agreed with the coordinating session. |
| 4 (2026-09-20) | 01:26:04, load 3.62 on the second consecutive check | 01:26:04 | **Completed**: three runs, PASS, eligible, exit 0 at 01:36:41. Run 1 waited 25 s for load ≤ 4.00 (`quietWaitSeconds`). Without the bounded wait, the harness would have refused it as it refused attempt 1. |

Attempts 1 to 3 measured nothing: the harness refuses before its first sample and writes no document.
Before attempt 3 the driver's start condition was tightened. Before attempt 4 the harness gained its
bounded quiet wait (§8), and the resource window was set to 180 s instead of the 300 s intended for
attempt 1. Each change came before any run was measured, and the three measured runs share one
configuration.

The start condition for attempt 4 kept the task's thresholds and added a broader process check.
Besides the task's pattern, no `cargo`, `rustc`, `clippy-driver`, `swift-frontend`, `swift-build`,
`swift-test`, `swiftc`, `xctest` or `xcodebuild` process could be running, and nothing could run from
a `target/(debug|release)/deps/` directory. The one-minute load had to be below 4 on two consecutive
checks 15 s apart. (Attempt 3 required 3.5.)

Load while the driver held the lock during attempts 1 to 3. The one-minute load comes from 15-second
samples, plus the driver's own two-minute checks before 20:51. The last column counts the processes
the start condition counted at a two-minute check. Before 21:17:57 that means the task's pattern,
including shell wrappers; after it, the broader check.

| Ten minutes from | One-minute load, min–max | Most build or test processes at one check |
| --- | ---: | ---: |
| 20:40 | 9.49–23.72 | 5 |
| 20:50 | 5.12–19.12 | 8 |
| 21:00 | 5.92–21.66 | 4 |
| 21:10 | 3.89–12.20 | 5 |
| 21:20 | 4.48–40.52 | 3 |
| 21:30 | 4.23–104.48 | 26 |
| 21:40 | 12.93–54.82 | 14 |
| 21:50 | 5.37–209.63 | 17 |
| 22:00 | 42.28–146.62 | 33 |
| 22:10 | 35.53–137.14 | 32 |
| 22:20 | 29.02–109.08 | 16 |

Attempt 4, with every session idle and no build process:

| Period | One-minute load, min–max (15 s samples) |
| --- | ---: |
| 01:23:33–01:26:04, before the capture | 3.68–5.52 |
| 01:26:04–01:36:41, during the capture | 3.53–5.44 |

The lowest one-minute load with no build and no session activity was 3.53. This host's idle floor is
therefore close to the 4.00 ceiling. The harness checks load only at each run's start, so load
between run starts does not affect eligibility. During the capture that load includes the
measurement's own client and daemon.

### Seed preflight

Before attempts 1 and 2 the driver timed two seeds each with the harness parameters
(`--duration-seconds 6 --restart-interval-seconds 1 --jobs-per-cycle 10`). All four made two ten-Job
cycles and left 20 terminal Jobs.

- On the quieter pair the cycles completed at 2.77/6.73 s and 2.73/6.73 s.
- Under the rising load of attempt 2 they completed at 3.17/8.49 s and 3.60/8.84 s.

A third cycle would need the second to finish before 5 s. A single cycle would need the first to take
5 s or more. So every run on this host seeds 20 Jobs, and all three measured runs read back
`jobStoreRowCount: 20`.

## 5. Results

Capture document:
[`spk-11-rust-capture-20260919.json`](spk-11-rust-capture-20260919.json) (schema
`arkdeck-perf-baseline-1.1.0`, generated 2026-09-19T17:36:40Z, SHA-256
`f79f4f9675f6794b7ae2df4a212f2e97ed9bae27256d7a74e23628e4ed0b14f8`). Its fields are
`task: TASK-XPA-025`, `spike: SPK-11`, `toolchain.runtimeKind: rust`, `measuredMetricCount: 10`,
`gapCount: 14` and `unstableMetrics: []`. The command, with the harness's defaults for everything
else (50 cold starts, 1,000 IPC samples, 200 calibration samples, the 6-second seed):

```sh
cd scripts
python3 -m bench capture \
  --daemon ../rust/target/release/arkdeck-agentd \
  --soak ../rust/target/release/arkdeck-soak \
  --runtime-kind rust --build-configuration release \
  --idle-seconds 180 --quiet-wait-seconds 600 \
  --out-dir <scratch directory>
```

| Run | UTC | One-minute load at start / end | Quiet wait | Seeded Jobs | Resident-set release |
| ---: | --- | --- | ---: | ---: | --- |
| 0 | 17:26:05–17:29:29 | 3.62 / 4.43 | 0 s | 20 | not observed (173 samples) |
| 1 | 17:29:54–17:33:17 | 4.00 / 3.91 | 25 s | 20 | not observed (173 samples) |
| 2 | 17:33:17–17:36:40 | 3.91 / 3.79 | 0 s | 20 | not observed (173 samples) |

p50, p95 and p99 are the medians across the three runs of each run's nearest-rank percentile, as in
SPK-1. MB means 10⁶ bytes.

| Metric | n per run | p50 | p95 | p99 | p95 of each run | p95 spread |
| --- | ---: | ---: | ---: | ---: | --- | ---: |
| `daemon.coldStart` (20 Jobs) | 50 | 24.34 ms | 31.42 ms | 60.35 ms | 35.45 / 31.19 / 31.42 ms | 13.58% |
| `ipc.health` (UDS) | 1,000 | 0.0616 ms | 0.1100 ms | 0.1483 ms | 0.1073 / 0.1100 / 0.1102 ms | 2.65% |
| `ipc.jobStatus` (UDS) | 1,000 | 0.3592 ms | 0.5758 ms | 0.9638 ms | 0.5758 / 0.5931 / 0.5727 ms | 3.55% |
| `ipc.jobList` (UDS, 20 rows, page size 50) | 1,000 | 11.85 ms | 15.28 ms | 16.65 ms | 15.36 / 15.28 / 14.97 ms | 2.55% |
| `daemon.residentSetPlateau` | 173 | 16.29 MB | 16.29 MB | 16.29 MB | 16.20 / 16.30 / 16.29 MB | 0.60% |
| `daemon.residentSetSteady` | 173 | 16.29 MB | 16.29 MB | 16.29 MB | 16.20 / 16.30 / 16.29 MB | 0.60% |
| `daemon.idleCpuPercent` | 173 | 0.0% | 0.0% | 0.0% | 0.0 / 0.0 / 0.0% | 0% |
| `daemon.idleThreadCount` | 173 | 2 | 2 | 2 | 2 / 2 / 2 | 0% |
| `daemon.idleOpenFileDescriptorCount` | 173 | 42 | 42 | 42 | 42 / 42 / 42 | 0% |
| `calibration.busyLoop` (not a product metric) | 200 | 1.88 ms | 2.06 ms | 2.21 ms | 2.03 / 2.06 / 2.08 ms | 2.14% |

For cold start, n = 50 means p99 is each run's maximum sample. The largest was 131 ms in run 0, which
is one observation, not a tail estimate. The n = 1,000 rows have genuine p99s.

### The resident set

Within each run the resident set did not move. Its minimum equalled its maximum in all 173 samples:
16,203,776, 16,302,080 and 16,285,696 bytes. The split looks for a single drop of at least 25% of the
running level and found none. So the plateau and steady metrics are the same series, and each run
records `residentSetReleaseObserved: false` and `residentSetReleaseAtSeconds: null`. This is the
harness reporting one observed level. It does not mean a release was averaged in.

### The resident set beyond the capture's window

Two supplementary traces ran after the capture, each on a fresh daemon over a freshly seeded store,
with no other measurement in the process. They are not part of the capture document.

| Trace | Sampler | Window | Resident set |
| --- | --- | ---: | --- |
| [`spk-11-rss-trace-20260920.json`](spk-11-rss-trace-20260920.json), from 01:37:59 | `ps -o rss=` only | 600 s | 16.25 MB until 28.4 s, then 8.55 MB; 8.06–8.14 MB from 217 s; 4.93 MB from 271.5 s; 4.93–4.95 MB to the end |
| [`spk-11-rss-trace-harness-sampler-20260920.json`](spk-11-rss-trace-harness-sampler-20260920.json), from 01:49:26 | the capture's sampler: `ps`, `ps -M` and `lsof` | 300 s | 16.30–16.32 MB until 228.7 s, then 8.14 MB to the end |

The capture's heavier sampler does not suppress the release: the control saw it too. What varies is
when it happens. First releases observed so far: 28.4 s and 228.7 s in these traces, 33 s and 44 s in
two runs of the loaded 2026-09-18 advisory capture, and later than 173 s in all three runs of this
capture. The 600-second trace also shows a second step, so the idle series has at least three levels:
about 16.3 MB at start-up, about 8.1 MB, and about 4.9 MB. The host's memory pressure level stayed at
1 (normal) in both traces, and the daemon held 2 threads and 42 descriptors throughout the control.

Two consequences for the method, for whoever sets the resident-set budget:

- The harness's 120-second default, and the 180 seconds used here, are both too short to catch this
  daemon's release reliably. A capture that misses it reports the start-up level as both metrics, as
  this one does, and says so through `residentSetReleaseObserved`.
- The split takes the largest single drop. Over a window covering both steps, the steady series would
  mix the 8.1 MB and 4.9 MB levels. The design's two-level model fits the Swift daemon's single step,
  not this daemon's two.

On 2026-09-18 an advisory capture ran under load with the earlier binary `b3e143c2…` (#1979 record,
not committed). It saw 15.83 MB fall to about 8.1 MB at samples 44 and 33 in two runs, and no fall in
the third. Tonight's quiet runs, with the current binary, show no such fall. That capture's host was
loaded and its binary was different, so this record does not attribute its fall to the daemon or to
host memory pressure.

### Swift last baseline, kept beside it

`scripts/bench/baselines/perf-baseline-2026-09-04.json` (SPK-1, Swift) is unchanged. It is the
before record of the migration. It was taken on macOS 26.6.2, from a different daemon, on a 30-Job
store. The comparison command refuses the pair in both modes, `ratio` and `absolute`, with exit 1:
every metric is "not comparable, workload scale differs: jobStoreRowCount: 30 vs 20". The comparison
standard is not relaxed. The values below are given side by side as the record the task asks for.
They are not compared: no ratio or improvement is claimed.

| Metric | Swift, SPK-1, 2026-09-04: macOS 26.6.2, 30 Jobs | Rust, SPK-11, this capture: macOS 27.0, 20 Jobs |
| --- | ---: | ---: |
| `daemon.coldStart` p95 | 51.77 ms | 31.42 ms |
| `ipc.health` p95 | 0.1120 ms | 0.1100 ms |
| `ipc.jobStatus` p95 | 0.3661 ms | 0.5758 ms |
| `ipc.jobList` p95 | 13.02 ms | 15.28 ms |
| resident set, start-up plateau p95 | 73.71 MB | 16.29 MB (no release observed) |
| resident set, settled p95 | 21.53 MB | 16.29 MB (no release observed) |
| idle CPU / threads / descriptors | 0.0% / 5 / 15 | 0.0% / 2 / 42 |

## 6. Design §I.2 coverage on the Rust daemon

| Design row | On the Rust daemon |
| --- | --- |
| daemon cold start | Measured: `daemon.coldStart` at 20 Jobs. The row's target scale of 10k stays unmeasured. |
| warm start and recovery | Gap `daemon.warmStartRecovery`: waits for the §L.1 item 13 recovery ruling and a Rust 10k fixture. |
| App time to interactive | Gap `app.timeToInteractive`: needs a device window and the UI lane. |
| IPC, fixed-size replies | Measured on UDS: `ipc.health` and `ipc.jobStatus`. Gap `ipc.xpc`: the XPC leg accepts only the signed App, and Rust's ingress is opt-in. Gap `ipc.namedPipe`: TASK-XPA-002. |
| IPC, paged projection | Measured: `ipc.jobList` at 20 rows. |
| Job event and log stream | Gaps `job.journalAppend` (no timed durable-append leg), `job.eventsPage` (no 1,000-event Job) and `job.eventsWait` (method unpublished). |
| large Artifact transfer | Gaps `artifact.pagedRead` (no large fixture in the lane) and `artifact.open` (method does not exist). |
| 10k journal and history recovery | Gap `daemon.warmStartRecovery`, shared with the warm-start row. |
| idle and busy CPU, RSS, threads, descriptors | Idle measured: CPU, threads, descriptors, and the resident-set plateau and steady level. Gap `daemon.busyResources`: needs a Golden Journey loop. The 24-hour growth target belongs to the soak (§7). |
| cancel and reconcile latency | Gap `job.cancelReconcile`: the harness is read-only, the terminal leg needs a device, and the Rust daemon answers `job.reconcile` as unavailable. |
| Viewer build, search, hit-test, scroll | Gap `viewer.scale`: a maintainer ruling on wall-clock budgets, and the UI lane. |
| UI frame response | Gap `ui.frameResponse`: the UI lane. |
| installer size and update delta | Gap `package.size`: no DMG or MSIX producer. |

The document carries each gap's full reason and blocker. Four rows have measurements, as in SPK-1.
The gap list is longer than SPK-1's ten because §8 declares four legs the SPK-1 document omitted.

## 7. Soak: `arkdeck-soak` reproducing `ArkDeckRuntimeSoakFixture`

`rust-soak-run.md` (#1977) records what the reproduction covers and what it leaves out:

- The same ten-Job cycle: eight immediate successes, one never-started cancellation, and one clean
  preflight Job retained for the next fresh owner.
- The same CLI flags and the `arkdeck-runtime-soak/v1` metric fields.
- The same gates: 32 MiB of max-RSS growth and 16 descriptors of growth.
- Production Rust owners behind a simulated provider that spawns no child process.
- One difference: it calls the owners directly, where the Swift fixture goes through its daemon's
  socket.

Every capture run seeds its store with this binary, so each measured run also contains one short soak.
In addition, one bounded soak ran on the same release binary after attempt 3, in a fresh private
`/private/tmp` root that was deleted afterwards. The host was heavily loaded (one-minute load 43–79),
which does not matter here: a soak judges resource growth, not latency.

```sh
arkdeck-soak --state-directory <fresh private tmp root> \
  --duration-seconds 1800 --restart-interval-seconds 60 --jobs-per-cycle 10
```

The soak exited 0 at 23:02:03 on 2026-09-19 after 1,806 s. The final metrics are committed beside this
record as [`spk-11-soak-metrics-20260919.json`](spk-11-soak-metrics-20260919.json), SHA-256
`ec8fbe6e2272ed9c7ad6ef7ff3f66c767129246e33584942fdf2d5d83a4ff9fc`.

| Field | Value |
| --- | ---: |
| cycles (fresh owners) | 25 |
| terminal Jobs | 250: 225 succeeded, 25 cancelled |
| succeeded Jobs with verified Artifact evidence | 225 |
| active Jobs / outstanding cleanup debt | 0 / 0 |
| journals | 500 |
| max RSS at the first cycle / at the end | 12.32 MB / 22.09 MB |
| max-RSS growth (gate 32 MiB) | 9.76 MB |
| open descriptors at the first cycle / at the end (gate +16) | 15 / 15 |
| simulated-provider child processes | 0 |

`maxResidentSetBytes` is `getrusage`'s lifetime maximum, not the current resident set. The Rust
fixture keeps only its latest snapshot. Unlike the Swift fixture, it prints no per-cycle `rssBytes`.
So this run cannot tell a steady per-cycle climb from a single peak, such as the final pass that reads
back all 250 Jobs and their Artifacts. A per-cycle resident-set line, like the Swift fixture's, would
settle it. This was a bounded 30-minute run, not the 24-hour soak.

## 8. Harness changes in this PR

- **A Rust capture now names its own spike.** Every capture used to say `task: TASK-XPA-023` and
  `spike: SPK-1`. So the 2026-09-18 Rust capture of #1979 carried the identity of the Swift baseline it
  is meant to sit beside. A Rust capture now says `TASK-XPA-025` / `SPK-11`, and a Swift capture keeps
  `TASK-XPA-023` / `SPK-1` (`baseline.document_identity`).
- **Gaps are stated for the daemon measured.** `metrics.gap_definitions(runtime_kind)` gives each row
  the reason that holds for that daemon.
  - On Rust, 10k recovery and `job.reconcile` wait for §L.1 item 13. On the release build, the Rust
    daemon answers `job.reconcile` with "unavailable in the read-only Rust foundation".
  - Rust's XPC ingress is opt-in.
  - The old reason for the cancel row, "published only on protocol 1.x, so a 2.x client cannot reach
    them", described a retired protocol split. Single v1 publishes both methods. A test now keeps
    retired version strings out of every reason.
- **Four legs the design table names are now declared.** The SPK-1 report found the XPC leg and the
  `job.events` page undeclared. The "Job event/log stream" row also budgets a durable append, and the
  "idle/busy" row notes the busy loop as unmeasured. `ipc.xpc`, `job.eventsPage`, `job.journalAppend`
  and `daemon.busyResources` are now declared for both daemons, so the document lists 14 gaps instead
  of 10.
- **A bounded wait for a quiet host before each run** (`--quiet-wait-seconds`). The default of 0 keeps
  the immediate refusal. Attempts 1 and 4 show why it is needed: the check runs at every run's start,
  and on this host the idle load sits near the ceiling. A run still starts only on a quiet host. Each
  run records the seconds it waited (`quietWaitSeconds`). An advisory capture does not wait. Neither
  the nightly lane's command nor its behaviour changes.
- `scripts/bench/README.md` documents these changes. The harness's unit tests went from 127 to 146.

## 9. Facts for §L.1 items 15 and 16 (no ruling)

- **Item 15, idle RSS.** An isolated Rust daemon on a 20-Job store held 16.20–16.30 MB at idle, as one
  level with no release observed in three 173-second windows. The traces add the settled levels: about 8.1 MB after a
  first release and about 4.9 MB after a second. The first release was seen at 28 s in one trace, at
  229 s in another, and not within 173 s in any capture run.
  Which stage the provisional 64 MiB ceiling bounds, and whether to budget the stages separately,
  remain the maintainer's decision. This record draws no headroom conclusion.
- **Item 16, paged projection.** Every first-page `job.list`, meaning one without a cursor, publishes
  an immutable snapshot document before it answers. `SnapshotPager::page_filtered` calls
  `HostDirectory::publish_document`, which writes a temporary file, `sync_all`s it, renames it and
  `sync_all`s the directory (`rust/crates/arkdeck-hoststore/src/snapshot_pager.rs`,
  `rust/crates/arkdeck-platform/src/host_store.rs`).
  - On Apple targets, Rust's `File::sync_all` is `fcntl(F_FULLFSYNC)`, so each measured `job.list`
    carries two full device flushes.
  - Swift's `RuntimeSnapshotPager` does the same through
    `DurableFileWriter.createOrReplaceAtomically`.
  - At 20 rows (p50 11.85 ms against 0.36 ms for `job.status`), flush latency bounds the page rather
    than per-row projection. One scale still cannot separate the two (design §I.2 note 1).
  - A flush-bound call is also sensitive to other processes' write traffic, which a start-of-run load
    average cannot see.

## 10. Local targeted checks

Under the 2026-09-19 verification policy (#2015) the PR's CI is the unified gate. These ran locally
before the push; log `/private/tmp/arkdeck-spk11-checks-20260920.log`.

| Check | Command | Result |
| --- | --- | --- |
| Harness unit tests | `cd scripts && python3 -m unittest discover -s bench -t .` | exit 0, 146 tests |
| SDD consistency (`openspec/**` and `rust/README.md` changed) | `ARKDECK_PYTHON=<repo>/.venv-sdd/bin/python sh scripts/check-sdd.sh` | exit 0, 0 errors, 0 warnings, 121 acceptance IDs, `check_union_merge: ok` |
| Whitespace | `git diff --cached --check` | exit 0 |
| Lanes CI will select | `python3 scripts/ci/plan.py --repo-root . --base-revision origin/main --head-revision HEAD --merge-base --include-worktree` | Rust lane only; no Swift, App or design-system lane |

This PR changes no crate, so no `cargo fmt`, `cargo clippy` or `cargo test` was needed. The Rust lane
is selected because `rust/README.md` lives under `rust/`.

## 11. CI

PR #2070 on `agent/xpa-025-spk-11-20260919`, merged as `65b2a073` on 2026-09-20T07:18:09Z. Every
check succeeded: SDD Guard `35496107727`, Swift CI `35496107837` (the aggregate that carries the
Rust lane), Performance lanes `35496107734` (the harness unit tests, which a `scripts/bench` change
triggers) and Agent PR `35496107724`. This section was filled by the next slice, as the 2026-09-19
policy allows.

## 12. Not run, and why

- The full local unified gate was not run. The 2026-09-19 verification policy (#2015, `AGENTS.md`)
  makes the PR's CI the unified gate. §10 lists the targeted checks.
- No `cargo clippy` or `cargo test`: this PR changes no crate. The only file under `rust/` it changes
  is `rust/README.md`, and CI's Rust lane covers it.
- The Rust capture is not committed as a baseline in `scripts/bench/baselines/` (maintainer decision 3
  in §13).
- No 24-hour soak, no soak socket leg, no device, no Windows host.
- The 300-second resource window intended for attempt 1 was not used. §4 records the 180-second window
  actually used.

## 13. Maintainer decisions (open)

1. §L.1 item 15, idle RSS: the Rust numbers are in §5 and §9. The stage decision is open.
2. §L.1 item 16, paged projection: one more scale and the flush-bound mechanism are in §9. The budget
   is open.
3. **Reference host and a committed Rust baseline.** This host matches design §I.2's hardware but runs
   macOS 27.0 and Xcode 27.0 instead of 26.6. Two questions depend on that ruling:
   - Can this capture be committed as the Rust reference baseline beside the Swift one?
   - A document in `scripts/bench/baselines/` becomes the nightly lane's comparison reference, because
     the lane takes the last file by name. Should the nightly lane compare against it?

   The harness defaults seed 20 Rust Jobs against Swift's 30. By the comparator's scale rule, a Rust
   baseline and the Swift one will therefore never be compared with each other, which suits a before
   and after record.
