# TASK-XPA-016 — Windows persistent device shell channel (gate inventory G19, shell half), 2026-09-30

- Task: TASK-XPA-016, the Windows counterpart of SPK-6 phase 3 (the persistent `hdc shell`
  channel, `DeviceShellChannel`). This is the shell-channel half of gate-inventory G19 ("PTY
  exchange and persistent shell channel", `../TASK-XPA-004/windows-gate-inventory-20260930.md`);
  the PTY half is `../TASK-XPA-011/windows-pty-exchange-run.md` (#2358).
- Base: protected `main` at `f0d83f78` (#2358, the G19 PTY exchange), whose pseudo console
  spawn (`spawn_attached`, `Console`) the channel rides. Work started on `ca880968` with the then
  open #2358 branch merged in; `main` was merged back after #2358 landed. Branch
  `agent/xpa-016-windows-executor-20260930`.
- Host: the Windows 11 x64 reference host (Windows 11 Pro 10.0.26200), non-elevated. No board
  was touched, no `hdc` was run, nothing was installed, elevated or reconfigured, and no process
  this run did not start was signalled.

This is host evidence for a Rust port, run against a fake `hdc shell`. It is not Windows
platform acceptance and not device evidence. Nothing composes the channel yet on either
platform (no provider consumer), so no operation changes behaviour.

## What the slice set out to do, and what was already done

The slice brief named three executor pieces as still macOS-only. When checked on `main`, two
of them were already on Windows:

| Piece | State found on `main` | This slice |
| --- | --- | --- |
| Budgeted tool runner (time/output budgets, process-tree kill) | on Windows since #2341: `VerifiedTool::run_tool` in `src/windows/tool.rs` (Job object, `TerminateJobObject`, per-stream capture budget, cancellation, `tests/windows_tool_dispatch.rs`) | unchanged |
| Loopback HDC server proof (`LoopbackServerLease`) | on Windows since #2341: `src/windows/server.rs` (`GetExtendedTcpTable` owning PID plus image check), `tests/loopback_server_lease.rs` | unchanged |
| Persistent HDC shell channel (`DeviceShellChannel`) | macOS only | **ported** |

## What changed

| Area | Before | Now |
| --- | --- | --- |
| `DeviceShellChannel`, `DeviceShellAnswer`, `DeviceShellChannelError` | macOS only | exported on macOS and Windows; one definition (`src/shell_channel.rs`) |
| `src/shell_channel.rs` | macOS module; the channel held the PTY master and child PID itself | compiled on both; the channel holds a platform `ShellClient` (start, alive, close, read, write). The macOS client is the former code moved into `ShellClient` under `cfg(target_os = "macos")`; its bodies are unchanged, and the framed line still ends in `\n` (`SHELL_LINE_ENDING`), so the bytes written are the same. The framing (`FrameScanner`), the bare-token rule, the budget and 4 MiB overflow tolerance, the settle wait, the opening no-op and the outcomes are shared |
| `src/windows/shell.rs` | — | the Windows `ShellClient` over a pseudo console, and the `Rendering` reader |
| `src/windows/pty.rs` (from #2358) | `Console` private | `Console`, its handle/input/output, `open`, `close`, `CONSOLE_SIZE` and `LINE_ENDING` are `pub(super)` so the shell client reuses them; no behaviour change |
| `tests/windows_shell_channel.rs` | — | `harness = false` target; the fake `hdc` is the test binary |

Linux does not build `shell_channel.rs`, the same as before.

### The Windows channel

1. `DeviceShellChannel::open(tool, ["-t", <connectKey>, "shell"], environment, settle)`: the
   tool is revalidated; the environment overlay goes through the tool runner's validator (the
   base `PATH`/`SystemRoot`/`WINDIR` and `__COMPAT_LAYER` cannot be named); a pseudo console
   (1024×64, G19's) is created; `hdc` is started through `spawn_attached` — argv array, no shell,
   suspended, admitted into a kill-on-close Job, image proved to be the retained file before
   `ResumeThread`, no inherited handle.
2. As on macOS the first write waits until the shell has said something, and opening is proved
   by one framed `true` answering status 0; anything else is `Unavailable` and closes the client.
3. `run(tokens, timeout, budget)`: bare tokens only, a fresh 128-bit nonce, `echo <n>B; <cmd>;
   echo <n>:$?` written in one write, the frame found by the shared scanner, the budget trimming
   the answer, the timeout, the client's death or an answer past budget plus 4 MiB closing the
   channel as `OutcomeUnknown`.
4. `close` (also on drop) ends the client's Job, its descendants included, and waits for it to
   be empty, then closes the pseudo console, whose reader is joined within the cleanup budget.

### Where Windows differs (decisions for review)

- **Why a pseudo console at all.** `hdc shell` refuses a standard input that is not a terminal
  ("Not support stdio TTY mode"); on Windows the terminal is a console, so the client rides a
  pseudo console as the macOS client rides a pseudo-terminal. The fake reproduces the refusal
  on pipes (test 7).
- **CR ends a framed line.** A console reads Enter as `\r` (G19's decision). A device shell on a
  terminal with `ICRNL` reads it as the end of the line. Not yet observed against real `hdc` on
  Windows — see "Not verified".
- **The answer is the console's rendering, read as text (T1).** A pseudo console re-renders its
  screen as VT: cursor visibility, erasures, modes, titles and cursor moves surround and can
  split the text. `Rendering` removes CSI (`ESC [ … final`), OSC (`ESC ] … BEL|ST`) and other
  escape sequences, keeping state across reads, and reads a cursor-forward (`ESC [ n C`, which
  the host writes over a run of blanks) back as `n` blanks, capped at the console width. Lines
  arrive as CRLF. The frame markers and the status digits are plain text and are unaffected;
  the body is T1 against macOS (the macOS body keeps LF and the device's own escapes). No
  consumer compares body bytes across platforms.
- **The shell "comes up" only on rendered text.** The host paints its modes and an empty screen
  before the client writes anything; those are control sequences and do not end the settle
  wait, so the macOS rule (first write only once the shell has spoken) keeps its meaning.
- **A flood ends at the timeout, not at the overflow bound.** The host renders a screen per
  frame rather than every byte written, so a flooding command cannot push 4 MiB past the budget
  through the console within any reasonable timeout; it ends at the command's timeout instead.
  Both are `OutcomeUnknown` and both close the channel, as on macOS. The overflow path itself is
  shared code covered by the macOS test.
- **No signal group.** Closing terminates the Job at once (the tool runner's T1 decision); an
  exited client stays owned until `close`, so its descendants never outlive the channel.

## Tests

`tests/windows_shell_channel.rs` (fake `hdc -t FAKE0123456789 shell`: refuses a non-console
stdin like `hdc`, refuses any other argv with status 64, prints a `$ ` prompt and runs one line
at a time; the console's cooked echo stands in for the device's echo):

1. a framed command answers with the device's own status and nothing else (`printf`, `false`
   → 1, an unknown command → 127 with its diagnostic, a non-bare token refused, a later command
   on the same channel);
2. an answer over budget is trimmed and marked and the channel stays open; the full 200-line
   answer reads back exactly as CRLF lines;
3. a command that never frames its answer is an unknown outcome within its timeout and closes
   the channel;
4. a flood is an unknown outcome and closes the channel;
5. a client that exits leaves the channel unknown/unavailable;
6. only bare tokens are carried (including `\`, which a Windows path would need);
7. the client needs a console (on the tool runner's pipes the fake exits 1 with `hdc`'s
   refusal) and the exact device argv (without `-t <key>` the channel never opens);
8. closing the channel ends the client's whole tree (a grandchild the fake started is gone
   within 5 s of the drop).

`src/windows/shell.rs` unit tests cover the rendering reader (host control sequences, sequences
split across reads, cursor-forward). The shared `shell_channel.rs` frame tests now also run on
Windows. No test sleeps to order events; synchronisation is the rendering and the frames.

## Local targeted checks

All with `CARGO_TARGET_DIR=D:\cargo-target\s1-executor`, from `rust/`:

| Command | Exit | Result |
| --- | --- | --- |
| `cargo fmt --all --check` | 0 | clean |
| `cargo clippy -p arkdeck-platform --all-targets -- -D warnings` | 0 | clean |
| `cargo clippy --workspace --all-targets -- -D warnings` | 0 | clean |
| `cargo test -p arkdeck-platform --test windows_shell_channel` (three consecutive runs) | 0 | 8 passed, each run |
| `cargo test -p arkdeck-platform` | 0 | every target passed, `windows_pty_exchange` included |
| `PYTHONUTF8=1 sh scripts/check-sdd.sh` (repo root) | 0 | passed |
| `git diff --check` | 0 | clean |

## CI

Not waited for. The macOS lane is the judge of the `cfg(target_os = "macos")` client, which
this host cannot compile; the cfg pairs were reread by hand (the macOS `ShellClient`, its
`SHELL_LINE_ENDING` and the `OwnedFd`/`AsRawFd`/`spawn_pty` imports are all
`cfg(target_os = "macos")`; the Windows imports `cfg(windows)`; `tests/shell_channel.rs` stays
macOS-only).

## Not verified

- Real `hdc shell` on Windows: CR as Enter through `hdc`'s raw console mode, the device echo
  and prompt in the rendering, the settle time. These need the maintainer's Phase A window with
  a board; this slice ran no `hdc`.
- The channel is not composed by any provider on either platform yet (pointer-injection
  routing through it remains the pending GJ-2/GJ-3 work), so no operation changed.
