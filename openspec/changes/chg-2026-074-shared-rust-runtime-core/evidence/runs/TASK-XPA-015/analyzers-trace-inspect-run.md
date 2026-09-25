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
is S23's chip for the workspace operations and the input gestures.

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

Pending.
