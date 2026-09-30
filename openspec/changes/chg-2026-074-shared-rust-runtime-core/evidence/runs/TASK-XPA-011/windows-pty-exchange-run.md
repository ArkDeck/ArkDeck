# TASK-XPA-011 — Windows PTY prompt/secret exchange (gate inventory G19), 2026-09-30

- Task: TASK-XPA-011 (WM3) prerequisite: the PTY half of gate-inventory G19 ("PTY exchange and
  persistent shell channel", `../TASK-XPA-004/windows-gate-inventory-20260930.md`), the Windows
  counterpart of SPK-6 phase 4 (`../TASK-XPA-016/spk-6-pty-exchange-run.md`). The persistent
  shell channel half of G19 belongs to GJ-2/GJ-3 and is not touched.
- Base: protected `main` at `84a44be1` (#2345). Branch
  `agent/xpa-011-windows-pty-exchange-20260930`. Independent of the open credential-store slice
  (#2354); its ConPTY test pattern was reused, none of its code is needed.
- Host: the Windows 11 x64 reference host (Windows 11 Pro 10.0.26200), rustc/cargo 1.98.1,
  non-elevated. No signer, keystore, profile or real secret was used; no board was touched, no
  `hdc` was run, nothing was installed, elevated or reconfigured, and no process this run did not
  start was signalled.

This is host evidence for a Rust port, run with a fake signer. It is not Windows platform
acceptance, not SPK-10 signing evidence and not device evidence: nothing composes the signing
flow on Windows yet (the provider-workspace consumers stay macOS-gated, see below).

## What changed

| Area | Before | Now |
| --- | --- | --- |
| `PtyRequest`, `PtyInteraction`, `PtyExecution`, `PtyError`, `PtyFailureCategory` | macOS only | exported on macOS and Windows; one definition (`src/pty_exchange.rs`) |
| `VerifiedTool::run_pty_exchange` | macOS (`openpty`, `posix_spawn`) | Windows implementation in `src/windows/pty.rs` with the same signature, bounds, errors and result |
| `src/pty_exchange.rs` | macOS module | compiled on both; the macOS runner, its child guard and `write_all` are `cfg(target_os = "macos")` with their bodies unchanged; the bounds, the transcript wipe (`Zeroing`), the prompt search and `classify_failure` are shared (`pub(crate)`) |
| `src/windows/process.rs` | `spawn_in`: pipes only | `spawn_with` behind `spawn_in` (pipes, unchanged behaviour) and `spawn_attached` (pseudo console); `Attributes` takes either a handle list or a pseudo console |

### The Windows exchange

1. The macOS admission rules: one to four interactions, each prompt 1..512 bytes, each secret
   1..4096 bytes, a budget of at least 1 KiB (`InvalidInteraction`); a zero timeout, an
   environment overlay that names the base or the compatibility layer, or a working directory
   that is not absolute and canonical are `Refused` (the tool runner's validators); the tool is
   revalidated. Nothing is spawned before these pass.
2. `CreatePseudoConsole` (1024×64, no flags) over two anonymous pipes that nothing inherits;
   the console's ends are closed in this process once the console holds its copies. A reader
   thread forwards each rendered chunk (in wiped buffers) and, once nobody listens, reads on and
   discards, so the console host never blocks on a full output pipe.
3. `spawn_attached`: the same `CreateProcessW` path as the tool runner — argv array, no shell,
   `.exe` only, suspended, assigned to a kill-on-close Job, image path and file identity proved
   to be the retained file and the tool revalidated before `ResumeThread`, the clean base
   environment (`PATH`, `SystemRoot`, `WINDIR`) with the validated overlay, the child-only
   working directory. The differences: `PROC_THREAD_ATTRIBUTE_PSEUDOCONSOLE` in place of the
   handle list, no handle inherited (`bInheritHandles = FALSE`), `STARTF_USESTDHANDLES` with null
   handles (so the child's standard handles are the console's, not this process's), no
   `CREATE_NO_WINDOW`.
4. The loop waits for rendered output for at most 25 ms at a time (the macOS poll; the wait
   wakes as soon as bytes arrive), asks the cancellation probe and the deadline, and looks at the
   child. Each chunk is checked in the macOS order: budget (`OutputBudgetExceeded`), a secret in
   the rendered output (`SecretEchoDetected`), any prompt rendered twice or a later prompt before
   its turn (`PromptProtocolViolation`). Each prompt that became due is answered with its secret
   followed by CR, in one write from a buffer wiped afterwards.
5. Every path then terminates the Job and waits for it to be empty (`kill_and_wait`), closes the
   pseudo console and its input, and joins the reader (bounded; `CancelSynchronousIo` past the
   budget). After a normal exit the output the closed console still delivers is read to its end
   (bounded by the 5 s cleanup budget, fail closed) and judged like the rest, so the failure
   category comes from the signer's last diagnostic. A child that ended before every prompt was
   answered is `PromptProtocolViolation`; otherwise the result is `Exited(code)`, the number of
   answered prompts, the rendered byte count and the classified category. The transcript is
   wiped; no byte of it is returned or logged.

### Decisions recorded as proposals (for the maintainer's review)

1. **Echo is detected, not prevented.** macOS clears `ECHO` on the slave before the child runs,
   so the parent owns the privacy boundary. A pseudo console's input mode belongs to the console
   host, and only a process attached to that console can change it (`SetConsoleMode` on its
   `CONIN$`); `AttachConsole` would change process-wide state of the daemon. On Windows the echo
   is the child's own choice (the signer's `readPassword` clears it before reading), and any
   echo that reaches the rendered output ends the exchange as `SecretEchoDetected` before the next
   secret is written — the check macOS also makes. The rendered output with the echoed secret
   never leaves the exchange's wiped buffer. The test `echo` role (echo left on) proves the
   detection on a real console.
2. **Line ending CR.** A console reads Enter as `\r` (the child's `ReadConsoleW` returns `\r\n`);
   macOS writes `\n` to a terminal that maps it.
3. **A secret must be UTF-8 text without C0 controls or DEL on Windows.** The console decodes its
   input pipe as UTF-8 and interprets control bytes (Ctrl-C raises a control event, ESC opens an
   input sequence, backspace and DEL erase, TAB may complete), so such a secret could never arrive
   intact; it is `InvalidInteraction` before any child runs. macOS refuses only NUL, LF and CR.
4. **Prompts are matched in the rendered VT stream.** The console re-renders its screen: the
   first frame opens with mode and clear-screen sequences and a window-title OSC naming the
   executable, and a trailing space that is not yet followed by text is rendered as a cursor move
   (`ESC[1C`), not a space. The OpenHarmony prompts the consumers pass (`Enter keystore
   password:`, no trailing space) match; a caller that includes the trailing space would not
   match the first prompt and would time out (fail closed). `observed_output_byte_count` counts
   rendered bytes, VT sequences included.
5. **No TERM; the Job ends with the exchange.** The budget, the deadline and a cancellation
   terminate the Job at once (the tool runner's T1 decision; macOS gives TERM 100 ms before
   KILL). The exchange also ends the Job after a normal exit, so no descendant outlives it; the
   macOS exchange reaps only the child.
6. **Answers are written after the whole chunk is judged.** macOS writes each due answer inside
   its prompt loop and checks for an out-of-order prompt afterwards; Windows checks first, so a
   chunk that is a protocol violation causes no secret to be written at all.

Not changed: the macOS runner (`run_pty_exchange` on macOS, `ExchangeChild`, `write_all`,
`spawn_pty`) is byte-for-byte the same code, now behind `cfg(target_os = "macos")`; it could not
be compiled on this Windows host (no Apple target installed), so the macOS CI legs are its check.
The consumers (`arkdeck-provider-workspace` `signer.rs`, `sdk_release.rs`) stay macOS-gated:
their other reasons (Unix file modes, `VerifiedSource`, the DevEco password layout — G12/G15/G39)
are still there. No gate was removed whose reason remains.

## Tests

- `cargo test -p arkdeck-platform --lib windows::pty` (2) and the shared `pty_exchange`
  classification test (now also run on Windows): a Windows secret is UTF-8 without controls
  (Ctrl-C, ESC, DEL, BS, TAB and a non-UTF-8 byte refused, non-ASCII text admitted); prompts
  become due in order across chunk boundaries and VT noise, a second rendering of a prompt and a
  later prompt before its turn are violations that answer nothing.
- `cargo test -p arkdeck-platform --test windows_pty_exchange` (`harness = false`; the fake signer
  is the test binary on the pseudo console), 9/9, five consecutive runs green:
  - the two OpenHarmony prompts answered in order: `Exited(0)`, two interactions, `None`; the
    child proves from the inside that it read exactly the keystore secret and then exactly the
    key secret (a second copy of the first answer would have been read in place of the second),
    that neither secret is in its argv or environment, and that its standard handles are a
    console; the key secret is non-ASCII (`ä€` and an astral character) and arrives intact; the
    result's `Debug` text carries no secret;
  - the wrong key secret: `Exited(1)`, two interactions, `keystorePasswordRejected` classified
    from the diagnostic the child prints just before exiting (read from the closed console);
  - the console's echo left on, and a child that prints what it read: `SecretEchoDetected`;
  - a near-miss prompt (`Enter keystore passwd:`) with a 2 s deadline: `TimedOut`, and the
    child's marker for "a line was read" absent — a written answer would have been read and
    ended the child within milliseconds;
  - a prompt rendered twice, prompts in the wrong order, a child that exits after printing
    something else, and one that exits 3 with no output: `PromptProtocolViolation`;
  - a flood under a 1 KiB budget: `OutputBudgetExceeded`; a silent child under a 1 s deadline:
    `TimedOut` in well under 10 s; a cancellation: `Cancelled`;
  - a child that starts a grandchild (in its Job) then answers both prompts and hangs: the
    cancellation probe holds the grandchild open while it is alive, cancels, and the grandchild
    has ended within 5 s of `Cancelled`; a child that starts a grandchild and exits 0 after both
    answers: `Exited(0)` and the grandchild has ended too;
  - no interaction, five, an empty prompt, an empty secret, a secret with LF, CR, Ctrl-C or ESC,
    a non-UTF-8 secret and a budget under 1 KiB are `InvalidInteraction`; a zero timeout, an
    overlay naming `Path` and a relative working directory are `Refused` — with a marker proving
    no child ran.
- `cargo test -p arkdeck-platform`: all targets green (lib 59 passed, 1 ignored;
  `windows_tool_dispatch` 21/21 over the refactored spawn; `windows_host_store` 9,
  `windows_transport` 14, `windows_stop` 1, `sha256_backend` 1, `windows_pty_exchange` 9).
- `cargo fmt --all --check`, `cargo clippy --workspace --all-targets -- -D warnings` (Windows),
  `sh scripts/check-sdd.sh`, `git diff --check`: clean. No `windows_pty_exchange` process was
  left running after the runs (`tasklist`).

## Not run, and why

- No hap-sign-tool, keystore, profile or real password: the exchange is driven by the fake
  signer; the real signer on Windows is SPK-10's and M3's once the signing consumers are ported.
- A Java child's `Console.readPassword` on a pseudo console was not run (no JDK was installed or
  launched); the fake signer uses the same console calls (`SetConsoleMode` without
  `ENABLE_ECHO_INPUT`, then `ReadConsoleW` in line mode).
- macOS: not compiled here; the macOS code is unchanged apart from `cfg` attributes and
  `pub(crate)` on shared helpers.
