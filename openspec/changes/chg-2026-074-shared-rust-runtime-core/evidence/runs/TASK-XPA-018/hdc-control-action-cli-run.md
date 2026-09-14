# TASK-XPA-018 — the Rust CLI's `runtime hdc impact-preview` and `runtime hdc restart` (macOS, 2026-09-15, rehung 2026-09-19)

TASK-XPA-018 remains in progress. Base: protected main `521c8fad`, which contains the Rust CLI's
`runtime hdc status` slice (#1992) this one was stacked on; rebased with
`git rebase --onto origin/main bfee57ba` after it merged, without conflict. Formerly stacked:
it extends the same leaf, option and help tables and shares that slice's `tests/support` fake
Runtime. Written on 2026-09-15 as `46577a6e` (declaring TASK-XPA-014) and rehung with
`git rebase --onto agent/xpa-018-runtime-hdc-status-cli-20260919 3e2afda1`; the record moved from
`runs/TASK-XPA-014/`. Every recorded answer here is one Swift's daemon gave; nothing is device
evidence (POL-VERIFY-001, POL-MODE-001). No Swift file changes.

## Already on main / this slice / still remaining

| Already on main | This slice | Still remaining for M1 |
| --- | --- | --- |
| Swift's argv fixtures and frame corpora for both methods; the Rust CLI's `target` and `human-action` leaves (#1967, #1974, #1981); below this slice, the Rust CLI's `runtime hdc status` and the fake Runtime its tests share | `runtime hdc impact-preview` and `runtime hdc restart` in the Rust CLI (`src/hdc_control.rs`); their argv fixtures in `rust/tests/fixtures/current-cli-argv/`; `tests/hdc_control_actions.rs` | The daemon's control-action owner: the preview record, the restart and the approval's dispatch. Their reopen semantics wait for the recovery ruling (design §L.1 item 13). Also the `control-action show\|list\|reconcile` leaves, and the approval at Swift's interactive console |

## What the leaves do

They follow Swift's `CLICommandRegistry` (the `runtime hdc` node) and `runHDCControlAction`
(`CLIHDCControlActions.swift`).

- **The registry's grammar.** Every failure here is `invalidOption` (64), at parse, before the
  handler:
  - every option is required;
  - `--action` is only `restart`;
  - `--expected-server-generation` is a positive integer with no leading zero, at most `Int64.max`;
  - `--preview-digest` is 64 lowercase hexadecimal digits;
  - `--timeout` is a duration of at most a day;
  - unknown and duplicate options, and `--output jsonl`, are refused.
- **The handler's checks.** They run before any connection; a failure is `invalidInput` (65), and
  nothing is sent:
  - `impact-preview` needs an exact restart intent (Swift's `HDCControlActionIntent`): the action
    request is an identifier, the endpoint reference is `hdc-endpoint:` followed by a digest, and
    the generation is canonical. Otherwise: "HDC control-action intent failed validation".
  - `restart` needs one exact preview tuple: two identifiers and a digest. Otherwise: "restart
    requires one exact control-action preview tuple".
- **The request.**
  - `impact-preview` sends `{action, serverEndpointRef, expectedServerGeneration,
    actionRequestId}`.
  - `restart` sends `{controlAction, previewId, previewDigest}`.
  - The answer is emitted as the Runtime gave it, and the process exits 0. That includes a
    restart's `awaitingImpactApproval`: the approval belongs to `human-action resume` at Swift's
    interactive console, which this CLI answers with `humanActionRequired`.
- **Mutations.** A refusal keeps its code only with the pre-admission proof.
  - Both methods' published error details admit only `newDispatchCount`, so no refusal can carry
    that proof. A named refusal is therefore an unknown outcome (75). So are the Rust foundation's
    `rejected` and a lost reply.
  - `unknownMethod` is `controlMethodUnavailable` (69), and `invalidParams` is `invalidInput` (65).
  - A connect failure, before anything is sent, maps as a read does.

## Tests

`crates/arkdeck-cli/tests/hdc_control_actions.rs`:
- **The argv fixtures.** Swift's `runtime.hdc.impact-preview.json` and `runtime.hdc.restart.json`,
  copied byte for byte into `rust/tests/fixtures/current-cli-argv/`, replay through `parse`. Each
  has seven cases.
- **The grammar.** The parameters and wait of a valid preview, and each refusal of the registry.
- **Recorded answers through the actual CLI.** The fake Runtime serves Swift's recorded preview
  (`previewReady`) and restart (`awaitingImpactApproval`). For each, it checks the CLI sends exactly
  the recorded parameters. Both are emitted as answered, with exit 0.
- **Refusals.** For each method, the fake serves four refusals. Each keeps Swift's code and exit
  for a mutation:
  - the corpus's refusal;
  - the Rust foundation's `rejected`;
  - `unknownMethod`;
  - `invalidParams`.
- **Invalid intents and tuples** are refused before any connection.

## Checks

| Check | Command | Result |
| --- | --- | --- |
| The leaves | `cargo test -p arkdeck-cli --test hdc_control_actions` | 4 passed. They cover the two argv fixtures, the grammar, the recorded preview and restart emitted as answered with exit 0, and the eight refusals with Swift's codes and exits. Invalid intents and tuples are never sent |
| Every CLI test | `cargo test -p arkdeck-cli` | 141 passed, none failed: 137 before this slice, plus the 4 above |
| Union merge | `python3 scripts/check_union_merge.py` | ok |
| Lint | `cargo fmt --all -- --check`; `cargo clippy --workspace --all-targets -- -D warnings` for `aarch64-apple-darwin`, `x86_64-unknown-linux-gnu` and `x86_64-pc-windows-msvc` | formatted; clean for all three |

These first ran on 2026-09-15 with #1962's fix picked locally beneath the stack (main `5e966172`
did not compile until #1962 landed); main has carried #1962 since.

### Rehang (2026-09-19)

Three conflicts, all from the retired `749969c9` context below the original stack:
- `src/job_plan.rs`: the lost-reply message table. Only this slice's
  `runtime.hdc.impact-preview | runtime.hdc.restart` arm is added; the retired branch's
  `agent.resume | human-action.resume` arm is not brought back.
- `src/lib.rs`: the mutation list keeps main's `target.adopt` and adds the two methods; the
  timeout chain keeps main's `human_action_timeout` and adds `hdc_timeout`.
- `src/main.rs`: the help text keeps main's line set and inserts the two leaves after
  `runtime hdc status`.
The `rust/README.md` union merge produced only this slice's paragraph. Rerun on the rehung tree:

| Check | Command | Result |
| --- | --- | --- |
| The leaves | `cargo test --locked -p arkdeck-cli --test hdc_control_actions` | 4 passed |
| Every CLI test | `cargo test --locked -p arkdeck-cli` | 146 passed, none failed |
| The leaves against the isolated Rust daemon | fresh development root, no development HDC; `runtime hdc impact-preview --action restart --server-endpoint-ref hdc-endpoint:<sha256> --expected-server-generation 1 --action-request-id req-e2e-0001` and `runtime hdc restart --control-action ca-1 --preview-id pv-1 --preview-digest <sha256>` | both reach the daemon, which answers `rejected` ("this method is unavailable in the read-only Rust foundation") without the zero-dispatch proof; the CLI reports `outcomeUnknown`, exit 75, `attentionRequired: true`, as for any mutation refused without proof |
| Format | `cargo fmt --all -- --check` | formatted |

Log of the cargo runs: `/private/tmp/claude-501/-Users-fuhanfeng-Dropbox-Code-Github-ArkDeck--claude-worktrees-macos-agent-branches-20260919-7896b5/e4ca8ae5-02b3-4669-8ede-6d7975251bb2/scratchpad/logs/hdcctl-cli-targeted.log`.

## Unified local gate

`python scripts/ci/plan.py --repo-root . --base-revision origin/main --head-revision HEAD
--merge-base --include-worktree --run-local`, with `ARKDECK_PYTHON` and the planner from a
virtual environment carrying PyYAML 6.0.3 and jsonschema 4.26.0:

| Run | Head | Result | Log |
| --- | --- | --- | --- |
| 2026-09-19 14:06:54–14:11:13 CST, merge base `81957589` (the diff includes the status slice below) | `e3f42c85` (the evidence-only amend recording this row follows) | **exit 0**. Lanes: rust only. Every cargo test summary sums to 887 passed, 0 failed, 15 ignored; published and candidate contract checks, `check-sdd`, `cargo deny` and `cargo vet` pass | `/private/tmp/claude-501/-Users-fuhanfeng-Dropbox-Code-Github-ArkDeck--claude-worktrees-macos-agent-branches-20260919-7896b5/e4ca8ae5-02b3-4669-8ede-6d7975251bb2/scratchpad/logs/hdcctl-cli-gate.log`, SHA-256 `f34bd17e70805ebc46379cef86c87085ff03ecb19e3cfb9685501eb79c31eff0` |

`cargo clippy --workspace --all-targets --locked --target <t> -- -D warnings` for
`x86_64-unknown-linux-gnu` and `x86_64-pc-windows-msvc`: both exit 0.

Re-stacked on protected main `2a4a3441` (after #1987 merged): gate on `95db93ff`, 2026-09-19
14:47:14–15:02:55 CST, merge base `2a4a3441`: **exit 0**, rust lane; cargo 902 passed, 0 failed,
16 ignored; Linux and Windows target clippy exit 0. Log:
`/private/tmp/claude-501/-Users-fuhanfeng-Dropbox-Code-Github-ArkDeck--claude-worktrees-macos-agent-branches-20260919-7896b5/e4ca8ae5-02b3-4669-8ede-6d7975251bb2/scratchpad/logs/cli2-gate-r2.log`,
SHA-256 `1c4d03b6f62ac23d102f246e4656f5f2739ead47b2bdb2aa2a6f8d893205a9bd`.

## Not run, and why

- **A served preview or restart from the Rust daemon.** On main the daemon still answers both
  methods with the foundation's `rejected` (shown above); the `runtime.hdc.impact-preview` and
  `runtime.hdc.restart` routes over the B lane's HDC lifecycle executor are a separate A-lane
  slice. Its preview record, restart and approval dispatch reopen only after the recovery ruling
  (design §L.1 item 13).
- **The approval at Swift's interactive console**, and the `control-action` leaves.
- **Human output.** Without `--output json`, the leaves print the answer as pretty JSON (T2).
- No device, no real HDC.

After #1992 merged, rebased onto protected main `521c8fad` (`git rebase --onto origin/main bfee57ba`,
no conflict). Serialized gate on `c91b853b`, 2026-09-19 16:05:42 CST–16:09:26 CST: **exit 0**,
rust lane; cargo 917 passed, 0 failed, 16 ignored. Linux and Windows target clippy exit 0. Log
`/private/tmp/claude-501/-Users-fuhanfeng-Dropbox-Code-Github-ArkDeck--claude-worktrees-macos-agent-branches-20260919-7896b5/e4ca8ae5-02b3-4669-8ede-6d7975251bb2/scratchpad/logs/cli2-gate-r3.log`,
SHA-256 `d28f566dbd31d141bd5b665bd430bea72b66f4cd4307cbeeba9b829850496610`.
