# TASK-XPA-016 — SPK-6 run record: the managed HDC server host

Change: CHG-2026-074-shared-rust-runtime-core@r11. Spike recorded here: SPK-6 (design §J.3), the
server-ownership primitive of lane B after phases 1–4 and the process dispatch (`spk-6-run.md`,
`spk-6-tool-runner-run.md`, `spk-6-shell-channel-run.md`, `spk-6-pty-exchange-run.md`,
`spk-6-process-dispatch-run.md`). Host measurement only — not hardware, platform or conformance
evidence (POL-VERIFY-001, POL-MODE-001). No device was contacted and no HDC executable was
launched: the servers here are shell scripts and a fake `hdc` compiled from a few lines of C.

Base: protected main `3f7e015b` (#1920). Branch `agent/xpa-016-managed-hdc-server-20260914`; no
stacking.

## What was missing

The Rust daemon can prove that an HDC server exists (`LoopbackServerLease`, phase 1) and run one
plan through the verified tool runner (`run_tool`, phase 2; `ProcessDispatch`, #1928), but it
cannot own a server: Swift's daemon launches `hdc -s <endpoint> -m` itself, keeps that foreground
process for its lifetime, and reports `ownership: arkDeckManaged` only when the listener's owner is
the process it launched. Without that, `runtime.hdc.status` on the Rust daemon can never say
`arkDeckManaged`, and the M1 `runtime.hdc.*` methods (lane A) have no server to own.

## What Swift does

`HeadlessHDCServerHost.startInternal` (`DeviceProviders/HeadlessHDCServerHost.swift` 177–297):
`ProcessIdentityBoundRequest` with argv `["-s", <endpoint>, "-m"]` and the endpoint selection's
child environment (`OHOS_HDC_SERVER_PORT` only), no timeout, 256 KiB capture; the spawn observer
records `HDCManagedProcessLaunch` (`HeadlessHDCStatusObserver.swift` 14–34: pid, birth seconds and
microseconds from `proc_pidinfo(PROC_PIDTBSDINFO)`, executable path and digest, argv);
`awaitReadiness` (385–450): a 30 s deadline polled every 100 ms, first the loopback listener must
be reachable by a nonblocking connect (455–487; never `checkserver` first, since an HDC client
bootstraps a competing server when no listener exists), then `hdc -s <endpoint> checkserver` with
2 s must exit 0 with nothing on stderr and parse to agreeing versions, the launched process's exit
throwing at every iteration; then the commandless identity must equal the launch
(`HDCManagedProcessLaunch.matches`: pid, birth, path, digest) and re-verify with the same birth
(`HDCCommandlessServerIdentity.verifiesManagedProcess`). Any failure stops the launch. An
unexpected exit later makes the daemon exit 70 for launchd to rebuild the provider graph
(`ArkDeckAgentDaemonMain/main.swift` 487–497).

## What Rust now does

- `rust/crates/arkdeck-platform/src/managed_server.rs` (macOS): `ManagedServer::launch(tool,
  arguments, environment, capture_bytes)` spawns the verified tool through its retained inode in
  its own group with the runner's environment rules (`validate_environment`, the tool revalidated
  before the spawn), records `ServerLaunch` from the kernel at once (`process_birth`: birth
  seconds and microseconds, plus the canonical executable path, its digest and the argv), and
  captures both streams up to the limit while the rest drains — with no budget. `exit()` says how
  the server ended, if it has; `same_birth()` re-reads the PID's birth; `stop()` ends the group
  (TERM, then KILL) or takes the end it already had, reaps it and returns `ServerStop` (both
  streams, `truncated`, `ServerExit::Exited`/`Signalled`). The capture, poll, finish and drain
  helpers are the tool runner's, shared.
- `rust/crates/arkdeck-provider-hdc/src/managed_server.rs` (macOS): `ManagedHdcServer::start(tool,
  endpoint, StartBudget)` — `StartBudget::default()` is Swift's 30 s / 100 ms / 2 s — launches
  `["-s", "<ip>:<port>", "-m"]` with `OHOS_HDC_SERVER_PORT=<port>`, waits for the listener
  (`TcpStream::connect_timeout` 100 ms), then for `["-s", "<ip>:<port>", "checkserver"]` through
  `run_tool` (2 s, 8 MiB) to exit 0 with an empty stderr and `parse_server_check` agreeing, then
  acquires `LoopbackServerLease` and requires its identity to match the launch (pid, birth, path,
  digest) with the birth read again. `StartFailure::{Refused, Exited, NotReady, Unbound}` carry
  Swift's reasons (`foreground HDC server exited with status N` / `after signal N`, `foreground HDC
  loopback listener did not become reachable before startup deadline`, `checkserver exit=… stdoutBytes=…
  stderrBytes=…`, `managed HDC launch could not be bound to its live process identity`); a launch
  that fails to be ready is dropped, which ends its group. `revalidate()` requires not ended, same
  birth and the lease still valid; `stop()` returns the server's streams and end.
- Not done here, on purpose: the daemon's exit-70 policy and the composition that owns the server
  (lane A's `runtime.hdc.status` slice decides where the server lives and what `ownership`
  reports); Swift's `SystemHDCManagedServerProcessInspector` argv re-read from the kernel
  (`KERN_PROCARGS2`) is not ported — the launch's argv is what this daemon passed to its own
  child, and the listener ownership and birth are re-proved instead.

## Tests

- `cargo test -p arkdeck-platform --test managed_server` (its own binary; it spawns children),
  4/4 in three consecutive runs: a launched script is recorded (pid, birth, canonical path, digest, argv), kept, and
  stopped with both streams and a signalled exit, its PID gone afterwards; a script that exits 7
  reports `Exited(7)` once and again after `stop`; 8 KiB against a 1 KiB capture keeps 1 KiB and is
  noted; a `PATH` overlay or a zero capture launches nothing. The first version of the first two
  tests stopped the server after a fixed 300 ms and lost its output under load — `/bin/sh` had not
  started yet — so they now wait for the script's own marker file, the fact rather than the clock.
- `cargo test -p arkdeck-provider-hdc --test managed_server` (5/5), over a fake `hdc`
  compiled at test time from C with its behaviour fixed by defines (the host names the child's
  environment, so nothing can be varied through it; a shell script cannot own a TCP listener and a
  copied Apple binary is killed by the kernel):

| Test | Fake | Proves |
| --- | --- | --- |
| `a_cold_server_becomes_ready_and_is_bound_to_its_launch` | binds 1 s after it starts | readiness waited for the listener, versions 3.2.0d agree, identity == launch (pid, birth, path, digest, endpoint), `revalidate` ok, `stop` ends it and frees the port |
| `a_server_that_ends_before_it_listens_reports_its_exit` | exits 3 at once | `Exited("foreground HDC server exited with status 3")` within seconds |
| `a_server_whose_versions_disagree_is_never_ready_and_is_stopped` | answers server 3.2.0f | `NotReady("checkserver exit=0 stdoutBytes=…")` at the 3 s budget and the listener is gone afterwards |
| `a_listener_of_another_process_never_binds_the_launch` | never binds; the test owns the port | `Unbound(...)` — a reachable listener with an agreeing `checkserver` is still not this launch |
| `the_server_port_is_named_to_the_child_and_its_output_is_kept` | prints its port variable | `OHOS_HDC_SERVER_PORT=<port>` is the child's and is captured |

## Not run, and why

- No real HDC and no device: whether hdc 3.2.0f binds the dual-stack listener the kernel labels
  `::ffff:127.0.0.1` is already covered by the lease's address rule (phase 1); the fake binds plain
  IPv4.
- PID reuse between the launch and the identity proof cannot be produced deterministically; the
  same-birth bracket is exercised by the lease tests' listener that exits.
