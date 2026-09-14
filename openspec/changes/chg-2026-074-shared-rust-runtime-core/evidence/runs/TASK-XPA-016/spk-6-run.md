# TASK-XPA-016 — SPK-6 run record: the HDC process executor primitives

Change: CHG-2026-074-shared-rust-runtime-core (r11 in review as #1910 at the time of this run).
Spike recorded here: SPK-6 (design §J.3, r11), the feasibility gate of lane B. Host measurement
only — not hardware, platform or conformance evidence (POL-VERIFY-001, POL-MODE-001). No device
was contacted and no HDC executable was launched: the first phase below only reads what the
kernel already reports about a listener process. r11 (#1910, merged as `f642d5d4`) made `TASK-XPA-016`
`ready`; phase 1 is the task's first slice and flips it to `in-progress`.

## Phase 1 — the commandless proof that an HDC server exists (macOS)

Base: protected main `5e63eb19` (#1909), rebased onto `af43c172` (#1912, after r11 `f642d5d4`).
Branch `agent/xpa-016-spk6-hdc-executor-20260914`.

### What was missing

`arkdeck_platform::LoopbackServerLease::acquire` returned `Unsupported` on every Unix platform
(`rust/crates/arkdeck-platform/src/unix.rs`, "commandless existing HDC server identity is not
implemented on this platform"). `HdcReadOnlyProvider::list_candidates` acquires that lease before
its only argv (`list targets -v`), so on macOS the Rust daemon could not spawn any HDC process at
all: `device.observations` always answered `unavailable`, and lane A's `observe.device@1` slice had
to keep refusing the two published HDC identities in the isolated composition. Windows already
proved the listener through the TCP owner table (`windows/server.rs`).

### What Swift does

`HDCExact320FSystemIdentityObserver` (`Sources/ArkDeckOpenHarmony/HDCSupervisorObservationProbeRegistry.swift:227-400`)
never connects to the endpoint and never launches a client, not even `checkserver`, which may
bootstrap a server. It scans `proc_listallpids`, keeps the processes whose `proc_pidpath`
(symlinks resolved) equals the selected tool's path, counts each one's TCP `LISTEN` sockets on the
endpoint's port through `PROC_PIDLISTFDS` and `PROC_PIDFDSOCKETINFO`, requires every such listener
to be the registered spelling (`127.0.0.1`, or its IPv4-mapped IPv6 form as the kernel labels the
address in `insi_vflag`, never a wildcard or `::1`), takes the birth time from `PROC_PIDTBSDINFO`,
and requires exactly one process with exactly one listener. Two scans must agree
("server process/listener identity changed during observation"); no process is `unavailable`;
everything ambiguous, unregistered or unscannable is `unknown`. `HDCCommandlessServerIdentity`
re-checks the same birth identity around later inspections so a recycled PID fails closed.

### What Rust now does

- `rust/crates/arkdeck-platform/src/macos_procscan.c` (compiled into the existing static archive by
  `build.rs`): extracts a process's TCP `LISTEN` sockets — the local address as the kernel labels it,
  the port — and nothing else. The struct layouts come from the SDK headers, so no hand-transcribed
  `socket_fdinfo` exists in Rust.
- `rust/crates/arkdeck-platform/src/macos_server.rs`: `LoopbackServerLease::acquire(tool, endpoint)`
  and `revalidate()` with Swift's scan, the registered-address rule, the two-scan agreement, and the
  birth identity; `ServerIdentityReceipt` carries pid, birth seconds/microseconds, the resolved
  executable path, the tool's SHA-256 and the endpoint. `NotFound` is Swift's `unavailable`,
  `PermissionDenied` its `unknown`, `InvalidInput` a non-loopback or zero port. The Unix stub now
  exists only off macOS.
- Deliberate difference from Swift: the owner must be the calling user (as the Windows lease's
  `require_client_user`); a server another account started is refused rather than trusted on its
  path alone (design §F.2 same-user boundary).
- No other module changed: `HdcReadOnlyProvider` still pins the tool version by the two published
  hashes, still requires the lease before its single read-only argv, and still revalidates the lease
  after the process even when execution failed.

### Tests

- `cargo test -p arkdeck-platform --lib macos_server`: Swift's
  `testHSO6_ListenerNormalizationRejectsWildcardPortOnlyAndUnregisteredAddresses` vectors, plus a
  16-byte IPv4 spelling and an unlabelled family.
- `cargo test -p arkdeck-platform --test loopback_server_lease` (its own binary because it spawns
  children): `/usr/bin/nc -l 127.0.0.1 <port>` as the verified executable — the lease names that
  process (pid, canonical path, tool hash, endpoint, microseconds < 1,000,000), revalidates while it
  runs and fails with "identity changed" once it exits; a port nobody listens on is `NotFound`; a
  listener owned by another executable (the test's own `TcpListener`) is `NotFound`; a wildcard
  listener of the verified executable (`nc -l <port>`, bound to `0.0.0.0`) is `PermissionDenied`
  "unregistered listener address"; a non-loopback address or port 0 is `InvalidInput`. 5/5 pass.
- Nothing connects to the listener at any point (`nc -l` would exit on its first connection; the
  positive test asserts it is still running after the lease is held).

### Not run, and why

- No real HDC executable or server: the lease is exercised with `nc`, whose identity the provider
  never accepts, so this phase publishes no HDC observation and no candidate snapshot. The first
  real use is lane A's `observe.device@1` slice once it admits a published HDC identity in the
  isolated composition.
- No device; no Golden/Probe fixture replay (they belong to the provider's parsers, unchanged).

## Phases still open (SPK-6)

2. A cancellable, budgeted runner for any verified tool with caller-controlled environment,
   working directory and stdin (`run_registered_tool`), generalising `run_analyzer` away from the
   analyzer's `VerifiedSource` and replacing the 5 ms sleep polling of `run_read_only_*`.
3. The persistent `hdc shell` channel with exit-code framing (`PersistentDeviceShellChannel`).
4. The PTY one-time secret exchange (`IdentityBoundPTYExecutor`).
