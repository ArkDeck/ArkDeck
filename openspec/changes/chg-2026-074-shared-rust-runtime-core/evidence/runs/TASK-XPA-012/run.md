# TASK-XPA-012 host-store shadow implementation — 2026-09-10

Status: in progress. No owner switch or TASK-XPA-012 acceptance is claimed.
Base: `eae27c6b97c2d9e5d67c8eee2d9353f2c0d38b93` (protected main).
Branch: `agent/xpa-012-hoststore-shadow-20260910`.
Readiness pins: the base above and RuntimeSessionStorageStore blob `5d4f994d33f8054c9cb6988aeaa94b0be7ce16ab`;
the same real pins are in the Task section.

## Delivered locally so far

- An offline `arkdeck-hoststore` Rust crate consumes bounded snapshot bytes over
  stdin and returns frozen document bytes plus read projections. It has no
  transport, device, capability or filesystem writer and is not linked into
  the facade. Only existing third-party dependencies are used.
- Real Swift History, display-name and bootstrap bundle/tool owners create and
  read isolated test stores. The harness compares their outputs with the Rust
  decoder, replaces only the test copy with Rust-produced bytes, and reads it
  back through the actual Swift owner. Tool fixtures are inspected, never run;
  bundle trust injection applies only to non-executable test bytes.
- History and display-name readers now reject extra/duplicate JSON keys rather
  than silently dropping them. No CodingKey, schema, writer byte format, lock
  name or permission changes. History's existing whitespace/order tolerance
  remains. Both readers retain the original bytes on refusal.
- The Python runner requires the complete declared case set and successful
  Swift execution before exclusively publishing a digest-only receipt. It pins
  relevant source and binary hashes and records actual timestamps/Actions
  provenance hints. It cannot backdate a run or count a local run as a nightly.
  Receipts explicitly say `cutoverEligible: false` and enumerate remaining work.

## Actual checks and limits

| Check | Exit | Result |
| --- | --- | --- |
| `cargo test -p arkdeck-hoststore` in `rust/` | 0 | Two Rust decoder tests, including duplicate/extra/null fields and UInt64 bounds |
| Initial Swift/Rust History differential | 1 | Positive byte/projection cases passed; two extra-field assertions exposed the Swift reader gap |
| `run-swiftpm.sh test -j 4 --filter 'HostStoreShadowContractTests|RuntimeHistoryFilterStoreContractTests'` with Rust binary | 0 | Six tests passed after strict-reader fix |
| `python3 rust/scripts/hoststore-shadow.py --output /private/tmp/xpa012-shadow-20260910-registries.json` | 0 | 19 cases: History + bundle/tool metadata/projections |
| Same runner, `--output /private/tmp/xpa012-shadow-20260910-names.json` | 0 | 24 cases, five XCTest methods; adds target/candidate names and tombstones |
| `python3 -m unittest discover -s rust/scripts -p test_hoststore_shadow.py` | 0 | Receipt completeness, store identity and outcome checks |

Local logs: `/private/tmp/xpa012-history-shadow.log`,
`/private/tmp/xpa012-history-shadow-fixed.log`,
`/private/tmp/xpa012-shadow-registries.log`, `/private/tmp/xpa012-shadow-names.log`.
These are development host checks, not hardware or seven-day shadow evidence.
The final unified gate is recorded when the complete implementation is ready.

## Coverage still required before the harness PR

- Session storage/policy and Trace cache snapshots/projections.
- Full semantic refusal parity (including timestamps, Unicode, sorted indexes,
  identity validation), selected/published tool identity cases, and additional
  nested/optional-key vectors. Current Rust decoders are not production admission.
- Lock contention/CAS and filesystem boundary tests; the offline byte adapter
  does not yet prove a future Rust store owner's lock or write discipline.
- Complete input/source pinning, scheduled job integration and seven actual
  nightly days. Local day count is zero. The complete implementation's unified
  gate, preflight and PR remain outstanding.

## Scope and review

The actual path checker refused `.github/workflows/swift-slow-lanes.yml` under
012 while accepting the Rust crate/scripts and Swift tests. Scope-only PR
[#1839](https://github.com/ArkDeck/ArkDeck/pull/1839) adds that one nightly path.
It passed selected local checks and hosted checks and is open for maintainer
review. No workflow is modified on this branch before that scope lands.
The scoped two-PR harness/cutover delivery follows the current handoff request;
no separate status/readiness PR is created.

## Cutover and hardware ledger

XPA-AC-1 is partial; XPA-AC-7 and XPA-AC-9 have not run for the owner change.
Cutover preflight blocking/parked sets, snapshot receipt, rollback/App smoke,
and GJ-1 re-pass are NOT_STARTED: this branch does not change ownership or
install a daemon. No Runtime state, credentials, device binding or hardware
evidence has been modified. There are no new device Job IDs. No higher task or
Windows work has started. The current installed helper pair is not assumed;
its typed service status must be read immediately before any authorized cutover.
