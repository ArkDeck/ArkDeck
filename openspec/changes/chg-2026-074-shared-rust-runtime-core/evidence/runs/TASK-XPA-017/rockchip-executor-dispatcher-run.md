# The Rockchip executor and the native RockUSB dispatcher (TASK-XPA-017, F6 S6)

This slice ports the rest of Swift's Rockchip runtime host to
`arkdeck-hoststore`:

- the executor that performs each typed Rockchip action once its intent is
  durable;
- the dispatcher through which the Runtime dispatches a host-managed
  Rockchip action (the Rust `RockchipHost`).

With S5's record store and durable host, a host-managed Rockchip action now
runs as Swift runs it, over ports. Nothing composes it yet: the daemon wires
the dispatcher and the lane with S8. The ArkForge lane's managed control
through the same host is S7.

Developed on S5's branch head `bfa41dc87` (#2256, merged as `752311deb`), then
rebased onto `e58dda2bb`. That base brings S3 (#2257) and a runbook (#2258),
neither of which touches this slice's files. The checks marked "after the
rebase" were run again. No contract input, Catalog or `tasks.md` changes. No
device, and nothing here is device evidence.

## What is ported

### `rockchip_executor` (Swift `FoundationRockchipRuntimeActionExecutor`)

The arms reuse `arkdeck-provider-hdc`'s halves: `RockchipLoaderTransition`
for the Loader, and `RockchipHdcObserver` for the HDC waits and the build
readback. What is the executor's own:

- **The descriptor-bound HDC**, resolved at an action's first command and
  kept for the rest of the action. A resolution that fails refuses before
  anything runs: `descriptor-bound HDC executable is unavailable: <e>`.
  `unavailable_reason` is Swift's
  `… unavailable to the Rockchip host: <e>`. Every spawn still checks the
  executable's identity, as Swift's identity-bound runner does.
- **The observation reuse cache** (Swift
  `RockchipRuntimeObservationReuseCache`), which keeps an entry for 120 s:
  - **Loader observations.** One exact Loader observation serves the actions
    of one managed-control attempt:
    - `enterLoader` remembers it.
    - `waitForHDCDisconnect` and `waitForLoader` reuse it.
    - `rebindLoader` consumes it.

    Only the performer's step id shape, `<step>-mc-<12 lowercase hexadecimal
    Characters>-a<index>`, keys the cache; fullwidth digits count, as Swift's
    `Character.isHexDigit` admits them.
  - **Bound HDC routes.** The bound reconnect remembers its route, and the
    build verification takes it once, after a fresh census readback.
- **Each arm's summary**, as Swift writes it, including the reuse markers
  (`observationReuse`) and the rebind's `bindingRevision`.
- **The post-flash alias.** A verified build publishes it
  (`PostFlashAliasStore::publish`, with the previous alias expected). A
  failure is `verified post-flash HDC binding could not be persisted:
  <e>`. Without a store, or without the profile's model and build, the
  verification refuses first: `post-flash binding verification is not
  fully configured`.
- **The HiLog capture:** `hdc -t <key> shell hilog -x <filters>`, under the
  request's duration and 15 s of grace (not the E0 capture's 45-second
  floor), within its byte budget. An empty capture is refused.
- **The retired direct reset** refuses: `legacy direct Rockchip reset is
  retired; native ArkForge owns device reset`.
- **The census's own refusal** of `observeHDCNormalUSB` passes through as
  it is, as Swift rethrows it (`LaneFailure::Other`).

### `rockchip_dispatcher` (Swift `ArkForgeNativeRockchipControlDispatcher`)

- **`refusing`**: Swift's refusal, `the per-action RockUSB host requires
  descriptor-bound HDC and a product state directory`. A known detail
  extends it after `: `.
- **`durable`**: the durable host over an executor, with its records under
  `<state>/rockchip-runtime`.
- **`action_host`**: the same host, for the lane's managed control (S7), so
  that there is one HDC owner.
- **`unavailable_reason`**: the configured `arkforged`'s identity first,
  then the host's reason.
- **`dispatch`**:
  1. anything but a Rockchip action is refused;
  2. unavailability refuses;
  3. `arkforged` is measured again and must be the executable the
     descriptor names (`… identity changed after availability
     materialization`);
  4. the host runs the action;
  5. a result without its durable record is an unknown outcome (`Rockchip
     host returned no durable job/step receipt`).

  The receipt carries exit status 0, the streams, the record id, and the
  summary with `recordID`. Its duration is 0: the sum of the subprocesses'
  durations, which Swift's Rockchip runner always reports as 0.

### Around them

- **`RockchipActionHosting`.** Swift's `RockchipRuntimeActionHosting`
  becomes a trait. S5's durable host implements it, and so does the new
  refusing host.
- **`LaneFailure::ConfirmedNotExecutedWithDiagnostic`**
  (`arkdeck-provider-arkforge`). This is Swift's
  `.confirmedNotExecutedWithDiagnostic`, with the diagnostic's raw value.
  - The Loader transition raises it when the exact HDC-normal readback
    proves that the transition did not complete.
  - The Flash run treats it as `confirmedNotExecuted`, as Swift's engine
    does.
  - One `described` renders a failure as Swift's `"\(error)"`. The
    diagnostic prints qualified by its module and type, as Swift prints an
    enum inside another's payload. Swift's tests do not pin that text; S7,
    whose failure reason carries it, pins it against Swift.
- **`RockchipHdcObserver::capture_post_flash_hilog`**
  (`arkdeck-provider-hdc`): the capture's read, judged as every read of that
  observer.

### Declared differences

- **The persisted action is decoded at dispatch.** Swift's typed plan
  carries the action itself. The lane's host action carries its persisted
  form, which decodes as Swift's `materialize()`. A persisted action that
  does not materialize is therefore refused here (failed, nothing run),
  where Swift would have refused it when the plan was materialized.
- **The HDC child's working directory** is the composer's choice of HDC
  dispatch. Swift's runner runs every child in the product-owned state
  directory; this is wired with S8.
- **The flash run does not journal the diagnostic.** The one host-managed
  action the flash run dispatches (the post-flash capture) never raises it.

## Tests

- **`rockchip_executor`, 13 tests**, porting Swift's executor cases:
  - an exact Loader already there skips HDC;
  - one managed-control attempt reuses one transition observation;
  - reuse is bound to the attempt's step ids and expires after 120 s;
  - a disproved transition carries its diagnostic and evidence;
  - a timed-out transition without either readback stays unknown;
  - the normal USB readback runs no HDC;
  - the retired reset never runs;
  - the reconnect wait returns its reads;
  - the bound reconnect route is reused by the verification, which alone
    publishes the alias;
  - an inexact build or an inconsistent route publishes nothing;
  - an unconfigured verification refuses first;
  - the capture's argv, timeout and budget;
  - an unresolvable HDC refuses only what needs it.
- **`rockchip_dispatcher`, 6 tests:**
  - only the configured `arkforged` authorizes an action;
  - a refusing dispatcher names its cause;
  - the identity is measured before the host;
  - only a Rockchip action is dispatched;
  - a result without its record is unknown;
  - a record root that cannot materialize makes the host unavailable.
- **`rockchip_hdc`, 2 tests** for the capture read.
- **Mutations.** Ten hand mutations of the executor and the dispatcher, each
  killed:
  - the rebind does not consume;
  - reuse expires at 120 s exactly;
  - a reuse digest of any length;
  - the bound route not remembered;
  - the alias not published;
  - the diagnostic dropped;
  - the capture on the E0 timeout;
  - the digest not compared;
  - the record not required;
  - any kind dispatched.

## Verification

**Local targeted checks.** Main worktree, target
`/private/tmp/arkdeck-m4-rust-target`, `CARGO_BUILD_JOBS=2`. Logs are under
the session's scratchpad `s6-logs/`.

| check | result |
|---|---|
| `cargo fmt --all --check` | exit 0 |
| `cargo clippy --all-targets -- -D warnings`: `arkdeck-provider-hdc`, `-provider-arkforge`, `-hoststore`, and their dependents `-agentd`, `-soak` | exit 0 (`clippy.log`, `clippy-dependents.log`) |
| `cargo test -p arkdeck-provider-hdc` | exit 0: 183 passed in 17 test binaries (`test-provider-hdc.log`) |
| `cargo test -p arkdeck-provider-arkforge` | exit 0: 65 passed in 5 test binaries, before S3 was in the base (`test-provider-arkforge.log`) |
| `cargo test -p arkdeck-hoststore` | exit 0: 704 passed, 18 ignored, in 90 test binaries; the library's Rockchip modules hold 37, 19 of them new (`test-hoststore.log`) |
| `cargo test -p arkdeck-agentd` | exit 0: 187 passed in 22 test binaries (`test-agentd.log`) |
| the ten mutations | each caught as above; the restored tree passes (`mutations.log`) |
| after the rebase: fmt; clippy of the five crates above; `-p arkdeck-hoststore --lib rockchip_`, `--test flash_plan`, `--test flash_run`; `cargo test -p arkdeck-provider-arkforge` with S3 | exit 0 each: 37, 2 and 12 passed; the provider's 74 unit tests (`rebased-*.log`) |
| after the rebase: `cargo clippy --all-targets -- -D warnings` for Windows and Linux: `arkdeck-provider-hdc`, `-provider-arkforge` | exit 0 each (`clippy-windows.log`, `clippy-linux.log`) |
| `sh scripts/check-sdd.sh` | exit 0 (`check-sdd.log`) |

Not run:

- **Cross clippy of `arkdeck-hoststore`.** Everything changed in it compiles
  only on macOS.
- **`arkdeck-soak` tests.** Nothing of it changed; its clippy above compiles
  it.
- **Swift.** Nothing of it changed.
- **`generate-contract.py --check`.** No contract input changed.

**CI.** Pending.

The CI of #2256 (S5) and #2257 (S3) was green before they merged.
