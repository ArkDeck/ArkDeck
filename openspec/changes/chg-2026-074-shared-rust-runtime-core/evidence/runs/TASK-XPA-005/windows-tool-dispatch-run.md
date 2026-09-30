# TASK-XPA-005 — Windows tool dispatch and managed-HDC server proof, 2026-09-30

- Task: TASK-XPA-005, WM1 slice T1: gate-inventory group 5 ("Tool dispatch and managed-HDC
  server proof", G06/G07 of `../TASK-XPA-004/windows-gate-inventory-20260930.md`).
- Base: protected `main` at `1ee57b1e` (#2338 merged; developed on `d0f72b03`, rebased, and every
  check below rerun on the rebased head).
- Host: the Windows 11 x64 reference host (Windows 11 Pro 10.0.26200), rustc/cargo 1.98.1,
  non-elevated. No board was touched, no `hdc` was run, nothing was installed, elevated or
  reconfigured, and no process this run did not start was signalled.

This is host evidence for a Rust port, run with a fake tool. It is not Windows platform
acceptance and not device evidence: no Windows HDC tuple is registered (its integration change
waits for the maintainer's samples), and nothing composes the new Windows owners into the daemon.

## What changed

| Area | Before | Now on Windows |
| --- | --- | --- |
| Tool types | `ToolRequest`, `ToolLimits`, `ToolExecution`, `ToolTermination`, `ToolRunError` defined in the macOS-only `tool_process.rs` | one shared definition (`src/tool_request.rs`, with the budget rule `check_limits`) used by the macOS runner and the Windows runner |
| Server records | `ServerIdentityReceipt` in `macos_server.rs`; `ServerLaunch`/`ServerExit`/`ServerStop` in the macOS `managed_server.rs` | one shared definition (`src/server_identity.rs`) |
| `VerifiedTool::run_tool` | macOS only | `src/windows/tool.rs`: `CreateProcessW` from the argv array (never `cmd.exe`/PowerShell), suspended, assigned to a kill-on-close Job object, image proved to be the retained file, then resumed; base environment `PATH`/`SystemRoot`/`WINDIR` + a validated overlay; optional canonical working directory; `NUL` stdin; per-stream capture with drain; deadline and cancellation terminate the Job |
| `ManagedServer` | macOS only | `src/windows/managed.rs`: `launch` (creation time read while suspended), `launch_record`, `same_birth`, `exit`, `stop`, and `verifies(receipt)` (below); `launch_paired` is not ported (no Windows owner needs it before GJ-4/GJ-5) |
| `LoopbackServerLease` | Windows: one IPv4 listener row, any-process wildcard refusal, no receipt | `src/windows/server.rs`: the macOS scan's shape — IPv4 and IPv6 listener tables, candidates by image path, file identity, one registered listener, calling user, two agreeing scans — and `identity()` returning a `ServerIdentityReceipt` |
| `arkdeck-provider-hdc` | `dispatch` and `managed_server` gated to macOS | both build on Windows (`ProcessDispatch`, `ManagedHdcServer`, `EndpointSelection`, `StartBudget`, `StartFailure`); `generation` moved beside the managed server (`lifecycle` re-exports it unchanged) |

The spawn path the read-only provider already used (`run_read_only`, XPA-002) is the same
function with no working directory; its environment block is now built from UTF-16 without the
lossy `to_string_lossy` step, and the output pipes get a 64 KiB buffer.

### T1 decisions recorded as proposals

1. **No TERM on Windows.** macOS gives a timed-out or cancelled group TERM, then KILL after
   0.25 s; Windows terminates the whole Job at once (`TerminateJobObject`, exit code 1). The
   outcome and its code are the same (`TimedOut`, `Cancelled { drained }`, `ServerExit`); only the
   grace a child could have used to exit on its own is absent. This is the inventory's §8
   question 4, answered here as a proposal for the maintainer's review.
2. **Environment overlay rule on Windows.** The overlay may not name `PATH`, `SystemRoot`,
   `WINDIR` (the base) or `__COMPAT_LAYER` (which changes how the verified image runs), compared
   ignoring case as Windows compares names, and may not name one variable twice. This is the
   Windows reading of macOS's "no `PATH`, `LC_ALL`, `DYLD_*`, `LD_*`".
3. **Working directory spelling.** As on macOS the directory must equal its own canonical form;
   on Windows that is the `\\?\`-spelled path `std::fs::canonicalize` returns (the same form
   `VerifiedTool` paths take). `CreateProcessW` accepts it and the child reports it unchanged.
4. **Hash drift is `NotFound`.** A server whose image file was renamed away (a running image
   cannot be rewritten, only renamed) is reported by Windows at its new path, so it is not a
   process of the verified path: `NotFound`, as a listener of another executable is on macOS.
   A process reported at the verified path but running another file is `PermissionDenied`
   (defensive; not reproducible on NTFS with this API).
5. **An owner that cannot be inspected fails the scan.** macOS skips a process whose path it
   cannot read; Windows cannot know a listener owner's image without opening it, so an owner it
   cannot open (other than one that has already exited) makes the proof `PermissionDenied`, as
   macOS's "the kernel would not say" does for a candidate.

## The server proof without argv (inventory §8 question 2)

Windows has no supported way to read another process's argv, so no Windows code reads one.
The proposal implemented here:

- **Existing server (`LoopbackServerLease`).** A process is the server when its image is the
  verified path **and** the image file's `FileIdInfo` equals the verified tool's retained file,
  whose bytes the tool's SHA-256 pin covers (the tool is revalidated around both scans); it owns
  exactly one listener on the endpoint's port, bound to `127.0.0.1` or `::ffff:127.0.0.1`
  (IPv4 and IPv6 tables); it runs as the calling user with the same elevation; and two scans
  agree. The receipt carries the PID and the `GetProcessTimes` creation time (as Unix seconds and
  microseconds, the macOS birth's shape); the lease holds the process handle, so the PID cannot
  be recycled while it lives, and `revalidate` re-checks the creation time and the listener.
- **Managed server (`ManagedServer::verifies`, in place of `verifies_managed_process`).** The
  argv is proved by provenance: this daemon launched the child with exactly
  `launch_record().arguments`, and the receipt must name that very child — the launch's PID,
  creation time, path and digest; that PID still has that creation time (before and after); the
  process it names is alive, runs the file the launch proved, and is a member of the server's own
  Job object (`IsProcessInJob`); the launch's argv declares the receipt's endpoint (`-s
  <endpoint>`); and it owns a listener on that port bound to the loopback or a wildcard (Swift's
  rule for the managed check).
- **Consequence.** A server this daemon instance did not launch can be proved to exist and be
  observed, but never proved managed: after a daemon restart, an HDC server the previous
  instance launched is an external server, never adopted or stopped (the profile's "no auto-kill
  of an external HDC server"). The provider's status verifier (`SystemManagedProcess`, still
  macOS-only with `status.rs`) would take this form on Windows by asking the `ManagedServer` the
  daemon holds; that composition is not done here.

**Decision needed (not taken here):** whether the maintainer accepts "managed = launched by this
daemon instance and still in its Job" as the Windows T1 equivalent of the macOS argv check. The
options are: (a) this proposal; (b) additionally persist the Job across daemon restarts by a
named Job object (would let a restarted daemon re-prove its predecessor's server, at the cost of
a named kernel object other same-user code could open); (c) read the command line through
`NtQueryInformationProcess(ProcessCommandLineInformation)`, an NT API outside the supported
Win32 surface that returns whatever the process has since written there — not recommended. Until decided, (a) is what the
code does; it fails closed (an unproved server is external).

## Tests

Fake tool only: the platform's `tests/windows_tool_dispatch.rs` and the provider's
`tests/windows_managed_hdc.rs` are `harness = false` targets whose fake tool / fake `hdc` is the
test binary itself (argv selects the role; the provider selects variants by the copy's file
name, since the host names the child's environment). No sleep synchronises anything: every wait
is a bounded wait on a condition (a report file written whole and renamed, a process handle, a
listener that must disappear).

`tests/windows_tool_dispatch.rs` (21):

- argv verbatim through `CreateProcessW` (empty, spaces, quotes, trailing backslash, `& | < > ^
  %PATH% $HOME` and a backtick, non-ASCII); `NUL` stdin reads 0 bytes;
- clean environment: exactly `PATH`, `SystemRoot`, `WINDIR` plus the overlay; refusals of
  `PATH`/`path`/`SystemRoot`/`windir`/`__COMPAT_LAYER`, an empty name, `=` in a name, NUL in a
  value and a name given twice, none of which ran the tool;
- working directory: the child's own, the daemon's unchanged; the non-canonical spelling, a
  relative path, a missing directory and a file refused;
- output limits: 4 MiB per stream kept to 1000 bytes each and truncated, exactly 1000 not;
- deadlines: `TimedOut` after at least the timeout with partial output kept; a live child tree
  (child + grandchild) terminated by the deadline, the grandchild observed through a handle opened
  while it was alive;
- cancellation: before the spawn (no child, zero duration) and during the run with a live tree
  (`drained: true`, grandchild ended);
- exit codes; the budget bounds refused before any spawn;
- `ManagedServer`: launch record (PID, birth, path, digest, argv), `same_birth`, stop (exit 1,
  output kept, child ended); a server that ends on its own; refused environment/capture launches
  nothing; a dropped server takes its child tree with it;
- listener-owner proof positive (receipt equals the launch record; lease revalidates; `verifies`
  holds; after the stop the lease no longer revalidates) and each refusal: a receipt with another
  PID, birth second, birth microsecond, zero birth, path, digest or endpoint; a launch that
  declares no endpoint; another server's receipt; zero listeners (no process, and a tool process
  without a listener: `NotFound`); a new server on the same endpoint is a new PID/birth; wrong
  image (same bytes, another file: `NotFound`) and a foreign wildcard beside the tool's exact
  listener not disturbing the proof; hash drift (image renamed away and other bytes pinned at the
  path: `NotFound`; the original bytes pinned at their new path are proved again but are not the
  launch); a wildcard (`0.0.0.0`, `[::]`), a second listener (`127.0.0.1` + `[::1]`, `127.0.0.1` +
  `0.0.0.0`) and two tool processes on one port: `PermissionDenied`; non-loopback endpoints
  refused.

Unit tests (`src/windows/`): Job **kill-on-close alone** — a live child tree whose owner skips
its own termination ends when the last Job handle closes, the grandchild's Job membership proved
first (`process::tests::closing_the_job_handle_kills_a_live_child_tree`; this closes the SPK-3
gap "Job Object cleanup of a live child tree is not covered on Windows"); IPv6 row bounds; listener
normalisation; one/two/unregistered listener counting; FILETIME→Unix birth.

`tests/windows_managed_hdc.rs` (6): a fake `hdc` server becomes ready and is bound to its
launch, then stopped (listener gone); one that exits before it listens (`Exited`, status 3); one
whose versions disagree (`NotReady`, listener gone once dropped); an occupied endpoint launches
nothing (the fake records no call); a foreign listener appearing after the launch never binds it
(`Unbound`); `ProcessDispatch` runs the plan argv with the inherited server port (and drops an
invalid one) and grants no mutation on Windows.

## Local targeted checks

All from the worktree's `rust/` with `CARGO_TARGET_DIR=D:\cargo-target\t1-tools`,
`CARGO_BUILD_JOBS=3`. Logs under `D:\cargo-target\t1-tools\logs\` (host only, not committed).

| Command | Exit |
| --- | --- |
| `cargo fmt --all --check` | 0 |
| `cargo clippy --workspace --all-targets -- -D warnings` | 0 |
| `cargo test -p arkdeck-platform -p arkdeck-provider-hdc` | 0 on the rebased head (platform lib 49, `windows_tool_dispatch` 21, `host_store` 9 (from #2338), `windows_transport` 14, `windows_stop` 1, `sha256_backend` 1; provider lib 119, `swift_fixture_parity` 11, `trace_probe` 7, `windows_managed_hdc` 6, `windows_usb_census` 2) |
| `sh scripts/check-sdd.sh` (repository root) | 0 |
| `git diff --check` | 0 |

macOS and Linux were not built here. Every `cfg` pairing touched was re-read: the shared type
modules are `any(target_os = "macos", windows)`; Linux keeps its placeholder lease and
`run_read_only` only; the macOS `tool_process.rs`, `managed_server.rs`, `macos_server.rs`,
`analyzer_process.rs`, `pty_exchange.rs` and the provider's `lifecycle.rs`/`status.rs` resolve the
moved items through the same paths (`super::Tool*`, `super::tool_process::{MAX_CAPTURE_BYTES,
MAX_TIMEOUT}`, `crate::ServerIdentityReceipt`, `crate::lifecycle::generation`). The macOS and
ubuntu CI lanes decide.

## CI

To be recorded in the next slice's run record (PR and run id not known when this was written).
