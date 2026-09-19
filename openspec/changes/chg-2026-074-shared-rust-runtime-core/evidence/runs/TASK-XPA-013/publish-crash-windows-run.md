# TASK-XPA-013 — the publish crash-window matrix (macOS, 2026-09-19)

TASK-XPA-013 remains in progress. Base: protected main `830fcc1c` (#2046); written on `3e95ac6d`
(#2041) and rebased without conflict onto `f56481d8` (#2045) and `830fcc1c`; no stack. Host-only
change: no device, real HDC, installed state or Swift daemon was used, and nothing here is device
evidence (POL-VERIFY-001, POL-MODE-001). No Swift source, control schema, corpus, Catalog,
entitlement, `openspec/specs` or constitution change.

## Already on main / this slice / still remaining

| Already on main | This slice | Still remaining (TASK-XPA-013) |
| --- | --- | --- |
| Job product publication with deadlines and quota (TASK-XPA-014); single-document publication atomic under SIGKILL (`arkdeck-platform` `host_store::publication_tests::process_death_preserves_a_complete_old_or_new_document`); Import upload and commit windows under SIGKILL (`import_upload_process_death.rs`, #1890, #1983); the retention sweep (#2039); the alias route (#2045) | XPA-AC-7 for a Job product: SIGKILL at each publication step through a real Job run, and the defect it found fixed (a recovered payload is sealed before the index names it) | Owner activation at M5; GJ-1/2/3 re-pass |

## The matrix

XPA-AC-7: "kill either process mid-publish → index consistent or product recorded missing; never
a half-record". In the isolated Rust composition one process publishes, the Rust daemon: its Job
runner publishes each product directly. The Swift engine's private `artifact.publish` is not
built (r10: a direct Rust path needs no Swift sidecar), and a client killed mid-request does not
stop a publication the daemon's own Job run makes. A Job product is published in three steps,
each step's write atomic by itself:

| Step | State the store keeps if the process dies right after it | Proven by |
| --- | --- | --- |
| inside the payload write | a `.part` temp file, no payload | the platform's single-document SIGKILL test |
| payload renamed to its derived name | payload `0600`, no index row | `AfterPayload` below |
| payload sealed | payload `0400`, no index row | `AfterSeal` below |
| inside the index write | the old index | the platform's single-document SIGKILL test |
| index rewritten | the product named, sealed and verified | `AfterIndex` below |

A publication that fails rather than dies is recorded missing by the Job runner (ADR-0007
decision 3). Swift's run oracle proves it and `tests/job_run.rs` replays it (`quotaExceeded`:
`artifactPublicationFailed`, the product's missing row).

## The defect it found, fixed

`ArtifactPublisher::publish` recovers an exact payload left at the derived name without an index
row, as Swift's `publish` does. Unlike Swift, it did not seal it. Swift's `validateStoredPayload`
seals every payload it has fully hashed, including this one. So a Job killed between the payload
rename and its seal, and whose publication is later retried, would have had its index name an
owner-writable (`0600`) payload. That contradicts the publisher's own invariant ("the payload
written and sealed owner read-only before the index names it"). The recovery now seals the payload
(`seal_document`, idempotent on an already-sealed file) before the quota check and the index write.
A seal that fails refuses the publication, as the normal path's does.

Import publication has no such window: `HostUploadFile::publish_immutable` seals its temp file
before it takes the final name.

## What changes

- `arkdeck-hoststore` `artifact_read_owner.rs`: `ArtifactPublicationFault` (`AfterPayload`,
  `AfterSeal`, `AfterIndex`) and `ArtifactReadStore::open_with_fault`. This is bounded host fault
  injection for crash tests, as `ImportUploadStore::open_with_fault` is, and never a wire field;
  the daemon opens the store with `open`.
- `artifact_publication.rs`: the three fault points in `publish`, and the seal of a recovered
  payload.
- `rust/README.md`: one paragraph after the retention sweep's.

## Tests

| Test | What it proves |
| --- | --- |
| `tests/artifact_publication_process_death.rs` `a_publication_killed_at_any_step_leaves_no_half_record` (own binary) | The parent admits an analyzer Job over the run oracle's `answered` source. A child process runs it through `JobRunner` with the store opened at a fault that writes a marker and parks at the chosen step, and the parent SIGKILLs it there (signal 9 asserted). After each kill every owner reopens. The Job's Artifact directory holds exactly one payload and no partial file. The payload is `0600` and unnamed after `AfterPayload`, `0400` and unnamed after `AfterSeal`, and `0400`, named, published and verified after `AfterIndex`. The index lists and verifies. `artifact.quota` counts exactly the source's and the named product's bytes. The retention sweep keeps what the killed (non-terminal) Job left |
| `artifact_publication::tests::a_publication_stopped_at_any_step_recovers_one_sealed_indexed_payload` | A publication stopped at each step by an erroring fault, then retried by a fresh owner: one payload at the derived name, and the retry indexes exactly its metadata with the payload `0400`, readable through `list`. With the seal of a recovered payload removed, the `AfterPayload` case fails (`0600` against `0400`); with it, all three pass |

## Local targeted checks

Run again on the head rebased onto `f56481d8`, which brings #2045's changes to
`arkdeck-hoststore`. The same checks passed on `3e95ac6d` before the rebase (442 tests). Logs are
under this session's scratchpad `logs/`. `arkdeck-soak` is the one other crate that depends on
`arkdeck-hoststore`.

| Command | Exit | Log SHA-256 |
| --- | --- | --- |
| `cargo fmt --all --check` | 0 | `e3b0c442…` (empty) |
| `CARGO_BUILD_JOBS=2 cargo clippy -p arkdeck-hoststore -p arkdeck-agentd -p arkdeck-soak --all-targets --locked -- -D warnings` | 0 | `7b2df3d0…` |
| `CARGO_BUILD_JOBS=2 cargo test -p arkdeck-hoststore -p arkdeck-agentd -p arkdeck-soak --locked`: 59 test binaries, 447 passed, 0 failed, 13 ignored (the child helper among them) | 0 | `95131cea…` |
| `ARKDECK_PYTHON=<repo>/.venv-sdd/bin/python sh scripts/check-sdd.sh`: 0 errors, 0 warnings | 0 | `77c17376…` |

After the last rebase, onto `830fcc1c` (#2046: the tool-selection control-action store, including
`arkdeck-hoststore/src/lib.rs`), fmt and the same clippy passed again (`23cb6d30…`), and so did this
slice's and its neighbours' test binaries: the `artifact_publication` unit tests,
`artifact_publication_process_death`, `artifact_retention`, `import_upload`, `artifact_read_owner`
and `job_run`, 73 passed, 0 failed (`28c59b5d…`).

The mutation check above (the recovered payload's seal removed) was run once by hand on the same
tree and restored.

## CI

PR #2049, head `95771383`, all green. It merged on 2026-09-19 as `0ae927d1`.

| Check | Run | Conclusion |
| --- | --- | --- |
| SDD Guard `guard` | 35449960354 | success |
| Swift CI `plan` | 35449960472 | success |
| Rust host-independent checks | 35449960472 | success |
| Rust workspace, `ubuntu-latest` | 35449960472 | success |
| Rust workspace, `macos-26` | 35449960472 | success |
| Rust workspace, `windows-latest` | 35449960472 | success |
| `swift` aggregate | 35449960472 | success |

`swift-tests`, `app-build` and `ds-interactions` were not selected for this diff and were skipped.
These rows were added by a documentation follow-up, since the PR merged as soon as it was green.

## Not run

Any device, real HDC, installed Runtime or Swift daemon. A killed Job's later finalization, which
would retry its publication, waits for the Job recovery port (design §L.1 item 13). The retry path
it will take is the one the in-process test covers.
