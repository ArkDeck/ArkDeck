# TASK-XPA-014 — Rust console approval and durable lifecycle recovery

Base: protected main `c015bd15b` (#2102), following #2101's recorded HDC
lifecycle contract and ADR-0009 item 13's accepted port of the Swift carriers.
The independently reviewed App boundary fix #2103 subsequently merged as
`3ceffd9d0`. This implementation does not complete C2b, M1 or G5.

The Rust daemon now routes `human-action.resume` using foreground-console
identity freshly read from the local socket's peer for each request. Default
control callers and App ingress cannot opt into console origin through frame
parameters. The production Host issues a one-time challenge bound to the
existing approval, immutable preview, generation and expiry. Only its hash is
persisted. The production Host still refuses consumption while the shared
Supervisor and managed-server exit handoff are not composed; issuing a
challenge does not dispatch or confer Runtime authority.

The durable HDC owner now accepts and validates the existing Swift challenge,
receipt and ordered lifecycle audit representations. Its Runtime-only driver
interface consumes the challenge under the final Job admission interlock,
reproduces the complete approved impact and relations, and retains the lease
until terminal reconciliation or interruption recovery. Actual-command
publication re-observes impact and binds the command to the durable intent;
launch-window publication checks the preceding command and inode path.
Receipt ownership and audit prefixes cannot be rewritten by a CAS update.
No RPC accepts audit events, trusted facts or a caller-supplied driver.

Recovery distinguishes all persisted boundaries: an approval before intent is
invalidated, an intent without a launch marker fails with zero dispatch, and
a launch marker without terminal reconciliation becomes outcome-unknown.
Even a recorded successful process outcome remains historical only after an
interruption; it is not promoted to success without terminal reconciliation.
Neither readback nor reopen replays an unknown effect.

Verification uses synthetic host-only impact and driver events. The production
Host test reproduces the complete committed Swift console-challenge response,
checks ordinary and forged origins, and verifies that an unconfigured executor
writes no receipt. Boundary tests exercise normal driver failure and injected
unwind followed by a new Runtime epoch, receipt/audit corruption, competing
interlocks, replaced/wrong/expired challenges, and drift before receipt and
again before actual-command publication. These are not hardware evidence.

Still required: the accepted shared Supervisor, lifecycle executor composition,
managed-server confirmed-exit/replacement ownership, trusted USB relation
source, and published Runtime deployment conditions for formal GJ-1 acceptance.
No installed Runtime, LaunchAgent, capability records or hardware evidence was
changed. The next slice must connect the validated durable chain to the existing
verified process primitive before enabling console consumption.

## Local targeted checks

All Rust checks use `CARGO_BUILD_JOBS=2` and the independent
`CARGO_TARGET_DIR=/private/tmp/arkdeck-1330-rust-target`.
- `cargo build --manifest-path rust/Cargo.toml -p arkdeck-cli`: exit 0,
  `/private/tmp/arkdeck-1330-c2b-cli-build.log` (daemon process-test prerequisite).
- `cargo test --manifest-path rust/Cargo.toml -p arkdeck-hoststore -p arkdeck-control -p arkdeck-agentd -p arkdeck-soak`:
  exit 0, 570 passed, 0 failed, 14 existing ignored (not passes),
  `/private/tmp/arkdeck-1330-c2b-tests-all.log`.
- After adding the final-impact/interlock assertions, the affected HDC owner
  subset passed all 22 cases (exit 0),
  `/private/tmp/arkdeck-1330-c2b-tests-final-boundaries.log`. The finalized
  production Host challenge test also passed (exit 0),
  `/private/tmp/arkdeck-1330-console-host-test.log`.
- `cargo clippy --manifest-path rust/Cargo.toml -p arkdeck-hoststore -p arkdeck-control -p arkdeck-agentd -p arkdeck-soak --all-targets -- -D warnings`:
  exit 0, `/private/tmp/arkdeck-1330-c2b-clippy.log`.
- `cargo fmt --all --check --manifest-path rust/Cargo.toml`: exit 0,
  `/private/tmp/arkdeck-1330-c2b-fmt.log`.
- `sh scripts/check-sdd.sh`: exit 0, zero errors/warnings,
  `/private/tmp/arkdeck-1330-c2b-sdd.log`.

The first production Host test exposed a missing `phase` in the unavailable
executor error; the Host now returns the accepted `preAdmission` details.
A test initially tried parsing the store lock as JSON; it now inspects only
record files and asserts that exactly one record was examined. Both fixes
were verified by the later passing runs.

No full local unified gate, performance measurement, slow UI rerun or hardware
acceptance was run. Soak crate unit tests do not replace the outstanding
performance/RSS soak acceptance.

## CI

Pending the implementation PR. CI execution and any skipped jobs will be
reported separately; green CI does not supply human approval or hardware PASS.
