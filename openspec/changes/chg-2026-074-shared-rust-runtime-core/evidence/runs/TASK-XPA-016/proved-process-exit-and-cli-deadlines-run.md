# TASK-XPA-016 — a proved server is ended once its exit finishes; the CLI's deadline tests outlast their own exchanges

Change: CHG-2026-074-shared-rust-runtime-core@r11. Lane A. One production change (how
`arkdeck-platform`'s `end_proved_process` knows a process has ended) and test changes in
`arkdeck-agentd`, `arkdeck-platform` and `arkdeck-cli` (TASK-XPA-018's console approval and
device wait tests). Host measurements with isolated fake processes only; nothing here is device
evidence. Base: protected main `a6294ec3c` (#2171); developed and measured on `f8cef4c07` (#2170),
rebased without conflict (#2171 touches `arkdeck-cli`'s sources and adds `tests/job_wait.rs`).

## Why

Two load-sensitive failures on protected main `c6f38e7e0`, Swift CI run `36091518181`, both on
the macos-26 Rust workspace job:

- attempt 1, job `107936892818`: `tests/spawning/managed_hdc_server.rs:747`,
  `a_stop_ends_the_proved_replacement_and_the_next_start_launches_its_own` — "a server is left
  on the endpoint": the daemon's stop had answered `ReplacementStop::Ended` and the replacement's
  proof no longer held, yet a connect to the endpoint succeeded.
- attempt 2, job `107938811379`: `arkdeck-cli/tests/console_approval.rs:181`,
  `actual_cli_never_resumes_after_wrong_input_or_expired_deadline_and_never_replays_loss` — the
  CLI under `--timeout 250ms` answered `outcomeUnknown` (exit 75) with `frames: []`, and the fake
  Runtime's second `readline` read end-of-file (`JSONDecodeError: Expecting value: line 1 column
  1 (char 0)`), which the harness counts as an error.

Attempt 3 passed. Neither test is in the diff of #2166/#2167.

## A proved process is reported ended as its exit begins, while it still listens

`end_proved_process` (used only by `ManagedHdc::stop` to end the replacement a confirmed restart
proved; that process is not the daemon's child and cannot be reaped by it) waited until
`proc_pidinfo(PROC_PIDTBSDINFO)` stopped reporting the receipt's birth, and its documentation
took that for "an exited process has none, reaped or not". Measured on this host
(xnu-13432.1.9, macOS 27.0) with C probes (not committed):

- An exited, unreaped child is not reported by `PROC_PIDTBSDINFO` at all.
- An orphan listener (forked, `setsid`, reparented to launchd, as the fake's `kill -r` starts its
  replacement): after SIGTERM its birth disappears within 0.005–0.14 ms, and a connect made the
  moment it has disappeared succeeds in 200 of 200 trials. The kernel hides a process from that
  call as soon as its exit begins; its threads then end and only after that are its descriptors
  closed — the listener among them.
- From the birth disappearing to the process being a zombie or gone (below), with no connection
  made meanwhile: mean 0.48 ms, max 0.86 ms over 500 trials on a quiet host; mean 0.41 ms, max
  9.1 ms, 9 of 300 over 1 ms with 16 CPU burners. With 50,000 descriptors opened after the
  listener, the listener (the lowest descriptor, closed last) lingered 3.5 ms after the birth
  had gone.
- `sysctl` `KERN_PROC_PID` keeps listing the exiting process (with `P_WEXIT`) where
  `proc_pidinfo` does not, and names it a zombie (`SZOMB`) only once its descriptors are closed:
  waiting for "a zombie or not listed" left nothing listening in 100 of 100 trials (20 of 20
  with 50,000 descriptors), as did waiting for kqueue `NOTE_EXIT`.

So `Ended` could be answered while the endpoint was still served. The stop polls every 10 ms,
which hides the window unless the first poll, made right after the signal, already finds the
birth gone, or the exit outlasts a poll — which a loaded runner allows. The fake `hdc`'s
servers never fork, and the replacement's descriptors are only its listener and `/dev/null`
(the `kill -r` launcher forks before the listener exists and its `servers` record is
`O_CLOEXEC`; `lsof` of a live replacement, parent launchd: `/dev/null` on 0–2, the TCP
listener on 3), so no other process holds the socket; since #2156 no other test of the binary
runs meanwhile.

Swift's stop (`HeadlessHDCServerHost.stop`) returns after its executor has collected the
child's termination, so the listener of the only server it stops is closed when it returns (its
contract test still polls up to 2 s). Rust's stop also ends the replacement, and says it leaves
"the endpoint as a stop without a restart does". The fix therefore holds the answer to that:

- `end_proved_process` returns only once `KERN_PROC_PID` lists the receipt's process as a zombie
  or not at all (or the PID with another birth: reaped and reissued); a list the kernel does not
  give is no proof. An exit already under way when the call begins, or when SIGKILL would be moot,
  is given `kill_grace` to finish; one that does not is an error (`ReplacementStop::Survived`),
  never an end. Signals are still guarded by the `proc_pidinfo` birth and uid as before.
- `ProvedProcessEnd`, `ReplacementStop::Ended` and the stop's comment say what an answer now
  means.

The same window broke a sibling test the same way: in
`confirmed_restart_transfers_dispatch_only_after_terminal_identity_proof` the replacement ends
on its own (the fake's `stop` marker) and the test started an unrelated server as soon as its
proof failed. It now also waits, bounded as before, until nothing answers on the endpoint.

### Deterministic reproduction

The race is made certain by observing the criterion as soon as it holds: the stop's 10 ms poll
(and, for the sibling, the test's own 20 ms poll) set to 0, the criterion unchanged:

| Probe build | Test | Result |
| --- | --- | --- |
| old criterion, poll 0 | `a_stop_ends_the_proved_replacement…` | 10/10 failed at :747, "a server is left on the endpoint" |
| new criterion, poll 0 | the same | 10/10 passed |
| old test, poll 0 | `confirmed_restart_transfers_dispatch…` | 10/10 failed: `Occupied("managed HDC endpoint was not absent before the foreground launch: a listener that is not the configured HDC executable holds it")` |
| new test, poll 0 | the same | 10/10 passed |
| old criterion, poll 0 | platform `only_the_proved_process_is_ended…`, new check | 5/5 failed, "the ended server still holds its endpoint" |
| new criterion, poll 0 | the same | 5/5 passed |
| unmodified old build | `a_stop_ends_the_proved_replacement…` | 5/5 passed (quiet host: chance does not reproduce it) |

The sibling's message is also the one #2154's CI run `36060676331` attempt 1 printed, which
#2156 traced to descriptor inheritance; this window is a second way to it.

The platform test now checks, right after `end_proved_process` answers and before the test
reaps its own child, that the endpoint can be bound.

## The CLI's deadline tests: a budget that outlasts the exchanges it covers

`--timeout` starts the CLI's deadline as it begins the leaf, before it connects: the connection,
`health` and the first request share it (`run_agent`, `Client::connect_bounded`). With 250 ms,
a runner that took that long to reach the first request made the CLI give up before sending it —
`outcomeUnknown`, no frame — which is the attempt-2 failure, not the behaviour the test is about
(an answer typed after the deadline is never sent).

- `console_approval.rs`: the expired-deadline run uses a 2 s budget (`DEADLINE_MS`), passed to
  the harness as `timeout_ms`. `support/console_pty.py` no longer sleeps a fixed 350 ms: it types
  the challenge only once the whole budget plus 50 ms has passed since it saw the prompt. The CLI
  writes the prompt after its first request, which its deadline already bounded, so the input
  always arrives after the deadline, however slowly the CLI started. The harness is as strict as
  before (end-of-file before a request is an error), and the test still requires one frame and
  exit 75.

  Counting from `Popen` instead, as first proposed, does not bound it: the deadline starts after
  the CLI has started, and a start slower than the margin lets the answer in before the deadline.
- `device_wait.rs`, `the_client_stops_waiting_without_adopting_or_cancelling_anything`: the same
  shape at 200 ms — the first read must finish inside the budget for `lastObservedGeneration` to
  be `"3"`. It now waits 2 s (at most five reads, 100/200/400/800 ms apart) and is offered eight
  snapshots.
- `support/mod.rs`, `connections()` (behind `run` and `run_partial`): with reads now up to 800 ms
  apart, the fake Runtime's partial mode gave up on the next connection after a fixed 1 s, so a
  CLI stalled between two reads connected after the fake had stopped serving ("no connection
  beyond the exchanges"). It now waits until the CLI process has exited — once it has, every
  connection it made is already queued — with 60 s (partial) and 10 s (exact) as hang bounds
  only. #2171's `job wait` test (`--timeout 300ms`, its reads up to 250 ms apart and never
  bounded by the deadline) runs through the same mode.

Deterministic probes (not committed): the console harness stops the CLI with SIGSTOP right after
the fake Runtime answers `health` (or right after `Popen`); the Rust harness answers the first
`health` late, or stops the CLI after the first exchange while the fake keeps waiting.

| Probe | Before | After |
| --- | --- | --- |
| console, CLI stopped 400 ms after `health` | 5/5 failed: exit 75, `outcomeUnknown`, `frames: []`, the harness's `JSONDecodeError` (the CI failure) | 5/5 passed |
| console, 1500 ms after `health` | — | 3/3 passed |
| console, 1000 ms at start | — | 3/3 passed; timed from `Popen` instead: 3/3 failed, exit 0 with 2 frames (the CLI resumed) |
| console, 2500 ms after `health` (beyond the budget) | — | fails as before: the residual — a first exchange longer than the whole budget |
| device wait, first `health` 300 ms late | 3/3 failed at :153, `lastObservedGeneration` null | 3/3 passed (1500 ms: 5/5) |
| device wait (2 s), CLI stopped 1.2 s after the first read | with the 1 s give-up: 3/3 failed, "no connection beyond the exchanges" | 3/3 passed |

Other sub-second budgets in `arkdeck-cli/tests` are parse-only (`999ms`, `500ms`, `10ms`) or,
like `job wait`'s, not charged with the exchanges they judge. `read_only_resources.rs`'s two
`--timeout 2s` runs with a 1.2 s delayed reply leave 0.8 s for the connection — the same shape
with more room; not changed.

### Swift, checked by reading (no oracle recorded; nothing changed)

Swift's CLI also starts the deadline before its first request (`CLIAgentExecutions.swift`), and
`AgentClient` checks it before the `health` exchange and before writing the request. An expired
deadline is `deadlineExceeded`, which `CLIRuntimeSession.mapped` turns into a `clientTimeout`
transport failure and `CLIControlFailureMapper.code(forTransportFailure:method:)` into
`outcomeUnknown` for a method that is not bounded read-only
(`CLIControlMethodRegistry.swift:401`). So `outcomeUnknown` (exit 75) with no byte written is
Swift's code too; the message differs (Rust: the leaf's "the Job run reply is unconfirmed; …";
Swift: "the client wait deadline expired; no cancellation was requested"). In the test's own
path — the deadline expired while the console was read — Swift's second request fails the same
way (`outcomeUnknown`), while Rust's `run_agent` answers `clientTimeout` from its own check;
both exit 75. These would need a Swift oracle before any change.

## Local targeted checks

With `CARGO_BUILD_JOBS=2`, target `/private/tmp/arkdeck-1330-rust-target`, on `f8cef4c07`, and
for `arkdeck-cli` again after the rebase (below):

- `cargo fmt --all --check`: exit 0.
- `cargo clippy --all-targets -- -D warnings` for `arkdeck-platform` and its direct dependents
  (`arkdeck-agentd`, `arkdeck-cli`, `arkdeck-client`, `arkdeck-hoststore`, `arkdeck-soak`,
  `arkdeck-provider-hdc`, `arkdeck-provider-workspace`, `arkdeck-provider-arkforge`): exit 0;
  `--target x86_64-unknown-linux-gnu` and `x86_64-pc-windows-msvc` for `arkdeck-platform`,
  `arkdeck-agentd` and `arkdeck-cli`: exit 0.
- `cargo test --no-fail-fast` for the same nine crates: exit 0, 192 targets, 1464 passed,
  0 failed, the 18 existing ignored (`tests/spawning` 24 in 50 s, `loopback_server_lease` 8,
  `console_approval` 6, `device_wait` 5, `job_watch` 4). No fake `hdc` left behind.
- The fixed binaries again, 10 runs each with eight CPU burners (load 12–15 on this 8-core
  host): `tests/spawning`'s seven `managed_hdc_server` tests, `loopback_server_lease`,
  `console_approval`, `device_wait` and `job_watch` each passed 10 of 10.
- After the rebase onto `a6294ec3c`: `cargo fmt --all --check` exit 0; `cargo clippy -p
  arkdeck-cli --all-targets -- -D warnings`, host and both cross targets, exit 0; `cargo test -p
  arkdeck-cli --no-fail-fast` exit 0, 44 targets, 268 passed, 0 failed (#2171's `job_wait` 7).
- `sh scripts/check-sdd.sh`: exit 0.
- Not run: `generate-contract.py --check` and `check-contracts.py` (no contract input changed),
  Swift, App, devices, a real `hdc`.

Logs: `/private/tmp/arkdeck-s26-*.log`; probe builds, sources and runs:
`/private/tmp/arkdeck-s26-probe/`.

## Left as they are

- `LoopbackServerLease` scans (and so a post-dispatch observation after an `hdc kill`) cannot see
  a server whose exit has begun either: "no server" there means no live server, not a free port
  for the next half millisecond. A start that races it is refused by its own connect gate rather
  than launched beside it. Whether the real `hdc` server leaves children holding its port was not
  examined (no real tool in this slice).
- The console test's budget can still be outlasted by a first exchange slower than 2 s.

## CI

PR #2174, head `bea19bb50`, merged as `681988448`: Agent PR 36100031789, SDD Guard
36100031801 (`guard`, `ds-tokens`) and Swift CI 36100031948 all succeeded (plan; Rust
host-independent checks; Rust workspace on ubuntu-latest, windows-latest and macos-26; `swift`
aggregate; swift-tests, ds-interactions and app-build skipped by the plan).
