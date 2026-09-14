# Rust CLI `agent run`, `agent status` and `artifact list` — macOS, 2026-09-14

TASK-XPA-014 remains in progress. Base: protected main `47d6f020`, which carries the daemon's
`agent.run`/`agent.status`/`artifact.list` (#1932), #1933 and #1934; no stack. This is the third
slice of milestone M1 (GJ-1) under r11: Golden Journey 1 enters through the CLI
(`arkdeck agent run --operation observe.device@1 --target <TGT>`), and after #1932 the isolated Rust
daemon answers that entry, but the Rust CLI had no `agent` leaves and no `artifact list`. Nothing
installed changes and no device is reached.

## Behaviour

- **Parse** (`arkdeck-cli/src/lib.rs`): `agent run`, `agent status` and `artifact list`, with the
  Swift registry's options (`--execution-id`, `--maximum-wait`, `--reviewed-plan-digest` join the
  existing ones) and its usage refusals: exactly one of `--request-file` and `--operation`, the
  flag form exclusive with a request document (`--capability` and `--reviewed-plan-digest`
  included), `--execution-id` required by `agent status`, exactly one of `--job` and `--import`
  for `artifact list`, bounded durations, a positive binding revision.
- **Intent** (`agent_executions.rs`): Swift `runtimeExecutionIntent` — `--maximum-wait` 5 min by
  default, a lowercase UUID execution identity unless one is given, a `--request-file` read as a
  bounded strict JSON document with the closed request key set and a typed request shape, or the
  flag form with `--inputs-file` (`{}` by default) — then Swift `AgentExecutionIntent`'s checks and
  messages before anything is sent: the closed key set and identities, the exact published
  operation (the Catalog compiled into `arkdeck-contract`), outputs, client context annotations,
  a device-bound binding revision, the capability reference, the reviewed-plan digest and the
  3 MiB canonical bound.
- **Projection** (`validate_execution`): Swift `executionFields` — the closed
  `arkdeck.agent-execution/1` key set, the execution identity, state and generation, the owned
  Job's state, outcome and Session publication agreeing with the execution, a terminal Job's
  evidence and verified Artifacts, and the next-action rules (`humanAction`, `wait`, `reconcile`,
  `readResult`); anything else is `recordUnreadable`.
- **Run** (`main.rs`): Swift `runRuntimeExecution` — `agent.run`, then `agent.status` polled at
  100 ms doubling to 2 s until the execution settles as Swift `emitSettledExecution` settles it: a
  waiting person (`humanActionRequired`, with the resume hint on stderr), a pre-Job failure code,
  an unknown outcome, a finalization to reconcile, a completed execution, or a Job that waits for
  a person. `--timeout` bounds only the client's wait (`clientTimeout`, "client stopped waiting;
  the Runtime execution and Job were not cancelled", with the execution identity). A completed
  run's one document is emitted first; its exit then follows Swift: an unknown outcome 75,
  evidence that could not be verified 2 (`evidenceIntegrityExit`), a failed, cancelled or
  interrupted Job 1 (`terminalJobExit`), an abandoned execution 1.
- **Refusals**: `agent.run` is mutation-capable, so a named refusal keeps its code only with the
  pre-admission zero-dispatch proof and anything unproven, a lost reply included, is
  `outcomeUnknown`; the mutation mapping now keeps every code Swift's mapper keeps
  (`bindingRevisionStale`, the orchestration budget and clock, `humanActionExpired`,
  `factsDrifted`, `targetTrustPending`, `invalidCursor`). `agent.status` is a bounded read: an
  unproven refusal is `internalError`, `rejected` is `operationFailed`. `artifact.list` joins the
  Artifact owner's proven refusals. The exit statuses Swift gives the agent codes (75, 77, 130)
  are added.
- **`artifact list`**: the owner, 100 per page by default, `--cursor`, no item filter or content
  access, and each page checked as Swift `ArtifactResourceProjection.validatePage` checks it: the
  page schema, a UUID snapshot revision, a cursor of that snapshot exactly when more rows follow,
  every row valid metadata of that owner, each identity once, in `createdAtDescArtifactIdAsc`
  order.

## Checks

| Check | Command | Result |
| --- | --- | --- |
| New tests | `cargo test -p arkdeck-cli --test agent_executions` | 10 passed: the Swift argv fixtures of the three commands; the intents of Golden Journey 1's two runs equal to what the Swift CLI sent the oracle (`observed.run`, `captured.run`); Swift's refusals of a bad intent; a request document carried into the intent; every recorded execution checked and settled (pending while the Job runs, settled once it completed); exits of failed, blocked, unknown and abandoned executions; a pre-Job failure and a waiting person raised with the execution; inconsistent projections refused; the recorded refusals keeping their codes with the proof and losing them without it; an Artifact page |
| CLI suite | `cargo test -p arkdeck-cli` | every existing target passes |
| Lint | `cargo fmt --all --check`; warnings-denied Clippy of `arkdeck-cli` for `aarch64-apple-darwin`, `x86_64-unknown-linux-gnu` and `x86_64-pc-windows-msvc` | passed |
| Real processes | `python3 rust/scripts/check-corpus-replay.py` on `tests/fixtures/agent-execution` and `tests/fixtures/observe-device` | PASS on both oracles. The agent oracle: 21 exchanges (the capture run's 8 not replayed) and 38 checks, the 35 of #1932 plus the Rust CLI reading the observed execution after the restart as the socket answers it, listing the observed Job's Artifacts, and running a new execution (`agent run --operation observe.device@1 --target TGT-3ba3f5f43b92 --execution-id gj1-cli --timeout 2m`) to `completed`, its Job `succeeded` and its evidence `verified`, exit 0. The observe oracle: 28 exchanges and 57 checks, the summary byte-identical to #1932's. Summaries `/private/tmp/xpa014-agent-cli-harness-agent-r2.json` (SHA-256 `b7bb07b85e9d48334a2d846f4854b8bc7997884cde2ed06b7b41048430afbbf0`) and `/private/tmp/xpa014-agent-cli-harness-observe-r2.json` (SHA-256 `3d23fca5670c853f80bb1f45d655abcf7624dd0eeb63d4d6dd2486033887d885`). The first run stopped at the daemon's health check on a scoping mistake in the new harness code (a local named `socket` hid the module from the nested request helper), fixed before this run |

## Unified local gate

`python scripts/ci/plan.py --repo-root . --base-revision origin/main --head-revision HEAD
--merge-base --include-worktree --run-local` over this commit on main
`3d880989`, with `ARKDECK_PYTHON` naming `.venv-sdd` and the planner run from a virtual
environment carrying PyYAML 6.0.3 and jsonschema 4.26.0:

| Run | Head | Result | Log |
| --- | --- | --- | --- |
| r1 | `82f43c51` | `gate exit=1`: the common checks and SDD, the Rust lane on the development and candidate views (format, Clippy, the workspace tests — 657 passed in all over the workspace run and both views, none failed — and the contract checks, `check-readonly.py` and every process harness among them) and the macOS facade tests passed; then `cargo deny --locked check` could not fetch the RustSec advisory database ("Error in the HTTP2 framing layer" from github.com), a network failure outside this diff | `/private/tmp/xpa014-agent-cli-gate-20260914-r1.log`, SHA-256 `e111bf9cdeaddc80888e02b914b2d4b4fb6fd4aa7fa556f501b8904d9321c960` |
| r1, continued | `82f43c51` | the steps from the failed one on, as `plan.py` lists them: `cargo deny --locked check` (advisories, bans, licenses and sources ok) and `cargo vet --locked --no-registry-suggestions` (36 fully audited) passed | `/private/tmp/xpa014-agent-cli-gate-20260914-r1-continued.log`, SHA-256 `320014126b8aa5348de186c46258c01f1753ea49d2020d947cb15fa0d8362f3c` |

The amend after r1 only fills in these rows.

After #1934 and #1933 merged (main `47d6f020`), this commit was replayed onto main. The only
conflict was `tasks.md`, where #1933's bullet and this slice's are both kept. The following pass on
that head: `cargo fmt`, the CLI and client tests, warnings-denied Clippy of the CLI, client and
agentd for macOS, Linux and Windows, and `check-corpus-replay.py` on both oracles. The two
summaries (`/private/tmp/xpa014-agent-cli-harness-{agent-execution,observe-device}-r2.json`) are
byte-identical to the r2 summaries above. CI gates the rebased commit.

## Deliberate differences from Swift

- A request document's typed request is checked for its shape only; the Runtime validates the
  intent and the admitter the whole typed request again, as for any caller.
- Ctrl-C is not turned into `clientInterrupted`: the Rust CLI installs no signal handler (the
  workspace forbids `unsafe`, and no signal crate is admitted), so an interrupted run ends as the
  shell ends it, without an envelope. Nothing is cancelled either way.
- Without `--timeout`, each request waits at most 30 s for its answer, where Swift's client waits
  unbounded; the execution's own orchestration budget is `--maximum-wait` either way.
- Refusal and transport wording is the Rust CLI's (T2).

## Not run, and why

- `agent list`, `agent resume`, `agent abandon` and `human-action *`: the Rust daemon does not
  serve them yet.
- No device: DAYU200 is not attached to this host.
