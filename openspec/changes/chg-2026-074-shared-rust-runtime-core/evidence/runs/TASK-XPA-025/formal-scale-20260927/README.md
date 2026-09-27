# TASK-XPA-025 — complete formal-scale capture, 2026-09-27

One authorized attempt completed all three runs on the quiet macOS host,
2026-09-27 **10:34:43.951915Z–11:06:12.118411Z** (31m28.166496s).
The unchanged tool returned **exit 0**, `spikeVerdict: PASS`, **9 measured stable
metrics**, **16 gaps**, and **`baselineEligible: false`**. PASS describes stability
of the measured subset. No run observed RSS release, so post-release steady RSS
is `NOT_MEASURED`. This is **not** complete baseline/SPK-11/G5 acceptance or
reference adoption. The original document is [perf-baseline-2026-09-27.json](perf-baseline-2026-09-27.json).

This attempt fills the actual IPC/calibration/seed-scale/final-output evidence
lost by the earlier interrupted capture. It does not replace earlier failures,
change budgets or Task status, or borrow older Artifact/recovery/journal results
to fill legs not requested here. All first samples remain, including the first
cold start of **481.86829197220504 ms**. No retry or sample selection occurred.

## Exact inputs and boundaries

- Tool source: protected main `2b049c61238165a88edb6f7cd40b67781f46c3af`, observation
  `phase-checkpoints-v1`; all 22 frozen input files are in `instrument-source.tar.gz`.
- Daemon source: `d330cc01945fcaeff6b59b1ecd9a2eb11b861350`; its entire tree equals
  the tool's main tree (`c00e0f7761c050eb891cad03da8963d3bd1941`). The binary is
  the supplied Release cargo artifact frozen **before Developer ID signing**,
  not extracted from a signed App.
- Soak source: `0400050d99b0e118491bfbd1324ed8a01054884f`; it is not relabeled as
  the daemon/tool source. Original locations, independent Rust tree IDs, sizes,
  modes and pre/post-copy checks are in `plan.json`. Both originals were regular,
  non-symlink 0500 files; private copies remained unchanged after execution.
- Registry bytes and generated Rust control contract were identical across the
  three source identities. Actual canonical contract identity is
  `1d7d101e83fe005f364c1e9273968b64d744c815eb39bc82d43a307ce046b633`.

| Binary | SHA-256 |
| --- | --- |
| daemon | `5ecf35b1b4be7aaf01e1a2023a6e4b997109773676356e16491a8af9f9c6abf7` |
| soak | `c9ab8e5f1d124e54d83f1174fbd454ba44c2531938be42547b9a565c977b0c1c` |

The coordinator granted the exclusive performance window. No build or test ran
in this task during capture. Host facts are in the original final document;
Python was 3.14.7. This task did not rebuild the supplied Release binaries.
Private root: `/private/tmp/xpa025-formal.l1gvx8k4`; `TMPDIR` pointed only to its
`state` subdirectory. Frozen binaries and original files remain locally; executable
binaries and temporary Runtime contents are not committed.

`plan.json` records the exact executable/argv. Parameters were unchanged from the
previous formal attempt: `--runtime-kind rust --build-configuration release
--runs 3 --cold-start-samples 50 --ipc-samples 1000 --calibration-samples 200
--seed-seconds 6 --seed-jobs-per-cycle 10 --idle-seconds 600 --quiet-wait-seconds 0`.
No recovery/journal/Artifact/UI leg was enabled. Normal quiet guards, failure
budgets, timing boundaries and cleanup remained active. There was no device,
Keychain, installed Runtime, signed bundle or retained Session access.

The preflight guard passed at load 1.6240234375. All **1,947 in-capture guards**
passed, with load range **1.21435546875–3.6357421875**, zero conflicting build
processes and process scanning performed. Refusal would have ended the attempt;
there was no automatic retry or loaded-host waiver.

## Observed workload and results

Each actual completed seed reported **20 terminal Jobs: 18 succeeded, 2 cancelled,
0 active**, with 18 verified-evidence Jobs. Each independently observed first
`job.list` page returned 20 rows (`pageSize: 50`). These are separate measured
facts, not `seed seconds × jobs/cycle` or an assumption that a page is a total.
Exact seed documents, hashes and process exits are in the raw observations.

Each run retained 50 cold starts, 200 calibration samples, 1,000 samples for each
of health/job.list/job.status, and 545 idle samples. Six phase checkpoints and
three complete-run checkpoints agree with the final document. Across all runs
this is 150 cold starts, 600 calibration samples, 9,000 IPC samples and 1,635 idle
observations. Every original first sample is retained.

| Metric | Per-run p95 | Across-run p95 spread |
| --- | --- | ---: |
| cold start (ms) | 30.096416 / 33.798208 / 30.121166 | 12.2897% |
| calibration (ms) | 1.860292 / 1.863750 / 1.849000 | 0.7929% |
| IPC health (ms) | 0.084208 / 0.091167 / 0.082208 | 10.6390% |
| IPC job.list (ms) | 15.747583 / 16.566417 / 14.730792 | 11.6566% |
| IPC job.status (ms) | 0.402583 / 0.444875 / 0.395500 | 12.2645% |
| RSS plateau (bytes) | 21,397,504 / 21,348,352 / 21,331,968 | 0.3070% |
| idle CPU (%) | 0 / 0 / 0 | 0% |
| idle threads | 2 / 2 / 2 | 0% |
| idle descriptors | 44 / 44 / 44 | 0% |

The three idle windows' last sample completion times were 600.437462,
600.405217 and 600.432537 seconds. Each RSS series was constant; the unchanged
25% adjacent-sample release criterion found no qualifying step. Steady RSS and
release time remain unmeasured. Stable plateau/CPU/thread/fd observations do not
resolve the product decision about RSS budget phases or the other 16 gaps.

## Integrity and cleanup

`verification.json` checks every retained sample against its phase/run checkpoint
and recomputes each run's final statistics with the frozen implementation. The
coordinator independently recomputed all nine metrics' per-run and aggregate
p50/p95/p99, spread and stability: `independent-summary.json` and
`independent-statistics.json` preserve those supplied review results. These are
post-capture checks, not another performance run.

All three Runtime cleanup records show cleared process references; all three
state cleanup records show root absence. After exit the dedicated state directory
was empty and a read-only process check found no matching frozen daemon/soak or
capture runner. Binary and all input hashes remained unchanged. The coordinator
and Runtime owner were notified that the window was released.

`files.json` binds stored and uncompressed bytes/SHA-256 to each original path.
`original-files.json` preserves the prior local file inventory. Gzip archives
retain exact uncompressed bytes; no original JSON or log was rewritten.

## Local targeted checks

- Original formal capture: exit 0; `stdout.log.gz`, `stderr.log.gz`, `exit.json`.
- `PYTHONDONTWRITEBYTECODE=1 python3 verify.py`: exit 0; `verification.log.gz`.
- Archive hashes/sizes, frozen inputs against the fixed Git commit, and data/log
  privacy checks: exit 0, `archive-check.log.gz`. The first privacy scan also
  scanned the entire pre-existing bench README and rejected its literal
  home-path placeholder example; `archive-check-initial.log.gz` retains this false
  positive. The corrected scan checks all new data/logs and only the added entry
  text, with fixed-source input identity checked independently.
- `sh scripts/check-sdd.sh`: exit 0, `sdd.log.gz`; `git diff --check`: exit 0.
- Evidence/link-only change: no compilation, implementation tests, full local
  gate or repeated performance capture.

## CI

Pending evidence PR creation. The PR body records actual run IDs and conclusions
when available; no green head is amended for status. Maintainer review remains
required, and this evidence is not copied into `scripts/bench/baselines/`.
