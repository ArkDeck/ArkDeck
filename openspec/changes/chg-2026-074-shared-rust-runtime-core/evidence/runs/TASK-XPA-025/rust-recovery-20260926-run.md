# TASK-XPA-025 — macOS Rust recovery capture

This slice adds real daemon recovery measurements over two separate temporary
workloads, without changing production recovery, App, CLI, Catalog, protocol,
signing or installed Runtime state. It does not approve a reference baseline,
replace the earlier cold-start/RSS capture or close TASK-XPA-025/G5.

## Implementation and workload

Base: protected main `fbbf925d0fc49535f9f8e5a11945975afd7442b6`.
The fixture is `rust-recovery-fixture-v1`; it writes fixed synthetic historical
snapshots using the production JobStore and durable JournalWriter, with no
capability, provider dispatch, device, Keychain or installed-state access.

- Journal: 1 active preflight Job; exactly 10,000 events (creation, preflight
  transition, 9,998 warnings). Successful completion requires the production
  daemon's durable `recovered: journal clean` marker, exact Job/state readback
  and an unchanged journal digest.
- History: 10,000 terminal succeeded snapshots; zero journals and zero active
  Jobs. Completion requires all unique IDs/states through 250-row pages and
  durable snapshots unchanged without recovery markers. Direct repository
  seeding follows the existing terminal-history benchmark; these synthetic
  terminal records do not claim 10,000 provider executions or hardware results.

Each independent run generates a pristine seed per workload. Every sample copies
that seed to a new root, validates actual event/Job counts and matches its input
hash to the pristine seed before spawning the real Rust daemon. Seed time is excluded. The metric
ends after completion verification, not socket availability. Total duration,
spawn-through-health duration and verification duration are recorded separately;
History pagination cost is visible. The totals are end-to-end upper bounds,
not pure replay time or an equivalent of the old in-process 5-second budget.
Comparison identity includes the fixture version, seed strategy, workload scales, page size
and timing boundary. Existing comparison thresholds are unchanged.

Raw attempts are appended immediately, including failures; no sample is
selected or discarded to obtain stability. Every daemon/root is stopped/removed
on success, seed failure, startup/recovery failure or timeout. Recovery-only
capture leaves other metrics explicitly unmeasured; the prior unstable
`rust-capture-20260926.json` and its run record remain unchanged.

## Local targeted checks

- `CARGO_TARGET_DIR=/private/tmp/arkdeck-xpa025-recovery-target CARGO_BUILD_JOBS=2`
  for all Rust commands. `cargo test --locked --manifest-path rust/Cargo.toml
  -p arkdeck-soak`: exit 0, 7 tests;
  `/private/tmp/arkdeck-xpa025-rust-test.log`.
- `cargo clippy --locked --manifest-path rust/Cargo.toml -p arkdeck-soak
  --all-targets -- -D warnings`: exit 0; `/private/tmp/arkdeck-xpa025-clippy.log`.
- `cargo fmt --all --check --manifest-path rust/Cargo.toml`: exit 0;
  `/private/tmp/arkdeck-xpa025-fmt.log`.
- `cargo build --locked --release --manifest-path rust/Cargo.toml
  -p arkdeck-agentd -p arkdeck-soak`: exit 0 (initial 1m55s, fixture increment 21.48s);
  `/private/tmp/arkdeck-xpa025-release.log`.
- `PYTHONPATH=scripts python3 -m unittest bench.test_recovery bench.test_baseline
  bench.test_compare bench.test_harness`, with `BENCH_TEST_DAEMON` and
  `BENCH_TEST_SOAK` pointing at the above release binaries: exit 0, 168 tests, no skips;
  `/private/tmp/arkdeck-xpa025-python.log`.
- `sh scripts/check-sdd.sh`: exit 0; `/private/tmp/arkdeck-xpa025-sdd.log`.
- `git diff --check`: exit 0. No full local unified gate or device acceptance.

Python tests exercise
wrong manifest/count/sequence, torn input, health without recovery marker,
missing/duplicate/wrong-state History, stalled paging, deadlines, cleanup,
quiet-host guard, immediate attempt retention and comparison identity.
Optional real-daemon tests use a 20-item correctness fixture and corrupt a
journal to verify recovery failure/process cleanup; they are not performance
samples. The first integration attempt exposed an omitted `actualEffect` in the
new synthetic record: `job.list` correctly refused its null projection. The
fixture now declares `readOnly`; no production contract was relaxed. A sandboxed
attempt could not bind the socket (exit 69); real process checks ran with the
private-socket permission.

## Advisory full-size smoke and formal window

The release binaries completed one pair of full-size workloads before template
reuse was added. Their unmodified output is
[rust-recovery-advisory-smoke-20260926.jsonl](rust-recovery-advisory-smoke-20260926.jsonl).
This is functional/elapsed-time estimation with quiet checks waived, **not a
baseline** and not comparable to the later pristine-template preparation strategy.

| Workload | Seed preparation | Spawn through health | Completion verification | Total |
| --- | --- | --- | --- | --- |
| 10k Journal events | 19.660 s | 178.639 ms | 7.801 ms | 186.440 ms |
| 10k terminal History | 141.831 s | 419.636 ms | 4577.621 ms | 4997.257 ms |

The Journal is 2,588,954 bytes with exactly one recovered marker; History has
10,000 verified distinct Jobs in 40 pages and zero markers. The two executable
SHA-256s and actual input digests/counts are in the raw output. Both binaries
were built with `--locked --release`, jobs 2, from this slice's Rust source.

Repeating durable generation for every sample would take about 42 minutes.
The capture therefore creates one never-started pristine template per workload
per independent run; every sample gets a distinct copy/root/daemon. Before
launch, every copied regular file must have a different inode from its source,
and input hashes must match. Afterward, the template is verified unchanged.
The preparation strategy is part of comparison identity. The 3 runs × 5 samples
× 2 full-size workloads remain unchanged.

## Formal recovery capture

Source head: `ed067a90d756e6a8c1475cf7699a8b49c0b7db40`. The existing release
binaries and measurement code stayed fixed throughout the exclusive window.
Command (from `scripts`):

```sh
python3 -m bench capture \
  --daemon /private/tmp/arkdeck-xpa025-recovery-target/release/arkdeck-agentd \
  --soak /private/tmp/arkdeck-xpa025-recovery-target/release/arkdeck-soak \
  --runtime-kind rust --build-configuration release \
  --recovery-only --recovery-samples 5 --runs 3 \
  --out-dir /private/tmp/arkdeck-xpa025-recovery-formal-20260926
```

Exit 0; UTC 2026-09-26 13:45:41–13:56:15 (10m34s).
[Full generated document](rust-recovery-formal-20260926.json) and
[all 30 raw attempts](rust-recovery-attempts-20260926.jsonl) are copied unchanged
from the capture output. Full command log: `/private/tmp/arkdeck-xpa025-formal-capture.log`.
All 30 attempts are `MEASURED`: exactly 5 Journal and 5 History samples in each
of 3 independent runs. No attempt failed, was removed or was retried. Every
sample verified the full required counts, input digest, separate copy inodes,
unchanged template and workload-specific completion proof. Each workload's
input digest is identical across all 15 samples.

| Metric | Unit | Run 1 p95 | Run 2 p95 | Run 3 p95 | p95 spread |
| --- | --- | --- | --- | --- | --- |
| `daemon.warmStartRecovery` | ms | 239.877 | 232.318 | 238.386 | 3.1713% |
| `daemon.warmStartRecovery.history` | ms | 5010.210 | 5074.747 | 4965.640 | 2.1777% |
| `calibration.busyLoop` | ms | 1.8485 | 1.9331 | 1.8620 | 4.5427% |

The unchanged harness reports `PASS`, 3 measured metrics, 22 explicit gaps and
`baselineEligible: true` for this measured subset. This is candidate eligibility,
not baseline adoption, reference-host approval, full metric coverage or a G5
completion. The host was arm64, 8 CPUs, macOS 27.0, Python 3.14.7; its OS differs
from the design reference host. All before/start/end sample guards reported
zero conflicting build processes, with one-minute loads from 1.804 to 3.766,
strictly below 4. The coordinating session kept other builds stopped until the
window was released after completion.

The History p95 includes roughly 4.5 seconds of full readback, so its value near
5 seconds is not a pure replay budget result. No old budget or threshold is
raised or declared passed here. These documents remain beside this record,
not under `scripts/bench/baselines/`. Earlier cold-start and RSS instability is
still unresolved and its original evidence is preserved.

## CI

PR [#2271](https://github.com/ArkDeck/ArkDeck/pull/2271), implementation head
`ed067a90d756e6a8c1475cf7699a8b49c0b7db40`:
SDD Guard `36245984966` and Performance harness `36245985062` succeeded;
Swift CI `36245985333` has successful Linux/Windows/host-independent Rust jobs,
with the macOS Rust job still running at the evidence commit. Nightly/soak
measurement jobs were skipped by the workflow; harness CI is not a performance
capture. Required main contexts were read back as `guard` and `swift`.
The evidence follow-up commit will receive its own CI; final status is reported
in the PR and coordinating session without amending a green head. Maintainer
review and merge remain with that session. No baseline adoption or reference-host
substitution is claimed.
