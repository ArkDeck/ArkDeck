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
| Bundle registry | 5 | Available/retained/removed metadata and extra-field refusal |
| Tool registry | 5 | Unregistered-tool metadata and extra-field refusal |
| Session configuration | 5 | Policy/custom-root/full-width values and strict canonical fields |
| Session timestamps | 20 | Exact Swift Date Double bits or matching refusal |
| Session status | 20 | Actual used/pinned bytes, counts, catalog generations and incomplete measurement |
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

## Remaining work before harness review

- Complete complex Foundation canonical JSON coverage. Unsupported encoding branches still stop the entire
  comparison explicitly; they are never reported as corrupt or unaccounted
  Sessions.
- Finish the Session scan failure matrix and root/configuration stability checks.
- Complete History/display-name timestamp refusal, registry semantic validation,
  published tool identity/selection and remaining Trace metadata compatibility.
- Automate dependency checkout provenance verification and finalize the complete
  nightly corpus. The nightly job is wired locally but has not been pushed or run.
- Run the final unified gate and committed preflight on the complete harness.

After harness review/merge, seven actual scheduled nightly days must be matched
to Actions provenance before owner cutover. Local runs, manual dispatch and
retries cannot manufacture those days. Owner/CAS/crash-window work, UI assertions,
GJ-1 re-pass and rollback evidence remain a later authorized cutover stage.

## Validation so far

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
- The actual SwiftPM ArkTrace checkout was read-only checked at the pinned
  revision and had no tracked or untracked changes. Automated receipt checks
  for that external source remain to be added.

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
