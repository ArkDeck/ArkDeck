# TASK-XPA-025 InputArtifact functional capture — 2026-09-27

This is an opt-in host-only functional slice, not an adopted baseline, a G5 pass,
a 200 MB/s pass, or device acceptance. Original recovery/cold/RSS/Journal evidence
is retained unchanged. No Runtime production semantics, App, CLI, Catalog or
protocol changed. The coordinator authorized the local window and it was released
following final small verification. Artifact branches remain separate from signing
and UI work.

## Fixture and measurement

The deterministic complete 17-member synthetic flash archive keeps every member
except the grow partition `userdata.img`. Streaming stored gzip yields exact 1,
128, or 1024 MiB bytes. Production ImportUploadStore begin/append/commit validates
and publishes the immutable flash-bundle. A fixed synthetic binding is confined
to the fixture resolver: no TargetStore/trusted facts/capability record or device.
The actual Rust daemon then serves `artifact.read` with owner.kind=import, 4 MiB
pages. Completion requires full range/EOF validation and complete client SHA-256.
Each root is fresh, private, and removed on success/failure. Seed/startup are outside
read timing; full server per-page payload hashing is inside. No warm-up read or
OS cache eviction. Memory is 0.2-second sampled process RSS, not exact peak/copies.

Disk admission reserves 4 GiB plus three payload copies and 64 MiB metadata.
Generation/publication/read budgets are 120/600/600 seconds. The final instrument
uses phase-boundary quiet checks (before generation, after publication, after
daemon startup, and after read completion), continuous exchange deadlines, and
bounded raw transport failure evidence. No per-page process scan enters timing. Those changes followed the 128 MiB smoke; their real
integration is separately recorded as `1m-transport-final`. No result from the
older 128 MiB driver is relabeled as final-instrument performance.

## Actual attempts (all retained)

All used the standalone smoke driver with `require_quiet=False` and explicitly
`functionalOnly=true`, `baselineEligible=false`. No formal quiet claim or 3-run
stability assessment. Lossless JSONL gzip and result JSON are adjacent; the file
manifest hashes the uncompressed original. Each refusal log is retained.

| Attempt | Outcome |
| --- | --- |
| 1m-attempt1 | Import refused missing synthetic stable identity, zero publication/read. Fixed only fixture resolver. |
| 1m-attempt2 | Import validated/published; read rejected string offset. Corrected to contract's numeric offset. |
| 1m-attempt3 | 1 MiB real owner/read passed with complete digest. |
| 128m-attempt1 | 128 MiB real owner/read passed, 32 pages, 21640.163125 ms, 6.202251 decimal MB/s (5.914928 MiB/s). |
| 1m-transport-final | Real owner/read passed after total-deadline/error-frame fixes. |

128 MiB input SHA-256:
`3a6db799b50f87ebe4cd21dc5c691a6f1433e684fdd992bb6388e761bc3b2e7e`.
Daemon RSS baseline/observed peak: 19,906,560 / 41,713,664 bytes.
Client RSS baseline/observed peak: 33,308,672 / 397,049,856 bytes.
These unfavorable observations are preserved, without removal/subtraction.
Copy count remains unmeasured. The 200 decimal MB/s target is not established.

1 GiB was not generated/published/read in this window. Every page rehashes the
whole payload; if that cost dominates, 8× bytes and 8× pages imply about 64× read
work (approximately 1385 s from this smoke), beyond the fixed 600 s budget.
This is a conservative scheduling inference, not a measured 1 GiB result or proof
of its validity. No limit/threshold was relaxed to obtain a result.

## Executables and source

Daemon: release, default features, locked Rust 1.98.1 build of main
`82f0971ce5f122bde47d9cd850f6df4e0b277da1`, immutable copied executable at
`/private/tmp/arkdeck-xpa025-pinned-82f0971c/arkdeck-agentd`, SHA-256
`3c929eb2445e3d7d2ae0b3ebb96cccd1812e64234effb594d35f79161b211925`.
This is the earlier reviewed Runtime, not acceptance of today's main changes.

Soak: debug, default features, locked build in task-private
`/private/tmp/arkdeck-xpa025-journal-target`, CARGO_BUILD_JOBS=2, on base
`72e9e7b08d78489c9e9488fe6c271510312a8730` plus this fixture implementation.
Attempts 2 onward used SHA-256
`1593d9d4abc8c63f50b3f6905e57ef38e5457e6e9be3e91f8c3c51f91dcf0434`.
Attempt 1 preceded the synthetic identity correction; its binary hash was not
captured before rebuild. Its raw rejection is evidence only, never a performance
sample. Intermediate Python sources were edited in place; their per-attempt file
hashes were not captured. Results are therefore development diagnostics, not a
reproducible pinned formal baseline. Future capture records executable provenance
through the normal harness and requires pinned source/build inputs.

## Local targeted checks

- `python3 -m unittest discover -s scripts/bench -t scripts -p 'test_*.py'`:
  exit 0, 203 tests, 3 opt-in daemon skips; archived `python-final.log`. An initial
  sandbox run could not invoke `ps`; host-authorized rerun passed. No assertion
  was changed to accommodate sandbox denial.
- `CARGO_BUILD_JOBS=2 CARGO_TARGET_DIR=/private/tmp/arkdeck-xpa025-journal-target cargo clippy --locked --manifest-path rust/Cargo.toml -p arkdeck-soak --all-targets -- -D warnings`:
  exit 0; archived `clippy-final.log`.
- Same environment `cargo test --locked --manifest-path rust/Cargo.toml -p arkdeck-soak`:
  exit 0, 9 tests; archived `rust-test.log`. After the binding correction the
  affected artifact refusal test was rerun (exit 0, `rust-test-final.log`), followed
  by the successful real small and 128 MiB functional runs above.
- `cargo fmt --all --check --manifest-path rust/Cargo.toml`, `sh scripts/check-sdd.sh`
  and `git diff --check`: exit 0; archived fmt/SDD logs. The default-path Python
  rerun also passed 203 tests (3 skips). No local full unified gate,
  release rebuild, 1 GiB run or formal baseline capture was performed for this slice.

## CI

Artifact PR #2281 follows merged Journal prerequisite #2277. Review added archive
and template SHA-256 comparison identity; changed valid hashes with unchanged
scale/version refuse comparison. Quiet admission is explicitly phase-boundary
only. Python 203 tests (3 opt-in skips), SDD and diff checks passed after this
review correction; adjacent `python-review.log` and `sdd-review.log` retain output.
No Rust rebuild or large-payload rerun was performed for these Python/doc edits.
CI for the updated artifact head is pending.
CI green is validation, not maintainer approval or baseline adoption.

### CI dependency-map correction

CI run 36297065896 at head 16ca4640 failed in Linux job 108557844537 and
Windows job 108557844562: `check-readonly.py::assert_boundaries` rejected the
new soak -> arkdeck-contract edge. Raw job logs are retained losslessly with
uncompressed hashes. This was a code failure, not an invalid/noisy run.

The exact dependency map now adds only arkdeck-contract for the host fixture's
pure ImportIntent/chunk codec/digest API. It adds no transport or authority owner;
the exact-set assertion is unchanged. Local system Python lacks jsonschema, so
the isolated check driver executes the actual assert_boundaries AST function
with its real ROOT/tomllib inputs, avoiding unrelated daemon/schema imports.
It reproduced the same failure before the correction and passed afterward
(exit 0; before/after logs and driver adjacent). No Rust rebuild, full local gate
or large-I/O capture was run. Updated-head CI must validate the complete lane.
