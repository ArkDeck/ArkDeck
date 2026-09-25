# An isolated start is refused before its managed HDC server launches, and a start that fails after the launch stops that server (TASK-XPA-014, macOS, 2026-09-26)

TASK-XPA-014 / CHG-2026-074, lane A. Found by #2197's CI. Developed and measured on protected
`main` `a3de6c316` (#2207), then rebased onto `fd17a5691` (#2213) before the push; the three
commits in between change only the CLI. Disposable host data and a fake `hdc` compiled from C
only; nothing here is device evidence.

## Failure

Swift CI run `36165807465`, job `108173208008` (`rust-checks / Rust workspace (macos-26)`), on
#2197's head `1beb3de44`:

```
panicked at crates/arkdeck-agentd/tests/managed_hdc_process.rs:898:9:
[("ARKDECK_DEVELOPMENT_MUTATION_AUTHORITY", "yes"), ("ARKDECK_DEVELOPMENT_HDC_SERVER", "managed"),
 ("OHOS_HDC_SERVER_PORT", "38518")]: no managed server was started
```

The test's rule is that a composition the acknowledgment does not name "fails startup before any
server starts". Its `fake_running` is `pgrep -f <root>/tools/hdc`, and the root is random per test.
So only a server launched by that refused start could match.

## Two defects

1. **The refusal came after the launch.** On `a3de6c316`, `serve()` validated some development
   inputs only after `development_hdc()` had started the managed server (`main.rs:158`):
   - `ARKDECK_DEVELOPMENT_USB_RELATIONS`, which must be an absolute path
     (`DevelopmentUsbRelations::from_environment`, `:490`);
   - `ARKDECK_DEVELOPMENT_CODE_SIGN_HELPER`, its path and its bytes (`:564`–`569`);
   - `ARKDECK_DEVELOPMENT_MUTATION_AUTHORITY`, its value and its combination (`:570`–`576`).

   Each of these refusals ran the fake twice before exiting 69: `-s 127.0.0.1:<port> -m` and a
   readiness `checkserver`. The start took about 0.5 s instead of 5 ms.
2. **The exit could leave the launched server running.** On a failure, `serve()` returned and
   only dropping the last `Arc<ManagedHdc>` stopped the server (`RunningChild`'s drop sends
   SIGKILL and reaps). The foreground-exit monitor started just before
   (`monitor_foreground_exit`, `managed_hdc.rs:149`) upgrades its `Weak` to a strong reference on
   every pass. If `serve()` dropped its references while the monitor held one, the monitor dropped
   the last one. `main` meanwhile called `exit(69)`, which ended the monitor thread before it
   stopped the server. The server was left running with PPID 1, nobody's child, holding the
   endpoint. Every later start refuses while it holds the endpoint (`StartFailure::Occupied`).
   This is a second way to orphan a server. The first is a daemon that SIGTERM kills without a
   drain.

## From the environment to the first launch, before the fix

`serve()` on `a3de6c316`, in order (`main.rs`):

1. `ARKDECK_RUNTIME_COMPOSITION` (`production::requested`, `refuse_other_compositions`).
2. `ARKDECK_APP_INGRESS` (`app_ingress::Configuration::from_environment`).
3. The development inputs a standalone or facade start may not name (`:198`–`256`).
4. The facade, if it applies; the argument count; `StopSignal`; the endpoint; `Host`; the bundled
   helper.
5. The isolated branch:
   - the endpoint and root checks;
   - `bind_facade`, the private children and every store;
   - the analyzer and workspace inputs.
6. `development_hdc()`:
   - `ARKDECK_DEVELOPMENT_HDC_SERVER`, the USB acknowledgment's value, the HDC path;
   - the path's digest and whether it is registered;
   - `development_usb::admit`;
   - `OHOS_HDC_SERVER_PORT`;
   - **the launch** (`ManagedHdc::start`: a connect gate, then `hdc -s <endpoint> -m`, readiness,
     `checkserver`, and the identity proof).
7. After the launch:
   - `monitor_foreground_exit`;
   - the refusals listed under the first defect;
   - `arkforge_lane::compose`, which never refuses, but launches `arkforged` when a bundle is
     named;
   - Job recovery, the Loader transition, `Control::new`, the App ingress's `listen`, and any
     accept error while serving.

The production composition refuses its own inputs before it claims anything
(`Inputs::from_environment`, absolute paths). Its launch is inside `production::compose`
(`production.rs:639`). After it, only owner and filesystem steps can fail:
- the monitor;
- `hdc-control-actions`;
- `HdcControlActions::open`;
- `OwnerContext::production`;
- the dispatch tool;
- `app_ingress::Configuration::production`.

Each of these failures reached the same drop path, so the same orphan was possible, around a real
server.

## Deterministic reproduction

The window is a monitor pass holding its strong reference as `serve()` fails. A probe build widens
it without changing what happens in it. The probe is not committed: `monitor_foreground_exit` sleeps
`S30_PROBE_MONITOR_HOLD_MS` after each `upgrade()`, as a thread descheduled inside
`foreground_exit` would. Without the variable the build behaves like the base.

- **The CI test, base test source and base daemon.**
  - Without the hold, 3 of 3 runs pass.
  - With a 300 ms hold, 3 of 3 runs fail at `managed_hdc_process.rs:898` with CI's message.
- **An external probe (`refused_start_probe.py`), base daemon.** It runs the refused start over
  the test's own fake. It counts the fake's recorded runs and `pgrep`s the fake's path after the
  daemon exits, recording PID and PPID.

  | refused input (managed server, port set) | hold | exit 69 | launched | left running (PPID 1) |
  | --- | --- | --- | --- | --- |
  | mutation authority `yes` | none | 5/5 | 5/5 | 0/5 |
  | mutation authority `yes` | 300 ms | 5/5 | 5/5 | 5/5 (e.g. pid 74508 `…/tools/hdc -s 127.0.0.1:64812 -m`) |
  | helper not an ELF / helper relative / relations relative | none | 3/3 each | 3/3 each | 0/3 each |
  | helper not an ELF / relations relative | 300 ms | 3/3 each | 3/3 each | 3/3 each |

- **After the fix, same probe and hold.** The table's rows give exit 69 in 5 of 5 and 3 of 3
  runs, with 0 launches, 0 fake runs and nothing left running, with or without the hold. The
  refusal comes in 5–6 ms; the first run, at 0.58 s, includes loading the binary.
  - The new post-launch test with the hold passes 3 of 3 runs. Its stderr shows, in order:
    `s30-probe: the foreground-exit monitor holds the managed server for 300 ms`,
    `arkdeck-agentd: stopped the managed HDC server this daemon launched (pid 99073), which ended
    on signal 15`, then the recovery refusal.

## Change

- **`development_admission.rs` (new).** It decides every value and combination of the isolated
  owner's development inputs, before anything is opened or started. `serve()` calls it once,
  right after the standalone and facade refusals.
  - **`admit(variable)`** is a pure function of the environment lookup. It returns the admitted
    inputs or the first refusal: the server mode, the USB acknowledgment, the HDC path and its
    absoluteness, the managed endpoint (`EndpointSelection::select`), the relations path, the
    helper path, and the mutation authority's value and combination.
  - **`Admission::admit_registration(registered)`** is also pure. It holds the refusals that
    depend on whether the HDC's digest is a registered HDC's.
  - Messages are unchanged.
- **`measured_hdc` and `MeasuredHdc::start` (`main.rs`) replace `development_hdc()`.** Before
  the launch, the owner reads the HDC's bytes and asks `admit_registration`. It opens every
  verified tool it will need, the launch's and the dispatch's. It also verifies the named
  helper's bytes. After that, only the launch can fail.
  - After the launch, the relations source comes from the admission, as does the mutation
    authority.
  - `DevelopmentUsbRelations::from_environment` is gone.
- **`managed_hdc::Launched`** owns the server a daemon launched.
  - Dropping it calls `ManagedHdc::stop` in the dropping thread: TERM to the group, then KILL, and
    the child is reaped before the drop returns. This happens however many references the monitor
    or the host still hold. `stop` marks the lifecycle stopping first, so the monitor exits
    quietly, never with 70.
  - The drop writes one line to stderr naming the server, its PID and how it ended.
  - Both compositions hold their server in it. Isolated: `MeasuredHdc::start`. Production:
    `production::compose`, whose order, inputs and refusals are unchanged.
  - `serve()`'s `managed_hdc` holds it until the drain's own stop.
- **`Stop` carries the launch PID, and `Stop::report(drained)` writes the stop's lines.** The
  drain's output is unchanged: only a failed stop, and the replacement lines.
- The standalone and facade refusals of development inputs are unchanged. They run on every
  platform and already come before anything is opened.

## Behavior that changes

- **An isolated start refused on its environment launches nothing.** It also no longer creates
  the root's private children and stores before refusing.
  - Some refusals still come after the stores are opened: those only the HDC's bytes or the
    helper's bytes decide. They still come before any launch.
- **With several faults at once, which refusal is reported changes.** Each input's own refusal
  and message are unchanged.
  - The environment's refusals now come before the argument count, the endpoint and root checks,
    and the store, analyzer and workspace errors.
  - Among the development inputs, the refusals that depend on the HDC's registration now come
    after the port, relations, helper and mutation refusals.
- **A daemon that ends after launching its managed server, without its drain, now stops that
  server and says so on stderr.** Before, it relied on the last reference being dropped before
  `exit`. This covers both compositions, and a serving loop that ends in an error.
  - Production's failed start now ends its server with TERM, then KILL, as its drain does, where
    the drop sent SIGKILL.
- **Swift has no counterpart to compare.** The development inputs exist only in the Rust
  isolated owner. Swift's start-up failure path after `HeadlessHDCServerHost.start` was not
  examined in this slice.

## Tests

- **`development_admission` unit tests (4).**
  - Every refusal the environment decides, with its message.
  - The first refusal when several are wrong.
  - What the environment admits: the default endpoint 8710, and no port read beside a fixture.
  - `admit_registration` over the registered, managed, relations and acknowledgment combinations.
- **`tests/managed_hdc_process.rs`.**
  - `refused_before_any_launch` asserts that the fake never ran (`tools/calls` is empty: no
    server, no `checkserver`) and that nothing of it is running. Every environment refusal of
    the managed-server, USB-relations, mutation-authority and code-sign-helper tests now goes
    through it.
  - The standalone refusals also assert that the fake never ran.
  - New cases:
    - a relative relations path beside the managed server;
    - both helper refusals beside the managed server.
  - Nothing was weakened: `fake_running` still runs on every refusal.
- **`a_start_that_fails_after_its_launch_stops_the_managed_server` (new).**
  - The test gives the start an admitted Job whose record outlived its journal. Job recovery
    therefore refuses the start after the launch, with `internalFailure("admitted job … has a
    partial durable projection")`.
  - The fake must have been launched once. The daemon must name the server it stopped (PID,
    signal 15 or 9).
  - That PID has no process (`process_argument_record`), and `pgrep` finds nothing.
- **`tests/spawning/managed_hdc_server.rs`,
  `a_launched_server_is_stopped_when_dropped_while_the_monitor_holds_it` (new).** A `Launched` is
  dropped while a clone stands for the monitor's reference. The test checks, right after the drop:
  - the server's PID is gone;
  - `active_launch` is `None`;
  - `foreground_exit` is `Some(false)`, stopped rather than unexpected;
  - a second stop is a no-op.

**Before the fix.** The new test binary was run against the base daemon, without the hold:
- the mutation, helper and relations tests each fail on "the HDC ran before the start was
  refused", with `left: ["-s 127.0.0.1:<port> -m", "-s 127.0.0.1:<port> checkserver"]`;
- the post-launch test fails on "the daemon named no server it stopped";
- the managed-server test passes, because its refusals already came first.

**Mutations.** Each was built from the final tree and not committed. Each was caught every time:

| mutation | caught by |
| --- | --- |
| M1: the mutation authority decided after the launch again | its process test 3/3 ("the HDC ran before…"); 2 admission unit tests |
| M2: `Launched`'s drop stops nothing | the post-launch test 3/3 without the hold and 3/3 with it ("named no server it stopped"); the spawning test 3/3 ("outlived the drop") |
| M3: the helper's bytes verified after the launch | the helper test 3/3 |
| M4: the relations path checked after the launch | the relations test 3/3; 1 admission unit test |

## `LoopbackServerLease` and a server whose exit has begun (S26's open question)

`scan()` (`arkdeck-platform/src/macos_server.rs:280`) cannot see a server whose exit has begun.
It reads processes through `proc_pidpath`, `proc_pidinfo` and the listener helper, which stop
answering at once, while the process still holds its listening socket. S26 measured the window in
`TASK-XPA-016/proved-process-exit-and-cli-deadlines-run.md`: a connect succeeds in 200 of 200
trials at that moment, the window has a mean of about 0.5 ms, and it reached 9 ms with 16
burners. So "no server" there means no live server, not a free port. What each caller does with
`NotFound`:

| caller | what it does with `NotFound` | effect |
| --- | --- | --- |
| `ManagedHdcServer::start` (`arkdeck-provider-hdc/src/managed_server.rs:126`) | decides absence with a connect (`reachable`), not the scan. An exiting server still accepts, so the start refuses (`Occupied`) and launches nothing. The scan only names the occupant (`occupant`, `:289`). | fail closed; the occupant is misnamed as "a listener that is not the configured HDC executable" |
| the same start, after readiness (`:208`) | the launched process must own the endpoint | `Unbound`, fail closed |
| `ManagedHdc::end_replacement` (`arkdeck-agentd/src/managed_hdc.rs`) | a fresh proof must name the replacement | `Unproved`, nothing signalled; the next start's connect gate refuses while the exit finishes |
| a restart's outcome (`managed_hdc_lifecycle.rs:229`) | the new server must be proved | `outcomeUnknown`, fail closed |
| `lifecycle::probe` with `Stop` (`arkdeck-provider-hdc/src/lifecycle.rs:311`) | reads "stopped" | no production caller: the only lifecycle command built outside tests is `Restart` (`managed_hdc_lifecycle.rs:181`) |
| `CommandlessIdentity::observe` (`status.rs:467`) | `hdc.selectedServerNotObserved` | a status report only; nothing acts on it |
| `HdcReadOnlyProvider` (`provider.rs:84`) | observation unavailable | fail closed |
| `LoopbackServerLease::revalidate` of a live lease | the birth is gone, so the lease has changed | dispatch refused, fail closed |

No path takes an empty scan to mean that the port is free or that it may start. The managed
start's own gate is the connect, which sees the exiting listener. The only cost is an earlier
refusal and, for the length of an exit, an occupant named "not the configured HDC executable".
As the task asked for this case, the conclusion is recorded and no code changes. Should the
occupant's name ever matter, it could say "a listener the commandless proof cannot attribute".

## Local targeted checks

`CARGO_BUILD_JOBS=2`, target `/private/tmp/arkdeck-1330-rust-target`, worktree
`/private/tmp/arkdeck-s22-lane`, logs `/private/tmp/arkdeck-s30-*.log`. Only `arkdeck-agentd`
changed, and no crate depends on it.

- `cargo fmt --all --check --manifest-path rust/Cargo.toml`: exit 0 (`fmt.log`; after the
  rebase `fmt-r2.log`).
- `cargo clippy --manifest-path rust/Cargo.toml -p arkdeck-agentd --all-targets -- -D warnings`
  for the host, `--target x86_64-unknown-linux-gnu` and `--target x86_64-pc-windows-msvc`: exit 0
  each (`clippy-host.log`, `clippy-linux.log`, `clippy-windows.log`; the host again after the
  rebase, `clippy-host-r2.log`).
- `cargo test --manifest-path rust/Cargo.toml -p arkdeck-agentd`, after
  `cargo build -p arkdeck-cli`:
  - on `a3de6c316`: exit 0 (`test-full-r1.log`), 20 test binaries, 178 passed, 0 failed,
    0 ignored, load 3–5;
  - after the rebase, run 2 (`test-full-r2.log`): 1 failure, not counted.
    `workspace_read_process`'s production `workspace.inspect-diff` Job answered `failed` at
    load 16, while the system's indexers ran after the load test. It is invalid on all four
    criteria:
    - the test starts no managed server, and this change does not touch workspace operations;
    - a host git read test of #2190, which added this test, failed once before at load 8–9 and
      passed alone (S28's notes, in no run record);
    - it passed 3 of 3 alone;
    - it has nothing to do with this diff.
  - after the rebase, run 3 with `--no-fail-fast` (`test-full-r3.log`): exit 0, 20 binaries,
    178 passed, 0 failed, load 3.
- **Repeated runs** of the final test binaries (`repeat-quiet.log`, `repeat-loaded.log`):

  | binary | runs | passed | failed | load |
  | --- | --- | --- | --- | --- |
  | `managed_hdc_process` | 5 | 10 each | 0 | 4.2–4.5 |
  | `spawning` | 3 | 25 each | 0 | 4.0–5.1 |
  | `managed_hdc_process`, 8 CPU burners | 5 | 10 each | 0 | 24–37 |
  | `spawning`, 8 CPU burners | 2 | 25 each | 0 | 45–49, and 80 at the end with the system's indexers |

- `rust/scripts/check-readonly.py --bin-dir <target>/debug` (validation venv): exit 0, `PASS`
  (`check-readonly.log`; after the rebase, with the rebuilt CLI, `check-readonly-r2.log`).
- `sh scripts/check-sdd.sh` (validation venv): exit 0 (`check-sdd.log`).
- The probe and mutation builds and runs are listed above. Binaries are in
  `/private/tmp/arkdeck-s30-probe/{before,after,after-hook,final}/`. The probe script and its
  JSON lines are in the S30 scratchpad.
- After the runs, no fake `hdc` of these tests was running.
- Not run:
  - `generate-contract.py --check` and `check-contracts.py`: no contract input changed.
  - `arkdeck-platform`: unchanged, no code change for the lease.
  - Swift and the App: nothing of theirs changed.
  - A real `hdc`, a device, and the production composition over an account.

## CI

Pending.
