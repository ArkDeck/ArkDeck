# TASK-XPA-013 — publication past 4096 Artifact entries (macOS, 2026-09-19)

TASK-XPA-013 remains in progress. Base: protected main `17b428d2` (#2055); written on `0ae927d1`
(#2049) and rebased without conflict onto `a3310b20` (#2052), then onto `17b428d2`. The six commits
between (#2051 to #2055, and #2057) touch none of this slice's files; #2051 changes
`arkdeck-agentd` loopback-port tests, and #2055 and #2057 change only Swift sources, tests and
fixtures. No stack. Host-only change: no device, real HDC, installed state or Swift daemon was
used, and nothing here is device evidence (POL-VERIFY-001, POL-MODE-001). No Swift source, control
schema, corpus, Catalog, entitlement, `openspec/specs` or constitution change.

## Already on main / this slice / still remaining

| Already on main | This slice | Still remaining (TASK-XPA-013) |
| --- | --- | --- |
| Trace cache purge with its Artifact census (#1885, TASK-XPA-012); Job product publication with deadlines and quota (TASK-XPA-014); the retention sweep (#2039); the alias route (#2045); the publish crash-window matrix (#2049) | A pre-existing defect fixed: every Artifact publication was refused once the store held more than 4096 entries | Owner activation at M5; GJ-1/2/3 re-pass |

## The defect (pre-existing, since #1885)

#1885 (TASK-XPA-012, `c1aef0d1`, 2026-09-13) guarded Trace cache purge with an Artifact census,
`ArtifactReadStore::with_trace_retention`. The census walks the whole Artifact store under the
guard's lock and refused once it had counted more than 4096 entries in total: every Job directory,
index and payload, and every member of the Import namespace. Every Artifact writer joined the whole
census, not only its lock, although none reads its answer: Job product publication (`publish`,
`record_missing`), Import publication (`publish_import`) and the Import unpin
(`finish_import_unpin`).

So once the store held more than 4096 entries, every publication failed with
`ioFailure("cannot inspect artifact retention: …")`. A Job run failed with
`artifactPublicationFailed`, and its product was not even recorded missing, because
`record_missing` took the same census. An Import commit was refused the same way. The store reaches
the bound by its history, not by its current size. The retention sweep reclaims expired payloads but
keeps each Job's directory and index, possibly empty, as Swift's does, so every Job that ever
published a product leaves two entries, and each product still retained adds its payload. About
2000 Jobs are enough, fewer while their products are retained. Each publication also walked the
whole store and decoded every Job index twice, once for the census and once for the quota.

Swift has no such bound. Its `trace.cache.purge` is ArkTrace's `purgeUnused`, which never consults
the Artifact store. Its publication reads its own Job's directory and every Job index for the quota
(`totalBytesUsed`), nothing else. The bound was noticed while the retention sweep was written
(#2039, `artifact-retention-run.md`): the sweep took the lock alone for that reason. It is fixed
here.

## The fix

1. **Artifact writers take the guard's lock alone** (`with_retention_lock`), as the sweep already
   did: the four call sites in `artifact_publication.rs`. The lock still excludes Trace maintenance,
   which holds it through its census and its purge, and that exclusion is all #1885 asked of
   writers ("Future Artifact writers must join this guard before publication"): no publication
   lands between a census and the deletion it permits. A publication now reads what Swift's reads,
   and fails on a corrupt index elsewhere only through the quota count, as Swift's does.
2. **The census has no bound on the store as a whole.** Each listing it reads is bounded at 100 000
   entries (`CENSUS_LISTING_BOUND`): the Artifact root's Job directories, bounded as the quota count
   (`used_bytes`) and the sweep already bound them, and each directory below it. Everything it
   refused before, it still refuses before its action, the Import namespace included: a nested
   directory deeper than eight levels, a link, a hard link, a file that is not the owner's alone, a
   special file, a corrupt Job index, and a root that changes during the census. Its cost grows
   with the store, one directory at a time, and only a Trace purge pays it. A paged or indexed
   census was not needed once no writer reads it; an index would have been new durable state with
   its own crash windows.
3. **No decision changes.** The census still retains every Trace entry while any Job directory,
   unknown namespace or retained Import state exists. The sweep still reclaims only an expired,
   unpinned row outside the Jobs and leases it keeps (ADR-0007 decision 5), and the quota still
   refuses a new product and never evicts one.

What stays: the Artifact root is listed with a bound of 100 000 Job directories by the quota count,
the sweep and now the census, and the Job owner lists its Job directories with the same bound.
Neither runtime ever removes a Job's directory. That bound is unchanged here.

## What changes

- `arkdeck-hoststore` `artifact_read_owner.rs`: `CENSUS_LISTING_BOUND` replaces the census's
  4096-entry listings and its running total; the guard's documentation says who takes what.
- `artifact_publication.rs`: `publish`, `record_missing`, `publish_import` and
  `finish_import_unpin` take `with_retention_lock`.
- `artifact_retention.rs`: its documentation, and the test that pinned the census's refusal.
- `rust/README.md`: two sentences in the Trace cache paragraph.

## Tests

| Test | What it proves |
| --- | --- |
| `artifact_publication::retention::tests::a_store_past_4096_entries_still_publishes_sweeps_and_takes_the_trace_census` (replaces `the_sweep_runs_over_a_tree_the_trace_census_refuses`) | The sample store plus 2048 Job directories the sweep emptied, each keeping an empty index: more than 4096 entries, counted. A new Job's product is published and a missing one recorded. The census answers "retain everything". With a link inside another Job's directory the census refuses and a publication still succeeds. The sweep then reclaims exactly the nine lapsed rows |
| `tests/artifact_read_owner.rs::trace_retention_reads_past_4096_entries_and_still_refuses_what_it_cannot_read` | Exactly 4097 entries: the census answers "retain everything". A corrupt index in the last Job it reads, then a link inside that Job, still refuse before the action runs. Once removed, it answers again |
| The census tests already on main, unchanged | The idle Import skeleton, retained Import state, unknown namespaces, and the refusals of a corrupt index, a link, a hard link, permissions and depth before any action |

Two mutation checks, each run once by hand on the same tree and restored:

- Both source files at `0ae927d1`, with the new tests: both tests fail. The publication fails with
  `ioFailure("cannot inspect artifact retention: Artifact inventory or payload changed or is
  unreadable")`, and the census refuses at 4097 entries.
- Only the four writers back on the whole census, now without its total bound: the first test fails
  at the publication made beside the link (`host snapshot refused`).

## Local targeted checks

Logs are under this session's scratchpad `logs/`. `arkdeck-soak` is the one other crate that depends
on `arkdeck-hoststore`.

| Command | Exit | Log SHA-256 |
| --- | --- | --- |
| `cargo fmt --all --check` | 0 | `e3b0c442…` (empty) |
| `CARGO_BUILD_JOBS=2 cargo clippy -p arkdeck-hoststore -p arkdeck-agentd -p arkdeck-soak --all-targets --locked -- -D warnings` | 0 | `d3fb8d6b…` |
| `CARGO_BUILD_JOBS=2 cargo test -p arkdeck-hoststore -p arkdeck-agentd -p arkdeck-soak --locked`: 59 test binaries, 460 passed, 0 failed, 13 ignored (the publication kill helper among them) | 0 | `c631e554…` |
| `ARKDECK_PYTHON=<repo>/.venv-sdd/bin/python sh scripts/check-sdd.sh`: 0 errors, 0 warnings | 0 | `77c17376…` |

Those ran on `0ae927d1` plus this change. On the head rebased onto `a3310b20`, fmt and the same
clippy passed again (`0b53209d…`), and so did this slice's and its neighbours' test binaries: the
`arkdeck-hoststore` unit tests, `artifact_read_owner`, `artifact_retention`, `import_upload`,
`job_run` and `artifact_publication_process_death`, 291 passed, 0 failed, 7 ignored (`d5df903d…`),
and `arkdeck-agentd`'s `artifact_retention_process`, 2 passed (`6e5f2d7d…`).

## CI

The PR's CI (`guard` + `swift`) is the unified gate; its run ids and conclusion are recorded by the
next slice or a documentation follow-up.

## Not run

Any device, real HDC, installed Runtime or Swift daemon. No test lists 100 000 entries in one
directory: that bound is unchanged and shared with the quota count and the sweep.
