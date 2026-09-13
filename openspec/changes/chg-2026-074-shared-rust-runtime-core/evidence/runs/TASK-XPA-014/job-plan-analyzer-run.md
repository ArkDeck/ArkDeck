# Rust `job.plan` for the crash-signature analyzer — macOS, 2026-09-14

TASK-XPA-014 remains in progress. Base: protected main `7dabc3c3` (#1891). This slice serves
`job.plan` for `analyzer.extract-crash-signature@1` from the isolated Rust development composition,
answering as Swift does, and gives the Rust CLI `job plan`. Nothing is admitted, journaled, reserved
or dispatched, and nothing installed changes. Every request and Artifact is synthetic host data;
nothing here is device evidence.

## Already on main / this slice / still remaining

| Already on main | This slice | Still remaining for TASK-XPA-014 |
| --- | --- | --- |
| Rust reads the v1 Job index, stored records, `job.events` and Artifact routing, and writes current journals, the admission index and `job-record.json` (#1863, #1879, #1889, #1891) | `job.plan` for `analyzer.extract-crash-signature@1`: the current request decoder and fingerprint, the catalog input rules, the analyzer profile and drift check, Swift lease resolution, the plan document digest and the `arkdeck.job-plan/1` projection; `arkdeck job plan`; a Swift-recorded oracle; a real-process Swift/Rust harness; the re-derived `job.plan` method schema | plans of every other operation (device facts, imported leases, debug permits, workspace projects, flash), admission in the published order, capability mint/reserve/consume, executor hand-off, §G.4 preflight, recovery (after the L.1 item 13 ruling), GJ-1..5 |

## Behaviour

`OperationRequest::decode` (`arkdeck-hoststore/src/operation_request.rs`) is Swift
`RuntimeOperationCodec.decodeRequest`: the 1 MiB bound; strict JSON with Foundation's number and
duplicate-key semantics; `RuntimeWireValidation.requestFields` (governance and retired-authority keys,
exact version and document type, closed members); the required members with Swift's
`is required`/`is malformed` messages; the optional members with Foundation's `DecodingError`
descriptions (type mismatch, missing value, missing key, corrupted value, their coding paths and the
name of the value found); then `validate()`. `canonical_bytes` is `CanonicalJSONEncoders.canonical()`
of the typed request, so its SHA-256 is Swift's request fingerprint.

`operation_catalog.rs` is a typed view of the generated catalog: exact id and version lookup,
`validateInputs` with Swift's messages, the effective effect, step selection and the host-only
descriptor check. A catalog `pattern` is refused as unsupported rather than skipped; no operation
this slice materializes declares one.

`JobPlanner` (`job_plan.rs`) keeps Swift's order: exactly one `requestJson` of at most 4 MiB, the
request, the capability refusal, the catalog lookup, the materialized-operation gate, the inputs,
the fingerprint, imported leases, the analyzer profile (absent, drifted), the Artifact store, the
host-only descriptor and unpinned revision, the source lease, the debug permit, the analyzer action's
byte check, the plan document and its digest, and the projection. `ArtifactReadStore::lease` is Swift
`resolveLease`, `storedFileURL` and `validateStoredPayload`: the payload is opened relative to its Job
directory through no link and hashed (`HostDirectory::check_payload`), and a refusal is spelled as
Swift interpolates `RuntimeArtifactError` — `artifactNotFound("ART-…")`,
`ioFailure("malformed job identifier")`,
`indexCorrupted("artifact payload is missing, linked or unreadable (errno 2)")` — or, for a source
collected from another target, as Swift's
`rejected(ArkDeckRuntime.RuntimeOperationErrorCode.invalidInput, "…")`.

`arkdeck-agentd` composes the planner only for an explicit development state root, with the analyzer
`ARKDECK_ANALYZER_PATH` names (a named path that is not an executable fails startup, as for the Swift
daemon). Every refusal carries `{"phase": "preAdmission", "newDispatchCount": 0}`, and an internal
planning failure answers with Swift's single message, "the Runtime could not complete the Job
lifecycle request". The façade still forwards `job.plan` to its Swift daemon, and the standalone
foundation answers `rejected`.

`arkdeck job plan` sends `--request-file` verbatim, or builds the current request from `--target`,
`--operation`, `--inputs-file`, `--expected-binding-revision`, `--request-id` and
`--idempotency-key` (generating `cli-…` identities when absent), applies the catalog's binding rule
as `operatorFlagForm` does, bounds the call by `--timeout` (30 s by default), accepts only a complete
`arkdeck.job-plan/1` projection of an unadmitted plan, and keeps a refusal's code only with the
pre-admission zero-dispatch proof, as the Swift CLI does.

Deliberate differences from Swift, all toward refusal or fewer side effects:

- Every operation but `analyzer.extract-crash-signature@1` is refused with `rejected`
  ("… is not materialized by the Rust Runtime yet") before its inputs are judged.
- A malformed imported (`imp-`) lease is refused as Swift refuses it; a well-formed one is refused
  with `rejected`, because the committed Import owner is not consulted yet.
- A Runtime debug attempt permit filed under the request's idempotency key is refused with
  `rejected`; Swift would read it.
- Planning writes nothing. Swift's lease lookup creates an empty Job directory for a missing Job
  (the harness observed `artifacts/job-oracle-absent`), persists `.payload-verification-v1.json`
  beside the payloads (observed in the oracle recording) and reseals payloads to 0400.
- A payload must also be a private single-link regular file, opened relative to its Job directory;
  a corrupt Job index is refused as `indexCorrupted("artifact index is unreadable")`, where Swift's
  wording depends on its decoder.
- The analyzer path is canonicalized; Swift's `resolvingSymlinksInPath` drops a leading `/private`,
  so a `/private/...` analyzer would drift in Swift only. The harness names `/usr/bin/true`, which both
  resolve alike.
- A flag-form request with an invalid identity or input reaches the Runtime and is refused there
  (`invalidInput`, exit 65) with the same rejection text, where the Swift CLI pre-validates it and
  exits 64 without an envelope.

## Shared oracle

`rust/tests/fixtures/job-plan-analyzer/` was recorded by Swift `JobPlanAnalyzerOracleContractTests` in
record mode (`ARKDECK_RUST_JOB_PLAN_RECORD`) under the fixed physical root
`/private/tmp/arkdeck-job-plan-oracle`, because the plan digest covers the source Artifact's absolute
path; both the producer and `tests/job_plan.rs` take `/private/tmp/arkdeck-job-plan-oracle.lock` and
rebuild the root. `provenance.json` lists the SHA-256 of each file.

| File | Content |
| --- | --- |
| `cases.json` | 71 requests through the Swift control handler and their full responses: 4 planned (plain, with client context, with an empty client context, with no requested outputs) and 67 refusals covering the parameter, decode, catalog, input, host-only, lease, analyzer, drift and payload branches |
| `analyzer` | the analyzer bytes the profile pins (never executed) |
| `artifacts/job-oracle-source/` | the index and two payloads (a crash log and an empty file) Swift published |

The same recording with `ARKDECK_CONTROL_FRAME_LOG` produced 71 `job.plan` frames.
`generate-control-contract.py --derive-method-schemas` over the committed corpus plus those frames
rewrote `spec/control/methods/job.plan.json` — `admissionDenied`, `inputTooLarge` and
`operationUnavailable` join the error codes, `bindingRevision` and `stableIdentitySha256` may be null,
and `sourceArtifactRef` joins the result inputs — and added two corpus frames. Refused parameters stay
in the shapes the corpus already published (`extra: true`, `{}`), so the request schema is unchanged;
a `requestJson` that is not text is covered by a Rust test instead. `generate-contract.py --write`
refreshed the checkout manifest.

## Checks

| Check | Command | Result |
| --- | --- | --- |
| Rust planner | `cargo test -p arkdeck-hoststore --test job_plan` | 3 passed: all 71 oracle answers reproduced (code and message of each refusal, the whole projection of each plan); a `requestJson` that is not text; the Rust-only refusals (an unmaterialized operation, an imported lease, a debug permit) |
| Rust CLI | `cargo test -p arkdeck-cli` | every binary passed; `tests/job_plan.rs` 5 passed (verbatim file and deadline, flag-form envelope and generated identities, refusals, projection check, zero-dispatch mapping) and the `job.plan` argv fixture replays |
| Swift oracle | `run-swiftpm.sh test --filter JobPlanAnalyzerOracleContractTests` | recorded once in record mode; in verify mode 1 executed, 0 failures: Swift regenerates exactly the committed oracle |
| Real processes | `python3 rust/scripts/check-job-plan.py --swift-bin-dir <run-swiftpm debug products>` | PASS, 141 checks: the standalone Swift daemon and the Rust owner, in turn over one state root with `/usr/bin/true` as the analyzer, answer all 67 unchanged-store requests identically; each live Swift answer equals the oracle apart from the analyzer-dependent digest; both CLIs return the same plan for `--request-file` and for the flag form; the Rust CLI refuses a pinned host-only revision and a request file with a flag (exit 64); Rust planning left the Artifact tree unchanged, while Swift's lease lookup created `artifacts/job-oracle-absent`. On `13f99cdd`: summary `/private/tmp/xpa014-job-plan-harness-r2.json`, SHA-256 `5d386b5e9f347f0751a09cf20d8743fc894475fb515e2fe8ecbb456d45f91b3d`, which records the SHA-256 of all four binaries |
| Contract | `generate-contract.py --write`, then `--check` | the checkout manifest describes the new schema and corpus |

## Unified local gate

`python3 scripts/ci/plan.py --repo-root . --base-revision origin/main --head-revision HEAD --merge-base --include-worktree --run-local`,
with `ARKDECK_PYTHON` on the SDD venv and the planner started from a venv holding `PyYAML` and
`jsonschema`. The planner classified 32 changed files and selected the common, design-system, Swift
and Rust lanes (no App build).

- r1 on `2acf7872` ended `gate exit=0` (`/private/tmp/xpa014-job-plan-gate-20260914-r1.log`,
  SHA-256 `1e8564f1021c82876cfd71ece9d2040b0bd60b7434e21d178d2a561c09a78130`). Reading Swift's
  handler afterwards showed it answers every internal planning failure with one generic message; the
  planner now does too, and r2 ran on the result.
- r2 on `13f99cdd` (merge base `7dabc3c3`), `/private/tmp/xpa014-job-plan-gate-20260914-r2.log`:
  - Common checks: planner and agent-PR workflow tests, SDD (0 errors, 0 warnings, 121 acceptance
    IDs), catalog generator tests and `--check`, 83 design-system tests.
  - Swift full lane: `full-parallel` 2,651 tests exit 0 (the oracle test among them),
    `full-process-identity-race` 1 test exit 0, `full-viewer-scale` 5 tests exit 0.
  - Rust lane: `generate-contract.py --check`, `cargo fmt --all --check`, warnings-denied Clippy,
    workspace tests, `test_contract_checks.py` (33 tests OK), `check-contracts.py` passing both views
    with every candidate process harness and `test-macos-facade.py` (7 tests OK), `cargo deny` and
    `cargo vet` (36 fully audited).
  - Result: the log ends `gate exit=0`; SHA-256
    `255c3f7c5fa0a3c39a60f97976825bcb863ede338a2c0698cec2bca53d2fc402`.

## Not run, and why

- No other operation plans yet. Device-bound plans need target facts read by the Rust authority,
  which the admission slice brings; imported leases, debug permits and workspace inputs need their
  owners.
- No admission, capability, journal intent, execution or recovery; ADR-0009 decisions 2/4 (L.1 item
  13) are not ported.
- `check-job-plan.py` needs the SwiftPM daemon and CLI products, so, like
  `check-facade-host-owners.py`, it runs by hand rather than inside `check-contracts.py` or CI.
- No device; DAYU200 is not attached to this host.
