# The lane's `arkforged` ends in Swift's order when the daemon ends without its drain (TASK-XPA-017, S35)

A daemon that ends without its drain — a start that fails once the lane is
composed, or serving that ends in an error — now stops its `arkforged` as
Swift's failed start does:

- the managed HDC server first, then `arkforged`;
- `arkforged` gets its end of input, then TERM to its group, then KILL once
  half a second has passed, and is reaped;
- stderr names it by PID with its end, as it names the managed HDC server
  (#2214's `Launched`).

The drain's order and its output are unchanged.

A paired server any owner drops without its stop now ends in that same order
too. Before, the platform killed it first and closed its input after.

Base: protected `main` `eec3df485` (#2241). Developed and measured on
`a30b1ba62` (#2237), then rebased. The nine commits between touch none of
this change's files, and the checks were run again after the rebase
(Verification). Lane A, agreed with M4. Only the
stop and drop paths change: the lane's composition, protocol, pairing and the
production composition F6 will change are untouched. No contract input,
Catalog or `tasks.md` changes. Fake `arkforged`, fake HDC and disposable roots
only; nothing here is device evidence.

## Swift's stop, as it runs

**One process stop on every path** (`ArkForgeLaneComposition.swift` 574-605,
`stopDaemonProcessGroup`; `IdentityBoundDaemonLauncher.swift` 50-56,
`Handle.terminate`):

| step | what Swift does | bound | past the bound |
|---|---|---|---|
| 1 | closes the liveness, the stdin pipe's write end: the daemon's end of input (54) | — | — |
| 2 | `kill(-pgid, SIGTERM)` right after, with no wait between (55) | — | — |
| 3 | `waitpid(pid, WNOHANG)` every 50 ms; returns once the leader is reaped, or once its group is gone after `ECHILD` (578-590) | 0.5 s | step 4 |
| 4 | `kill(-pgid, SIGKILL)`; returns on `ESRCH` (592) | — | — |
| 5 | the same wait (593-604) | 0.5 s | returns, reaped or not |

**Who calls it, and in what order beside the managed HDC server**
(`main.swift`):

| path | lines | order |
|---|---|---|
| drain (SIGTERM, SIGINT) | 1624-1627 | `drainAndStop(20)`, then `arkforged`, then HDC, then `exit(0)` |
| failed start | 1595-1602 | HDC, then `arkforged`; then "failed to start" (1649) and `exit(1)` |
| second instance | 1581-1589 | HDC, then `arkforged` |
| lane refused after its launch | `ArkForgeLaneComposition.swift` 418, 430, 440 | `arkforged` only |
| lifecycle released | `DaemonLifecycle.deinit` (56) | `arkforged` only, the same stop |
| partial secret | `IdentityBoundDaemonLauncher.swift` 186-192 | close and TERM; no wait, no KILL, no reap |
| managed HDC's foreground exit | 492-496, `exit(70)` | nothing is stopped; the kernel closes the liveness as agentd ends |

So the normal and failure orders differ between the two children, not
inside the process stop.

**What TERM does to Swift's `arkforged`.** Swift's daemon ignores TERM
(`signal(SIGTERM, SIG_IGN)`, 378) before it starts any child. Its launcher
sets only `POSIX_SPAWN_SETPGROUP` (153), so `arkforged` inherits TERM
ignored. `arkforged` installs no handler of its own. Its liveness monitor
(`arkforged/src/main.rs` 219-226, ArkForge `eee57872`) exits 11 at its end of
input. Under Swift, step 2 therefore does nothing to `arkforged`: the end of
input ends it within step 3's half second, or KILL does.

**No wait between the end of input and TERM.** The order this slice was
asked for put a bounded wait for the daemon's own exit between closing its
input and TERM. Swift has none. This change follows Swift (M4's condition),
so a daemon that ends at its end of input may still be sent TERM. The tests
model "ends at its end of input" as Swift runs it: TERM does nothing to the
stand-in, and it exits 11 at the end of its input.

## Rust before this change

The stop itself was already Swift's (`ManagedServer::stop`, M4-2b): close,
TERM, 0.5 s, KILL, 0.5 s, reap. What each holder did without it:

| holder | after the drain | dropped without its stop |
|---|---|---|
| platform `ManagedServer`, paired | its `stop` | No `Drop`. `RunningChild`'s drop SIGKILLed the group and reaped it; the liveness, the last field, closed after. **KILL first, end of input last** (S30's observation in #2214 holds here). |
| provider `Lane` | `stop` | `Drop` called `stop`: Swift's order. The exception was a lock a panic poisoned: the server then dropped by field, KILL first. |
| agentd `Composed` | `stop`: `arkdeck-agentd: stopped arkforged (<exit>)` | No `Drop`. `Lane`'s drop stopped it without a word. |
| agentd `serve()` | `arkforged`, then HDC (Swift's drain) | `arkforged` was declared after the managed server, so it was dropped first: **the reverse of Swift's failed start** |

Measured on the base sources, with this change's tests:

- the three new lane cases pass: the lane's own drop already ended its
  daemon in Swift's order;
- both new platform cases fail;
- the new daemon case fails: the failed start names no `arkforged`.

## Change

- **`arkdeck-platform` `ManagedServer`.**
  - `stop`'s end moved into `end()`, with the same steps and graces; `stop`
    behaves as before.
  - A new `Drop`: a paired server dropped while its liveness is still held
    runs `end()` and is reaped. That is its end of input, TERM to its group
    and 0.5 s, then KILL and 0.5 s: Swift's `DaemonLifecycle.deinit`.
  - An unpaired server (the managed HDC server) is left to the child's own
    drop, as before.
- **`arkdeck-provider-arkforge` `Lane`.**
  - `stop_daemon()` returns `DaemonStop { pid, stopped }`: the launch's PID,
    and what the stop collected or why it failed.
  - A poisoned lock still hands the daemon over, to be stopped in the same
    order.
  - `stop()` is `stop_daemon()`'s collected output, as before.
- **`arkdeck-agentd`.**
  - `arkforge_lane::Composed` gets a `Drop`: it stops the lane's daemon and
    writes one line, `stopped the arkforged this daemon launched (pid N),
    which exited with status S | ended on signal S`, or `… (pid N) did not
    stop: <error>`.
  - After the drain, `stop` has already taken the daemon; `exit(0)` also
    runs no drop. So the drain writes only its old line.
  - `serve()` declares the lane before the managed server. A failed start
    drops, and so stops, the managed server first, then `arkforged`: Swift's
    1595-1602. The drain still stops `arkforged` first, explicitly.

What a failed start now writes (the process test's run, fake `arkforged`
with TERM's default):

```
arkdeck-agentd: stopped the managed HDC server this daemon launched (pid 78567), which ended on signal 15
arkdeck-agentd: stopped the arkforged this daemon launched (pid 78580), which ended on signal 15
arkdeck-agentd: internalFailure("admitted job job-082b8363fce0462b4571a62147751099 has a partial durable projection")
```

The drain, as before: `arkdeck-agentd: stopped arkforged (Signalled(15))`.

## Differences that remain

Each is stricter than Swift, T2, or outside this slice:

- **The wait after TERM and after KILL.** Rust waits for the whole process
  group to drain, probing every 10 ms. Swift waits for the leader's reap,
  probing every 50 ms. Past the KILL grace, Rust still reaps the child (a
  bounded wait, then a background reaper); Swift returns with it unreaped.
- **A partial secret** is closed, sent TERM, then KILL, and reaped. Swift
  closes and sends TERM only. Unchanged here: it is the launch.
- **TERM's disposition in `arkforged`.** Rust's daemon catches TERM
  (`StopSignal`) rather than ignoring it, so `arkforged` starts with TERM's
  default. Under Rust, the TERM right after the end of input usually ends it
  (signal 15) before its liveness monitor exits 11; the process test saw
  signal 15 in both of its cases. It ends promptly either way. Matching
  Swift would change the launch, which this slice leaves alone.
- **`production::compose`.** Its one fallible step after the lane, the App
  ingress configuration (`production.rs` 723-725), still drops the lane
  before the managed server. F6 recomposes that function; the same
  declaration order fixes it there.
- **A release build aborts on a panic** (`panic = "abort"`). Nothing is
  dropped, as when Swift crashes: `arkforged` ends at its end of input when
  the kernel closes the pipe.
- **The managed HDC's foreground exit** (`exit(70)`) stops nothing, as in
  Swift.

## Tests

Order is asserted from state, never from which thread recorded first. Time is
asserted only as a lower bound. One assumption is the product's own bound:
each stand-in must run within the stop's 0.5 s TERM grace.

**`arkdeck-provider-arkforge` `tests/lane.rs`.** Three new stand-ins of the
existing fake `arkforged` catch TERM (`StopSignal`). Each records its events
in `events` with the microsecond. The lane is composed, then dropped without
its stop.

- **`a_dropped_lane_ends_a_daemon_at_its_end_of_input`.** The stand-in
  watches its input, as `arkforged` does; TERM does nothing to it.
  - Expected events: `eof`, `exit 11`.
  - Local run: the drop took 15 ms; `eof` at +0.0 ms, `exit` at +0.2 ms.
- **`a_dropped_lane_sends_term_only_once_the_input_has_ended`.** The
  stand-in does not watch its input. At TERM it reads stdin without waiting:
  0 bytes means the input has ended, would-block means it is still open. It
  then exits 21.
  - Expected events: `term input-ended`, `exit 21`.
  - Local run: TERM at +1.2 ms.
- **`a_dropped_lane_kills_a_daemon_that_outlives_term_after_its_grace`.** The
  stand-in records the same at TERM and keeps running.
  - Expected events: `term input-ended` only.
  - The drop must take at least 0.5 s. Local run: 524 ms.
- **In every case:**
  - the stand-in's PID names no process (`process_argument_record`);
  - `pgrep -f <runtime dir>` finds nothing;
  - its lifelong lock is free.

**`arkdeck-platform` `tests/managed_server.rs`.** A paired shell stand-in,
dropped without its stop.

- **`a_dropped_paired_server_gets_its_end_of_input_then_term_then_kill`.**
  TERM is ignored; the stand-in writes a marker once its input ends.
  - The marker must exist and the drop must take at least 0.5 s.
- **`a_dropped_paired_server_is_sent_term_before_kill`.** The stand-in's TERM
  trap writes a marker.
- Both then require the PID gone and `pgrep -g <pgid>` empty.

**`arkdeck-agentd` `tests/arkforged_owner_stop.rs`** (new, `harness =
false`). The real daemon with its managed server (the fake HDC compiled from
C) and a lane over a verified bundle whose daemon is this test binary.

- **`a_start_that_fails_once_the_lane_is_composed_stops_hdc_then_arkforged`.**
  Job recovery refuses the start after the launch, S30's partial Job.
  - Required: exit 69, then the HDC line, the `arkforged` line, and the
    refusal, in that order and last.
  - The `arkforged` line names the stand-in's own PID. Its end is `exited
    with status 11` or `ended on signal 15`.
  - Both PIDs are gone, and nothing runs from the root.
- **`the_drain_stops_arkforged_with_its_line_as_before`.**
  - SIGTERM after `health`; the daemon exits 0.
  - Its only stop line is `stopped arkforged (Exited(11))` or `(Signalled(15))`.
  - stdout ends with `arkdeck-agentd stopped`.
  - Nothing is left.

**`arkdeck-agentd` unit test.**
`arkforge_lane::tests::a_daemon_ending_without_its_drain_names_the_arkforged_it_stopped`:
the line's three forms.

## Mutations

Each was applied to the final tree, built, and run, then the sources were
restored and checked against their digests (`mut.py`, `mut.sh` and
`final.sha256` in the S35 scratchpad; logs
`/private/tmp/arkdeck-s35-mut-*.log`).

| mutation | caught by |
|---|---|
| M1: skip the end of input before TERM (the liveness kept open through the stop) | platform: the end-of-input case. Lane: all three cases (`ends-at-eof` killed with no events; `term input-open` in the other two). |
| M2: no TERM, KILL at once | platform: both cases. Lane: all three (no events). Daemon: both cases (`ended on signal 9`, `Signalled(9)`). |
| M3: `Composed`'s drop reports nothing | daemon failure case: no `arkforged` line |
| M4: the lane declared after the managed server again | daemon failure case: the `arkforged` line comes before the HDC line |
| base `ManagedServer` (no paired drop) | platform: both cases. The lane cases pass: `Lane`'s drop already stopped in order. |
| base agentd (`arkforge_lane.rs`, `main.rs`) | daemon failure case: no `arkforged` line. The drain case passes: its output is unchanged. |

## Verification

**Local targeted checks.** Worktree `/private/tmp/arkdeck-s22-lane`, target
`/private/tmp/arkdeck-1330-rust-target`, `CARGO_BUILD_JOBS=2`, logs
`/private/tmp/arkdeck-s35-*.log`.

| check | command | result |
|---|---|---|
| fmt | `cargo fmt --all --check` | exit 0 (`fmt.log`) |
| clippy, host | `cargo clippy -p arkdeck-platform -p arkdeck-provider-arkforge -p arkdeck-agentd --all-targets -- -D warnings` | exit 0 (`clippy-host.log`) |
| clippy, Linux | the same with `--target x86_64-unknown-linux-gnu` | exit 0 (`clippy-linux.log`) |
| clippy, Windows | the same with `--target x86_64-pc-windows-msvc` | exit 0 (`clippy-windows.log`) |
| clippy, the platform's other dependents | `cargo clippy -p arkdeck-provider-hdc -p arkdeck-hoststore -p arkdeck-bootstrap -p arkdeck-provider-workspace -p arkdeck-cli -p arkdeck-client -p arkdeck-soak --all-targets -- -D warnings` | exit 0 (`clippy-dependents.log`) |
| tests | `cargo test --no-fail-fast -p <crate>`, after `cargo build -p arkdeck-cli` for agentd | exit 0 each: `arkdeck-platform` 201 passed, 4 ignored (20 binaries); `arkdeck-provider-arkforge` 24 (5); `arkdeck-provider-hdc` 181 (17), the managed HDC server's `ManagedServer` user; `arkdeck-agentd` 184 (22) (`test-<crate>.log`) |
| repeated, quiet | the new binaries run again, load 4 | lane 5/5, platform drop cases 5/5, daemon cases 3/3 (`repeat-quiet.log`) |
| repeated, loaded | the same beside 8 CPU burners (8 cores) | lane 3/3, platform 3/3, daemon 2/2; the `ignores-term` drop took 516-522 ms (`repeat-loaded.log`) |
| read-only host check | `rust/scripts/check-readonly.py --bin-dir <target>/debug` (validation venv) | exit 0, `PASS`; 136 control responses (`check-readonly.log`) |
| records | `sh scripts/check-sdd.sh` (validation venv) | exit 0 (`check-sdd.log`) |
| leftovers | `pgrep -fl 'pair-from-stdin'` and a search for every scene root after the runs | none of these tests' processes. The one match is the installed Swift daemon's own `arkforged`, which nothing here touched. |
| after the rebase onto `eec3df485` | fmt; the three crates' clippy for the host, Linux and Windows; `cargo test --no-fail-fast` of `arkdeck-provider-arkforge`, `arkdeck-platform` and, after `cargo build -p arkdeck-cli`, `arkdeck-agentd`; the read-only host check | exit 0 each: 24, 203 passed with 4 ignored, and 185; `PASS` (`r2-*.log`). The failed start's lines and the drain's line were as above. |

Not run: `generate-contract.py --check` and `check-contracts.py`, since no
contract input changed; Swift and the App, since nothing of theirs changed;
tests of the platform's other dependents, which use neither `ManagedServer`,
`Lane` nor `Composed` (their clippy above compiles them); a real `arkforged`,
a device, or the production composition over an account.

**CI.** Pending.
