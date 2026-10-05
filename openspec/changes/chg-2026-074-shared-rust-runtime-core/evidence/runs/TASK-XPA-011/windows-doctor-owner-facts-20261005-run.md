# Windows doctor reads its composed owners

Date: 2026-10-05. Task: TASK-XPA-011. Base: protected main
`e957da597d23c001157a05c7ba0a8ce1b3d38d3d`. This is software regression evidence;
no Journey or hardware acceptance is claimed.

The installed Windows daemon's deep doctor reported an unconfigured Artifact store,
unconfigured discovery and unreadable cleanup debt before any device Job was dispatched.
The Windows composition already opened these owners. `Host::doctor_facts` read their
quota, cleanup, unreadable-record and recovery facts only on macOS; Windows returned
default missing-owner facts and checked only the standalone read-only provider for
discovery, ignoring its composed HDC and Target owners.

The existing owner adapter now runs on both macOS and Windows. It reads actual quota,
ledger and recovery facts and preserves the shallow/deep distinction. Other platforms
retain the previous fallback.

Review also identified an existing macOS adapter error that this port would expose on
Windows: `.ok()` discarded a failed durable Job index census. The internal owner fact
now retains `Option<Result<(count, sample), WireError>>`: `None` means not checked or
not composed, and `Err(recordUnreadable)` retains the actual refusal. Following the
current doctor policy that failed deep subchecks remain blocker findings, the report
uses `runtime.durableRecordsUnreadable` with a bounded summary and no invented count.
Underlying error messages are not copied into the report. Published
report/error shapes are unchanged; successful Swift corpus answers remain identical.

The signed private Windows daemon/CLI regression verifies shallow and deep reports,
actual quota accounting, an empty cleanup ledger and the adopted Target count. With
no HDC composed, discovery remains false and `--require-healthy` still returns
`healthRequirementFailed`/69. A malformed cleanup ledger remains unreadable and a
blocker; its bytes are retained. A real unsupported SQLite index layout introduced in
the private fixture after daemon composition reports a blocker on repeated deep reads,
including while cleanup debt remains readable and zero. Standard mode does not read
that census, and doctor leaves the index bytes unchanged. A control regression proves
the same refusal blocks an otherwise-ready report without replacing its other checks.
The discovery unit regression opens the test image as an unlaunched tool and checks
that both HDC and Target owners are required. None of these tests starts HDC, probes
TCP 8710, reads/writes the account Runtime state or touches a device.

## Local targeted checks

Checks use `tools/run_check.py`, `CARGO_TARGET_DIR=D:/cargo-target/doctor-owner`,
`CARGO_BUILD_JOBS=2` and development signer
`AAC23CA4D38D100996C861D9E1A68DEECD69B149`. Cargo build/test/clippy run through
`D:/src/ArkDeck-wt/tools/gate_slot.py`. The controlled native executor runs the signed
fixture; no signer path is skipped.

| Command after the runner | Result | Log under `D:/src/ArkDeck-wt/tools/logs/` |
| --- | --- | --- |
| `cargo build --manifest-path rust/Cargo.toml -p arkdeck-cli` | exit 0, before signed CLI tests | `doctor-owner-cli-build.log` |
| `cargo test --manifest-path rust/Cargo.toml -p arkdeck-agentd --bin arkdeck-agentd doctor_discovery_requires_both_hdc_and_target_owners -- --nocapture` | exit 0; 1 passed, 38 unrelated tests filtered | `doctor-owner-unit.log` |
| `cargo test --manifest-path rust/Cargo.toml -p arkdeck-agentd --test windows_target_owners_process -- --nocapture` | exit 0; 3 passed, 0 skipped/ignored | `doctor-owner-signed-process.log` |
| `cargo test --manifest-path rust/Cargo.toml -p arkdeck-control --test doctor_report` | exit 0; 4 passed | `doctor-owner-control-report.log` |
| `cargo clippy --manifest-path rust/Cargo.toml -p arkdeck-agentd --all-targets -- -D warnings` | exit 0 | `doctor-owner-clippy.log` |
| `cargo build --manifest-path rust/Cargo.toml -p arkdeck-cli` | exit 0, before final signed index-failure regression | `doctor-owner-index-cli-build.log` |
| `cargo test --manifest-path rust/Cargo.toml -p arkdeck-control --test doctor_report` | exit 0; 5 passed, including all recorded Swift reports | `doctor-owner-index-control.log` |
| `cargo test --manifest-path rust/Cargo.toml -p arkdeck-agentd --bin arkdeck-agentd doctor_owner_tests -- --nocapture` | exit 0; 2 passed, 38 unrelated tests filtered | `doctor-owner-index-unit.log` |
| `cargo test --manifest-path rust/Cargo.toml -p arkdeck-agentd --test windows_target_owners_process gj1_target_hops_run_through_the_cli_against_a_dev_signed_daemon -- --nocapture` | exit 0; signed test passed, 2 unrelated tests filtered; no signer skip | `doctor-owner-index-signed-process.log` |
| `cargo test --manifest-path rust/Cargo.toml -p arkdeck-cli --test current_surface` | exit 0; 11 passed | `doctor-owner-cli-surface.log` |
| `cargo clippy --manifest-path rust/Cargo.toml -p arkdeck-control -p arkdeck-agentd -p arkdeck-cli --all-targets -- -D warnings` | exit 0 | `doctor-owner-index-clippy.log` |
| `cargo fmt --all --check --manifest-path rust/Cargo.toml` | exit 0 | `doctor-owner-final-fmt.log` |
| `C:/Program Files/Git/usr/bin/sh.exe scripts/check-sdd.sh` | exit 0 | `doctor-owner-final-sdd.log` |

The coordinator then replaced the new failed-census summary with bounded text,
without copying the underlying error message. Control report tests passed again
(5/5; `doctor-owner-control-summary.log`) and the CLI build passed
(`doctor-owner-cli-summary-build.log`). The first signed rerun failed one stale
summary assertion (`doctor-owner-signed-summary.log`, exit 101); the assertion
now requires the exact bounded summary, while retaining the blocker, no-count,
unchanged checks and original-index-byte requirements. The final signed case
passed (`doctor-owner-signed-summary-final.log`, exit 0). All-target control,
agentd and CLI clippy, full fmt and SDD then passed with exit 0 in
`doctor-owner-summary-{clippy,fmt,sdd}.log`. Earlier logs are preserved.

This increment retains the handover's existing isolated worktree target for its
already-started checks. Integration keeps main's persistent Cargo runner change;
the validation cache is not migrated midway through this run.

The full agentd suite is intentionally unrun during the live device window: its managed
HDC/live lanes may probe the account Runtime's TCP 8710. Targeted private-root tests and
all-target compilation cover this adapter without crossing that boundary. macOS execution
is not available on this Windows host. No contract inputs changed; contract generation is
unnecessary.

## CI

Not run for this local owned commit; integration owns the PR and CI record. Live acceptance
must use the rebuilt protected-main RC after review, CI and merge, then repeat doctor through
the published CLI. This run does not turn the failed installed-doctor window into a pass.
