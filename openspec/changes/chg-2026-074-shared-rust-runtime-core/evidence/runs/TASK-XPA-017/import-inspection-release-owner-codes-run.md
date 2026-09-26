# `artifact.import.inspection` and `artifact.import.release` publish the Import owner's refusals (TASK-XPA-017, contract)

`import-commit-owner-codes-run.md` (#2232) left this gap open: the two
schemas lacked codes that Swift's daemon answers.

- `artifact.import.inspection` lacked `resourceNotFound` and `inputTooLarge`.
- `artifact.import.release` lacked `resourceNotFound`.

The Rust control layer rewrites an answer outside its method's schema as
`internalError` "the result does not conform to the current contract". So on
the Rust daemon, for an Import that does not exist:

- `arkdeck artifact import inspect` (which sends `artifact.import.inspection`)
  read `internalError`, where Swift's CLI answers `resourceNotFound`.
- `arkdeck artifact import release` read the same answer, with no evidence.
  For a mutation-capable method, §8.4 turns that into `outcomeUnknown`.

Neither method reaches the App: Swift's App transport admits neither, and
neither does the Rust App ingress.

This change records Swift's answers, widens the two schemas from them, and
gives the Rust Import owner's reference-scan refusals Swift's evidence.

Base: protected `main` `8bddca654` (#2249). The work began on `d238bec7d`
(#2246), where Swift's answers were recorded and validated. Between the two,
`main` changed no Swift source and no contract input: the baseline
regenerated over the new base is byte-identical. No stack. Routed methods,
executable operations and the contract identity (`1d7d101e83fe…`) are
unchanged.

## Does Swift answer these codes?

Yes, as they are. `RuntimeImportControlHandler.response` answers the owner's
`AgentExecutionControlFailure` code and message with
`{"phase": "importOwner", "newDispatchCount": 0}`:

- `resourceNotFound` comes from `RuntimeImportStore.byID` and
  `RuntimeArtifactStore.inspectImport`;
- `inputTooLarge` comes from `RuntimeAdmissionService.activeImportReferenceJobs`,
  which reports at most 1,000 active Jobs.

`DurableImportContractTests.testInspectionAndReleaseRefusalsCarryTheImportOwnersCodeMessageAndEvidence`
drives Swift's `RuntimeControlPlaneHandler` through each refusal and asserts
the exact answer:

| Scenario | Method | Code | Message |
|---|---|---|---|
| an Import this Runtime never began, by `importId` | inspection | `resourceNotFound` | Import does not exist |
| a request identity this Runtime never saw, by `importRequestId` | inspection | `resourceNotFound` | Import does not exist |
| the release of an Import this Runtime never began | release | `resourceNotFound` | Import does not exist |
| a committed HAP that 1,001 active `debug.hap@1` Jobs reference | inspection | `inputTooLarge` | Import reference inspection exceeds its Job bound |

All 1,001 submissions were accepted: Swift's submission path has no other
bound. Nothing was dispatched. The measurement matched the expectation, so
the contract change below follows from it.

The 1,001 submissions are there only to reach that bound, which is what
records the `inputTooLarge` frame. They make this one test take about 22 s,
which it adds to the Swift lane; the other three answers need no Job.

Recorded with `ARKDECK_CONTROL_FRAME_LOG` (on `d238bec7d`, 09:34): four
frames, one per row.

## Who decodes the new codes

- **The App (ClientKit)** sends neither method.
- **Swift's CLI** maps any wire code through `CLIControlFailureMapper`, and
  never checks it against the method schema.
- **The Rust CLI** decodes a response against the method schema compiled in
  (`arkdeck_contract::decode_response`), then maps it as Swift's mapper does
  (`failure_mapping`, §8.4).
  - `artifact.import.inspection` is a bounded read, and keeps the owner's code.
  - `artifact.import.release` is mutation-capable. With the Import owner's
    evidence (phase `importOwner`, zero new dispatches), which every one of
    these answers carries, it keeps `resourceNotFound`.

## Task

TASK-XPA-017, as #2232: the same line of work and the same kind of change,
a widening from Swift witness frames with the Rust Import owner answering as
Swift's does. #2232's run record named this gap as remaining.

## The contract change

- **Corpus, append-only.** The existing lines stay verbatim (each file
  begins with `main`'s bytes exactly), and the four frames are appended in
  the order Swift answered them.
  - `ControlFrames/artifact.import.inspection.jsonl`: 9 lines, plus 3, makes 12.
  - `ControlFrames/artifact.import.release.jsonl`: 4 lines, plus 1, makes 5.
- **The committed corpus reproduces the committed schemas.** Each schema was
  derived from its committed corpus alone, with
  `generate-control-contract.py --derive-method-schemas` over an isolated copy
  of its inputs (`scratchpad/contract/derive_one.py`). Each `$defs` came out
  equal to the committed one, so no published code lacked a witness frame (as
  `admissionDenied` did for #2232).
- **Schemas, widened only.** Each committed schema was widened by hand:
  - `errorCode` gains the codes;
  - the sample counts grow by the appended lines: inspection requests 12 → 15
    and errors 2 → 5; release requests 4 → 5 and errors 3 → 4.

  Each widened schema's `$defs` was asserted equal to the derivation over the
  final corpus. No request, result or error-detail shape changes.
- **Structural check** (`scratchpad/contract/covers.py`). It finds one
  difference per method, `errorCode.enum` widened, besides the sample counts.
  Run the other way round, it reports a narrowing.
- **jsonschema 4.26** (the validation venv):
  - the committed schemas admit the committed 9 and 4 lines, and refuse
    exactly the appended frames;
  - the widened schemas admit all 12 and 5 lines;
  - each `artifact.import.*` schema admits every frame of its method that the
    Swift validation run below recorded: 154 frames, 12 of them inspection and
    5 release.
- **Generated.** `rust/scripts/generate-contract.py --write` refreshed
  `spec/baselines/swift-single-v1.json`: 105 methods, 1043 recorded requests
  (1039 before), 468 errors (464 before). The contract identity and the
  generated bindings are unchanged. `refresh-contract-digests.py --check`
  passes: no bundle product digests method schemas.

## The Rust Runtime

The control layer needs no change: it already passes every answer the
compiled schema admits.

- **Missing Imports.** The Import owner already answered both methods'
  missing-Import refusals with Swift's code, text and evidence.
- **The Job reference scan.** The refusals of the scan both methods run
  (`JobStore::with_import_references`) carried no details:
  - `inputTooLarge` "Import reference inspection exceeds its Job bound";
  - the scan's own `recordUnreadable`.

  Swift's handler gives every Import refusal the owner's evidence.
  `import_lifecycle.rs` (`with_owner_evidence`) now adds it where a scan
  refusal lacks it. It leaves the refusals the owner raises itself as they
  are, since they already carry it.
- **The bound.** The bound itself was already Swift's: 1,000 Jobs are
  reported, and the 1,001st refuses.

## Tests

| Where | Test | Holds |
|---|---|---|
| Swift | `DurableImportContractTests.testInspectionAndReleaseRefusalsCarryTheImportOwnersCodeMessageAndEvidence` | the four answers above, and zero dispatch |
| hoststore | `refusal_oracle_tests::corpus_import_refusals_are_answered_as_swift_s_daemon_answered_them` | the owner answers the three missing-Import refusals as the corpus's Swift frames, byte for byte |
| hoststore | `refusal_oracle_tests::an_inspection_past_its_job_bound_is_refused_as_swift_s_daemon_refused_it` | 1,000 referencing Jobs are reported; the 1,001st makes the inspection answer the corpus's `inputTooLarge` frame, evidence included |
| control | `read_only::every_recorded_inspection_and_release_refusal_reaches_the_caller_as_the_import_owner_answered_it` | every recorded refusal of both methods reaches the caller as the owner answered it; the new codes are published exactly where the view's corpus holds a frame of them |
| agentd | `import_tests::inspection_and_release_refusals_reach_the_local_client_as_swifts_daemon_answers_them` | the production Host answers the three missing-Import refusals to the local client as Swift's frames, deciding by the compiled schema: check-contracts' published view expects the old `internalError` |
| CLI | `import_resources::inspection_and_release_refusals_reach_the_caller_with_the_import_owners_code` | this CLI's binary, against a fake Runtime answering the four Swift frames, answers the owner's code, words and exit status wherever the compiled schema publishes the code |

### check-contracts' published view

That view compiles this checkout's `rust/` with the merge base's contract
inputs, whose corpus predates the four appended frames. The first head,
`c9e338c4f`, required them in the hoststore owner's two tests, which read
the corpus through `include_str!`. So those tests failed in that view only
(Swift CI run 36210880468, `Rust workspace (macos-26)`, step `Published
consumer and candidate contract parity`). The checkout and candidate views
passed them, and every other new test passed in all three runs.

The two tests now resolve an appended frame through `appended_refusal`, and
what they require depends on whether the view's corpus holds the frame, not
on which view runs:

- Where the view's corpus holds the frame, the owner's answer must be that
  frame, byte for byte, and the frame must be the answer the test writes
  down.
- Where it does not, the view must be the published one (`CONTRACT_INPUTS`
  of kind `development` naming a `commit`, as agentd's `published_view()`),
  and the owner is held to the same written answer without its witness.

Two local runs check both branches, with the two corpora put back to
`main`'s and restored from `HEAD` afterwards:

- Without a `commit` in the baseline (the checkout view with the frames
  missing), both tests fail with "no Swift frame of … answers …".
- With the baseline naming the merge base as its `commit` (the published
  view), all four tests of the module pass.

The agentd, CLI and control tests already decided by the compiled schema or
by the view's corpus, and passed in the published view.

## Which tests enumerate these corpora

Appending lines to a corpus that a test replays line by line can change that
test's cases (F5 met this in `CLIDomainExecutorEvidenceOracle`). Every reader
of the two corpora was found by searching for their file names, for
`ControlFrames/{method}` and `ControlFrames/\(method)` readers, and for
whole-directory reads. None needs a re-recording:

- `arkdeck-contract` `corpus_parity::all_methods_and_recorded_shapes_in_the_input_manifest_replay_through_rust`
  replays every line of every corpus. It holds each method's counts to the
  regenerated baseline (12/5/7 and 5/4/1), and it passes.
- `arkdeck-contract` `imports.rs` reads both corpora, but only their
  successful rows. The appended refusals leave its cases as they were.
- These readers look a frame up by its code and message, or its parameters,
  and each gains the new cases above:
  - the hoststore oracle's `corpus_refusal`;
  - agentd's `swift_refusal`;
  - the CLI's new test.
- The new control test enumerates the refusals by design.
- `ControlMethodSchemaContractTests` validates the whole corpus against the
  schemas. It passed in the Swift validation run.
- No Swift oracle reads these two corpora:
  - `CLIDomainExecutorOracleContractTests`, `CLIDiagnosticsInspectOracleContractTests`
    and `CLIUIDumpInspectOracleContractTests` read other methods' first
    matching successful frame;
  - `ImportRefusalOracleContractTests` records its own cases;
  - the continuation and resume fixtures that name these methods record live
    CLI flows, not the corpus.
- The other `ControlFrames/{method}` readers (cleanup debt, control actions,
  Job waits and lists, Artifact reads, bootstrap, read leaves) are called for
  other methods only.

## Left open

- **The scan's `recordUnreadable` text.** A reference scan that cannot verify
  a Job answers "The Runtime Job snapshot is unreadable or unsupported". Swift
  answers "Job references cannot be verified from durable history". No Swift
  frame of it is recorded, so the text is unchanged; only its evidence now
  matches.
- The App transport admits neither method, in Swift and in Rust.

## Verification

**Local targeted checks.** `CARGO_BUILD_JOBS=2`, own target
`/private/tmp/arkdeck-sleepy-allen-1abe73-rust-target`. The Swift rows ran on
`d238bec7d` in the SwiftPM windows the hub granted. The other rows ran on
`8bddca654`, after the rebase, except the derivation rows, which ran on
`d238bec7d` and were repeated on `8bddca654` for the corpus prefixes, the old
frames and the structure.

| Check | Command | Result |
|---|---|---|
| Swift recording (window 1) | `ARKDECK_CONTROL_FRAME_LOG=<new path> sh Packages/ArkDeckKit/Scripts/run-swiftpm.sh test --filter DurableImportContractTests/testInspectionAndReleaseRefusalsCarryTheImportOwnersCodeMessageAndEvidence` | exit 0; 1 test; the four frames |
| Swift validation (window 2) | the same variable, pointed at a new directory seeded with the four frames; `--filter 'ControlMethodSchemaContractTests\|DurableImportContractTests\|FlashBundleImportViewsContractTests'` | exit 0; 31 tests, 0 failures, 0 skipped |
| Derivation and structure | `derive_one.py`, `covers.py`, `admits.py` (jsonschema 4.26) | as above |
| Generated | `python3 rust/scripts/generate-contract.py --write`, then `--check`; `generate-control-contract.py --check`; `refresh-contract-digests.py --check` | exit 0 each |
| Format | `cargo fmt --all --check --manifest-path rust/Cargo.toml` | exit 0 |
| Lints | `cargo clippy --manifest-path rust/Cargo.toml -p arkdeck-hoststore -p arkdeck-control -p arkdeck-agentd -p arkdeck-soak -p arkdeck-cli -p arkdeck-contract --all-targets -- -D warnings`, natively and with `--target x86_64-pc-windows-msvc` and `--target x86_64-unknown-linux-gnu` | exit 0 each |
| Rust | `cargo test --manifest-path rust/Cargo.toml -p arkdeck-hoststore -p arkdeck-control -p arkdeck-contract -p arkdeck-agentd -p arkdeck-cli -p arkdeck-soak` | exit 0; 1356 passed, 0 failed, 18 ignored (ignored before this change) |
| Mutations | `scratchpad/contract/mutations.sh`, three mutations, each restored from `HEAD` and checked equal: (1) the two schemas as `main`'s; (2) the two corpora as `main`'s; (3) the inspection's scan refusals without the owner's evidence | each caught: (1) control (`internalError` "the result does not conform to the current contract"), agentd and CLI (only the published view may predate the code); (2) hoststore's two tests and agentd (no Swift frame), control (a code published with no witness), CLI (the frame is not in the corpus); (3) the hoststore bound test (`details` null) |
| Records | `sh scripts/check-sdd.sh` (validation venv) | exit 0; 0 errors, 0 warnings |
| The published view, locally | the two corpora as `main`'s; the hoststore module `refusal_oracle_tests`, with the baseline unchanged and then naming the merge base as its `commit`; everything restored from `HEAD` | without the `commit`, both appended-frame tests fail; with it, 4 passed, 0 failed |

**CI.** The first head, `c9e338c4f`, failed only check-contracts' published
view (run 36210880468, above). Otherwise, this pull request's lanes; the
result is recorded outside this
commit.
