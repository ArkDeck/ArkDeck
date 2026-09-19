# TASK-XPA-012 — the tool registry's HDC selection ledger on the Rust owner (macOS, 2026-09-19)

TASK-XPA-012 remains in progress. Base: protected main `17b428d2` (#2055, the oracle); no stack.
Nothing here is device evidence (POL-VERIFY-001, POL-MODE-001). No production Swift source, control
schema, corpus, Catalog, entitlement, `openspec/specs` or constitution change, and no Swift test.

This is the Rust port of the selection operations `BootstrapToolRegistry` performs on `tools.json`,
against the Swift oracle the previous slice recorded (`tool-selection-registry-oracle-run.md`).

## Already on main / this slice / still remaining

| Already on main | This slice | Still remaining |
| --- | --- | --- |
| `runtime.tool.select` answered as Swift's daemon without a tool-selection owner, and the Rust CLI leaf (#2032); the control-action store and its records (#2038, #2046); the Rust tool registry's strict reader with the ledger's invariants, its rows, registration and retirement; the Swift oracle of the ledger (#2055) | The nine ledger operations on `arkdeck_hoststore::ToolRegistryStore`, with the published HDC identities a store matches made injectable as Swift's `knownIdentity` | The owner that observes the impact, asks the registry and drives the restart, its composition and `runtime.tool.select` over it (after C2 and ruling A, `tool-select-route-run.md`); the schema widening from that owner's frames |

## What changes

- **`tool_selection_ledger.rs` (new).** `initialize_service_selection`, `adopt_installed_hdc`,
  `selection_candidate`, `prepare_selection`, `startup_selection`, `publish_pending_selection`,
  `fail_pending_selection`, `selection_outcome` and `acknowledge_selection_outcome`, each Swift's
  operation line for line inside one transaction of Swift's `withSharedStore`: the store's directory
  re-checked around the bootstrap owner's `.lock` taken without waiting; `bundles.json` and
  `tools.json` read strictly, either created empty only when nothing it would describe is in the
  store; the tools an operation names measured against their retained content
  (`ToolRegistryStore::verify_record`) exactly where Swift measures them; the index published only
  where Swift publishes it, as the canonical bytes of the same document; Swift's codes and messages.
  The answers are Swift's values: `SelectionSnapshot` (`arkdeck.runtime-tool-selection/1`),
  `SelectionCandidate`, `StartupSelection` (the retained executable, its SHA-256 and dependencies,
  which a caller verifies before it runs anything) and `DurableSelectionOutcome`.
- **`registry.rs`.** `decode_tools` is now its two halves: `read_tools`, the strict reader with every
  record and ledger check it had, and `tool_projection`, one record's `arkdeck.runtime-tool/1` row for a
  given identity. The index types are crate-visible for the ledger's transitions; nothing about what
  is read or refused changed.
- **`tool_registry_owner.rs`.** `ToolRegistryStore` carries the published identities its rows and
  admissions match (`PublishedIdentities`; the daemon's two by default, `with_published_identities`
  for others), as Swift's registry takes `knownIdentity`. `list`, `inspect`, registration and
  retirement build their rows through it, so a store answers one identity everywhere; with the
  default nothing they answer changes.
- **`rust/README.md`**: one paragraph beside the tool-selection store's.

Where the port does more than Swift, each where Swift's own transitions never go:

1. It refuses to publish an index its own reader would refuse (`recordUnreadable`, the reader's
   message). Swift writes whatever its transition made; no transition in the oracle makes such an
   index.
2. Before publishing it checks again that the lock, the directory and both indexes are the ones it read,
   as retirement does. Under the lock no Swift or Rust owner writes them.
3. Refusals carry the bootstrap owner's `phase` and `newDispatchCount: 0`, as the Rust registration and
   retirement do; the oracle holds codes and messages.

Nothing composes the ledger yet, and no request reaches it.

## Tests

`tool_selection_ledger_tests.rs` (4 tests):

| Test | What it holds |
| --- | --- |
| `every_swift_timeline_plays_again_byte_for_byte` | The oracle's seven timelines, each on a fresh store with the oracle's executables and identities: after every step `tools.json` is the index Swift left, byte for byte (or absent where Swift's was), it was published exactly where Swift published it (a new file renamed into place), and the answer or refusal is Swift's — through Rust's own registration, retirement and listing as well as the ledger. The pins Swift took with `acquire` and `release` (no Rust caller takes them) and the harness's unpinned ledger are stood in for by Swift's index; the lost index, altered content and a lock held by another owner are made as Swift's harness made them |
| `every_swift_index_is_its_own_canonical_bytes` | All 22 recorded indexes decode and re-encode to their exact bytes; the reader accepts all but the harness's unpinned ledger |
| `members_are_swifts_and_no_other` | Two indexes carrying every member Swift's `Codable` types declare (a pending selection and a failed outcome, a verified trust, a dependency, quarantine digests) re-encode to their bytes; a member more anywhere is refused, and a member less is refused unless Swift encodes it only when present |
| `publication_stops_at_the_last_generation` | A pending selection at generation `u64::MAX` is not published (`the exact pending tool selection does not exist`, as Swift's `activeGeneration < UInt64.max`), and the index is untouched |

Swift reads back what Rust writes: every index Rust leaves in the replay is byte for byte the index
Swift's registry wrote at that step and read again at its next one, so no Rust-only document exists
for Swift to read.

## Local targeted checks

Run 2026-09-19 in a worktree of its own (its own `rust/target`), `CARGO_BUILD_JOBS=4`.

| Check | Command | Result |
| --- | --- | --- |
| Format | `cargo fmt --all --check` | exit 0 |
| Lint, macOS | `cargo clippy -p arkdeck-hoststore -p arkdeck-agentd --all-targets -- -D warnings` | exit 0 |
| Lint, the other hosts (`registry.rs` builds everywhere) | `cargo clippy -p arkdeck-hoststore --all-targets --target x86_64-unknown-linux-gnu -- -D warnings`, and `--target x86_64-pc-windows-msvc` | exit 0, exit 0 |
| The ledger against the oracle | `cargo test -p arkdeck-hoststore --lib tool_selection_ledger` | 4 passed |
| Negative probe | one recorded index changed by one byte (`…Failed` to `…Failes` in the reason of `864ec7e4…`), the replay run again, the fixture restored (`git status` clean) | FAILED, at exactly `adopted-then-failed step 9 ("failPendingSelection")`, the step that wrote it |
| The whole hoststore suite, on the final base | `cargo test -p arkdeck-hoststore` | exit 0; 414 passed, 0 failed, 13 ignored (registration, retirement, listing and #2046's control-action tests among them) |

The unified local gate was not run: the PR's CI is the gate (`AGENTS.md`, #2015).

## CI of the oracle slice

Every check of #2055 passed on its head `da40fed8`; its `swift-tests` lane ran
`ToolSelectionRegistryOracleContractTests` in compare mode on the CI image (job 105918445398,
2026-09-19 15:22 UTC), so a second host wrote every checked-in file byte for byte as well:

| Check | Run | Result |
| --- | --- | --- |
| `open-pr` | 35451154700 | pass |
| `guard`, `ds-tokens` | 35451154778 | pass |
| `plan`, `ds-interactions`; `rust-checks`: host-independent checks, Rust workspace on `ubuntu-latest`, `macos-26` and `windows-latest`; `swift-tests` and the `swift` aggregate | 35451154970 | pass |
| `app-build` | 35451154970 | skipped by the plan |

## CI

#2060 merged (squash `674c2ed7`, head `b1f07753`) before this record could carry its CI. Every check
passed on head `b1f07753`:

| Check | Run | Result |
| --- | --- | --- |
| `open-pr` | 35452354498 | pass |
| `guard`, `ds-tokens` | 35452354575 | pass |
| `plan`; `rust-checks`: host-independent checks, Rust workspace on `ubuntu-latest`, `macos-26` and `windows-latest`; the `swift` aggregate | 35452354740 | pass |
| `swift-tests`, `app-build`, `ds-interactions` | 35452354740 | skipped by the plan (no Swift, App or design-system input changed) |
