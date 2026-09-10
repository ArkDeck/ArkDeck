# TASK-XPA-012 — host-store shadow work

Status: **in progress**. The Rust candidate is not installed or connected to the
façade. No Swift store owner has been disabled. No qualifying nightly day,
cutover, rollback, GJ-1 or hardware acceptance is claimed.

## Scope and baseline

The workflow scope supplement was reviewed and merged through
[PR #1839](https://github.com/ArkDeck/ArkDeck/pull/1839) at
`7b43ea0fabb697e5d0550df5d2a6b8264410362f`; see [scope.md](scope.md).
The Task readiness pins retain the protected-main implementation baseline
`eae27c6b97c2d9e5d67c8eee2d9353f2c0d38b93`. Each run additionally hashes its actual
source files and candidate binary. The pinned ArkTrace dependency revision is
`c85731b0f903261bd69cf789027774fde615c8de` in Package.resolved.

The implementation remains local on `agent/xpa-012-hoststore-shadow-20260910`.
There is no implementation PR yet: the remaining harness coverage below must be
completed before presenting it for review.

## Implemented comparisons

`rust/scripts/hoststore-shadow.py` runs the actual Swift store readers against
Rust using fresh test-owned directories. Document candidates receive bounded
snapshot bytes through stdin. Trace and Session inventory candidates read one
explicit physical fixture root through descriptor-relative, no-follow access.
All filesystem comparisons check snapshots before and after Rust reads. The
Swift oracle may initialize or reconcile only its isolated fixtures.

| Surface | Cases | Current comparison |
| --- | ---: | --- |
| History filter | 19 | Durable bytes, list projection, generations, strict fields, enum/text refusal |
| Display names | 24 | Target/candidate projections, tombstones, ordering, identity and staged-name consistency |
| Bundle registry | 31 | Available/retained/removed metadata, closed fields, reference/state/owner/bounds/time refusal |
| Tool registry | 74 | Closed metadata, trust/dependency shape, legacy schema, active/pending/outcome selection ledger |
| Published tool identity | 7 | Actual Swift diagnostic lookup of both existing published digests and unknown spellings |
| Session configuration | 5 | Policy/custom-root/full-width values and strict canonical fields |
| Session timestamps | 20 | Exact Swift Date Double bits or matching refusal |
| Session canonical JSON | 52 | UTF-8 keys, canonical duplicates, integer/float spelling, depth and manifest byte bounds |
| Session status | 37 | Actual used/pinned bytes, counts, catalog generations, unsafe layout and incomplete measurement |
| Session parameters | 28 | Typed state, restore byte equality, status consistency and Swift character-count boundaries |
| Session Steps | 224 | All 56 kinds, valid typed arguments, closed fields, required arguments and digests |
| Session compensation | 84 | All six permitted kinds, declarations, execution records, source relationships and outcomes |
| Session confirmations | 16 | Typed actors, decisions, scopes and Step backreferences |
| Session Step semantics | 32 | Risk declarations, binding references, terminal states, standardAgent and plan-only conditions |
| Session arguments | 38 | Scalar and path bounds, optional fields, remote action and workspace argument semantics |
| Session recovery | 44 | Typed hazards, guides, device mode, abandon records and compensation relationships |
| Runtime audit records | 37 | Closed historical audit fields, Provider/Step labels and mutation consumption requirements |
| Grapheme corpus batches | 3 | Unicode 16/17 official inputs and 54,660 generated Indic property combinations |
| Trace cache | 7 | Actual Swift adapter inventory, missing metadata, key/lease contention and unsafe entries |

The 105-case receipt is preserved unchanged in
[local-shadow-20260910.json](local-shadow-20260910.json). It identifies itself as
an isolated host differential with `sourceDirty: true` and `cutoverEligible:
false`; its per-file hashes describe the tested local snapshot. It contains no
raw filter strings, display names, payload bytes or hardware claims. Each case
pins the actual Swift XCTest executable; the runner rejects missing cases,
unexpected outcomes, invalid hashes or mixed oracle binaries. macOS,
architecture, Swift, Rust and Xcode versions are recorded.

The expanded 131-case snapshot is preserved separately in
[local-shadow-parameters-20260910.json](local-shadow-parameters-20260910.json),
also with `sourceDirty: true` and `cutoverEligible: false`. The earlier receipt
remains an immutable record of its own tested source snapshot.

History and display-name Swift readers gained duplicate/extra-field checks to
meet the frozen field-set requirement. Their writers and durable keys were not
changed. macOS Unicode handling uses the same immutable CoreFoundation control
and whitespace sets as Foundation. Canonical-equivalence keys match Swift String
equality while preserving original durable spellings and embedded NUL in bounded
candidate identifiers.

The Session scanner measures the actual tree, validates identity and supported
manifest branches, joins the retention catalog, and predicts initialization,
policy reconciliation and removal without writing. Cases cover registered and
unregistered Sessions, pinning, duplicate identity, unscoped content, corrupt or
missing metadata, identity mismatch, and symlinks. Selected comparisons run Rust
before Swift reconciliation and compare the resulting full status afterward.
The Session filesystem entry point preserves owner/no-group-or-world-write and
same-volume rules; the private Trace entry point keeps its stricter permissions.

Session date conversion preserves the frozen grammar, leap seconds, offsets up
to ±23:59, arbitrary fractional precision with the current nanosecond truncation,
and Gregorian calendar behavior. Manifest artifact checks include typed derived
provenance, canonical Base64, path/size/hash constraints, source-hash matching,
unique lineage and cycle detection. These only interpret fixture records; they
confer no Runtime authority or tool trust.

Parameter validation covers missing/unreadable/value states, the desired-value
requirement, restore dispositions, and exact UTF-8 equality for a restored value.
Length comparisons exercise 4096/4097 Swift Characters with family emoji, CRLF,
combining marks, flags, Hangul, Indic conjuncts and skin-tone modifiers. The
candidate now uses exactly pinned `unicode-segmentation` 1.13.3 with narrowly
scoped Swift Indic-linker compatibility rules. The earlier CoreFoundation
composed-range counter was removed after it disagreed with Swift segmentation.
The actual Swift Character iterator is compared on all 1,859 official Unicode
16/17 GraphemeBreakTest inputs and 54,660 generated consonant/linker sequences.
The official fixtures and Unicode license are retained unchanged; the generated
property table is checked against the pinned DerivedCoreProperties input on
every shadow run. The dependency's public Mozilla cargo-vet audit is imported;
this does not constitute maintainer approval of the implementation or cutover.

All 56 Step types now receive typed structural, argument and digest validation.
Compensation records and confirmations are checked against declared source Steps.
Recovery parsing covers the complete closed record and interrupted-state
requirements. Historical Runtime Provider audits are interpreted solely as
stored data; the candidate cannot mint, reserve or consume authority. HDC keeps
its existing closed field set, including the allowed cross-branch metadata keys.

Registry semantic validation now covers both state/generation pairs, bounded and
unique owners, reference identity, sorted unique records, legacy date parsing,
version/trust/dependency constraints, and the full active/pending/outcome tool
selection ledger. Two separately registered fixture executables exercise pending
pins and successful/failed outcomes without executing either fixture. Published
identity lookup mirrors the existing Swift diagnostic composition; it adds no
Provider support declaration or admission authority. Content/signature
revalidation remains part of the subsequent filesystem owner implementation;
these registry comparisons cover metadata decoders and their projections.

The Session reader now validates the full current canonical JSON domain with a
separate encoder/parser: UTF-8 key ordering, Swift canonical-equivalent duplicate
keys, exact 64-bit integers, Foundation floating-point spelling and the current
256-level strict-parser bound. It does not use the CLI JCS encoder or serde's
smaller wire nesting bound. Noncanonical numeric/string spellings are refused;
no durable document is normalized or rewritten. The implementation is exercised
against the actual Swift encoder on finite values from 2048 deterministic
binary64 bit patterns, explicit numeric boundaries, and full manifest/derived
provenance records. A 16 MiB manifest and one-byte overflow verify the real store
reader's size boundary and resulting inventory projection.

Session inventory now revalidates the configured physical root and its directory
identity before returning, plus the held lock inode and initialization marker.
Deterministic platform tests replace the directory or lock and change permissions
while descriptors remain open; the final binding checks refuse those states.
Configuration is an immutable stdin snapshot, not a live configuration-file read.
The later owner stage must coordinate live configuration publications under its
store lock; this harness does not claim that contract yet.

Seventeen additional actual Swift comparisons cover missing, oversized,
extra-field and noncanonical identity files, hardlinks, FIFOs, writable year/month/
session/file entries, and invalid or regular-file layout components. Rust leaves
every fixture unchanged and matches Swift's incomplete measurement projection.

## Remaining work before harness review

- Finish the Session scan budget refusal checks.
- Complete History/display-name timestamp refusal and remaining Trace metadata
  compatibility.
- Finalize the complete nightly corpus. The nightly job is wired locally but has not been pushed or run.
- Run the final unified gate and committed preflight on the complete harness.

After harness review/merge, seven actual scheduled nightly days must be matched
to Actions provenance before owner cutover. Local runs, manual dispatch and
retries cannot manufacture those days. Owner/CAS/crash-window work, UI assertions,
GJ-1 re-pass and rollback evidence remain a later authorized cutover stage.

## Validation so far

- 782 cases across 25 XCTest methods passed. Immutable receipt:
  [local-shadow-filesystem-20260910.json](local-shadow-filesystem-20260910.json).
  Log: `/private/tmp/xpa012-shadow-filesystem-initialized.log`.
  Seven platform filesystem/lock tests, seven receipt integrity tests and
  hoststore/platform all-target Clippy also passed.
- The 782-case implementation passed the complete-diff unified gate (exit 0):
  Swift full suite, App test build, design-system, published/candidate Rust
  contracts, cargo deny and cargo vet (26 audited). Log:
  `/private/tmp/xpa012-shadow-filesystem-gate.log`.

- 765 cases across 24 XCTest methods passed, including the new Session JSON
  domain and manifest limits. Immutable receipt:
  [local-shadow-session-json-20260910.json](local-shadow-session-json-20260910.json).
  Log: `/private/tmp/xpa012-shadow-session-json-bounded.log`.
- The 765-case implementation passed the complete-diff unified gate (exit 0):
  Swift full suite, App test build, design-system, published/candidate Rust
  contracts, cargo deny and cargo vet (26 audited). Log:
  `/private/tmp/xpa012-shadow-session-json-gate.log`.

- The 713-case implementation passed the complete-diff unified gate (exit 0):
  Swift full suite (2567 parallel tests plus six serialized timing/race tests),
  App test build, design-system, published/candidate Rust contracts, cargo deny,
  and cargo vet (26 audited). Log: `/private/tmp/xpa012-shadow-registry-gate.log`.

- 713 cases across 22 XCTest methods passed, including expanded registry and
  published-identity coverage. The immutable receipt is
  [local-shadow-registry-20260910.json](local-shadow-registry-20260910.json).
  It includes actual dependency source hashes and remains `cutoverEligible: false`.
  Log: `/private/tmp/xpa012-shadow-registry-provenance-build.log`.

- The 611-case implementation passed the complete-diff unified gate (exit 0):
  Swift full suite (2565 parallel tests plus six serialized timing/race tests),
  App test build, design-system, published/candidate Rust contracts, cargo deny,
  and cargo vet (26 audited). Log:
  `/private/tmp/xpa012-shadow-typed-manifests-gate.log`.

- 611 cases across 20 XCTest methods passed, including 32 new Step semantic
  boundaries. Initial fixture setup omitted catalog initialization; adding it
  restored the expected complete measurement for valid cases. The immutable snapshot is
  [local-shadow-typed-manifests-20260910.json](local-shadow-typed-manifests-20260910.json).
  It retains `sourceDirty: true` and `cutoverEligible: false`.
  Log: `/private/tmp/xpa012-shadow-semantics-catalog.log`.
- The runner now verifies the actual SwiftPM ArkTrace checkout before and after
  the comparisons. It requires the resolved revision and actual HEAD to match,
  rejects dirty/untracked/ignored inputs, compares every tracked file with the
  fixed Git tree, and records SHA-256 for all 370 checkout files. The two upstream
  license files explicitly marked CRLF are verified with pinned-tree attributes
  and their original checkout bytes are retained in the hash manifest.
- Seven receipt/provenance integrity tests pass, including modified bytes hidden
  behind a clean Git status, resolution mismatch and restricted CRLF conversion.

- 579 cases across 19 XCTest methods passed after the Runtime audit field fix.
  Log: `/private/tmp/xpa012-shadow-runtime-audit-fixed.log`. Its source is superseded by the 611-case snapshot above.

- 131 cases across 12 XCTest methods passed after the parameter/Unicode fixes.
  Log: `/private/tmp/xpa012-shadow-parameter-unicode-fixed.log`.
- The parameter snapshot passed the full unified gate (exit 0): Swift full
  suite, App test build, design-system, published/candidate Rust contracts,
  cargo deny and cargo vet (25 audited). Log:
  `/private/tmp/xpa012-shadow-parameters-gate.log`.
- 105 cases across 11 XCTest methods passed. Latest execution log:
  `/private/tmp/xpa012-shadow-session-artifacts.log`.
- Four receipt integrity tests, five filesystem/lock tests and hoststore/platform
  all-target Clippy passed. One Clippy style finding was fixed using `as_chunks`.
- Earlier full unified gates passed through the 65-case implementation, including
  Swift, App build-for-testing, design-system and published/candidate Rust lanes,
  cargo deny and cargo vet (25 audited).
- The expanded Session implementation also passed the complete-diff unified
  gate (exit 0), including all selected lanes and cargo vet (25 audited). Log:
  `/private/tmp/xpa012-shadow-session-gate.log`.

Initial differential failures exposed extra-field acceptance in Swift and were
fixed in the readers. Trace fixture initialization initially failed because
Foundation normalizes `/private/tmp` after directory creation; fixture path
handling was corrected without relaxing production guards. The Session timestamp
test initially needed `@testable import ArkDeckStorage`; no production visibility
or frozen Storage source was changed. No device operation was run.
