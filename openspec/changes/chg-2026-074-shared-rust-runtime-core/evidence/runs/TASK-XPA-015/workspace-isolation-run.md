# Runtime-owned isolated copies on the Rust daemon (TASK-XPA-015, M3)

The Rust daemon now executes `workspace.prepare-isolated-copy@1`, the first of
the 13 `workspace.*` operations. For a registered workspace project it plans,
admits, runs and publishes a Runtime-owned copy of the project's tree exactly
as Swift does, and a restarted daemon adopts the copies an earlier one made,
as Swift's `adoptRuntimeWorkspaces` does. The #2094 oracle replays byte for
byte: the four frames, the copy's manifest and its tree.

Base: protected `main` `ae404cc5` (#2144); written on `52745924` (#2143) and
rebased without conflict, then re-checked (below).

| Already on `main` | This change | Still remaining (M3) |
|---|---|---|
| The workspace project and preset owner and the DevEco pins (#1989, #2056, #2073, #2076); the Swift oracle of this operation (#2094) | The Rust workspace provider over the registered projects: profiles, the isolation lifecycle, the plan, admission, run and result of `workspace.prepare-isolated-copy@1`, start-up adoption; the workspace-subject issuance rule; `workspaceKind: null` published for the five Job status surfaces | `apply-patch` / `revert-patch` (slice 11), their patch lineage in adoption, and the issuance of a copy's capability; the other ten operations; the project and operation availability projections; GJ-5 |

## Swift, as ported

**Composition** (`main.swift`). At start-up every registered project whose
root is still the directory its registration pinned resolves to the profile
of its kind: `arkdeck` is `WorkspaceProjectProfile.arkDeck` (`workspace-host@1`,
`Packages/ArkDeckKit/**`, `Catalog/**`, `docs/**`, grep, patch, git when the
root holds `.git`, the fixed SwiftPM tool and its role links, `Package.swift`
required); `openharmony` is `waterFlowDemo` (`waterflow-openharmony@1`, the four
`entry/src/*` scopes, grep, sed, patch, bsdtar, git inside a working copy, the
WaterFlow markers required, a root under Desktop/Documents/Downloads refused).
When a primary profile resolves, the isolation manager is created under the
state root's `evolution-workspaces/` and adopts; every registered generation
is then marked applied. When none resolves, the provider is unavailable with
Swift's joined reason.

**Plan** (`materializeTypedPlanBeforeAuthorization`). The provider must be
registered and able to serve the operation, the Artifact store present, the
descriptor host-only and the request unpinned. The provider's `action` routes
the request to the profile it names, re-measures its tools, refuses a stated
revision the tree no longer has (`workspace.revisionConflict:<12>!=<12>`),
requires a primary profile and an isolation manager, requires every requested
scope narrower than a profile scope, and measures the narrowed revision. The
typed intent derives every identity: `evo-` + 24 and `evolution-` + 20 hex
digits of `sha256(runtime-<Job>|<project>|<narrowed revision>)`. As in Swift the
plan is materialized for the authorization envelope's Job and carries the
engine clock, so the plan digest names that Job's copy. The step is a host
workspace action pinned by `workspace.prepare-isolated-copy/v1#action-sha256:`
and the intent's canonical digest; no process runs.

**Admission.** The operation is `hostOnly` under `defaultReadOnly`: the default
read-only policy admits it, with no capability issued, reserved or consumed.
Swift's `acquireWorkspaceProjectInput` is ported: while a Job is materialized
it holds its registration (a copy's Jobs hold their source's), a project
registered or changed since start-up is refused until a restart, and the
project and its presets can be neither updated nor removed meanwhile.

**Run** (`runOwned` → `dispatchWithWAL`). The intent is materialized again for
the Job itself; its typed action is persisted before the write-ahead intent,
and the copy is made only after the intent is durable. Verification is
Swift's: the receipt against the typed action, then an independent readback
from disk. The correlated outcome precedes the one product,
`isolated-workspace.json`, whose bytes are Swift's default envelope (the
product, its operation, Job and catalog, and the verified facts).

**The copy** (`EvolutionWorkspaceManager`). No tool runs. The source revision
the caller stated and the narrowed base revision are measured first; the tree
is copied into `.workspace.tmp` and published by one rename: at most 100,000
entries, 512 MiB per file, 4 GiB in all; `.build` left out at any depth; a
`.git` pointer file left out, a `.git` directory copied by value; hidden
entries copied; a link kept only when it resolves inside the tree, an absolute
one rewritten relative; a special file refused; each file read through
`O_NOFOLLOW` and written through `O_EXCL` with its mode and proven unchanged;
directories owner-only. The copy is then measured against the narrowed base
and the full source revision, its derived profile (no source control, presets
rebased) registered, and its manifest written. A refusal names a tree-relative
entry and never a host path.

**Adoption** (`adoptRuntimeWorkspaces`). Each Runtime-owned manifest must name
a primary source, and its tree must measure its base revision and its scopes
their digest; otherwise it is reported `<workspace>:metadata|revision|scopes|
profile` and stays unresolvable. The daemon prints `runtime workspace not
adopted for …` for each, as Swift does.

**Revision** (`workspaceRevision`, `files`). HEAD, the index file and every
scoped file, from files alone. Foundation is reproduced where it decides the
answer, each rule measured on this host with the Swift toolchain: the
enumerator skips exactly the entries whose `NSURLIsHiddenKey` is true and
descends no directory whose `NSURLIsPackageKey` is true (read through
CoreFoundation, `arkdeck_platform::host_entry_presentation`); symbolic links
resolve through `realpath(3)`, falling back to lexical standardization, and a
leading `/private` is dropped when the rest exists; paths sort by their NFC
scalars; `**` stops at an ICU line terminator.

## Capability admission

`workspace.prepare-isolated-copy@1` needs no capability, and none is created;
the oracle's authority is `defaultReadOnlyPolicy`. The rule a workspace
mutation will meet is fixed now, where admission will read it: a device
subject follows the catalog's `defaultPolicyIssuance`; a workspace subject may
be issued a Runtime capability only when it is a Runtime-owned isolated copy
(`WorkspaceAuthorizationFacts.isolatedTaskCopy`), and a person's primary tree
never is, whatever the catalog says. No workspace mutation is materialized yet,
and this Runtime issues no workspace capability: a primary tree is refused with
Swift's `effect deviceMutation requires an explicit runtime capability`, and a
copy with the existing "does not issue yet" refusal, both with zero dispatch.

## The contract correction

A workspace operation belongs to no App workspace, so every projection of its
Job carries `workspaceKind: null`. The published `job.run`, `job.result`,
`job.status`, `job.show` and `job.reconcile` schemas were derived from corpora
that never sampled one, so they refused Swift's own answers (the #2094 frames
fail them), and the Rust control plane turned every such answer into
`internalError`. `WorkspaceIsolationOracleContractTests` gains
`testTheIsolationJobReadsBackThroughTheStatusSurfaces`, which records the three
read surfaces Swift answers; one Swift frame per method was appended to the five
corpora (committed lines unchanged), and the five schemas were derived from
each committed corpus plus that frame. The only `$defs` change is
`workspaceKind` becoming `["null", "string"]`; a second derivation from the
final corpora changes nothing. `x-arkdeck-sampleCounts` now counts the corpus
the schema was derived from.

## Choices on the refusing side

- **A provider refusal at run time fails the Job.** When the source moved after
  admission, Swift's provider refuses before the intent, its run escapes and
  the Job stays `running` for a later run to retry. This Runtime resumes no
  host Job from `running`, so the refusal fails the Job instead, with zero
  dispatch; a new request is the way on.
- **Registered presets are not composed.** Build, test, symbol and signing
  presets a caller registered run through operations this Runtime does not
  materialize; their tools are not part of a profile's re-measured identities
  yet. The code-owned presets of each kind are.
- **Patch lineage is not read.** This Runtime patches nothing, so a copy whose
  tree moved from its base is not adopted, where Swift would ask its patch
  lineage; it stays unresolvable (`:revision`).
- **Order and links.** Entries are copied in byte order of their names, so when
  several would be refused the first in that order is named (Swift names the
  first its enumerator yields). A link is read once, so the target admitted is
  the one recreated.
- **The manifest** is written owner-only and read without following a link.
- `EvolutionWorkspacePolicy.allowedOperations` is validated as Swift's
  initializer validates it and, as in Swift, enforced nowhere.

## Not changed here

`workspace.project.list/show` still answer the projection of an unapplied
project, and `operation.list` still reports the workspace provider as
unregistered: both need the per-operation availability of all 13 workspace
operations, which follow with the operations. `job.reconcile` of a parked
isolation Job refuses without a write, and start-up recovery parks an
interrupted copy's outstanding intent; neither replays it.

## Tests

- `workspace_isolation_oracle` (hoststore, 7): the #2094 sequence replayed
  over the same tree, profile and clock — every answer equal to Swift's (the
  plan's additive review digest aside), the manifest byte for byte, the tree
  file for file; adoption by a restarted Runtime and its `metadata`,
  `revision` and `scopes` refusals; the copy's exclusions, modes and links, and
  a `.git` directory copied by value; an escaping link failing the Job by its
  tree-relative name with no host path; a source that moved after admission
  failing before any intent; Swift's plan-time refusals; the production
  composition over a registered project, its use token, a project registered
  after start refused until a restart, and adoption after the restart.
- `workspace_isolation_process` (agentd): the isolated daemon over its control
  socket — registration, restart, plan, submit, run, the five status surfaces,
  result, restart, adoption, and a moved copy reported at start and left
  unresolvable. In `check-contracts.py`'s published view, whose schemas predate
  the correction, it asserts the control plane's nonconforming-result refusal.
- Unit tests: glob, narrowing, anchor and Foundation-path rules; the profile
  registry; derived profiles; the workspace issuance rule; the intent's
  identities; the platform hidden/package table.

Mutations (`scratchpad/s20/mutate.py`), each caught by a failing test and
restored by checksum:

| Mutation | Caught by |
|---|---|
| `.build` caches copied | `the_copy_keeps_swifts_exclusions_modes_and_links` |
| a `.git` pointer file copied | `the_copy_keeps_swifts_exclusions_modes_and_links` |
| a link leaving the tree admitted | `a_refused_entry_fails_the_job_naming_only_the_entry` |
| hidden entries counted in the revision | `the_copy_keeps_swifts_exclusions_modes_and_links` |
| a primary tree reads as a Runtime-owned copy | `only_a_runtime_owned_copy_is_issued_a_workspace_capability` |
| every workspace subject auto-issued | `only_a_runtime_owned_copy_is_issued_a_workspace_capability` |
| the composition skips adoption | `a_registered_project_is_copied_and_its_copy_adopted_after_restart`, and the daemon's `workspace_isolation_process` |
| adoption registers nothing | `a_restarted_runtime_adopts_the_copies_a_previous_runtime_made`, `a_registered_project_…` |
| adoption skips the scopes digest | `a_restarted_runtime_adopts_the_copies_a_previous_runtime_made` |
| file modes not kept (the mode source) | `the_copy_keeps_swifts_exclusions_modes_and_links` |
| a copy maps to itself, not its source | the oracle replay, adoption and registration tests |
| a project registered after start-up acquired | `a_registered_project_is_copied_and_its_copy_adopted_after_restart` |

A first variant of the mode mutation changed only the creation mode and
survived: the `fchmod` after the copy re-applies the source's mode, as
Swift's does, so it was equivalent.

## Local targeted checks

With `CARGO_BUILD_JOBS=2` and this tree's own target; logs are
`/private/tmp/arkdeck-s20-*.log`.

| Check | Exit | Result |
|---|---|---|
| `cargo fmt --all --check` | 0 | |
| `cargo clippy -p arkdeck-platform -p arkdeck-hoststore -p arkdeck-agentd -p arkdeck-soak -p arkdeck-contract -p arkdeck-control -p arkdeck-client -p arkdeck-cli --all-targets -- -D warnings` | 0 | |
| `cargo test --no-fail-fast` over the same eight crates | 0 | 149 targets: 1,169 passed, 0 failed, 18 ignored (existing) |
| `cargo test -p arkdeck-hoststore --test workspace_isolation_oracle` | 0 | 7 passed |
| `cargo test -p arkdeck-agentd --test workspace_isolation_process` | 0 | 1 passed |
| The same two with `origin/main`'s contract inputs (the published view of `check-contracts.py`), then restored | 0 | 7 and 1 passed |
| 12 mutations (`mutate.py`) | — | 12 caught |
| `run-swiftpm.sh test --filter WorkspaceIsolationOracleContractTests` with `ARKDECK_CONTROL_FRAME_LOG` (the recording) | 0 | 2 tests, 0 failures |
| `run-swiftpm.sh test --filter 'ControlMethodSchemaContractTests\|ControlMethodReachabilityContractTests\|WorkspaceIsolationOracleContractTests'` | 0 | 9 tests, 0 failures, 1 skipped |
| `run-swiftpm.sh test --filter WorkspaceIsolationOracleContractTests --parallel --num-workers 2`, the class as CI's eight-worker suite runs it | 1, then 0 | before the fix below: the recording fails (`recordUnreadable`, `evolution-workspaces` gone); after it: 3 runs of 2 tests, 0 failures, both roots removed |
| `generate-control-contract.py --derive-method-schemas` on the five corpora, run twice | 0 | only `workspaceKind` widened; idempotent |
| `python rust/scripts/generate-contract.py --write`, then `--check` | 0 | 105 methods, 958 recorded shapes |
| `check-corpus-replay.py` (default fixture `observe-device`, the built daemon and CLI) | 0 | 28 exchanges, 64 checks |
| `sh scripts/check-sdd.sh` | 0 | 0 errors, 0 warnings |
| After the rebase onto `ae404cc5`: `cargo fmt --all --check`; `generate-contract.py --check`; `cargo clippy -p arkdeck-platform -p arkdeck-hoststore -p arkdeck-agentd -p arkdeck-soak -p arkdeck-cli --all-targets -- -D warnings`; `cargo test --no-fail-fast -p arkdeck-hoststore -p arkdeck-agentd` | 0 | 73 targets: 663 passed, 0 failed, 14 ignored (existing), including the oracle's 7 and the daemon's 1 |

Not run: `check-contracts.py` itself. Each of its two views is a cold build of
the whole workspace in its own target and this host had 23 GiB free; the
macos-26 Rust lane runs it. Its published view was simulated above for the two
tests that read the corrected schemas. No App, device, signing or installed
Runtime was touched.

## CI

PR #2145. Swift CI 35994583769 on `7958ec5c`: `plan`, `ds-interactions`, the Rust
host-independent checks and the Rust workspace on ubuntu-latest, windows-latest
and macos-26 passed, the last including the published consumer and candidate
contract parity (`check-contracts.py`, not run locally); SDD Guard 35994583348
passed. `swift-tests` failed in `WorkspaceIsolationOracleContractTests`: the
read-back test this change adds shared the recording's fixed root, and
SwiftPM's parallel runner ran the two at once in two processes, so one test's
set-up and tear-down removed the other's Runtime state (`Runtime SQLite batch
failed: disk I/O error`). Reproduced locally with two workers and fixed in the
test: each test names its own fixed root, which only that test empties and
removes; the recording's root and frames are unchanged. No other test failed.

On the fixed head `f238ffd5` everything passed: Swift CI 35997529148 (`plan`,
`ds-interactions`, `swift-tests`, the Rust host-independent checks and the Rust
workspace on ubuntu-latest, windows-latest and macos-26, the `swift` aggregate),
SDD Guard 35997528363 (`guard`) and Agent PR 35997528419. Merged as
`642cac83`.
