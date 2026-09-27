# TASK-XPA-025 — cached Runtime capture, 2026-09-27

The fixed protected-main source completed one 128 MiB and one 1 GiB real
InputArtifact read. Neither reaches 200 decimal MB/s. A single three-run
startup/RSS capture stopped with exit 1 when run 3's quiet-host guard rejected
load 4.48 > 4.00. All 150 cold-start observations, two complete idle windows,
the partial third window and failure are retained. No unchanged-condition retry,
threshold waiver, sample removal, reference adoption or G5 completion is claimed.
Earlier recovery, journal, Artifact, cold-start and RSS records remain unchanged.

## Source and build

Measured source is exactly `4c3ed7491a96921a5a48f908f168cd27438e1064`, including
sealed-payload cache #2291, Python reader v4 #2288 and startup observation v2
#2290. Main advanced during the run; neither the source nor result identity was
changed. This is not a measurement of the later socket-soak commit #2292.

`plan.json` and `provenance.json` bind source/Rust/bench trees, Cargo.lock SHA,
all parameters and host. Apple M3, 8 logical CPUs, 17,179,869,184 bytes RAM;
macOS 27.0 build 26A428, Xcode 27.0 build 27A266a, SDK 27.0;
Rust/Cargo 1.98.1 and Python 3.14.7. Release default features include the reviewed
macOS ARM64 SHA assembly backend, with no RUSTFLAGS/encoded flags.

```sh
CARGO_INCREMENTAL=0 CARGO_TARGET_DIR=/private/tmp/arkdeck-xpa025-journal-target CARGO_BUILD_JOBS=2 cargo build --locked --release --manifest-path rust/Cargo.toml -p arkdeck-agentd -p arkdeck-soak
```

Build exited 0 in 1m29s. The target was exclusively owned by this worktree.
Copied binaries under `/private/tmp/arkdeck-xpa025-final-4c3ed749-20260927/bin`:

| Binary | SHA-256 |
| --- | --- |
| arkdeck-agentd | `310ac44296a8d6a68c4d8b9fd30f9f9f2f19b7668bcf19f60c801be42b854cf9` |
| arkdeck-soak | `4f9356b59dda0226cd573679e14f5e3a911c4dceae937f9f10bff53ecbfee2bd` |

Twenty measured input files were frozen with per-file hashes in
`instrument-source.tar.gz`. Drivers verify those files and both binaries before
and after captures, including failure cleanup; `verification.json` rechecks them.
Executables and large generated payloads are not committed.

## Admission, workload and measurement boundaries

The coordinator granted the exclusive local build/measurement window. First
pre-build disk admission at 08:30:27Z passed: 9,666,560,000 bytes available against
7,583,301,632 required (three 1 GiB copies, metadata and untouched 4 GiB reserve).
Per-fixture disk admissions remain in raw data. No other local build/test was
started by this task during measurement. Each Artifact run's four phase guards
passed; load values are included in `verification.json`.

The unchanged fixture publishes an import-owned flash-bundle InputArtifact via
the actual production owner in a temporary Runtime root. Payloads use
`input-artifact-stored-gzip-v1`, template SHA
`1e3ab5867689c4059b6c11a080f6496ad5217e1ca3b529ea7388cb3b1657911d`.
Reader is `fixed-buffer-chunked-canonical-json-v4`. Synthetic local bindings
produce no device dispatch, trusted-facts/capability record, Keychain access or
installed Runtime operation; this is not real-device acceptance.

Timing starts with the first read on a contract-verified connection and ends
after every byte and the complete client digest are verified. It includes the
first production full-file hash, subsequent actual per-page integrity checks,
4 MiB page transport/canonical base64 validation and connection renewal after
64 requests. Invalid/ineligible cache proofs retain the production full-hash
fallback. Publication and startup are outside this read interval. No warm-up
read, cache eviction or overhead subtraction occurs. Generation/publication/read
budgets remain 120/600/600 seconds. Client means the Python capture PID, not
Swift App or Rust CLI; sampled RSS peaks are lower bounds, not exact peaks or
copy-count measurements.

## Artifact results — one attempt per size

| Payload | Pages | Milliseconds | Decimal MB/s | Full archive SHA-256 |
| --- | ---: | ---: | ---: | --- |
| 128 MiB | 32 | 1,037.159583 | 129.408946 | `3a6db799b50f87ebe4cd21dc5c691a6f1433e684fdd992bb6388e761bc3b2e7e` |
| 1 GiB | 256 | 8,599.597833 | 124.859539 | `ba5eb9d725c43a044fd910e491dceccda54c9a84cfbc711138d89e059dfe62a0` |

| Payload / process | Baseline bytes | Sampled peak bytes | Sampled growth bytes |
| --- | ---: | ---: | ---: |
| 128 MiB / daemon | 20,070,400 | 42,008,576 | 21,938,176 |
| 128 MiB / Python client | 47,218,688 | 57,147,392 | 9,928,704 |
| 1 GiB / daemon | 20,070,400 | 42,811,392 | 22,740,992 |
| 1 GiB / Python client | 20,873,216 | 45,760,512 | 24,887,296 |

Both reads exited 0; all offsets, byte counts, EOF, page counts and final digest
checks passed. These single validations set `baselineEligible: false`; they
cannot establish three-run stability. The previous v3 uncached 1 GiB result
(252,677 ms / 4.249 MB/s) is preserved in the adjacent historical run directory.
The implementation and reader changed, so these are contextual observations,
not a same-identity stable-baseline comparison or isolated causal experiment.
The 200 MB/s goal remains unmet; Python measurements do not prove a Swift
product-client RSS gate or copy-count requirement.

## Startup and idle capture — incomplete, not adoptable

One unchanged CLI invocation ran 08:37:45Z–09:01:08Z, requesting three runs,
50 cold starts/run, 1,000 IPC samples/run, 200 calibration samples,
600 idle seconds/run, and seed parameters 6 seconds with 10 Jobs/cycle.
`baseline/invocation.json` records every argument. The 600-second window was
fixed before the run; old 180-second records are not merged into this series.
No `--allow-loaded-host` was used and quiet wait was zero.

Cold start still means spawn through contract verification and explicit health
completion on seeded state; it is not the separate 10k Journal/10k History
recovery measurement. All 50 samples in each run, including each first sample,
are retained with `startup-observation-v2` actual sleep and connection phases.

| Run | Samples | Cold-start p95 ms | Idle samples | Last observation seconds | RSS bytes (constant) |
| --- | ---: | ---: | ---: | ---: | ---: |
| 1 | 50 | 42.948666960 | 545 | 600.012436 | 21,266,432 |
| 2 | 50 | 32.249083044 | 546 | 601.082956 | 21,463,040 |
| 3, interrupted | 50 | 36.638292018 | 108 | 118.857267 | 21,413,888 |

The fixed source's `baseline.summarize_run` and `spread_ratio` produce p95
spread **0.29203282485554516 (29.203%)**, below the unchanged 30% threshold for
this individual metric. This does not make the incomplete capture a baseline.
The unchanged `split_at_release` finds no release in any retained series:
post-release steady RSS and release time are unmeasured. A constant plateau is
not substituted for post-release steady RSS.

At 09:01:08Z, run 3's idle guard rejected one-minute load **4.48 > 4.00** and
raised `HostTooBusy`; `baseline.log.gz`, the last raw failure and `exit.json`
retain the exact outcome. The last successful guard at 09:01:07Z recorded
load 2.873046875 and zero conflicting build processes. The refusal does not
record its process count, so zero conflicts at that later instant is not
asserted. The source of the load increase was not established.

The CLI only emits its assembled baseline after all runs succeed. Consequently
no baseline JSON was produced; in-memory IPC/calibration samples and observed
Job row counts were not archived by this failed invocation. Seed configuration
is recorded, but actual Job count must not be inferred from it. Completed-run
log messages are not replacements for those missing raw values. We preserve
all raw observations the instrument actually emitted and do not reconstruct a
complete baseline from the cold/RSS subset.

Normal/failure `finally` paths stop each temporary Runtime and remove its root.
The process exited 1; a subsequent read-only process check found no matching
capture/daemon/build process (only that check itself). This is not an independent
per-root deletion probe. No device or unrelated process was touched. The local
window was explicitly released to the coordinator and other owners.

## Local targeted checks

- Release build above: exit 0; `release-build.log.gz`.
- Actual 128 MiB and 1 GiB captures: exit 0; complete raw/results and driver
  adjacent. Formal baseline attempt: exit 1, expected quiet-host rejection
  reported above; not described as a passing performance check.
- `PYTHONDONTWRITEBYTECODE=1 python3 verify_capture.py`: exit 0;
  `verification.log.gz` and `verification.json`. Checks fixed-source/binary
  hashes, all 288 contiguous pages, exact verified sizes, four quiet guards per
  size, all 150 cold-start indices and retained failure/exit identity.
- Archive stored/uncompressed hashes and frozen manifest: checked separately.
- `sh scripts/check-sdd.sh`: exit 0, `sdd.log.gz`; `git diff --check`: exit 0.
- No Rust production or Python measurement implementation changes in this PR;
  no repeated crate/Clippy/Python suite or full local unified gate. The README
  only corrects the timing description to match the merged production cache.

## CI

Pending evidence/README PR creation. The PR records the actual CI run IDs and
conclusions when available; no already-green head is amended for status text.
