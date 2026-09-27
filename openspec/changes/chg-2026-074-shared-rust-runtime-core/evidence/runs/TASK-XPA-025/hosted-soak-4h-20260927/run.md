# Hosted four-hour Rust owner soak — 2026-09-27

Existing workflow run [36291225535](https://github.com/ArkDeck/ArkDeck/actions/runs/36291225535)
completed successfully at 07:26:05 UTC. This record downloads and verifies the
finished evidence; it does not dispatch or repeat a workflow.

The measured checkout is `443e805ef7529e61a9860ccae7011c072142e52a`, confirmed by
the actual job checkout log, not the later branch tip. The runner was GitHub
Actions `macos-26`, image `macos-26-arm64` version `20260907.0351.1`, macOS 26.6.2
(build 25G83). This is hosted simulation evidence for that source, not current-main,
installed Runtime, 24-hour or real-device acceptance.

## Actual result

The workload began at 03:25:59 UTC and completed at 07:26:00 UTC. Configuration:
14,400 seconds, 300-second owner-reopen interval, ten Jobs per cycle. Recorded
elapsed duration: 14,401 seconds. There are 48 logged cycle samples and one final
metrics snapshot. The final snapshot is preserved byte-for-byte in
`runtime-soak-metrics.json`; `analysis.json` extracts the actual 48-row series.

| Measurement | Actual result |
| --- | --- |
| Terminal Jobs | 480: 432 succeeded, 48 cancelled |
| Active Jobs / cleanup debt | 0 / 0 |
| Verified Artifact Jobs | 432 |
| Lifetime max-RSS baseline / final | 15,826,944 / 22,708,224 bytes |
| Max-RSS growth | 6,881,280 bytes (6.5625 MiB), below 32 MiB |
| File descriptors baseline / final | 19 / 19; growth 0, below 16 |
| State files / bytes | 4,647 / 35,641,863 |
| Journals / bytes | 960 / 7,351,296 |
| Artifact files / bytes | 1,728 / 2,054,592 |
| Simulated-provider child processes | 0 |

All workload and resource gates passed, including journal inspection and final
Artifact/cleanup verification. The harness job also passed. Its log includes an
expected negative-argument error from a successful unit test, not a soak failure.

## What the cycles mean

The fixed source `rust/crates/arkdeck-soak/src/lib.rs:251` opens production owners
for each workload cycle and drops them on return; it does not restart an OS
process. There are 48 normal cycles plus one drain, recovering 48 clean preflight
Jobs in total. `collect` also reopens owners for each of its 49 samples; these
sampling opens are separate from the 49 workload opens. None is an installed
daemon restart or unknown-outcome replay. The soak stays in one process, uses
an in-memory simulated HDC provider, and has no device transport or socket IPC.
RSS is this process's lifetime high-water mark, not a sampled standalone daemon's
live/settled RSS. Repeating bounded runs cannot be added together into 24 hours.

## Provenance and checks

Artifact `runtime-soak-36291225535`, GitHub artifact ID `10925493277`, was downloaded
unchanged. `run.log.gz` is a deterministic gzip of the complete downloaded raw run
log. `files.json` records stored-file hashes and the uncompressed log hash/length.
`analysis.json` is derived analysis, kept distinct from raw metrics/logs.

Local targeted checks: JSON parse, raw/log agreement (48 consecutive cycles),
archive hash and decompression round-trip verification, and `git diff --check`:
exit 0. `sh scripts/check-sdd.sh`: exit 0, log
`/private/tmp/arkdeck-hosted-soak-sdd.log`. No build, benchmark, device action or
local unified gate was run for this documentation-only archival change.

CI: source soak run `36291225535` is successful. The independent archival PR's
SDD/planner result is pending and will be recorded in its body, without changing
a green head. No claim of TASK-XPA-025, SPK-11, G5 or G7 completion is made.
