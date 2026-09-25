# TASK-XPA-018 — `workspace continuation inspect|submit|run` on the Rust CLI (macOS, 2026-09-25)

TASK-XPA-018 remains in progress. This is slice c of the Rust CLI's batch 1,
which the hub's ruling B (moving the Catalog model into `arkdeck-contract`,
`catalog-to-contract-run.md`, #2177) prepared for. Base: `main` `4137506c3`,
which is #2177 merged. The slice was first pushed stacked on that move's head
`4a57d1128`, and replayed onto `main` once it merged. Since `aa2afe6ba`,
`main` gained only #2176, which is records, and #2177, the move itself. The
checks below first ran on `681988448` (#2174), then again on `aa2afe6ba`,
where #2173's registry pass also reports these leaves' parse refusals. A
compile check ran after the replay.

Nothing here is device evidence (POL-VERIFY-001, POL-MODE-001). No Runtime,
control schema, corpus, Catalog, `openspec/contracts`, `openspec/specs` or
constitution change. The Swift change is one new oracle test file; no Swift
source changes.

## What the leaves do

CLI spec §7.9's headless continuation, as Swift's
`CLIWorkspaceContinuationDraft` and `RuntimeCLI.runWorkspaceContinuation` do
it. A continuation is a fresh typed request rebuilt from an exact terminal
source Job, never a replay of it:

1. `health`, then the source's `job.show`, then, for a device-bound source,
   its Target's `target.show`. `prepare` rechecks the source against all
   three. The source must use the Runtime's Catalog and this CLI's. Its
   provider must be published. Its typed request must be readable and carry
   no authority. It must be terminal and settled, with no unknown outcome,
   human wait, residue or superseding recovery. Its inputs must match the
   current Catalog, and its recorded effect must be host-only or read-only.
   It must carry no capture markers. A device-bound source's Target and
   binding revision must still be current.
2. `inspect` emits that draft.
3. `submit` builds the fresh request: the caller's continuation identity as
   request and idempotency key, the source's target, operation and inputs,
   and provenance naming the source Job and its thread. It sends the request
   to `job.submit` and reads the resolved Job back. That Job must hold
   exactly this request, this binding and this Catalog's effect.
4. `run` then runs that Job once if it is runnable. If it has already settled,
   it is emitted with the exit its outcome earns. Anything else is refused,
   and an unconfirmed run is never replayed.

All exchanges share the invocation's one deadline (`--timeout`, 30 s unless
given).

## What changes

- **`arkdeck-contract`**: `CatalogOperation::inputs_match_catalog`, Swift
  `RuntimeWorkspaceContinuation.inputsMatchCatalog`. It sits next to the
  Runtime's own `validate_inputs` because the Catalog's field constraints are
  private to the model. It is stricter in its own ways:
  - only boolean, integer, string and string-array fields match;
  - `maxLength` counts UTF-8 bytes;
  - a string array without `maxItems` holds no item, and its items are not
    held to the field's enum;
  - a pattern the Catalog evaluator does not read matches nothing.
- **`arkdeck-cli`**, new `workspace_continuation.rs`:
  - Swift `CLIJobReadValidation` for `show` and `status`, in its words. A
    status whose next action needs a person or a reconciliation still reads.
  - Swift `RuntimeOperationRequest` decoding as pass or fail, returning the
    document it encodes back to. That document is also what two requests
    compare by, so a `reviewedPlanDigest` does not count. Swift refuses
    governance and retired-authority members by name before its closed
    member set, only to report them apart; for pass or fail the closed set
    alone decides, so the CLI keeps that set only.
  - `requires_current_target`, `Draft::prepare`, `Draft::request`,
    `Draft::validate_accepted_job`, `Draft::projection` and
    `continue_workspace`, the flow over one request function.
  - The parser serves the three leaves with `--source-job`,
    `--continuation-request-id` and `--timeout`. `main.rs` runs them over one
    bounded connection, whose first exchange is the leaf's own `health`.
  - `run`'s terminal exit is `job_plan::run_exit` of the emitted Job.
  - The fresh request's `requestJson` text is the canonical document as
    Swift's `CanonicalJSONEncoders.canonical()` writes it. Keys come in
    ordinal order (`requestId` before `requestedOutputs`), with
    `\u0001`-style escapes and no escaped slash; the oracle checks this byte
    for byte.
- **Swift argv fixtures**: `workspace.continuation.{inspect,submit,run}.json`
  (21 cases) are copied unchanged into `rust/tests/fixtures/current-cli-argv`,
  so the three leaves are listed by `arkdeck commands`.

## The oracle

`CLIWorkspaceContinuationOracleContractTests` (new file) records
`rust/tests/fixtures/workspace-continuation/cases.json` from Swift's own
functions:

| Part | Cases | What Swift answered |
| --- | --- | --- |
| `sources` | 87 | Whether the Target is read (`sourceRequiresCurrentTarget`), and the draft or refusal (`prepare`): code, words and `details` |
| `requests` | 11 | The fresh request's `requestJson` text for each continuation identity, or the refusal |
| `accepted` | 23 | What `validateAcceptedJob` makes of the Job an identity resolves to |
| `projections` | 4 | What `submit` and `run` emit |

The sources cover accepted device, host-only and diagnostics sources. They
also cover every refusal `prepare` makes and every path of the typed request's
decoding. The rest are each input constraint and Target display-name rule,
and a host-only source that carries a binding.

## Findings

- **Swift's precomposition check never refuses.** Swift compares a display
  name with `name.precomposedStringWithCanonicalMapping` using String `==`,
  which is canonical equivalence (the oracle's `displayNameDecomposed` is
  accepted). The continuation keeps that. The Rust `device wait` leaf's
  `canonical_name` compares bytes, so it refuses a decomposed name that
  Swift's `CLIDeviceWait` accepts. That is a parity gap of that leaf, reported
  and not changed here.
- **The Rust `job status|show` leaves refuse a status waiting on a person**
  (`read_only_resources::validate_job_status`). Swift's `CLIJobReadValidation`
  reads it: only its next action needs attention. The continuation follows
  Swift. That gap is also reported and not changed here.
- **Some Swift checks cannot be reached through the Rust client.** Swift's
  CLI judges Runtime answers the published schemas do not admit: a null
  `actualEffect`, a human action's next-action members, a superseding epoch,
  or an off-contract request. The Rust client refuses such an answer as
  `protocolMalformed` before any leaf reads it. The oracle keeps these cases
  for the function replay: 19 sources and 6 resolved Jobs are off-schema. The
  leaf runs serve only answers the published schemas admit.
- **One connection instead of Swift's one per request.** Swift's client opens
  a connection for each exchange, each with its own contract check, under
  one absolute deadline. This CLI keeps one bounded connection, whose first
  exchange is the leaf's own `health`. The requests, their order and the
  deadline are Swift's; only the Runtime sees the difference.

## Tests

| Test | What it holds |
| --- | --- |
| `workspace_continuation.rs` (new): oracle replay, all platforms | Every source, identity, resolved Job and projection in the oracle answers through this CLI's functions exactly as Swift did: the value, or the refusal's code, words and `details`. The oracle was recorded against this Catalog |
| `workspace_continuation.rs` (new): the leaves against a fake Runtime (macOS) | `inspect` of device, host-only and diagnostics sources. Seven refused sources, with nothing submitted. An identity refused after the source reads. `submit` sends Swift's `requestJson` and reads the Job back, including the conflicting Job an identity resolves to. `run` runs a runnable Job once and reads it back. A settled Job is emitted and exits 1 as failed. A queued Job is refused, and an unconfirmed run exits 75 and is never read on |
| `workspace_continuation::tests` (unit) | The typed request decodes as Swift's, with its defaults and without the reviewed digest, and 20 malformed members are refused |
| `operation_catalog::tests::continuation_inputs_match_the_catalog_as_swift_judges_them` (contract unit) | The input rule over `capture.diagnostics@1`'s constraints, including UTF-8 byte counting, and an Artifact lease field |
| `argv_fixtures.rs` | The three copied Swift fixtures replay with no new deviation |
| Swift `CLIWorkspaceContinuationOracleContractTests` | The checked-in oracle is byte for byte what Swift answers |

## Local targeted checks

Logs are under `/private/tmp/`.

| Check | Command | Result |
| --- | --- | --- |
| fmt | `cargo fmt --all --check --manifest-path rust/Cargo.toml` | exit 0 (`arkdeck-wc-fmt.log`) |
| clippy | `cargo clippy -p <crate> --all-targets -- -D warnings` for `arkdeck-contract` and `arkdeck-cli` | exit 0 for each (`arkdeck-wc-clippy-<crate>.log`) |
| Dependents compile | `cargo check --all-targets -p arkdeck-hoststore -p arkdeck-agentd -p arkdeck-soak -p arkdeck-control -p arkdeck-client` | exit 0 (`arkdeck-wc-check-dependents.log`); the contract change only adds a function |
| Tests | `cargo test --no-fail-fast -p arkdeck-contract` and `-p arkdeck-cli` | exit 0 for each: contract 58 passed, cli 284 passed; none failed (`arkdeck-wc-test-<crate>.log`) |
| After the rebase onto `aa2afe6ba` | fmt, clippy (contract, cli), both crates' tests and the read-only host check again | exit 0 each: contract 58, cli 289 passed (with #2173's registry pass, whose argv replay also names these leaves' refusals), none failed; `PASS` (`arkdeck-wc2-*.log`) |
| After the replay onto `4137506c3` | `cargo check --all-targets -p arkdeck-cli -p arkdeck-contract` | exit 0 (`arkdeck-wc3-check.log`) |
| Read-only host check | `rust/scripts/check-readonly.py --bin-dir <this build>` (validation venv) | `PASS`: 136 control responses, 13 CLI envelopes, 127 valid requests; exit 0 (`arkdeck-wc-readonly.log`) |
| Swift oracle | `sh Packages/ArkDeckKit/Scripts/run-swiftpm.sh test --filter CLIWorkspaceContinuationOracleContractTests`, recorded, then compared | exit 0 both ways (`arkdeck-wc-swift-record3.log`, `arkdeck-wc-swift-compare.log`) |
| Mutations | nine, one at a time (`wc_mutations.py` in the session scratchpad): `maxLength` counted in characters; attention statuses refused; the provider unchecked; the Target read for every source; the outputs reordered; effect drift ignored; the display name held to its precomposed bytes; `run` exiting 0 whatever its Job; the governance-member check dropped | eight killed by the oracle replay, the contract unit test or the leaf runs. The ninth survived as an equivalent mutant: every governance and retired-authority member is also outside the request's closed member set, so that check could not change a pass-or-fail decode. It was removed from the CLI's decode and the eight were run again on the final source; all eight killed, sources restored by digest (`arkdeck-wc-mutations.log`, `arkdeck-wc-mutations2.log`) |
| Records | `ARKDECK_PYTHON=<validation venv> sh scripts/check-sdd.sh` | PENDING |

Not run, because no input it reads changed: `generate-contract.py --check`.
The copied argv fixtures are not contract inputs; `check-contracts.py` only
holds them byte-identical to Swift's corpus.

## CI

- #2177, the move this slice stands on (head `4a57d1128`): `guard` (run
  `36103995265`) and `swift` (run `36103995476`) passed. All four Rust lanes
  passed: host-independent, ubuntu, macos-26 and windows. `swift-tests` was
  not selected. It merged as `4137506c3`.
- This slice, first push (head `a5530b353`, stacked): `guard` (run
  `36104171584`) and `swift` (run `36104171633`) passed. `swift-tests`
  passed, which ran `CLIWorkspaceContinuationOracleContractTests` against
  the checked-in oracle, and so did all four Rust lanes.
- After the replay onto `4137506c3`: pending.
