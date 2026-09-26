# The lane's `arkforged` starts with SIGINT and SIGTERM ignored, as under Swift's daemon (TASK-XPA-017, F6a)

The Rust daemon now launches the lane's `arkforged` with SIGINT and SIGTERM
ignored, as Swift's daemon does. TERM to its group, the second step of every
stop, therefore does nothing to it, and its end of input ends it with status
11, as it ends under Swift. The daemon's own handling of both signals is
unchanged, and so is every other child's.

The production composition also configures its App ingress before it starts
any child. A failure after both children run would now stop the managed HDC
server first and `arkforged` after it, in Swift's order.

Both were asked for by the coordinating session on 2026-09-26, after S35
(#2244). They are the first slice of F6; the production lane itself waits for
the ArkForge client change. Developed and checked on protected `main`
`82706393d` (#2243), then rebased onto `167783bb1` (#2219), which changes one
design document only; `check-sdd` was run again after the rebase. No
contract input, Catalog or `tasks.md` changes. Only fakes and disposable
roots were used, so nothing here is device evidence.

## What Swift does

- **The daemon ignores both signals before any child starts.**
  `main.swift` 377-378 call `signal(SIGINT, SIG_IGN)` and
  `signal(SIGTERM, SIG_IGN)`. A `DispatchSource` watches for the stop.
- **Its launcher resets no disposition.**
  `IdentityBoundDaemonLauncher.swift` 153 sets only `POSIX_SPAWN_SETPGROUP`.
  No Swift source sets `POSIX_SPAWN_SETSIGDEF`. An ignored disposition
  survives `exec`, so `arkforged` starts with both signals ignored.
- **`arkforged` installs no handler of its own.** ArkForge `main` `9ddede5`
  has none, and the pinned `eee57872` has none either. Its liveness monitor
  (`arkforged/src/main.rs` 219-226) exits 11 at its end of input.

So under Swift, step 2 of `stopDaemonProcessGroup` (TERM to the group) does
nothing to `arkforged`. Its end of input ends it within step 3's half second,
and KILL is used only if it does not.

## The Rust daemon before this change

- **The daemon catches both signals** (`StopSignal`). A caught disposition
  resets to the default across `exec`. The lane's `arkforged` therefore
  started with the default action for both: the difference `managed-hdc-daemon-run.md`
  (TASK-XPA-016) declares for every child.
- **The stop raced.** The stop sends TERM right after closing the input.
  `arkforged` either exited 11 at its end of input or died of that TERM.
  S35's tests accepted both endings: `exited with status 11` or
  `ended on signal 15`, and `Exited(11)` or `Signalled(15)`.

## Change

### `arkdeck-platform`

- **`ManagedServer::launch_paired`** starts its child with SIGINT and SIGTERM
  ignored. This is Swift's `IdentityBoundDaemonLauncher`; its only caller is
  the lane. `launch`, used for the managed HDC server, and every tool spawn
  are unchanged.
- **`macos_process::spawn_suspended_ignoring`** is the mechanism.
  - Why not `posix_spawn`: it can reset a disposition to the default but
    cannot set one to ignore.
  - Why not change this process: it catches both signals. Ignoring them
    here, even for one spawn, would drop a stop request that arrived in that
    moment. It would also pass the ignore to any other child spawned then.
  - So this thread forks with every signal blocked. The copy sets SIGINT and
    SIGTERM to ignored in itself alone, joins its own process group, and
    waits for one byte.
  - While the copy waits, it is the child. It has the tool's PID and birth,
    and it has run no tool code. The owner records the birth and checks the
    tool again, as it does for a child created suspended.
  - `resume` sends the byte. The copy then applies what `posix_spawn` gives
    every child here: the working directory, `stdin` or `/dev/null`, the two
    capture pipes, and no other descriptor (it closes all the rest, as
    `POSIX_SPAWN_CLOEXEC_DEFAULT` does). It restores the spawning thread's
    signal mask and `execve`s the tool through its retained inode.
  - If a step fails, the copy writes the error to its report pipe and exits
    127, and `resume` returns that error. A successful `exec` closes the
    report unread.
  - From the fork to the `exec`, the copy makes only async-signal-safe calls
    over values prepared before the fork. It allocates nothing, and no
    handler it inherited can run in it.
- **`SuspendedChild`** records how it resumes: SIGCONT for a child
  `posix_spawn` created suspended, or the byte for a forked copy. The
  `posix_spawn` path is otherwise unchanged.

### `arkdeck-agentd` `production::compose`

- **The App ingress is configured before any child starts.** Rust's
  configuration can fail and Swift's listener cannot. Previously it ran after
  the managed HDC server and `arkforged` had started, and a failure there
  dropped `arkforged` first. It reads only the state root that `compose`
  validates on its first lines, so it now runs there. The line that says the
  ingress was omitted over an overridden home keeps its place.
- **`arkforge` is declared before the managed server,** as `main.rs` holds
  them since S35. Any later failure, once both children run, drops the managed
  server first and `arkforged` after it: Swift's failed start
  (`main.swift` 1595-1602). No step after the lane can fail today.

## Declared difference, closed for `arkforged`

`managed-hdc-daemon-run.md` (TASK-XPA-016) declares: "Signals are caught, not
ignored … the Rust daemon's children keep the default action."

- **The lane's `arkforged`:** closed. It starts as Swift's does.
- **Every other child:** still declared. This covers the managed HDC server
  and the tools.

S35's run record allowed either ending for the stop line. Now only
`exited with status 11` and `Exited(11)` are correct, and the tests require
them.

## Tests

- **`arkdeck-platform` `tests/managed_server.rs`**
  - New:
    `a_paired_server_starts_with_sigint_and_sigterm_ignored_and_ends_at_its_end_of_input`.
    - The kernel's record of the child (`kinfo_proc` `p_sigignore`) lists
      both signals as ignored.
    - After INT and TERM to its group, the child's stop ends with
      `Exited(0)`: its end of input ended it.
    - Its mask is the test thread's, as Perl reports it.
    - A descriptor the test deliberately leaves open across `exec` does not
      reach it.
    - The test process's own dispositions are unchanged.
    - An unpaired server ignores only what the test process ignores, so the
      case holds under a runner that starts it with either signal ignored.
  - `a_dropped_paired_server_is_sent_term_before_kill`: the stand-in must
    catch TERM itself. `/bin/sh` cannot undo an ignore it inherited, so the
    stand-in is now Perl.
    - It waits in 10 ms steps. Perl runs a handler between operations, so a
      TERM landing just before a one-second sleep would wait out that sleep.
    - With `sleep 1`, the first version failed 4 of 8 runs. It then passed 12
      of 12.
- **`arkdeck-provider-arkforge` `tests/lane.rs`**
  - A composed lane's stop now requires `Exited(11)` and the stand-in's
    `eof` note.
  - The not-ready refusal now requires the `eof` note.
  - The stop-order stand-ins still catch TERM themselves and are unchanged.
- **`arkdeck-agentd` `tests/arkforged_owner_stop.rs`**
  - The failed start's line now requires
    `exited with status 11`.
  - The drain's line now requires `stopped arkforged (Exited(11))`.

## Mutations

`f6a-mutations.py` applied each mutation to the tree, ran the tests, then
restored the source and checked it against its digest. The last run of the
restored tree exited 0.

| mutation | caught by |
|---|---|
| `launch_paired` spawns without the ignore | the new case: `ignored` is `[false, false]` |
| the copy ignores nothing | the same |
| the copy keeps every descriptor | the new case: the leaked descriptor reached the server |
| the copy keeps every signal blocked | the new case: the mask lists every signal but 9 and 17. The TERM case also fails: TERM stays blocked, so only KILL ends the stand-in |

No test covers the production composition's declaration order. No step after
the lane can fail, so a test could not reach that failure.

## Verification

**Local targeted checks.** Main worktree, target
`/private/tmp/arkdeck-m4-rust-target` (`-win` and `-linux` for the cross
checks), `CARGO_BUILD_JOBS=2`. Logs are under the session's scratchpad
`f6a-logs/`.

| check | result |
|---|---|
| `cargo fmt --all --check` | exit 0 (`fmt.log`) |
| `cargo clippy --all-targets -- -D warnings`, host: `arkdeck-platform`, `-provider-arkforge`, `-agentd` and the platform's other direct dependents (`-cli`, `-hoststore`, `-client`, `-bootstrap`, `-provider-workspace`, `-provider-hdc`, `-soak`) | exit 0 (`clippy.log`) |
| the same for Windows (`x86_64-pc-windows-msvc`) and Linux (`x86_64-unknown-linux-gnu`): `arkdeck-platform`, `-provider-arkforge`, `-agentd` | exit 0 each (`clippy-windows.log`, `clippy-linux.log`) |
| `cargo test` for each of those ten crates, after `cargo build -p arkdeck-cli -p arkdeck-agentd` | exit 0 each (`test-<crate>.log`): platform 204 passed, 4 ignored (20 binaries); provider-arkforge 24 (5); agentd 185 (22); provider-hdc 181 (17); bootstrap 34, 1 ignored (2); client 10 (4); provider-workspace 27 (4); soak 4 (4); cli 402 (61); hoststore 659, 18 ignored (89) |
| after the last test edit (the unpaired contrast): fmt, the platform's clippy, and its `managed_server` binary six times | exit 0; 7 passed each run (`r2-*.log`) |
| `a_dropped_paired_server_is_sent_term_before_kill` alone, 12 runs | 12 passed |
| the platform's `managed_server` binary, 8 runs before that edit | 8 passed |
| the four mutations, again on the final tests | each caught as above; the restored tree exit 0 (`mutations.log`) |
| `sh scripts/check-sdd.sh` | exit 0 (`check-sdd.log`) |

Not run:

- `generate-contract.py --check`: no contract input changed.
- Swift and the App: nothing of theirs changed.
- A real `arkforged`, a device, or the production composition over an
  account.

**CI.** Pending.
