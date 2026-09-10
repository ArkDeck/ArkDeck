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


## Continued implementation after scope merge

PR #1839 merged by the maintainer at `7b43ea0fabb697e5d0550df5d2a6b8264410362f`.
The local foundation checkpoint was rebased onto that main; it is not an
implementation PR. The original 16-file development diff completed the unified
local gate with exit 0 (`/private/tmp/xpa012-shadow-development-gate.log`): Swift
suite, App build-for-testing, design-system checks, published/candidate Rust
contract lanes, cargo deny and cargo vet (25 audited dependencies) passed.
Subsequent implementation below requires its own final gate before submission.

- Session configuration now compares actual policy/root/generation output and
  exact document bytes, including Int64.max quota and extra-key rejection.
  The 29-case wrapper run exited 0, `/private/tmp/xpa012-shadow-session.log`.
  Full Session inventory/retention is still outstanding; configuration equality
  does not claim full status parity. Swift status can mutate its retention
  catalog, so it runs only in prepared isolated fixture roots.
- A macOS descriptor-relative reader opens bounded files/directories and existing
  locks without creating or writing them. Symlink/hardlink/permission refusal,
  read/enumeration bounds, missing-lock non-creation and cross-process exclusion
  pass in `cargo test -p arkdeck-platform --test host_store` (4 tests including
  the child probe); clippy passed for hoststore/platform with all targets.
- Rust Trace inventory reads the same isolated cache as the real ArkTrace
  maintenance adapter. Empty, unaccounted, Ready/inactive, key contention,
  lease contention, entry symlink and enumeration overflow comparisons pass.
  The resulting complete wrapper run has 36 cases and eight XCTest methods,
  exit 0; `/private/tmp/xpa012-shadow-trace-fixed2.log` and
  `/private/tmp/xpa012-shadow-20260910-trace-fixed2.json`.
- Earlier Trace fixture runs failed before inventory because Foundation only
  canonicalizes `/private/tmp` to `/tmp` after the directory exists. A standalone
  temporary-directory probe reproduced it. The fixture now standardizes after
  creation and passes its POSIX physical root to Rust; no product path guard was
  relaxed. The failed runs published no receipt.

The Trace snapshot reader is not a purge implementation. Its acceptance still
needs full Foundation timestamp spellings and metadata/permission failure
parity. The pinned ArkTrace reader currently tolerates unknown metadata keys;
this fact is not silently converted into strict-decoder acceptance. Session
full status and the other semantic/owner gates above remain open. No daemon
was installed, no production state was read or changed, and nightly day count
remains zero.

### Semantic refusal coverage and nightly wiring (2026-09-10)

The real Swift/Rust differential now passes 49 named cases across nine XCTest
methods, including 13 additional refusals: unsupported History enums, bounded
search/identity fields, control characters, unordered/duplicate display-name
indexes, and incomplete or mismatched staged target references. Every new
refusal checks original document bytes remain unchanged. Receipt:
`/private/tmp/xpa012-shadow-20260910-semantics.json`; log:
`/private/tmp/xpa012-shadow-semantics.log`. After this run, a Clippy style finding
was fixed without changing the condition; hoststore/platform all-target Clippy
passes with warnings denied. Receipt completeness tests pass (3 tests).

The scope supplement was merged in PR #1839. The authorized workflow now has
an independent macOS shadow job using pinned toolchains and the repository's
SwiftPM runner, with digest receipts and diagnostics archived for 90 days.
Existing jobs, triggers and permissions are unchanged. This wiring is local
and unpushed; no scheduled run or qualifying nightly day is claimed. Receipts
still explicitly report incomplete coverage and `cutoverEligible: false`.
The source manifest now also pins the workflow, SwiftPM runner and receipt tests.
A fresh complete-diff unified gate remains required after implementation work.

The expanded complete-diff unified local gate subsequently passed (exit 0),
including full Swift tests, App build-for-testing, design-system checks,
published/candidate Rust contract checks, cargo deny and cargo vet (25 audited).
Log: `/private/tmp/xpa012-shadow-expanded-gate.log`.
A new differential run after the Clippy and source-manifest edits passed all
49 cases, with current source fingerprints in
`/private/tmp/xpa012-shadow-20260910-expanded-final.json` (log beside it as
`/private/tmp/xpa012-shadow-expanded-final.log`). These are local results;
no nightly-day, owner-cutover, rollback or hardware acceptance claim is made.

### Identity and Unicode parity (2026-09-10)

The candidate now validates target identifiers, candidate/observation byte
bounds, the Swift owner's newline-delimited composite-key collisions, display
name bounds and boundary whitespace. macOS text predicates use the immutable
CoreFoundation Cc/Cf and whitespace/newline sets, matching the Foundation owner
without invoking any Swift process. Canonical-equivalence keys preserve Swift
String duplicate detection and staged-name equality; persisted bytes retain
the original spelling. Embedded NUL in bounded candidate identity is preserved,
not silently truncated by a C-string conversion. The SDK's CFCharacterSet.h and
CFString.h define the ABI and constants used by this read-only platform adapter.

Actual differential runs passed 55 identity cases, then 62 Unicode cases and
65 cases with canonical duplicates, staged equivalent spellings and embedded
NUL. The latest receipt is
`/private/tmp/xpa012-shadow-20260910-canonical.json`, with log
`/private/tmp/xpa012-shadow-canonical.log`. All-target hoststore/platform Clippy
passes with warnings denied; the three Rust hoststore unit tests and three
receipt completeness tests also pass. These checks do not close the remaining
Session inventory/retention, timestamp, registry semantics or cutover gates.

The complete-diff unified gate after the Unicode adapter passed (exit 0):
full Swift tests, App build-for-testing, design-system checks, Rust published
and candidate checks, cargo deny, and cargo vet (25 audited). Log:
`/private/tmp/xpa012-shadow-unicode-gate.log`. No installed Runtime was changed.

### Session date and directory prerequisites (2026-09-10)

Added the frozen Session timestamp grammar and Gregorian conversion, separate
from the History/Trace formatter domains. Twenty real Swift/Rust vectors compare
exact Double bit patterns or matching refusal: leap seconds, numeric offsets up
to ±23:59, lowercase separators, fractional digits beyond nanosecond precision,
reference epoch, historic Gregorian dates and year bounds. Conversion uses the
macOS CoreFoundation Gregorian calendar in UTC, preserving the current owner's
calendar behavior. The first test build failed because an internal Swift helper
required `@testable import ArkDeckStorage`; the test import was corrected without
changing production visibility or the frozen Storage module.

The read-only filesystem adapter now has an explicit Session tree entry point:
owner identity and no group/world write, with same-volume checks inherited by
child directories and files. The private-cache entry point remains private.
Five platform tests pass, including separate-process lock exclusion and the new
read-permission/link refusal checks. All-target hoststore/platform Clippy passes.

All 85 differential cases pass in
`/private/tmp/xpa012-shadow-20260910-session-provenance.json` (log:
`/private/tmp/xpa012-shadow-session-provenance.log`). Every case now pins its actual
Swift XCTest executable; mixed oracle binaries are refused. The receipt records
macOS, architecture, Swift, Rust and Xcode versions. Four receipt integrity tests
pass. The new date vectors are prerequisites, not full Session status coverage:
manifest validation, tree/catalog reconciliation and complete status comparison
remain unfinished. The unified gate must be rerun after that implementation.
