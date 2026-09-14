# TASK-XPA-016 — SPK-6 phase 3 run record: the persistent device shell channel

Change: CHG-2026-074-shared-rust-runtime-core@r11. Spike recorded here: SPK-6 (design §J.3),
phase 3 of lane B; phase 1 is `spk-6-run.md` (#1914), phase 2 `spk-6-tool-runner-run.md` (#1915).
Host measurement only — not hardware, platform or conformance evidence (POL-VERIFY-001,
POL-MODE-001). No device was contacted and no HDC executable was launched: the channel is driven
by `/bin/sh -i` on a pseudo-terminal in place of `hdc -t <key> shell`.

Base: protected main `aa4cc8d8` (#1914), stacked on #1915 (`72c5dd08`, phase 2) because both add
the module list of `process.rs`, the `macos_process.rs` helpers and the `lib.rs` export block.
Branch `agent/xpa-016-spk6-shell-channel-20260914`.

## What was missing

Every Rust dispatch spawns one client per command. Swift's `PointerInputChannelDispatcher`
(`Sources/ArkDeckWorkflows/DeviceProviders/PointerInputChannelDispatcher.swift`) routes the pointer
injection of `input.tap/swipe/long-press@1` — one `hdc -t <key> shell <bare tokens>` per gesture —
over a long-lived `hdc shell`, because a spawned client costs a process launch on top of the device
round trip (p50 242 ms spawned vs 177 ms over an open channel against the DAYU200) and an
interactive gesture has to fit inside 400 ms. Nothing in `arkdeck-platform` could hold a client
open, speak to it over a terminal, or frame a command's answer.

## What Swift does

`PersistentDeviceShellChannel` (`Sources/ArkDeckProcess/PersistentDeviceShellChannel.swift`):
`hdc shell` refuses a plain pipe ("Not support stdio TTY mode"), so the client is spawned on a
pseudo-terminal with echo and newline translation off, in its own process group, on the verified
executable's inode path. The client discards anything written before its device shell is up, so
opening waits for the shell to say something and then proves the channel with one framed `true`
that must come back with status 0. Each command is `echo <nonce>B; <tokens>; echo <nonce>:$?`,
where the nonce is fresh per command; the frame is found by the printed opening marker (followed by
a newline, unlike the echoed one followed by `;`) and the printed closing marker (followed by the
status digits, unlike the echoed `:$?`). Only bare tokens are carried — a command the shell would
not read back exactly as written is refused rather than quoted. Anything unexpected (an answer past
the budget plus 4 MiB, the timeout, the client's death) closes the channel and is an unknown
outcome, never a failure, because the device may well have carried the command out.

## What Rust now does

- `rust/crates/arkdeck-platform/src/macos_process.rs`: `spawn_pty` — `openpty`, the slave's
  `ECHO`/`ECHONL`/`ONLCR` cleared, the master nonblocking, the slave as the child's stdin, stdout
  and stderr, the child started suspended in its own process group on the retained inode and
  continued only once the tool still verifies; the argv/environment builder and the inode launch
  path are shared with `spawn_in`.
- `rust/crates/arkdeck-platform/src/shell_channel.rs`: `DeviceShellChannel::open(tool, arguments,
  environment, settle)`, `run(tokens, timeout, output_byte_budget) -> DeviceShellAnswer { stdout,
  device_exit_status, truncated }`, `is_alive`, `close`, `is_bare_token`, with Swift's messages;
  `DeviceShellChannelError::{Unavailable, OutcomeUnknown}` keep Swift's two meanings. The frame
  search is incremental (`FrameScanner` resumes where the previous read left off) — a whole-buffer
  scan per read made a 4 MiB flood take longer than its timeout through the terminal's small
  output queue, which Swift's memmem-backed `Data.range(of:)` hides.
- Not changed: no consumer yet; `PointerInputChannelDispatcher`'s routing rule (`-t <key> shell`
  plus bare tokens only, idle sweep, one channel per connect key) is lane A's provider work.

## Tests

- `cargo test -p arkdeck-platform --lib shell_channel` (4): the frame with the prompt, the echoed
  line and the trailing prompt excluded; a status still being written is incomplete and a missing
  frame absent; an incremental scan across reads agrees with one look at the whole buffer; bare
  tokens.
- `cargo test -p arkdeck-platform --test shell_channel` (its own binary; it spawns children), 6/6
  with `/bin/sh -i` as the client: `printf hello` answers `hello` with status 0, `false` answers an
  empty body with status 1, `printf a;b` is refused and the channel then answers `second`; `seq 1
  200` under a 16-byte budget is trimmed and marked truncated while the channel stays open; `sleep 30`
  under a 1 s timeout is `OutcomeUnknown` ("timeout") and closes the channel; `yes` under a 1 KiB
  budget is `OutcomeUnknown` ("past every bound") once the tolerance is exceeded; `exit 3` is
  `OutcomeUnknown` ("exited before answering"); non-bare tokens and an empty command are refused
  with the channel left alive.
- `cargo test -p arkdeck-platform`: 121 passed, 0 failed; warnings-denied clippy on
  aarch64-apple-darwin, x86_64-unknown-linux-gnu and x86_64-pc-windows-msvc.

## Not run, and why

- No HDC client: `hdc shell`'s banner, prompt and echo shapes are excluded by the framing rather
  than recognised, exactly as Swift's are, but no real `hdc` was on this host's path for the Rust
  daemon; the first real use is the pointer-input routing of lane A.
- No device.

## Phase still open (SPK-6)

4. The PTY one-time secret exchange (`IdentityBoundPTYExecutor`), for the workspace signing of M3.
