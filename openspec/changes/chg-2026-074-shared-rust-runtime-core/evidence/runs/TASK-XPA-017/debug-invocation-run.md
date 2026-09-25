# The Flash recovery broker's start and evaluate on the Rust Runtime (TASK-XPA-017, M4-5)

Swift's `RuntimeDebugInvocationController` is the protected Flash recovery
broker. A candidate may observe the pinned request, execute it or stop, and
nothing else.

Before this change, the Rust daemon answered its reads only (`debug.status`
and `recovery.flash-invocation.list`, #2148). `debug.start` and
`debug.evaluate` got the foundation's refusal.

The Rust daemon now answers both as Swift's daemon does:

- **`debug.start`** pins one unprivileged typed request. Its plan-only
  preview must be the Runtime's own and destructive. It then opens a
  four-hour invocation over it.
- **`debug.evaluate`** takes one candidate action with its source and build
  provenance:
  - observe the pinned request again (plan-only, dispatch-free), or stop;
  - execute is the declared difference below.

The preview is this Runtime's `job.plan` (#2162): the same planner, Flash
composition and facts, on the Runtime clock.

The CLI gains `recovery flash-invocation start|evaluate` and the legacy
`debug start|evaluate`.

Base: protected `main` `b5d254c2` (#2162, after #2164 and #2165). Routed
methods: **104/105**, since #2163 routed `trace.inspect`. Only
`flash.lanePlanPreview` remains, after the upstream ArkForge client change.

| Already on `main` | This change | Still remaining (M4) |
|---|---|---|
| The broker's reads (#2148); the Flash `job.plan` (#2162) | `debug.start` and `debug.evaluate` (observe, stop), as Swift answers them; the CLI leaves; the Swift oracle `debug-invocation` | Executing the pinned request, with the Flash admission and run; `flash.lanePlanPreview`, after the upstream ArkForge client change |

## The oracle

`DebugInvocationOracleContractTests` composes Swift's controller as the
daemon composes it: `RuntimeJobEngineDebugAttemptDriver` over the engine's
`planOnly`. The requests go through the daemon's control-plane handler.

A flash bundle is first imported with the production policy, and every seed
names its lease. Each exchange composes the engine as its setup names it, at
the clock reading the setup names, over one controller state directory:

- the provider's availability;
- the dispatcher's reason;
- the lane's toolchain;
- the facts port's answer.

Four documents are laid down before the exchanges. The same controller
writes them over a scripted driver:

- one blocked by a known failure;
- one succeeded;
- one whose sixteen destructive epochs are spent;
- one whose last attempt was interrupted while executing.

There are 68 exchanges (`cases.json`):

- **`debug.start`, 17.**
  - Parameter refusals.
  - Seeds refused before planning: malformed, a duplicate member, a
    governance field, an authorization, a client context.
  - Seeds whose plan refuses: an unknown operation, a hardware-gated lane,
    an alias that cannot be converted, no expected binding revision, another
    provider.
  - Four invocations started, canonical and alias.
- **`debug.evaluate`, 43.**
  - Parameter and provenance refusals, and unknown and invalid identities.
  - 22 candidate documents, each refused with its codec error.
  - Observations: plain, with a provider blocker, refused by the planner
    (hardware-gated, facts unavailable), and of the alias.
  - A stop, and an evaluation after it.
  - A stop reason with a trailing newline, which Swift refuses.
  - Expiry, and an evaluation after it.
  - The four laid-down states, each refused before anything is planned.
- **`debug.status`, 8.** Every document the exchanges leave, then compared
  with what they leave on disk.

The broker names each invocation it mints at random. The oracle reads each
one as `<invocation-N>` in order of its start, and its last twelve
characters as `<invocation-N-suffix>`. A request that names one names its
label, and the replay mints its own identities.

The oracle is recorded once. A later run lays the inputs down and replays
every exchange, and it passed twice.

`execute.json` records Swift's `executePinnedRequest` on its own invocation,
with the engine over the broker's state directory as the daemon composes it.
Swift admits the pinned Flash with a capability issued automatically, runs
it, and records the attempt. It records a Job, `nextCandidateAllowed` and
epoch 1, since the lane stub fails before any write.

## The Rust broker

- **Owner** (`flash_invocation_broker.rs`, beside the reads). It ports:
  - `start` and `evaluate`, over the same document codec, which now writes
    what it reads (`stored`);
  - the candidate action codec. The document is one non-empty object,
    without a duplicate member, as Foundation decodes it. Closed shapes;
    the stop reason matched exactly;
  - the four-hour lifetime, and expiry persisted before it is answered;
  - the interrupted and predecessor checks, and the epoch budget;
  - Swift's `activeEvaluations`: one evaluation of an invocation at a time,
    refused, not queued;
  - atomic owner-only replacement through `HostDirectory::replace_document`.
- **Error descriptions.** The broker's refusals carry Swift's descriptions
  of `RuntimeDebugInvocationError`. A request's decoding rejection is
  rendered as Swift prints `RuntimeOperationRequestRejection`.
  - A planning refusal reads as Swift's `"\(error)"` of what its planner
    threw (`PlanRefusal::swift_description`). The Job lifecycle handler maps
    `RuntimeJobEngineError.rejected` onto its codes many to one, so each code
    this planner answers is read as the case Swift raises on that path.
  - An alias that cannot be converted carries `DeviceProviderError`'s own
    detail (`canonical_inputs` now names which of Swift's three details
    refused it).
- **Composition** (`host.rs`). `job.plan` and the broker share one planner
  (`with_flash_planner`). The broker adds the Runtime clock and a fresh
  `debug-<UUID>` identity. The control layer routes both methods to the
  invocation owner. A host without it answers as Swift's daemon without its
  controller: "Runtime debug invocation is not configured".
- **CLI** (`flash_leaves.rs`, `lib.rs`, `main.rs`).
  - `recovery flash-invocation start --request-file <path>` sends
    `debug.start`.
  - `evaluate --invocation --action-file --source-sha256 --build-sha256`
    sends `debug.evaluate`.
  - Both have legacy spellings, which carry Swift's §12 lifecycle.
  - Each document is read whole as UTF-8 before any connection. One that
    cannot be read is refused `ioFailure` (74), as Swift's leaf refuses it.

## Declared differences

- **Executing the pinned request.** This Runtime does not execute a Flash
  yet. `executePinnedRequest` is refused where Swift would begin its attempt:
  - after every check Swift makes before it writes anything (the interrupted
    predecessor, the epoch budget);
  - before any permit, epoch or evaluation is written.

  The answer is `rejected`: "executePinnedRequest is not available on the
  Rust Runtime yet: it runs the pinned Flash, which this Runtime does not
  execute; the invocation is unchanged". Resuming an interrupted attempt of
  the same candidate is refused alike. `execute.json` pins Swift's answer,
  and the replay pins that nothing was written.
- **Planning refusals Swift does not make.** Some refusals only this
  Runtime's planner makes, such as an operation it does not materialize yet.
  They read as their own message.
- **`invalidInput` descriptions.** Where Swift raised `.invalidRequest` or
  `.governanceFieldRejected` while planning, both mapped to `invalidInput`
  on the wire, the description names `.invalidInput`. No Flash seed reaches
  such a refusal.
- **Swift's internal planning failures.** Other than the alias conversion,
  an internal planning failure keeps the handler's generic words.
- **Persistence failures** name the step that failed in this Runtime's words.

## The contract

- **Frames.** The oracle, run with `ARKDECK_CONTROL_FRAME_LOG`, gave 69
  frames. Against the committed schemas five were refused:
  - two parameter refusals whose requests the request schemas did not
    describe (`extra`, a non-string `requestJson`);
  - a non-string `actionJson`;
  - a stop evaluation without `observation`;
  - Swift's executed attempt (`destructiveEpoch`, `requestID`,
    `idempotencyKey`, `jobID`, `outcome`).
- **Corpora, append-only.** One frame was appended per new shape:
  `debug.start` +3, `debug.evaluate` +5, `debug.status` +2.
- **Schemas, widened only.** The derivation over the corpora
  (`generate-control-contract.py --derive-method-schemas`) ran as a check,
  and exactly its widening was applied by hand:
  - `debug.start`'s request: `extra`, and an integer `requestJson`;
  - `debug.evaluate`'s request: an integer `actionJson`;
  - `debug.evaluate`'s evaluation: `observation` optional, and the five
    fields of an executed attempt, as `debug.status` already publishes them;
  - `debug.status`: its sample counts only.
- **Generated.** `generate-contract.py --write`, then `--check`: 1009 shapes
  on `b5d254c2`, which is `main`'s 999 and these ten. The contract identity
  is unchanged.

The control layer publishes a stop evaluation only under the widened schema.
The agentd test therefore reads which contract the build compiled
(`publishes_stop_beside_attempts`). It expects the refusal only where that
contract refuses the answer, and asserts that this happens only in
check-contracts' published view. That is this change's own published view,
whose merge base predates the widening. A later change's published view,
whose merge base includes it, asserts the answer like the checkout. #2162
fixed #2161's analyzer test for exactly this. The CLI test reads an observed
evaluation, which every view admits.

`rust/scripts/check-readonly.py`: the standalone daemon composes no
invocation owner, so both methods answer `internalError` there, as its reads
already do.

## Verification

**Local targeted checks.** `CARGO_BUILD_JOBS=2`, `CARGO_INCREMENTAL=0`, own
target `/private/tmp/arkdeck-m4-rust-target`, logs
`/private/tmp/arkdeck-m4-debug-invocation-*.log`.

| Check | Command | Result |
|---|---|---|
| Swift oracle, recorded | `ARKDECK_RUST_DEBUG_INVOCATION_RECORD=<fresh> run-swiftpm.sh test --filter DebugInvocationOracleContractTests` | exit 0 (`swift-record3.log`) |
| Swift oracle, replayed | the same without the record variable, twice | exit 0 each (`swift-compare{1,2}.log`) |
| Rust replay | `cargo test -p arkdeck-hoststore --test debug_invocation` | 1 passed: 68 exchanges, the documents left, and the declared difference |
| Composition | `cargo test -p arkdeck-agentd --bin arkdeck-agentd debug_invocation_control` | 1 passed |
| CLI | `cargo test -p arkdeck-cli --test flash_invocation_broker --test argv_fixtures` | 3 and 5 passed; the four Swift argv fixtures (28 cases) replay without deviation |
| Mutations | eight of the broker, the planner's descriptions and the alias details | all eight killed; files restored by digest |
| Frames against the schemas | jsonschema (validation venv), before and after the widening | 5 refusals, then 0 |
| Contract | `generate-contract.py --write`, then `--check`, on `b5d254c2` | exit 0; 105 methods, 1009 shapes (`final-check.log`) |
| Swift schema contract | `ARKDECK_CONTROL_FRAME_LOG=<frames> run-swiftpm.sh test --filter 'ControlMethodSchemaContractTests\|DebugInvocationOracleContractTests\|FlashPlanOracleContractTests'` | exit 0; 7 tests, again on `b5d254c2` with both oracles in compare mode (`final-swift.log`) |
| Published view | `published-view-sim-debug.sh` (main's three debug schemas, the view forced) and `published-view-sim-debug-later.sh` (this change's schemas, the view forced, as a later change's view compiles them) | agentd 1 and CLI 3 passed; agentd 1 passed; again on `b5d254c2`; restored by digest (`final-pubsim.log`, `final-pubsim-later.log`) |
| fmt, clippy | `cargo fmt --all --check`; `cargo clippy -p <crate> --all-targets -- -D warnings` for `arkdeck-contract`, `arkdeck-control`, `arkdeck-hoststore`, `arkdeck-agentd`, `arkdeck-cli`, `arkdeck-soak`, on `b5d254c2` | exit 0 (`final-fmt.log`, `final-clippy-<crate>.log`) |
| Crate tests | `cargo test --no-fail-fast -p <crate>` for the same six, on `b5d254c2` | exit 0 each: contract 52, control 30, hoststore 595, agentd 161, cli 255, soak 4 (`final-test-<crate>.log`) |
| Read-only host check | `rust/scripts/check-readonly.py --bin-dir <this build>` (validation venv), on `b5d254c2` | PASS on macOS; 135 control responses (`final-readonly.log`) |
| Records | `ARKDECK_PYTHON=<validation venv> sh scripts/check-sdd.sh` | exit 0 |

**CI.** Pending.

**#2162 (M4-4b3), recorded here.**

- *Head `e823a407`.* Red only in the macos-26 Rust lane's published contract
  view, in #2161's own test. It assumed the merge base predates #2161's
  `agent.run`/`agent.status` widening, and #2162's merge base included it.
- *Head `c27ae9d4`.* The test fixed there now judges by the compiled
  contract, and every check passed: SDD Guard run 36086766007, and Swift CI
  run 36086766209, whose `swift` aggregate and Rust lanes on ubuntu,
  macos-26 and windows passed.
- *Merged* as `b5d254c2`.

No device, installed service, real `arkforged` or App was used, and nothing
here is device evidence. The bundle is synthetic, the facts are scripted,
and the documents laid down were written over a scripted driver.
