# TASK-XPA-025 — the first Rust soak run, and the per-cycle line it needed

Change: CHG-2026-074-shared-rust-runtime-core@r11. Slice: the weekly soak lane ran on the Rust
daemon for the first time and stopped at its own resource gate. This slice records that run, gives
`arkdeck-soak` the per-cycle resident-set line the Swift fixture has and the Rust one lacked, and
sets out what the growth is and is not, for the maintainer to rule on.

No gate is changed. The 32 MiB resident-growth limit and the 16-descriptor limit are existing hard
gates (design §I.1); this slice only measures against them. No device and no installed Runtime were
touched.

## 1. The run that failed

Dispatched by the coordinating session at 2026-09-20T07:18:30Z on `65b2a073`, four hours requested:
run `35496513810`.

| Step | Result |
| --- | --- |
| Toolchain, then `cargo build --locked --release -p arkdeck-agentd -p arkdeck-soak` | success |
| Run the Runtime soak | **failure** after 3 h 08 m (07:19:28Z → 10:27:40Z) |
| Archive the soak metrics, Summary | success; the archive step runs `if: always()` |

```
ArkDeck Rust soak failed: soak resource growth exceeded:
RSS 34422784 / 33554432, descriptors 0 / 16
```

The archived metrics, at cycle 38 and 11,185 s elapsed, beside the last Swift soak of the same lane
(run `34746531597`, 2026-09-13, four hours, completed):

| Field | Rust, cycle 38 | Swift, cycle 46 |
| --- | ---: | ---: |
| terminal Jobs | 379 | 460 |
| max resident set, first cycle → last | 12.47 → 46.89 MB | 27.98 → 35.60 MB |
| growth against the 32 MiB (33.55 MB) gate | **34.42 MB, over by 0.87 MB** | 7.62 MB |
| open descriptors, first → last | 19 → 19 | 11 → 11 |
| state files / bytes | 3,679 / 27.20 MB | 2,583 / 10.95 MB |
| state bytes per Job | 71.8 KB | 23.8 KB |
| journals | 759 | 460 |
| journals per Job | 2.0 | 1.0 |
| outstanding cleanup debt | 0 | 0 |

Nothing else failed in the Rust run: no torn journal, no unresolved intent, no descriptor growth, no
cleanup debt. The fixture stopped itself at its own gate, which is the gate working.

## 2. What this slice adds

`arkdeck-soak` now prints its resource state on every cycle, as the Swift fixture prints `rssBytes=`:

```
Rust soak cycle=12 jobs=120 active=1 recovered=1 rssBytes=18317312 \
rssGrowthBytes=5373952 fdCount=15 stateBytes=6874154 simulatedProvider=true
```

Without it, a failed gate reports one number at the end and no series, and a reader cannot tell a
leak from a peak that grows with the store. The growth, the descriptor count and the state size
travel on the same line because they are what the gate compares and what it plausibly scales
against. The metrics document is unchanged; this is stdout only, which design §G.1's tier 2 leaves
free.

The soak job also takes a dispatch-only `soak-restart-interval-seconds` input, default 300, so that
a diagnosis dispatch can reach a cycle count in minutes rather than hours. The weekly schedule is
unchanged: it passes no input and keeps 300 s.

## 3. What the growth is

A local run on the instrumented binary, stopped at cycle 32 when the maintainer wound the host down,
with a 5-second interval on a busy host. The gate is not reached here; the series is the point.

| Cycle | Jobs | max RSS | growth | descriptors | state bytes | growth / state |
| ---: | ---: | ---: | ---: | ---: | ---: | ---: |
| 1 | 10 | 12.94 MB | 0.00 MB | 15 | 0.47 MB | 0.00 |
| 6 | 60 | 15.04 MB | 2.10 MB | 15 | 3.04 MB | 0.69 |
| 10 | 100 | 16.94 MB | 4.00 MB | 15 | 5.52 MB | 0.72 |
| 14 | 140 | 19.79 MB | 6.85 MB | 15 | 8.32 MB | 0.82 |
| 20 | 200 | 24.56 MB | 11.62 MB | 15 | 13.01 MB | 0.89 |
| 26 | 260 | 32.06 MB | 19.12 MB | 15 | 17.73 MB | 1.08 |
| 32 | 320 | 38.22 MB | 25.28 MB | 15 | 22.47 MB | 1.13 |

- The resident set climbs with the store, roughly one byte per byte of accumulated state, and the
  ratio drifts up rather than flattening.
- Descriptors do not move: 15 for 32 cycles here, 19 for 38 cycles on CI.
- `vmmap -summary` on the running process at cycle 15 put the resident growth in the malloc heap
  (`Malloc Small` 9,136 KB resident, `Malloc Small (empty)` 880 KB), not in file-backed regions.
- `maxResidentSetBytes` is `getrusage`'s lifetime maximum, so the metric only ratchets upward. A
  workload whose per-cycle peak scales with the store will therefore reach any fixed growth limit
  eventually; the gate's question is when.

Two mechanical differences from the Swift fixture explain why the Rust store, and with it the
per-cycle peak, grows faster. Both sit in the fixture, not in a runtime leak.

1. **The Rust soak publishes a Session for every Job; the Swift fixture publishes none.** The Swift
   fixture's source contains no Session code at all, while the Rust one wires a `SessionPublisher`
   into both the runner and the canceller, as production does. In a local state root at 200 Jobs
   that is 203 Job journals plus 202 Session journals, and 4,242 files under `sessions/` out of
   5,826 in the tree. Hence 2.0 journals and 71.8 KB of state per Job against Swift's 1.0 and
   23.8 KB.
2. **The Rust soak verifies every journal in the tree on every cycle.** `run_workload` calls
   `inspect_tree(root, true)` inside the loop; the Swift fixture calls `verifyJournalIntegrity` once
   after the loop. So the Rust fixture's own accounting is O(store) per cycle and its per-cycle peak
   rises as the store does.

## 4. What this does not establish

- It does not establish a leak. Descriptors are flat, the growth tracks the store, and no cycle
  fails to release: `maxResidentSetBytes` cannot fall, so this series cannot show a release even if
  one happens. A current-RSS series would settle that and is not what the gate reads.
- It does not establish that the Rust owners hold more memory than the Swift ones for the same work.
  The two fixtures do not do the same work per Job, as §3 shows.
- The local run above is a 5-second-interval run on a loaded host, stopped early. It is a shape, not
  a measurement of the hosted lane.

## 5. For the maintainer

The soak lane is red on the Rust daemon, and TASK-XPA-025's acceptance needs all three lanes green
before TASK-XPA-017. The options, with no recommendation acted on here:

1. **Re-scale the gate.** The 32 MiB growth limit comes from the Swift fixture's workload. Applied to
   a fixture that also publishes a Session per Job, it bounds a different program. A limit expressed
   against the accumulated state, or a larger absolute number, would need the maintainer's number.
2. **Align the fixture's accounting with Swift's**: verify journals once after the loop rather than
   on every cycle. This removes the O(store) per-cycle work. It also removes the early warning that
   per-cycle verification gives, though both fixtures still refuse a torn tail before they finish.
3. **Bound what the soak accumulates**, by pruning published Sessions or Artifacts during the run, so
   the per-cycle peak stops tracking a store that only grows.

Options 2 and 3 change what the soak exercises, which is why this slice does neither.

To get the full curve up to the gate, dispatch the soak with the new input, for example
`soak-hours=1` with `soak-restart-interval-seconds=30`: the failing run took 303 s per cycle, almost
all of it the 300-second pause, so a 30-second interval reaches the same 38 cycles in well under an
hour. The run will still stop at the gate; the point is the series the new line prints on the way.

## 6. Local targeted checks

Under the 2026-09-19 policy (#2015) the PR's CI is the unified gate. The maintainer is winding this
host down, so nothing beyond the crate's own checks ran here.

| Check | Command | Result |
| --- | --- | --- |
| Soak crate lint | `CARGO_BUILD_JOBS=2 cargo clippy --offline --locked -p arkdeck-soak --all-targets -- -D warnings` | exit 0 |
| Soak crate tests | `CARGO_BUILD_JOBS=2 cargo test --offline --locked -p arkdeck-soak -- --test-threads=1` | exit 0, 4 tests |
| Formatting | `cargo fmt -p arkdeck-soak` | applied, no further diff |
| Workflow parses; the dispatch inputs and the soak step's environment are as intended | `python3 -c "import yaml; …"` with the SDD virtual environment | exit 0 |
| SDD consistency | `ARKDECK_PYTHON=<repo>/.venv-sdd/bin/python sh scripts/check-sdd.sh` | exit 0, 0 errors, 0 warnings |

## 7. CI

Pushed to `agent/xpa-025-soak-growth-20260920`; the Agent PR workflow opens the pull request.
The PR number, run ids and conclusion are appended by the slice that follows it, as the 2026-09-19
policy allows.
