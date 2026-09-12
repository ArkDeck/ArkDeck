# Job event metadata reader — macOS, 2026-09-12

TASK-XPA-014 remains in progress. The branch uses protected main `f92acd36`, which merged
Job/Artifact reads in #1863 after its `522085ed` head passed all required CI. This
event slice still requires its own final validation and maintainer review.

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
and `/private/tmp/xpa014-events-rebase-process.log`. The final unified gate remains
pending before submitting this slice. Journal/SQLite writers, complete stored Job
authority validators, watch/wait CLI behavior, execution coordination and installed
owner cutover remain separate necessary migration work.
