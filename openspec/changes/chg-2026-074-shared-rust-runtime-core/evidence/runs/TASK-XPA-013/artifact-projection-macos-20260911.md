# TASK-XPA-013 — Job Artifact inspect/read projection slice

This is a local Rust library implementation and fixture verification. It does not
complete TASK-XPA-013, establish Runtime Job ownership, publish Runtime authority, or constitute hardware evidence. The accompanying
Swift fixture recordings extend the inferred Artifact method schemas to existing
producer shapes; they do not change producer semantics.

## Implemented API and scope

`artifact_projection.rs` adds `ArtifactInspectRequest::new/from_params` and
`ArtifactReadRequest::new/from_params`, plus
`ArtifactReadStore::inspect_wire/read_wire`. Requests contain exact identifiers,
never a payload path. `inspect` permits only owner/artifactId; `read` additionally
permits offset/maxBytes/allowSensitive. Counts must be integer JSON values;
strings, floating-point numbers, null and booleans do not become counts. The
read defaults are offset 0, 1,048,576 bytes, sensitive opt-in false, with the
current 4,194,304-byte maximum and 2^53-1 integer bound. Import requests explicitly
return Unsupported; imported receipt/release/lease handling is not implemented.

Returned JSON preserves the production inspect field set (17 fields), casing,
nulls and Job lease reference spelling, and the read result's exact eight fields,
standard padded base64, offsets, byte counts, total and EOF. Canonical results
are bounded by the current handler's 8 MiB minus 4096 response budget. The Job
lease string is only the existing projection of a stored publication; this
library creates no lease authority, capability or Runtime ownership record.

The former durable decoder remains unchanged. The projection separately checks
safe integers, bounded name/media/provider/operation, target identity, optional
binding revision/digest, retention timestamp, and ordered observation window.
`read_with_metadata` is crate-private and returns the metadata from the very same
index/read pass as its validated bytes. This avoids two metadata lookups around a
possible index/privacy change. Public `read` retains its original return type.
`inspect` now uses verified rows without applying list's time sorting to unrelated
records, matching Swift `loadIndex` + selected `artifactProjection` behavior.

These APIs return io::Result<Value>, not transport envelopes. The integrating
Runtime still owns exact error-code mapping, its real `engine.jobReadSnapshot`
check, and outer schema enforcement. Syntactic Job identifiers are not proof that
a Job exists. Root selection is supplied by existing trusted composition.

## Genuine Swift recordings and schema coverage

The real `ArtifactResourcesContractTests` handler now exercises missing metadata
with null artifactDigest, published metadata with null bindingRevision and a
startUtc/endUtc observationWindow, plus bounded prefix/tail/EOF reads. Missing
content returns the existing resourceNotFound refusal and no bytes. The tests
reuse the existing fixture Job repository, Artifact store and wire helper; the
Dispatcher count remains zero. No new producer behavior or transport endpoint was
implemented. An existing source-mutation test records artifactIntegrityFailed so
schema regeneration preserves that already accepted error code.

The debug recorder wrote actual frames under
`/private/tmp/xpa013-artifact-wire-frames/control-frames-44765.jsonl` and
`control-frames-` files from the source-mutation/final verification processes.
The generator input was the exact old committed corpus plus the two initial
successful recording runs (460 frames across 97 methods). The unchanged
`Packages/ArkDeckKit/Scripts/generate-control-contract.py` ran in
`/private/tmp/xpa013-artifact-schema-generator`; only artifact.inspect/read schema
and corpus outputs were copied back. Other generated outputs and published
baseline pins were not changed. Sample counts describe that combined input,
not a new execution of every published method. No frame was synthesized or
relabeled. The two required exact scope extensions are:

- `spec/control/methods/artifact.inspect.json`
- `spec/control/methods/artifact.read.json`

artifact.inspect now admits its existing nullable digest/revision and closed
observation window. artifact.read additionally admits its existing
resourceNotFound error; its result shape is unchanged. Existing string-offset
request samples remain rejected by the production handler and strict Rust parser.

## Targeted verification

`python3 rust/scripts/check-artifact-read-owner.py` passed with the pinned Rust
1.98 toolchain: 20 integration tests, one deterministic platform payload-change
test, two date tests, and targeted hoststore clippy with `-D warnings`.
`cargo clippy -p arkdeck-hoststore --lib -- -D warnings` also passed.
`git diff --check` passed.

Two tests directly consume the committed actual Swift
`Fixtures/ControlFrames/artifact.inspect.jsonl` and `artifact.read.jsonl` Job
success recordings, including newly recorded missing/window metadata, reconstruct
new private fixture payloads using the exact bytes from the Swift test source,
and prove their digest before invoking the real Rust owner. The resulting JSON
matches the entire recorded result and passes the current method validator.
No import corpus row is treated as Job-owned. Additional tests cover closed
input, default read budget, sensitive refusal, base64 padding/binary/partial/EOF,
4 MiB slash-heavy payload within frame budget, total inspect response bound,
malformed projected metadata, and production null/observation cases validated
against the expanded method schemas.

The final Swift selection passed six tests (two new producer tests and four
ControlMethodSchemaContractTests) with `ARKDECK_CONTROL_FRAME_LOG` enabled.
The existing source-mutation test separately passed. The Swift test fixture's
existing Unix socket required an approved unsandboxed test run after sandbox bind
failed with errno 1. Logs: `/private/tmp/xpa013-artifact-wire-final.log`,
`/private/tmp/xpa013-artifact-integrity-wire-tests.log`, and
`/private/tmp/xpa013-artifact-expanded-final-rust.log`.

All inputs are freshly created local host fixtures, not user Artifact roots or
hardware evidence. Swift's existing teardown removes its own test roots; Rust
fixtures are retained. No device, install, capability, trusted admission fact or
Provider evidence was changed. The root integration task owns the final unified
gate and subsequent published baseline pin refresh.

## Integration diff

New file: `rust/crates/arkdeck-hoststore/src/artifact_projection.rs`.
Updated owned files: `artifact_read_owner.rs` and `tests/artifact_read_owner.rs`.
The existing targeted script already executes the expanded integration test.
Shared `lib.rs` adds only:

```rust
#[cfg(target_os = "macos")]
mod artifact_projection;
#[cfg(target_os = "macos")]
pub use artifact_projection::{ArtifactInspectRequest, ArtifactReadRequest};
```

Earlier platform/date/owner patches remain in this isolated worktree. Swift
changes are confined to ArtifactResourcesContractTests.swift and the two
Artifact schemas/corpora. No daemon, CLI, Cargo project, generated baseline,
task status or another worktree was changed. Final integration and PR submission are tracked in run.md.

The two primary raw recording files are retained byte-for-byte under
`native-producer-frames-macos-20260911/`. The final verification recording
`control-frames-45965.jsonl` is byte-equal to `control-frames-44765.jsonl`.

Final integration: the selected unified repository gate passed on `b315f371`;
see [the phase run record](run.md). Runtime cutover and device acceptance remain
pending.
