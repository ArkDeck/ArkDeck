# TASK-XPA-016 — R2 run record: the managed HDC server in the isolated Rust daemon, and its stop

Change: CHG-2026-074-shared-rust-runtime-core@r11. Lane B, R2 of the HDC lifecycle map: the
managed `-m` server (`ManagedHdcServer`) and the commandless identity proof that binds its
listener to its launch (`LoopbackServerLease`), composed into `arkdeck-agentd` as an opt-in of
the isolated owner, with the daemon's stop semantics in the same change. Host measurement only
(POL-VERIFY-001, POL-MODE-001). Base: protected main `05861555` (#2003). No stack.

No Swift source, control schema, corpus, Catalog, entitlement, `openspec/specs` or constitution
change. No device, real HDC, installed state or Swift daemon is used; the HDC is the fake the
provider's own tests compile from C, now shared as `rust/tests/fixtures/managed-hdc/fake-hdc.c`.

## Why

#1994 recorded GJ-1 on the pure Rust daemon as `BLOCKED_BY_PRODUCT_DEFECT`. Its first blocker:
the isolated owner refuses a registered HDC ("a registered HDC needs the existing-server
identity proof"), and nothing in the daemon could give that proof — `ManagedHdcServer` existed
in `arkdeck-provider-hdc` but no composition started it. `runtime.hdc.status` therefore always
answered `unconfigured_status(None)` and `target.availability`'s tool leg was always `absent`.

Starting a server in the daemon was blocked in turn by the daemon's stop (analysis of
2026-09-15): `arkdeck-agentd` handled no signal, so SIGTERM ended it by the default action,
running no destructor, and a `-m` child in its own process group would outlive it holding the
port. (`ManagedServer` has no `Drop` of its own, but its `RunningChild` field's `Drop` already
SIGKILLs and reaps the group — a dropped server leaves nothing; the orphan came only from a
daemon killed without unwinding.)

## What

Swift facts are from `HeadlessHDCServerHost.swift`, `HDCEndpointSelection.swift`,
`HeadlessHDCStatusObserver.swift`, `AgentDaemon.swift` (`drainAndStop`, `encodeToolLeg`) and
`ArkDeckAgentDaemonMain/main.swift` (signal sources, host start, stop order) on the base.

**The opt-in.** `ARKDECK_DEVELOPMENT_HDC_SERVER=managed`, accepted only with
`ARKDECK_DEVELOPMENT_STATE_ROOT` and `ARKDECK_DEVELOPMENT_HDC_PATH` (any other value, or either
missing, fails startup, exit 69). Before the daemon serves, the owner starts the development HDC
as Swift's host starts its executable:

- endpoint as `HDCServerEndpointSelector.select()` with no explicit endpoint — the inherited
  `OHOS_HDC_SERVER_PORT` on `127.0.0.1` (`inheritedEnvironment`), else `127.0.0.1:8710`
  (`default`); a set port outside 1...65535 fails startup (Swift `invalidInheritedPort`).
  `arkdeck_provider_hdc::EndpointSelection`;
- `hdc -s <endpoint> -m` with the port named to it, reachable, `checkserver` exiting 0 with
  agreeing versions, and the listener's owner proved to be this launch by PID, birth, path and
  digest (`ManagedHdcServer::start`, unchanged); a failure fails startup and leaves no child;
- a registered HDC is then accepted — the launch is the identity proof the isolated owner
  lacked — and without the opt-in the refusal stands, message unchanged. Development USB
  relations stay allowed only beside a fixture: with a registered HDC they are refused, since
  they would be a trusted fact about a real device that no physical relation proved.

The dispatch is unchanged: the same `ProcessDispatch` with the inherited port, as Swift's
dispatcher uses `inheritedPortChildEnvironment`.

**What answers from it** (`agentd/src/managed_hdc.rs`, `host.rs`, `arkdeck-control`):

| | Swift | Rust (isolated owner, managed) |
| --- | --- | --- |
| `runtime.hdc.status` | `statusObserver(daemonVersion:)` over `activeLaunch()` (the spawn record while armed, not exited, not stopping) and the host's supervisor | `HdcStatusObserver` over the launch while the server has not ended and is not stopped; no supervisor; `CommandlessIdentity`, `NativeSignature`, `SystemManagedProcess` |
| `daemonVersion` | the bundle's `CFBundleShortVersionString`; `null` for the bare SwiftPM binary | `null` (bare binary) |
| startup diagnostics | `checkserver`'s client/server versions, the selection's endpoint and source, set once | same, set once (`StartupDiagnostics`) |
| `target.availability` tool | `ready` + `toolSha256`, `clientVersion`, `serverVersion`, `endpointSource` from those diagnostics, never refreshed; else `absent` | same: `HostServices::managed_hdc_tool` → `ManagedToolFacts`; hosts without it keep `absent` |
| server ends unexpectedly | watcher → `exit(70)`, launchd restarts daemon and server | see the declared differences |

**The stop** (`arkdeck-platform` `StopSignal`, `LocalListener::{accept_until, stop_listening}`,
`LocalConnection::closer`; `agentd/src/drain.rs`, `main.rs`), for the Rust-serving daemon (the
isolated owner and the standalone composition; the facade path is untouched):

1. SIGTERM and SIGINT are caught once, before anything the daemon owns is started; the handler
   only writes a byte to a close-on-exec, nonblocking pipe. A second signal changes nothing.
2. The accept loop waits on the listener and that pipe together; a requested stop wins and no
   further connection is accepted.
3. Swift `drainAndStop(deadline: 20)`: the listening socket is closed and its own name removed;
   the frames being answered — each counted from a complete frame read to its reply written or
   failed, as `beginRequest`/`finishRequest` — finish; then every registered connection, idle
   ones included, is shut down both ways and the drain's `closing` latch is set; then the loop
   waits for the connections to be let go. A connection's thread waits for the start of its next
   frame on its socket and on that latch together (`LocalConnection::wait_readable`), so the
   drain ends an idle connection whether or not the shutdown wakes a blocked read.
   One 20 s cutoff covers both waits; past it the daemon goes on. A frame arriving during the
   drain is answered, as in Swift. Background Jobs are neither awaited nor cancelled; the App
   ingress is not drained (Swift's XPC listener is not either).
4. The managed server is stopped (TERM to its group, KILL after 0.25 s), `arkdeck-agentd stopped`
   is printed to stdout, and the daemon exits 0.

## Declared differences from Swift

- **Unexpected server end.** Swift fail-stops with `exit(70)` for launchd to restart the daemon
  and its server; that restart and recovery wait for design §L.1 item 13 and are not ported. The
  isolated owner instead refuses every HDC dispatch, before anything runs, once its server is not
  the one launched (ended, a new birth, or no longer the one listener on the endpoint):
  `DispatchFailure::Refused("dispatch refused: …")`, and `mutation_identity_current()` turns
  false. Swift's dispatcher gates on the executable only; without the fail-stop, a later client
  would otherwise bootstrap a server of its own on the endpoint or address one another process
  started there. The status then reports what the observer sees.
- **No supervisor.** Swift's host also confirms its supervisor's health, generation and
  `arkDeckManaged` record at start; the Rust daemon has no supervisor, so ownership rests on the
  launch record alone, which the observer already accepts first.
- **Signals are caught, not ignored.** Swift sets SIGTERM/SIGINT to `SIG_IGN` before starting
  children and never sets `POSIX_SPAWN_SETSIGDEF`, so its children inherit the ignore. A caught
  signal is reset to its default across `exec`, so the Rust daemon's children keep the default
  action (as before this change); `stop_signal.rs` tests it.
- **Lock release order.** Swift lets go of its instance lock at the end of the drain, then stops
  ArkForge and its HDC host. Here the transport directory's lock (`bind_facade`) and every store
  lock go only with the process, after the managed server has stopped, so a successor never meets
  this server on the endpoint.
- **A signal during startup** is acted on once serving starts (drain, stop, exit 0); Swift fails
  its startup (`exit(1)`, racing the handler's `exit(0)`).
- **Idle connections are ended by a latch as well.** Swift relies on `shutdown(SHUT_RDWR)` alone
  to end a connection whose thread waits in `read`. On the macOS 26 CI runner a read blocked on
  a Unix socket was seen not to wake from that shutdown (see the gate section), so the Rust
  daemon also waits on the drain's latch; the shutdown is kept.
- **Control actions.** With the managed server the isolated owner still composes the union
  control-action owner over no HDC owner (#2003): impact-preview/restart stay
  `operationUnavailable`. The HDC control-action owner over this server is the next lane-B slice.

## Tests

- `arkdeck-platform tests/stop_signal.rs` (own binary; the handler is process-wide): a requested
  stop ends `accept_until` and stays requested, a waiting client is never accepted after it, a
  second signal changes nothing, `stop_listening` removes the socket's name; a launched child
  keeps the default SIGTERM; a `ConnectionCloser` ends a read blocked on another thread; a stopped
  facade listener keeps its directory until its `ListenerLock` is dropped.
- `arkdeck-provider-hdc tests/managed_server.rs`: a dropped server leaves nothing on its endpoint;
  the endpoint selection's inherited, default and refused ports. The fake's C source moved to the
  shared fixture; the other five tests are unchanged.
- `arkdeck-agentd` unit: `drain.rs` (a drain waits for the frame being answered, then ends idle
  connections through the latch; a connection's wait sees its next frame, its idle timeout, and a
  set latch first and for good; a drain returns at its deadline with work still running); `managed_hdc.rs` (a plan runs
  while the server is the one launched; after SIGKILL of the server a plan is refused before
  anything runs, the launch is gone from the status, and after `stop` a plan is refused too).
- `arkdeck-agentd tests/managed_hdc_process.rs` (real daemon, real fake server, adoption fixture's
  Target): `runtime.hdc.status` answers the managed server's facts and passes the published
  schema (`identityFamilyUnavailable`, since the fake's digest has no commandless identity family;
  `startupVersions` 3.2.0d/3.2.0d; endpoint and source from `OHOS_HDC_SERVER_PORT`);
  `target.availability`'s tool leg is `ready` with the startup facts; SIGTERM ends the daemon with
  status 0 and stdout `arkdeck-agentd stopped\n` well within 10 s, an idle connection reads EOF,
  the socket's name is gone and nothing listens on the endpoint; a foreign listener on the
  endpoint never becomes the managed server (startup fails, exit 69, nothing left); the opt-in's
  refusals (unknown mode, bad port, no development HDC, no isolated root).

The harnesses that stop a daemon with SIGTERM and `wait()` assert no exit status, and none reads
the daemon's stdout as frames.

## Not run

Any device, real HDC (registered digest), installed Runtime or Swift daemon; the GJ-1 real-device
run (#1994's second and third blockers — a trusted USB relation reader and the maintainer's
choice of the daemon setup before M5 — stand).

## Gate

Unified gate (`scripts/ci/plan.py --merge-base --include-worktree --run-local`, serialized with
every other gate on the host).

First head `f8f05ee0` (origin/main `05861555`):

- r1 (17:42 CST, load 14.9): exit 1 — `arkdeck-provider-hdc tests/lifecycle.rs`
  `a_command_that_changes_nothing_cannot_be_re_proved` found a listener on its endpoint that was
  not its own fake ("no existing selected HDC process owns the exact endpoint"): a port its
  `free_endpoint()` released was taken by another process while other agents' test runs were on
  the host. The test and the lease are untouched by this change, and the binary passed alone four
  times in a row; invalid run. Log SHA-256 `4e3573501c88e9e1407e02bf52017ab542e1e1009938d5b25b1ef79f73cafbeb`.
- r2 (17:47 CST): exit 0 — cargo 950 passed, 0 failed, 16 ignored; read-only and isolated host
  checks PASS. Log SHA-256 `651c0a2d38bee10a60df58b46594044c25e0a878336c048982cb11c9d895a62e`.

CI on that head, pushed as `7a5d52c9` (#2004, run 35435906996): Linux and Windows green; the
macOS 26 Rust workspace lane red in `drain::tests::a_drain_waits_for_the_frame_being_answered_then_ends_idle_connections`,
which waited out the whole 20 s deadline (20.12 s): the thread blocked in `read` on the served
socket was not woken by the drain's `shutdown(SHUT_RDWR)`. It did not reproduce on the macOS 27
development host (40 runs alone, 8 runs of the whole binary). The fix is the `closing` latch
above: a connection waits for its next frame on the socket and the latch together, and the unit
test now drives that wait.

Head `e1a7dff1` (the latch; origin/main `05861555`):

- r3 (18:04 CST, load 5.2): **exit 0** — cargo 951 passed, 0 failed, 16 ignored; the read-only
  and isolated host checks PASS; no Swift lane. Log `scratchpad/logs/managed-hdc-r2-gate-r3.log`,
  SHA-256 `9ccf2b858defd5e27b77891c75817275cb84dd82b07205a791c252b558d40aac`.

Before each gate: `cargo clippy --workspace --all-targets --locked -D warnings` clean for macOS,
`x86_64-unknown-linux-gnu` and `x86_64-pc-windows-msvc`.
