# TASK-XPA-016 — SPK-6 run record: the managed server's birth is recorded while it is suspended

Change: CHG-2026-074-shared-rust-runtime-core@r11. A fix to lane B's managed HDC server (#1930,
`arkdeck_platform::ManagedServer`), reported by lane A from #1945's macOS CI run. Host
measurement only — not hardware, platform or conformance evidence (POL-VERIFY-001,
POL-MODE-001). No HDC, no device, no daemon.

Base: protected main `847eefdb` (#1941). Branch `agent/xpa-016-managed-server-birth-20260914`.
Files: `arkdeck-platform/src/macos_process.rs`, `arkdeck-platform/src/managed_server.rs` (and its
new unit test), this record, one README sentence. No provider, agentd, Swift or contract change.

## The failure

`crates/arkdeck-provider-hdc/tests/managed_server.rs::a_server_that_ends_before_it_listens_reports_its_exit`
(a fake `hdc` compiled with `EXIT_EARLY=3`) failed once on the macOS Rust workspace job of
#1945 (run 34842672045, job 103971088798) with

```
expected the exit, got Refused(Custom { kind: Other, error: "server launch could not be recorded from the kernel" })
```

while passing on main `0ae4fe45` and in every local gate. #1945 changes neither
`arkdeck-provider-hdc` nor `arkdeck-platform`.

## The cause

`spawn_in` (`macos_process.rs`) already creates the child suspended
(`POSIX_SPAWN_START_SUSPENDED`), re-proves the tool, and then resumes the child with `SIGCONT`
before returning. `ManagedServer::launch` read the child's birth (`proc_pidinfo`,
`PROC_PIDTBSDINFO`) only after that return. A server that exits at once can already be a
zombie by then; a zombie has no `proc_bsdinfo`, so the read failed and the launch was refused
as "could not be recorded" — instead of being what it is, a server that ended, which is what
the provider's `ended` check would have reported as `StartFailure::Exited("foreground HDC
server exited with status 3")` had the launch been recorded. Swift's `HeadlessHDCServerHost`
reports the exit in this situation: `Lifecycle.missingLaunchReason()` returns the exit reason
before the "managed HDC spawn identity capture failed" reason.

## The fix

`spawn_in` is split into `spawn_suspended`, which returns a `SuspendedChild` — the child
created suspended on the retained inode, the tool re-proved, no tool code run — and
`SuspendedChild::resume`, which sends the `SIGCONT`; `spawn_in` is the two back to back, so
`VerifiedTool::run_tool` and every other spawn keep their behaviour. `ManagedServer::launch`
now reads the birth from the suspended child and resumes it afterwards: a stopped process
cannot exit, so the birth is always there, and a server that ends at once ends after its
launch was recorded.

## Measurement

`managed_server.rs` gains a unit test, `a_server_that_ends_at_once_is_recorded_and_reports_its_exit`:
a script `#!/bin/sh\nexit 3` at a private temporary directory, launched fifty times through
`ManagedServer::launch`, each launch required to carry a recorded birth and to end as
`Exited(3)`.

The test was run once against the unfixed code and three times against the fix on this host
(8 cores, load average about 30 during the run): 50/50 launches recorded and `Exited(3)` every
time, before and after. The unfixed code did not fail here — the race needs the parent to be
held off the CPU between the `SIGCONT` and the birth read for longer than the child takes to
exit, which is what a loaded CI runner did once and this host did not in 50 tries — so the
fix is not measured as a narrowed window but argued by construction: the birth is read from a
process the kernel keeps stopped, which cannot exit until `resume`. `cargo test -p
arkdeck-platform --lib a_server_that_ends_at_once`: 1 passed (×4).

The provider's `tests/managed_server.rs` (the fake `hdc` from C, including the racing test)
passes on the fix; clippy `--all-targets -D warnings` is clean for both crates.
