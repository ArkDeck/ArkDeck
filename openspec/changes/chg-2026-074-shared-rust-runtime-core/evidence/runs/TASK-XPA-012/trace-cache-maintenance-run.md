# Guarded Rust Trace cache maintenance

2026-09-13. TASK-XPA-012 remains in progress. This slice is based on protected
main `6bb0d0eb` and enables the existing `trace.cache.purge` method and the
`trace cache purge` CLI leaf for the isolated Rust host state only. It does not
detach the installed Swift owner, activate anything installed, or introduce a
durable format. Every fixture below is synthetic host data; nothing here is
parser or device acceptance.

## Provenance of the recovered work

The implementation was checkpointed on 2026-09-12 in the local worktree
`/private/tmp/arkdeck-xpa012-trace-maintenance-20260912` and excluded from the
Session cleanup PR (#1880) because the paired native ArkTrace purge did not
remove the entry that Rust removed. The three checkpoints `24823de7`, `bf189cff`
and `e36c872b` were cherry-picked onto current main; the two-mode native
producer, its fixture script and the harness directory helper were taken from
the final checkpoint `7ac34ec7`. Conflicts were confined to the CLI help text and
refusal mapping (Session cleanup apply and Trace purge now share the
`outcomeUnknown` unconfirmed-reply branch), the platform module exports, the
Artifact read owner's struct fields, and the Artifact owner test file, where the
export tests from #1874 and the Trace retention tests now sit side by side.
The second leftover worktree, `/private/tmp/arkdeck-xpa-native-validation-20260912`,
holds no undelivered content: its tracked changes are byte-identical to or
behind main, and its untracked fixtures already exist on main.

## Behaviour

The Rust owner reuses the pinned ArkTrace maintenance semantics: existing key
lock, exclusive entry lease and exact owner lock; owner evidence bound by
device, inode and relative path; quarantine of the proven inode under its
anchored parent; publication of the existing owner evidence for that location;
removal; and stale private session/build recovery with orphan marker cleanup.
Creating or unbound evidence grants no removal authority, `building` evidence
promoted into the canonical namespace requires the full Ready transaction, and
original Trace Artifacts are never selected. Faults preserve uncertain owner
evidence and never adopt a replacement at the former pathname.

The Host holds the Job activity census and the Artifact retention census across
the whole purge. Any retained Job directory, unknown Artifact namespace or
retained file preserves every entry and residual, and unsafe or unreadable
members refuse maintenance before any deletion. One change from the checkpoint:
the Rust Import owner delivered in #1881 creates its empty `.imports-v1`
skeleton (`records`, `identities`, `payloads`, `.owner.lock`) at every startup,
so a literal "non-empty Artifact root" census would have retained everything
forever in the real daemon. `ArtifactReadStore::with_trace_retention` now treats
that idle skeleton as inactive and retains on any upload record, identity,
payload or unrecognised member inside it; every other namespace keeps the
conservative rule.

The CLI validates the closed receipt (nine fields, two four-field inventories,
`originalTraceArtifactRemovalCount` fixed at zero, removed plus skipped bounded
by the entries before) and maps EOF, malformed framing, wrong schema and
semantically invalid receipts to `outcomeUnknown`, exit 75, without reconnecting
or replaying.

## Root cause of the 2026-09-12 native mismatch

Reproduced first on pinned ArkTrace `e6e3133d` with the native producer:
`pinned-e6e3133d/swift-expected-purge.json` shows `removedEntryCount 0`,
`skippedActiveEntryCount 1`, `recoveredPrivateDirectoryCount 1`, and
`native-owner-diagnostics.json` shows the owner target
`…/traces/<trace>/<parser>` without the trailing slash of the canonical entry
URL. In ArkTrace's `TraceCache.swift`, `ownerTarget` rebuilt the owner directory
URL with `append(path:)`, which never marks an existing directory, while
`maintenanceEntries` and `CacheLayout` build directory-hinted URLs; `evict` then
required `owned.url.standardizedFileURL == entry.url.standardizedFileURL` and
skipped every Ready entry. A Foundation probe on this host confirmed that no
form of `standardizedFileURL` or `resolvingSymlinksInPath()` reconciles the two
forms, and an instrumented run of the new ArkTrace regression test failed under
the temporary directory, a home cache root and `/private/tmp` alike, so the
installed Swift daemon's `trace.cache.purge` also reclaims nothing today. The
`ParserIntegrationTests` cases that would have caught this need the pinned
parser bytes and are skipped in ArkTrace CI.

The fix is ArkTrace PR #25, commit `ef541c7c53be4b8ca747fd634cf67bbec067eae6`
on `agent/trace-cache-purge-directory-hint-20260913` (source patch SHA-256
`0aae6fbe02a186f4a363e1316bb4b194157d22dc8ecc2f3cd450540d253fe9ac`): append each
owner-target component with `directoryHint: .isDirectory`, plus the parser-free
integration test `TraceCacheMaintenanceReadyEntryTests`. On that tree the
workflow-equivalent suite passed (583 tests, 79 runtime skips confined to the
parser-dependent targets, 0 failures) and `scripts/test_api_baseline.sh` passed.
The Rust owner already matched the fixed semantics; no Rust selection rule
changed for parity.

## Checks

- Rust unit and integration tests: 6 `trace_maintenance` owner tests, 4
  `trace_removal` platform tests, 2 Artifact `trace_retention` tests (idle
  Import skeleton, each retained member, unknown member, refusals before
  action), 2 CLI receipt tests and the CLI socket test (EOF, malformed, wrong
  schema, semantic refusal: one request, exit 75, no reconnect); the complete
  `arkdeck-hoststore`, `arkdeck-platform` and `arkdeck-cli` test targets pass.
- `cargo fmt --all --check` and `cargo clippy --workspace --all-targets -- -D
  warnings` pass for the native target and for `x86_64-pc-windows-msvc` and
  `x86_64-unknown-linux-gnu`.
- `python rust/scripts/generate-contract.py --check`: no drift (105 methods,
  601 recorded shapes); this slice changes no contract input.
- Synthetic process harness `rust/scripts/check-trace-cache-owner.py` against
  the debug daemon and CLI: PASS, 23 control exchanges plus CLI calls, covering
  empty and ready inventory, key/lease contention, restart, invalid
  parameters, Session root overlap, unsafe links, unindexed and retained Job
  directories, the idle Import skeleton, retained Import records and payloads,
  an unknown Artifact namespace, a corrupt Job index, the actual purge, the
  empty second purge and a replaced root. Log: `rust-harness-synthetic.log`.
- Native parity, pinned `e6e3133d`: the producer linked against the SwiftPM
  checkout objects of `Packages/ArkDeckKit/.build` seeded
  `/private/tmp/xpa012-trace-native-20260913-r1`; the native report retained the
  Ready entry (`pinned-e6e3133d/`, with the pinned source provenance).
- Native parity, fixed `ef541c7c`: the same producer source (SHA-256
  `8ff8d90071c8ab63623ae0adc5ffc294e86c6273c5fb6565e82dcb85adc4cd05`) linked
  against the ArkTrace SwiftPM runner build of the fix worktree (package
  identity `workspace`) seeded `/private/tmp/xpa012-trace-native-fixed-20260913-r5`;
  the native purge removed one derived entry and one private residual, and
  `check-trace-cache-owner.py --native-fixture` ran the Rust daemon and CLI on
  the paired `rust/` tree: PASS, 21 control exchanges, and
  `fixed-ef541c7/rust-purge.json` equals `fixed-ef541c7/swift-expected-purge.json`
  field for field. The pre-purge inventory is 1 entry, 1,267 bytes, in both.
- Unified local gate: see the final section.

## Remaining TASK-XPA-012 work

- Bump the ArkDeck ArkTrace pin to the reviewed merge of ArkTrace PR #25 in a
  separate dependency PR (the #1791 file set), then re-run
  `produce-trace-maintenance-fixture.py` and `--native-fixture` against the
  pinned SwiftPM checkout so the parity record carries pinned provenance. Until
  then the installed Swift daemon's purge keeps reporting every Ready entry as
  skipped.
- Trace database preparation, remaining tool selection writes, installed
  host-store composition (the façade serving these stores while the Swift
  daemon stops opening them), the isolated-root to installed switch under the
  §G.4 preflight, and the GJ-1 headless re-pass.

## Unified local gate

The first run of `python3 scripts/ci/plan.py --repo-root . --base-revision origin/main --head-revision HEAD --merge-base --include-worktree --run-local`
on the squashed candidate exited 1: `check-contracts.py`'s candidate view failed in `check-readonly.py`, because a
daemon with no configured Trace owner answered `trace.cache.purge` with `outcomeUnknown` where the read-only
contract expects the same `rejected` refusal `trace.cache.status` gives. The Host now returns `rejected` for the
unconfigured owner and keeps `outcomeUnknown` for census or maintenance failures; no schema changed (`rejected`
is already in the published purge vocabulary). Log of the failed run:
`/private/tmp/xpa012-trace-unified-gate-20260913-r1.log`.

The re-run on the corrected commit exited 0. The planner selected the Rust lane only (no Swift, App or
design-system paths changed): common checks, `cargo fmt --check`, warnings-denied Clippy, the workspace tests,
`generate-contract.py --check`, `test_contract_checks.py`, `check-contracts.py` with the published view covered by
the candidate view (identical inputs) and every process harness including `check-trace-cache-owner.py`,
`cargo deny` and `cargo vet`. Log: `/private/tmp/xpa012-trace-unified-gate-20260913-r2.log`, SHA-256
`eb000439ba7fb03f878d157c2378d5cb84502fa35d0183c850740012c42e3ef2`. Only this record changed after that run.
