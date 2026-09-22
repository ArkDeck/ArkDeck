# TASK-XPA-014 — Rust confirmed HDC restart execution and ownership transfer

Base: protected main `d4b56cb6b` (#2104), verified on 2026-09-22 after the
maintainer merged the console/receipt/recovery slice. This continues the
ADR-0009 item 13 port on macOS. No new Catalog operation, device authority,
platform exception or completion status is introduced.

The production Host now consumes a foreground console's HDC approval through
the union control-action owner, using the same managed-server impact source as
preview and restart. An absent managed server, Job owner or source still
refuses before receipt. The durable owner keeps Job admission frozen across
fresh impact, receipt, intent, command, launch marker, process execution and
terminal reconciliation/recovery.

The managed host runs the existing `PreparedLifecycle` verified process
primitive with the typed restart argv. It reproduces the accepted canonical
Supervisor scope, records preview/confirmation/intent in order, rechecks the
owned server after intent persistence and again at the launch lease, and persists actual command and inode
identity before entering the runner. The process outcome must establish a
strictly newer generation. Terminal reconciliation records the historical and
outward outcomes before the shared Supervisor transfers dispatch ownership.

After success, ordinary HDC dispatch uses the retained replacement process
identity, rather than the original foreground child's handle. Unknown launch
outcomes leave dispatch unavailable and never fall back to that child. A later
unrelated process at the same endpoint cannot inherit the proof. Status and
impact observations both use the shared Supervisor; impact ownership requires
unchanged, healthy, managed state on both sides of the observation, matching
the kernel-observed generation and exact endpoint. This does not establish
registered health or trusted USB relations by itself.

The process test compiles a fake HDC in a private host directory. It exercises
two successive restarts through the real durable owner and verified runner,
checks follow-up dispatch through each replacement, refuses terminal replay,
and rejects an unrelated newer process. An uncertain process outcome (the fake
emits unregistered stderr) remains unknown, keeps the Job interlock through
the bounded probe, and disables subsequent dispatch. The impact test covers
missing, changed, unhealthy, foreign and endpoint-mismatched Supervisor state.
These are isolated host-process tests, not hardware evidence or REAL_DEVICE_PASS.

Review correction: the Host no longer turns every executor/storage error into
`preAdmission` / zero dispatch. After an executor error, the owner attempts
durable recovery under the Job interlock. A recovered launched action returns
its actual terminal projection (including `outcomeUnknown`, dispatch count 1).
Only a durable pre-launch projection supports the zero-dispatch refusal. If
recovery itself fails, the existing `recordUnreadable` error names the action
for querying, states that the outcome is unknown, and omits zero-dispatch
details. No replay or protocol vocabulary expansion is introduced.

The added production Host/control-route test uses a test-binary-only synthetic
impact source and actual isolated fake processes. At both the post-launch and
pre-reconciliation boundaries it injects a one-shot audit identity failure, and
separately removes record-directory write permission to fail publication and
recovery. It checks the wire response, durable unknown projection when
available, and exactly one lifecycle command even after a repeated resume.
Owner tests also assert zero dispatch at every pre-launch recovery boundary.

Remaining M1 work includes the trusted USB relation source, published Runtime
deployment and startup/exit recovery conditions, CLI foreground interaction
acceptance and formal pure-Rust GJ-1 device acceptance. Shutdown still follows
the existing foreground-host stop behavior; replacement-server lifetime across
a daemon shutdown/relaunch needs explicit recovery validation before cutover.
No installed Runtime or LaunchAgent was changed. M1/G5 remain incomplete.

## Local targeted checks

Checks use `CARGO_BUILD_JOBS=2` and independent
`CARGO_TARGET_DIR=/private/tmp/arkdeck-1330-rust-target`.

- CLI process-test prerequisite build: exit 0,
  `/private/tmp/arkdeck-1330-supervisor-cli-build.log`.
- `cargo test --manifest-path rust/Cargo.toml -p arkdeck-hoststore -p arkdeck-control -p arkdeck-agentd -p arkdeck-soak`:
  exit 0, 573 passed, 0 failed, 14 existing ignored (not counted as passes),
  `/private/tmp/arkdeck-1330-supervisor-tests.log`.
- Final `cargo test --manifest-path rust/Cargo.toml -p arkdeck-agentd managed_hdc::tests`:
  2 passed, exit 0, `/private/tmp/arkdeck-1330-lifecycle-integration-final.log`.
- Shared fixture consumer `cargo test --manifest-path rust/Cargo.toml -p arkdeck-provider-hdc --test managed_server`:
  7 passed, exit 0, `/private/tmp/arkdeck-1330-supervisor-provider-tests.log`.
- Clippy for the four affected/direct-dependent crates with `--all-targets -- -D warnings`:
  exit 0, `/private/tmp/arkdeck-1330-supervisor-clippy.log`.
- `cargo fmt --all --check --manifest-path rust/Cargo.toml`: exit 0,
  `/private/tmp/arkdeck-1330-supervisor-fmt.log`.
- `sh scripts/check-sdd.sh`: exit 0, zero errors/warnings,
  `/private/tmp/arkdeck-1330-supervisor-sdd.log`.

Review-correction checks (same jobs/target configuration):

- `cargo test --manifest-path rust/Cargo.toml -p arkdeck-hoststore -p arkdeck-control -p arkdeck-agentd -p arkdeck-soak`:
  exit 0, 574 passed, 0 failed, 14 existing ignored;
  `/private/tmp/arkdeck-1330-audit-refusal-tests.log`.
- Isolated production Host audit-fault test: exit 0, 1 test covering four
  stage/failure combinations; `/private/tmp/arkdeck-1330-audit-fault-test.log`.
- Clippy for the same four crates (`--all-targets -- -D warnings`), fmt and
  SDD: exit 0; `/private/tmp/arkdeck-1330-audit-refusal-clippy.log`,
  `/private/tmp/arkdeck-1330-audit-refusal-fmt.log`,
  `/private/tmp/arkdeck-1330-audit-refusal-sdd.log` (zero errors/warnings).

No complete local unified gate, RSS/performance measurement or device run was
performed. Successful soak crate unit tests do not clear the RSS soak failure.

## CI

#2105 initial head `53593558` passed all four selected Rust jobs and the
`swift` aggregate in run `35699894384`; Guard `35699894153` and `35700012713`
passed. App, Swift tests and design-system interactions were skipped. The
review correction above requires a fresh CI run after push; this earlier green
run does not validate that correction or constitute maintainer approval.

The preceding #2104 passed all selected Rust
jobs and the `swift` aggregate in run `35697917453`; Guard `35697917287` passed.
App build, Swift tests and design-system interactions were skipped in that run.
The independent #2103 UI-only run `35695961440` completed successfully with
`ui-tests` actually executed; this clears its presentation-boundary regression,
not signed-App-to-independent-Rust hardware acceptance.
