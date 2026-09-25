# TASK-XPA-018 — the domain leaves' handler, and the host-side read leaves on the Rust CLI (macOS, 2026-09-26)

TASK-XPA-018 remains in progress. Base: protected main `a3de6c316` (#2207), with C0 (#2205) merged; no stack. Slice C1 of the CLI
remaining-leaves lane: the first leaves of group d3 (the domain leaves without a capture preset).
Nothing here is device evidence (POL-VERIFY-001, POL-MODE-001). No Swift source or test, control
schema, corpus, Catalog, `openspec/contracts`, `openspec/specs` or constitution change. Host
evidence only: a fake Runtime on a private socket answering Swift's recorded scripts.

## What changes

- **`arkdeck_cli::domain_leaves`**, Swift's `RuntimeCLI.runDomainOperation`,
  `agentExecutionRequest` and `emitAgentOutcome`, in front of the executor ported in #2184:
  1. The leaf's Catalog operation is the registry's `catalogOperation`; the leaf never names
     another.
  2. The typed request is Swift's `RuntimeAgentExecutionRequest`: `--inputs-file` read as one JSON
     object (every number read as Swift's `JSONValue` reads it: `Int64`, then `UInt64`, then
     `Double`, so `1.0` and `1e2` are integers), `--capability` forwarded as the reference of a
     capability the Runtime already holds (never built here), `--target`, `--execution-id` (a new
     lowercase UUID when absent) and Swift's 900-second budget. An unreadable file, or one that is
     not an object, is Swift's plain usage error (`cannot read typed inputs from <path>`, exit
     64) before any connection.
  3. The executor runs over the local Runtime, one authenticated connection per request
     (`LocalRuntime`), and keeps a pause's pending record in `agent-runtime` beside the Runtime's
     socket, as Swift's `AgentRuntimeExecutor` does by default.
  4. The end, as `emitAgentOutcome` and Swift's `dispatch` render it: a completed run emits its
     receipt; a failed run emits its receipt in a machine mode, then its reason on stderr and exit
     1, and in the human rendering only the reason; a pause is `humanActionRequired` with the
     action's kind, prompt, resume token, selection options and Job in its details, and in the
     human rendering the action and how to resume it on stderr first; a client error the executor
     throws is `CLIRuntimeSession.mapped` under `job.submit`, stamped with the leaf; an executor
     error escapes Swift's handler, so it is its description on stderr and exit 1 with nothing on
     stdout, in every mode.
- **Served**: `workspace status|diff|inspect|read` (`workspace.inspect-git-status@1`,
  `workspace.inspect-diff@1`, `workspace.inspect-source@1`, `workspace.read-source-range@1`) and
  `analyze trace|trace-summary|hilog-summary|crash-signature` (the four analyzers). The other
  domain leaves follow in C2–C5 on the same handler (`domain_leaves::SERVED`).
- `main.rs`: the endpoint and daemon identity are resolved in one function
  (`runtime_endpoint`), shared by `execute` and the domain leaves.

## Declared differences from Swift

- **Human rendering (T2).** Swift prints `completed <reference> job=<id>` for a completed run; the
  Rust CLI prints the receipt as pretty JSON, as every Rust human rendering does.
- **An unreachable Runtime is exit 1, not `runtimeUnavailable`.** The executor's first request is
  its own `health`; Swift turns any failure of it into `RuntimeAgentExecutorError.daemonUnavailable`,
  which escapes the handler (`arkdeck <root>: daemonUnavailable("connectFailed(…)")`, exit 1,
  nothing on stdout). The Rust leaf answers the same, byte for byte, rather than the §8.4
  `runtimeUnavailable` envelope a direct Runtime leaf gives: nothing was sent either way.
- **Windows.** Swift has no Windows CLI. The pending record's directory is derived from the
  endpoint as on macOS; a Windows pipe has no such directory, so a pause there fails closed with the
  executor's `persistence(…)` error (exit 1) and no pending record, and never a half-written one.
- **Resuming a pause.** The pause names `arkdeck agent resume --resume-token <token>`. The Rust
  CLI's `agent resume --resume-token` still sends the token to the Runtime's `agent.resume`
  rather than resuming the client-side pending record as Swift's `executor.resume` does. The host
  leaves served here never pause (their scope is the host), so this matters from C2 on, where the
  executor's resume is ported with the device leaves.

## Tests (`tests/domain_leaves.rs`, the CLI process against a fake Runtime)

- `every_leaf_replays_swifts_recorded_runs`: 28 of the executor oracle's 30 scenarios
  (`rust/tests/fixtures/domain-executor`, recorded by `CLIDomainExecutorOracleContractTests`,
  whose owners include `emitAgentOutcome` and `CLIRuntimeSession.mapped`), each through one of the
  eight leaves in turn, with the scenario's operation named as that leaf's everywhere it appears.
  The executor's path is chosen by what `operation.describe` answers, so the host-scope and the
  device-target scenarios both run. Each must send the recorded frames (labelled identities) over
  as many connections, persist the recorded pending record, and end as recorded: the receipt
  (clock readings taken as recorded), Swift's refusal (code, words, details, exit status), or the
  plain diagnostic. Not replayed: `hostArtifactConsumerKeepsItsTarget`, which its operation's name
  decides (`workspace.apply-patch@1`, C3), and `capabilityWithoutVersion`, whose unversioned
  reference only `agent run --operation` can send.
- `each_ending_renders_as_swifts_handler_renders_it`: the human and legacy `--json` renderings of a
  completed run, a failed run and a pause.
- `unreadable_typed_inputs_are_refused_before_any_request`: an absent file and a non-object, in
  JSON mode: exit 64, empty stdout, no connection.
- `domain_leaves::tests`: Swift's number reading; every served leaf names its operation.

Mutation check (`/private/tmp/arkdeck-cli-lane-mut-c1.py`, baseline passing, each reverted
after): a failed run not emitted in a machine mode, or emitted in the human rendering; a pause
without its Job; the pause's progress dropped; an executor error rendered as an envelope; the
pending records kept elsewhere; a budget other than Swift's 900 seconds; `--capability` or
`--target` not forwarded; the inputs file not read; numbers kept as floats. Each fails a named test
above (`a_pause_carries_its_action_and_job_in_its_details` and
`numbers_are_read_as_swifts_json_value_reads_them` are unit tests; `--capability` is
`a_named_capability_is_forwarded_as_its_reference`, since no replayed scenario names one). One
mutation first survived and its code was removed instead: stamping the leaf on a client error
changes nothing, because every failure envelope already names the invoked leaf.

## Counts

- Rust CLI served leaves: 145/209 → 153/209.
- `cli-parity-audit.py` on this build, registry leaves not served: category 2
  (leaf missing, daemon routed) 41 → 33, category 3 15, category 4 8.

## Local targeted checks

`CARGO_TARGET_DIR=/private/tmp/arkdeck-cli-lane-rust-target CARGO_BUILD_JOBS=2 CARGO_INCREMENTAL=0`

- `cargo fmt --all --check --manifest-path rust/Cargo.toml` — exit 0.
- `cargo clippy --manifest-path rust/Cargo.toml -p arkdeck-cli --all-targets -- -D warnings` —
  exit 0; also with `--target x86_64-pc-windows-msvc` and `--target x86_64-unknown-linux-gnu` —
  exit 0 each (the first cross run caught `runtime_service::utc_now`, a macOS-only module; the
  clock moved to `arkdeck_cli::utc_now`, which `runtime_service` re-exports).
- `cargo test --manifest-path rust/Cargo.toml -p arkdeck-cli` — exit 0
  (`/private/tmp/arkdeck-cli-lane-c1-test-all.log`).
- `python rust/scripts/check-readonly.py --bin-dir /private/tmp/arkdeck-cli-lane-rust-target/debug`
  (validation venv) — exit 0, `PASS`.
- `sh scripts/check-sdd.sh` — exit 0.

## CI

Pending; recorded by the next slice.
