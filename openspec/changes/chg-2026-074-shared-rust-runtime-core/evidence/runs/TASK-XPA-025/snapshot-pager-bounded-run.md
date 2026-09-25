# TASK-XPA-025 — stored snapshot pages and the Job list's snapshot in bounded memory

Change: CHG-2026-074-shared-rust-runtime-core. Branch: `agent/xpa-025-snapshot-pager-bounded`,
based on protected `main` `b4981f5f3`. macOS Runtime only; no device, no installed Runtime.

No answer, stored byte, validation, gate, workload or interval changes. Every snapshot-paged
list answers, and stores, byte for byte what it did. The 32 MiB resident-growth limit, the
16-descriptor limit, ten Jobs per cycle and the soak's per-cycle checks are as before.

## 1. What held memory

After #2129 the soak still grew linearly: 0.24 MB per cycle over cycles 51–70, which reaches the
32 MiB gate near cycle 133 (`soak-rss-bound-run.md` §7). This change's base reproduces it. The
local soak of `main` `33d30079e` (§5) stops at its own gate in cycle 125:

```
ArkDeck Rust soak failed: soak resource growth exceeded: RSS 33619968 / 33554432, descriptors 0 / 16
```

At 300 Jobs the heap high-water mark was 8.39 MB, and 4.74 MB of it was `SnapshotPager::read`.
Two paths of the pager held a whole snapshot:

- **A stored page** (every cursor): the whole snapshot file was read into memory, decoded strictly
  into one `Value` tree and converted again by `serde_json::from_value`. Each page was then copied
  by `json!` and encoded canonically to check its bound — all to answer one page.
- **A new snapshot** (every first page): every row as a `Value`, a second copy of all of them from
  `serde_json::to_value(&snapshot)`, then the whole canonical encoding.

A third holder sat in front of the pager. The Job list's projection collected every history row
as a `Value`, sorted them, and only then handed them over. A row takes about 5.8 KB as a `Value`
and 1.1 KB encoded.

## 2. Changes

1. **A stored page is read in one pass plus the page itself**
   (`rust/crates/arkdeck-hoststore/src/snapshot_pager.rs`).
   - The pass streams the document through `serde_json`'s reader deserializer. It decodes each
     page in place as a `Vec<StrictValue>`, checks its bounds (1000 rows, and `MAX_PAGE` bytes
     canonically encoded), notes where the page lies and drops it. It keeps the other members.
   - Only then are the integrity checks, the query binding and the cursor's position decided, in
     the same order as before.
   - Then only the named page's bytes are read again, from the noted place in the same inode, and
     decoded. They must come back as the same bracketed array with the same canonical length, or
     the read is `recordUnreadable`.
   - At most one page is held at a time. The place is known because the pass counts the bytes it
     hands the deserializer: a page begins at the bracket the deserializer looked ahead to, and
     ends at the bracket that closed it.
2. **Everything the whole read and decode refused is refused the same way.**
   - Members: each page is decoded with the contract's own `StrictValue`, in place in the same
     streaming deserializer. Repeated member names at any depth, plain or escaped, and the nesting
     limit are therefore those of `strict_json` over the whole document. Decoding pages on their
     own would reset the nesting depth; a mutation that does that is caught (§4).
   - Shape: the six members are closed, each present once and of its type, as the derived decoding
     required. The derived decoding also accepted the members as an array in declared order. This
     one does too, so the set of accepted documents is exactly the same. Trailing data after the
     document is refused.
   - Integrity and binding, in order: schema version, revision, page and token counts, unique
     tokens bound to the revision, every page's bounds, then the query digest and order, then the
     cursor.
   - The read uses new platform calls:
     - `HostDirectory::open_document` opens the document as `HostDirectory::read` does.
     - `HostDocument::pass` reads it by offset from the first byte, up to one byte beyond the
       maximum.
     - `HostDocument::read_range` reads a part again, within the size the file had when opened.
     - `HostDocument::check` makes `read`'s closing checks: size, modification and status times,
       and the name still linking the inode. It shares one predicate with `read`.
   - Failure order: a document refused part way through is read to its end before it is judged.
     A failed read, a changed document and a reclaimed document therefore answer as a whole read
     did. The check runs after the pass and again after the page is read.
   - One narrower window: a snapshot reclaimed between the pass and the page read answers
     `invalidCursor` ("…its snapshot was reclaimed"), where the whole read could have answered
     from memory. Retention runs only under the pager's lock document, or inside an owner that
     serializes its requests, so no pager reaches that window.
3. **A new snapshot holds its rows once** (`Draft` in the pager).
   - Each row is encoded once, straight into the stored document. The document's members are
     written in canonical order, which puts the pages before their tokens.
   - Only the first page's rows are kept, for the answer, and they are moved into it.
   - Refusals keep their order: the owner's refusal, then the revision, then the first row refused
     in answer order, then the tokens, then the encoded bound.
4. **The Job list hands each row over as it is projected**
   (`rust/crates/arkdeck-hoststore/src/job_owner.rs`, `job_repository.rs`).
   - SQLite now reads the rows in the list's order: creation key descending (or ascending), then
     Job identity ascending. It uses the same transaction snapshot, reads and checks every row, and
     counts every row against the same 64 MiB budget.
   - The pager's new `page_streamed` encodes each row as it arrives.
   - A typed record refusal still answers the list once every row has been read. It is the
     refusal of the first such record in creation order, which is the one the collected list
     returned.
   - SQLite serves the newest-first order by walking `runtime_job_created_idx` backwards and
     sorting only within a group of equal creation keys (`USE TEMP B-TREE FOR LAST TERM OF ORDER
     BY`). It therefore buffers at most one group.
5. `arkdeck-contract`: `StrictValue` is now public, so a streaming reader can decode parts in place.
6. `arkdeck-platform` gains the document calls above and a test-support feature,
   `allocation-meter` (`AllocationMeter` and `peak_allocation`). It wraps the system allocator and
   counts, per thread, the bytes held and the most ever held at once. Only `arkdeck-hoststore`'s
   tests enable the feature, as a macOS dev-dependency; no production build does.

## 3. Equivalence

The tests keep the pager and the Job list as they were, verbatim except for their I/O, and use them
as oracles.

- `snapshot_pager_tests.rs`, `stored_documents_and_their_pages_are_those_of_whole_snapshots`
  compares stored bytes, the first page and every later page for:
  - no rows, and rows of every kind: non-objects, `1.0`, `-0.0`, `5e-324`, escapes, astral keys
    and U+2028;
  - pages of 1, 4, 7 and 1000 rows, pages closed by their byte bound, and the largest row a page
    takes.
- `storing_refuses_what_whole_snapshots_refused` covers a row past its page bound, rows past the
  storage bound, an encoding past it, an integer beyond the exact range, and the first refused row
  deciding between two.
- `stored_pages_are_read_as_whole_snapshots_were` reads 48 stored documents and three file cases by
  cursor. Each answer or refusal is compared byte for byte with the whole-snapshot reader. Each
  case's outcome is also asserted, so no case passes vacuously. The documents cover:
  - layout: whitespace, member order, escaped member names, and the positional form (accepted by
    both) with its wrong lengths;
  - repeated members, plain and escaped, and repeated names in rows of the page read and of other
    pages;
  - unknown and missing members, wrong types, trailing data, trailing whitespace, empty files and a
    byte order mark;
  - invalid UTF-8, a lone surrogate, inexact and out-of-range numbers, and numbers on the page read;
  - 1000- and 1001-row pages, and a page past its byte bound;
  - rows at the deepest accepted nesting and one level deeper: on the page read, in another page
    and in the positional form;
  - token faults, another schema, revision, query or order, and an unlisted cursor;
  - file cases: past the storage bound, not owner-only, reached through a link, and reclaimed.
- `job_list_stream_tests.rs`, `a_streamed_list_is_the_list_that_collected_every_row`:
  - 60 Jobs over nine creation seconds, with identities out of creation order;
  - eleven option sets: both orders, page sizes 1–1000, every filter, and the timeline and current
    projections;
  - every page and the stored snapshot are compared with the collected list, after renaming its
    random revision and tokens;
  - a malformed record refuses both lists, in either order and under a filter that would drop its
    row.

## 4. Memory tests and mutations

The counts are bytes requested from the allocator on the test's own thread. They depend on neither
the clock nor the host load.

- `reading_a_stored_page_holds_that_page_and_not_the_snapshot` reads page two (100 rows of about
  1 KB) of a 1,000-row snapshot and of a 10,000-row snapshot. The larger read may hold at most 1.2
  times the smaller.
- `storing_a_snapshot_holds_its_rows_once` bounds storing 2,000 rows at 1.25 times what the rows
  alone hold.
- `a_new_job_list_holds_each_row_encoded_and_not_as_a_value` bounds what 600 more Jobs add to a
  first page at twice what they add to the stored document.

| Build | One page read: 1,000 / 10,000 rows | Storing 2,000 rows (rows alone: 10,880,482 B) | Job list, 600 more Jobs (stored: +538,080 B) |
| --- | ---: | ---: | ---: |
| This change | 832,302 / 844,248 B | 11,026,476 B | +733,081 B |
| Mutant: the read also holds the whole snapshot | 7,492,426 / 73,727,390 B, red | | |
| Mutant: the pass keeps every page | 6,272,687 / 55,247,321 B, red | | |
| Mutant: storing holds a `to_value` copy | | 21,906,478 B, red | |
| Mutant: the list collects its rows first | | | +3,495,576 B, red |

Strictness, place and order mutants, all red in the differential tests:

- The pass decodes pages without `StrictValue` ("a repeated name in another page's row" answered a
  page).
- The pass decodes each page on its own from its raw text ("a row too deep on the page read"
  answered a page).
- The pass skips pages instead of decoding them.
- A page's place misses its closing bracket.
- The newest-first list reads oldest first, or breaks ties by descending identity (the stored
  snapshot differed).

The source was reset to the commit after each mutant.

## 5. Soak

### 5.1 Method

- Host: macOS 27.0 (26A428), arm64, 8 cores, 16 GB. Release `arkdeck-soak`, built with
  `CARGO_BUILD_JOBS=2` and `CARGO_TARGET_DIR=/private/tmp/arkdeck-1330-rust-target`.
- Workload: the CI command with `--jobs-per-cycle 10` and `--restart-interval-seconds 1`, where CI
  uses 300. The pause only waits, as in `soak-rss-bound-run.md`.
- A driver process (not committed; the one of `soak-rss-bound-run.md`) reads each cycle's line
  and samples the live resident set. At chosen cycles it stops the soak with `SIGSTOP` between
  cycles and runs `vmmap --summary` and `heap -s`. Runs end at their own gate or with `SIGTERM`
  after cycle 300, so a run stopped at 300 skips the final verification.
- The gate compares the soak's own `getrusage` lifetime maximum resident set with cycle 1. Runs
  overlapped other measurements and builds (one-minute load 2.8–9). Free memory stayed at
  39–54%, with no memory pressure.
- Builds and their SHA-256:
  - `main` `33d30079e`: `8d69c02c…`;
  - pager only (§2.1–2.3 on `02bd0bb98`): `09a3fbeb…`;
  - pager and Job list, with a second pass over the whole file (on `02bd0bb98`): `8b37b400…`;
  - this change: `abe6a17c…`. It was measured on `6c73312e4`; rebuilt on `b4981f5f3` it is the
    same bytes, because the commits between touch only the CLI.

### 5.2 Growth

Growth in MB against cycle 1, as the gate measures it:

| Cycle | Jobs | `main` | Pager only | Pager + list | This change |
| ---: | ---: | ---: | ---: | ---: | ---: |
| 1 | 10 | 0.00 | 0.00 | 0.00 | 0.00 |
| 10 | 100 | 1.92 | 0.69 | 0.54 | 1.47 |
| 25 | 250 | 5.29 | 2.59 | 1.79 | 2.95 |
| 26 | 260 | 7.65 | 3.21 | 2.31 | 3.46 |
| 50 | 500 | 14.35 | 6.14 | 3.82 | 6.96 |
| 75 | 750 | 19.79 | 9.73 | 5.82 | 9.03 |
| 100 | 1000 | 27.23 | 12.91 | 7.26 | 10.09 |
| 124 | 1240 | 33.36 | 17.79 | 11.01 | 12.75 |
| 125 | 1250 | gate | 17.79 | 11.04 | 12.75 |
| 150 | 1500 | — | 20.94 | 13.43 | 14.17 |
| 175 | 1750 | — | 23.53 | 14.93 | 16.29 |
| 200 | 2000 | — | 26.61 | 17.40 | 19.25 |
| 225 | 2250 | — | 29.31 | 20.40 | 20.69 |
| 250 | 2500 | — | 31.72 | 20.40 | 22.50 |
| 268 | 2680 | — | 33.08 | 20.40 | 22.74 |
| 269 | 2690 | — | gate | 20.40 | 22.74 |
| 275 | 2750 | — | — | 21.35 | 22.74 |
| 288 | 2880 | — | — | 23.18 | 22.74 |
| 300 | 3000 | — | — | 23.71 | 23.43 |

Least-squares slopes in MB per cycle:

| Cycles | `main` | Pager only | Pager + list | This change |
| --- | ---: | ---: | ---: | ---: |
| 51–124 | 0.260 | 0.156 | 0.096 | 0.081 |
| 125–200 | | 0.127 | 0.090 | 0.088 |
| 201–288 | | 0.091 (to its gate) | 0.041 | 0.037 |

- `main` stops at its gate in cycle 125 with `RSS 33619968 / 33554432`.
- Bounding the pager alone is not enough: that build stops at its gate in cycle 269 with
  `RSS 33718272 / 33554432`.
- **This change reaches cycle 288 at 22,740,992 B (22.74 MB), 10.8 MB under the gate, and cycle
  300 at 23.43 MB.** The pager + list build reaches cycle 288 at 23.18 MB and cycle 300 at 23.71 MB.
- Every run holds 15 descriptors in every cycle. Between cycles the live heap is 2,984 nodes and
  261 KB, at cycle 288 of this change as at cycle 100 of `main`.
- Peak physical footprint from `vmmap`: 28.5 MB at cycle 100 of `main` and 26.3 MB at cycle 250 of
  the pager-only build, against 19.5 MB at cycle 150 and 21.6 MB at cycle 288 of this change.
- Single runs vary by a megabyte or more early on. This change sat about 3 MB above the pager +
  list build through cycle 100, then converged with it from cycle 150.

### 5.3 Where the peak went

Heap high-water mark, from `MallocStackLogging=full` and `malloc_history -highWaterMark
-allBySize`, with allocations grouped by their allocating frame (MB):

| Share at the high-water mark | Before (#2129, cycle 30, 300 Jobs) | Pager only (cycle 60) | Pager + list (cycle 60) | This change (cycle 50) |
| --- | ---: | ---: | ---: | ---: |
| High-water mark | 8.39 | 7.2 | 5.9 | 5.2 |
| Reading a stored page | 4.74 | — | 0.03 | 2.48 |
| Job list rows as values | — | 3.55 | 1.56 | — |
| The stored document being built | — | 0.59 | 1.16 | — |
| The soak's retained page (removed by #2129) | 1.68 | 0.08 | 0.02 | 0.03 |
| SQLite page cache and statements | 1.62 | 2.96 | 3.03 | 2.56 |
| Everything else | 0.35 | 0.35 | 0.35 | 0.35 |

The 4.74 MB was the whole snapshot, decoded and copied to answer page two. A cursor read now holds
one page. At cycle 50 that is 2.48 MB for a 250-row page: 1.68 MB decoded, 0.52 MB for its
canonical-length check and 0.27 MB of its bytes. The same page costs the same whatever the
snapshot's size; the unit test's 100-row page holds 0.83 MB in a 1,000-row snapshot and in a
10,000-row one. The read is the peak at cycle 50 only because the first page no longer is: the
Job list's rows as values (3.55 MB at 600 Jobs) became the first page's 250 rows and each row's
encoding.

### 5.4 What still grows

- **Apple's SQLite page cache**, filled by the repository's row check at open. The system
  `libsqlite3` sets `DEFAULT_CACHE_SIZE=2000` pages, about 8 MB, and the cache fills as the table
  grows. It stops growing near cycle 225, where the pager + list build held 20.40 MB for 45
  cycles.
- **The stored document of a new first page**: about 1.1 KB per Job. The buffer grows by
  doubling, which shows as steps; cycles 270 and 276 of the pager + list build are two of them.

After cycle 200 the gain is 0.04 MB per cycle, and what remains is bounded or about a kilobyte per
Job.

### 5.5 The hosted soak

The weekly design soak is 24 hours: 288 cycles at 300 s. A hosted job stops at six hours (this job's
timeout is 330 minutes), so reaching 288 cycles needs a shorter interval:

```
gh workflow run rust-perf.yml --ref agent/xpa-025-snapshot-pager-bounded \
  -f soak-hours=4 -f soak-restart-interval-seconds=35
```

- Per-cycle work grows with the store. For `main` here it summed to 733 s over 124 cycles (4.1 s
  per cycle over the first 48), which extrapolates to about 2,900 s over 288 cycles.
- The hosted runner did the first 48 cycles in about 2 s each (#2129's four-hour run took 302 s per
  cycle at a 300 s interval).
- At 35 s, 288 cycles take about 3.2 hours at hosted speed, or 3.6 hours at this Mac's. The soak
  then continues until four hours have passed (about 300–350 cycles) and runs its final
  verification.
- Expected result: about 23 MB of growth at cycle 288, and under about 26 MB by cycle 350, against
  33,554,432 B. No descriptor growth, and every Job terminal and verified.
- The scheduled four-hour lane at 300 s (48 cycles) stays near 7 MB.

## 6. Local targeted checks

Every command used `CARGO_BUILD_JOBS=2` and `CARGO_TARGET_DIR=/private/tmp/arkdeck-1330-rust-target`
and ran in `rust/`. The changed crates are `arkdeck-contract`, `arkdeck-platform` and
`arkdeck-hoststore`. Every workspace crate is one of them or a direct dependent of one.

- `cargo fmt --all --check`: exit 0 (`/private/tmp/arkdeck-s29-fmt5.log`).
- `cargo clippy --workspace --all-targets -- -D warnings`: exit 0 on the host, both on `6c73312e4`
  and after the last rebase (`/private/tmp/arkdeck-s29-clippy-host{4,5}.log`).
- The same with `--target x86_64-unknown-linux-gnu` and `--target x86_64-pc-windows-msvc`: exit 0
  (`/private/tmp/arkdeck-s29-clippy4-<target>.log`). After the last rebase, `-p arkdeck-cli
  -p arkdeck-platform -p arkdeck-contract -p arkdeck-hoststore` on both targets: exit 0
  (`/private/tmp/arkdeck-s29-clippy5-<target>.log`).
- `cargo clippy -p arkdeck-platform --lib --features allocation-meter` on both cross targets:
  exit 0 (`/private/tmp/arkdeck-s29-clippy4-meter-<target>.log`).
- `cargo build -p arkdeck-cli`, then `cargo test --workspace --no-fail-fast` on `6c73312e4`: exit 0,
  with 208 test targets, 1,598 passed, 0 failed and the 18 existing environment-dependent tests
  ignored (`/private/tmp/arkdeck-s29-test-workspace4.log`).
- After the last rebase, which changed only `arkdeck-cli` on `main`: `cargo test -p arkdeck-cli
  --no-fail-fast`, exit 0, with 50 targets and 312 passed (`/private/tmp/arkdeck-s29-test-cli5.log`).
- `cargo test -p arkdeck-hoststore --lib snapshot_pager -- --nocapture`: 9 passed
  (`/private/tmp/arkdeck-s29-pager-tests3.log`). `list_stream`: 2 passed
  (`/private/tmp/arkdeck-s29-list-stream2.log`).
- Mutants (§4), each exit 101: `/private/tmp/arkdeck-s29-mutation2-*.log` and
  `/private/tmp/arkdeck-s29-mutation-{list-collect,ascending-only,tiebreak}.log`.
- `rust/scripts/check-readonly.py` `assert_boundaries()`: passed. The new dependency edge is a
  dev-dependency, and the crate edges are unchanged.
- `sh scripts/check-sdd.sh`, run with the validation virtual environment: exit 0
  (`/private/tmp/arkdeck-s29-check-sdd.log`).
- Timing probe: a temporary release test, not committed, with the allocation meter installed. It
  reads page two of a snapshot of 250-row pages, median of 15
  (`/private/tmp/arkdeck-s29-timing2.log`):

  | Rows | Cursor page two: new / old | Building the snapshot: new / old |
  | ---: | ---: | ---: |
  | 1,000 | 10.97 / 7.79 ms | 4.04 / 8.24 ms |
  | 5,000 | 54.00 / 40.70 ms | 22.33 / 42.55 ms |

  A cursor read now costs 1.3–1.4 times as much: the reader deserializer is slower per byte than
  the slice deserializer, and the page is decoded twice. A first page costs half; the timing
  excludes its synchronized publication.

Not run:

- `generate-contract.py --check` and `check-contracts.py`: no contract input changed.
- Swift and App: not affected.
- The hosted soak: a `workflow_dispatch`, which the coordinating session triggers (§5.5).

## 7. CI

PR #2185, merged as `e59e5a412`: at `a0a0d2892` Agent PR 36129933234
(`open-pr`), SDD Guard 36129933215 (`guard`, `ds-tokens`) and Swift CI
36129933371 all succeeded — `plan`, the Rust host-independent checks (42 s),
the Rust workspace on macos-26 (9 min 31 s), ubuntu-latest (2 min 40 s) and
windows-latest (4 min 21 s), and the `swift` aggregate; `swift-tests`,
`ds-interactions` and `app-build` were skipped by the plan.

The hosted soak the coordinating session dispatched (§5.5; Performance lanes
run 36130214960, `workflow_dispatch`, `soak-hours=4`) succeeded. It ran the
branch head `a0a0d2892`, whose content is the merged `e59e5a412`, on macos-26
for 4 hours with a 35 s restart interval: 317 cycles, 3,170 terminal Jobs,
2,853 of them with verified Artifacts. Resident growth was 23.76 MB at cycle
288 and 24.95 MB at the end, under the fixture's 32 MiB gate; the descriptor
count stayed 19 throughout. Growth per cycle keeps falling: 0.106, 0.073 and
0.045 MB over cycles 51–124, 125–200 and 201–317 as the coordinating session
fitted them (the end points of the same windows give 0.096, 0.077 and
0.049 MB).
