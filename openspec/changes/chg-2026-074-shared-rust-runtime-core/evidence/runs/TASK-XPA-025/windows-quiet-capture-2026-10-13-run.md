# Windows quiet-host capture attempts — 2026-10-13

## Result

Both default-scale captures were correctly refused by the unchanged quiet-host
gate. **No complete run, performance pass or baseline was produced.** Each
started after a full-minute Windows CPU observation below the required ceiling
and 30 checks without a conflicting build process. During cold-start samples,
the harness observed a one-second busy-CPU value above 4 and stopped.

Windows has no native load average. The preflight used `GetSystemTimes` over
a full minute; the published harness additionally uses its existing
one-second `windows_host.load_equivalent` checks around each phase. Neither
threshold, sample size nor assertion was changed. `--allow-loaded-host` was
not used. This host needs a more stable quiet window for performance capture;
these partial observations do not qualify its long soak or baseline adoption.

## Provenance and workload

The Runtime is the signed release from protected main
`aea6c663e8c79fe1501d5751a411a5b15021b3e6`, SHA-256
`23e658ca9e006a23082f30297d11864509709c8a0c7d82e892c2df7e1934b43c`.
The matching `arkdeck-soak` was built with the official runner from the same
clean source using `build --release --locked -p arkdeck-soak`, then a copy
was signed with the existing development identity. Its signed SHA-256 is
`0eaf9af1e12b8d9a7e9921485a8c9bbe2129095c4865f91ffcda476fd3120632`.
Both signatures verified `Valid`; the soak signer pin was supplied normally.
The same fixed session Cargo cache and two build jobs were reused.

The unmodified command was `python -m bench capture --runtime-kind rust
--daemon <signed-release-daemon> --soak <signed-matching-soak>
--build-configuration release --out-dir <fresh-output>`. Defaults request
three independent runs, 50 cold starts per run, 1,000 IPC samples, a 120-second
idle window, 200 calibration samples and the six-second Job seed workload.
Recovery, journal and large-Artifact legs were not requested. Private roots
and simulated-provider owner workloads do not access installed state or
dispatch to a device.

## Actual observations

| Attempt | Full-minute busy CPUs / 16 | Failure-phase busy CPUs | Outcome |
| --- | ---: | ---: | --- |
| Initial | 1.4028 | 5.4280 | `HostTooBusy`, `cold-start-after`, run index 0, exit 1 |
| Retry | 1.4491 | 5.1613 | `HostTooBusy`, `cold-start-after`, run index 0, exit 1 |

The ceiling is strictly below 4 and at most half the CPU count. Both
generated failure documents retain `completedRuns: []` and
`baselineEligible: false`; their JSONL files retain partial samples and
cleanup observations. The first failure document's ID is
`06dd049e4b604b209dcf159a508c8e25`; the retry's is
`400714242c1d4f559dd6e4d4727521f5`. No partial number is reported as a percentile
or promoted to a baseline. A Windows capture would remain capture-only even
if the complete workload succeeded, pending maintainer baseline adoption.

Raw output stays outside Git under
`D:/temp/arkdeck-windows-acceptance-20261013/perf-capture` and
`perf-capture-retry`: `admission.json`, `capture.log`, `exit.json`, and the
unchanged `capture/capture-failed-<id>.json` and `capture-samples-<id>.jsonl`.

## Local targeted checks

- Official native release build: exit 0 in 154 seconds;
  `perf-soak-build-native.log` under the acceptance root. An earlier explicit
  native `--target` argument was refused by the runner before building;
  `perf-soak-build.log` is retained. The successful command used the runner's
  prescribed implicit native target.
- Both executable signatures and recorded digests matched before capture.
- Initial capture: exit 1 after 21.2 seconds; retry: exit 1 after 39.8 seconds,
  in addition to each 60-second admission observation. The unchanged host
  gate produced both failures; no product test assertion was relaxed.
- No code or measurement algorithm changed. The benchmark README's stale
  Windows G01 owner-gap paragraph was corrected to match the already
  published owner composition, without changing acceptance requirements.

## CI

The measured protected-main source passed #2633's Swift CI `38373622565` and
SDD Guard `38373622446`. This documentation follow-up reports its own CI on
its PR; CI success cannot replace a complete quiet-host performance run.
