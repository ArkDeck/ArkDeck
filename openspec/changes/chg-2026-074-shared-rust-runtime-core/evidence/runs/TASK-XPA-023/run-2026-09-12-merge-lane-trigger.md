# TASK-XPA-023 — run record (lane trigger and cache repair after `done`)

Change: CHG-2026-074-shared-rust-runtime-core. Acceptance: XPA-AC-5. Host
measurement lanes only — not hardware, platform or conformance evidence
(POL-VERIFY-001, POL-MODE-001). No device was contacted.

The task is `done`; this record covers three repairs to the delivered lanes in
`.github/workflows/rust-perf.yml`, all inside the task's Allowed paths, after
the CI cost review of the 30 merges #1844..#1873 (2026-09-10 23:19 to
2026-09-12 11:19 UTC; 205 workflow runs read through the Actions API per job
and step).

## Findings

| # | Finding | Measurement |
| --- | --- | --- |
| 1 | The micro-benchmark lane ran on every agent-branch push that touched the measured sources, for an advisory verdict that never gates | 34 `microbenchmarks` jobs, 185 of the 856 runner-minutes the 30 merges cost, the largest single item; 20 of the 34 builds were no-ops (under 1 minute) followed by the fixed 1.8-minute capture, 10 were release rebuilds of 5 to 11 minutes after a `Packages/ArkDeckKit/Sources/**` change |
| 2 | Every push held 4 or 5 of the 5 concurrent macOS jobs a Free-plan organisation has (`/orgs/ArkDeck` reports `plan: free`), so overlapping pushes queued each other's merge-gate lanes | 16 of 34 pushes used 5 macOS jobs at once; on 2026-09-11 06:53–07:10 UTC three branches pushed within six minutes and their `swift-tests`, `app-build` and Rust macOS jobs queued 3.3 to 9.2 minutes; #1855's Swift CI took 14.1 minutes and its perf run 21.5 |
| 3 | The release SwiftPM cache was keyed without the runner image build, so a restore on the other image build of a rollout recompiled every C unit | 257 C compiles (BoringSSL, NIO shims, Citadel) in the `microbenchmarks` build step of #1854, #1858 and #1859's main runs, about 1.5 minutes each; 0 on same-image restores; the mechanism is recorded in `swift-ci.yml`'s `swift-tests` job (#1853) |

## Repairs

- `microbenchmarks` runs on pushes to `main` only (`github.ref ==
  'refs/heads/main'`). The merged tree is measured with the same ratio mode
  and +20% threshold; the signal arrives one step later and no longer
  competes with the merge gates. A branch can still be measured by hand with
  `python3 -m bench capture` per `scripts/bench/README.md`.
- `harness-tests` runs on `ubuntu-latest`. The suite is pure Python; its one
  Darwin clock assertion skips itself on other platforms
  (`test_the_two_roles_do_not_collapse_onto_one_clock_on_darwin`), and
  `harness.py` falls back from `platform.mac_ver()` to `platform.release()`.
- The release SwiftPM cache key of `microbenchmarks`, `nightly` and `soak`
  names the runner image build read from `$ImageVersion` in a `Record the
  runner image build` step, with a same-toolchain fallback as the last restore
  key, the same shape `swift-ci.yml` adopted in #1853. The key family stays
  `perf-v1` so existing entries remain reachable through that fallback.

## Verification

- `ruby -ryaml` parses the workflow; the three jobs carry the record step
  before their restore step; no un-keyed `perf-v1` line remains.
- `python3 -m unittest discover -s bench -t .` passes locally on macOS
  (the Darwin assertion runs here); the branch push of this change runs the
  same suite on `ubuntu-latest` and shows `microbenchmarks` skipped off
  `main`.
- Expected effect: per push, 1 to 2 fewer macOS jobs and no advisory build;
  per Swift-touching merge, about 5.4 macOS-minutes less on average; a new
  image build costs the C rebuild once instead of on every cross-image
  restore. The first `main` run after this merges writes the image-keyed
  entry; the run after it is the first that can hit it.
