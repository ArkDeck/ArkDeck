# Recovery broker `executePinnedRequest` on Rust (TASK-XPA-017, S2b)

This is the second half of final-lane §4 S2. It removes the other
"Rust does not execute Flash yet" declared difference: the protected Flash
recovery broker's `executePinnedRequest`
(`flash_invocation_broker.rs`), which until now refused where Swift began
its attempt.

Built on S2a (#2305, `flash-entry-points-run.md`, merged as `53b832780`); rebased onto `main` `fa8d9d81b`. The driver admits through
the `with_flash_admitter` helper S2a added. No contract input, Catalog,
OpenSpec delta or `tasks.md` change. No device, and nothing here is device
evidence.

## What is ported, in Swift's order (`RuntimeDebugInvocation.swift` `evaluate`, `finish`)

- **Execute.** Every check Swift makes before it writes stays as it was:
  predecessor outcome, epoch budget, expiry and the running guard. Then, in
  order:
  1. The attempt's exact request is derived from the pinned seed. Its request
     id is `debug-<suffix12>-e<epoch>`. Its idempotency key is
     `runtime-debug-<suffix12>-e<epoch>-<candidate revision prefix>`, where the
     candidate revision is SHA-256 of canonical
     `{actionSha256, buildSha256, sourceSha256}`. The request carries no
     capability and no caller provenance.
  2. Its permit record is persisted.
  3. The epoch is counted and the `executing` evaluation ("Runtime attempt
     durably prepared") is persisted.
  4. Only then does the driver run.
  5. The evaluation is settled as Swift's `finish` settles it:

     | outcome | disposition | invocation |
     |---|---|---|
     | `succeeded` | `succeeded` | state `succeeded` |
     | `safeToReflash` | `nextCandidateAllowed` | unchanged |
     | `outcomeUnknown` | `awaitingRuntimeRecoveryProof` | unchanged |
     | `failedKnown` | `blockedKnownFailure` | state `blocked` |
     | `refused` | `refusedBeforeDispatch` | the epoch is given back |

     A result with no Job drops the evaluation's `destructiveEpoch`.
- **Resume.** An interrupted `executing` attempt with the same candidate and
  provenance is resumed with its own request id and idempotency key. The
  permit is written again, the same request is driven, and the same
  evaluation is settled. No new attempt, epoch or request is made.
- **Permit store** (`debug_attempt_permit.rs`, Swift
  `RuntimeDebugAttemptPermitStore`):
  - Location: `<state>/runtime-debug-attempts/<idempotencyKey>.json`,
    canonical JSON, replaced atomically in a private directory.
  - `load_exact` checks, in Swift's order:
    - the record's exact five-string shape;
    - no client provenance;
    - the idempotency key and the fingerprint of the request without its
      capability.
  - With the Runtime clock, it then checks the invocation document
    (`flash_invocations::dispatch_permitted`). The document must be current,
    `active`, within budget and before expiry, and must hold the executing
    destructive evaluation of this key and candidate action.
  - Refusals are Swift's `persistenceFailure("…")`, answered as a typed
    preflight failure.
- **The Flash plan** (`flash_plan.rs`) reads the permit where it used to
  refuse any permit. When a permit is present, the plan document carries
  `runtimeDebugInvocationID` and `runtimeDebugCandidateActionSHA256`, as
  Swift's `encodeIfPresent` does. An ordinary Job's digest bytes are
  unchanged. Non-Flash plans still refuse a permit (unchanged). The broker
  only accepts destructive seeds, which are the two Flash references.
- **The driver** (`host.rs` `debug_attempt`, Swift
  `RuntimeJobEngineDebugAttemptDriver`):
  1. It admits through the Flash admitter, exactly as `job.submit` does:
     DEC-016 classification and the Runtime's own destructive capability.
  2. It runs the Job through this Host's `job.run`, so the run is claimed as
     a concurrent `job.run` would claim it.
  3. It classifies the result with the new `debug_execution_outcome` (Swift
     `runtimeDebugExecutionOutcome`):
     - succeeded or recovered: `succeeded`;
     - outcome unknown or `waitingForRecovery`: `outcomeUnknown`;
     - failed, with every step intent typed and neither a device mutation nor
       destructive: `safeToReflash`;
     - otherwise, the Job's own capability use: `safeToReflash`, `pending` or
       unknown as `outcomeUnknown`, and `confirmed` or missing as
       `failedKnown`.

     Once a Job exists, an outcome that cannot be read is `outcomeUnknown`,
     never `refused`.
- **Isolated owner** (`main.rs`). The invocation owner now opens in the
  planner's state directory, as production already does (`layout.state` for
  both), instead of `jobs-state`. The broker writes a permit where the
  planner reads it. Isolated roots are disposable, so nothing is migrated.

## Declared differences (T2 prose only)

- A refused attempt's `detail` reads `<code>: <message>` of the admission
  refusal, and a failed run's reads `Runtime Job failed after admission:
  <code>: <message>`. Swift interpolates its error values. The codes,
  outcomes and dispositions are Swift's.
- When the permit record cannot be written, the error is answered
  `internalError` with the writer's description. Swift's catch-all answers
  the same code.

## Tests

- **`arkdeck-hoststore/tests/debug_invocation.rs`.** The Swift oracle's
  `execute.json` is no longer a declared difference. It is replayed over a
  scripted driver that answers as Swift's engine did (Job failed, classified
  `safeToReflash`). The answer is Swift's byte for byte, including the
  derived idempotency key's candidate revision prefix (`2d2b943b3079`). The
  test also checks that:
  - the driver got the attempt's exact request once, with no authorization;
  - the permit record names the invocation and the candidate action.
- **`debug_attempt_permit` unit tests (3).**
  - A request without a record has no permit.
  - A record is read back for its exact request, the admitted capability
    notwithstanding, and refused for a changed input.
  - A timed read refuses without a current invocation.
  - A record with an extra member is refused.
- **`arkdeck-agentd` `debug_invocation_control`.** The interrupted fixture's
  resume now persists the permit and drives the request. This Host composes
  no Job owner, so the attempt settles `refusedBeforeDispatch` and gives its
  epoch back.
- **New `tests/spawning/flash_broker_control.rs`, end to end through Control**
  with `flash_execution_control`'s Host (real owners, the oracle's fake lane
  and host). `debug.start` pins the canonical full restore, and
  `debug.evaluate` executes it:
  - **completed:** the attempt is settled `succeeded`, the invocation is
    `succeeded`, and the Job is `succeeded`. A second execute is refused and
    dispatches nothing.
  - **unknown:** the attempt is `outcomeUnknown` /
    `awaitingRuntimeRecoveryProof`, and the Job is `waitingForRecovery`.
    `job.run` is refused, with no replay.
  - **both:** exactly one perform, the permit is on disk, and the Job's
    materialized plan digest (`job.show`) differs from the seed's baseline.
- **Mutation.** With the permit pins removed from the plan document, both
  broker cases fail on the digest assertion. Restored.

## Local targeted checks

Worktree `agent-adc7ba94d908e1c5c`, `CARGO_TARGET_DIR=/private/tmp/arkdeck-lane1-target`,
`CARGO_BUILD_JOBS=2`. Logs are under `/private/tmp/arkdeck-lane1-logs/`.

| check | result |
|---|---|
| `cargo fmt --all --check` | exit 0 |
| `cargo clippy --all-targets -- -D warnings` for `arkdeck-hoststore`, `-agentd`, `-cli`, `-client`, `-soak` (`s2b-clippy.log`) | exit 0 |
| `cargo test --no-fail-fast` for the same five crates (`s2b-test.log`) | exit 0: 191 test binaries, 1458 passed, 0 failed, 21 ignored |
| `sh scripts/check-sdd.sh` (`s2b-sdd.log`) | exit 0 |

After the rebase onto `fa8d9d81b`: fmt exit 0; the same clippy exit 0 (`s2b-rebase-clippy.log`); `cargo test --no-fail-fast -p arkdeck-hoststore -p arkdeck-agentd` exit 0, 115 binaries, 959 passed, 0 failed (`s2b-rebase-test.log`).

Not run:

- `generate-contract.py --check`: no contract input changed.
- Swift: nothing changed.
- `arkdeck-provider-arkforge`: unchanged by this slice. Its tests ran in S2a.

## CI

Pending.
