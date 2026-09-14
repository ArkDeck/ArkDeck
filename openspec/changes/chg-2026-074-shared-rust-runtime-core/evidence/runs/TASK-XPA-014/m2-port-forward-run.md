# TASK-XPA-014 — the Rust owner changes port rules as Swift does, on the durable Rust authority: `port-forward.create@1` and `port-forward.remove@1` planned, admitted, run and read, each readback judged against its operation, and a changed rule restored after a confirmed failure (macOS, 2026-09-15, rehung 2026-09-19)

TASK-XPA-014 remains in progress. Base: protected main `81957589` (#1985). The slice was first
written on 2026-09-15 over a pointer-run stack (`261bde58`) that protected main later replaced
with #1984 (`bda735df`, "Execute pointer operations with durable Rust authority"). It is rehung
from `261bde58` onto `81957589` and now runs through #1984's runner; see
[Rehang](#rehang-2026-09-19). Every answer and every file here is replayed from Swift's
port-forward oracle, recorded over the shared fake HDC, in a fixed-root host fixture. None of it is
device evidence or installed-Runtime activation (POL-VERIFY-001, POL-MODE-001).

## Already on main / this slice / still remaining

| Already on main | This slice | Still remaining for M2 |
| --- | --- | --- |
| The port-forward oracle (#1958); the provider's port rules (#1961); the capability store's writes (#1963); the pointer plans (#1964) and admission under Runtime capabilities (#1968); #1984's durable mutation authority: `MutationAuthority` and `MutationExecution`, the account-fixed root and Session continuity, consumption and its evidence before the step intent, settled outcomes, and pointer execution | Both port operations planned, admitted, run and read on that runner: consumption before any step at or above `deviceMutation`, the readback judged against the operation, the compensation that restores a changed rule, `port-rule-readback.json`, and both operations held to the mutation owner in operation availability | `debug.hap@1` (GJ-2) and `deploy.native-library.app-owned@1` (GJ-3); `capture.screen-sequence@1`; recovery, which settles an unknown outcome or a parked Job (design §L.1 item 13, ADR-0009 decisions 2 and 4); the installed signed Runtime, App/CLI journeys on it and real-device acceptance |

## Why

Swift runs `port-forward.create@1` and `port-forward.remove@1` under a Runtime capability, as it
runs the gestures. The Rust owner refused both at planning (`… is not materialized by the Rust
Runtime yet`), so no port rule could be planned, admitted or run.

## What changes

- **Planning** (`job_plan.rs`, `device_steps.rs`):
  - Both operations are materialized. Their inputs are refused by the catalog's rules in Swift's
    words.
  - The provider's port action is named from the inputs (`StepAction::Port`) and lowered to one
    30 s `hdc` process.
  - The journal arguments are Swift's:
    - create: `{forwardId, hostEndpoint, deviceEndpoint}`, host first whatever the direction;
    - remove: `{forwardId}`;
    - readback: `{probeId, expectedState}`. `expectedState` is `absent` exactly when the step is
      journaled under `port-forward.remove@1`.
- **Admission.** Nothing new. Each request is issued a standing capability for its exact rule: all
  three inputs, thirty days, 10000 uses. It needs the account-fixed Job root, as every mutation
  admission on main does.
- **Consumption** (`device_run.rs`, `mutation_execution.rs`). The runner consumes the Job's use
  before any catalog step at or above `deviceMutation`, which is Swift's rule, where #1984 gated it
  on a pointer action. The port change therefore goes through #1984's consumption, renamed
  `consume_mutation_authority` from `consume_pointer_authority`: the account-fixed root and the
  Sessions proved, the plan and binding materialized again, the lineage checked, and the use and
  its evidence durable before the change's intent. The use is settled `confirmed` once the Job is
  terminal, or `outcomeUnknown` when it parks.
- **The verdict** (Swift `RuntimeJobEngine` over `verify-port-rule` and
  `verify-port-rule-compensation`). A create's readback must find the rule and a remove's must
  not; otherwise the step fails with `portForwardReadbackMismatch`. The provider reports only what
  `fport ls` shows.
- **The compensation** (Swift `compensatePortForward`) follows a confirmed failure after a
  completed change:
  1. The Target's facts are read again and must still name the materialized binding (Swift
     `validateMaterializedTargetFacts`).
  2. `compensate-port-rule` runs the inverse change.
  3. `verify-port-rule-compensation` reads it back.

  Both steps run under the inverse operation, which journals them and judges the readback, through
  the same write-ahead dispatch: the typed action persisted and the intent durable before the
  process starts. Neither consumes a use; the Job's consumed use covers them. As for every
  mutation on this runner, the dispatcher must still prove the executable it retained
  (`mutation_identity_current`) before the inverse change. The timeline then says
  `compensated port rule to <operation>`. If the compensation fails, the timeline says
  `port-rule compensation failed closed: <failure>` and the Job fails with the compensation's
  failure.
- **The product.** A verified readback publishes `port-rule-readback.json`.
- **Reads.** `job.result` and `job.evidence` read both operations.
- **Availability** (`operation_availability.rs`, agentd `host.rs`). Both operations are
  unavailable without the mutation owner (`provider_tool_unavailable`,
  `runtime.mutationOwnerUnavailable`), as the gestures are, so the isolated development daemon
  advertises them unavailable. The daemon checks the HDC tool identity for them.

## Checks

Run in this worktree (`/private/tmp/arkdeck-port-forward-20260919`), building only in its own
`rust/target`, on 2026-09-19. Commands run from `rust/` unless stated.

| Check | Command | Exit | Result |
| --- | --- | --- | --- |
| Formatting | `cargo fmt --all --check` | 0 | Clean |
| The port-forward oracle and the pointer replays | `cargo test --locked -p arkdeck-hoststore --test port_forward --test pointer_input_run --test pointer_input_submit --test pointer_input_plan` | 0 | 18 tests pass. `port_forward` (4): (1) all 62 exchanges answered as Swift answered them, message included; the fake received Swift's 40 calls; the Job index (versions 13 for six Jobs, 16 for `ruleUnlisted`, 12 for `readbackUnanswered`), every Job file, the published readbacks, the capability checkpoint and ledger, every Session file and every entry's kind and mode match byte for byte; (2) a refused compensating removal fails the Job with the compensation's failure, its use settled `confirmed`/`failed`; (3) a dispatcher that can no longer prove its executable dispatches no compensating change and writes no compensating intent; (4) an owner under another root admits no rule and issues no capability, and a runner without the mutation owner fails the Job before its change, consuming nothing and dispatching no `fport`. `pointer_input_run` (9), `pointer_input_submit` (4) and `pointer_input_plan` (1) pass unchanged |
| The workspace | `cargo test --workspace --locked --no-fail-fast` | 101 | On the committed tree (`9b9bdd28`, load 31–34 on 8 cores): 837 tests pass, 15 are ignored, and 1 fails, in 113 suites. The failure is `arkdeck-platform` `verified_process::output_overflow_kills_and_reaps_the_child`, whose `elapsed < 2 s` bound on killing `/usr/bin/yes` is a known load-sensitive timeliness assertion; this slice does not touch `arkdeck-platform`, which does not depend on the crates it changes. Alone at the same load it passed once (1.24 s) and failed twice (2.22 s, 2.45 s). An earlier run on the same code but for assertion-only edits to `tests/port_forward.rs` (load 7.5) passed whole: 838 passed, 0 failed, 15 ignored |
| Lints, Linux | `cargo clippy --workspace --all-targets --locked --target x86_64-unknown-linux-gnu -- -D warnings` | 0 | Clean: no warning over every crate and target |
| Lints, Windows | `cargo clippy --workspace --all-targets --locked --target x86_64-pc-windows-msvc -- -D warnings` | 0 | Clean: no warning over every crate and target |
| Lints, macOS | `cargo clippy --workspace --all-targets --locked -- -D warnings` | 0 | Clean: no warning over every crate and target |
| Union-merged records | `python3 scripts/check_union_merge.py` (repository root) | 0 | `check_union_merge: ok` |

Test (3) was also run once with the new identity check disabled: it failed, because the
compensation then removed and re-read the rule. The check was restored before any commit.

## Unified local gate

From the worktree root:

```sh
ARKDECK_PYTHON=/private/tmp/arkdeck-validation-venv/bin/python \
/private/tmp/arkdeck-validation-venv/bin/python scripts/ci/plan.py --repo-root . \
  --base-revision origin/main --head-revision HEAD --merge-base --include-worktree --run-local
```

| Run | Head | Result | Log |
| --- | --- | --- | --- |
| r1 | `c2083315` | `exit=1`. The common checks, SDD, formatting and Clippy passed. The workspace tests stopped on `arkdeck-platform` `verified_process::output_overflow_kills_and_reaps_the_child`, its `< 2 s` bound missed at load 26 on 8 cores (five gates were running at once), after 682 passed and 15 ignored in 86 suites. That test is outside this diff; the contract checks, `cargo deny` and `cargo vet` were not reached | `/private/tmp/claude-501/-Users-fuhanfeng-Dropbox-Code-Github-ArkDeck--claude-worktrees-macos-agent-branches-20260919-7896b5/e4ca8ae5-02b3-4669-8ede-6d7975251bb2/scratchpad/logs/port-forward-gate-r1.log`, SHA-256 `94dd3115d638c31ff5da33cdca444d22261dd688a5b6d4f295185aefdf339888` |
| r2 | `c2083315` | `exit=0`: the common checks (the plan tests, the agent PR workflow tests, SDD, the catalog and contract generation checks), formatting, Clippy, the workspace tests (838 passed, 0 failed, 15 ignored, in 113 suites), the contract-check tests (35), the published and candidate contract checks (the candidate `arkdeck-contract` tests, 46, and the owner scripts), `cargo deny --locked check` and `cargo vet --locked --no-registry-suggestions` (36 fully audited) | `/private/tmp/claude-501/-Users-fuhanfeng-Dropbox-Code-Github-ArkDeck--claude-worktrees-macos-agent-branches-20260919-7896b5/e4ca8ae5-02b3-4669-8ede-6d7975251bb2/scratchpad/logs/port-forward-gate.log`, SHA-256 `df949ce96ce0f9255db10489117773b1d3f3fb31dfec1e9789c29264739559f2` |

`origin/main` was `829e5c8c` by then, so `--merge-base` compared this head with `81957589`, the
ten files of this slice. The planner selected the common checks and the Rust lane; the Swift and
App lanes were not selected for this diff. r2 was started at once after r1, without waiting for the load. The
amend after r2 only fills in these rows and the commit message.

## Not run, and why

- **Recovery** is not ported (design §L.1 item 13, ADR-0009 decisions 2 and 4). That covers
  settling the outstanding readback a parked Job leaves, reconciliation, and the provider's
  reconciliation pieces (`readback`, `desired_presence`, `conclude`, `reconcile_without_readback`),
  which stay unwired. A Job that parks keeps its use `outcomeUnknown`, which blocks the binding's
  next mutation, as the oracle's `afterUnknown` shows.
- **A replay against a live daemon.** The isolated development daemon has no mutation authority:
  its Job store is not the account-fixed root (`require_mutation_state`), so it advertises both
  operations unavailable and refuses their admission. Mutation is exercised only in fixed-root host
  fixtures, as #1984's are.
- **A failed compensation's wording.** Swift interpolates its `RuntimeDispatchFailure` there, and
  this Runtime spells that `failed("…")` as it spells a skipped optional step's failure. No oracle
  records a failed compensation; tests (2) and (3) drive one.
- **Line breaks in `fport ls`.** The provider splits its answer on `\n` alone, where Swift splits on
  every newline character. Only the provider carries this difference, and no oracle answer has
  another line break.
- No device, no real HDC, no installed Runtime.

## Rehang (2026-09-19)

`git rebase --onto origin/main 261bde58` replayed `7d70a45e` onto `81957589`. Conflicts and their
resolutions:

- **`rust/crates/arkdeck-hoststore/src/device_run.rs`** (content). #1984 replaced the runner this
  slice was written against: its `RunAuthority`, `CarriedEvidence` and `authorize_mutation` are
  gone, and `MutationExecution` with `consume_pointer_authority`, the reservation guard, the
  continuity checks and `settle_mutation` took their place. Main's file was kept whole and only
  this slice's parts were re-applied: the readback verdict, the completed-step set, the
  compensation, and the operation passed to the journal arguments. The consumption gate moved
  from "a pointer action" to "a step at or above `deviceMutation`", so the port change consumes
  through #1984's function (renamed `consume_mutation_authority`; its module note names both
  mutations). The compensation dispatches through main's `dispatch_step`, consumes nothing, and
  gained the tool-identity check #1984 requires of every mutation dispatcher.
- **`rust/crates/arkdeck-hoststore/src/device_steps.rs`** (content). #1984 had moved `persisted`
  and `verify` into `StepAction`. Main's version was kept and the port arm added to each method,
  with `claim`, `forward_id`, the port journal arguments (now given the operation) and the
  `verify-port-rule` product.
- **`rust/crates/arkdeck-hoststore/tests/pointer_input.rs`** (modify/delete). Main deleted the
  replaced pointer replay; `pointer_input_run.rs` succeeds it. The file stays deleted, and so does
  the harness `7d70a45e` had moved out of it into `tests/support/device_oracle.rs`, because it
  was built on the replaced `RunAuthority`/`CarriedEvidence` API. `tests/support/mod.rs` is
  main's. `tests/port_forward.rs` now composes its owners as `pointer_input_run.rs` does: the
  fake's fixed root with the Job owner at `store`, `MutationAuthority { default_root:
  <root>/store, sessions: Some(…) }` and `MutationExecution`. The replay passed byte for byte on
  its first run over main's runner.
- **`rust/README.md`** (merge=union, no textual conflict). The union driver resurrected the
  replaced parent's `## Pointer gestures (TASK-XPA-014, M2)` section, which describes code that is
  not on main (`tests/pointer_input.rs`, carried session evidence), and added this slice's own
  `## Port rules` section. Both were removed; the README is main's, since no new README section is
  added.
- **`job_plan.rs` and `job_result.rs`** merged without conflict.
- **Not in `7d70a45e`, needed on main.** Since #1984, operation availability holds the gestures
  to the mutation owner, which the development root never has. Adding the port operations to the
  executable set alone would have advertised them unavailable for a tool drift that did not
  happen, and never for the missing mutation owner. They now join the gestures behind the
  mutation owner, and the daemon checks the HDC tool identity for them.

While this slice was checked, protected main moved on to `829e5c8c` (#1986–#1988). The branch
stays on `81957589`, the base this slice was rehung for. A trial `git merge-tree` of this
slice with `829e5c8c` has no textual conflict, but #1987 adds an `imports` member to
`JobPlanner` and `JobRunner` and sets it in every existing test, so `tests/port_forward.rs` needs
`imports: None` in its planner and runner once rebased there.

## Rebase onto protected main `2a4a3441` (2026-09-19, after #1987 merged)

The slice was rebased from `81957589` onto `2a4a3441` without a textual conflict. #1987 added an
`imports` owner to `JobPlanner` and `JobRunner`, so `tests/port_forward.rs` sets `imports: None` in
its planner and runner (as `pointer_input_run.rs` does); nothing else changed. Targeted rerun:
`cargo test --locked -p arkdeck-hoststore --test port_forward --test pointer_input_run --test
pointer_input_submit --test pointer_input_plan` — 4, 9, 4 and 1 passed. The unified gate is rerun
on the rebased head (below).

## Signature kept for concurrent slices; rebase onto `521c8fad` (2026-09-19)

A trial merge of this slice with the `debug.hap@1` plan (then PR #1993) had no textual conflict but
did not compile: this slice had added a `reference` parameter to `device_steps::journal_arguments`,
which the HAP planner calls with the old three arguments. `journal_arguments(step, inputs, action)`
now keeps main's signature (a port readback defaults to `expectedState: "present"`), and the new
`journal_arguments_for(step, reference, inputs, action)` — used by the port runner and planner —
names `absent` for `port-forward.remove@1`. Behavior is unchanged: the targeted rerun passed
(`port_forward` 4, `pointer_input_run` 9, `pointer_input_submit` 4, `pointer_input_plan` 1,
`observe_device` 1, `capture_diagnostics` 1), and the merge of this slice with the HAP plan
compiled and passed `port_forward` 4, `pointer_input_run` 9, `debug_hap_plan` 2, `job_plan` 3,
`job_admission` 1. #1993 then merged; the slice was rebased onto protected main `521c8fad` without
conflict, and the unified gate is rerun on that head (below).

Gate on `b39c1ca5` (merge base `521c8fad`), serialized, 2026-09-19 16:01:59–16:05:42 CST: **exit 0**,
rust lane; cargo 917 passed, 0 failed, 16 ignored; published and candidate contract checks,
`check-sdd`, `cargo deny` and `cargo vet` passed. Linux and Windows target clippy with `-D warnings`:
exit 0. Log `/private/tmp/claude-501/-Users-fuhanfeng-Dropbox-Code-Github-ArkDeck--claude-worktrees-macos-agent-branches-20260919-7896b5/e4ca8ae5-02b3-4669-8ede-6d7975251bb2/scratchpad/logs/port-forward-gate-r4.log`,
SHA-256 `0ae3586bf2df7c268d621d6858da90272a5661e9862a073d4d68c0daab8b0784`.
