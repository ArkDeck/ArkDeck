# TASK-XPA-018 — client failures named as Swift's CLI names them, failing closed (macOS, 2026-09-25)

TASK-XPA-018 remains in progress. This slice is the hub's next CLI item after
the domain executor port (#2184): how the Rust CLI names a failure between
itself and the Runtime. Base: `main` `2c0c59d6f`, after #2184, #2185 and #2186
merged. #2184's executor now names its client errors through
`CliError::from_client`, which answers `job.submit`'s errors as the removed
`job_plan::mutation_error` did; its replay is unchanged.

**It is also a safety fix.** Before it, seven served leaves answered a reply
lost after their request went out with `runtimeUnavailable`, which a caller
may retry:

- `debug.start` and `debug.evaluate` (the Flash recovery broker);
- `flash.reconcile-alias` and `flash.bind-current-loader`;
- `session.cleanup.preview`, `session.export.preview` and
  `session.export.apply`.

Most mutation-capable methods on the generic path also answered a malformed
reply with `protocolMalformed`. Both break the Constitution's rule that an
uncertain outcome fails closed and an unknown intent is never replayed. Both
are now `outcomeUnknown`, for every method the effect table does not name a
bounded read.

The hub's rulings behind it:

- the 26 differences the first recording showed: codes and details follow
  Swift; the client's deadline uses Swift's fixed sentence; a lost or
  malformed reply keeps this CLI's own words (message text is T2);
- the safety premise: `runtimeUnavailable` only when no byte of the request
  left the process; once the request is out, a failure is `outcomeUnknown`,
  and never replayed;
- the full port of Swift's mapper as the one source of codes, in one slice
  with the safety fix;
- the classes a failure may leave `outcomeUnknown` by, from the CLI product
  spec §8.4 (`docs/design/arkdeck-cli-product-spec.md`, "最小错误 registry"),
  for a mutation-capable method:
  - **A**, §8.4's fixed fallback table, whatever the evidence:
    `unsupportedProtocolVersion`, `malformedFrame`, `unknownMethod`,
    `invalidParams`, `conflict`, `notFound`, `recordUnreadable`, and Swift's
    same pass-through of `workspaceReferenceNotFound`;
  - **B**, zero-dispatch evidence: the pre-admission proof, or the method's
    own owner's proof;
  - **C**, everything else: the transport failures once the request is out,
    `rejected`, `internalError`, an unclassified code, and a named refusal
    without evidence. These must be `outcomeUnknown` (see "The audit" and
    "Declared differences").

Nothing here is device evidence (POL-VERIFY-001, POL-MODE-001). What changes:

- `arkdeck-cli`:
  - a new module `failure_mapping`, a port of Swift's `CLIControlFailureMapper`
    and `CLIControlMethodRegistry.effect(of:)`, with two declared
    fail-closed differences;
  - `CliError::from_connect` (new) and `CliError::from_client`, rewritten on
    the port. The four module mappers are removed
    (`job_plan::mutation_error`, `agent_executions::read_error`,
    `target_resources::client_error`,
    `bootstrap_resources::retirement_error`), as are the special cases around
    them in `from_client` and `main.rs`. The per-method words for an
    unconfirmed reply are kept in one table;
  - every connection site in `main.rs` now names the method it was opened for;
- the Swift oracle test `CLIClientFailureMappingOracleContractTests` (new) and
  its oracle;
- a new Rust test, and nine existing tests that pinned a code Swift's CLI
  does not give (listed below).

No Runtime, client crate, control schema, corpus, Catalog,
`openspec/contracts`, `openspec/specs` or constitution change.

## The safety premise

`runtimeUnavailable` for every method is safe only if the connect step sends
nothing. Both clients were checked:

- **Swift.** `AgentClient` throws `connectFailed` in three places only:
  creating the socket, a socket path that is too long, and `connect()`. All
  three come before any byte is written.
- **Rust.** `Client::connect` and `Client::connect_bounded` open the socket,
  check the peer's identity and set timeouts. Nothing is written until
  `request`, which sends the contract preflight and then the request, and
  whose failures go through `from_client`.

So `from_connect` names only a connection that never carried a byte.

## What changed

| Failure | Before | Now |
| --- | --- | --- |
| The connection never opened | named as a read of a stand-in method (`job.status`, `agent.status`, `job.plan`, `runtime.hdc.status`, `artifact.import.inspect`, `health`), whose name went into the details; the broker leaves and the generic path mapped it as a lost reply | `runtimeUnavailable` for every method, in Swift's words ("connect failed: errno N"), details `{method}` with the method asked |
| The client's own deadline | `clientTimeout` or `outcomeUnknown` per module, in the transport's words | Swift's rule: `clientTimeout` for a bounded read, else `outcomeUnknown`, with Swift's sentence. This includes a socket read timeout (`WouldBlock`) and a deadline passed while connecting |
| A lost or malformed reply, or a connection that ended, for a mutation-capable method | `outcomeUnknown` only where a module listed the method (above) | `outcomeUnknown` for every mutation-capable method, in this CLI's words for what to read next |
| The same, for a bounded read | `runtimeUnavailable` / `protocolMalformed` | unchanged |
| A contract the preflight could not prove, or a request this client refused to encode | `outcomeUnknown` in the modules' own mappers; `protocolVersionUnsupported` elsewhere | `protocolVersionUnsupported` for every method. The business request was never written, and Swift names a failed preflight so too |
| A Runtime refusal | five tables. An unproven refusal of a mutation-capable method on the generic path was `internalError` (`rejected`: `operationFailed`). The display-name mapper kept codes Swift's owner lists do not. `runtime.tool.list` turned `recordUnreadable` into `internalError`, a rule Swift's mapper no longer has. The Trace cache owner's proof also required `purgeScope` | one port of Swift's mapper for every method (owner lists, the 15 codes a pre-admission proof keeps, the effect rule for anything unproven), with the two declared differences below |
| Details | the display-name, workspace-registration and tool-registration answers had no `method`; the display-name refusals had no `wireCode` | every failure names `method`; every refusal keeps the Runtime's details and adds `wireCode` |

The request check this CLI makes before connecting (the request against the
compiled schema) is not a client failure. `runtime tool|bundle register` keeps
its `protocolMalformed` for it, and `validate_read_only_request` answers as
before.

## The audit

The old mapping (`main` `b4981f5f3`) and the new one were run over the same
101,972 inputs: every published method (and an unclassified one), each
paired with 10 transport and contract failures and with 34 wire codes under
28 kinds of evidence. The audit was a scratch test and is not committed. Its
outputs are `/private/tmp/arkdeck-cf-audit-{old,new}.jsonl`, and the report
is `/private/tmp/arkdeck-cf-audit-report3.txt`, which also sorts every cell that leaves `outcomeUnknown` into the classes above.

| Change | Cases |
| --- | --- |
| Unchanged | 75,088 |
| Toward `outcomeUnknown` | 26,061 |
| Between two other codes | 706 |
| Away from `outcomeUnknown`, class A: `recordUnreadable` for `runtime.tool.remove` and `runtime.bundle.remove` without the retirement owner's proof, now `recordUnreadable` (§8.4's fixed table; exit 2, not retryable, needs attention) | 54 |
| Away from `outcomeUnknown`, class B: the same two methods under the pre-admission proof, whose old mapper accepted only the retirement owner's. Six named refusals keep their code, and `fileIdentityChanged`, `ioFailure` and `quotaExceeded` are `internalError` | 18 |
| Away from `outcomeUnknown`, class C | **0** |
| Away from `outcomeUnknown` before the business request was written: `ContractMismatch`/`UnsupportedVersion` on the Import, workspace-registration, display-name, Artifact-export, session-cleanup and Trace-purge methods, now `protocolVersionUnsupported` (not retryable) | 36 |
| Away from `outcomeUnknown`, bounded reads: the Runtime's own `outcomeUnknown` under the Artifact, Import or bootstrap owner's proof, now `internalError` as Swift's owner lists give it; a read leaves nothing behind | 9 |

The first run of the audit found 479 cells after a mutation-capable request
was written. The slice stopped and reported them, with the 36 and the 9
above, and the hub ruled on each:

1. `recordUnreadable` for the two retirements without proof (54): follow
   Swift, as §8.4's fixed table does (class A).
2. `resultNotReady` for the 15 methods the old mutation mapper served (405):
   keep `outcomeUnknown`, or `internalError` with the pre-admission proof.
   This is declared difference D1.
3. The two retirements under the pre-admission proof (20): follow Swift
   (class B). The exception is the Runtime's own `outcomeUnknown` with that
   proof (2). It stays `outcomeUnknown` for every mutation-capable method:
   declared difference D2.
4. The 36 before the business request: follow Swift. Two conditions:
   "before the business frame" must be structural, and a test must show that
   no business frame reaches the Runtime. Both are met (see "The
   preflight").
5. Bounded reads: follow Swift.

## The preflight

`ContractMismatch` and `UnsupportedVersion` come from exactly two places in
`arkdeck-contract`, and both are before the business frame is written:

- `decode_request` (`framing.rs` 197, 200): this client's own check of the
  request it is about to send;
- `validate_health` (`framing.rs` 262–279): the preflight `health` on a fresh
  connection, which `Client::request` completes before it writes the request.

`decode_response`, which reads the answer to a request that went out, never
returns them. The mapping reads the error's variant, never its words.
`leaves::a_contract_the_runtime_cannot_prove_sends_no_business_frame` runs
three mutation-capable leaves against a fake Runtime whose well-formed
`health` names another contract identity: `trace cache purge`,
`target display-name set` and `session cleanup apply`. The fake reads the
preflight and fails on any further frame or connection. Each leaf answers
`protocolVersionUnsupported`: exit 69, not retryable, details `{method}`.

## Declared differences

Where this CLI stays more cautious than Swift's mapper, for a mutation-capable
method only (`failure_mapping::fail_closed`, the hub's rulings):

- **D1. A mutation is never told `resultNotReady`.** That code is retryable
  (`controlRequestRetryable: true` in the error registry), and retrying a
  mutation is the replay POL-RECOVERY-001 forbids. §8.4's fixed fallback
  table does not name `resultNotReady`, so Swift passing it through for
  every method (`CLIControlMethodRegistry.swift` 354) is not the spec's.
  Without proof, §8.4 makes a mutation-capable refusal `outcomeUnknown`; with
  the pre-admission proof, `internalError`. That is the answer this CLI gave
  before. No published mutation-capable method admits `resultNotReady` today,
  so the client's schema check already made such an answer `outcomeUnknown`.
  D1 keeps it so if one ever does.
- **D2. The Runtime's own `outcomeUnknown` stays `outcomeUnknown`**, whatever
  evidence comes with it. Swift reads it under the pre-admission proof as
  `internalError` (the default at 365–370). §8.4 defines `internalError` as an
  unexpected error proven to leave no uncertain mutation. A Runtime that says
  it does not know the outcome proves no such thing: the evidence
  contradicts itself, and the Constitution fails closed.

The replay counts where Swift answers otherwise, for each of the 52
mutation-capable methods: 1,456 answers, which is `resultNotReady` under 27
kinds of evidence, and the Runtime's own `outcomeUnknown` under the
pre-admission proof. Every other answer is Swift's.

The words also differ, as the hub ruled, and there are two more differences:

- **The words for a reply that did not come back whole.** Swift passes the
  transport's own text. This CLI keeps it for a lost reply to a bounded read,
  says the contract was broken for a malformed one, and for a
  mutation-capable method says what to read instead of repeating the request.
- **A contract preflight that fails.** Swift's client turns any failed
  preflight into `unsupportedProtocolVersion` with the pre-admission proof.
  Rust's names what failed (a contract mismatch is `protocolVersionUnsupported`
  without the proof in its details; a lost preflight reply is judged like a
  lost reply). The hub accepted this: it is never less cautious.
- **Answers off the published schema.** Rust's client checks every answer
  against the method's published schema, and Swift's does not. The hub asked
  for this to be recorded with #2184; it makes no difference against a real
  Runtime.

## Swift inconsistencies found (followed, reported)

Swift's daemon recorded three owner refusals that Swift's CLI mapper cannot
name (`Fixtures/ControlFrames`). Swift's CLI reads each as `outcomeUnknown`,
which is fail-closed, and so does this one until the source of truth flips:

- `artifact.import.begin`, `importOwner`, `admissionDenied` ("Import was not
  created by the App transport");
- `runtime.tool.register`, `bootstrapRegistryOwner`, `inputTooLarge` ("HDC and
  its fixed sibling exceed the byte bound");
- `workspace.preset.register`, `workspacePresetOwner`, `fileIdentityChanged`
  ("DevEco child role cannot be opened safely").

## The nine tests that pinned another code

Swift's lines are in `CLIControlMethodRegistry.swift` unless another file is
named, at `main` `b4981f5f3`. The direction is relative to `outcomeUnknown`.

| Test | Case | Was | Now | Swift's rule | Direction |
| --- | --- | --- | --- | --- | --- |
| `current_surface::host_owner_failure_scope_and_lost_reply_are_preserved` | `history.filter.save`, `resourceConflict` under phase `other` | `internalError` | `outcomeUnknown` | 333–343: a named refusal keeps its code only with the pre-admission proof; otherwise a mutation-capable method (136) is `outcomeUnknown` | toward |
| the same test | `runtime.storage.policy`, `resourceConflict` under `historyFilterOwner` | `internalError` | `outcomeUnknown` | 296 (not its owner), then 333–343; mutation-capable (137) | toward |
| `flash_host_reads::runtime::reconcile_alias_…` | the recorded `rejected`, no details | `operationFailed` | `outcomeUnknown` | 357–364: `rejected` without the proof, mutation-capable (163); `CLIRuntimeSession.swift` 137 says the same of `daemonError` | toward |
| `loader_binding::runtime::bind_loader_…` | the recorded `rejected`, no details | `operationFailed` | `outcomeUnknown` | 357–364; mutation-capable (159) | toward |
| `tool_register::endpoint::actual_owner_refusals_…` | the recorded `inputTooLarge` under `bootstrapRegistryOwner` | `inputTooLarge` | `outcomeUnknown` | 251–255: the registration owner list has no `inputTooLarge`; then 333–343 | toward |
| `bootstrap_resources::bundle_list_maps_only_bounded_bootstrap_owner_errors` | `ioFailure` under `bootstrapRegistryOwner` | `ioFailure` | `internalError` | 263–267 (no `ioFailure`), then the default for a bounded read; `runtime.bundle.list` is read-only | neither is `outcomeUnknown` |
| `bootstrap_resources::tool_list_keeps_readonly_connection_and_owner_error_policy` | `recordUnreadable` without proof | `internalError` | `recordUnreadable` | 356: `recordUnreadable` whatever the evidence; `runtime.tool.list` is read-only | neither is `outcomeUnknown` |
| `bootstrap_resources::retirement_preserves_only_proven_owner_failures_…` | `runtime.bundle.remove`, `recordUnreadable` without the retirement owner's proof | `outcomeUnknown` | `recordUnreadable` | 356, and §8.4's fixed fallback table (`recordUnreadable` → `recordUnreadable`) | away, class A (the hub's ruling 1) |
| `bootstrap_resources::tool_retirement_owner_errors_require_exact_proof_…` | `runtime.tool.remove`, `recordUnreadable` without the retirement owner's proof | `outcomeUnknown` | `recordUnreadable` | the same | away, class A (the hub's ruling 1) |
| `trace_cache::tests::purge_receipts_…` | `trace.cache.purge`, `ContractMismatch` | `outcomeUnknown` | `protocolVersionUnsupported` | `AgentClient.swift` 195–211: a failed preflight is `unsupportedProtocolVersion` with the zero-dispatch proof, before the business request is written; then 344. The test now uses a response-side `SchemaMismatch` for the malformed reply, which stays `outcomeUnknown` | away, but before the business request was written |

## The oracle

`rust/tests/fixtures/client-failure-mapping`:

- `cases.json`: 56 failures in full (code, words, details, command): seven
  kinds of failure for eight methods;
- `methods.json`: Swift's code for all 105 classified methods, grouped into
  profiles:
  - four transport failures;
  - 34 wire codes, each with no evidence, the pre-admission proof, and each of
    the 12 owner phases, all also with one dispatch instead of none.
  A variant beyond the first two is recorded only where it changes the
  answer. As it records, the test checks Swift's words and details for every
  entry;
- `provenance.json`.

Recorded twice in the hub's build window, byte for byte the same, then
compared (exit 0 each). `cases.json` equals the copy recorded earlier.

## Tests

| Test | What it holds |
| --- | --- |
| `CLIClientFailureMappingOracleContractTests` (Swift, new) | Records the oracle, or compares with the checked-in one |
| `client_failure_mapping.rs::each_recorded_failure_maps_as_swift_maps_it` | The 56 cases: code and details equal; words equal except the declared ones |
| `…::every_classified_method_maps_every_failure_as_swift_does` | Every classified method: 6 transport answers (with the socket timeout and a deadline while connecting) and 918 refusals, codes and details equal to Swift's except the two declared differences, whose extent (1,456 answers) is counted |
| `…::the_read_only_methods_are_swifts` | The read-only set equals Swift's `boundedReadOnlyMethods` (53), directly; an unclassified method is mutation-capable |
| `…::an_unproven_refusal_of_a_mutation_is_an_unknown_outcome_unless_the_spec_fixes_it` | Class C over every published mutation-capable method: every wire code (36) under every kind of evidence that proves nothing (18) is `outcomeUnknown`, except §8.4's fixed fallbacks (class A) |
| `…::a_mutation_capable_request_that_went_out_is_an_unknown_outcome` | Every published method the effect table does not name a bounded read: a lost reply (four ways), the client's deadline (two), a malformed reply (four) and a connection left unusable are `outcomeUnknown`, exit 75, never retryable, so a method added later is held to it too |
| `…::no_refusal_makes_a_mutation_capable_request_retryable` | The same methods: no wire code (36, including `clientTimeout` and `runtimeUnavailable` sent as the Runtime's own) under any of 10 kinds of evidence is retryable |
| `…::a_connection_that_never_opened_is_unavailable_for_every_method` | Every published method, read-only or not: a connection that never opened is `runtimeUnavailable` and retryable (Swift's `connectFailed`) |
| `…::an_unproven_contract_is_unsupported_for_every_method` | A failed preflight or a refused request encoding is `protocolVersionUnsupported` for every classified method |
| `…::leaves::a_connection_that_never_opened_…` | Eight leaves over seven connection sites, against an absent socket: exit 69, `runtimeUnavailable`, "connect failed: errno 2", details `{method}`, retryable |
| `…::leaves::a_contract_the_runtime_cannot_prove_sends_no_business_frame` | Three mutation-capable leaves against a Runtime publishing another contract: no business frame, `protocolVersionUnsupported`, exit 69, not retryable |

## Mutations

Each mutation changed one place, ran `client_failure_mapping`,
`current_surface`, `bootstrap_resources`, `tool_register`, `flash_host_reads`,
`loader_binding` and the library's unit tests, and restored the file by
digest. The logs are `/private/tmp/arkdeck-cf-mut-run.log`, `…-run2.log` and
`…-run3.log`. All 23 were killed. Two more mutations were run against the
intermediate retirement rule, and both were killed; they went with the rule
when the hub ruled it out.

| Mutation | Killed by |
| --- | --- |
| A connect failure judged by effect | the connect-failure structural test, both replays, the leaf test |
| A lost reply to a read called malformed | both replays, `tool_list_keeps_…` |
| `job.plan` not a bounded read | the per-method replay, the read-only set test |
| An owner's proof without its zero count | the per-method replay, `bundle_list_…`, `tool_list_…` |
| A pre-admission proof without its zero count | the per-method replay |
| Registration keeping `inputTooLarge` | the per-method replay, `actual_owner_refusals_…` |
| An unproven rejection of a read called `admissionDenied` | the per-method replay, an agent-execution test |
| A proven unclassified refusal of a mutation called unknown | the per-method replay |
| `bindingRevisionStale` not among the named refusals | the per-method replay |
| No `wireCode` in a refusal's details | both replays |
| An unproven contract judged as a malformed reply | the post-write structural test, `an_unproven_contract_…` |
| A connect failure in other words | the per-method replay, the leaf test |
| The deadline in other words | the 56-case replay |
| The effect guard inverted | both replays, the post-write structural test and five module tests |
| `job run` connecting as `job status` | the leaf test |
| The generic path mapping a connect failure as a lost reply | the leaf test |
| A socket read timeout not a deadline | the per-method replay |
| An owner's list applied to any method | the per-method replay and three module tests |
| A resume connecting as a mutation's lost reply | the leaf test |
| D1 removed: a mutation told `resultNotReady` | the class-C test, the per-method replay, the no-retryable test |
| D1's `internalError` without a zero count | the class-C test, the per-method replay |
| D2 removed: the Runtime's own `outcomeUnknown` sharpened by a proof | the per-method replay |
| An unproven named refusal of a mutation keeping its code | the class-C test, the per-method replay and four module tests |

## Local targeted checks

Logs are under `/private/tmp/`.

| Check | Command | Result |
| --- | --- | --- |
| fmt | `cargo fmt --all --check --manifest-path rust/Cargo.toml` | exit 0 (`arkdeck-cf-fmt2.log`) |
| clippy | `cargo clippy --manifest-path rust/Cargo.toml -p arkdeck-cli --all-targets -- -D warnings` | exit 0 (`arkdeck-cf-clippy2.log`) |
| clippy, Windows | the same with `--target x86_64-pc-windows-msvc` | exit 0 (`arkdeck-cf-winclippy2.log`) |
| CLI tests | `cargo test --no-fail-fast --manifest-path rust/Cargo.toml -p arkdeck-cli`, after the rebase | exit 0: 329 passed, none failed (`arkdeck-cf-test5.log`); 322 before it |
| Swift oracle | `sh Packages/ArkDeckKit/Scripts/run-swiftpm.sh test --filter CLIClientFailureMappingOracleContractTests`: recorded into `/private/tmp/arkdeck-cfm-oracle-2` and `-3`, byte for byte the same, then compared with the checked-in copy. This was the hub's build window | exit 0 each (`arkdeck-cfm-record-2.log`, `arkdeck-cfm-record-3.log`, `arkdeck-cfm-compare.log`) |
| Audit | the scratch audit test on `main` `b4981f5f3` and on this slice, then `audit_compare.py` | as above; class C: 0 (`arkdeck-cf-audit-report3.txt`) |
| Mutations | `cf_mutations.py` (scratch) | 23 of 23 killed |
| Records | `ARKDECK_PYTHON=<validation venv> sh scripts/check-sdd.sh` | 0 errors, 0 warnings; exit 0 (`arkdeck-cf-sdd.log`) |

Not run:

- `generate-contract.py --check` and the contract views: no contract input
  changes;
- check-readonly and the parity audit: no leaf is added or removed.

## CI

- This PR: pending.
