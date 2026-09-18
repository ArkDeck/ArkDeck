# Standalone Rust History App ingress — implementation evidence

Date: 2026-09-19. Base: protected-main commit
`1ee1d73ddeffcae6cda7ca49bf57ff22bf89d3d7` (#1974). Scope: macOS,
TASK-XPA-019 / SPK-8, first isolated standalone composition. This is **not**
signed App UI acceptance, installation cutover, Swift retirement or a real-device
result.

## Delivered behavior

- Explicit `ARKDECK_APP_INGRESS=history` selects the restricted App ingress on the
  existing isolated Rust development owner. It requires
  `ARKDECK_DEVELOPMENT_STATE_ROOT` and the existing endpoint-inside-root contract;
  default UDS behavior is unchanged. Unsupported modes, Swift pairing (including
  inferred facade pairing), overridden account home, nonprivate/aliased roots and
  installed ArkDeck state are refused. It does not create a launchd registration.
- The fixed `com.arkdeck.agentd` Mach listener uses the existing platform
  `listen_mach` implementation: same-euid peer check and the exact existing App
  code-signing requirement (team `8AQTYW5FKR`, identifier `com.arkdeck.desktop`).
  No entitlement, signature requirement or platform auth implementation changed.
  Connection identity comes only from the platform callback, never request JSON.
- Only `health`, `history.filter.list`, `history.filter.save`, and
  `history.filter.delete` reach the shared production `Control<Host>`.
  Current wire version/identity, bounded strict JSON, complete closed parameter
  keys and generated schema types are checked before Control. Every other
  published method receives a schema-conforming explicit `rejected` response.
  No Swift forwarding, retry or response cache exists on this route.
- XPC and UDS share the same Control and HistoryStore. Durable generation CAS,
  semantic query validation and unknown-publication outcomes remain owned by
  HistoryStore. App job/import/other resource methods are not migrated or exposed
  by this slice; the existing typed App job and import ownership gates must be
  ported before those methods are enabled.

## Local verification

- `cargo test --offline --locked -p arkdeck-agentd app_ingress -- --test-threads=1`:
  **PASS: 3 unit tests + 1 startup integration test.** Focused tests cover production Host/Control/HistoryStore save, shared Control
  readback, stale-generation refusal, owner close/reopen, delete and persistent
  generation. Startup subprocesses test invalid mode, missing isolated root,
  forbidden Swift pairing and account-home override; they exit before listening.
- Negative ingress tests exercise wrong synthetic euid, absent PID, CLI console
  origin, every other published method, oversized/malformed/duplicate-key frames,
  forged origin fields, wrong protocol version, missing/wrong/extra parameters.
  Refusals show zero Control calls and no owner lock/document creation. This is
  an origin-composition test, **not a live code-signature authentication test**.
- `cargo clippy --offline --locked -p arkdeck-agentd --all-targets -- -D warnings`
  **PASS** (all agentd targets); `cargo fmt --all -- --check` and
  `git diff --check`: **PASS**.
- Unified repository gate remains pending coordination with the parent task.
  A direct system-Python invocation of `check-readonly.py` stopped at missing
  `jsonschema`; it did not run its workload and is not counted as a pass.

Logs: `/private/tmp/arkdeck-app-ingress-tests.log`,
`/private/tmp/arkdeck-app-ingress-clippy.log` (local, not committed).

## Explicit remaining acceptance

No Mach listener was activated by this validation; no launchctl, installed
service, signed sandbox App, HDC or device was used. The available Developer ID
identity does not prove that this composition has passed signed peer admission,
reverse daemon version/signature pinning, interruption UI behavior or SPK-8 UI.

A safe isolated bootstrap namespace must be proved before a live run with the
unchanged App service entitlement. Same-UID gui/user domains share Mach lookup
names; bsexec only adopts a namespace; the SDK marks bootstrap_subset deprecated.
Do not reuse SPK-2's production-service bootout workflow. An independently
isolated macOS login/VM remains an alternative for that future verification.

The final installed Rust owner, release packaging and remaining App facades are
separate incomplete work. No completed SPK-8 or M5 claim is made here.

## Private bootstrap feasibility probe

On 2026-09-19, a separate host-only C probe compiled against the installed
macOS SDK attempted the deprecated `bootstrap_subset` API, using a fresh Mach
requestor port and a random `com.arkdeck.isolation-probe.*` test name. The parent
lookup first returned `1102 (Unknown service name)`. Subset creation returned
`125 (unknown error code)` and the probe exited 5 before any registration. A
second invocation confirmed the same result outside the filesystem sandbox.
No formal ArkDeck service name, launchctl action or installed service was used.

Source: `/private/tmp/arkdeck-bootstrap-subset-probe.c`, SHA-256
`c916d66369e22c176db19542c8ebc81d4beabc85d8fd2e19bf055b338c063eec`;
result: `/private/tmp/arkdeck-bootstrap-subset-probe-result.json`.
The SDK emitted the expected deprecation warnings. This is evidence that this
specific isolation mechanism failed on this host, not a claim that every
possible isolation mechanism is unavailable. A separately proven private
namespace or an independent macOS login/VM is still needed before connecting
the real sandbox App to the fixed service name for isolated acceptance.
