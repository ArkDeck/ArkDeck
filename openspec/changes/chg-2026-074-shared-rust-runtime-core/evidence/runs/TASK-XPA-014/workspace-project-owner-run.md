# macOS workspace project registration owner

Status: implementation and targeted verification passed; unified gate pending. This record does not claim Task,
workspace integration, installation cutover, or hardware acceptance completion.

## Scope and compatibility

The Rust owner implements `workspace.project.register`, `.list`, and `.show`
using the existing Swift `RuntimeWorkspaceProjectStore` registration identity,
root identity, private document, request idempotency, and resource projection.
The Control host and CLI consume this actual durable owner. No workspace Job,
preset mutation, toolchain/credential recovery, signing, or device execution is
added. Registering a root does not authorize execution on it.

A registered project is a real persisted resource. Since this slice does not
compose a workspace execution provider, its configuration remains
`runtimeRestartRequired`, with unavailable operation configuration and empty
operation/preset references, matching Swift's uncomposed resource branch. A
restart preserves the registration; it does not claim to activate a provider.

Existing schema 1–3 project documents and fully validated preset records are
preserved. Definition, registration, and last-mutation digests remain checked.
A pending toolchain mutation requires the missing dependency owners and returns
`operationUnavailable` without rewriting its document. It is not discarded,
completed, or represented as recovered.

## Planned verification and precise limits

The added owner tests cover nonempty registration/list/show after reopening,
request identity and root replacement conflicts, concurrent identical
registration, symlink/private-file/duplicate-JSON refusal, retained preset
validation, and byte-preserving pending mutation refusal. CLI process tests
cover closed arguments, actual framed requests, nonempty resources, and a lost
registration response with no replay. Actual daemon Control/Host tests exercise
the durable owner rather than substituting a canned resource.

The new Swift contract test invokes the existing production handler and owner
for successful registration/show, deterministic parameter/identity/conflict/
quota/unreadable/dependency failures, and staging/rename storage failures using
the existing injected clock and test-owned files. No production fault hook or
hardware fact is added. The native test passed after correcting its test-owned root canonicalization
to use `realpath`: Foundation URL normalization retained `/var`, which the
production owner correctly refused as symbolic ancestry in the initial run.
The successful run recorded 15 actual handler frames. The existing generators
merged those frames with the corpus and regenerated the three method schemas
and baseline pins; `workspace-project-native-recording/provenance.json` records
the source, exact command, test patch, and frame hashes. Contract identity and
method registry remain unchanged. No manually authored frame or error enum was
introduced.

`factsDrifted` during root inspection requires an actual concurrent identity
change. No probabilistic CI race or encoder-only frame is introduced to pretend
this was observed. The owner retains this failure; until a real dispatched
Swift frame extends the sampled vocabulary, the external contract validator
continues its strict `internalError` fallback for the unsupported wire shape.
This is an explicit sampling/observable-error gap, never a success response.

All tests are host filesystem/client fixtures. They provide no real-device or
GJ acceptance evidence. Full repository validation is pending a coordinated
build window; static formatting and diff checks alone are not acceptance.

## Development validation

- Integrated protected main `510b46508d8719318114a17c2567b701297efb65` into
  checkpoint `58ea9b71`, merge `6c17117f`.
- `CARGO_BUILD_JOBS=1 cargo check --manifest-path rust/Cargo.toml --workspace --all-targets`:
  PASS, 34.73 seconds; `/private/tmp/arkdeck-workspace-check-20260919.log`.
- Native Swift wrapper `test --jobs 2 --filter AgentDaemonContractTests/testWorkspaceProjectControlFramesPreserveRegistrationAndStorageFailures`:
  PASS, one test / zero failures;
  `/private/tmp/arkdeck-workspace-swift-sampling-fixed-20260919.log`.
  The preceding root-canonicalization failure is retained at
  `/private/tmp/arkdeck-workspace-swift-sampling-20260919.log`.
- Rust targeted owner (6), actual CLI process (2), and Control (18) tests passed.
  `/private/tmp/arkdeck-workspace-targeted-20260919.log` retains the initial
  daemon test failure: its test adapter incorrectly supplied the LF delimiter to
  `Control.handle_frame`, whose API accepts only the payload. The adapter now
  matches existing daemon tests; its focused rerun passed (one test / zero
  failures), `/private/tmp/arkdeck-workspace-host-fixed-20260919.log`.
- Both contract generators' `--check` drift checks pass. Full repository unified
  validation has not run for this slice.
