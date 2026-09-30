# TASK-XPA-025 — the soak and the bench harness run on Windows (WM6, enablement only)

Date: 2026-09-30. Change: CHG-2026-074-shared-rust-runtime-core. Slice Q1 of the Windows phase
(`docs/design/cross-platform/windows-phase-agent-prompt.md` WM6: "性能：让 `scripts/bench` 和 soak
能在 Windows 上跑起来；正式测量属于阶段 A 的参考主机"). Branch
`agent/xpa-025-windows-soak-bench-20260930`, developed on `main` `544cc934` and rebased onto
`b20827ab` (#2344, the client-started Windows daemon). Host: the maintainer's
Windows 11 x64 reference host (build 10.0.26200, 16 logical CPUs), rustc 1.98.1, Python 3.14.7
(`$ARKDECK_PYTHON`). No device, no installed Runtime, no elevation, no system change.

**This is enablement, not measurement.** The host was not quiet (other agents were building; the
load figure was 4.8–9.7 CPUs busy during the runs). The smoke runs below show that each leg runs
to completion and writes its documents; none of their numbers is a Windows measurement, and none
may be read against a budget of design §I. Formal Windows measurement belongs to phase A on a
quiet reference host, and no Windows baseline is committed here.

## 1. What changed

### Rust soak (`rust/crates/arkdeck-soak`)

- The crate builds on Windows. The macOS workload moved unchanged from `lib.rs` to `owners.rs`
  (its three sibling modules are now its children); `lib.rs` keeps what both platforms share: the
  command line, the `arkdeck-runtime-soak/v1` document, the growth gate, the continuous-clock
  pause. macOS behaviour is identical: same workload, bounds, output and document bytes (the four
  new optional fields are skipped when absent, and only Windows sets them).
- `pipe_cycle.rs` is the Windows workload. Each cycle binds a private
  `\\.\pipe\arkdeck-soak-<run>` with `FILE_FLAG_FIRST_PIPE_INSTANCE` (so a generation that did not
  release every instance fails the next bind), serves the shared `arkdeck_agentd::serve_control`
  loop on the binding thread (a Windows listener is not `Send`, as in the daemon), and makes
  `--jobs-per-cycle` connections with the production `Client::connect_bounded`, which checks the
  pipe owner, the server's image path and its Authenticode signer as the CLI checks an installed
  daemon. The soak is its own server, so it runs as a copy signed with the host-trusted
  development certificate and reads the pin from `ARKDECK_SOAK_SIGNER_SHA256`; without it it
  refuses before creating anything. There is no switch that skips the check.
- **What is not ported, and why.** The Job owners, journals, SQLite repository and Artifact store
  the macOS workload drives are macOS-only in `arkdeck-hoststore` until the Job store reaches
  Windows (G01). The reason for that gate is not gone, so it stays: on Windows each exchange is a
  verified health handshake followed by a `job.list` the owner-less host refuses (`rejected`); the
  document says `workload: windows-pipe-transport/v1`, counts `transportExchangesThisCycle`, and
  reports zero Jobs rather than inventing any. `--seed-recovery`, `--measure-journal` and
  `--seed-artifact-bench` are refused on Windows with that reason.

### Windows resource counterparts (T1: same growth semantics, not the same numbers)

`arkdeck_platform::self_resources` now has a Windows implementation, and `SelfMemory` /
`self_memory` add the live figures:

| soak field | macOS | Windows |
| --- | --- | --- |
| `maxResidentSetBytes` | `getrusage` `ru_maxrss` (lifetime high-water) | `PeakWorkingSetSize` (lifetime high-water) |
| `openFileDescriptorCount` | entries of `/dev/fd` | `GetProcessHandleCount` (every kernel handle) |
| `workingSetBytes` | — | `WorkingSetSize` |
| `privateBytes` | — | `PrivateUsage` |

The gate is unchanged in meaning on both: growth of the high-water mark over the first cycle's
reading ≤ 32 MiB, and growth of the descriptor/handle count over the first cycle's reading ≤ 16.
The counts are never compared across platforms. `ContinuousInstant` has a Windows implementation
(`GetTickCount64`, which counts through sleep and hibernation), as the pause's budget requires.

### Bench harness (`scripts/bench`)

`windows_host.py` holds each Windows counterpart (stdlib `ctypes`/`_winapi` only) and names it in
the document:

- clocks: continuous = `QueryInterruptTimePrecise`, awake-work =
  `QueryUnbiasedInterruptTimePrecise` (REQ-NFR-001 semantics, recorded in `clocks`);
- quiet host: Windows has no load average; the figure is the CPUs kept busy over one second
  (`GetSystemTimes`), held to the same ceilings (`loadSource` in the host facts); conflicting
  builds by image name, and for Python the process's own command line (`plan.py`);
- transport: the daemon's named pipe, found in the development root's `instance.json` at the
  first start and waited for with `WaitNamedPipe` afterwards; every connection checks that the
  pipe's server process (`GetNamedPipeServerProcessId`) is the daemon the harness started; stop
  sets the daemon's named stop event (a drain, as `SIGTERM` is on Unix) and only falls back to
  terminating it;
- rows: `ipc.namedPipe` (health round trip over the pipe), `daemon.idleHandleCount`,
  `daemon.idlePrivateBytes`; the resident set is the working set; `ipc.health` and
  `daemon.idleOpenFileDescriptorCount` stay rows, as gaps naming their Windows counterparts;
  `ipc.jobList`/`ipc.jobStatus` and the recovery, journal, artifact and cancel rows are gaps with
  the G01 reason, and those opt-in legs are refused before a run starts;
- archive: the same `arkdeck-perf-baseline-1.1.0` document and raw JSONL, with a host tag
  (`hostTag: windows-amd64`, Windows only), `captureOnly: true` and `baselineEligible: false`.
  `select-baseline` and `compare` refuse a capture-only document on either side, so nothing
  compares against or gates on a Windows capture until phase A commits a Windows reference
  baseline;
- privacy: the identity gate also refuses a Windows `<drive>:\Users\<name>` profile; a failed
  Windows start keeps the daemon's bounded output with the root, profile and SIDs redacted.

The macOS/Linux paths are unchanged: the same definitions, gaps, host facts, clocks, transport
and raw records (`metric_definitions(False)` is `METRIC_DEFINITIONS`).

`.github/workflows/rust-perf.yml` is **not** changed: no Windows job is added and nothing gates on
Windows. A Windows lane, when one is added, archives only.

## 2. The macOS soak test flake (#2338, #2344)

`tests/workload.rs::the_existing_benchmark_socket_path_boundary_remains_valid_for_seeding` failed
twice on macOS CI with `soak resource growth exceeded: RSS … / 33554432, descriptors 24 / 16` and
passed on rerun.

**Root cause.** The gate reads process-wide counters: `ru_maxrss` and the `/dev/fd` census of the
process that calls `run()`. libtest runs the tests of one integration binary as threads of one
process, and `workload.rs` holds nine tests, several of which call `run()` in-process or hold
descriptors while they work (the full workload's SQLite databases, journals and sockets; the
journal test's child process pipes; the recovery seeds' stores). A workload whose first-cycle
baseline is read while a sibling is quiet, and a later reading while that sibling holds eight or
more descriptors, reports "growth" that is not its own. It is not the other test binaries of the
`shared-resources` queue: Cargo runs test binaries one after another, so only threads of the same
binary overlap. The same holds for the high-water resident set, which a sibling's allocations can
raise.

**Fix, without relaxing the bound.** Every test of `workload.rs` takes one process-wide mutex
(poison-tolerant) for its whole body, so each workload's first and later readings see only
itself. The 16-descriptor and 32 MiB bounds, the workload and the queue are unchanged. Not run on
macOS from this Windows host: the macOS lane of this PR is the check.

## 3. Local checks (Windows host)

All Cargo commands with `CARGO_TARGET_DIR=D:\cargo-target\q1-perf`, `CARGO_BUILD_JOBS=2`.

- `cargo fmt --all --check`: exit 0.
- `cargo clippy --workspace --all-targets -- -D warnings`: exit 0.
- `cargo test -p arkdeck-soak -p arkdeck-platform`: exit 0 (see §5 for the ignored signed leg).
- `cargo test -p arkdeck-soak --test windows_pipe -- --ignored` with
  `ARKDECK_DEV_SIGNER_THUMBPRINT` set: exit 0 — a signed copy completes, stays within both
  bounds, continues its own marked state and refuses a foreign root without touching it.
- `python -m unittest discover -s bench -t .` (`scripts/`): on Linux (WSL Ubuntu 24.04,
  Python 3.12, the CI lane's platform) 262 tests OK, 8 skipped (the Windows API tests). On
  Windows the new `bench.test_windows_host` passes (12 tests, including a pipe round trip, the
  server-process refusal and the counters of the running process); the pre-existing suite
  assumes Darwin/Linux (`AF_UNIX`, `ps`, POSIX clocks) and is not a Windows lane, as before this
  change.
- `sh scripts/check-sdd.sh`, `git diff --check`: exit 0.

## 4. Smoke runs (not measurements)

Executables: release builds of this branch, `arkdeck-agentd.exe`
`ff130adbd6ca804a74592d71307f4fcb1a62d48ed7dedb27823be1f1e4b7786e`, `arkdeck-soak.exe`
`1d488969c96dffc31586863f1f9b157c80d7334179543d29e5de462fa0f9a779` (the soak ran as a signed copy).
Documents stayed outside the repository and are not committed.

- **Soak.** A signed copy with `--duration-seconds 60 --restart-interval-seconds 5
  --jobs-per-cycle 10`: exit 0, 12 generations, 10 authenticated exchanges each, every
  generation drained; the document is `phase: completed`, `workload: windows-pipe-transport/v1`,
  zero Jobs; both growth figures stayed far inside their bounds. The state root was removed.
- **Bench.** `capture --runtime-kind rust --build-configuration release --allow-loaded-host`
  with reduced counts (`--cold-start-samples 20 --ipc-samples 256 --idle-seconds 15
  --calibration-samples 20`, three runs): exit 0; 66 daemon starts on development roots, each
  stopped through its stop event; the document measured the eight Windows rows
  (`daemon.coldStart`, `ipc.namedPipe`, `daemon.residentSetPlateau`, `daemon.idleCpuPercent`,
  `daemon.idleThreadCount`, `daemon.idleHandleCount`, `daemon.idlePrivateBytes`,
  `calibration.busyLoop`) and carries 19 gaps, `captureOnly: true`, `baselineEligible: false`,
  host tag `windows-amd64`; no profile path or user name in the document or the raw log. No
  working-set release was observed in the short idle windows, so `daemon.residentSetSteady` is
  reported not measured, as the rule requires. Verdict `UNSTABLE` on a loaded host, which is
  expected and not an error for an advisory capture.
- **After the rebase onto `b20827ab`** the release executables were rebuilt and the same bench
  smoke repeated: exit 0, another 66 daemon starts and stops, the same eight rows and 19 gaps;
  `cargo fmt`, workspace clippy, `cargo test -p arkdeck-soak` and its signed leg passed again.
  The executable digests above are from before the rebase.
- **Quiet-host gate.** The same capture without `--allow-loaded-host` refused at run start
  (`HostTooBusy`, busy-CPU figure 4.8 against the ceiling 4) and wrote its failure document.

## 5. A defect found and fixed during the smoke

Two earlier smoke captures failed a daemon restart with exit 69. With the daemon's output kept,
the cause was explicit: `the instance document of <state-root> is unusable: … (os error 32)` — a
sharing violation. The first harness version read `instance.json` on every poll of every start;
an open Python handle (no `FILE_SHARE_DELETE`) while a restarting daemon atomically replaced the
document failed that daemon's start. The harness now reads the document only at the first start
on a fresh root (before any daemon has published it, so no replacement can overlap) and waits for
the same pipe name with `WaitNamedPipe` afterwards; 66 further starts completed. This was the
harness's defect, not the daemon's.

## 6. Scope and what remains

- The Windows soak exercises the named-pipe serving/drain path, client identity checks and the
  resource gate. The Job workload (and so journal, recovery and Artifact growth) waits for the
  Job store on Windows (G01).
- The Windows capture measures cold start, the named-pipe round trip and the idle footprint of
  the lifecycle-only development root; every Job-store row is a declared gap.
- Phase A: three runs on a quiet reference host, the 30% spread rule, and a committed Windows
  reference baseline before any comparison. `rust-perf.yml` is unchanged.
