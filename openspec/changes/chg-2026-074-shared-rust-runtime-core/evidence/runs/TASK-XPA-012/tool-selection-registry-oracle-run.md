# TASK-XPA-012 — the Swift oracle of the tool registry's HDC selection ledger (macOS, 2026-09-19)

TASK-XPA-012 remains in progress. Base: protected main `6592bcce`; no stack. Recorded on `f56481d8`
and compared on `e5daa945`; #2037, #2046–#2049, #2051, #2053 and #2054 changed nothing the test reads
(no `ArkDeckBootstrap` source). This is a Swift-only
contract slice before the Rust port of the selection writes to `tools.json` (the next slice): one new
contract test and the oracle it records. No production Swift source, control schema, corpus, Catalog,
entitlement, `openspec/specs` or constitution change. Nothing here is device evidence
(POL-VERIFY-001, POL-MODE-001).

## Already on main / this slice / still remaining

| Already on main | This slice | Still remaining |
| --- | --- | --- |
| `runtime.tool.select` answered as Swift's daemon without a tool-selection owner, and the Rust CLI leaf (#2032); the control-action store's Swift oracle (#2038) and its Rust port (#2046); the Rust tool registry's strict reader with the ledger's invariants, registration and retirement | `ToolSelectionRegistryOracleContractTests`: the production `BootstrapToolRegistry`'s `tools.json` after every step of seven timelines over the selection ledger, each step's answer or refusal and whether it published the index, checked in at `rust/tests/fixtures/tool-selection-registry` | The Rust port of the ledger's operations over this oracle (next slice); the owner that composes them and `runtime.tool.select` over it (after C2 and ruling A, `tool-select-route-run.md`) |

## What the oracle holds

`BootstrapToolRegistry` keeps the HDC selection beside its records in `tools.json`
(`arkdeck.bootstrap-tools/2`): the active tool and its generation, at most one selection in flight
(its action, old and new tool, the generation it expects) and the last outcome until it is
acknowledged, with an `activeSelection` pin on the active tool and a `controlAction` pin on both tools
of the one in flight. The daemon drives it through `adoptInstalledHDC` and `startupSelection` at start,
`publishPendingSelection` or `failPendingSelection` once the selected server is verified or not, and
the tool-selection owner through `selectionCandidate`, `prepareSelection`, `selectionOutcome` and
`acknowledgeSelectionOutcome`; `runtime service install` calls `initializeServiceSelection`.

The test plays seven timelines, each on a fresh store, through those nine operations and `register`,
`acquire`, `release`, `remove` and `list`:

| Timeline | Steps | What it reaches |
| --- | --- | --- |
| `fresh-store` | 12 | A store that does not exist yet: the first operation creates `bundles.json` and the empty `tools.json`, nothing else publishes; the refusals of a missing ledger, an unregistered and a malformed reference, a malformed failure reason (refused before the lock), and the lock held by another owner |
| `initialized-then-published` | 32 | The install path and a selection that succeeds: `initializeServiceSelection` and its idempotent retry (not published) and refusals; the candidate and its refusals; `prepareSelection` and its idempotent retry; the pending startup tool; both tools pinned against removal; publication at generation 2; the unacknowledged outcome refusing every new selection and `initializeServiceSelection`; acknowledgement (only its own action publishes); the initial selection idempotent again at generation 2; the old tool removable |
| `adopted-then-failed` | 18 | The daemon's migration: `adoptInstalledHDC` idempotent, and a different file registered without changing the selection; a second action and another tool refused while one is pending; failure (pins released, outcome kept), its outcome, retries refused, the candidate removable, acknowledgement; a removed tool refused |
| `refusals-by-tool` | 27 | A tool without a published identity, one not relocatable, one removed; an `activeSelection` pin without a ledger ("an active tool pin exists without its selection ledger"); releasing a pin not held; an action identity that is no owner identifier, refused after every other check; the tool that is not relocatable selected, started and published |
| `lost-index` | 5 | `tools.json` removed beside retained content: every operation refuses |
| `unpinned-ledger` | 6 | A ledger whose active tool lost its pin: the reader refuses every operation, acknowledgement included |
| `altered-content` | 11 | Retained content changed in place: an operation refuses exactly when it measures that tool (`startupSelection` only the tool it starts, `selectionOutcome` the active tool, acknowledgement none) |

Files:

- `oracle.json`: the producer, the store, the registration clock, the published identity the test's
  lookup answers, and the five executables (bytes in base64, SHA-256, published or not, and the
  `toolRef` the registry gives each).
- `timelines.json`: every step's operation and arguments (tools by `toolRef`), its answer or refusal
  (code and message), whether another owner held the lock, the SHA-256 of the `tools.json` it left
  (null when none exists), and whether it published the index (a new file renamed into place: inode or
  birth time changed). Answers are the operations' own values: `SelectionSnapshot.value`
  (`arkdeck.runtime-tool-selection/1`), the startup selection's tool, generation, pending action,
  executable (relative to the store), SHA-256 and dependencies, the candidate beside its selection, the
  durable outcome, and the `arkdeck.runtime-tool/1` rows of `register`, `acquire`, `remove` and `list`.
- `indexes/<sha256>.json`: the 22 distinct `tools.json` the timelines left, as the registry wrote them.

## The same bytes on every host

The registered tools are synthetic Mach-O executables the test builds byte for byte: a 64-bit arm64
`MH_EXECUTE` header and one load command, `LC_UUID` with its own bytes for four of them and, for the
fifth, `LC_LOAD_DYLIB` of `/opt/fixture/libfixture.dylib` (a library outside the system, so not
relocatable). There is no program and nothing runs them. macOS's Security framework reports them
unsigned (`errSecCSUnsigned`, −67062, checked with `codesign` and `SecStaticCodeCheckValidity`
before the test was written), so the production trust inspection records `{"signature":"unsigned"}`
with no seam. The content digest covers only each entry's path, kind, executable bit, quarantine
digest, byte count and SHA-256 (`BootstrapBundleFiles.scan`), none of which depends on the host or the
time, and the registration clock is injected (2026-09-01T00:00:00Z). A second run therefore writes
every file again byte for byte: without the recording variable the test plays every timeline and
requires the checked-in files, and no other, to be exactly its own. No provenance pin or masking is
needed, unlike the control-action store's oracle (#2038), whose records carry random identities.

The daemon's identity lookup (`HeadlessHDCBootstrapIdentity`) knows only two real HDC executables, so
the test's lookup answers `fixture-1` (`fixture-profile`) for four of the synthetic executables and
nothing for the fifth, as `BootstrapToolRegistryContractTests.selectionRegistry()` answers for its
fixture. The Rust port has to take the lookup the same way.

## Swift behaviour the oracle pins

The port follows each of these; the first is a question for the maintainers.

1. **A tool that is not relocatable can become the active HDC.** `initializeServiceSelection` and
   `resolveHDC` refuse one, but `prepareSelection`, `startupSelection` and `publishPendingSelection`
   do not check (`refusals-by-tool` steps 21–25): through `runtime.tool.select`, the daemon's next
   start would compose its server from an executable whose library lives outside the retained copy.
2. `release` of a pin the tool does not hold still publishes the index (step 12 there);
   `acknowledgeSelectionOutcome` for another action publishes nothing.
3. A removed candidate is refused as "candidate has no published HDC executable identity", the
   unpublished candidate's message (`refusals-by-tool` step 15).
4. `adoptInstalledHDC` of another file while a selection exists registers it (and publishes) and
   answers the existing selection unchanged (`adopted-then-failed` step 2).
5. `selectionOutcome` measures the active tool before it answers, so once the active tool's content
   changed every outcome is refused, even an absent one (`altered-content` step 9).
6. The wording is the registry's: lock contention is "another bootstrap operation holds the store;
   retry after it completes", and the read refusals are "tool index failed bounded schema and identity
   validation", "tool index is missing beside retained tool state" and "registered host tool failed
   content, identity or trust validation". Rust's registration and retirement, already on main, word
   some of these differently; this slice changes neither.

## Recording

Recorded 2026-09-19 22:55 CST on base `f56481d8` with
`ARKDECK_RUST_TOOL_SELECTION_REGISTRY_RECORD=/private/tmp/tool-selection-registry-oracle-rec1
sh Packages/ArkDeckKit/Scripts/run-swiftpm.sh test --filter ToolSelectionRegistryOracleContractTests`
(1 test, 0 failures, 1.46 s), then copied unchanged (`diff -r` clean) into
`rust/tests/fixtures/tool-selection-registry`: 24 files. No path, user or host name of the recording
machine appears in them (`grep` for home, `/private/tmp` and host names: none).

## Local targeted checks

Run 2026-09-19 on this worktree through the shared SwiftPM runner (one build lock across
worktrees); each exit code was read directly.

| Check | Command | Result |
| --- | --- | --- |
| The oracle, compare mode, on base `e5daa945` | `sh Packages/ArkDeckKit/Scripts/run-swiftpm.sh test --filter ToolSelectionRegistryOracleContractTests` | exit 0; 1 test, 0 failures (2.15 s): every one of the 24 checked-in files, and no other, written again byte for byte |
| SDD | `sh scripts/check-sdd.sh` | `check_sdd: 0 error(s), 0 warning(s)` |

No Rust source changed, so no Rust check ran; the unified local gate was not run (the PR's CI is the
gate, `AGENTS.md`, #2015).

## CI of #2046

The control-action store's Rust port merged (squash `830fcc1c`, head `d9b541e1`) before its record
could carry its CI. Every check passed on head `d9b541e1`:

| Check | Run | Result |
| --- | --- | --- |
| `open-pr` | 35448800838 | pass |
| `guard`, `ds-tokens` | 35448800848 | pass |
| `plan`, `ds-interactions`; `rust-checks`: host-independent checks, Rust workspace on `ubuntu-latest`, `macos-26` and `windows-latest`; `swift-tests` and the `swift` aggregate | 35448800953 | pass |
| `app-build` | 35448800953 | skipped by the plan |

## CI

Recorded once this PR's CI finishes.
