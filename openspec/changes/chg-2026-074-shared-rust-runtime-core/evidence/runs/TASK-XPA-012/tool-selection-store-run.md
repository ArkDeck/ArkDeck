# TASK-XPA-012 — the tool-selection control-action store on the Rust owner (macOS, 2026-09-19)

TASK-XPA-012 remains in progress. Base: protected main `3e95ac6d`; no stack. Written on the oracle slice's head `13f28a9c` and moved onto `3e95ac6d` once #2038 merged; only `rust/README.md` and the crate's `lib.rs` met other changes, merged without conflict. Nothing here is device
evidence (POL-VERIFY-001, POL-MODE-001). No production Swift source, control schema, corpus, Catalog,
entitlement, `openspec/specs` or constitution change; one new Swift contract test reads what Rust
writes.

This is the Rust port of `RuntimeToolSelectionControlActionStore` and its records, the durable half of
`runtime.tool.select`, against the Swift oracle the previous slice recorded
(`tool-selection-store-oracle-run.md`, #2038).

## Already on main / this slice / still remaining

| Already on main | This slice | Still remaining |
| --- | --- | --- |
| `runtime.tool.select` answered as Swift's daemon without a tool-selection owner, and the Rust CLI leaf (#2032); the Swift oracle of the store, 17 records over all eleven states (#2038); the HDC control-action owner, its store, records and impact values over the managed server (#2017) | `arkdeck_hoststore::ToolSelectionRecords` over `ToolSelectionRecord`: every record transition of Swift's owner, its validation and projection, and Swift's replacement rules; the impact approval, console challenge and receipt values (`control_action_approval.rs`); the store mechanics shared with #2017's HDC records (`control_action_store.rs`); the Rust-written records Swift reads back | The owner that observes the impact and asks the registry, its composition and `runtime.tool.select` over it (after the HDC restart, C2, and a maintainer ruling; `tool-select-route-run.md`); `tools.json`'s selection writes; the schema widening from the production owner's frames |

## What changes

- **`control_action_store.rs` (new).** The store both Swift owners keep, twins in Swift, now one Rust
  implementation generic over the record (`StoredAction`): the owner-private directory re-checked
  around a transaction under a non-blocking `.lock`, records named `action-<sha256(requestId)>.json`
  and checked against their identity, interrupted publications (Swift's `.tmp`, the shared
  publisher's `.part`) removed, the record, count and byte bounds, begin with request-identity
  idempotency, load by identity or request, the creation-then-identity listing, and replacement by
  the exact next generation on the owner's own conditions. #2017's `Store` keeps its signatures as a
  wrapper over it; its 13 tests pass unchanged.
- **`control_action_value.rs` (new).** #2017's `HDCControlValue` helpers moved out of
  `hdc_control_action.rs` unchanged, with `record_unreadable`, for both owners.
- **`control_action_approval.rs` (new).** `ImpactApproval` (Swift `HDCControlHumanAction`: minted,
  read, expired, resolved, its `continues` rule and its `arkdeck.human-action/1` projection),
  `InteractionChallenge` (issued at most 120 s before it expires; only the SHA-256 kept) and
  `InteractionReceipt` (only the challenge's own text mints it, else
  `impactApprovalChallengeMismatch`). #2017's HDC records refuse these; the HDC restart can use them.
- **`tool_selection.rs` (new).** `ToolSelectionIntent`, `ToolFacts`, `SelectionImpact` (over #2017's
  `Impact`), the preview (`arkdeck.tool-selection-preview/1`, its digest and canonical impact) and
  `ToolSelectionRecord` (`arkdeck.runtime-tool-selection-control-action/1`, 20 members, the bindings
  between state, dispatch count and nested records), with Swift's transitions — `publishing`,
  `requesting_impact_approval`, `issuing_interactive_challenge`, `recording_interactive_approval`,
  `prepared`, `appending_lifecycle_audit`, `failed_before_launch`, `settled`, `invalidated` — each
  taking its instant and the identities Swift draws, and the `arkdeck.control-action/1` projection.
  `ToolSelectionRecords` is the store over it. Refusals keep Swift's codes and messages.
- **`rust/README.md`**: one paragraph in the HDC control-action section.

Nothing composes the store yet, and no request reaches it: `runtime.tool.select` still answers
the owner's absence (#2032).

## Tests

`tool_selection_tests.rs` (8 tests):

| Test | What it holds |
| --- | --- |
| `every_swift_record_is_read_as_its_own_canonical_bytes` | All 17 Swift records, eleven states, parse and re-encode to the exact file bytes — the production lifecycle record's audit rows and the synthetic payloads that stress canonical JSON (UTF-16 key order, escapes, `1e+21`) included |
| `the_store_lists_swifts_directory_with_swifts_projections` | A private copy of Swift's directory lists in Swift's order with Swift's projections; loads by identity and request |
| `every_swift_timeline_plays_again_byte_for_byte` | 16 timelines replayed through the Rust store with the instants and identities their final records hold leave Swift's bytes in the store's own files (the lifecycle record's rows come from the Supervisor and are not replayed) |
| `a_member_more_or_less_is_refused_at_every_level` | An extra or a missing member of the record, its intent, preview, both tools, a signature, a trust, the approval, challenge and receipt is `recordUnreadable`; each nested type refuses on its own; a re-signed preview with an unsorted impact is "stored tool-selection impact is not canonical" |
| `the_bindings_between_state_and_nested_records_are_swifts` | State against receipt, approval and dispatch count; another action's approval; malformed members |
| `the_store_replaces_only_what_swift_replaces` | Request-identity idempotency, exact next generation, `failed` only after dispatch was prepared, audit growth by one row, an approval never waiting again, the clock, a second lock holder |
| `transitions_refuse_as_swift_does` | `admissionDenied`, `humanActionExpired`, `impactApprovalChallengeMismatch`, `impactApprovalChallengeExpired`, one launch window, unknown audit kinds and results, the projection's next action |
| `rust_written_records_are_the_checked_in_ones` | Five timelines with Rust's own identities and instants write `rust/tests/fixtures/tool-selection-store-rust` byte for byte (recorded with `ARKDECK_TOOL_SELECTION_RUST_RECORD`) |

`ToolSelectionStoreRustReadbackContractTests` (Swift, new): the production
`RuntimeToolSelectionControlActionStore` lists the Rust-written directory, finds every record its own
canonical bytes and Rust's projections, then answers the Rust-issued challenge and prepares the
Rust-recorded approval, replacing both as their next generations; a stale Rust generation is refused.

## Local targeted checks

Run 2026-09-19 in this worktree's own `rust/target`, `CARGO_BUILD_JOBS=2`; each exit code was read
directly.

| Check | Command | Result |
| --- | --- | --- |
| Format | `cargo fmt --all --check` | exit 0 |
| Lint | `cargo clippy -p arkdeck-hoststore -p arkdeck-agentd -p arkdeck-control --all-targets -- -D warnings` | exit 0 |
| The whole hoststore suite, before the move onto main | `cargo test -p arkdeck-hoststore` | exit 0; 393 passed, 0 failed, 12 ignored |
| The hoststore library, after the move | `cargo test -p arkdeck-hoststore --lib` | 217 passed, 0 failed, 5 ignored (the 8 tool-selection tests and #2017's 13 control-action tests among them) |
| The daemon's control-action routes over the refactored store | `cargo test -p arkdeck-agentd control_action` | 5 passed |
| The Rust-written directory, recorded | `ARKDECK_TOOL_SELECTION_RUST_RECORD=/private/tmp/<new> cargo test -p arkdeck-hoststore --lib tool_selection::tests::rust_written_records_are_the_checked_in_ones`, copied unchanged into `rust/tests/fixtures/tool-selection-store-rust` | 5 records, the empty lock and `projections.json`; no path, user or host name |
| Swift reads Rust back, beside the oracle and the neighbouring control-action tests | `sh Packages/ArkDeckKit/Scripts/run-swiftpm.sh test --filter 'ToolSelectionStoreRustReadbackContractTests\|ToolSelectionStoreOracleContractTests\|RuntimeToolSelectionControlActionContractTests\|HDCControlActionContractTests\|ControlActionWithHostContractTests'` | exit 0; 29 tests, 0 failures, 1 skipped (`testFacadePreservesForegroundConsoleChallengeAndRedirectedHAR`, which needs external executables) |
| SDD | `sh scripts/check-sdd.sh` | `check_sdd: 0 error(s), 0 warning(s)` |

The unified local gate was not run: the PR's CI is the gate (`AGENTS.md`, #2015).

## CI of #2038

The oracle slice merged (squash `dc989225`, head `13f28a9c`) before its record could carry its CI.
Every check passed on head `13f28a9c`:

| Check | Run | Result |
| --- | --- | --- |
| `guard`, `ds-tokens` | 35446960317 | pass |
| `open-pr` | 35446960344 | pass |
| `plan`, `ds-interactions`; `rust-checks`: host-independent checks, Rust workspace on `ubuntu-latest`, `macos-26` and `windows-latest`; `swift-tests` and the `swift` aggregate | 35446960526 | pass |
| `app-build` | 35446960526 | skipped by the plan |

## CI

Recorded once this PR's CI finishes.
