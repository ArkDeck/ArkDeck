# Job Artifact read library and projection phase — 2026-09-11

Integration base: protected main `b315f371`. TASK-XPA-013 remains in progress.
This phase is independently reviewable; the full owner cutover retains its
TASK-XPA-012 dependency. It does not enable a second Runtime store writer.

`ArtifactReadStore` provides immutable in-memory discovery pages, metadata
inspection and bounded byte ranges for existing Job-owned Artifact publications.
Every published payload is checked against its actual length and full SHA-256.
Range reads retain only the requested maximum of 4 MiB, and release no bytes
until descriptor, named inode and index/root identities are revalidated.
Sensitive payload reads require explicit opt-in. Reads preserve all source
metadata, payload bytes and verification documents.

Typed Job Artifact inspect/read conversion matches the current Swift handler's
exact fields, nulls, base64 encoding and offset/EOF semantics. Import owners are
explicitly unsupported. The integrating Runtime must still check actual Job
existence and map transport errors; identifiers alone establish no authority.
The existing frozen index decoder is shared without widening its accepted shape.
The existing FormatStyle acceptance parser is preserved while adding a comparison
time for Artifact list ordering.

Two actual Swift producer supplements cover nullable digest/revision, observation
windows, missing content and existing integrity failures. Only the two relevant
schemas/corpora change, with exact scope extensions for artifact.inspect/read.
Primary producer frames are retained unchanged under
`native-producer-frames-macos-20260911/`; the detailed provenance is in
[artifact-projection-macos-20260911.md](artifact-projection-macos-20260911.md).

Targeted tests passed for the owner/projection (20), deterministic payload
mutation/replacement (1), comparison dates (2), and warnings-denied Clippy.
Actual Swift producer/schema selection passed 6 tests and its existing integrity
failure test passed separately.

The final repository unified gate passed on protected main `b315f371` using
`--merge-base --include-worktree --run-local`: common checks, design-system,
full selected Swift lanes, Rust formatting and warnings-denied Clippy, workspace
tests, published/candidate contracts and actual process checks, dependency deny
and vet (26 fully audited). The planner selected `app: false`; no App build or
UI/device acceptance is claimed. The gate log is
`/private/tmp/xpa013-artifact-read-full-gate.log`, SHA-256
`49483a931d89fa8f123dbb4ba484aa8945b4f5a6ee79d241f0001237bde09057`.
Contract recordings are under
`rust/target/readonly-check/e6b84e5f0b4b4a6f8f30fcfc4d3c9480`.
Published baseline refresh follows reviewed merge.

Runtime routing, private engine publish, import leases, retention/GC, installed
owner switch, crash-window write acceptance and GJ-1/2/3 acceptance remain future
TASK-XPA-013 work. These isolated host fixtures are not device evidence.
