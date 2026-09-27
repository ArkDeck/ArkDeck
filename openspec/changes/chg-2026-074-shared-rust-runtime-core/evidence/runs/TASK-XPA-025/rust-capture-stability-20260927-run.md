# TASK-XPA-025 — capture phase and diagnostic correction

Base main: `443e805ef7529e61a9860ccae7011c072142e52a`.
This implementation corrects measurement evidence; it does not establish that
cold start or RSS is stable, adopt a baseline, or close TASK-XPA-025/G5.
Production Runtime, signing, CLI, App, devices and installed roots are untouched.

## Findings and implementation

The previous RSS splitter reported the complete startup plateau as post-release
steady when no qualifying release occurred. The preserved September 26 local
capture consequently mixed two approximately 20.2 MB unreleased runs with one
10.99 MB post-release run. The raw evidence cannot establish a product leak.
The latest existing nightly, run `36266604312` at main `cdf417a6`, also reports
three unobserved releases as measured steady. Its cold-start result is UNSTABLE;
workflow success is not performance qualification.

The splitter now leaves steady unmeasured without an observed 25% downward step.
If any run lacks that phase, the complete JSON records NOT_MEASURED, the reason
and any partial measurements, and disqualifies the candidate. No sample is
removed. RSS comparison identity adds the phase-method version and fixed window.
The old JSON is unchanged and is not silently comparable to the new RSS method.

`residentSetReleaseAtSeconds` previously stored an array index despite reader
and scheduling overhead (the old 180-second runs contained 171–172 observations).
It now uses actual elapsed time at the resource read. Raw RSS trajectories stay
at run level; all resource read intervals are appended to a separate JSONL.

Cold start retains its existing spawn-through-contract-health-plus-explicit-
health boundary. Added per-attempt timings identify spawn return, first socket
observation, contract verification and final health, with connection attempts.
The old phrase “first health” was inaccurate; the second call is not removed.
No wait, outlier or failed attempt is subtracted. JSONL observations include
binary hashes, run identity and build configuration and survive a later failure.
Quiet-host guards cover cold samples, IPC boundaries and the idle window;
failures stop the daemon and clean the private root.

The proposed independent Rust environment uses the actual M3/8-core/16-GB host
with macOS 27 / Xcode 27, release. Historical Swift reference data and strict host
comparison stay intact. Candidate numbers remain outside `baselines/` until
review. RSS ceiling scope remains a product decision; neither 64 MiB nor the
30% cross-run stability limit changed.

## Local targeted checks

- `PYTHONPATH=scripts python3 -m unittest discover -s scripts/bench -t scripts`:
  exit 0, 173 tests, 2 optional real-daemon integration tests skipped;
  `/private/tmp/arkdeck-xpa025-stability-python.log`.
- `sh scripts/check-sdd.sh`: exit 0;
  `/private/tmp/arkdeck-xpa025-stability-sdd.log`.
- `git diff --check`: exit 0.

The initial sandboxed Python run could not execute `ps`; rerunning with read-only
process permission passed. No Rust source changed, so Cargo tests/builds/Clippy
were not run. No full unified local gate was run. Runtime/App builds own the
local host window; real-daemon integration, diagnostics and formal sampling
remain pending that coordinated window. The prior 30 recovery samples are
preserved and were not repeated. No new performance baseline is claimed.

## CI

Pending the implementation PR. The coordinator independently dispatched a full
4-hour soak against main `443e805e`, run `36291225535`; it is not this branch's
result, a 24-hour soak, or device acceptance. Nightly reference-host mismatch
skips and the remaining NOT_MEASURED rows remain explicit limitations.

## Review correction

Review of head `83f87122` reproduced an exit-code regression: missing steady
made an otherwise formal unstable cold-start capture exit 0. Coverage failure
is now separated from the caller's explicit advisory declaration. Full/partial
missing steady plus unstable cold-start tests require exit 2 for quiet release
and preserve exit 0 only for explicitly advisory captures. A stable incomplete
subset exits 0 with NOT_MEASURED and baselineEligible false; it is not adopted.
The first head's CI was green (harness `36291639537`, guard `36291639535`, Swift
aggregate `36291639703`), but that does not validate the corrected head; its CI
will be checked separately.
