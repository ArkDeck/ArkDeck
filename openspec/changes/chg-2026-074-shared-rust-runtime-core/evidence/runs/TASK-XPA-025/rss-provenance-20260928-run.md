# TASK-XPA-025 — RSS observation provenance repair, 2026-09-28

This implementation fixes an actual collection defect: filtering missing RSS
reads could turn `[100, missing, 40]` into two adjacent values and falsely infer
a qualifying release. Original attempt indices now constrain adjacency; the
25% drop threshold, largest qualifying drop selection, sampling delay and fixed
idle window remain unchanged. An idle-window record ties samples to the new
post-health daemon, and owned-child liveness is checked before and after each
resource read. An exited child causes failure; invalid observations are archived
but not accepted as measurements. All-missing RSS leaves both phases unmeasured.

The phase identity is `observed-release-v3`. Existing comparison rules refuse
RSS v2/v3 mixing; the version does not change other metrics' scale. Raw gap
indices and missing counts remain run evidence, not workload inputs. No source
under Rust Runtime, CLI, App, Catalog, signing, credentials or protocol changed.

## Evidence retained and current scope

This is a collector repair, not a new performance capture or a stable-baseline
claim. Replay of all three original RSS series in the
[formal-scale archive](formal-scale-20260927/README.md) still finds no release.
Its 1,635 observations, cold-start outlier, nine stable metrics, 16 gaps and
`baselineEligible: false` remain unchanged. Previously archived interrupted and
unstable captures are retained. Existing real Rust 10k Journal / 10k History
recovery evidence is not replaced by this replay or by cold-start timing.

Per the user's 2026-09-28 scope decision, 24-hour soak and its retries/power-window
wait are removed from the current macOS delivery's remaining work. Both ABORTED
histories remain intact (`adk24h.x9a5uvr3`, `adk24h.esgwtrw5`); their durations are
not combined or relabeled PASS. The general test implementation and acceptance
standards remain. This decision neither completes G5/G7 nor adopts a baseline.

## Local targeted checks

From an independent `agent/xpa-025-rss-sample-provenance` worktree based on main
`b441c8a2337103265fe1d57d3e4b9fd5637135c9`:

- `PYTHONDONTWRITEBYTECODE=1 PYTHONPATH=scripts python3 -m unittest bench.test_rss_provenance bench.test_harness bench.test_baseline bench.test_compare bench.test_observations`
  — exit 0, **186 tests**. Log: `/private/tmp/arkdeck-rss-provenance-tests-final.log`.
  Covers missing-read adjacency, all-missing phases, before/during-sample process
  exit, invalid evidence and cleanup, archived-series replay, version mismatch,
  raw-field preservation and exclusion from comparison scale, plus existing
  capture/checkpoint/failure/comparison checks. Mocked failures are unit evidence,
  not real-daemon performance or device acceptance.
- Initial 174-test invocation exited 1: two new tests incorrectly expected empty
  returned sample arrays instead of omitted unmeasured metrics, and the sandbox
  denied the existing `ps` self-process check. Assertions were corrected; the
  targeted suite passed with permission to read its own process. Initial log:
  `/private/tmp/arkdeck-rss-provenance-tests-initial.log`.
- `git diff --check` — exit 0.
- `sh scripts/check-sdd.sh` — exit 0. Log: `/private/tmp/arkdeck-rss-provenance-sdd.log`.

No Rust build, heavy test, daemon launch or formal capture ran in this slice.
The previously verified recovery and formal-scale data were reused. No new quiet
window or baseline was claimed, and the local unified gate was not run.

## CI

PR and run IDs are reported to the coordinator after push. CI has not run at this
commit's preparation. The coordinator owns review and merge; this branch does
not self-merge. Final CI results are not amended into an already-green head.
