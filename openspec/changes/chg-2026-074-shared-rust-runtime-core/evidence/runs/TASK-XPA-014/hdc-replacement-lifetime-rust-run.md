# TASK-XPA-014 — Rust HDC replacement server lifetime across daemon stop and restart

Base: protected main `55e00d50a` (#2128). This continues the C2b port on macOS
(#2101/#2102/#2104/#2105/#2107) at the gap #2105 and #2107 left open: who owns
the replacement server a confirmed `kill -r` starts once the daemon stops or
ends. No Catalog operation, contract input, schema, capability, trusted fact,
device authority or completion status changes. Everything below is isolated
host-process evidence over the compiled fake HDC, never REAL_DEVICE_PASS.

## Swift semantics (the standard for this port)

- `kill -r` starts the replacement in a session of its own (HDC's client-side
  daemonisation; the fake mirrors it), so it is no child of the daemon in Swift
  or in Rust. The Supervisor holds it as `arkDeckManaged` with the resulting
  generation, in memory only (`ArkDeckOpenHarmony.swift:2004-2008`,
  `managedProvenance`/`arkDeckLaunchedGenerations` at `:1368`/`:1373`).
- Normal stop (SIGTERM/SIGINT, `main.swift:1606-1633`): `drainAndStop(20)`,
  ArkForge stop, `HeadlessHDCServerHost.stop()` (`HeadlessHDCServerHost.swift:299`:
  request stop, cancel the task that ran the original foreground child), exit 0.
  After a restart nothing reaches the replacement: it keeps listening, although
  the host's own contract says stopping it drains the listener
  (`AgentDaemonContractTests.swift:6341`) and `main.swift` says cancellation tears
  down the dedicated server on LaunchAgent update/uninstall.
- Crash paths: exit 70 only for an unexpected exit of the original foreground
  child (`main.swift:496`); after a restart's 20 s expected window nothing
  watches the replacement. SIGKILL or a trap runs no stop, so the replacement
  (and after SIGKILL also a still-running original child) stays.
- Next start: a fresh Supervisor, so `authorizeManagedStart`
  (`ArkDeckOpenHarmony.swift:1728`) checks only its empty memory and launches a
  second `hdc -s <endpoint> -m` beside the leftover. That launch cannot own the
  endpoint, or is not the listener's owner, so readiness fails
  (`serverDidNotBecomeReady`); composition refuses to continue because it "would
  publish a Runtime whose HDC ownership is unknown" (`main.swift:577-583`) and
  exits 1 (`main.swift:1648-1650`). launchd KeepAlive retries and fails the same way
  until the leftover ends. Swift never adopts or stops the leftover and serves
  no `runtime.hdc.status` meanwhile.
- Interrupted lifecycle records are recovered lazily when the new epoch first
  reads them (`approvalRecorded` invalidated, `dispatchPrepared` failed,
  `dispatching` outcomeUnknown with a missing-observation reconciliation) and
  are never replayed. This slice leaves that unchanged.
- Spec: REQ-HDC-003 forbids any automatic kill/restart of an `external` or
  `unknown` server; AC-HDC-003-02 marks `arkDeckManaged` only when the endpoint
  had no server before ArkDeck's start and PID, tool path and endpoint verify.

Rust before this slice had the same outcomes: `ManagedHdc::stop` ended only the
original child, and `ManagedHdcServer::start` launched `-m` first and then failed
in readiness (the fake's bind exit 67, or `Unbound`), so a start beside a
leftover exited 69 with a race-dependent reason after running a second server
process of the tool.

## What this slice changes

1. **A normal stop ends the replacement a confirmed restart proved.**
   `ManagedHdc::stop` now also ends `DispatchOwnership::Replacement(lease)`, but
   only while the tool still verifies, the retained lease still revalidates, and
   a fresh two-scan `LoopbackServerLease::acquire` names exactly that process as
   the endpoint's owner. The new platform primitive `end_proved_process` rereads
   the PID's birth and user immediately before each signal, signals only that PID
   (never a group; PID 0 and negative PIDs are refused), SIGTERM, then SIGKILL
   after 250 ms, and waits 1 s for the end (Swift's group-drain budgets). An
   uncertain outcome (`Pending`/`Unknown` ownership) and anything the fresh proof
   does not name are never signalled (REQ-HDC-003); the daemon reports these on
   stderr. stdout stays `arkdeck-agentd stopped`.
2. **A start refuses an occupied endpoint before launching anything.**
   `ManagedHdcServer::start` first asks the endpoint itself, by the connect-only
   reachability probe Swift's readiness already uses (no HDC client runs). If
   anything answers, nothing is launched and the new
   `StartFailure::Occupied` names the holder from the commandless proof: a
   server of the configured executable this launch did not start (PID and
   generation), a listener of another executable, or an unprovable owner. It is
   neither adopted nor stopped, and the daemon exits 69 with Swift's own message,
   "managed HDC endpoint was not absent before the foreground launch". The proof
   after the launch still decides a listener that appears in between.

| Path | Before (Swift and Rust) | Now |
| --- | --- | --- |
| restart, SIGTERM/SIGINT, start | replacement survives; every start fails | stop ends the proved replacement; the start launches and proves its own server; the durable record read by a new epoch is unchanged and nothing reruns it |
| restart, SIGKILL or exit 70, start | leftover survives; a second `-m` launches and the start fails | every start refuses before launching, naming the leftover (PID, generation); nothing is adopted or stopped; once it ends, a start works |
| uncertain restart outcome, stop, start | nothing signalled; start fails | nothing signalled (`Uncertain`); start refuses, naming it |
| replacement replaced by an unrelated server, stop, start | not touched; start fails | fresh proof differs, so nothing is signalled (`Unproved`); start refuses, naming it; never inherited |
| foreign listener on the endpoint, start | `-m` launched, readiness fails | refused before launch |

### Declared differences from Swift (maintainer 09-20 practice: fix in Rust, record the difference)

- **D1:** Swift's stop leaves the replacement listening, contrary to its own
  "stop drains the listener" contract, so the next start cannot proceed. Rust
  ends it under the proof conditions above. This is the same interruption a stop
  already imposes on the original managed child and on every client sharing the
  endpoint. REQ-HDC-003 permits it only because the server is `arkDeckManaged`
  by the audited restart's proof.
- **D2:** Swift's absence gate reads only the Supervisor's memory, which every
  start begins empty, so it runs a second server process beside the leftover
  before failing. Rust checks the endpoint first and launches nothing. The
  fail-closed outcome is the same (the start is refused, nothing is adopted or
  stopped), and no second server process ever runs. D2 is stricter than Swift in
  one edge: a non-HDC wildcard listener on the port also refuses the start.
- Residual: macOS offers no descriptor that pins a non-child process. The birth
  reread immediately before each signal is what keeps a recycled PID from being
  signalled; the kernel hands PIDs out in turn.

## Maintainer decision needed: the crash paths

The queue's target was that after SIGKILL or exit 70, the next start's
`runtime hdc status` gives an ownership conclusion by claiming or rejecting the
leftover. That requires a start that serves beside a server it did not launch,
which Swift refuses by design (`main.swift:577-583`) and AC-HDC-003-02 does not
allow for claiming. That is a change to fail-closed startup semantics and an
Acceptance Scenario, so this slice stops at the Swift-equivalent refusal (made
deterministic and launch-free by D2) and asks. Options:

- **A — keep refusing (current).** Spec-safe and Swift-equivalent. Downside:
  under launchd KeepAlive the daemon keeps restarting until an operator ends the
  leftover (`hdc -s <endpoint> kill`). The refusal names it, but App and CLI see
  no daemon and no `runtime.hdc.status`.
- **B — serve degraded.** Start without a managed server; `runtime.hdc.status`
  names the holder with ownership `unknown` (or `external` by Swift's
  four-evidence rule, with durable restart records counting as ArkDeck-launched
  generations); every HDC dispatch is refused; recovery through the existing
  audited, user-confirmed lifecycle path (AC-HDC-010-02). Needs a new status
  reason and probably schema widening plus Swift frames (contract inputs), and it
  reverses Swift's explicit refusal to publish unknown HDC ownership.
- **C — claim by durable proof.** Persist the managed launch receipt and each
  confirmed restart's resulting identity (PID, birth, tool path and digest, argv,
  endpoint). On start, adopt the endpoint's unique owner only if a fresh two-scan
  proof plus `verifies_managed_process` equals that record; otherwise fall back to
  A or B. No interruption for other clients on the endpoint (the default 8710 is
  shared with DevEco). Needs an OpenSpec delta to AC-HDC-003-02 and review of the
  new durable record.
- **C' — stop by durable proof, then start fresh.** Same record, but the start
  ends the proved leftover instead of adopting it, then launches its own
  (AC-HDC-003-02 holds for the new server). It interrupts clients on every crash
  recovery, and whether a previous epoch's managed server counts as
  `arkDeckManaged` under REQ-HDC-003 is an interpretation the maintainer owns.

Recommendation: C, with anything unproved falling back to B (or A until B's
contract work exists). None of these is implemented here.

## Tests

In-process, real fake HDC processes and the real durable owner, lifecycle driver
and verified runner (`cargo test -p arkdeck-agentd --bin arkdeck-agentd -- managed_hdc::`):

- `a_stop_ends_the_proved_replacement_and_the_next_start_launches_its_own`:
  restart, stop, start.
- `a_crash_after_a_restart_leaves_its_replacement_and_starts_refuse_it_until_it_ends`:
  restart, no stop, start (refused twice with the exact message and no launch,
  then works after an operator `kill`).
- `an_unrelated_server_in_the_replacements_place_is_neither_stopped_nor_inherited`.
- `host_never_claims_zero_dispatch_after_lifecycle_audit_failure` now also checks
  that all four uncertain outcomes stop as `Uncertain`, leave the server the
  restart started untouched, and refuse the next start without a launch.

The restart itself cannot run through the daemon socket in a process test: the
production impact source proves no identity for the fake's digest (as Swift's
proves none for its fixture), and the synthetic impact source exists only in the
unit-test binary. The process tests therefore cover the daemon boundaries with
the same leftover shapes (`cargo test -p arkdeck-agentd --test managed_hdc_process`):

- `an_external_restart_leaves_a_server_every_start_refuses_until_it_ends`:
  another client's `kill -r`, daemon exit 70, start refused (exact message,
  zero `-m` launches), leftover untouched, operator `kill`, start, status,
  SIGTERM exit 0, nothing left.
- `a_killed_daemon_leaves_its_server_and_every_start_refuses_it_until_it_ends`:
  SIGKILL, orphaned original child, the same checks.
- `a_foreign_listener_on_the_endpoint_never_becomes_the_managed_server` now
  asserts the refusal names the foreign holder and that nothing was launched.
- The process tests' fake now records calls, stops via its marker, and ends its
  servers when the test process ends; `Runtime`'s drop also reaps `kill -r`
  servers with #2128's `fake_hdc_servers::tear_down`.

Provider (`--test managed_server`): an occupied endpoint is refused before any
invocation, both for a foreign listener and for a server of the same executable
(named by PID and generation, left running). `Unbound` stays covered
deterministically by a listener that appears only after the launch. Platform
(`--test loopback_server_lease`): `end_proved_process` terminates a proved
listener, kills one that ignores SIGTERM, signals nothing for a birth one
microsecond off or for an already-ended process, and refuses PIDs 0 and -1.

Mutation runs were not performed: the local environment refused a temporary
edit that disabled the absence gate. The assertions above name the new
behaviour directly (launch counts, exact refusal text, surviving versus ended
PIDs).

## Local targeted checks

Rust uses `CARGO_BUILD_JOBS=2` and `CARGO_TARGET_DIR=/private/tmp/arkdeck-1330-rust-target`.

- New and changed tests first: platform `--test loopback_server_lease` 8 passed;
  provider `--test managed_server` 9 passed; agentd `managed_hdc::` 7 passed;
  agentd `--test managed_hdc_process` 9 passed (after `cargo build -p arkdeck-cli`);
  all exit 0. Logs: `/private/tmp/arkdeck-s8-platform-lease-1.log`,
  `/private/tmp/arkdeck-s8-provider-managed-1.log`,
  `/private/tmp/arkdeck-s8-agentd-unit-1.log`,
  `/private/tmp/arkdeck-s8-agentd-process-1.log`.
- `cargo fmt --all --check`: exit 0 (`/private/tmp/arkdeck-s8-fmt-3.log`).
- `cargo clippy -p arkdeck-platform -p arkdeck-provider-hdc -p arkdeck-provider-workspace -p arkdeck-hoststore -p arkdeck-client -p arkdeck-cli -p arkdeck-agentd -p arkdeck-soak --all-targets -- -D warnings`
  (the changed crates and every direct dependent): exit 0
  (`/private/tmp/arkdeck-s8-clippy-2.log`, final tree).
- `cargo test --no-fail-fast` for the same eight crates: exit 0, 151 test
  targets, 1,143 passed, 0 failed, 18 existing ignored (not counted as passes)
  (`/private/tmp/arkdeck-s8-test-8crates.log`). That build preceded a rename
  of one closure parameter inside `end_proved_process`; on the final tree the
  platform lease tests (8), agentd `managed_hdc::` (7), `managed_hdc_process`
  (9) and provider `managed_server` (9) and `lifecycle` (7) passed again
  (`-platform-lease-2`, `-agentd-unit-2`, `-agentd-process-2`, `-provider-2`
  logs), and the two agentd sets three times more each
  (`-agentd-{process,unit}-repeat-{1,2,3}.log`), load average about 2.2.
- Orphan check after every run:
  `ps -axo ppid=,command= | awk '$1==1 && $2 ~ /arkdeck-managed-hdc-/'` found 0.
- `sh scripts/check-sdd.sh`: exit 0, 0 errors and 0 warnings
  (`/private/tmp/arkdeck-s8-sdd.log`).
- Not run: `generate-contract.py --check` and `check-contracts.py` (no contract
  input changed); Swift/App (untouched); no real HDC, device, installed Runtime or
  LaunchAgent was used.

## CI

PR #2131, head `67ca7f682`; merged as `20abb8553`.

- SDD Guard `35884169583` passed (`guard`, `ds-tokens`); Agent PR `35884169769`
  passed.
- Swift CI `35884169894` passed: `plan`, Rust host-independent checks, the Rust
  workspace on ubuntu-latest, macos-26 (job `107260033191`) and windows-latest,
  and the `swift` aggregate. `swift-tests`, `app-build` and `ds-interactions`
  were skipped by the plan; a skipped job is not a pass.
