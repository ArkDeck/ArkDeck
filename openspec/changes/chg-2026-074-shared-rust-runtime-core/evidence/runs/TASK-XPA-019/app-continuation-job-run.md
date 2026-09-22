# TASK-XPA-019 — fresh App workspace continuation through Rust

Base: protected main `86434afd82bfc0417447a2b50407d31205311f8c` (#2114,
including the App Job ingress in #2113).
Branch: `agent/xpa-019-app-continuation-jobs`.

ClientKit's `RuntimeWorkspaceContinuation` uses the distinct client name
`arkdeck-overview-continuation`; the new standalone App Job gate did not admit that
client, so a fresh continuation request was refused after the App's source checks.
The gate now accepts this exact client for `observe.device@1` and
`capture.diagnostics@1`, with the existing source provenance and a binding revision.

Only validated host-only/read-only requests enter Control. Classification reuses the
JobPlanner's existing Catalog lookup, input validation and effective-effect resolver;
there is no copied step-selection algorithm. Selected screenshot, component-tree and
trace mutations are refused before Control. Nonempty historical capture markers,
missing source/binding, invalid inputs, other operations and other versions are refused.
The source provenance remains an audit label; it grants no authority or historical plan.
The normal Runtime owns current binding/facts, admission, execution and idempotency.

Production Host tests use the exact continuation client and provenance, execute fresh
observation and read-only diagnostic Jobs through the synthetic HDC, then read Job
status and published Artifacts through the App ingress. A stale binding is rejected
without an HDC call. An interrupted observation parks with unknown outcome, survives
store reopening and is not replayed even if a caller explicitly resubmits the identical
request. App one-shot ownership and refusal of Jobs submitted outside this ingress
remain covered. The App consumer's status parsing is separately owned; no Swift or
ClientKit file is modified here.

These are synthetic peer/Target/Provider integration tests, not signed Mach IPC,
physical-device acceptance or REAL_DEVICE_PASS.

## Local targeted checks

Cargo uses `CARGO_BUILD_JOBS=2`,
`CARGO_TARGET_DIR=/private/tmp/arkdeck-1330-rust-target`, and
`--manifest-path rust/Cargo.toml`.

- `cargo test -p arkdeck-agentd --bin arkdeck-agentd app_ingress`: exit 0,
  15 passed; `/private/tmp/arkdeck-app-continuation-tests.log`.
- `cargo test -p arkdeck-hoststore -p arkdeck-agentd -p arkdeck-soak`: exit 0,
  564 passed, 14 existing environment-dependent tests ignored;
  `/private/tmp/arkdeck-app-continuation-all-tests.log`.
- `cargo clippy -p arkdeck-hoststore -p arkdeck-agentd -p arkdeck-soak --all-targets -- -D warnings`:
  exit 0; `/private/tmp/arkdeck-app-continuation-clippy.log`.
- `cargo fmt --all --check`: exit 0; `/private/tmp/arkdeck-app-continuation-fmt.log`.
- `sh scripts/check-sdd.sh`: exit 0; `/private/tmp/arkdeck-app-continuation-sdd.log`.

No contract input changed, so generation was not run. No Swift/App, signed Mach,
physical-device, performance or local unified-gate check ran for this slice.

## CI

Pending automatic PR CI. No skipped lane is a pass.

The independent inventory-memory candidate is PR #2116 at
`b2625a4b32063cd07962e741c00772263c9eb4a4`. Its unchanged four-hour/300-second
hosted soak was dispatched as run `35713299790`; harness-tests passed and the soak
job started its build, while nightly was skipped. No soak success is claimed here.

## Remaining

Signed App acceptance still needs the fixed Mach service in a suitable isolated
login environment. Continuation uses a new request; it is not recovery authorization
for a historical uncertain intent. G5 and the formal pure-Rust GJ acceptances remain open.
