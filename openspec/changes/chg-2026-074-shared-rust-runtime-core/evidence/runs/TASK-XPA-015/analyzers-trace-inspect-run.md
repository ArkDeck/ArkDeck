# TASK-XPA-015 — the remaining analyzers, `trace.inspect`, and an analyzer's agent run

G5 queue slice 13, first half (M3 "no regression after Swift is deleted", A
lane). This record grows with the slice's PRs; each section names its PR, its
base and what it verified.

## 1. `agent run` of an analyzer runs its Job to the end

Base: protected `main` `8e65fc877` (#2156); developed on `333023ae4` (#2154)
and rebased without conflict, then checked again on the new base.

### What a caller saw

The GJ-5 fake rehearsal (S23, `gj5-fake-rehearsal-2026-09-25.md`) found that
`arkdeck agent run --operation analyzer.extract-crash-signature@1 …` never
ended on the Rust daemon, while `job submit` + `job run` of the same request
ran to `succeeded`.

- The execution reached `jobOwned` and stayed there: every `agent.status`
  answered the Job `preflight` with next action `wait` / `job.running`, and
  the client read it again forever (`agent run` has no end of its own but
  `--timeout`, as in Swift's `runRuntimeExecution`).
- The Job could not be run by anyone afterwards either: its journal had
  already moved `preflight → running` (`steps-start`) while its record still
  said `preflight`, so `job.run` refused it as a journal that does not stand at
  its boundary.

### Why

Swift's `AgentExecutionCoordinator.startJob` runs the owned Job with the same
engine that admitted it. The Rust daemon's `Host::start_agent_run`, which runs
the owned Job in the background, composed its `JobRunner` with
`analyzer: None`, while the admission that accepted the Job (the planner inside
`agent_execution`) had the configured analyzer. So the run reached
`steps-start`, found no analyzer profile for the typed action and returned an
internal failure before the record was persisted.

### The fix

`start_agent_run` now takes the analyzer from the same planning composition as
the admission (`rust/crates/arkdeck-agentd/src/host.rs`). Nothing else
changes: the run, its verification, publication and the execution's
`finishJob` are the ones `job.run` already uses.

### Evidence

- New process-level test `an_agent_execution_of_the_analyzer_runs_its_job_to_the_end`
  (`rust/crates/arkdeck-agentd/tests/crash_ledger_analyzer.rs`): an isolated
  daemon whose `ARKDECK_ANALYZER_PATH` names itself, over the reconcile
  oracle's analyzer source, receives the `agent.run` the CLI sends. The test
  waits at most 60 s for the execution's durable record to leave `jobOwned`
  (the client's wait, bounded), then checks the record is `completed` with
  the Job `succeeded` and its outcome known, `job.status` agrees, the derived
  `crash-signature.json` is Swift's analysis of the source beside the source's
  identity (the existing `job.run` test's assertion, now shared), the source is
  untouched and `0400`, and a later `job.run` of the Job is refused
  `resourceConflict`.
- Before the fix (the same test on `333023ae4`, the fix left out): it fails
  after 61 s, "the execution never ended; its Job is "preflight"", with the
  execution record at generation 7, `jobOwned`
  (`/private/tmp/arkdeck-s25-agentrun-before2.log`).
- After the fix: 5/5 in the binary pass in 1.7 s
  (`/private/tmp/arkdeck-s25-agentrun-after2.log`).
- Mutation: putting `analyzer: None` back in `start_agent_run` is caught (the
  test fails at its 60 s bound, as above); restored by SHA-256.

### Left for the contract PR

With the Job now finishing, the first `agent.status` read of the *completed*
execution is refused by the daemon's own conformance check ("the result does
not conform to the current contract", `internalError`): the published
`agent.status` and `agent.run` result schemas were derived from device-bound
executions only, so a host-only execution's `artifacts[].bindingRevision`,
`artifacts[].stableIdentitySha256`, `evidence.artifacts[]…` and
`evidence.bindingRevision` (all `null`, as Swift answers them) do not conform.
`agent run` therefore now ends — with that refusal — instead of waiting
forever; answering `completed` needs a Swift recording of a host-only agent
execution and those two schemas widened (a contract-input change, held for the
coordinator to order against the M4 lane's `generate-contract`). The same gap
is S23's chip for the workspace operations and the input gestures. Section 3
widens the two schemas.

### Checks (local, targeted)

`CARGO_BUILD_JOBS=2`, target `/private/tmp/arkdeck-1330-rust-target`, logs
`/private/tmp/arkdeck-s25-a-*.log`:

- `cargo fmt --all --check --manifest-path rust/Cargo.toml`: exit 0.
- `cargo clippy --manifest-path rust/Cargo.toml -p arkdeck-agentd --all-targets -- -D warnings`:
  exit 0 (no other crate changed; nothing depends on the daemon crate).
- `cargo test --manifest-path rust/Cargo.toml -p arkdeck-agentd --no-fail-fast`:
  exit 0 on the rebased tree; the bin's 84 tests and 69 in 13 integration
  binaries pass (`crash_ledger_analyzer` 5/5, `tests/spawning` 24/24). No
  fake HDC or daemon left running. Logs `/private/tmp/arkdeck-s25-a-r-*.log`
  (before the rebase: `/private/tmp/arkdeck-s25-a-*.log`, 107 + 42, exit 0).
- `sh scripts/check-sdd.sh`: exit 0.
- Not run: `generate-contract.py --check` and `check-contracts.py` (no contract
  input changes), Swift, the App, a device.

### CI

PR #2157, merged as `93fcb4f95`: Agent PR 36071075884, SDD Guard 36071075883
and Swift CI 36071076042 all succeeded (plan; Rust host-independent; Rust
workspace on ubuntu-latest, windows-latest and macos-26; `swift` aggregate;
swift-tests, app-build and ds-interactions skipped by plan).

## 2. `analyzer.summarize-hilog@1` on the Rust daemon

Base: protected `main` `3317bda08` (#2159); developed on `93fcb4f95` (#2157),
rebased without conflict onto `8bd64581b` (#2158) and then `3317bda08`, and
checked again on each (below).

### What a caller sees

- `arkdeck-agentd --summarize-hilog <absolute path>` is Swift's closed HiLog
  mode, answered before anything a daemon does. It reads the one file it is
  named as Swift's bounded reader reads it and prints the canonical
  `HilogSummaryAnalysis`: how many lines, how many blank, how many carry no
  recognized OpenHarmony header, and how many of each severity (`D I W E F`).
  No log body, tag, process ID or timestamp reaches the answer. A usage
  refusal is `analyzer.hilogInvalidArguments` and exit 64; any failure is
  `analyzer.hilogReadFailed` and exit 1 (neither line names the path).
- With `ARKDECK_ANALYZER_PATH` naming the daemon's own executable, the Rust
  Runtime plans, admits (default read-only policy), runs, reconciles and
  publishes `analyzer.summarize-hilog@1`, with `job.plan`/`job.submit`/
  `job.run`/`agent.run` and the reads, and `operation.list` shows it available.
  An analyzer executable that is not this daemon leaves it unavailable as
  `analyzer.hilogRequiresCurrentDaemon`; no analyzer at all, as
  `analyzer.profileUnavailable` — Swift's reasons and codes, before anything
  is admitted.
- The Job runs the daemon with no environment and the source's `/.vol` alias,
  under Swift's 120 s budget, and accepts only a silent child whose stdout is
  the canonical, closed summary of exactly that source (8 KiB at most). It
  publishes `hilog-summary.json` as Swift's `HilogSummaryDerivedArtifact`:
  the source's Artifact ID, the analyzer executable's SHA-256, the digest and
  length of what it printed, and the summary. A signal or timeout parks the
  Job; its reconcile confirms the analysis not performed and fails the Job by
  that name (`executionConfirmedNotPerformed`), never re-running it.

### Swift, the oracle

- The mode (`ArkDeckAgentDaemonMain`): exactly one argument whose first
  Character is `/`; `ArkTraceProfileFileReader.read(path:maximumByteCount:
  allowKernelInodeAlias: true)` — an absolute path walked one component at a
  time with `O_NOFOLLOW` (no `.`/`..`, no symbolic link anywhere, so
  `/tmp/…` is refused), or a `/.vol/<device>/<inode>` alias of canonical
  decimals bound to a regular file; the size fixed at open, read exactly, no
  growth, the same inode and times afterwards and on a second open; then
  `HilogSummaryDerivedAnalyzer.analyze`.
- The summary: lines cut at every line feed byte; a line of spaces, tabs and
  carriage returns is blank; any other line is judged by its first 256 bytes
  less one trailing carriage return, decoded with ill-formed sequences
  replaced (maximal subparts, as Rust's `from_utf8_lossy`), against the
  `NSRegularExpression` header pattern. Its ICU semantics are ported by hand:
  every quantified run is followed by a character it cannot hold, the domain
  ends at the first solidus, the tag is 1–31 code points without a C0 control
  or DEL and may contain colons, and `$` outside multiline mode also matches
  before one final line terminator (LF, VT, FF, CR, NEL, LS, PS, or CR LF).
- The Runtime (`AnalyzerProvider`, `RuntimeArtifactService`): the profile
  exists only when the analyzer executable's SHA-256 equals the daemon's own;
  `verify` adds, after the shared exit/truncation/budget/empty/JSON checks, an
  empty stderr and `HilogSummaryArtifactContract.validateReport` (decode,
  re-encode to the same bytes, the source identity, counts that add up and a
  coverage that matches them), and the summary's `toolSha256`.
- Two new Swift-only recordings, compared byte for byte afterwards
  (`run-swiftpm.sh test --filter 'HilogSummaryAnalyzerOracleContractTests|
  JobRunAnalyzerOracleContractTests|CrashLedgerAnalyzerOracleContractTests'`,
  exit 0):
  - `HilogSummaryAnalyzerOracleContractTests`
    (`rust/tests/fixtures/hilog-summary-analyzer/oracle.json`, 62 cases): the
    built Swift daemon with an empty environment and no stdin, as the Runtime
    runs it — six usage refusals; seventeen read refusals (missing file,
    directory, `/`, mode 000, symbolic link, FIFO, the `/tmp` link, `.`/`..`
    components, a `/.vol` alias of a directory, of a signed, zero-padded,
    overflowing or absent device/inode, or with an extra part); four path
    spellings that read; and 35 contents covering blank lines, CR handling,
    every header part at and past its bounds, the tag's closing and its
    31-code-point bound (supplementary scalars, flags, combining marks), ICU's
    end anchor before each line terminator, the 256-byte prefix (a colon, a
    CR, a character and a tag cut there), sixteen ill-formed UTF-8 sequences
    placed at the tag's bound, a byte order mark, NUL, and 3,000 lines.
  - `JobRunAnalyzerOracleContractTests/testSwiftRunsTheSharedHilogSummaryJobs`
    (`rust/tests/fixtures/job-run-hilog/`): `job.plan` where the analyzer is
    composed, where the host's analyzer is another executable, and where none
    is; then eleven Jobs through `job.submit`/`job.run` with an oracle
    analyzer whose answers are Swift's summaries of the sources (answered;
    trailing newline, stderr, another source's summary and an extra member,
    each `analyzer.schemaMismatch`; exit 3; empty; malformed; scalar; 9,002
    bytes over the 8 KiB budget; signal), every Job's status, details, result
    and evidence, the Job index and files, and every Artifact index and
    payload. All 69 recorded answers conform to the published method schemas,
    so no contract input changes.

### Rust

- `arkdeck-platform/src/profile_file_reader.rs`: Swift's bounded physical
  reader (`read_profile_file`, `open_profile_path`), path classification left
  to the caller.
- `arkdeck-hoststore/src/hilog_summary.rs`: `analyze_hilog`, the argument and
  path rules over Swift Characters (`hilog_source`, `profile_path`), and
  `validate_hilog_report`.
- `arkdeck-hoststore/src/analyzer_composition.rs`: Swift's
  `AnalyzerProvider(profiles:unavailableReasons:)` — the operation→analyzer
  and artifact tables, `AnalyzerProfiles::for_daemon_analyzer`, and
  `runtime_availability` shared by `job.plan`, admission and
  `operation.list`. `JobPlanner`/`JobRunner` take the composition; a single
  `AnalyzerProfile` still composes its own analyzer, so the crash-ledger
  replays are unchanged.
- `job_plan.rs`, `job_run.rs`, `analyzer_output.rs`, `job_reconcile.rs`,
  `job_result.rs`, `operation_availability.rs`: the analyzer step, intent,
  typed action, verification, envelope and publication by operation instead of
  crash-ledger constants.
- `arkdeck-agentd`: `hilog_summary_analyzer.rs` (the mode, answered first in
  `main`, and `composed`, the daemon's analyzer composition from
  `ARKDECK_ANALYZER_PATH` for the isolated and the production composition).

### Differences from Swift (declared)

- A summary that cannot be written to stdout exits 1 with the mode's one line;
  Swift's `FileHandle.write` raises and the process aborts.
- `job.plan`'s `stepSetDigestSHA256` is Rust presentation provenance (#2121)
  that Swift's answer does not carry; the replay checks it separately.
- The two ArkTrace analyzers (`analyzer.summarize-trace@1`,
  `analyzer.analyze-trace@1`) are still not materialized here; they are this
  record's next section.

### Evidence

- `cargo test -p arkdeck-agentd --test hilog_summary_analyzer`: 4/4 — all 62
  Swift cases byte for byte on the first run; the mode first under any
  composition and the facade's name with nothing created; the isolated daemon
  as its own analyzer through `job.run` and `agent.run` publishing Swift's
  summary of the Swift oracle's source beside the daemon's own digest; and an
  analyzer that is not the daemon refused by name at `operation.describe` and
  `job.plan` with no Job created.
- `cargo test -p arkdeck-hoststore --test job_run_hilog`: the three plans,
  eleven admissions and runs, 44 reads, the Job index, every Job file and
  every Artifact index and payload, byte for byte; then the parked Job
  reconciled twice to `executionConfirmedNotPerformed`.
- `operation_availability_control` (agentd bin): the composed crash-ledger
  analyzer leaves the HiLog summary `provider_tool_unavailable`,
  `analyzer.hilogRequiresCurrentDaemon`, `host_configuration`.
- Mutations: 14/14 caught, each restored by SHA-256 (fraction digit lengths,
  NEL as a terminator, the 256-byte prefix, the trailing-CR drop, per-byte
  UTF-8 replacement, a signed `/.vol` device, VT counted blank, a 32-code-point
  tag, the report not re-encoded, stderr ignored, the HiLog profile for any
  analyzer executable, a followed leaf link, the executable digest in the
  envelope, and the agent run's analyzer; log
  `/private/tmp/arkdeck-s25-b-mutations.log`, script in the session scratchpad).

### Checks (local, targeted)

`CARGO_BUILD_JOBS=2`, target `/private/tmp/arkdeck-1330-rust-target`, logs
`/private/tmp/arkdeck-s25-b-*.log`:

- `cargo fmt --all --check`: exit 0.
- `cargo clippy -p arkdeck-platform -p arkdeck-hoststore -p arkdeck-agentd
  -p arkdeck-soak -p arkdeck-cli -p arkdeck-client -p arkdeck-provider-hdc
  -p arkdeck-provider-arkforge -p arkdeck-provider-workspace --all-targets
  -- -D warnings`: exit 0 (the platform change only adds a module; every
  crate that depends on it is checked); the platform, host store and daemon
  again for `x86_64-unknown-linux-gnu` and `x86_64-pc-windows-msvc`: exit 0.
- `cargo test -p arkdeck-hoststore -p arkdeck-platform --no-fail-fast`:
  exit 0, 762 passed, 18 ignored (existing).
- `cargo test -p arkdeck-agentd -p arkdeck-soak --no-fail-fast`: exit 0,
  161 passed. No fake HDC or test daemon left running.
- On the rebased tree (`8bd64581b`): fmt 0; the same clippy 0; `cargo test
  -p arkdeck-hoststore -p arkdeck-platform -p arkdeck-agentd -p arkdeck-soak
  --no-fail-fast` exit 0, 928 passed, 18 ignored (logs
  `/private/tmp/arkdeck-s25-b-r-*.log`).
- On `3317bda08` (#2159 touched only the App's Import ingress and the
  `artifact.import.*` schemas): fmt 0; `cargo test -p arkdeck-agentd` and the
  host store's `job_run_hilog`, `job_run` and `job_plan` replays exit 0, 163
  passed (`/private/tmp/arkdeck-s25-b-r2-test.log`).
- Swift: the three oracle classes above, exit 0.
- `sh scripts/check-sdd.sh`: exit 0.
- Not run: tests of the platform's other dependents (CLI, client, providers:
  the change adds a module and alters nothing they use),
  `generate-contract.py`/`check-contracts.py` (no contract input changes), the
  App, a device.

### CI

PR #2160, merged as `9ae1e4997`: Agent PR 36076386272, SDD Guard 36076386147
and Swift CI 36076386420 all succeeded at `eb7293d87` (plan; Rust
host-independent; Rust workspace on ubuntu-latest, windows-latest and
macos-26; swift-tests; ds-tokens; ds-interactions; `swift` aggregate;
app-build skipped by plan).

## 3. `agent.status` and `agent.run` answer a completed host-only execution

Base: protected `main` `9ae1e4997` (#2160); developed on `3317bda08` (#2159,
after M4's contract-input PR merged) and rebased without conflict;
`generate-contract.py --write` on the rebased tree changed nothing. This is a
contract-input change: `spec/control/methods/agent.run.json`,
`spec/control/methods/agent.status.json`, three new corpus lines and the
regenerated `spec/baselines/swift-single-v1.json` (outside this task's Allowed
paths, declared as the workspace isolation slice declared its own).

### What a caller sees

`arkdeck agent run --operation analyzer.extract-crash-signature@1 …` on the
Rust daemon now ends `completed` with the Job `succeeded`, its derived
Artifact and evidence, and `agent.status` of that execution answers the same.
Since §1 the daemon had refused its own answer to both
(`internalError`, "the result does not conform to the current contract"),
because the published result schemas only knew device-bound executions.

### Swift, the oracle

- `AgentExecutionAnalyzerOracleContractTests/testSwiftCompletesAHostOnlyAgentExecution`
  (new, `rust/tests/fixtures/agent-execution-analyzer/`): the intent the CLI
  sends for `analyzer.extract-crash-signature@1` over a crash listing
  collected from an adopted Target, with the daemon's agent execution owner
  and `AnalyzerProvider` composed beside the shared fake HDC
  (`HDCOracleHarness.composition(analyzers:)`, new: the provider is registered
  and the dispatcher router sends analysis plans to a descriptor-bound
  analyzer dispatcher, as the daemon composes them). The oracle analyzer holds
  until the oracle releases it, so the accepted run's answer keeps the name of
  the Job state it read, not its value; the oracle then waits for the
  execution's durable `completed`, reads `agent.status`, sends the intent
  again, and reads `job.result`, `job.evidence` and `artifact.list`, keeping
  the Target, Job, Session, execution and Artifact files.
- Swift answers a host-only execution with `bindingRevision: null` and
  `stableIdentitySha256: null` on each Artifact (the owned Job binds no
  device), and `evidence.bindingRevision: null`.
- Schemas: the oracle's frames (`ARKDECK_CONTROL_FRAME_LOG`), derived with
  `generate-control-contract.py --derive-method-schemas` over the corpus and
  those frames for the two methods only, widen five members of each result
  from one type to that type or `null`: `artifacts[].bindingRevision`,
  `artifacts[].stableIdentitySha256`, `evidence.artifacts[].bindingRevision`,
  `evidence.artifacts[].stableIdentitySha256`, `evidence.bindingRevision`.
  Nothing else in the structure changes (compared member by member: no
  property, code or requirement removed or added); the corpus grows by the
  run's two `agent.run` frames (26 → 28 lines) and one `agent.status` frame
  (11 → 12). `x-arkdeck-sampleCounts` now counts those corpus lines (28/12
  requests); the earlier counts (59/26) came from a larger recording and no
  check reads them. The baseline is regenerated (105 methods, 994 recorded
  shapes, contract identity `1d7d101e83fe`).

### Rust

No production change: the Rust owners already answer as Swift does once the
schemas admit it.

- `rust/crates/arkdeck-hoststore/tests/agent_execution_analyzer.rs` (new):
  replays the oracle against the agent execution owner, the Job admitter and
  runner with the analyzer, run in the background as `start_agent_run` runs
  it: every answer (the held run's Job state compared by name and required
  non-terminal), the Target document and every file the execution, the Job
  and the Session leave, byte for byte.
- `rust/crates/arkdeck-agentd/tests/crash_ledger_analyzer.rs`: §1's
  process-level test now also reads the completed execution through
  `agent.status` and `agent.run` and requires `completed`, `succeeded` and the
  null revision and identity; in the merge base's published view (narrow
  schemas) it requires the daemon's `internalError` instead, as the other
  published-view tests do.

### Evidence

- The Swift oracle compares byte for byte after recording
  (`run-swiftpm.sh test --filter 'AgentExecutionAnalyzerOracleContractTests|ControlMethodSchemaContractTests'`,
  exit 0, with and without `ARKDECK_CONTROL_FRAME_LOG`, so the recorded
  frames validate against the new schemas).
- `cargo test -p arkdeck-hoststore --test agent_execution_analyzer`: 1/1 on
  the first run.
- Mutations on the rebased tree: 5/5 caught, each restored by SHA-256
  (`agent.status`'s `artifacts[].bindingRevision` narrowed back to an
  integer; a host-only Artifact's revision answered as `0`; its identity as
  `""`; the published view taken for the checkout; the agent run's analyzer
  left out; log `/private/tmp/arkdeck-s25-a2-r-mutations.log`).

### Checks (local, targeted)

`CARGO_BUILD_JOBS=2`, target `/private/tmp/arkdeck-1330-rust-target`, logs
`/private/tmp/arkdeck-s25-a2-r-*.log` (before the rebase:
`/private/tmp/arkdeck-s25-a2-*.log`, the same results):

- `generate-contract.py --write` then `--check`: exit 0, nothing to write.
- `cargo fmt --all --check`: exit 0.
- `cargo clippy -p arkdeck-hoststore -p arkdeck-agentd --all-targets -- -D warnings`:
  exit 0 (only their tests changed).
- `cargo test -p arkdeck-hoststore --test agent_execution_analyzer --test
  agent_execution --test agent_lifecycle --test agent_human_action_raise
  --test agent_human_action_records`: exit 0, 13 passed, 1 ignored
  (existing).
- `cargo test -p arkdeck-contract -p arkdeck-control -p arkdeck-agentd -p
  arkdeck-cli -p arkdeck-client -p arkdeck-soak --no-fail-fast`: exit 0, 505
  passed. No fake HDC or test daemon left running.
- Swift: the two classes above, exit 0.
- `sh scripts/check-sdd.sh`: exit 0.
- Not run: `check-contracts.py` (its two views build the whole workspace
  twice in their own targets, more than this host's free disk allowed; CI's
  Rust lane runs it), the App (it calls neither method; only the CLI does),
  a device.

### CI

PR #2161, merged as `9612b00c0`: Agent PR 36078677970, SDD Guard 36078677985
and Swift CI 36078678268 all succeeded at `961410f7e` (plan; Rust
host-independent; Rust workspace on ubuntu-latest, windows-latest and
macos-26, each running `check-contracts.py`'s published and candidate views;
swift-tests; ds-tokens; ds-interactions; `swift` aggregate; app-build
skipped by plan).

## 4. `trace.inspect` answers as Swift's daemon without a Trace inspector

Base: protected `main` `9612b00c0` (#2161); developed on `9ae1e4997` (#2160)
and rebased without conflict. No contract input changes: the
corpus already holds Swift's refusal (`trace.inspect.jsonl`, the frame with no
parameters) and the method's schema publishes its code and details.

### What a caller sees

`trace.inspect` on the Rust daemon is routed to a Trace inspection owner and
answers every request as Swift's daemon does when it composed no Trace
inspector: `operationUnavailable`, "Trace inspection is unavailable", with the
owner's details (`phase` `traceInspectionOwner`, `newDispatchCount` 0,
`deviceEvidenceCreated` false), before it reads a parameter. Until now the
Rust daemon answered the foundation's `rejected`. The App does not call the
method, so the App transport is unchanged; the Rust CLI has no `trace inspect`
leaf yet (CLI parity, TASK-XPA-018).

### Swift, the oracle

- `RuntimeTraceInspectionResourceHandler` asks for its Artifact owner and its
  inspector before anything else; the daemon composes the inspector
  (`ProductTraceOfflineInspector`, over ArkTrace's
  `TraceOfflineInspectionService` linked into the daemon) only beside a
  `trace-summary@1` profile loaded from an ArkTrace distribution
  (`ARKDECK_ARKTRACE_DESCRIPTOR`).
- `TraceInspectOracleContractTests` (new,
  `rust/tests/fixtures/trace-inspect-unavailable/`): the control-plane
  handler composed as the daemon is without that profile, over the shared
  fake HDC and an adopted Target, answers seven requests — none, the exact
  Job/Artifact request the CLI sends, and each one the owner would otherwise
  refuse `invalidInput` (no sensitive opt-in, a zero or too-long timeout, a
  Session owner, a lone Artifact identity) — all with that refusal, and the
  fake is never called. Every request conforms to the method's request
  schema, so none of them could put a line the schema refuses into a corpus.

### Rust

- `arkdeck-control`: `HostServices::trace_inspection`, whose default is that
  refusal, and the `trace.inspect` route, which hands it every request
  unread. The daemon composes no inspector, so it answers with the default.
- `check-readonly.py` expects the refusal for `trace.inspect`;
  `check-corpus-replay.py` serves the method.

### Evidence

- `cargo test -p arkdeck-control --test read_only`:
  `trace_inspection_without_an_inspector_answers_swift_s_refusal` replays the
  seven exchanges and sends three requests the schema refuses (a member it
  does not declare, values of other types, an extra owner member), which
  reach the same refusal, as in Swift, whose daemon validates no request
  against a method schema; no other owner is entered.
- `check-corpus-replay.py --fixture rust/tests/fixtures/trace-inspect-unavailable`
  over the built daemon and CLI: PASS, 7 exchanges replayed, 13 checks (the
  fake received no call; a restart; the four refused startups).
- `check-readonly.py`: PASS (135 control responses, 13 CLI envelopes).
- Mutations: 6/6 caught, each restored by SHA-256 (the message reworded,
  another owner's phase, a dispatch counted, evidence claimed, the route
  removed, parameters read before the owner; log
  `/private/tmp/arkdeck-s25-c-mutations.log`).

### Differences from Swift (declared), and the decision it needs

On a host whose daemon names an ArkTrace distribution — this maintainer's
installed daemon does (`ARKDECK_ARKTRACE_DESCRIPTOR`) — Swift composes the
inspector and inspects the Trace; the Rust daemon refuses. The inspector is
ArkTrace's own library (`ArkTraceAppSupport.TraceOfflineInspectionService`:
the bundled `trace_streamer` run over the Artifact, SQLite staging, the
schema fingerprint and data quality), linked into the Swift daemon; the Rust
daemon links no ArkTrace. Porting it is not a translation of ArkDeck code, so
the maintainer decides between:

- (a) port ArkTrace's offline inspection to Rust — a second implementation of
  ArkTrace's parser staging and schema derivation inside ArkDeck, which then
  drifts from ArkTrace's own;
- (b) answer from the pinned ArkTrace CLI once `analyzer.summarize-trace@1`
  runs on the Rust daemon (this record's next slices): its `summary --json`
  envelope carries the trace's duration, schema fingerprint, parser identity,
  provenance and data quality. One published field changes meaning:
  `engine.sourceRevision` would be the distribution manifest's
  `source.revision` (the reviewed CLI's revision) instead of the ArkTrace
  library revision the Swift daemon was built with
  (`ArkDeckTraceConfiguration.arkTraceSourceRevision`);
- (c) keep the refusal on the Rust daemon: the App does not call the method;
  a CLI `trace inspect` would answer unavailable after the cutover.

Proposal: (b) once the summary analyzer runs, with `engine.sourceRevision`
documented as the reviewed distribution's revision; (c) until then.

### Checks (local, targeted)

`CARGO_BUILD_JOBS=2`, target `/private/tmp/arkdeck-1330-rust-target`, logs
`/private/tmp/arkdeck-s25-c-*.log`, and again on `9612b00c0`
(`/private/tmp/arkdeck-s25-c-r-*.log`, the same results):

- `cargo fmt --all --check`: exit 0.
- `cargo clippy -p arkdeck-control -p arkdeck-agentd --all-targets -- -D warnings`:
  exit 0 (the daemon is the only crate that depends on `arkdeck-control`).
- `cargo test -p arkdeck-control --no-fail-fast`: exit 0, 30 passed.
- `check-corpus-replay.py` and `check-readonly.py` over
  `cargo build -p arkdeck-agentd -p arkdeck-cli --bins`: PASS.
- Swift: `run-swiftpm.sh test --filter TraceInspectOracleContractTests`,
  exit 0 (recorded, then compared).
- `sh scripts/check-sdd.sh`: exit 0.
- Not run: `generate-contract.py`/`check-contracts.py` (no contract input
  changes), the App (it does not call the method), a device.

### CI

PR #2163, merged as `44774d58c`: Agent PR 36082355422, SDD Guard 36082355614
and Swift CI 36082355706 all succeeded at `db6f633a5` (plan; Rust
host-independent; Rust workspace on ubuntu-latest, windows-latest and
macos-26; swift-tests; ds-tokens; ds-interactions; `swift` aggregate;
app-build skipped by plan).

## 5. The ArkTrace analyzers: Swift's answers without ArkTrace, and the distribution loader

Base: protected `main` `44774d58c` (#2163); developed on `9612b00c0` (#2161)
and rebased without conflict. No contract input changes.

### What a caller sees

- Without `ARKDECK_ARKTRACE_DESCRIPTOR`, `analyzer.summarize-trace@1` and
  `analyzer.analyze-trace@1` answer as Swift's daemon does: `operation.list`
  and `operation.describe` unavailable, `provider_tool_unavailable`,
  `analyzer.arktraceNotFound`, `host_configuration`; `job.plan` and
  `job.submit` refused before admission, `invalidInput` "… is runtime
  unavailable: analyzer.arktraceNotFound", nothing admitted. Until now the
  Rust daemon said it had no executor for them (`operation_not_supported`)
  and refused their plans as `rejected` "not materialized".
- With a descriptor named, nothing changes yet: the production start names
  the variable as unread, and the operations say this Runtime has no executor
  for them. Loading it needs the production trust checker and doctor probe
  (next slice).
- Every analyzer profile's pinned files and trees are measured again at each
  availability read, as Swift's `runtimeAvailability` measures them:
  `tool_identity_drift`, `analyzer.profileIdentityDrift`. The crash-ledger
  and HiLog profiles pin none; their executable is now measured with Swift's
  bounded physical reader (`analyzer.toolIdentityDrift`, as before).

### Swift, the oracles

- `ArkTraceProfileLoaderOracleContractTests` (new,
  `rust/tests/fixtures/arktrace-profile-loader/`): Swift's
  `ArkTraceSummaryAnalyzerProfileLoader.loadProfiles` over 46 distributions
  built at one fixed root, with stub trust checkers (the App tree's digest;
  its files and digest, as the production checker returns them; a refusal; a
  root replaced during the check), a stub doctor and the loader's two hooks.
  It records every input entry, each case's outcome by the reason the daemon
  composes from it, every trust and doctor contract, and every entry left
  afterwards. The cases: two loaded profiles, from the install, with tree
  evidence, and from a private snapshot generation made and then reused; and
  every refusal — a missing, writable or malformed descriptor, a linked,
  missing or writable root, a missing, drifted, duplicated or open manifest,
  one of another contract or type or naming a path out of its root, a
  drifted tool, parser, parser manifest, signing record or receipt, a refused
  or replaced trust check, a failed doctor, a linked layout directory, a
  writable ancestor or tree entry, a linked snapshot root, one replaced once
  bound and a colliding final generation. It pins what Swift's readers accept
  at the edges: a descriptor format version `1.0` or `true` loads
  (`JSONSerialization` bridging), a manifest byte count `64.0` loads, a
  stapled flag `1` does not (`JSONDecoder`), a fullwidth manifest digest
  passes `Character.isHexDigit` and then drifts, malformed descriptor JSON is
  a contract mismatch, and a missing receipt is one too (its path must
  open). Every mode it records is one the oracle or the loader sets, never
  the test process's mask (`run-swiftpm.sh` runs under `077`).
- `ArkTraceAbsentOracleContractTests` (new,
  `rust/tests/fixtures/arktrace-absent/`): Swift's daemon composition with
  the crash-ledger analyzer an installed daemon's `ARKDECK_ANALYZER_PATH`
  names and no descriptor; each operation's descriptor, and the plan and
  submission of a complete request over a raw Trace Artifact.

### Rust

- `arkdeck-platform`: `profile_file_reader.rs` gains Swift's `matches`,
  `isPhysicalDirectory`, `hasNoSymlinkComponent`,
  `openPhysicalDirectoryDescriptor`, `openOrCreateOwnerPrivateDirectory` and
  `validateOwnerOnlyAuthority`; `distribution_tree.rs` (new) is
  `ArkTraceDistributionTreeHasher` (digest, pins, the descriptor-bound copy,
  removal) with `openRelativeDirectoryIfPresent` and the exclusive rename.
- `arkdeck-hoststore`: `arktrace_profile.rs` (new) is the loader, over three
  seams — `DistributionTrust`, `DoctorProbe` and `LoaderHooks` — with
  Swift's string, digest and number readings; `AnalyzerProfile` carries the
  canonical namespace root, pinned files and trees and the reviewed ArkTrace
  contracts; `AnalyzerProfiles::without_arktrace`;
  `runtime_availability` measures the pins; `job.plan` and `job.submit`
  refuse an analyzer operation this Runtime does not materialize by the
  host's reason for its analyzer, after its inputs, as Swift's
  `materializeTypedPlanBeforeAuthorization` does.
- `arkdeck-agentd`: the daemon's composition names both ArkTrace analyzers
  not found when no descriptor is named, in the isolated and the production
  root.

### Evidence

- `cargo test -p arkdeck-hoststore --test arktrace_profile_loader`: all 46
  cases — outcomes, 17 trust contracts, 8 doctor contracts — and the 870
  entries left afterwards (833 before), byte for byte. The first run matched
  every case and differed only in the modes of links and of the collision
  hook's entries, which the Swift test's `077` mask had set; the oracle now
  records neither.
- `cargo test -p arkdeck-hoststore --test arktrace_absent`: the four plan and
  submission answers, nothing admitted, the source untouched.
- `operation_availability_control` (agentd bin): each ArkTrace operation's
  descriptor equals Swift's whole `operation.describe` answer; a named
  descriptor leaves them without an executor.
- Unit tests: the tree digest's layout and byte order (`a-b` before `a/b`),
  empty, linked, group-writable and missing entries, the copy's modes and
  removal, the exclusive rename; owner-only authority below `/private/tmp`
  and refused for a writable ancestor or leaf; the private directory created
  `0700` and never through a link; pins drifting by name.
- Mutations: 9 of 11 caught, each restored by SHA-256 (the tree's mode in
  decimal, its files unsorted, group-writable entries admitted, a Boolean
  format version refused, fullwidth digits not hexadecimal, the trust pins
  unsorted, pins that never drift, another reason for an absent ArkTrace,
  an unmaterialized analyzer refused as unported). The two survivors are
  equivalent for the recorded cases: the snapshot root's identity check
  (twice weakened) is backed by the layout's own physical path check, which
  refuses the same replaced root with the same reason. Log
  `/private/tmp/arkdeck-s25-d-mutations.log`.

### Differences from Swift (declared)

- A named descriptor is not loaded (above).
- A daemon with no `ARKDECK_ANALYZER_PATH` has no analyzer dispatcher in
  Swift, which adds "provider executable is unavailable: no dispatcher route
  is registered for provider analyzer" to every analyzer operation's
  reasons; the Rust daemon gives the first reason only. This predates this
  slice and holds for all four analyzer operations.
- `URL(filePath:)`'s own normalization of a descriptor or root path (a
  repeated or trailing solidus beyond one) is not ported; a trailing solidus
  is dropped, as the loader's directory URLs drop it.

### Checks (local, targeted)

`CARGO_BUILD_JOBS=2`, target `/private/tmp/arkdeck-1330-rust-target`, logs
`/private/tmp/arkdeck-s25-d-*.log`:

- `cargo fmt --all --check`: exit 0.
- `cargo clippy -p arkdeck-platform -p arkdeck-hoststore -p arkdeck-agentd
  -p arkdeck-soak -p arkdeck-cli -p arkdeck-client -p arkdeck-provider-hdc
  -p arkdeck-provider-arkforge -p arkdeck-provider-workspace --all-targets
  -- -D warnings`: exit 0; the platform, host store, control and daemon
  again for `x86_64-unknown-linux-gnu` and `x86_64-pc-windows-msvc`: exit 0.
- `cargo test -p arkdeck-platform -p arkdeck-hoststore --no-fail-fast`:
  exit 0, 770 passed, 18 ignored (existing).
- `cargo test -p arkdeck-agentd -p arkdeck-soak --no-fail-fast`: exit 0, 163
  passed. No fake HDC or test daemon left running.
- Swift: `run-swiftpm.sh test --filter
  'ArkTraceProfileLoaderOracleContractTests|ArkTraceAbsentOracleContractTests'`,
  exit 0 (recorded, then compared).
- `sh scripts/check-sdd.sh`: exit 0.
- Again on `44774d58c` (`/private/tmp/arkdeck-s25-d-r-*.log`): fmt 0; the two
  replays, `operation_availability_control` and `read_only` exit 0;
  `check-readonly.py` over the built daemon and CLI: PASS.
- Not run: the other dependents' tests (CLI, client, providers: they use
  nothing that changed), `generate-contract.py`/`check-contracts.py` (no
  contract input changes), the App, a device.

### Next

The production trust checker (`SecStaticCode` validity against the Developer
ID and notarization requirement, signing information, leaf certificate,
CDHashes, Info.plist, stapled ticket), the production doctor probe (the CLI's
`doctor --self-test` through a verified canonical-path launch, with its
pinned files and trees held and its envelope validated), and the daemon
loading the named descriptor into a private snapshot root; then
`trace-summary@1` and `trace-analysis@1` planned, run and verified
(`ArkTraceSummaryEnvelopeValidator`, `ArkTraceAnalysisEnvelopeValidator`).

### CI

PR #2164, merged as `3d878b183`: Agent PR 36083721545, SDD Guard 36083721495
and Swift CI 36083721718 all succeeded at `eb6483f38` (plan; Rust
host-independent; Rust workspace on ubuntu-latest, windows-latest and
macos-26; swift-tests; ds-tokens; ds-interactions; `swift` aggregate;
app-build skipped by plan).

## 6. The ArkTrace production trust checker, doctor probe and verified launch

Base: protected `main` `3d878b183` (#2164). No contract input changes.

### What changes

Nothing a caller reads yet: the daemon still composes no loader (§5). This
slice ports the three production pieces the loader needs to load a named
descriptor — the trust checker, the doctor probe and the verified launch the
probe (and later the analyzers) runs the CLI with — and proves them on the
maintainer's host against the reviewed, signed and notarized ArkTrace
distribution the installed Swift daemon names.

### Swift, the oracles

- `ArkTraceDoctorOracleContractTests` (new,
  `rust/tests/fixtures/arktrace-doctor/`): Swift's
  `ProductionArkTraceDoctorProbe.probe` over a stand-in CLI compiled from
  `fake-arktrace.c` into a bundle at one fixed root (a Mach-O, so the
  verified canonical-path launch can prove its first mapping), which logs its
  argument zero, arguments and two home variables and answers with the
  oracle's bytes. 37 cases: the reviewed envelope (and with trailing
  whitespace, and a check name of exactly 128 bytes) accepted; every
  member of another value, set or type (the tool's name, version and build
  revision, the command, the self-test parameter as `false` or `1`, the
  schema version, a non-null trace, the limits, a warning, the quality
  status, a truncation, the result's self-test), eight or reordered checks, a
  failed one, a check name empty, too long, or holding a control or format
  character, an extra or duplicate member, a fractional or Boolean timeout, a
  non-zero exit, a diagnostic, output past the 256 KiB kept, none, or not
  JSON — each refused after one launch; a drifted tree, a drifted pinned file
  and a namespace another user could write — each refused before anything
  runs. It records every verdict, every launch and the private home made.
  The envelope names the executable's own digest, which depends on the
  compiler, so it is recorded as `SHA`.
- `ArkTraceReviewedDistributionOracleContractTests` (new, host acceptance):
  Swift's production load of a reviewed distribution at a fixed root, run
  only when `ARKDECK_REVIEWED_ARKTRACE_DESCRIPTOR` names one; nothing is
  checked in, since a reviewed distribution is a host's.

### Rust

- `arkdeck-platform`: `verified_launch.rs` (Swift's
  `VerifiedRegularFileDescriptor` and `VerifiedDirectoryDescriptor`:
  pinned files held open and bound to their digests, the bundle's owner-only
  directory held open, both checked again by descriptor and by path);
  `VerifiedTool::run_tool_at_canonical_path` (Swift's
  `.verifiedCanonicalPath`: the child spawned suspended at the canonical
  path, its first executable mapping — `proc_pidinfo`
  `PROC_PIDREGIONPATHINFO` — proved to be the retained inode, the caller's
  bindings checked before and after the spawn, killed before it runs on any
  failure); `static_code.rs` (the Security framework's `SecStaticCode`
  validity against a requirement, strict, all architectures, nested code,
  then the team, hardened runtime, code directory hash, leaf certificate
  subject summary and SHA-1 — CommonCrypto — and identifier).
- `arkdeck-hoststore`: `arktrace_doctor.rs` (`ProductionDoctorProbe`, its
  private home, and Swift's closed envelope validator with
  `StrictJSONIntegerTokenValidator`; names are judged against the host's
  control set, Cc and Cf, as `CharacterSet.controlCharacters`);
  `arktrace_trust.rs` (`ProductionDistributionTrust`: formats, the Developer
  ID and notarization requirement for App and helper, both tree digests,
  `Info.plist`'s bundle, version and build, the stapled `CodeResources`);
  `AnalyzerProfile::holds`.

### Evidence

- `cargo test -p arkdeck-hoststore --test arktrace_doctor`: all 37 verdicts,
  every launch (argument zero, arguments, home) and the private home, as
  Swift's, on the first run.
- Host acceptance on this Mac (`ARKDECK_REVIEWED_ARKTRACE_DESCRIPTOR` = the
  descriptor the installed daemon names): Swift's production load recorded
  at `/private/tmp/arkdeck-arktrace-reviewed` (1.7 s: trust, the real CLI's
  `doctor --self-test`, the snapshot generation), then `cargo test -p
  arkdeck-hoststore --test arktrace_reviewed` with
  `ARKDECK_REVIEWED_ARKTRACE_SWIFT` pointing at it: the Rust load (2.4 s)
  gives the same two profiles byte for byte — 52 pinned files, the App tree
  `5f9ff8b3…` the manifest reviews — and both hold. Nothing installed was
  written; the snapshot and the doctor's home were under `/private/tmp`.
  Logs `/private/tmp/arkdeck-s25-e-reviewed-{swift,rust}.log`.
- Unit tests: a resource bound to its digest and path (the `/tmp` alias
  read below `/private`, a replacement at its path refused, a linked path
  refused); a namespace that stays owner-only and itself; the integer token
  validator; the trust formats and `CFBundleVersion`'s description; unsigned
  bytes refused whatever the manifest says.
- Mutations: 7 of 8 caught, each restored by SHA-256 (format characters
  allowed in check names, `maxRows` unchecked, truncated output accepted,
  diagnostics accepted, the private home left `0755`, a writable namespace
  admitted — by the unit test, the replay's tree check refusing it first —,
  a lowercase team admitted). The survivor, the bindings not checked again
  after the spawn, is equivalent for the recorded cases, which change
  nothing inside the spawn window. Log `/private/tmp/arkdeck-s25-e-mutations.log`.

### Differences from Swift (declared)

- A child's base environment: Swift passes the daemon's own `PATH`, `HOME`,
  `TMPDIR` and `LANG`; the Rust daemon's tool runs get `PATH=/usr/bin:/bin`,
  `LANG=C` and `LC_ALL=C` (every Rust tool run, as declared before). The
  doctor's `HOME` and `CFFIXED_USER_HOME` are the private home in both.
- `String(describing:)` of `CFBundleVersion` is ported for the scalar values
  (a string, an integer, a Boolean, an integral real); no collection can be a
  reviewed build.

### Checks (local, targeted)

`CARGO_BUILD_JOBS=2`, target `/private/tmp/arkdeck-1330-rust-target`, logs
`/private/tmp/arkdeck-s25-e-*.log`:

- `cargo fmt --all --check`: exit 0.
- `cargo clippy -p arkdeck-platform -p arkdeck-hoststore -p arkdeck-agentd
  -p arkdeck-soak -p arkdeck-cli -p arkdeck-client -p arkdeck-provider-hdc
  -p arkdeck-provider-arkforge -p arkdeck-provider-workspace --all-targets
  -- -D warnings`: exit 0; the platform, host store and daemon again for
  `x86_64-unknown-linux-gnu` and `x86_64-pc-windows-msvc`: exit 0.
- `cargo test -p arkdeck-platform -p arkdeck-hoststore --no-fail-fast`:
  exit 0, 784 passed, 18 ignored (existing).
- `cargo test -p arkdeck-agentd -p arkdeck-soak -p arkdeck-provider-hdc -p
  arkdeck-provider-workspace --no-fail-fast`: exit 0, 371 passed (every tool
  run goes through the refactored runner). No fake HDC or stand-in left
  running.
- Swift: `run-swiftpm.sh test --filter
  'ArkTraceDoctorOracleContractTests|ArkTraceProfileLoaderOracleContractTests|ArkTraceReviewedDistributionOracleContractTests|ArkTraceAbsentOracleContractTests'`,
  exit 0 (the reviewed one skipped without its variables; run with them
  above).
- `sh scripts/check-sdd.sh`: exit 0.
- Not run: the CLI's and client's tests (they use no changed API),
  `generate-contract.py`/`check-contracts.py` (no contract input changes),
  the App, a device.

### Next

The daemon composing the loader for a named descriptor
(`ProductionDistributionTrust`, `ProductionDoctorProbe` under
`<state>/arktrace-availability-home`, snapshots under
`<state>/arktrace-profile-snapshots`, Swift's reasons on failure), together
with `trace-summary@1` planned, run through the verified canonical-path
launch with the profile's pins, verified by `ArkTraceSummaryEnvelopeValidator`
and published; then `trace-analysis@1` (`ArkTraceAnalysisRequest`,
`ArkTraceAnalysisEnvelopeValidator`).

### CI

Pending.
