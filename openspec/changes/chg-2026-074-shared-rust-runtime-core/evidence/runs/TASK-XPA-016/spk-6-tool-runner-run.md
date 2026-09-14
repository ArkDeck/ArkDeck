# TASK-XPA-016 — SPK-6 phase 2 run record: the verified tool runner

Change: CHG-2026-074-shared-rust-runtime-core@r11. Spike recorded here: SPK-6 (design §J.3),
phase 2 of lane B; phase 1 (the macOS server identity proof) is `spk-6-run.md` on its own PR.
Host measurement only — not hardware, platform or conformance evidence (POL-VERIFY-001,
POL-MODE-001). No device was contacted and no HDC executable was launched: every child in this
phase is a shell script under a scratch directory.

Base: protected main `af43c172` (#1912). Branch `agent/xpa-016-spk6-tool-runner-20260914`.

## What was missing

Every identity-bound spawn in `arkdeck-platform` fixed the child's environment to
`PATH=/usr/bin:/bin`, `LANG=C`, `LC_ALL=C` plus at most one `OHOS_HDC_SERVER_PORT`, its working
directory to `/`, and its stdin to `/dev/null`. `run_read_only_with_environment` (the HDC provider's
path) is capped at 60 s and 8 MiB combined, polls its pipes with a 5 ms sleep and has no
cancellation hook; `run_analyzer` has the cancellation hook, poll-driven readers and the longer
budget but requires a `VerifiedSource`. A device dispatch (lane A's `HdcDispatch`), a workspace
tool (hvigor, ohpm, hap-sign-tool) or DevEco needs the analyzer's discipline with a named
environment and a working directory, and Swift's receipt needs the run's duration.

## What Swift does

`FoundationProcessExecutor` (`Sources/ArkDeckProcess/ArkDeckProcess.swift`): a `ProcessRequest`
names the executable, `argv`, an explicit `environment` overlaid on the fail-closed base
(`baseChildEnvironmentKeys` = `PATH`, `HOME`, `TMPDIR`, `LANG` filtered from the parent; nothing
else the daemon carries reaches a child, lines 400–414), a child-only `workingDirectory` applied by
`posix_spawn` file actions after it is checked to be a file URL, absolute, NUL-free, canonical and an
existing directory (`workingDirectoryUnavailable`, lines 703–712, 888–896), and a timeout. Output is
captured per stream up to a limit while the rest drains; a timeout terminates the process group
(TERM, 0.25 s, KILL, 1 s, lines 1433–1460); the receipt carries `durationSeconds` from a monotonic
clock.

## What Rust now does

- `rust/crates/arkdeck-platform/src/tool_process.rs`: `VerifiedTool::run_tool(&ToolRequest,
  cancelled)`. `ToolRequest` = `arguments`, `environment` (overlaid on the clean base; `PATH`,
  `LC_ALL`, `DYLD_*` and `LD_*` cannot be overlaid; keys and values are non-empty NUL-free text
  without `=` in the key), `working_directory` (absolute, canonical, existing directory; `None` is
  `/`), `limits` (1 s..1 h, 1 byte..64 MiB per stream). The run is the analyzer runner's: revalidate,
  a cancellation before the spawn leaves no child, spawn through the retained inode in a new group,
  poll-driven per-stream capture that keeps the first bytes and drains the rest, `try_wait` with
  `WNOWAIT`, timeout → TERM then KILL, cancellation → group drain with Swift's proof, partial output
  of a terminated child kept and never judged. `ToolExecution` adds `duration`, the monotonic time
  from the spawn to the child's end or termination.
- `rust/crates/arkdeck-platform/src/macos_process.rs`: `spawn_in` takes the child-only working
  directory for `posix_spawn_file_actions_addchdir_np`; `spawn` is `spawn_in` with `/`.
- `rust/crates/arkdeck-platform/src/analyzer_process.rs`: `run_analyzer` is now a wrapper over
  `run_tool` with the source retained across the run; its public types and refusal message are
  unchanged and `arkdeck-hoststore` is untouched.
- Deliberate difference from Swift: the base environment is the fixed `PATH=/usr/bin:/bin`,
  `LANG=C`, `LC_ALL=C` every identity-bound spawn here already used, not the parent's `PATH`,
  `HOME`, `TMPDIR`, `LANG`; a caller that needs `HOME` or `TMPDIR` names them. Lane A's fake HDC
  driver was written for this base.
- Not changed: `run_read_only_with_environment` and the HDC provider keep their path until lane A's
  `HdcDispatch` seam maps `ProcessPlan` onto `ToolRequest`.

## Tests

- `cargo test -p arkdeck-platform --test tool_process` (its own binary; it spawns children), 8/8:
  a named variable reaches the child while the test process's own `ARKDECK_LEAK` does not and the
  base is exactly `PATH=/usr/bin:/bin`/`LANG=C`; `PATH`, `DYLD_INSERT_LIBRARIES`, `LD_PRELOAD`,
  `LC_ALL`, an empty key, a key with `=`, a NUL in a key or value are `Refused` and the tool's
  marker proves nothing spawned; `pwd` in the child is the given directory while the daemon's own
  directory is unchanged, `None` is `/`, and a missing path, a file, a symlink to the directory and a
  relative path are `Refused`; stdin reads as empty and a 40,000-byte stdout keeps 1,024 bytes with
  `truncated` while stderr keeps `err`; a 3 s timeout terminates `printf partial; sleep 30` as
  `TimedOut` with the printed bytes kept (asserted once the script's marker proves it printed — a
  loaded host started `/bin/sh` in about 0.6 s during this run) and `duration >= 3 s`; a
  cancellation before the spawn leaves no marker and `duration` zero, one during the run drains the
  group; `kill -9 $$` is `Signalled(9)` and `exit 7` is `Exited(7)` with its stderr; four out-of-range
  budgets are `Refused`.
- `cargo test -p arkdeck-platform --test analyzer_process`: 8/8 unchanged over the wrapper.
- `cargo test -p arkdeck-hoststore`: 223 passed, 0 failed (the analyzer Job path over the wrapper).
- `cargo fmt --check`; warnings-denied clippy on aarch64-apple-darwin, x86_64-unknown-linux-gnu and
  x86_64-pc-windows-msvc.
- Unified local gate: see the PR's commit body.

## Not run, and why

- No HDC, DevEco or workspace tool: the runner is exercised with shell scripts; its first production
  caller is lane A's `HdcDispatch` implementation, which maps `ProcessPlan` onto `ToolRequest`.
- No device.

## Phases still open (SPK-6)

3. The persistent `hdc shell` channel with exit-code framing (`PersistentDeviceShellChannel`).
4. The PTY one-time secret exchange (`IdentityBoundPTYExecutor`).
