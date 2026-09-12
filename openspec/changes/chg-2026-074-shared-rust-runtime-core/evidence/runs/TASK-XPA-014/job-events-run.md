# Job event metadata reader — macOS, 2026-09-12

TASK-XPA-014 remains in progress. The branch uses protected main `84d7107f`, including the ArkForge pin update #1868
and the stable Rust toolchain change #1867.
Job/Artifact reads merged in #1863 at `f92acd36` after its `522085ed` head passed
all required CI. This event slice still requires maintainer review.

## Behavior

The actual isolated Rust daemon routes `job.events` through its SQLite Job owner.
The journal reader takes the current manifest lock, validates descriptor/root/
lock/inode identity, and reads bounded complete JSONL records. It validates all
nineteen current Journal event kinds and emits their closed metadata projection.
Journal records, stored Job records and capability/recovery decisions are never
modified. Unknown fields, corrupt complete records, mismatched sequence/Job
identity, changed cursor predecessors and replaced or truncated journals refuse.
An incomplete final append remains invisible until its complete line arrives.

The existing AES-256-GCM `jec1` cursor is compatible with Swift, including AAD,
nonce/key sizes and the Job/inode/generation/origin/predecessor/high-water bindings.
A cursor key is privately and durably created only for a new stream page; a
missing key cannot be recreated to resume an existing cursor. Metadata cursors
confer no operation, admission or recovery authority. The Rust CLI validates
closed metadata and ordering before emitting a bounded page.

## Completed checks

The initial implementation passed four owner paging/corruption tests, two CLI
argv/native-page tests, all nineteen source-created Journal kind fixtures and
workspace Clippy. After rebase, warnings-denied workspace Clippy and locked deny/
vet passed again on Rust 1.98.1. The six additional publisher-trust windows are
exactly the separately authorized versions, checksums and UTC publication days;
`job-events-dependency-review.md` records the decision and source facts. Publisher
trust is not a source-code audit.

Actual Swift creates `/private/tmp/xpa-job-events-fixture-r1` with private Job
SQLite, Journal and cursor key files. The actual Rust daemon/CLI matches all three
native pages, resumes a Swift cursor, rejects cursor forgeries and resumes a Rust
cursor after restart without changing SQLite, Journal or key bytes. The current
Swift owner in turn reads the actual Rust cursor. This fixture must stay on the
same inode: copying a journal invalidates its cursor identity. Initial process and
native readback logs are `/private/tmp/xpa014-job-events-process-r1.log` and
`/private/tmp/xpa014-event-cursor-swift-readback-r1.log`.

`job-events-producer-frames-macos-20260912/` retains unchanged native method frames
and source hashes. The separate nineteen-kind native output is byte-identical to
`rust/tests/fixtures/journal/all-event-kinds.jsonl`. These are source-created host
fixtures and do not establish hardware acceptance.

## Remaining validation and migration

On rebased Rust 1.98.1 binaries, the four owner tests, two CLI tests and actual
process checker passed again. Logs: `/private/tmp/xpa014-events-rebase-targeted.log`
and `/private/tmp/xpa014-events-rebase-process.log`. The unified gate passed on the `f92acd36` checkout: common checks, 83 design-system tests, 2,632 Swift parallel
tests plus one identity and five serial viewer checks, Rust workspace and both
contract views, actual process checks, locked deny and vet. The App build lane was
not selected by this diff. Log: `/private/tmp/xpa014-events-main-unified-gate-r2.log`.

Journal/SQLite writers, complete stored Job authority validators, watch/wait CLI
behavior, execution coordination and installed owner cutover remain separate
necessary migration work.

## Full-gate fixture timing

The first full Swift lane hit an unchanged FakeHDC semantic matrix: its normal
`unknown` reply timed out under the two-second budget and therefore correctly
received a failure classification instead of the expected completed unknown
output. The same build/test passed alone in 0.832 seconds. Completed-exit samples
now have a ten-second scheduling allowance; the actual hang case retains its
200 ms timeout and every semantic, exit-code and output assertion is unchanged.
This changes test fixture budgets only. Logs:
`/private/tmp/xpa014-events-main-unified-gate-r1.log` and
`/private/tmp/xpa014-events-fault-matrix-isolated.log`.

After the additional #1868 rebase, the checkout contract manifest is unchanged.
The final latest-main gate also passed all selected lanes, with 2,632 Swift tests
plus identity and serial viewer checks, both Rust contract views, real process
checks, deny and vet. Log: `/private/tmp/xpa014-events-main-unified-gate-r3.log`.

The subsequent #1867 rebase changes no compiled Package/Rust crate source, Cargo
lock, dependency policy or contract byte relative to the fully tested `86013547`
head (`git diff --exit-code` checked those complete paths). The selected stable
compiler is still `rustc 1.98.1 (48a229cea 2026-09-01)`. The checkout generator and
final Task014 preflight passed after rebase; required CI runs on the new head.
