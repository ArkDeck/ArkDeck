# TASK-XPA-013 — macOS Artifact read-owner library slice

Base: `f9f38a2473308195978fc536f5b83efc9d47f5b3`.
This is local fixture verification, not hardware evidence or task completion.
Full TASK-XPA-013 cutover acceptance retains its TASK-XPA-012 dependency; this read-only library slice is independently reviewable and does not activate Runtime routing. TASK-XPA-013 remains in progress.

Implemented `ArtifactReadStore::open/list/inspect/read` in the hoststore crate.
`list` returns an owned, immutable in-memory `ArtifactReadSnapshot`; its `page`
method accepts an offset and page size 1–1000. Rows keep the frozen index metadata
field sets and sort by parsed creation time descending / artifactID ascending.
Equivalent timezone and fractional-second spellings tie-break by Artifact ID,
matching `artifactInventory` / `ArtifactResourceProjection.createdAt` in Swift.
The shared `format_time` reader retains its original acceptance checks, now also
returning parsed components for conversion through the existing platform Gregorian
primitive. Timestamp spelling in the durable metadata is preserved. Snapshot
lifetime is the Rust value's lifetime: it is neither a persisted wire cursor nor a
claim of restart survival. Opening and reading never create directories or files.

The existing ArtifactUsage index decoder was factored into `decode_index`, retaining
strict unknown-key rejection, status and nested provenance validation, owner and
safe-ID checks, and Foundation-canonical duplicate-name handling. ArtifactUsage
continues its existing quota accounting and payload verification behavior.

`read` returns typed bytes, digest, offsets, total byte count and EOF. The byte
range maximum is 4,194,304, matching the Swift read bound. Sensitive content
requires explicit opt-in; missing/truncated records remain inspectable but cannot
return content. Every indexed published payload must verify. The selected payload
is fully hashed with 64 KiB scratch memory while retaining only the requested
range. A final held-descriptor and linked-inode identity/content check precedes
return. Index bytes and retained root/job directory bindings are checked again.
This first slice always hashes; it does not rewrite the frozen payload verification
document or introduce an identity cache. Large payload reads therefore still incur
full-hash I/O cost on each call.

## Verification

`python3 rust/scripts/check-artifact-read-owner.py` passed on macOS with the pinned
Rust 1.98 workspace toolchain:

- 11 Artifact owner integration tests passed: range/chunk/EOF, unchanged source bytes,
  quota-reader parity, stable snapshot pagination after publication, bounds and
  sensitive opt-in, missing/truncated states, strict/duplicate/malformed index
  fields, foreign identity, derived provenance preservation, canonical-equivalent
  names, digest corruption outside the requested range, payload size and symlink/
  hard-link rejection, corrupt unselected payloads, chronological timezone/fractional
  pagination and invalid creation time refusal.
- 2 date unit tests passed: existing parser acceptance unchanged and eight exact
  Date reference-second bit patterns observed using Swift's actual
  `fractional.parse(value) ?? plain.parse(value)` entry point. Equivalent `.1Z`,
  `.100000000+08:00` and `.100-05:00` timestamps have equal comparison values.
- 1 platform unit test passed with deterministic post-read checkpoints for same-inode
  content mutation and replacement by a new inode containing identical bytes.
- Hoststore targeted clippy with `-D warnings` passed.
- `cargo clippy -p arkdeck-platform --lib -- -D warnings` passed separately.

Fixtures are newly generated private temporary directories, intentionally retained;
no actual Artifact directory, deletion, device dispatch, install, GC, capability,
trusted facts or Provider evidence was touched. No full merge gate, Xcode, UI or
real-device test was run in this parallel slice; the integrating task owns those.

## Integration patches and remaining dependencies

The minimal shared `lib.rs` addition registers/re-exports `artifact_read_owner` and
its five public types/constants under the existing macOS cfg. The platform
`host_store.rs` patch adds only `verify_payload_range`, its private checked helper
and the isolated test module; existing `verify_payload` remains unchanged. Merge
these methods alongside other host-store helpers rather than replacing that file.
The additional shared `format_time.rs` patch exposes parsed comparison values while
preserving its existing acceptance predicate; it does not replace Session's parser.

Runtime/daemon/control/CLI integration is not included. The API is job-scoped and
returns frozen metadata, not tagged ArtifactResource wire projections. Reserved
`imp-` owner IDs are rejected so import lifecycle checks cannot be bypassed through
the job-scoped library entry point. Imported
owner receipt/lease checks, wire error mapping, persisted query-bound cursors,
Swift private publish routing, import/export/quota/retention/cleanup ownership,
crash-consistent publication and macOS Golden Journey hardware re-pass remain
outside this slice. No existing wire cursor or import ownership semantics should
be redirected to this API without the corresponding adapter and validation.

Final integration: the selected unified repository gate passed on `b315f371`;
see [the phase run record](run.md). Runtime cutover and device acceptance remain
pending.
