# DevEco registration owner — macOS, 2026-09-11

Final integration base: protected main `b315f371` (99-method Bootstrap contract pin and the subsequent CI cache-only change).

The isolated Rust daemon now owns DevEco registration metadata via the additive
`runtime.tool.register` method. Both Rust and current Swift CLIs submit the typed
DevEco root to that owner. HDC registration retains its existing Swift path.
The request cannot provide a registry path, registration time or trust result.
The owner reads native signed content without executing it, preserves the frozen
Swift key set, uses the shared Bootstrap lock and atomically publishes metadata.
Repeated registration returns the original reference and registration time.
Publication uncertainty is non-replayable and never claims zero host writes.
`newDispatchCount: 0` describes device dispatch only.

The candidate has 100 methods. Its 99 existing method definitions have only the
identity refresh required by the registry addition. Existing non-health corpus
files and the published Rust pin are preserved. Fresh actual Swift producer
recordings cover registration and both current health shapes. See
[producer evidence](deveco-register-oracle-macos-20260911.md).

## Native validation

The standalone harness `rust/scripts/check-deveco-register.py` used release
candidate binaries and `/Applications/DevEco-Studio.app/Contents` as a read-only
native source. It stopped every temporary daemon and retained each registry.

- Rust CLI → Rust daemon: PASS, retained root
  `/private/tmp/arkdeck-deveco-register-q_5muhr2`.
- Current Swift CLI → Rust daemon: PASS, retained root
  `/private/tmp/arkdeck-deveco-register-h6966sja`.
- Each run exercised 6 real CLI commands and 4 direct typed exchanges, including
  first registration, idempotent repeat, restart inspect, restart registration,
  absent content and invalid kind/path refusals. Native signature verification
  completed; no successful content/trust response was substituted.
- Registration completed within the existing production client timeout: Rust
  first/repeat/restart registration took 1.078/1.273/1.565 seconds; Swift took
  0.727/1.417/1.242 seconds. Neither run encountered or retried uncertainty.
- Both runs verified unchanged source role hashes and ancestor identities,
  unchanged installed Bootstrap metadata, and unchanged isolated index bytes,
  inode, mode and timestamps for idempotent/read/refusal calls.
- Frozen Swift decoder and native owner read-back are recorded independently in
  [Swift read-back evidence](deveco-rust-write-swift-readback-macos-20260911.md).

Rust owner tests additionally cover unsafe/missing indexes, held locks, exact
root identity, before-publication external index changes, after-publication
uncertainty and explicit independent re-open, and full-index refusal preserving
all historical records. Control fault tests call the registration owner exactly
once and preserve `outcomeUnknown` when its receipt is malformed, unclassified or
too large for the response frame. These injected negative receipts do not claim
native registration success. Native opt-in tests were actually executed; ordinary
portable runs truthfully skip tests requiring installed signed content. A
synthetic full historical index is quota-only negative input, not native evidence.

## Integration validation

The repository unified gate passed on `f71ff8b8`, including common checks, full
Swift tests, App build-for-testing, Rust workspace/Clippy, published 99-method and
candidate 100-method conformance, real owner process checks, cargo deny and cargo
vet (26 audited). Log: `/private/tmp/xpa012-deveco-register-full-gate-r4.log`.
Recordings: `rust/target/readonly-check/53b8e40a54ae463e92ffe96431adb79c`.
Native harness runs are explicit host checks and are not device acceptance.

Final integration of `b315f371` adds only the Swift CI workflow cache key and its
workflow tests; product and contract inputs are unchanged. Common and workflow
checks were revalidated after integration; the existing functional passes remain
applicable.

Four declared scope extensions cover CLIArgumentParser, CLIBootstrapTools,
CLICommandRegistry and its exported command registry. Existing Task scope covers
all other changes. No installed owner activation, device operation, HDC write,
selection, deletion or Runtime authority migration is included. Remaining host
store writes, installed cutover and GJ-1 acceptance remain TASK-XPA-012 work.

Final unified log SHA-256: `24232116e4ddb129e723ccb57cbe59dd193b97c7fa7004f443921829a3bc3274`.
