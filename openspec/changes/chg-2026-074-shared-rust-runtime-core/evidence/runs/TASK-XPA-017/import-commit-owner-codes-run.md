# `artifact.import.commit` publishes the Import owner's refusals (TASK-XPA-017, contract)

The App's Debug upload (ClientKit `RuntimeAppArtifactUpload`) and the CLI's
`artifact import <kind>` finish an upload with `artifact.import.commit`. When
the Import owner refuses the commit, Swift's daemon answers the owner's code
and message with its zero-dispatch evidence. Four of those codes —
`resourceNotFound`, `resourceConflict`, `artifactIntegrityFailed` and
`quotaExceeded` — were missing from the method's published schema, whose
corpus had recorded none of them. The Rust control layer rewrites an answer
outside its method's schema as `internalError` "the result does not conform
to the current contract", so on the Rust daemon:

- the App showed that text instead of why its upload was refused (S9, #2132,
  first saw it; S26 met it again as `resourceConflict` "The exact Target
  binding is no longer current" for a Swift-recorded upload);
- the Rust CLI read `internalError` without evidence, which §8.4 maps to
  `outcomeUnknown` for a mutation-capable method: it inspected the upload
  once and exited 75, where Swift's CLI answers the owner's code (exit 65 for
  `resourceConflict` and `resourceNotFound`, 2 for `artifactIntegrityFailed`,
  69 for `quotaExceeded`).

This change records Swift's answers, widens the one schema from them, and
makes the Rust Import owner answer each of them with Swift's text.

Base: protected `main` `dc709dc3e` (#2224). Developed and first checked on
`3315a9cba` (#2217), then rebased onto `9f1fdcce3` (#2222, after #2220's
agent schema widening): that rebase touched none of this change's files but
the generated baseline, which was regenerated over the new base (not merged
by hand), and every check below after the Swift rows ran again. #2223 and
#2224 then changed no contract input; after the last rebase
`generate-contract.py --check`, `cargo fmt --check`, the family check and
the three new Rust tests ran again (exit 0). No stack. Routed methods and
executable operations are unchanged.

| Already on `main` | This change | Still remaining |
|---|---|---|
| The Rust Import owner's commit (#2121 line of work) and the App ingress admitting it (#2132); the owner codes in `append`, `abort` and `begin`'s schemas | Swift frames of every commit refusal; `artifact.import.commit`'s schema publishing the four codes; the Rust owner's commit refusals in Swift's text; tests through the control layer, the production Host, the App ingress and the CLI's §8.4 mapping | The other Import texts that are not Swift's (below); `artifact.import.inspection` and `release` lack `resourceNotFound` (and `inspection` `inputTooLarge`) in the same way |

## Does Swift answer these codes?

Yes, as they are. Swift's daemon does not hold its answers to the method
schemas: `RuntimeControlPlaneHandler.handleFrame` dispatches `artifact.import.*`
to `RuntimeImportControlGateway`, whose `RuntimeImportControlHandler.response`
answers an `AgentExecutionControlFailure`'s code and message verbatim, and a
`RuntimeArtifactError.quotaExceeded` as `quotaExceeded`, each with
`{"phase": "importOwner", "newDispatchCount": 0}`. The schema was narrower
than Swift's own behaviour, so this is a widening from witness frames, as
#2197 and M4-4b2 (`app-flash-upload-run.md`) were, and no new contract
decision. The new Swift test below measured it: every refusal it provokes
answers the owner's code.

## Who decodes the new codes

- **The App (ClientKit).** `RuntimeXPCRequestTransport` checks only the
  envelope (`ControlProtocolContract.responseFields`: a non-empty string
  code, a string message, object details), and `RuntimeAppArtifactUpload`
  reads only `error.message`. The vocabulary is open: no App change, and an
  App built before this change decodes the new codes. The contract identity
  (`1d7d101e83fe…`), which the App's health check compares, is unchanged.
- **Swift's CLI** maps any wire code through `CLIControlFailureMapper` and
  never checks it against the method schema.
- **The Rust CLI** decodes a response against the method schema compiled in
  (`arkdeck_contract::decode_response`), then maps it as Swift's mapper does
  (`failure_mapping::wire_code`, §8.4). `artifact.import.commit` is
  mutation-capable. With the Import owner's evidence — phase `importOwner`
  and zero new dispatches, which every one of these answers carries — each of
  the four keeps its code. Without it, `resourceConflict` and
  `resourceNotFound` keep theirs only with the pre-admission proof, and
  everything else is `outcomeUnknown`. The CLI's upload inspects once and
  never re-commits after an `outcomeUnknown` commit; a refusal it can read
  now ends the upload with the owner's code instead.

## Task

TASK-XPA-017, not TASK-XPA-019:

- the Rust half is Runtime owner behaviour (the Import owner's commit texts,
  the Target owner's refusal text), which TASK-XPA-019 forbids
  (`rust/**` runtime semantics) and TASK-XPA-017 allows;
- the App needs no change: ClientKit reads only the message;
- the defect blocks GJ-2 and GJ-3 uploads on the pure Rust daemon, which is
  TASK-XPA-017's acceptance, and the nearest precedent — the Import schemas
  widened from Swift frames for the App's flash bundle upload (M4-4b2) — is
  recorded here.

## The frames

`DurableImportContractTests.testCommitRefusalsCarryTheImportOwnersCodeMessageAndEvidence`
drives Swift's `RuntimeControlPlaneHandler` through each refusal and asserts
the exact answer — code, message and `{"phase": "importOwner",
"newDispatchCount": 0}` — and that nothing was published:

| Scenario | Code | Message |
|---|---|---|
| an Import this Runtime never began | `resourceNotFound` | Import does not exist |
| an upload whose bytes have not all arrived | `resourceConflict` | Import is incomplete or no longer uploadable |
| a complete upload whose Target this Runtime no longer holds (a handler over an empty Target store) | `resourceConflict` | the exact target binding is no longer current |
| a complete upload bound, when it began, to another identity of its Target | `resourceConflict` | target binding changed during Import |
| a complete upload whose bytes are not the ones its metadata names | `artifactIntegrityFailed` | Import source digest does not match its metadata |
| a complete, valid upload the Artifact store has no room to publish (a 1 KiB quota) | `quotaExceeded` | Artifact capacity is exhausted; the Import remains discoverable |

The refused uploads stay `inProgress` without a receipt; the one the store
had no room for keeps its durable commit intent (`committing`).

Recorded with `ARKDECK_CONTROL_FRAME_LOG`: six `artifact.import.commit`
frames, one per row.

## The contract change

- **Corpus, append-only.** `ControlFrames/artifact.import.commit.jsonl` keeps
  its 7 lines verbatim and gains 7 (14):
  - the six frames above;
  - one frame of `admissionDenied` (Swift's App transport refusing to commit
    an Import it did not begin, `phase: preAdmission`), recorded by the
    existing `testRestartDoesNotGiveAppOwnershipOfCLIOrUnmarkedImports`.
    The schema already published `admissionDenied` — from an earlier
    whole-suite recording whose frame the corpus selection dropped — so the
    committed corpus alone did **not** reproduce the committed schema: a
    corpus-only re-derivation would have silently unpublished it. With this
    one frame it does, byte for byte in `$defs`.
- **Schema, widened only.** `generate-control-contract.py
  --derive-method-schemas` ran over the final corpus in an isolated copy of
  its inputs (`scratchpad/s33/derive_one.py`), as a check. The committed
  schema was widened by hand — `errorCode` gains the four codes — and
  asserted equal to that derivation's `$defs`. The sample counts grow by the
  appended lines (requests 48 → 55, errors 16 → 23). No request, result or
  error detail changes.
- **Structural check** (`scratchpad/s33/covers.py`): exactly one difference,
  `errorCode.enum`, covered; run the other way round it reports a narrowing.
- **jsonschema 4.26** (validation venv): the committed schema admits the 7
  committed lines, refuses the six new refusal frames and admits the
  `admissionDenied` frame; the widened schema admits all 14 lines, and every
  one of the 150 `artifact.import.*` frames the Import test classes recorded
  in the validation run below.
- **Generated.** `rust/scripts/generate-contract.py --write` refreshed
  `spec/baselines/swift-single-v1.json` (105 methods, 1017 recorded shapes,
  1010 before); the contract identity and the generated bindings are
  unchanged. `runtime-control-plane.schema.json` names the method schema by
  path, and no bundle product digests method schemas, so no export changes.

## The Rust Runtime

The control layer needs no change: it already passes every answer the
compiled schema admits. Three commit refusals of the Rust owner carried
another text than Swift's, and now carry Swift's (code and details
unchanged):

| Refusal | Before | Now (Swift's) |
|---|---|---|
| incomplete upload, another generation, not uploadable | Import generation, committed offset or lifetime state changed | Import is incomplete or no longer uploadable |
| the Target owner resolves another binding than the upload's | (the same) | target binding changed during Import |
| the Target owner holds no Target at the upload's revision | The exact Target binding is no longer current | the exact target binding is no longer current |

The last is the Target owner's own text
(`TargetStore::resolve_import_binding`), which Swift's commit answers as it
is. `begin` rewrites that refusal into its own text, as before.

Tests:

- `arkdeck-control` `every_recorded_commit_refusal_reaches_the_caller_as_the_import_owner_answered_it`:
  every recorded refusal in the corpus, answered by an Import owner, reaches
  the caller unchanged; each of the four codes is published exactly where the
  view's corpus holds a frame of it. Corpus and schema are one view's, so it
  holds in both of check-contracts' views.
- `arkdeck-agentd` `commit_refusals_reach_the_local_client_and_the_app_as_swifts_daemon_answers_them`
  (App ingress, production Host owners over the Import Target fixture): five
  of the scenarios — the local client's and the App's — each answered as the
  corpus's Swift frame of that code and message. It decides by the compiled
  schema: where the merge base's schema predates a code (check-contracts'
  published view) it expects the control layer's `internalError` and asserts
  it is that view.
- `arkdeck-hoststore` `publication_refuses_partial_digest_binding_and_quota_without_a_receipt`:
  the owner's own answer — code, Swift's text and evidence — for the partial,
  generation, digest, Target, binding and quota refusals and an absent
  Import, with no receipt and the state each leaves.
- `arkdeck-cli` `import_owner_errors_remain_distinct_and_lost_mutation_responses_are_unknown`:
  commit's owner codes keep their code and exit status, as append's do.

The control and App ingress tests read Swift's answers from the corpus, so
the appended lines are the oracle they replay: the corpus stays append-only,
as every method's does.

## Not changed (found on the way)

- **A missing Import on the App transport.** Swift's App gateway refuses it
  before the owner (`admissionDenied`, `preAdmission`); the Rust owner
  answers `resourceNotFound` (`importOwner`). This is #2132's declared
  difference — the owner, not a gateway read, checks App scope — now visible
  for commit as it already was for append.
- **Other Import texts that are not Swift's**, all refusals of the same
  code: the HAP container check (Swift: "Import is not a ZIP-based HAP/HSP
  container", corpus line 2; Rust: "Import content failed its registered
  format validator"); the closed-parameter, identity and generation checks;
  `begin`'s binding refusals; `append`'s and `abort`'s conflicts; the Target
  owner's storage faults. A message-parity slice of its own.
- **`artifact.import.inspection` and `artifact.import.release`** lack
  `resourceNotFound` (and `inspection` `inputTooLarge`) in the same way; this
  change widens no other method.

## Verification

**Local targeted checks.** `CARGO_BUILD_JOBS=2`, own target
`/private/tmp/arkdeck-1330-rust-target`, logs `/private/tmp/arkdeck-s33-*.log`
(`-r-` after the rebase). The Swift rows ran on `3315a9cba`, in the Swift
window the hub assigned; the rebase changed no Swift file they compile
against the Import owner (its Swift changes are the Xcode tool shim, the
workspace provider and other oracles).

| Check | Command | Result |
|---|---|---|
| Swift frames | `ARKDECK_CONTROL_FRAME_LOG=<fresh> sh Packages/ArkDeckKit/Scripts/run-swiftpm.sh test --filter 'DurableImportContractTests/testCommitRefusalsCarryTheImportOwnersCodeMessageAndEvidence'`, then the same for `…/testRestartDoesNotGiveAppOwnershipOfCLIOrUnmarkedImports` | exit 0 and 0; 1 test each; 6 commit refusal frames, then the `admissionDenied` frame (`swift-record.log`, `swift-record-r2.log`) |
| Derivation | `derive_one.py` over the committed corpus, the committed corpus with the `admissionDenied` frame, and the final corpus | the first lacks `admissionDenied`; the second equals the committed `$defs`; the third equals the widened schema's `$defs` |
| Structural | `covers.py` both ways; every `artifact.import.*` schema against `origin/main` | one covered widening, reported as a narrowing reversed; the other seven Import schemas and every other method schema byte-identical to `main` (`r` run: `family-covers.log`) |
| jsonschema 4.26 | the committed and the widened schema over the corpus and the frames | committed: 7/7 committed lines, the 6 refusals refused, the `admissionDenied` frame admitted; widened: 14/14 and 150/150 Import frames of the run below |
| Affected Swift classes | `ARKDECK_CONTROL_FRAME_LOG=<dir seeded with both recordings> sh Packages/ArkDeckKit/Scripts/run-swiftpm.sh test --filter 'ControlMethodSchemaContractTests\|DurableImportContractTests\|FlashBundleImportViewsContractTests'` | exit 0; 30 tests, 0 failures (`swift-validate.log`) |
| Contract | `python3 rust/scripts/generate-contract.py --write`, then `--check`; `generate-control-contract.py --check`; `refresh-contract-digests.py --check` | exit 0 each; after the rebase 105 methods, 1027 recorded shapes (1020 on `main`); identity `1d7d101e83fe…` unchanged |
| Format | `cargo fmt --all --check` | exit 0 |
| Clippy | `cargo clippy -p arkdeck-hoststore -p arkdeck-control -p arkdeck-agentd -p arkdeck-soak -p arkdeck-cli -p arkdeck-contract --all-targets -- -D warnings`, native and with `--target x86_64-unknown-linux-gnu` and `--target x86_64-pc-windows-msvc` | exit 0, 0 and 0 (`r-clippy*.log`) |
| Tests | `cargo test -p arkdeck-hoststore --test import_upload --test import_target`; `-p arkdeck-control`; `-p arkdeck-contract`; `-p arkdeck-cli --test import_resources`; `-p arkdeck-agentd --bin arkdeck-agentd -- app_ingress` | exit 0 each: 41 passed (1 ignored), 31, 59, 11, 31 (`r-test-*.log`) |
| Mutations | `mutate.py` (scratchpad/s33): the corpus without the `quotaExceeded` frame; the control layer still rewriting `resourceConflict` of a commit; the owner's old generic text for a changed binding | each caught (101) by the tests named above, each file restored by digest (`mutations.log`) |
| Records | `ARKDECK_PYTHON=<validation venv> sh scripts/check-sdd.sh` | exit 0; 0 errors, 0 warnings |
| Both contract views | `CARGO_INCREMENTAL=0 CARGO_PROFILE_DEV_DEBUG=line-tables-only /private/tmp/arkdeck-validation-venv/bin/python rust/scripts/check-contracts.py --output-dir /private/tmp/arkdeck-s33-contract-check` | not completed: started, then stopped at the coordinating session's request (AGENTS.md: local checks before a push are the targeted ones; the two views are a step of CI's macOS workspace job). By then the published view's `cargo clippy --workspace --all-targets -D warnings` had passed; its `cargo test --workspace` was stopped while compiling. Its view directory was removed (`check-contracts.log`) |

**CI.** Pending.

No device, installed service or App was used; nothing here is device
evidence.
