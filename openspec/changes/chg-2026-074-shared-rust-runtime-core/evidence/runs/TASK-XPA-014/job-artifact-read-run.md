# Job SQLite discovery and Artifact read routing — macOS, 2026-09-12

TASK-XPA-014 is in progress. Rebased base: protected main `a3b384d3` (initial
validation used `6be27ace`). This phase adds the
Rust Job read owner and connects Artifact inspect/read to that owner through the
actual daemon and CLI. It does not implement Runtime admission or execution and
does not establish installed cutover or hardware acceptance.

## Product behavior

`job.list`, `job.status`, `job.show`, and `job.timeline` read the existing v1
`runtime_job` SQLite layout through a bounded platform wrapper. Existing databases
are opened read-only without checkpoint/recovery or a version change. The owner
validates schema, row identity, Foundation timestamp order keys and closed stored
records. New databases are initialized only in an empty owner directory; a lost
initialized index, orphan state or unsupported layout is preserved and refused.
A second owner is refused, and every query checks the directory, lock and database
inode. List/timeline cursors preserve immutable snapshots across restart.

Artifact inspect/read resolves the Job via the same SQLite owner before opening
its published bytes. An orphan Artifact directory is insufficient. Closed
metadata, complete digest/length verification, sensitive-byte authorization and
bounded range output remain in the Artifact owner. The Rust CLI validates the
metadata and returned range before emitting JSON or `--raw` bytes.

Session cleanup preview holds a stable census of all readable Jobs and retains
nonterminal Jobs plus terminal unknown outcomes. An incomplete census cannot
reach cleanup. Future Job writers must use that same activity guard.

The stored-record decoder deliberately refuses optional capability, recovery,
evidence and Session-publication fields whose validators have not been ported;
it never silently drops them or treats them as absent. Such records return
`recordUnreadable`. Their full support remains in the authority migration.

## Validation

- Five Rust Job owner tests pass: current SQLite reads, restart/frozen pages,
  exact query binding, malformed/unknown record fields, schema drift, preserved
  missing index/orphan state, symlink and multi-statement refusal, and activity
  census retention/refusal.
- Current Swift `JobReadResourcesContractTests/testRustJobOwnerCurrentSQLiteFixture`
  creates two Jobs in its production SQLite repository and records five replies.
  The actual Rust daemon returns equal values, and four actual CLI commands pass.
  Restart preserves SQLite bytes; a second owner refuses. Log:
  `/private/tmp/xpa014-job-oracle-swift.log`.
- Current Swift `ArtifactResourcesContractTests/testRustArtifactOwnerCurrentFixture`
  publishes a source-created plaintext Artifact and its Job. The actual Rust
  daemon matches both inspect/read replies; three CLI processes including raw
  output pass, as do restart and second-owner refusal. Log:
  `/private/tmp/xpa014-artifact-oracle-swift.log`.
- Two native Swift Artifact refusal tests pass for missing Job, missing Artifact,
  mutated content and the retired job-only request. Only closed inspect frames
  enter the inspect corpus. These add the actual `resourceNotFound` and
  `artifactIntegrityFailed` schema errors. Log:
  `/private/tmp/xpa013-artifact-inspect-swift.log`.
- Five affected Rust crates pass warnings-denied Clippy. Unified gate and final
  preflight results are recorded after integration below.

All committed producer frames are copied unchanged into
`job-artifact-producer-frames-macos-20260912/`. The reusable process checker is
`rust/scripts/check-job-read-owner.py`; it accepts only an explicit generated
private temporary fixture. No installed Runtime state or device is used.

## Scope and remaining work

The two exact Scope-Extension paths are `spec/control/methods/artifact.inspect.json`
for actual producer refusals and `spec/baselines/swift-single-v1.json` for the
current checkout manifest refresh. Their bounded declarations do not claim approval.

Compatibility with merged #1866: the v2 manifest describes the current checkout;
the published contract test view remains the verified protected-main merge base.
The rebase preserves #1862 Bundle registration, Rust 1.98.1, and the main-branch
daemon initialization and bounded-client timing fixes. The checkout generator
produces 105 methods and 578 shapes for this candidate.

Admission, journal/SQLite writes, capability and recovery authority, full stored
record support, executor coordination and installed handoff remain pending.
Artifact publication/import/lease/quota/export/GC and the remaining host writers
continue in separate implementation slices. No `REAL_DEVICE_PASS` is claimed.

## Final local gate

The repository unified entry point passed on 2026-09-12 against `origin/main`
`6be27ace` with the complete worktree diff. Common checks, 83 design-system tests,
2,628 parallel Swift tests, the serial process identity test and five serial viewer
scale tests passed. The path plan did not select an App build for these Rust/test
changes. Published and candidate Rust views passed warnings-denied Clippy, all
workspace tests, real daemon/CLI checks and every selected owner harness; cargo
deny and locked cargo-vet also passed. Full log:
`/private/tmp/xpa014-job-artifact-unified-gate-r4.log`.

The gate found and resolved two fixture assumptions: parser argv samples now use
the existing packaged-current-CLI mechanism with byte-equality checks, and Artifact
inspect reconstruction selects exact source fixture bytes by their recorded digest.
No recorded digest or native response was rewritten to satisfy those assertions.

## Rebased local gate

The full unified entry point passed again against protected main `a3b384d3` on
2026-09-12. Common checks, 83 design-system tests, 2,630 parallel Swift tests,
one serial process-identity test and five serial viewer-scale tests passed. The
path plan did not select an App build. Rust workspace tests, warnings-denied
Clippy, published and candidate contract views with actual process checks, cargo
deny and locked cargo-vet all passed. Log:
`/private/tmp/xpa014-job-artifact-rebase-gate-r1.log`.

Rebuilt Rust binaries also passed the explicit Swift-created Job and Artifact
fixtures: five plus two matching RPC samples, four plus three CLI processes,
raw bytes, unchanged SQLite after restart and second-owner refusal. Logs:
`/private/tmp/xpa014-rebase-job-process.log` and
`/private/tmp/xpa014-rebase-artifact-process.log`. The final diff retains main's
Bundle registration and its lost-response classification without changes, and
retains both main's bounded-client timing fix and daemon initialization wait.
