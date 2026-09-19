# Generated ClientKit History wire models

Base: protected main `98cb3b963e2b959287b9bc1c94e4840c747b3ccc`.
TASK-XPA-019 / SPK-8 remain incomplete.

The three History filter methods have a bounded Swift structure generator from
`spec/control/methods`. Requests preserve missing separately from explicit null;
responses require published fields and reject unknown keys. The generator fails
on unsupported schema vocabulary. The App facade retains its existing enum,
canonical generation, tombstone and list-consistency checks after structural
decoding. Transport authentication, health identity, frame limits and no-replay
behavior are unchanged. The generated structures do not implement Runtime policy.

The previous list schema had only null samples for sessionId and targetId,
while save and the Runtime owner support non-null identities. The actual Swift
`AgentDaemonContractTests.testCLIHistoryFilterUsesOneRuntimeOwnedCASResource`
now lists the saved non-null query through the production handler and CLI.
It passed and recorded `session-1` / `target-1` in the list response. No frame
or schema shape was invented. Only the three existing History corpora plus the
five newly recorded History frames were passed to the existing schema generator.
The sole structural schema change is list query identities becoming null|string;
save/delete sample counts reflect this bounded recording, and delete gains an
actual stale-generation resourceConflict corpus frame. Rust's manifest was
regenerated with its existing generator (105 methods, 728 shapes, same protocol
identity); Rust generated source remained unchanged.

Validation uses the repository `run-swiftpm.sh` shared-lock wrapper, `--jobs 2`:

- Actual History recording test: 1 passed.
- ClientKit: 9 passed, including non-null list identity preservation, omitted vs
  explicit-null requests, required nullable fields, closed keys, distinct method
  responses, canonical generation/enum rejection and no replay on conflict.
- Method schema tests: 4 passed; the recording-env-only check was initially
  skipped, then separately passed against the actual recording directory.
- Four generator tests, 37 planner tests, generated-model `--check`, Rust
  contract `--check`, and diff whitespace check passed.

Recording: `/private/tmp/arkdeck-clientkit-models-history-frames/control-frames-99167.jsonl`.
SHA-256: `2f0a58bf429aade61e4d67416705a50053afe2033cbfb1d99bbc42307bd7de3e`.
Logs: `/private/tmp/arkdeck-clientkit-models-recording.log`,
`/private/tmp/arkdeck-clientkit-models-focused.log`, and
`/private/tmp/arkdeck-clientkit-models-recorded-schema.log`.
The new relevant shapes are retained in the committed ControlFrames corpus.

The full unified gate, Rust published/candidate parity, signed standalone Rust
App acceptance and SPK-8 completion remain pending. This is a host-only Swift
oracle/ClientKit contract run, not installed activation or real-device evidence.

Checkpoint `8fd38984` preserves the focused-tested slice. Main `187321ea` was
subsequently merged without conflicts. The published/candidate contract views
must both run in the final unified gate because method schemas and the Swift
corpus changed. Its standard Rust lane runs `test_contract_checks.py` and
`check-contracts.py`, alongside manifest and workspace validation; targeted
ClientKit/schema tests alone do not satisfy that requirement.

## First complete unified attempt

Integrated main `760c527e` and reused the exact three-file HAR source-view
fixture fix (`0f282c7f` plus `fc70ffde` to preserve main's then-unimplemented
resume refusal). Both argv copies compare byte-identically with Swift sources.
The final net test change only redirects include paths; no assertion is relaxed.

The complete unified entry on `5f19ec7c` used the validation venv, Cargo jobs 2,
Rust test threads 2, Swift test workers 2 and Xcode jobs 2. Common/design-system
checks, full Swift tests, App build-for-testing, Rust workspace/strict Clippy,
35 contract-check tests and the complete published view passed. The candidate
workspace failed `verified_process::output_overflow_kills_and_reaps_the_child`
at its unchanged `started.elapsed() < 2 seconds` assertion. The expected
FileTooLarge result had already passed. This does not establish the cause of
the timing overrun and is not a successful full gate. No time bound or runtime
implementation was changed, and nothing was pushed.

Log: `/private/tmp/arkdeck-clientkit-models-unified-final-20260919.log`.
Failure metadata: `rust/target/readonly-check/05b072dbfef04ae7b05ea7a7b7cedb29`.
The temporary contract source views were automatically removed by the runner.
New main resume contracts landed during the run; integration must retain both
resume and History corpus changes and regenerate their shared manifest before
the next complete unified attempt.

Integrated main `76612c9f` after the failed attempt. The only conflict was the
shared generated manifest; regenerating from the merged inputs retains both
resume and History recordings (105 methods, 737 shapes, same protocol identity).
The manifest and ClientKit generation drift checks pass; no build was started.
The merged main now implements resume, so its native `invalidOption` expectation
is retained rather than the older unimplemented-command expectation.

Runner audit: `ARKDECK_TEST_WORKERS=2` only limited Swift test workers in the
previous full run. The existing `run-swiftpm.sh` has no build-jobs environment
setting, so Swift compilation had no explicit jobs limit. The earlier focused
recording/tests did explicitly use `--jobs 2`. The next full attempt must enforce
an explicit Swift compiler job limit through the shared-lock runner. No timing
assertion is changed to accommodate host pressure.

## Complete unified validation after History extraction

Integrated protected main `94b2896609c549177fa052512aa2b800dfc4e25e`
without conflicts. The validated source is
`c0ba7fc1207fc9112349b7bbb0369f6dc79cf9b3`. Both generated drift checks
passed with 105 methods and 737 recorded shapes.

The complete repository entry exited 0:

```sh
ARKDECK_PYTHON=/private/tmp/arkdeck-validation-venv/bin/python \
ARKDECK_SWIFT_EXECUTABLE=/private/tmp/arkdeck-swift-jobs2.sh \
CARGO_BUILD_JOBS=2 RUST_TEST_THREADS=2 ARKDECK_TEST_WORKERS=2 ARKDECK_XCODE_JOBS=2 \
/private/tmp/arkdeck-validation-venv/bin/python scripts/ci/plan.py \
  --repo-root . --base-revision origin/main --head-revision HEAD \
  --merge-base --include-worktree --run-local
```

The local Swift executable wrapper (SHA-256
`a50ddb92710750ab1970ba0c82988f6745c299e6b7c6df59bcfecb03976d5723`)
only execs the real Xcode Swift with `--jobs 2` for build/test. Repository
locking, cache paths, warnings-as-errors, complete tests and exit status remain
unchanged. Actual SwiftPM argv contained `--jobs 2` and `--num-workers 2`.
Xcode received `-jobs 2`, limiting build tasks; this does not claim all internal
SwiftDriver threads were restricted to two.

Common/design-system checks, 2,690 parallel Swift tests and the runner's serial
sets, App build-for-testing, Rust workspace/strict Clippy, contract-check tests,
both published/candidate views, cargo deny and cargo vet (36 fully audited)
passed. The unchanged output-overflow process time bound passed in both views.
The earlier failed attempt above remains part of the record; this rerun does
not establish its cause or relax its assertion.

Log: `/private/tmp/arkdeck-clientkit-models-unified-jobs2-20260919.log`.
SHA-256: `53e829e11d49e4338daa0b79a1151643ba75ebdce3b0097c0ec21c78adbf843b`.
Retained provenance: `rust/target/readonly-check/01388b861f0e4fbc964fd611b57ba3c7`.
Signed standalone Rust App acceptance, installed activation, hardware journeys
and SPK-8 completion are not claimed.
