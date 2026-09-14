# Remaining macOS Rust implementation

Updated 2026-09-14 against protected main `7cebb912` (#1938), revision 11. This list tracks
implementation and review, not published activation or hardware acceptance. Windows product work
and real-device acceptance are outside this goal.

## Dashboard (update on every merge)

| Methods on the standalone Rust daemon | Operations executable in Rust | Golden Journeys on Rust | App facades on ClientKit | CLI leaves on Rust | Swift targets deleted |
| --- | --- | --- | --- | --- | --- |
| 60 / 105 (installed facade serves 3 locally) | 3 / 30 (`analyzer.extract-crash-signature@1`, `observe.device@1`, `capture.diagnostics@1`) | 0 / 5 | 0 / 13 | 63 / 256 | 0 / 6 |

How each number is measured: the method count is the set of literal method names in the
`handle_frame` match of `rust/crates/arkdeck-control/src/lib.rs` that answer natively (not the
`rejected` default arm); the operation count is the Catalog operations the isolated Rust daemon
plans, admits and runs end to end; Golden Journeys count `REAL_DEVICE_PASS` records on the pure Rust
daemon (`docs/design/references/single-v1/gj-headless-rerun-<date>-xpa0NN.json`); facades count the
13 App-facing facades of `ArkDeckWorkflows` switched to `ArkDeckClientKit`; CLI leaves count the
canonical command names of the Rust CLI (`rust/crates/arkdeck-cli/src`, until it serves
`arkdeck commands --output json`) that are `feature`s of the 256 entries of
`openspec/contracts/cli-feature-coverage.json`; Swift targets count the six targets TASK-XPA-017
deletes.

## Milestones (design §G.1 r11)

| Milestone | Golden Journey | Delivers | Lane | State |
| --- | --- | --- | --- | --- |
| M1 | GJ-1 | `observe.device@1`, `capture.diagnostics@1`, `agent.*` with HAR, `human-action.*`, `target.adopt/availability`, `runtime.hdc.*`, restart carry-over | A (+ B for the executor) | in progress: SPK-6 and SPK-7 passed; `observe.device@1` (#1920), `capture.diagnostics@1` (#1938), `agent.run/status` and `artifact.list` (#1932, CLI #1935), the Rust daemon dispatching HDC through `ProcessDispatch` (#1933); remaining: `agent.list/abandon`, HAR with `agent.resume` and `human-action.*`, `target.adopt/availability`, `runtime.hdc.*` on the executor primitives (#1930, #1931) |
| M2 | GJ-2/3 | Artifact publication and import commit, capability mint/reserve/consume, `debug.*`, `deploy.native-library.app-owned@1`, `capability.*`, `cleanupDebt.*` | A (+ B) | after M1; the `debug.hap@1` and `deploy.native-library.app-owned@1` T0 oracles are recorded (#1924) |
| M3 | GJ-5 | 13 `workspace.*` operations, `workspace.preset/project.*`, registered toolchain, hap-sign-tool, Keychain | D | after SPK-10 |
| M4 | GJ-4 | ArkForge lane through `arkforge-client`, `flash.*`, Rockchip probes, DEC-016 recovery epoch | A + D | lane B's Rockchip pieces are in: live-mode probe (#1934), post-flash HDC observation (#1936), Loader transition (#1937); the alias store's host primitives, Swift oracle and Rust store are open (#1939, #1940, #1941); the ArkForge lane and `flash.*` wait for SPK-9 and the §L.1 item 13 ruling |
| M5 | cutover | G.4 preflight, LaunchAgent to the standalone Rust binary, deletions, DMG, lock and traceability flip (TASK-XPA-017) | all | after 018, 019, 025 |

## Tasks

| Task | Status | Submitted/current result | Necessary remaining capability |
| --- | --- | --- | --- |
| XPA-012 | in-progress | Isolated Rust owners for History, Session, Trace cache, Bootstrap, DevEco/HDC registration, tool/bundle registry, Target queries; facade History filter owner (#1888); owner locks unlock on drop (#1903) | tool selection writes, trace database preparation; installed per-store composition withdrawn (r11) — activation only at M5 |
| XPA-013 | in-progress | Artifact read library, inspect/read/export, durable Import begin/append/abort/inspect (#1881) | commit/publication, release, inspection, leases, quota, active-use/release, GC — inside M2 |
| XPA-014 | in-progress | v1 SQLite reads, journal/index/record writers, the analyzer's plan/submit/run/result/evidence/cancel (incl. running) and Session publication (#1889–#1900); `capability.list/inspect` reads (#1909); `observe.device@1` (#1920), `agent.run/status` and `artifact.list` (#1932), map-valued contract members (#1929), `capture.diagnostics@1` (#1938); the M1/M2 T0 oracles (#1918, #1921, #1924, #1925) | M1 → M2 → M3 → M4 as above; recovery after the §L.1 item 13 ruling |
| XPA-015 | ready (r11) | HDC observation/parsers and process foundation | SPK-10, then M3; the three ArkTrace/hilog analyzers after M4 |
| XPA-016 | in-progress | SPK-6 complete (#1914, #1915, #1917, #1919; lease scan #1926, `ProcessDispatch` #1928, managed server #1930, lifecycle executor #1931); M4 Rockchip live-mode probe (#1934), post-flash HDC observation (#1936), Loader transition (#1937); alias-store primitives, oracle and store open (#1939–#1941) | the M1/M2 provider families as their methods land; M4's ArkForge-served ports after SPK-9 |
| XPA-018 | in-progress | 63 Rust CLI leaves (`agent run/status`, `artifact list` with #1935) | remaining leaves continuously (lane C); Swift CLI retirement with M5 |
| XPA-019 | ready (r11) | no ClientKit target; 13 App-facing facades | SPK-8, then the facades one by one; hard prerequisite of M5 |
| XPA-025 | ready (r11) | Swift performance baseline; merge-lane micro-benchmarks retired (#1902) | SPK-11, then the Rust soak fixture and the lanes on the Rust daemon |
| XPA-017 | blocked | — | M5 |

Spikes SPK-6..11 are defined in `tasks.md` and design §J.3; their records land under
`runs/<task>/spk-N-run.md`. The decision package for design §L.1 item 13 is
`adr-0009-decision-package-20260914.md` in this directory.

## History

2026-09-14 (`7cebb912`): 29 commits since the r11 dashboard (`5e63eb19`): lane A's #1918, #1920,
#1925, #1929, #1932, #1933, #1935, #1938; lane B's #1914–#1931 (SPK-6) and #1921, #1924 (oracles),
#1934, #1936, #1937 (M4); CI trims #1902, #1904, #1905, #1907, #1912. The dashboard row above is
remeasured on this head: methods by the `handle_frame` literals, operations by the three
Catalog operations the isolated Rust daemon runs end to end, CLI leaves by the Rust CLI's
canonical names against the coverage file.

2026-09-12 (`f92acd36`): Bundle PR #1862 merged. Job/Artifact PR
[#1863](https://github.com/ArkDeck/ArkDeck/pull/1863) merged after its full local gate, actual
Swift-fixture process checks and required latest-head CI passed. Cleanup apply, target display
names, Artifact export and upload, and Job events were prepared in isolated worktrees. The original
signed Library Bundle capture validation was previously refused by automatic approval review; its
exact native positive tests remain unexecuted, and unsigned fixtures do not replace them.
