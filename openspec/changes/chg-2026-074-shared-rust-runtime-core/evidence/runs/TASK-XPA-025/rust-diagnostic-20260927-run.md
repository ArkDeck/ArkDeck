# TASK-XPA-025 — current-main release diagnostics

Source main: `82f0971ce5f122bde47d9cd850f6df4e0b277da1`.
This is a real isolated-daemon verification and an interrupted diagnostic,
not a baseline, performance pass or task/G5 closure. The prior 30 recovery
samples and all prior unstable measurements remain unchanged.

## Build and Local targeted checks

`CARGO_TARGET_DIR=/private/tmp/arkdeck-xpa025-recovery-target CARGO_BUILD_JOBS=2
cargo build --locked --release --manifest-path rust/Cargo.toml
-p arkdeck-agentd -p arkdeck-soak`: exit 0, 1m27s.
Log: `/private/tmp/arkdeck-xpa025-release-20260927.log`.
Source/configuration/toolchain and binary SHA-256s are in
[rust-diagnostic-build-20260927.json](rust-diagnostic-build-20260927.json).
The provisioned build-local-helpers output is Debug and was not used.

`PYTHONPATH=scripts BENCH_TEST_DAEMON=<private target>/release/arkdeck-agentd
BENCH_TEST_SOAK=<private target>/release/arkdeck-soak python3 -m unittest -v
bench.test_recovery.RealDaemonRecoveryTests`: exit 0, 2 tests, 2.027s.
Log: `/private/tmp/arkdeck-xpa025-real-daemon-20260927.log`.
Both tiny workloads, corrupt-journal rejection and process/root cleanup passed.
These 20-item correctness fixtures do not replace the 10k performance samples.

## Fixed diagnostic attempt 1

The predeclared diagnostic uses one independent run, 50 cold starts, 1,000 IPC
iterations, 600 seconds idle, 200 calibration samples, a 2-second seed with
10 Jobs/cycle and the existing one-second restart interval. It calls
`metrics.execute_run` with runtime_kind rust, require_quiet true, no recovery
leg, and appends every observation. It never produces a baseline candidate.

After the build, the first quiet check read load 4.52 and refused. A bounded
15-second preflight loop retained every subsequent check in
[rust-diagnostic-preflight-20260927.jsonl](rust-diagnostic-preflight-20260927.jsonl).
At 03:48:51 UTC load was 3.7793 with zero conflicting build processes.
The diagnostic began at 03:49:04 UTC with load 3.9565. After seeding, before
its first cold start, load rose to 4.60 and the guard refused. Exit 1;
**zero cold-start, IPC and RSS samples**. The FAILED HostTooBusy attempt is
retained in [rust-diagnostic-attempt-1-20260927.jsonl](rust-diagnostic-attempt-1-20260927.jsonl).
Calibration/seed work is not substituted for a completed diagnostic.

A read-only process check immediately afterward showed system `dasd` about
93.2% CPU and `ANECompilerService` about 91.6%, with additional system activity.
This is evidence of environmental load, not attribution of any product latency.
No system service was terminated and no threshold was relaxed. The diagnostic
process exited, the temporary Runtime root was removed in finally, and the
local window was explicitly released to the coordinator. A later attempt must
retain this failure and obtain a new coordinated quiet window; it cannot be
presented as the only attempted run.

## CI

The measurement implementation was reviewed and merged by the coordinator in
PR #2274, merge `82f0971ce`. Corrected implementation head `0e9f0ee20` passed
harness `36291854558`, guard `36291854556`/`36291877285`, and swift aggregate
`36291854682`. Those results do not turn this interrupted local diagnostic into
performance qualification. Formal three-run cold/RSS measurement remains pending.
