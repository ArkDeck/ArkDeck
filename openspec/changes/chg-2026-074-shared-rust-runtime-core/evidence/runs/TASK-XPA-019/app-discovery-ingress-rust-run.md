# TASK-XPA-019 — Rust App discovery ingress

Base: protected main `780a51a02cf8b542489b7123bf8b5a8fa4e762a3` (#2106, including #2107).
Branch: `agent/xpa-019-app-read-ingress`. CHG-2026-074, macOS App migration.

The signed App transport previously stopped device and Runtime discovery at the
standalone History-only ingress. The existing isolated Rust Mach composition now
forwards five already-published App reads to the same production Control/Host as UDS:
`operation.list`, `target.list`, `device.observations`, `runtime.hdc.status`, and
`runtime.storage.status`. Tool absence, unavailable operations and unconfigured owners
remain the Runtime's actual projections; the ingress adds no fallback or readiness.

The four parameterless methods reject every caller field, including `path` (present
in an old recorded HDC-status request schema). Device observations accept only an empty
request or one complete `following` reference parsed by the existing Target owner.
Retired warm-snapshot fields, caller facts, missing fields, noncanonical/overflowing
generations and unknown nested fields are refused before entering Control. A stale
reference preserves the owner's refusal and is never retried.

The fixed App signing requirement, kernel UID/PID checks, non-console origin, isolated
physical state-root requirement and no-Swift-facade activation remain unchanged. The
existing opt-in value `ARKDECK_APP_INGRESS=history` is retained for compatibility. The
internal ingress type is renamed to reflect its broader read surface. No public wire
schema, Package.swift, Swift App file or LaunchAgent changes.

Tests use production Host projections plus an explicit synthetic observation source
and kernel-origin fixture. Invalid peer/console identities and bad parameters make
zero Control calls. The all-method refusal test still denies every nonallowlisted
method, including Job execution, import mutation and capability/control-action paths.
Existing Artifact owner/sensitive-read and History persistence checks remain intact.
These are isolated host tests, not signed App UI acceptance or REAL_DEVICE_PASS.

## Local targeted checks

Rust commands use `CARGO_BUILD_JOBS=2
CARGO_TARGET_DIR=/private/tmp/arkdeck-1330-rust-target` and
`--manifest-path rust/Cargo.toml`.

- `cargo test -p arkdeck-agentd`: exit 0, 66 passed, none ignored;
  `/private/tmp/arkdeck-app-read-all-tests.log`.
- `cargo clippy -p arkdeck-agentd --all-targets -- -D warnings`: exit 0;
  `/private/tmp/arkdeck-app-read-clippy.log`.
- `cargo fmt --all --check`: exit 0; `/private/tmp/arkdeck-app-read-fmt.log`.
- `sh scripts/check-sdd.sh`: exit 0; `/private/tmp/arkdeck-app-read-sdd.log`.

Checks ran on main `16bcbf0b6` plus this patch. The subsequent fast-forward to
`780a51a02` changed only CLI code/tests and its run record, with no ingress/daemon
intersection; the passed daemon suite was not repeated. No contract inputs changed,
so generation was not run. No App/xcodebuild, live signed IPC, performance/soak or full
unified gate was run locally.

## CI

Pending automatic PR. No skipped job counts as passing.

## Remaining

App-owned typed Job submission/run/cancel and import ownership still need their existing
Swift gates migrated before those methods can be admitted. This slice makes discovery
readable; it does not claim a complete UIDump/Diagnostics journey, production deployment,
signed IPC acceptance, trusted USB discovery, performance acceptance or G5 completion.

Separately, Debug PR #2108's Ubuntu failure in run `35705565526` was fixed in
`f7e5eccde`: the process check now asserts implemented Debug parameter/owner refusals.
Its failed command passed locally (129 control responses/12 CLI envelopes); replacement
CI `35707202311` is running. This branch does not depend on that unmerged implementation.
