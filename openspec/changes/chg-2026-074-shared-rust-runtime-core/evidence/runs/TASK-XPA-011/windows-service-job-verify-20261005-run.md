# Windows persisted Job service verification

Date: 2026-10-05. Task: TASK-XPA-011. Implementation parent:
`68c5e0f093310476b1d019ad1d8628c6af5b1f02`; the parent-owned Doctor test isolation
repair `fe29794cc99979dfa91865a2aa97af96a933e1a5` is also present as local
`e264b9302`. This is software fixture evidence, not a Golden Journey or hardware pass.

GJ-1's published `runtime service verify --job` was parsed on Windows but refused as
`unsupportedOnPlatform`. Windows now reuses the existing macOS persisted Job closure
verifier over one pipe connection whose actual daemon image and signer have been
verified. It only reads `health`, `job.status`, `job.evidence` and `artifact.list`;
it does not start a daemon, create or run a Job, or dispatch a device operation.
Existing status/evidence/Artifact/profile checks and report shapes are unchanged.
No-job Windows identity verification remains unchanged. A requested Job cannot be
verified when the daemon is absent; conflicting execution options remain exit 64.

The signed actual CLI/production-daemon regression uses the recorded Swift
`agent-execution` Job and Artifacts in a private Windows development scope. It verifies
the completed observe receipt and the same report after restart, with the original
Job record, Journal and immutable Artifact bytes retained. A missing Job exits 1
without a report; an untrusted signer exits 69 with `runtimeVerified: false`; a
damaged private Artifact index retains closure blockers and exits 1 without repairing
the damaged bytes; an absent daemon returns false/69 and remains absent. No HDC is
configured, no test probes TCP 8710, and no account Runtime or device is touched.

The Windows runbook's RC replacement instructions also needed correction: a
new-directory RC cannot authenticate a daemon running from the old directory. The
old verified RC's typed `runtime service uninstall` performs the closed-Job preflight
and stop while preserving state; only then are the new RC identity and environment
selected. The first Runtime call starts the new image, whose actual path/hash and
identity are verified. Same-directory configuration-preserving `restart` remains the
GJ-1 durability step. This note does not claim any live replacement or acceptance.

## Local targeted checks

Commands run through `D:/src/ArkDeck-wt/tools/run_check.py` with
`CARGO_TARGET_DIR=D:/cargo-target/service-verify`, `CARGO_BUILD_JOBS=2`, and signer
`AAC23CA4D38D100996C861D9E1A68DEECD69B149`. Cargo build/test/clippy run through
`D:/src/ArkDeck-wt/tools/gate_slot.py`. The owner explicitly selected this independent
candidate target for these checks. The controlled native executor ran the signed
fixture; its signer path was not skipped.

| Command after the runner | Result | Log under `D:/src/ArkDeck-wt/tools/logs/` |
| --- | --- | --- |
| `cargo build --manifest-path rust/Cargo.toml -p arkdeck-cli` | exit 0; before signed process test | `service-verify-cli-build.log` |
| `cargo test --manifest-path rust/Cargo.toml -p arkdeck-cli --test windows_runtime_service` | exit 0; 7 passed | `service-verify-cli-tests-final.log` |
| `cargo test --manifest-path rust/Cargo.toml -p arkdeck-agentd --test windows_artifact_owner_process gj1_artifact_commands_run_through_the_cli_against_a_dev_signed_daemon -- --nocapture` | exit 0; signed test passed, 2 unrelated tests filtered | `service-verify-signed-process.log` |
| `cargo clippy --manifest-path rust/Cargo.toml -p arkdeck-cli -p arkdeck-agentd --all-targets -- -D warnings` | exit 0 | `service-verify-clippy.log` |
| `cargo fmt --all --check --manifest-path rust/Cargo.toml` in the equivalent short source copy | exit 0 | `service-verify-fmt-short.log` |
| `C:/Program Files/Git/usr/bin/sh.exe scripts/check-sdd.sh` | exit 0 | `service-verify-sdd.log` |

The initial CLI regression expected the leaf's conflict wording, but the published
registry refuses each option pair before the leaf. Its assertion was corrected to
the actual pairwise parser diagnostic, retaining exit 64/no output/no start checks
and adding direct leaf rejection coverage. The final seven tests pass.

The native full formatting check exceeded the Windows command-line length limit
(OS error 206; `service-verify-fmt.log`, exit 1). The same command passed in a fresh
`D:/src/ArkDeck-wt/vfmt` copy of all 6,937 tracked Rust files, SHA-256 compared to
the working source before checking and byte-compared afterward. The local helper
is `D:/src/ArkDeck-wt/tools/gj1-review/service_fmt_snapshot.py`. That copy only ran
format checking; no build or test target was moved or shared.

Full CLI/agentd suites are unrun during the live device window; the targeted private
scopes and all-target compilation avoid any real HDC lane. macOS execution is not
available here. No Catalog, control schema, argv corpus, trust or capability input
changed, so contract generation is unnecessary.

## CI

Not run for this owned local increment. Root owns integration, the PR and its exact
head CI record. Live GJ-1 must use the rebuilt protected-main RC after review, CI and
merge. Passing fixtures do not establish readiness or `REAL_DEVICE_PASS`.
