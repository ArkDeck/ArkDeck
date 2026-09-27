# TASK-XPA-025 — bounded startup observation v2

This slice makes the next existing cold-start capture more explainable; it does
not change Runtime startup or establish a new performance result. Only the Python
measurement harness, behavior tests and documentation change. No real daemon,
measurement, Rust build or production startup tracing was run.

The preserved attempt-2 raw has 50 samples and one connection attempt each. Its
423.405 ms first sample contains 355.498 ms between spawn return and socket
observation, 66.257 ms between socket and contract completion, and only 0.101 ms
for the second explicit health. Forty-six of fifty spawn-return-to-socket
intervals fall between 5.9 and 6.3 ms despite requested 1 ms polling sleeps.
Those facts locate intervals, not a cause. The pinned Rust startup binds its
isolated socket before owner/recovery work and starts serving afterward; socket
to contract therefore is not pure IPC latency. Old raw and first samples remain.

## Implementation

`startup-observation-v2` extends the raw diagnostics with socket poll count,
last negative socket-observation elapsed time, actual awake sleep count/total/max,
and successful connect-return elapsed time separate from contract completion.
Requested sleep remains exactly 1 ms; actual overshoot is included, never removed.
No busy wait, warm-up, discarded sample or threshold/default/sample-count change.
Total timing still starts immediately before Popen and ends after contract health
plus the existing second health. The prior post-response close remains outside
that endpoint. Continuous deadline behavior is unchanged.

Timestamps are durations from the same awake origin, not persisted clock instants.
No missing/completed phase is fabricated. Each retry resets connection completion
fields; a bounded last recoverable-failure record and failure count keep context
without an unbounded list. Connections close on contract, health, unexpected or
close failures under the same retry policy. Socket observations and clock reads
are in-memory; the existing metrics recorder writes one raw startup record after
return/failure. The additional bookkeeping is included in timing, not subtracted.

README defines field meanings and versioning. This is a raw diagnostic extension,
not a control protocol/metric schema change; comparison rules remain unchanged.
Old records lack this version and are never retroactively interpreted as v2.
No phase establishes a dyld, signature, disk or scheduler diagnosis on its own.

## Local targeted checks

- `python3 -m unittest discover -s scripts/bench -t scripts -p 'test_*.py'`:
  exit 0, 230 tests, 3 optional integration skips; `python-tests-final.log.gz`.
- Nine new controlled-clock/failure-path tests verify actual oversleep totals/max,
  last negative observation, connect/contract/second-health ordering and unchanged
  total endpoint, missing-socket timeout, daemon exit, interrupted sleep, failed
  contract then refused connection, failure then successful retry, unexpected
  decoder failure, close failure and one post-failure raw record with cleanup.
- The initial targeted invocation used the wrong working-directory path before
  the class was added; its missing-class error is retained in `targeted.log.gz`.
  Corrected six-test intermediate and 229-test intermediate logs are retained;
  final 230-test run is the validation of the complete change.
- SDD (`sdd.log.gz`) and git diff --check returned 0. No Rust tests
  or unified local gate are needed because no Rust/product code changed.
- The local heavy window remains with the server-cache owner. No real performance
  sample or baseline was produced; final source/binaries must be pinned again
  for the later coordinated reference-host capture.

## CI

Pending for this independent small PR. Final run IDs belong in its PR body rather
than an amendment to a green head. CI success does not qualify a baseline or G5.
