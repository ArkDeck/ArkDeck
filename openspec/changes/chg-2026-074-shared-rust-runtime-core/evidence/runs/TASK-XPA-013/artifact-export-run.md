# Artifact export owner — macOS, 2026-09-12

TASK-XPA-013 remains in progress. This slice uses protected main `1fd85b93` (including #1869, #1870 and #1873) and
its actual SQLite Job/Artifact read owner. It serves the existing `artifact.export`
RPC and `artifact export` CLI leaf for explicit Job-owned payload export.

## Behavior

The Job owner is resolved before Artifact content is opened. Source index,
metadata, inode, complete length and digest are validated; sensitive payloads need
explicit opt-in. Export writes only into the explicit owned physical destination.
A private staging file receives a fixed-memory copy; publication binds the source,
parent and destination identities, validates the output digest, then syncs and
reads back the result. A new destination uses exclusive publication. Overwrite
requires the exact previously observed regular file; a substituted file,
symlink, hardlink or directory cannot be silently replaced.

The CLI verifies the exact owner, Artifact identity/digest, byte count, destination
and overwrite receipt. Lost/invalid mutation replies remain `outcomeUnknown` and
are never automatically replayed. Restart reads the existing completed export;
it does not dispatch another export. Source Artifact bytes and SQLite remain
unchanged. Import-owned exports await the complete Import owner.

## Validation completed

Warnings-denied workspace Clippy, 24 Artifact read/export owner tests and eight
CLI Artifact tests passed on Rust 1.98.1. Log:
`/private/tmp/xpa013-export-main-targeted.log`. The corrected platform filter
`host_store::file_export::tests` passed all eight tests, including actual child
SIGKILL publication windows; its subprocess helper is intentionally ignored when
run directly. Log: `/private/tmp/xpa013-export-main-platform-r2.log`.

The current Swift producer passed two targeted contract tests. It records a real
source-created Job/Artifact export, missing owner/Artifact refusals and the existing
prepublication failure path. The native responses supply `resourceNotFound` and
`operationFailed` to the exported method schema; the existing main corpus is
retained in derivation. Raw recordings and source hashes are committed under
`export-producer-frames-macos-20260912/`. Log:
`/private/tmp/xpa013-export-native-swift-r2.log`.

The rebuilt actual Rust daemon and CLI passed the Swift-created temporary fixture:
three RPC samples, six CLI processes (inspect/read/raw/export/conflict/overwrite),
matching exported payload bytes, restart persistence, unchanged SQLite and
second-owner refusal. The comparison remaps only the explicit destination path
to its own isolated export directory; recorded native frames remain unchanged.
Log: `/private/tmp/xpa013-export-main-process.log`.

The current CLI argv fixture for export is copied byte-for-byte into the same
packaged test-fixture directory used by main's inspect/read tests, so both
published and candidate Rust views can verify it. The checkout manifest uses
v2 under merged #1866 and describes 105 methods/581 shapes; its published test
view remains the verified protected-main merge base.

## Final gate and remaining work

The earlier complete unified gate on base `84d7107f` passed (log: `/private/tmp/xpa013-export-main-unified-gate-r1.log`). After rebase onto `1fd85b93`, all 24 Artifact owner tests and eight CLI tests passed again (`/private/tmp/xpa013-export-latest-targeted-r1.log`). The new combined source retains Target and Job events. Its fresh complete unified gate passed with exit 0 (`/private/tmp/xpa013-export-latest-unified-r2.log`), including the selected Swift, design-system, Rust and published/candidate contract lanes. The planner did not select App build for this diff. Final commit preflight is run immediately before push. The exact
Scope-Extension paths are `spec/control/methods/artifact.export.json` (native
refusals) and `spec/baselines/swift-single-v1.json` (checkout input manifest).
These declarations do not establish maintainer approval. Artifact publication,
Import completion, leases, quota/GC integration and installed owner cutover remain
necessary migration work. These source-created host fixtures are not hardware
acceptance.
