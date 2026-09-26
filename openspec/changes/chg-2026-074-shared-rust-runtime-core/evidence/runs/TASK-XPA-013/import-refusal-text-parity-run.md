# `artifact.import.*` refusals in Swift's words (TASK-XPA-013)

Swift's daemon answers a refused Import request with the Import owner's code
and a text of its own for each condition. The App's Debug upload (ClientKit
`RuntimeAppArtifactUpload`) shows only `error.message`, and both CLIs print it
as `error.message` in machine output. The Rust Import owner and the Rust CLI
answered many of those refusals with Swift's code but another text: two
catch-all texts for every `invalidInput` and `resourceConflict`, a rewrite of
the Target owner's binding refusals, and CLI texts of their own. This change
gives each of them Swift's text, fixes three orders of checks that answered a
request with several faults in a different code, and replays Swift's answers
byte for byte.

Base: protected `main` `76dcad2e9`.

- Developed and checked on `896565e97` (#2232), then rebased onto
  `76dcad2e9` so the PR carries the helper packaging check fix (#2236,
  `7064dabb1`). That rebase touched no file of this change.
- The Swift oracle was recorded on `d7273116f`. No Swift source changed
  between it and the new base: `git diff --stat d7273116f 76dcad2e9 --
  Packages/ArkDeckKit/Sources` is empty.
- No contract input, schema, corpus line, Catalog or `tasks.md` changes.
  Routed methods and executable operations are unchanged.

| Already on `main` | This change | Still remaining |
|---|---|---|
| #2232: every commit refusal in Swift's text, and the Target owner's binding refusal text | begin, append, abort, inspect, inspection, release and list refusals, the missing-owner refusal, the CLI's own refusals of an upload, in Swift's text; three check orders; a Swift oracle and its replays; a concurrent-begin proof | The App channel's refusal codes (X3, X4); the Rust CLI's own pre-refusals (X6); the native-library name refusal (X7); the per-fault storage texts (declared below); a foreign or reclaimed list cursor, whose text the shared snapshot pager gives and the CLI lane's pager change aligns for every method it serves; the missing `resourceNotFound` in the inspection and release schemas (X9, contract queue) |

## What was measured first

The coordinator's rulings rest on a survey of every `artifact.import.*`
refusal: Swift's texts from the ControlFrames corpus or its source, Rust's
from a temporary hoststore probe (not committed) that drove the owner into
each refusal, 50 of them, before this change. It found:

- 32 wire refusals whose code was Swift's and whose text was not;
- 17 texts of the Rust CLI's own, of which those with Swift's code change here;
- one difference only in human-readable output;
- nine refusals whose code differs:
  - this change fixes two of them (X1, X2) and proves one (X8);
  - four are left to their own changes (X3, X4, X6, X7);
  - one is a declared difference (X5) and one is in the contract queue (X9).

A wire refusal's message reaches the CLI's machine output unchanged: Swift
passes it through `CLIRuntimeSession.mapped`, Rust through
`CliError::from_client` (`arkdeck-cli/src/lib.rs`). So the wire texts reach
the App and both CLIs alike.

## Swift's answers: the oracle

`ImportRefusalOracleContractTests` drives Swift's `RuntimeControlPlaneHandler`
over an actual `RuntimeArtifactStore`, `RuntimeTargetStore` and
`RuntimeJobEngine`, and Swift's `arkdeck` CLI against that handler's daemon,
into each refusal the corpus holds no frame of. It asserts each exact code
and message. With `ARKDECK_IMPORT_REFUSAL_ORACLE_OUTPUT` set it writes
`rust/tests/fixtures/import-refusal-oracle/cases.json`; without it, it
compares Swift's answers with that file byte for byte.

- 40 wire cases:
  - append: its bounds, identity and generation checks and their order, and the owner's generation and overlap refusals;
  - abort, commit, inspect, inspection and release: their identity and generation checks and orders;
  - release with an active materialization, and with a Job referencing the Import;
  - list: its closed options and malformed cursors;
  - begin: its two Target binding refusals, and a Target store that cannot be read (the handler's catch-all).
- 5 CLI cases: a source that cannot be opened, one outside its kind's bound, metadata outside its kind, a changed source for an existing request identity, and other metadata for one.
- Runtime identities are recorded by the names the replay substitutes (`provenance.json`).
- Not recordable, so cited from Swift's source instead:
  - "Import requires the target's current proven HDC route" (`RuntimeImportControlHandler.swift:164`): Swift reaches it only if a Target disappears between two reads.
  - "Import snapshot exceeds its storage bound; narrow the query" (`RuntimeArtifactStore.swift:1586`): it needs more than 16 MiB of projections.

## What changes in the Rust Runtime

In the Import owner (`arkdeck-hoststore` `import_upload.rs`,
`import_lifecycle.rs`, `import_publication.rs`):

- **Parameters are judged before a record is read, in Swift's order.** Swift's
  handler judges the parameter names, then the identity (a non-empty string:
  "Import identity is required"), then the generation ("exact Import
  generation is required"). The owner's lookup then judges the identity's
  form ("invalid Import identity", "invalid Import request identity").
  - append judges its offset, bytes and digest first ("Import append requires
    exact bounded bytes, offset and digest").
  - release and commit judge the generation before the lookup and the
    identity's form.
  - release refuses generation "0" as `invalidInput`, where it answered
    `resourceConflict`.
  - Before this change a request with several faults could be answered
    another code than Swift's.
- **The owner's refusals carry Swift's texts:**
  - the parameter names: "Import control parameters are closed" (append,
    abort, commit, release), "exactly one Import selector is required"
    (inspect, inspection);
  - begin's metadata: "Import requires registered metadata and exact
    target/binding references";
  - append: "Import generation or state changed", "Import chunk size or digest
    is invalid", "Import chunk overlaps different committed bytes", "Import
    chunk does not start at the committed offset";
  - abort: "Import commit or another generation owns this upload";
  - commit: a HAP that is no ZIP, "Import is not a ZIP-based HAP/HSP
    container";
  - release: "release requires the exact committed Import generation", "Import
    is still used by an active materialization", "Import is still referenced by
    an active or uncertain Job";
  - list: "Import list options are closed", "Import filter is invalid",
    "invalid pageSize", "invalid Import cursor". The capture is bounded by 16
    MiB of canonical projection bytes, as Swift's `listImports` bounds it
    before its pager.
  - A foreign or reclaimed list cursor is not changed here, by the hub's
    division of the work. The Import owner passes the shared snapshot
    pager's refusal through, and the CLI lane's pager change gives the pager
    Swift's shared text for every method it serves.
- **begin's Target binding.**
  - begin passes the Target owner's `resourceConflict` through, as Swift's
    `binding` does, instead of rewriting it; after #2232 that owner speaks
    Swift's text.
  - A missing Target owner is refused with "Import owner services are
    unavailable".
  - Any other failure to read the Target store gets the handler's catch-all.
- **Storage faults** carry Swift's catch-all "Import state or immutable content
  is unreadable" where two Rust texts stood.

In `arkdeck-agentd` `Host::imports_for`, a composition without the Target,
Artifact or Job owner refuses with Swift's "Import owner services are
unavailable". The production composition holds all four.

In the Rust CLI (`arkdeck-cli` `import_resources.rs`), each refusal of the
CLI's own with Swift's code carries `CLIImports.swift`'s text:

- a changed source, "Import source changed; staged data was not overwritten or aborted", in all three places;
- "Import request identity already names different metadata";
- "target has no exact current binding reference";
- "Import receipt changed the upload metadata";
- "Import append returned another owner or offset";
- "Import recovery changed its owner or committed prefix";
- "Import commit returned another owner";
- the release receipt's two texts;
- the inspection's two texts;
- the page and row texts of a listing;
- "Runtime returned an invalid Import projection";
- the metadata text;
- "Import client timed out; inspect or retry the same request identity";
- "Import source cannot be opened", and "Import source exceeds its registered regular-file bound".

## Concurrent begins (X8)

Swift guards concurrent begins of one request identity in memory and refuses
all but the first with `resourceConflict` "Import begin is already in
progress". The Rust owner holds its lock across the lookup, the binding and
the durable record. Its store is exclusive to one process: a second open of
the same root fails
(`one_owner_and_private_directory_bindings_prevent_foreign_writes`).
`concurrent_begins_of_one_request_allocate_one_import` races 8 threads on one
request identity for 16 rounds, and in every other round races two metadata.
In every round:

- one Import is allocated;
- every accepted answer is the same projection;
- every other answer is `idempotencyConflict` in Swift's words;
- the store holds one record, one identity map and one empty staging file per
  request, and nothing temporary.

A concurrent begin is answered as Swift answers a repeated one. The test
passed 20 runs in a row. This is a declared difference, by the coordinator's
ruling: serializing is safer than an in-memory guard.

## Declared differences

- **Storage-fault texts.** Swift's store names about 35 faults in words of
  its own; this owner answers each with the catch-all. Aligning them one by
  one would need a Swift fault injection per fault.
- **Concurrent begins**, as above.
- **Only in human-readable output.** An upload whose Import is aborted or
  released ends differently:
  - Swift prints the projection as its machine result, then exits 1 with a
    human line;
  - Rust answers `operationFailed` "Import request is terminal; use a new
    request identity for a new input".

  This is a difference of result shape, not a text of the same code, so it
  is left to the CLI changes (X6, X7).
- **A Runtime inspection whose nested Import is malformed.** Swift answers
  "Runtime returned an invalid Import projection"; the Rust CLI answers "Import
  reference inspection is malformed". Only a corrupt daemon answer reaches it.
- **Rust-only guards with texts of their own**, none of which Swift has or a
  correct composition reaches:
  - begin's check that the Target owner resolved a complete binding;
  - the Import clock;
  - the internal record invariants.

## Tests

| Where | Test | Holds |
|---|---|---|
| hoststore | `refusal_oracle_tests::swift_recorded_refusals_the_corpus_lacks_are_answered_in_swift_s_words` | all 40 oracle wire cases, as the daemon routes each method, with the real Target owner: code, message and details byte for byte |
| hoststore | `refusal_oracle_tests::corpus_import_refusals_are_answered_as_swift_s_daemon_answered_them` | 16 recorded corpus refusals of begin, append, abort, inspect, inspection, list and release (the list's foreign cursor is left to the pager change) |
| hoststore | `refusal_oracle_tests::concurrent_begins_of_one_request_allocate_one_import` | X8 |
| hoststore | `tests/import_upload.rs` | 14 assertions that compared codes now compare code and message |
| agentd | `import_tests::a_host_without_the_import_owners_refuses_as_swift_s_handler_does` | a Host without the owners answers each of 7 methods as the corpus's Swift frame |
| agentd | `import_tests` | 3 assertions that compared codes now compare code and message |
| CLI | `upload::swift_recorded_upload_refusals_are_answered_in_swift_s_words` | the 5 oracle CLI cases, rendered as this CLI prints them (`failure_envelope`), and their exit statuses |
| CLI | `upload::upload_refusals_of_unacceptable_runtime_answers_are_swift_s` | six of the CLI's own refusals no oracle holds, cited from `CLIImports.swift`: a Target without its binding, an answer that is no Import, a begin, an append or a commit answering other metadata, another offset or another owner, and the client's deadline |
| CLI | `import_resources` | 4 assertions that compared codes, or only that the call failed, now compare code and message; an inspection and a release receipt of another Import |

## Verification

**Local targeted checks.**

- Environment: `CARGO_BUILD_JOBS=2`, own target
  `/private/tmp/arkdeck-sleepy-allen-1abe73-rust-target`, logs in the session
  scratchpad (`xpa013-*.log`).
- The Swift rows ran on `d7273116f` in a SwiftPM window the hub granted.

| Check | Command | Result |
|---|---|---|
| Swift oracle | `ARKDECK_IMPORT_REFUSAL_ORACLE_OUTPUT=<new path> sh Packages/ArkDeckKit/Scripts/run-swiftpm.sh test --filter ImportRefusalOracleContractTests` | exit 0; 1 test; 40 wire and 5 CLI cases recorded |
| Swift comparison | `sh Packages/ArkDeckKit/Scripts/run-swiftpm.sh test --filter 'ImportRefusalOracleContractTests\|DurableImportContractTests'` | exit 0; 24 tests, 0 failures |
| Swift mutation | one word of `cases.json` changed, then the same filter | exit 1 at the comparison; restored, digest as recorded |
| Rust format | `cargo fmt --all --check --manifest-path rust/Cargo.toml` | exit 0, before and after the pager split below |
| Rust lint | `cargo clippy -p arkdeck-hoststore -p arkdeck-agentd -p arkdeck-cli -p arkdeck-soak --all-targets -- -D warnings`, native and with `--target x86_64-pc-windows-msvc` and `--target x86_64-unknown-linux-gnu` | exit 0 on all three targets (`xpa013-clippy-*.log`) |
| Rust tests | `cargo test -p arkdeck-hoststore -p arkdeck-agentd -p arkdeck-cli -p arkdeck-soak --no-fail-fast` | exit 0; 172 test binaries, 1,216 passed, 0 failed, 16 ignored (`xpa013-test.log`) |
| After the pager split | the pager's foreign-cursor rewrite and its replay row removed; then `cargo fmt --check`, the lint above for hoststore, agentd and soak natively and for hoststore on the two other targets, and `cargo test -p arkdeck-hoststore --lib` with the seven Import test binaries | exit 0 each; 8 binaries, 381 passed, 0 failed, 7 ignored (`xpa013-r2-*.log`) |
| After the rebase onto `76dcad2e9` | `cargo fmt --check`; the native lint above for the four crates; `cargo test -p arkdeck-hoststore --lib --test import_upload --test import_target`, `-p arkdeck-agentd --bins import_tests`, `-p arkdeck-cli --test import_resources` | exit 0 each; 369, 8 and 13 passed, 0 failed (`xpa013-r3-*.log`) |
| Concurrency | the X8 test binary, 20 runs | 20 passed |
| Records | `sh scripts/check-sdd.sh` (validation venv) | exit 0; 0 errors, 0 warnings |

**CI.** This pull request's lanes; the result is recorded outside this
commit.
