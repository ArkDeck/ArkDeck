# TASK-XPA-019 — App-owned UIDump through the Rust Runtime

Base: protected main `73eeacc99ccabff609f1aded791c7fe6382668bf`.
Branch: `agent/xpa-019-app-job-ingress`. CHG-2026-074, macOS only.

The standalone Rust App ingress now accepts the existing closed App client/operation
pairs for `job.plan`, `job.submit`, `job.run` and `job.cancel`. A successful submission
is the only source of this ingress's runnable ownership. A run consumes that ownership
before entering Control; parallel cancellation remains possible without holding the
gate lock over execution. Every return clears run ownership. Foreign Jobs, failed
submissions, malformed requests, caller authority fields and ownership from a previous
ingress are refused. Runtime capability issuance/consumption remains in the existing
Runtime owners; the App gate grants no execution authority or foreground-console proof.

UIDump previously could not materialize or execute its screenshot/tree file legs.
Diagnostics now uses the existing typed FileAction lowering for capture, readback,
receive and cleanup. The materialized plan binds the host receive root. Publication
checks the landed regular file, size, digest and unchanged inode/timestamps. Screenshots
retain exact bytes; received UI tree JSON uses the existing text redactor. Diagnostics
checks the measured received size against its existing Job byte budget before reading.
Ring-buffered capture remains unavailable until its coverage-anchor implementation exists.

The production Host test exercises the App UIDump envelope through plan, Runtime
admission, run, Job readback, Artifact listing and bounded reads. Its transport identity,
Target and HDC executable are explicit synthetic fixtures. The screenshot is a valid
tiny PNG; the tree's secret is redacted. Missing received files and interrupted capture
park with unknown outcome, remain unknown on durable readback and cannot be rerun by
the App gate. Separate concurrent-owner tests verify cancellation and foreign-Job refusal.
Independent test roots use distinct request identities so their deterministic Job IDs
do not share the Provider's host landing. No raw real-device operation was executed.

## Signed-App integration contract

The existing isolated daemon startup contract is unchanged: a private physical
`ARKDECK_DEVELOPMENT_STATE_ROOT`, its directly contained control endpoint, no Swift
facade, and `ARKDECK_APP_INGRESS=history` activate the fixed `com.arkdeck.agentd` Mach
service. The fixed App signing requirement is team `8AQTYW5FKR` and identifier
`com.arkdeck.desktop`; the authenticated kernel UID must match the daemon owner.
The activation value is retained for compatibility despite the expanded method set.

Device-mutation admission in this development composition additionally requires the
existing acknowledged `ARKDECK_DEVELOPMENT_MUTATION_AUTHORITY=acknowledged` and
`ARKDECK_DEVELOPMENT_HDC_SERVER=managed`, with the explicit verified development HDC
path. These controls are unchanged; this patch does not provision a service, replace
the installed Runtime, populate Target facts or grant a hardware acceptance window.
App integration must run where the fixed Mach service is free of the installed facade.
The separately owned signed App harness and UI acceptance are not changed here.

## Local targeted checks

Rust uses `CARGO_BUILD_JOBS=2` and
`CARGO_TARGET_DIR=/private/tmp/arkdeck-1330-rust-target`; all Cargo commands use
`--manifest-path rust/Cargo.toml`.

- `cargo build -p arkdeck-cli`: exit 0, prerequisite for daemon process tests;
  `/private/tmp/arkdeck-app-job-cli-build.log`.
- `cargo test -p arkdeck-hoststore -p arkdeck-agentd -p arkdeck-soak`: exit 0,
  562 passed, 14 existing environment-dependent tests ignored;
  `/private/tmp/arkdeck-app-job-all-tests.log`.
- After the final duplicate-submit guard and artifact/reopen assertions,
  `cargo test -p arkdeck-agentd --bin arkdeck-agentd app_ingress`: exit 0,
  13 passed, none ignored; `/private/tmp/arkdeck-app-job-tests.log`.
- `cargo clippy -p arkdeck-hoststore -p arkdeck-agentd -p arkdeck-soak --all-targets -- -D warnings`:
  exit 0; `/private/tmp/arkdeck-app-job-clippy.log`.
- `cargo fmt --all --check`: exit 0; `/private/tmp/arkdeck-app-job-fmt.log`.
- `sh scripts/check-sdd.sh`: exit 0; `/private/tmp/arkdeck-app-job-sdd.log`.

The live-reopen test initially hit the store's exclusive owner lock; the final test
releases its actual owner before reopening. The earlier parallel fixture landing
collision was corrected by distinct request identities, without sleeps or relaxed
assertions. The missing-file and process-signal unknown assertions remain strict.
No contract inputs changed, so generation was not run. The read-only process parity
script was inspected: this change does not alter its unconfigured-HDC host behavior
or command expectations. Existing affected corpus/process suites above ran. No Swift,
App build, signed Mach IPC, hardware, performance soak or full unified gate ran locally;
the soak crate's ordinary tests do not constitute performance acceptance.

## CI

Pending automatic PR. Skipped lanes are not counted as passed.

## Remaining

This proves an executable pure-Rust UIDump path in an isolated synthetic environment,
not signed Mach IPC, a physical capture or REAL_DEVICE_PASS. The occupied installed
Mach service still requires the separately owned signed-App environment/harness.
Current protected-main deployment, trusted physical USB relations, GJ acceptance and
safe unique-authority cutover remain outstanding. No G5 completion is claimed.
