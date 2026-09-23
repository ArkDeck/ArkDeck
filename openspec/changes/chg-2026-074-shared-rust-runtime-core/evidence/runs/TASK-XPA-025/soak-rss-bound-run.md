# TASK-XPA-025 — the soak's resident growth was an autorelease leak in the Session census

Change: CHG-2026-074-shared-rust-runtime-core. Branch: `agent/xpa-025-soak-rss-bound`, based on
protected `main` `55e00d50a` (#2128). macOS Runtime only; no device, no installed Runtime.

No gate, workload, interval or test changes. The 32 MiB resident-growth limit, the 16-descriptor
limit, ten Jobs per cycle, the Session publication per Job, the per-cycle whole-tree journal
verification and the final verification are exactly as before.

## 1. The failure

The four-hour soak for #2116 (run `35713299790`, job `106698847466`) stopped at its own gate:

```
ArkDeck Rust soak failed: soak resource growth exceeded: RSS 34226176 / 33554432, descriptors 0 / 16
```

Cycle 41 printed growth 33.03 MB. Cycle 42 was over the limit. The per-cycle increase went from
0.31 MB at cycle 2 to 1.21 MB at cycle 41, so total growth was superlinear in the Job count. The
descriptor count stayed at 19. The Rust soak of 2026-09-20 failed the same way at cycle 38.

## 2. Which process the gate measures

`arkdeck-soak` has no daemon or socket leg. It opens the production owners
(`JobStore`, `SessionStore`, `ArtifactReadStore` and `TargetStore`) in its own process and runs
them there. The gate reads that process's `getrusage` lifetime maximum resident set. So harness
memory and owner memory are counted together. Only heap attribution can separate them.

## 3. Method

- Host: macOS 27.0 (26A428), arm64, 8 cores, 16 GB. Release builds of `arkdeck-soak` use
  `CARGO_BUILD_JOBS=2` and `CARGO_TARGET_DIR=/private/tmp/arkdeck-1330-rust-target`. Binary
  SHA-256 values: before `71798cb4…` (`6afce0892`), calendar change only `37e7181b…`, and both
  changes `b7423757…`. Rebuilding on the rebased branch gives the same `b7423757…` bytes.
- Workload: the CI command with `--jobs-per-cycle 10` and `--restart-interval-seconds 1`, where CI
  uses 300. The pause only waits. Snapshot and Session retention depend on count and size, or on
  90 days, so they do not change within hours. Before the change, the local curve followed CI
  within about 3%: cycle 9 was 3.29 MB locally and 3.26 MB on CI.
- A driver process (not committed) started one soak and read its per-cycle line. It sampled live
  RSS with `ps` every 0.2 s. At cycles 10, 30 and 60 it stopped the process with `SIGSTOP` during
  the pause and ran `vmmap --summary` and `heap -s`.
- Stacks: `MallocStackLogging=1` (lite mode) plus `malloc_history -allBySize` for live allocations
  at cycle 20. `MallocStackLogging=full` plus `malloc_history -highWaterMark -allBySize` for the
  heap high-water mark at cycle 30.
- A thread-level probe, not committed, called each CoreFoundation-backed platform helper
  10,000 times on a fresh thread. It compared `malloc_zone_statistics` blocks before and after.

## 4. Root cause

**Live objects between cycles, before the change (`heap`):**

| Cycle | Live nodes / bytes | `CFDateComponents` | `NSDateComponents` | autorelease pool pages |
| ---: | ---: | ---: | ---: | ---: |
| 10 | 13,463 / 1,365 KB | 5,247 (984 KB) | 5,247 (82 KB) | 11 (44 KB) |
| 30 | 94,544 / 9,916 KB | 45,747 (8,578 KB) | 45,747 (715 KB) | 92 (368 KB) |

Only these classes grow: exactly 40,500 of each between cycles 10 and 30. The count equals
P(P+1)/2 + 2P − 3, where P is the number of published Sessions. It is quadratic.

**Allocation site.** These are the lite-mode stacks of the 19,701 live objects at cycle 20. Rust
frames are shown without their hashes:

```
SessionPublisher::attempt → SessionStore::publication_status → locked_storage
→ session_inventory::inventory → expiry closure → arkdeck_platform::host_gregorian_add_days
→ CFCalendarDecomposeAbsoluteTime → Foundation _NSSwiftCalendar._components(_:from:)
→ DateComponents._bridgeToObjectiveC() → -[NSDateComponents init] → CFDateComponentsCreate
```

Foundation serves `CFCalendarDecomposeAbsoluteTime` with an autoreleased date-components object.
A Rust thread has no autorelease pool of its own. Each object therefore waits for the thread to
exit. The soak's main thread does not exit, and neither does any long-lived owner thread.

The probe shows two leaking helpers. `host_gregorian_add_days` and `host_gregorian_timestamp`
each keep +20,020 blocks and +2,161,920 bytes per 10,000 calls: two blocks and 216 bytes per call.
The other helpers do not accumulate. `host_gregorian_seconds` and `host_canonical_text` keep 0
blocks. `host_legacy_iso8601` and `host_control_character` keep +2 blocks once.

**Why quadratic.** Every publication reconciles the census. The census re-derives the expiry of
every Session already in the tree, with one `host_gregorian_add_days` each. Registration then
makes three more calendar calls. Publication p therefore leaks p + 2 objects. At cycle 42
(P = 420) that is about 89,000 objects, or roughly 20 MB of the 33 MB growth. The rest comes from
the per-cycle peak and from free pages around the leaked objects. At cycle 30 the zone was 55%
fragmented: 9.9 MB allocated, 21.5 MB dirty.

## 5. Changes

1. `rust/crates/arkdeck-platform/src/host_calendar.rs`: each of the three calendar helpers now runs
   inside its own autorelease pool, using `objc_autoreleasePoolPush` and `objc_autoreleasePoolPop`
   from libobjc. The guard is declared first, so it pops last and on the same thread. Nothing
   autoreleased escapes the call. The helpers return a Rust `String` or `f64`, and their answers
   do not change. This is a production fix: any Rust thread that publishes Sessions over time
   leaked in the same way.
2. `rust/crates/arkdeck-soak/src/lib.rs`: `rows()` keeps only `(jobId, state)` from each page.
   Those two fields are all the soak reads. Previously it kept a clone of every history row while
   the owner served the next page. The calls, their order and every check are unchanged. The only
   stricter rule is that every row must now carry both fields. The final verification already
   required that.
3. Regression test `rust/crates/arkdeck-platform/tests/host_calendar_autorelease.rs`. Each helper
   runs on a fresh thread: first an unmeasured warm-up batch of 10,000 calls, then two measured
   batches of 10,000 calls each. The second measured batch must keep fewer than 100 heap blocks,
   below one block per hundred calls.
   - A cache filled on first use does not come back in a later batch.
   - Anything a call keeps grows again with every batch. Before the fix, the leaking helpers kept
     20,020 blocks in each batch.
   - The failure message reports both batches, so a failing run shows which case it is.
   - The file holds one test, so no other test allocates while it counts.

   The first commit measured a single batch after one warm-up call, with a bound of 1,000 blocks.
   On macOS 26 CI that shape failed (§9).

## 6. After

**Live objects between cycles, both changes:** 2,959 nodes and 259 KB at cycles 10, 30 and 60. The
counts match exactly. There are no date components, and there is one pool page.

**Resident-set curve** (MB; growth is measured against the cycle-1 baseline, as the gate does):

| Cycle | Jobs | Before: max RSS / growth | Calendar fix: max RSS / growth | Both changes: max RSS / growth | Both: live RSS between cycles | State bytes |
| ---: | ---: | ---: | ---: | ---: | ---: | ---: |
| 1 | 10 | 13.45 / 0.00 | 13.17 / 0.00 | 13.12 / 0.00 | 13.07 | 0.47 |
| 10 | 100 | 17.27 / 3.82 | 15.70 / 2.52 | 15.38 / 2.26 | 14.89 | 5.52 |
| 20 | 200 | 23.33 / 9.88 | 17.66 / 4.49 | 17.60 / 4.47 | 16.66 | 13.00 |
| 25 | 250 | 27.15 / 13.70 | 18.96 / 5.78 | 18.71 / 5.59 | 17.55 | 16.94 |
| 26 | 260 | 30.61 / 17.15 | 21.22 / 8.04 | 20.40 / 7.27 | 19.19 | 17.73 |
| 30 | 300 | 34.01 / 20.56 | 22.25 / 9.08 | 21.33 / 8.21 | 19.94 | 20.89 |
| 40 | 400 | 44.25 / 30.80 | 24.40 / 11.22 | 23.67 / 10.55 | 21.84 | 28.78 |
| 42 | 420 | 46.63 / 33.18 | 24.94 / 11.76 | 24.10 / 10.98 | 22.17 | 30.36 |
| 43 | 430 | **gate: 34.42** | 25.17 / 11.99 | 24.41 / 11.29 | 22.43 | 31.14 |
| 48 | 480 | — | 26.23 / 13.06 | 25.59 / 12.47 | 23.40 | 35.10 |
| 50 | 500 | — | 27.12 / 13.94 | 26.71 / 13.58 | 24.41 | 36.67 |
| 51 | 510 | — | 28.79 / 15.61 | 26.92 / 13.80 | 24.58 | 37.47 |
| 60 | 600 | — | 30.77 / 17.60 | 29.05 / 15.93 | 26.30 | 44.57 |
| 65 | 650 | — | 31.87 / 18.69 | 30.28 / 17.15 | 27.31 | 48.51 |
| 70 | 700 | — | — | 31.44 / 18.32 | 28.25 | 52.46 |

- Before: the local run failed at cycle 43 with `RSS 34422784 / 33554432`, which reproduces CI.
- Calendar fix only: 65 cycles and the final verification completed, exit 0. Final growth was
  18.76 MB; there were 650 terminal Jobs, 585 with verified Artifact evidence, and no debt.
- Both changes: 70 cycles and the final verification completed, exit 0. Final growth was 18.35 MB;
  there were 700 terminal Jobs, 630 verified, no descriptor growth and no debt. The final
  verification added 0.03 MB at 700 Jobs.
- The soak change removes the step at the third page: +1.67 MB at cycle 51 before it, +0.22 MB
  after. The second-page step at cycle 26 shrinks from +2.26 MB to +1.68 MB.

## 7. What still grows, and the four-hour extrapolation

The retained heap is flat, but the peak inside a cycle still grows linearly. At 300 Jobs,
calendar fix only, the process heap high-water mark was 8.39 MB (`-highWaterMark`). It was in
`collect → rows → job.list`, reading page two from the stored snapshot:

| Share at the high-water mark | MB |
| --- | ---: |
| `SnapshotPager::read`: whole snapshot bytes, strict parse of every page, a `Value` copy and canonical bytes | 4.74 |
| the soak's retained page-1 rows (removed by change 2) | 1.67 |
| SQLite page cache (`pcache1Alloc`) filled by the reopened Job repository's row check; bounded by SQLite's default cache size | 1.61 |
| everything else | 0.37 |

`inspect_tree` and `inspect_journal` have no allocation at the peak. They read one journal at a
time. The per-cycle whole-tree journal verification therefore does not drive the growth. Q10
(verify only at the end, as the Swift fixture does) is not needed, and nothing about it changed.

The remaining linear term comes from the owners' full materialization in `SnapshotPager`. The first
page of `job.list` builds every row as a `Value`, a `serde_json::to_value` copy and canonical bytes.
Every cursor page parses and copies the whole stored snapshot. The Session census also keeps one
manifest summary per Session.

Both changes fitted over cycles 51–70 give 0.24 MB per cycle, with small steps at page boundaries.

- **The four-hour lane**: the hosted run took 302 s per cycle, so four hours is 48 cycles and
  480 Jobs, followed by the final verification. Growth is 12.47 MB locally at cycle 48. Before the
  change, CI growth stayed within about 3% of local (cycle 41: 33.03 MB on CI, 32.00 MB locally).
  The final verification adds less than 0.1 MB. The expected result is about 13 MB against
  33.55 MB, which should pass with about 20 MB of margin.
- Linear extrapolation reaches the gate near cycle 133, about 1,330 Jobs or about 11 hours at
  300 s. At this workload the design's 24-hour weekly soak (288 cycles) would still exceed 32 MiB.
  It needs the next cut below, not a new limit.

**Next cut (not in this change).** Page `SnapshotPager` in bounded memory without changing its
stored format or validation:

- For a cursor read, deserialize the pages as borrowed `RawValue` slices. Then strictly parse and
  bound-check one page at a time, and keep only the requested page.
- For the first page, stop holding the whole history twice (`rows` plus `to_value`).

Both changes preserve the stored snapshot bytes. They are shared by every snapshot-paged list, so
they need their own tests and review.

## 8. Local targeted checks

`CARGO_BUILD_JOBS=2`, `CARGO_TARGET_DIR=/private/tmp/arkdeck-1330-rust-target` and
`--manifest-path rust/Cargo.toml` were used for every check. They ran on the rebased tree (`main`
`55e00d50a` plus this change).

- Before the fix, the probe showed `host_gregorian_add_days` and `host_gregorian_timestamp` each
  keeping +20,020 blocks per 10,000 calls. Log: `/private/tmp/arkdeck-s6-probe-autorelease.log`.
- `cargo test -p arkdeck-platform --test host_calendar_autorelease`, single-batch form of the first
  commit: exit 0. Two mutants each failed with exit 101 and the message "kept 20020 heap blocks
  after 10000 calls": one without the add-days pool and one without the timestamp pool. The source
  was restored by checksum. Logs: `/private/tmp/arkdeck-s6-calendar-test.log` and
  `-calendar-mutant-{adddays,timestamp}.log`.
- Batch form of the follow-up commit, on macOS 27 (26A428):
  - Five local runs with `--nocapture`, exit 0 each. Every helper reported "0 then 0 heap blocks
    per 10000 calls" in all five runs. Logs: `/private/tmp/arkdeck-s6b-calendar-run{1..5}.log`.
  - Pool-removal mutants. The source was restored by checksum after each one. Logs:
    `/private/tmp/arkdeck-s6b-calendar-mutant-{adddays,timestamp,seconds}.log`.
    - Add-days pool removed: exit 101, "kept 20020 and then 20020 heap blocks per 10000 calls".
    - Timestamp pool removed: exit 101, with the same numbers.
    - Seconds pool removed: exit 0, 0 then 0 blocks. `CFCalendarComposeAbsoluteTime` autoreleases
      nothing on this OS, as the probe showed. That pool is defensive, and this test cannot prove
      it here.
  - `cargo fmt --all --check`: exit 0.
  - `cargo clippy -p arkdeck-platform --all-targets -- -D warnings`: exit 0.
  - `cargo test -p arkdeck-platform --no-fail-fast`: exit 0, with 18 targets, 161 passed and
    4 ignored.
  - Logs: `/private/tmp/arkdeck-s6b-{fmt,clippy,platform-tests}.log`.
- `cargo fmt --all --check`: exit 0. Log: `/private/tmp/arkdeck-s6-fmt.log`.
- `cargo clippy -p arkdeck-platform -p arkdeck-hoststore -p arkdeck-provider-hdc
  -p arkdeck-provider-workspace -p arkdeck-client -p arkdeck-cli -p arkdeck-agentd -p arkdeck-soak
  --all-targets -- -D warnings`: exit 0, covering the changed crates and every direct dependent of
  `arkdeck-platform`. Log: `/private/tmp/arkdeck-s6-clippy.log`.
- `cargo build -p arkdeck-cli`, the process-test prerequisite, then `cargo test` of the same eight
  crates with `--no-fail-fast`: exit 0. That was 144 test targets: 1,136 passed, 0 failed and
  18 existing environment-dependent tests ignored. No fake HDC server was left behind. Logs:
  `/private/tmp/arkdeck-s6-cli-build.log` and `/private/tmp/arkdeck-s6-tests.log`.
- `sh scripts/check-sdd.sh`, run with the validation virtual environment: exit 0, with 0 errors and
  0 warnings. Log: `/private/tmp/arkdeck-s6-sdd.log`.
- Soak runs:
  - Before, calendar fix and both changes: exit 1 at cycle 43, exit 0 after 65 cycles, and exit 0
    after 70 cycles.
  - Driver logs: `/private/tmp/arkdeck-s6-{base1,fix1,fix2}.log`.
  - Cycle series, `vmmap`, `heap` and `malloc_history` reports were kept in the session scratch
    directory. They are not committed.

Not run:

- `generate-contract.py --check`: no contract input changed.
- Swift, App and the full local gate: not affected, and the policy does not run them locally.
- The four-hour soak: it is a `workflow_dispatch`, a maintainer or coordinator action.

## 9. CI

PR #2129. The soak lane runs only on dispatch or the Sunday 03:00Z cron. A skipped soak job is not
a pass. The dispatch for this branch:

```
gh workflow run rust-perf.yml --ref agent/xpa-025-soak-rss-bound -f soak-hours=4
```

This uses the default 300 s interval, which is the weekly lane's definition.

- On `bcbef6936`, the first commit:
  - SDD Guard `35873441568` passed.
  - In Swift CI `35873441947`, the host-independent Rust job and the ubuntu and windows workspace
    jobs passed. The macOS 26 workspace job (`107223255607`, image `macos-26-arm64`) failed in this
    test: "host_gregorian_add_days kept 1109 heap blocks after 10000 calls" against the bound of
    1,000. Cargo stops at the first failing target, so later targets did not run in that job.
  - An undrained call would have kept 20,020 blocks, so the pool works on macOS 26 as well.
  - A single batch cannot tell a cache filled on first use from a small per-call leak. That is
    why the follow-up commit changes only the test, to the batch form of §5.3. If macOS 26 also
    keeps blocks in the second measured batch, that is a per-call leak there, and it goes to the
    maintainer with those numbers. The bound is not raised for it.
- The coordinating session dispatched the four-hour soak on `bcbef6936`: run `35873673934`. The
  follow-up commit touches only this test and this record, so the soak binary is unchanged.
- On `04295eb90`, the final head (the batch-form test and this record):
  - SDD Guard `35877685742` passed (`guard`, `ds-tokens`); Agent PR `35877685750` passed.
  - Swift CI `35877685921` passed: Rust host-independent checks, the Rust workspace on
    ubuntu-latest, macos-26 (job `107237852331`) and windows-latest, and the `swift` aggregate.
    `swift-tests`, `app-build` and `ds-interactions` were skipped by the plan; a skipped job is not
    a pass.
  - In the macos-26 job, `calendar_calls_drain_what_they_autorelease` passed. Its figures are
    captured when it passes, so the log shows that each function's second measured batch kept fewer
    than 100 blocks there (`CALLS / 100`), not how many.
- The four-hour soak `35873673934` (Performance lanes, `workflow_dispatch` on `bcbef6936`; job
  `soak` `107224030697`, 14:22–18:24Z) succeeded: 48 cycles and 480 Jobs, all terminal, 432 with
  verified Artifacts. The last cycle's RSS growth was 11,780,096 bytes (11.78 MB) against the
  32 MiB gate (33,554,432 bytes), and the descriptor count was 19 in every cycle.
- The maintainer merged #2129 by hand at 2026-09-23T16:03:58Z, on `04295eb90` and before the soak
  concluded: `7d6382c9e` on main.
