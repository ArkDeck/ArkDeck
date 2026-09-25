# TASK-XPA-018 — Swift's domain executor, recorded (macOS, 2026-09-25)

TASK-XPA-018 remains in progress. This is the first slice of the domain-leaf
series (group d). As the hub queued it, it only records what Swift's
client-side executor does, for the Rust port to replay in the slices that
follow. Base: `main` `6c73312e4` (#2181).

Nothing here is device evidence (POL-VERIFY-001, POL-MODE-001). What changes:

- one new Swift oracle test, in a test target, and the oracle it recorded;
- one Rust test that holds the recording to its own terms.

No Rust source, Runtime, control schema, corpus, Catalog,
`openspec/contracts`, `openspec/specs` or constitution change.

## What Swift does

For a domain leaf (`screen capture`, `input tap`, `workspace build`, …),
Swift's CLI does not ask the Runtime to run an execution. Instead, its client
runs one itself: `AgentRuntimeExecutor`, one connection per request.

1. `health` reads the catalog digest.
2. `operation.describe` reads the binding (`none` or `confirmedDevice`) and the
   provider.
3. **A host-only operation** takes its host scope from the target, the
   project, or `<provider>-host`. A target other than the project is refused,
   except for the two operations that consume an imported Artifact.
4. **A device operation** reads `target.list`, then `device.observations`.
   With no adopted target it adopts the one connected candidate with
   `target.adopt`.
5. **When a person is needed** — to reconnect, to confirm the trust prompt or
   to choose a target — it persists a resume record and pauses. The CLI then
   refuses with `humanActionRequired`, carrying the resume token.
6. It sends `job.submit` with a canonical request under the
   `agent-request-`/`agent-execution-` identities, then `job.run`,
   `job.evidence`, and every page of `artifact.list`.
7. **When the run is lost, refused or not terminal**, it requests
   `job.cancel` once and reports the run as failed.
8. **A client error from `operation.describe`, `target.adopt` or
   `job.submit`** is thrown, and the CLI names it as `job.submit`'s failure.

## The oracle

`rust/tests/fixtures/domain-executor`:

- **30 scenarios** on `input.tap@1`, `workspace.build-openharmony@1` and
  `workspace.apply-patch@1`. Each script is built from the frames Swift's
  daemon recorded (`Fixtures/ControlFrames`).
- **Per scenario**, the oracle records:
  - the frames sent, in order, with labelled identities: 257 frames in all,
    132 of the executor's `agent-<uuid>` and 125 of the client's `<UUID>`;
  - the connections and clock reads;
  - the outcome (receipt and action) or the error;
  - the CLI's rendering;
  - the pending resume record.
- **Endings**:
  - 4 completed;
  - 8 failed;
  - 9 paused: 5 `physicalReconnect`, 2 `trustDevice`, 2 `selectTarget`;
  - 4 client errors;
  - 5 executor errors.
- **The fake Runtime** is a Unix socket in the test process. It never
  reaches the installed service or a real account's socket.

## Found for the port

- **What the executor reads.** It reads only `jobId` from `job.submit`, so
  `deduplicated` changes nothing.
- **When it cancels.** Any failed `job.run` leads to one `job.cancel`,
  including a refusal without details.
- **Its reasons embed Swift's error descriptions**, for example
  `transport("connection closed before response")` and
  `daemonError(code: "internalError", message: "the Runtime failed")`. The port
  must reproduce them verbatim or declare the difference.
- **An Artifact page must continue its snapshot.** The cursor starts with the
  page's snapshot revision, and a missing Artifact carries no lease. A page
  that breaks either is refused.

## Tests

| Test | What it holds |
| --- | --- |
| `CLIDomainExecutorOracleContractTests` (Swift, new) | Runs the 30 scenarios against the scripted Runtime and records them, or compares with the checked-in oracle |
| `domain_executor_oracle.rs::each_scenario_consumed_exactly_its_script_in_order` | Every script was used up; the business frames are the script's methods in order; no frame was answered by the peer's defaults |
| `domain_executor_oracle.rs::every_random_identity_is_labelled` | Frame identities, resume tokens and temporary paths are labelled |
| `domain_executor_oracle.rs::the_scenarios_cover_every_way_a_run_ends` | The endings above; each pause persisted exactly its one resume record and is `humanActionRequired`; each client error is named as `job.submit`'s |

## Tampering

The Rust test was run against the oracle with each of three edits, and the
oracle was restored by digest after each run. All three were caught:

| Tampering | Caught by |
| --- | --- |
| A script entry left unused | `each_scenario_consumed_exactly_its_script_in_order` |
| An unlabelled frame identity | `every_random_identity_is_labelled` |
| A resume record carrying a raw token | `the_scenarios_cover_every_way_a_run_ends`; `every_random_identity_is_labelled` |

## Local targeted checks

Logs are under `/private/tmp/`.

| Check | Command | Result |
| --- | --- | --- |
| Swift oracle | `sh Packages/ArkDeckKit/Scripts/run-swiftpm.sh test --filter 'CLITraceInspectOracleContractTests\|CLIDomainExecutorOracleContractTests'` | Exit 0 on all three runs (`arkdeck-oracles-record.log`, `-record2.log`, `-compare.log`). The hub and the coordinator granted the build window, and free memory stayed at 39–42% |
| fmt | `cargo fmt --all --check --manifest-path rust/Cargo.toml` | exit 0 (`arkdeck-de-fmt.log`) |
| clippy | `cargo clippy --manifest-path rust/Cargo.toml -p arkdeck-cli --all-targets -- -D warnings` | exit 0 (`arkdeck-de-clippy.log`) |
| Oracle test | `cargo test --manifest-path rust/Cargo.toml -p arkdeck-cli --test domain_executor_oracle` | exit 0: 3 passed (`arkdeck-de-test.log`) |
| Records | `ARKDECK_PYTHON=<validation venv> sh scripts/check-sdd.sh` | 0 errors, 0 warnings; exit 0 (`arkdeck-de-sdd.log`) |

The Swift oracle was recorded three times:

1. The first recording had a flaw in how the Artifact page was built. The
   template Artifact was a missing one yet carried a lease, and the cursor did
   not continue the snapshot revision. So the two-page success path failed on
   its first page.
2. The page was fixed and the oracle re-recorded.
3. The compare run matched the checked-in copy byte for byte.

After the first push, the Rust port of the next slice replayed the oracle. It
showed that `oneAdoptedTargetFailedJob` answered `job.evidence` with a refusal
that method does not publish: `resourceNotFound` without details. Rust's
client checks every answer against the published method schema, so it read
that answer as malformed; Swift's client does not check, so it read it as a
daemon error. The scenario now answers with the refusal Swift's daemon
recorded for a Job it does not know: `notFound`, "the referenced Job does not
exist". The hub granted a second build window. The oracle was re-recorded,
and only that scenario changed; the compare run then passed (exit 0,
`arkdeck-dx-record.log`, `arkdeck-dx-compare.log`). The Rust test passed
again (3 passed, `arkdeck-de-test2.log`).

Not run: the rest of the CLI suite, since only a test file was added, and
`generate-contract.py --check`, since no contract input changed.

## CI

- #2181 is recorded in `cli-trace-inspect-run.md`. This slice's base already
  contains it.
- This PR: pending.
