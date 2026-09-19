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
