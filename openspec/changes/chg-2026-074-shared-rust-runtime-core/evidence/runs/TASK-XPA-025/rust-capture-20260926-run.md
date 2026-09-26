# TASK-XPA-025 — Current-main Rust capture, 2026-09-26

The three-run release capture **did not qualify as a reference baseline**: exit 2,
`spikeVerdict: UNSTABLE`, `baselineEligible: false`. Eight measured metrics were stable;
cold start and settled RSS exceeded the unchanged 30% spread limit. Fourteen legs remain
explicit measurement gaps. No budget or reference-host substitution is approved here.

## Build and scope

The daemon and soak binaries were built from protected main
`bb3b5531c81863e19597eb2a3522545a55cf9057` with `--locked --release`, jobs 2, and the
worktree-private target `/private/tmp/arkdeck-takeover-d79c-target` (exit 0, 1m 33s).
The capture document records both SHA-256 digests. The harness in this change only corrects
obsolete gap explanations: Rust recovery and `job.reconcile` now exist, and macOS UDS
measurements do not cover the Windows named-pipe transport. Sampling, clocks, thresholds
and aggregation are unchanged. A CLI test being authored during capture was not built or run.

The host was arm64, 8 CPUs, macOS 27.0, Python 3.14.7. No build/test process was present at
start, and the one-minute load was below 4 on the two preparatory reads (1.82 and 1.85).
The harness independently admitted all three runs without waiting; their start loads were
2.021, 2.263 and 1.654. The host-version difference from the design reference host remains
subject to maintainer acceptance even if a future capture is stable.

Only isolated temporary Runtime roots were used. The soak supplied simulated, terminal Jobs;
the measurement client submitted no operation and contacted no device. The installed Runtime,
Keychain and LaunchAgent were untouched. This is not real-device evidence.

## Capture

```sh
cd scripts
python3 -m bench capture \
  --daemon /private/tmp/arkdeck-takeover-d79c-target/release/arkdeck-agentd \
  --soak /private/tmp/arkdeck-takeover-d79c-target/release/arkdeck-soak \
  --runtime-kind rust --build-configuration release \
  --idle-seconds 180 --quiet-wait-seconds 600 \
  --out-dir /private/tmp/arkdeck-rust-capture-20260926
```

UTC window: 2026-09-26 11:30:04–11:40:19. All runs used 50 cold starts, 1,000 IPC samples,
200 calibration samples and 20 seeded Jobs. The complete generated document is
[rust-capture-20260926.json](rust-capture-20260926.json), kept beside this record rather
than in `scripts/bench/baselines/`.

| Metric | Unit | Per-run p95 | Spread | Result |
| --- | --- | --- | --- | --- |
| `calibration.busyLoop` | milliseconds | 1.855 / 1.855 / 1.851 | 0.24% | stable |
| `daemon.coldStart` | milliseconds | 31.304 / 47.226 / 80.705 | 104.61% | unstable |
| `daemon.idleCpuPercent` | percent | 0.000 / 0.000 / 0.000 | 0.00% | stable |
| `daemon.idleOpenFileDescriptorCount` | count | 44.000 / 44.000 / 44.000 | 0.00% | stable |
| `daemon.idleThreadCount` | count | 2.000 / 2.000 / 2.000 | 0.00% | stable |
| `daemon.residentSetPlateau` | bytes | 20185088.000 / 20316160.000 / 20348928.000 | 0.81% | stable |
| `daemon.residentSetSteady` | bytes | 20185088.000 / 20316160.000 / 10993664.000 | 46.19% | unstable |
| `ipc.health` | milliseconds | 0.084 / 0.083 / 0.083 | 2.27% | stable |
| `ipc.jobList` | milliseconds | 15.465 / 14.945 / 15.489 | 3.51% | stable |
| `ipc.jobStatus` | milliseconds | 0.429 / 0.415 / 0.421 | 3.28% | stable |

The first two resource windows observed no release, so both RSS fields describe their
startup plateau. Only run 3 observed the release, at sample timestamp 101 seconds; its
settled RSS was 10,993,664 bytes versus 20,185,088 / 20,316,160 bytes in runs 1 / 2. This
is a difference in observed residency phases, not evidence of a leak. Longer traces are
needed before claiming a repeatable settled level. Cold-start spread is also unresolved;
stable calibration and IPC alone do not establish its cause. No samples were discarded,
no thresholds were relaxed, and there was no retry to select a passing result.

## Local targeted checks

- `python3 -m unittest bench.test_baseline bench.test_compare bench.test_harness` from
  `scripts`: exit 0, 151 tests; `/private/tmp/arkdeck-reference-harness-tests.log`.
  The initial sandboxed run exposed one stale gap-text assertion and denied `ps`; after
  updating the assertion, the rerun used read-only process sampling permission.
- Release build: exit 0; `/private/tmp/arkdeck-rust-reference-build.log`.
- Capture: exit 2 (recorded instability); `/private/tmp/arkdeck-rust-reference-capture.log`.
- `sh scripts/check-sdd.sh`: exit 0, 121 acceptance IDs;
  `/private/tmp/arkdeck-reference-capture-sdd.log`.
- `git diff --check`: exit 0.

## CI

No PR or CI run exists for this slice. Remote push was rejected by automatic approval
review pending explicit authorization for the GitHub destination. This record does not
close TASK-XPA-025, G5 or the macOS cutover.
