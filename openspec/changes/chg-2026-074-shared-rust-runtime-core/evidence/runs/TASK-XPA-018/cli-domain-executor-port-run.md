# TASK-XPA-018 — Swift's domain executor ported to Rust (macOS, 2026-09-25)

TASK-XPA-018 remains in progress. This is the second slice of the domain-leaf
series (group d). It ports Swift's client-side `AgentRuntimeExecutor.run` into
`arkdeck_cli::domain_executor` and replays the first slice's oracle on it.
Base: `main` `b4981f5f3`, where #2183 (the oracle) merged.

The next slice (d3) connects the domain leaves to the executor. So nothing
reaches it yet:

- the 28 leaves without a capture preset go in d3;
- the five leaves with one (`screen capture`, `ui-dump capture`,
  `ui-dump component-detail`, `debug logs`, `trace capture`) follow in d4;
- `flash run` waits for the M4 lane.

Nothing here is device evidence (POL-VERIFY-001, POL-MODE-001). What changes:

- `arkdeck-cli`: the new module `domain_executor` and its tests;
- one new Swift oracle test for the evidence reading, and its oracle.

No Runtime, control schema, corpus, Catalog, `openspec/contracts`,
`openspec/specs` or constitution change.

## What the port does

The port follows Swift's `run(_:)` step by step:

1. The execution identity must be safe. The check is ICU's
   `^[A-Za-z0-9][A-Za-z0-9._-]{0,127}$`, whose `$` also matches before one
   line terminator that ends the text.
2. The clock is read for the start.
3. `health` gives the catalog digest.
4. `operation.describe` gives the binding and the provider.
5. The host scope, or the device target: listed, observed, or adopted when
   none is adopted yet. A person's action is a pause, with the same kinds,
   prompts, resume modes and selection options.
6. `job.submit` with the canonical request under the
   `agent-request-`/`agent-execution-` identities, then `job.run`. A failed or
   non-terminal run gets one `job.cancel`.
7. `job.evidence`, decoded as Swift's `RuntimeHardwareEvidenceTrustedFacts`,
   and every page of `artifact.list`.
8. The receipt, with the Runtime's snapshot when one was read.

How it talks to the Runtime:

- **One connection per request.** The port proves the contract itself with
  its own `health` first, with an uppercase UUID identity, as Swift's client
  does. A failed proof is Swift's refusal
  (`unsupportedProtocolVersion`, pre-admission) and sends no business
  request.
- **Identities.** The executor's requests are `agent-<uuid>`; the Artifact
  pages carry the client's own identity.
- **Errors.** A client error is named by what it proves, as Swift's
  `AgentClientError` names it. Swift's descriptions are rebuilt where a run
  embeds them in a reason or a blocker, for example
  `transport("connection closed before response")` and
  `daemonError(code: …, message: …)`.
- **Pending records** are written as Swift's `JSONEncoder` writes them
  (pretty, sorted, solidus unescaped), to a private temporary file that is
  moved into place.

## Replay

**The 30 scenarios of #2183.** The port runs each one against an in-memory
Runtime that answers as the Swift test's scripted peer did, with a counting
clock. For every scenario the following equal Swift's:

- the frames sent (method, parameters, labelled identity);
- the connections, the clock reads, the unused script and the pending
  record;
- the outcome (kind, reason, receipt, action), or the thrown error's case
  and fields;
- for a thrown client error, the CLI's code, words and details.

**One scenario was re-recorded.** `oneAdoptedTargetFailedJob` first answered
`job.evidence` with a refusal that method does not publish
(`resourceNotFound` without details). Rust's client checks every answer
against the published method schema, so it read that answer as malformed,
while Swift's client, which does not check, read it as a daemon error. The
scenario now answers with the refusal Swift's daemon recorded for a Job it
does not know: `notFound`, "the referenced Job does not exist". #2183's
oracle was re-recorded with it before #2183 merged.

**The evidence reading.** `CLIDomainExecutorEvidenceOracleContractTests`
records Swift's reading of 74 evidence answers into
`rust/tests/fixtures/domain-executor-evidence`: the 21 that Swift's daemon
recorded, and 53 variants of two of them. The variants cover counts, required
and optional members, nulls, unknown members, closed values and recovery
epochs. Swift reads 42 and refuses 32:

- 22 are `DecodingError`s;
- 5 are "Job evidence is not the current resource";
- 5 are "Evidence Artifact count is not canonical".

The port gives the same trusted facts for every answer, as Swift encodes them
again, or the same refusal. A `DecodingError` is Swift's own text; the port
answers in its own words.

## Declared differences

- **Swift's description of a `details` dictionary** is in hash order; the port
  sorts it.
- **A decoding failure's text** is Swift's `DecodingError` description in
  Swift, and this port's own words here.
- **A persistence failure's text** is Swift's `NSError` description in Swift.
- **Answers off the published schema.** Rust's client checks every answer
  against the published method schema and refuses one it does not admit;
  Swift's client does not check. This makes no difference against a real
  Runtime, whose answers all conform. The hub asked for this to be recorded.

## Mutations

Each mutation changed one place in `domain_executor.rs`, ran the module's unit
tests and both replays, and restored the file by digest
(`/private/tmp/arkdeck-dx-mut.log`). All 20 were killed. E8 was killed only by
the compiler, so a variant with the same effect (E8c) was also run: the
scenario replay failed.

| Mutation | Killed by |
| --- | --- |
| No final line terminator allowed in an identity | the unit test |
| A host scope that differs from the project not refused | the scenario replay |
| The imported-Artifact consumers not exempt | the scenario replay |
| The default host scope misnamed | the scenario replay |
| An unlisted target not paused | the scenario replay |
| Ambiguous routes not paused | the scenario replay |
| An unauthorized device read as offline | the scenario replay |
| A choice of targets with only one option (E8c) | the scenario replay |
| No candidates paused without the empty option list | the scenario replay |
| The binding revision not submitted | the scenario replay |
| A lost run not cancelled | the scenario replay |
| A running Job read as terminal | the scenario replay |
| The reconcile prefix lost | the scenario replay |
| Runtime facts always claimed | the scenario replay |
| An integer read from text | the evidence replay |
| A non-canonical count read | the evidence replay |
| No contract proof before a request | the scenario replay |
| A repeated cursor followed | the scenario replay |
| An unknown member kept | the evidence replay |

## Local targeted checks

Logs are under `/private/tmp/`.

| Check | Command | Result |
| --- | --- | --- |
| fmt | `cargo fmt --all --check --manifest-path rust/Cargo.toml` | exit 0 (`arkdeck-dx-fmt.log`) |
| clippy | `cargo clippy --manifest-path rust/Cargo.toml -p arkdeck-cli --all-targets -- -D warnings` | exit 0 after the one `manual_clamp` finding was fixed (`arkdeck-dx-clippy.log`) |
| CLI tests | `cargo test --no-fail-fast --manifest-path rust/Cargo.toml -p arkdeck-cli` | exit 0: 308 passed, none failed (`arkdeck-dx-test.log`); the replays again after the fix: 41 + 2 passed (`arkdeck-dx-test5.log`) |
| Swift oracles | `sh Packages/ArkDeckKit/Scripts/run-swiftpm.sh test --filter 'CLIDomainExecutorOracleContractTests\|CLIDomainExecutorEvidenceOracleContractTests'`: recorded (`ARKDECK_RUST_DOMAIN_EXECUTOR_RECORD=/private/tmp/arkdeck-de-oracle-3`, `ARKDECK_RUST_DOMAIN_EXECUTOR_EVIDENCE_RECORD=/private/tmp/arkdeck-dev-oracle-1`), then compared with the checked-in copies. The hub granted this second build window | exit 0 each; free memory stayed at 40–50% (`arkdeck-dx-record.log`, `arkdeck-dx-compare.log`) |
| Records | `ARKDECK_PYTHON=<validation venv> sh scripts/check-sdd.sh` | 0 errors, 0 warnings; exit 0 (`arkdeck-dx-sdd.log`) |
| After the rebase onto `b4981f5f3` | fmt, clippy and the CLI tests as above, then check-sdd | fmt and clippy exit 0; 316 passed, none failed (the 8 more are #2182's); check-sdd 0 errors (`arkdeck-dx2-fmt.log`, `arkdeck-dx2-clippy.log`, `arkdeck-dx2-test.log`, `arkdeck-dx2-sdd.log`) |
| Windows | `cargo check` and `cargo clippy ... -- -D warnings`, both `--target x86_64-pc-windows-msvc -p arkdeck-cli --all-targets`, after the fix below; then fmt, clippy and the domain-executor tests on macOS | exit 0 each; 42 + 2 + 3 passed (`arkdeck-dx3-wincheck.log`, `arkdeck-dx3-winclippy.log`, `arkdeck-dx3-clippy.log`, `arkdeck-dx3-test.log`) |

Not run:

- check-readonly and the parity audit: no leaf changes;
- `generate-contract.py --check`: no contract input changes.

## CI

- #2182 (`trace inspect`, head `009afd130`): `guard` (run `36122511956`) and
  `swift` (run `36122512141`) passed. All four Rust lanes and `swift-tests`
  passed too. It merged as `ba339f00f`.
- #2183 (the oracle, head `723617781`): `guard` (run `36124559878`) and
  `swift` (run `36124560171`) passed. All four Rust lanes and `swift-tests`
  passed too. It merged as `b4981f5f3`, and this slice was rebased onto it
  without conflicts.
- This PR, first head `0ab7ae263`: the Windows Rust lane failed to compile
  (run `36127080302`). The pending-record writer set the directory's owner-only
  mode through `std::os::unix::fs::DirBuilderExt` in library code. The mode is
  now set only on Unix, as the POSIX mode exists only there; the macOS and
  Linux behaviour is unchanged. The lane had not been checked locally for
  Windows before; it has now (above).
- This PR, second head: pending.
