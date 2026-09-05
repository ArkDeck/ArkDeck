# Runtime-owned CLI Job read resources

This vertical slice implements the Job discovery/detail/result portion of
`arkdeck-cli-product-spec.md` for the current v1 control contract. It advances GJ-1–GJ-5
result inspection without changing operation admission, dispatch or recovery.
The Catalog digest and published typed operations are unchanged.

All Job commands use the current versioned resource projections. Output format,
filters and waiting options do not select another wire shape.

```sh
arkdeck job list --state succeeded --page-size 20 --output json
arkdeck job show --job JOB_ID --output json
arkdeck job result --job JOB_ID --output json
arkdeck job timeline --job JOB_ID --page-size 20 --output json
```

Job lists always use `arkdeck.cli.page/1` with seven fixed fields. The default
`createdAtDescJobIdAsc` order compares parsed UTC instants descending, then ASCII
Job IDs ascending. `createdAtAscJobIdAsc` reverses only the time component. Exact
`state`, `operation`, `target` and `thread` filters select Jobs, never targets to
adopt or work to execute. The durable history includes nonterminal Jobs;
`includeCurrent` overlays Runtime current records, and `includeTimeline` adds
historical prose. No typed inputs appear in list summaries.

The first read captures an immutable private snapshot; continuation binds the
method, every filter, order, page size and snapshot revision. It survives daemon
restart and cannot see Jobs or state updates that arrived later. Runtime retains
up to 32 snapshots / 64 MiB, with a 16 MiB snapshot and 1 MiB page bound. Reclaimed
or cross-query cursors return `invalidCursor`; a corrupt stored projection is
`recordUnreadable`. SQLite rows are copied one at a time with a 16 MiB record
bound. Large result sets require a narrower query instead of an unbounded read.

`job show` publishes the typed request, pinned materialization identifiers,
status and capture facts, plus exact Job event/evidence references. It never
serializes private provider lowering or recovery actions. Timelines larger than
256 KiB become a `job.timeline` reference. That resource returns fixed snapshot
pages in `entryIndexAscPartIndexAsc` order; each row has canonical decimal
`entryIndex` / `partIndex`, `text` and `lastPart`. Parts contain at most 64 KiB of
UTF-8, split at Unicode scalar boundaries. Joining parts preserves exact bytes,
even for one paragraph larger than a wire frame.

`job result` is assembled by the Runtime owner from the same captured Job and
its evidence, Artifact inventory and cleanup ledger; Artifact metadata and byte receipts are
captured together in one store actor turn, and the residue count comes from the
read cleanup ledger. The CLI no longer combines
unrelated read calls for this protocol. A changed Job during async evidence
verification returns `resourceConflict`. Artifact bytes are hashed in bounded
chunks and must retain file identity, size and digest. Symlinks, missing required
metadata, wrong Job/target/provider lineage, missing bytes and changed payloads
cannot verify. Index reads are bounded as well. The expected required products
come from the current pinned Catalog; an unavailable historical digest is not
silently verified against a different Catalog. Evidence excludes raw inputs,
probe output and exception text. `inventoryAvailable: false` explicitly marks
an unreadable inventory. An unreadable cleanup ledger fails the result query;
it is never represented as an empty successful cleanup list.

Successful `status/show` queries exit 0 regardless of Job outcome. A nonterminal
`result` returns `resultNotReady`, exit 75, and the Runtime next action. Terminal
failed/cancelled/interrupted results remain `ok: true` with exit 1. Evidence
integrity failures retain the result and stable `evidence.status` with exit 2;
unknown outcomes remain exit 75 and keep their reconcile next action. Cleanup
references are owned by the exact Job and omit raw paths, actions and prose.
No read path starts, resumes, cancels or reconciles a Job.

Validation uses isolated Runtime/daemon fixtures and real CLI child processes:
fixed pagination across updates/restart, query-bound cursor refusal, full Job
reads, result/exit semantics, required Artifact deletion, foreign ownership,
large-file verification, symlink refusal, corrupt cleanup/index records and
lossless long Unicode timeline pages. These are host contract checks, not
`REAL_DEVICE_PASS`. Real-device GJ-1–GJ-5 acceptance still requires the reviewed
protected-main Runtime and current Catalog digest through Agent/CLI.
