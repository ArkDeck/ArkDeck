# v2 request contract moves from ArkDeckRuntime to ArkDeckCore

Base: protected main `6592bcce`. TASK-XPA-019 / SPK-8 remain incomplete. This slice moves two
files from one module to another. It changes no encoded contract, but it did change the text of
one error message: see Behaviour and wire format, corrected after merge.

## Ruling

The coordination session ruled on 2026-09-19, under authority the maintainer delegated to it,
among three options for `RuntimeWorkspaceContinuation`. It chose the first, in two slices:

1. This slice sinks the v2 request contract into ArkDeckCore, and nothing else.
2. The next slice moves `RuntimeWorkspaceContinuation` into ClientKit, with its XPC provider and
   `make()`. `OverviewResumeSheet.swift` then stops importing Workflows (16 → 15), and the CLI
   reaches it over the transitional edge.

The sink comes first and alone so the maintainer can review it by itself.

Why the contract has to move:
- `RuntimeWorkspaceContinuation.request()` builds a `RuntimeOperationRequest`. `prepare()` calls
  it to check the source's thread and provenance syntax, and fails with
  `continuation_invalid_source_provenance` otherwise.
- ClientKit may import only Core.
- Under `docs/ArchitectureRules.md` §6 example 1, a type needed on both sides sinks to Runtime (a
  contract) or Core (a global model) rather than growing a reverse import. Runtime is not an
  option here: the Swift Runtime is deleted at M5, and the App still builds v2 requests after
  that.

The rejected options:

| Option | Why not |
| --- | --- |
| Split the continuation, and inject the provenance check and the provider from the composition root | Two injection seams that would have to be removed again. It also changes `prepare()`'s API. |
| Wait for M5 | The App's Workflows import count would not drop. |

## What moved

- `Sources/ArkDeckCore/RuntimeOperationModels.swift` and
  `Sources/ArkDeckCore/RuntimeOperationFailure.swift` are the former ArkDeckRuntime files,
  renamed. Each loses one line, its `import ArkDeckCore`, which in Core would be a self-import
  (a ModuleSelfImport warning). The rest of both files is byte-identical. They declare:
  - the request: `RuntimeOperationRequest`, `RuntimeOperationReference`,
    `DurableTargetReference`, `RuntimeClientContext`, `RuntimeRequestedOutput` and
    `RuntimeCapabilityReference`;
  - the rejection: `RuntimeOperationErrorCode` and `RuntimeOperationRequestRejection`;
  - the failure projection: `RuntimeOperationFailure` and its code, category, retryability and
    recovery enums;
  - the package-level `PublishedOperationBundleManifest` and `RuntimeOperationCodec`, and the
    internal `RuntimeWireValidation`.
- Everything the two files depend on was already in Core: `JSONValue`,
  `StrictJSONDuplicateValidator`, `CanonicalJSONEncoders` and `RuntimeOperationCatalog`. They use
  no other ArkDeckRuntime type. Within Runtime, only these two files used the internal
  `RuntimeWireValidation`, and they move together.
- No import changed anywhere else.
  - All 18 source files that name these types already import ArkDeckCore: 13 in Workflows and 5
    in the CLI.
  - Every test file that names them already imports Core. The ones that reach internal members,
    such as `validate()` and `RuntimeWireValidation`, already use `@testable import ArkDeckCore`.
  - The coordination session's estimate of about 14 import changes assumed some users lacked
    Core. None did.
- Nothing spells a module-qualified name such as `ArkDeckRuntime.RuntimeOperationRequest`, so the
  new owner breaks no reference.
- Core's `.strictMemorySafety()` now covers these two files too. They use no unsafe construct,
  and the build reports no new warning.
- ArkDeckRuntime keeps its other contract types (`HumanActionRequired`, the crash-ledger schema,
  AgentStrictJSON) and its host facilities.
- `docs/ArchitectureRules.md`:
  - the diagram's Core label gains the v2 request DTOs;
  - the §1 point on ArkDeckRuntime now says the DTOs are in Core and why;
  - the §4 list of structural tests gains the new test;
  - §6 example 1 cites this move as a precedent.
- `ArchitectureBoundaryContractTests` gains section 9, `testTheV2RequestContractIsDeclaredInCore`.
  It requires the nine public contract types to be declared under `Sources/ArkDeckCore` and none
  under `Sources/ArkDeckRuntime`. Until the continuation slice makes ClientKit use them, nothing
  else would notice if they drifted back.

## Behaviour and wire format

Correction after merge: this section first said nothing changes. One message did change.
When an Artifact lease's binding does not match the request, the rejection is built by string
interpolation of an enum with an associated value. The interpolation is Swift's default
description, and that description names the error code's module:
`rejected(ArkDeckRuntime.RuntimeOperationErrorCode.invalidInput, "…")` became
`rejected(ArkDeckCore.RuntimeOperationErrorCode.invalidInput, "…")`. The error's `code` is
unchanged. Only its `message` text changed, by three bytes.

Nothing checked by this slice's local checks saw it:
- the Rust port copies that text byte for byte in four `arkdeck-hoststore` sources;
- the shared `job.plan` oracle, `rust/tests/fixtures/job-plan-analyzer/cases.json`, records it;
- `JobPlanAnalyzerOracleContractTests` compares against that oracle, and was not among the
  targeted classes.

The follow-up fix (`core-request-contract-message-fix-run.md`) moves the oracle and the four
Rust copies to `ArkDeckCore`. The rest of this section held:
- Codable encodes property names, not module names.
- The coding keys, canonical encoding, strict duplicate-key validation and the request checks
  moved verbatim.
- No contract input changed. `rust/scripts/generate-contract.py` reads other Core files, and
  `spec/control` and `spec/baselines` are untouched.
- The task lists of earlier changes (CHG-2026-049, -056 and -075) name the old path as history.
  `check-sdd` does not resolve those paths.

## Acceptance

| | On `6592bcce` | At this head |
| --- | --- | --- |
| ArkDeckApp files importing `ArkDeckWorkflows` | 16 | 16 |

No App file changes. This slice unblocks the continuation slice, which frees
`OverviewResumeSheet.swift`.

## Local targeted checks

These ran on this change over `6592bcce`, before the check sections were written. The full local
unified gate is not run (AGENTS.md "验证与完成"); the PR's CI is the gate.

| Check | Command | Result |
| --- | --- | --- |
| Swift, the affected classes | `sh Packages/ArkDeckKit/Scripts/run-swiftpm.sh test --filter 'RuntimeOperationContractTests\|CLIWorkspaceContinuationContractTests\|RuntimeCampaignWireContractTests\|ArchitectureBoundaryContractTests\|ArkDeckContractTests\.ArkDeckContractTests/'` | r2 exit 0. 50 passed and 0 failed, all in ContractTests: `ArchitectureBoundaryContractTests` 16 (15 before, plus section 9), `ArkDeckContractTests` 4, `CLIWorkspaceContinuationContractTests` 6, `RuntimeCampaignWireContractTests` 2 and `RuntimeOperationContractTests` 22. `RuntimeOperationContractTests` holds the request contract's codec and validation tests. The run builds every test target of the package, so every source and test file that names a moved type compiled against Core. Among those are the 41 test files, 36 of which use `@testable import ArkDeckRuntime`. No warning names a moved file or the boundary test. Log `/private/tmp/claude-501/-Users-fuhanfeng-Dropbox-Code-Github-ArkDeck--claude-worktrees-blissful-goldstine-c7d922/26822f74-e8f8-4647-9226-2234ed41e115/scratchpad/logs/dto-swift-r2.log`, SHA-256 `24b5568b3311361a4c574cd99f487f9ca6a50273dd63588800e31cf6a2985ebc` |
| | the same, r1 | Failed to compile, in the new test only. The first draft appended section 9 at the end of the file, and that put it inside `RockchipLoweringRemovalContractTests`, the file's second class. There `swiftFiles` and `codeWithoutComments` are not in scope. r2 moves the section into `ArchitectureBoundaryContractTests`. Every product module compiled in r1, Core among them with the two moved files, and no warning named either moved file. Log `/private/tmp/claude-501/-Users-fuhanfeng-Dropbox-Code-Github-ArkDeck--claude-worktrees-blissful-goldstine-c7d922/26822f74-e8f8-4647-9226-2234ed41e115/scratchpad/logs/dto-swift-r1.log`, SHA-256 `e7a15c3461de32e12e4bd0341670710dae577c1efa90f66a69d6f9f568151667` |
| SDD | `sh scripts/check-sdd.sh` | exit 0: 0 errors, 0 warnings |

## CI

PR #2058 was merged at 15:38:42Z, before its CI finished: `swift-tests` was still running, and
the required `swift` aggregate had not reported. On head `5561eea1` (base `6592bcce`):

| Workflow run | Jobs | Conclusion |
| --- | --- | --- |
| Swift CI `35452126984` | `plan`, `app-build` and `ds-interactions` succeeded, and `rust-checks` was skipped. `swift-tests` failed at 15:41:42Z: `JobPlanAnalyzerOracleContractTests.testSwiftPlansTheSharedAnalyzerOracle` found `cases.json` 3 bytes short and `provenance.json`'s digest different. That made the required `swift` aggregate fail | failure |
| SDD Guard `35452126786` | the required `guard`, `ds-tokens` | success |
| Agent PR `35452126785` | `open-pr` | success |

Main carried that failure from the merge until the follow-up fix landed. The cause and the fix
are in `core-request-contract-message-fix-run.md`.

## Not run

- App build-for-testing. No App source names a moved type, and the PR's `app-build` job builds
  the App.
