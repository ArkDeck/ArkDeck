# TASK-XPA-025 — retain interrupted capture evidence

The fixed-source capture archived in #2293 lost its in-memory calibration, IPC
and actual seed scale when run 3's idle guard raised `HostTooBusy`. This bench-only
follow-up starts from protected main `0ba0f4fa41c67cb58647a50985c2ef1433b45d8d`
and prevents that loss in future captures. It does not reconstruct missing old
samples or run a new performance measurement.

`phase-checkpoints-v1` tags every new raw record and the successful document.
Seed child output is file-backed; only a 64 KiB prefix per stream is read and
archived, with actual size and explicit prefix/full hash scope. This bounds reads
and capture memory, not the amount a child can write to its temporary file before
the existing timeout. Temporary streams close on success, failure, timeout and
recorder error. Rust's actual completed soak document is read with a 1 MiB bound,
rejecting symlinks/non-regular files and inconsistent/active counts. Its exact text,
SHA-256 and observed workload are retained before measurement. Actual total Jobs
are separate from the unchanged first-page `jobStoreRowCount` denominator.

Calibration/IPC checkpoints are written after measured intervals; failures retain
only the values actually obtained. Each completed run has a raw checkpoint before
the next run. Refusals write a separate `capture-failed-<id>.json` with
`baselineEligible: false` and references to the raw data; it is not a baseline or
a retry/resume facility. Root removal and process-reference observations describe
what was verified, including false/unknown outcomes. Host refusal facts distinguish
an unperformed process scan from zero conflicts and retain the actual known load,
threshold and phase. The existing 25% adjacent-sample RSS split, quiet checks,
sampling, successful metric scales and 30% comparison rule are unchanged. The
misleading "running median" comment now matches the existing implementation.

## Local targeted checks

The coordinator released Runtime's build window before these tests. No Rust build,
Rust test/Clippy, App build, formal capture or release diagnostic was performed.

- Initial targeted Python run: exit 1, one environment `ps` permission error and
  existing mocks that expected only old record kinds/no seed-metrics read. Full
  initial output remains `tests.log.gz`. Assertions were updated to select the
  original cold/idle events while preserving their values and multiplicities;
  composition tests mock the separately tested seed-evidence reader.
- Targeted five-module run after fixes: exit 0, 190 tests / 2 skips;
  `tests-permitted.log.gz`. Additional malformed-input/refusal tests: exit 0,
  193 tests / 2 skips; `tests-final.log.gz`.
- Final shared bench suite:
  `PYTHONDONTWRITEBYTECODE=1 PYTHONPATH=scripts python3 -m unittest discover -s scripts/bench -t scripts`
  exited 0, **242 tests / 3 existing conditional skips**; `tests-delivery.log.gz`.
  Covers log truncation/hash scope, actual seed counts, oversized/duplicate/active
  inputs, nonblocking FIFO/symlink refusal, timeout, partial IPC timing boundaries,
  completed-run survival, admission refusal, recorder failure and failed removal.
  Existing baseline comparison, RSS split and runtime composition tests pass.
- `git diff --check`: exit 0. `sh scripts/check-sdd.sh`: exit 0, `sdd.log.gz`.

## CI

Pending PR creation. Actual PR/head/run IDs and conclusions are recorded in the PR
body after CI completes, without amending an already-green head. No baseline
adoption, RSS budget decision, reference-host change or G5 completion is claimed.
