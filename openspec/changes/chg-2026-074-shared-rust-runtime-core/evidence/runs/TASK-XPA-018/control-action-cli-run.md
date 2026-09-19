# TASK-XPA-018 — the Rust CLI's `control-action list|show|reconcile` (macOS, 2026-09-15, rehung 2026-09-19)

TASK-XPA-018 remains in progress. Base: the Rust CLI's `runtime hdc impact-preview` and
`runtime hdc restart` slice (#1995, merged as `b5f9d6a6`) and the `runtime hdc status` slice (#1992),
both on protected main `b5f9d6a6`; rebased with `git rebase --onto origin/main 72b452d0` after #1995
merged, without conflict. Stacked: it extends the same
tables and the module those leaves added. Written on 2026-09-15 as `8a3acf83` (declaring
TASK-XPA-014) and rehung with `git rebase --onto e3f42c85 46577a6e`; the record moved from
`runs/TASK-XPA-014/`. Every recorded answer here is one Swift's daemon gave; nothing is device
evidence (POL-VERIFY-001, POL-MODE-001). No Swift file changes.

## Already on main / this slice / still remaining

| Already on main | This slice | Still remaining for M1 |
| --- | --- | --- |
| Swift's argv fixtures and frame corpora for the three methods; below this slice, the Rust CLI's HDC restart preview and request | `control-action list`, `show` and `reconcile` in the Rust CLI (`src/hdc_control.rs`); their argv fixtures in `rust/tests/fixtures/current-cli-argv/`; `tests/control_actions.rs` | The daemon's control-action owner; its reconciliation waits for the recovery ruling (design §L.1 item 13) |

## What the leaves do

They follow Swift's `CLICommandRegistry` (the `control-action` node) and `runHDCControlAction`
(`CLIHDCControlActions.swift`).
- **The registry's grammar.** Every failure here is `invalidOption` (64):
  - `show` and `reconcile` require `--control-action`;
  - `list` takes `--kind`, which is only `hdcLifecycle`;
  - `list` takes `--state`, which is one of Swift's twelve control-action states;
  - `--page-size` is a positive integer of at most 1,000;
  - `--cursor` is opaque;
  - each leaf also takes `--timeout`.
- **The handler's check.** A `show` or `reconcile` whose control action is not an exact identifier
  is `invalidInput` (65), "an exact control-action identity is required", and nothing is sent.
- **The request.** `show` and `reconcile` send `{controlAction}`. `list` sends the filters it was
  given, with the page size as a number, as Swift does. The answer is emitted as the Runtime gave
  it.
- **Mutations.** Swift classes all three as mutation-capable, the reads included: a preview's
  expiry and snapshot can be written behind them.
  - A refusal keeps its code only with the pre-admission proof. Their published details admit
    only `newDispatchCount`, so a named refusal is an unknown outcome (75), as is a lost reply.
  - `unknownMethod` and `invalidParams` map as Swift maps them.
  - A connect failure, before anything is sent, maps as a read does.

## Tests

`crates/arkdeck-cli/tests/control_actions.rs`:
- **The argv fixtures.** Swift's `control-action.list.json`, `control-action.show.json` and
  `control-action.reconcile.json`, copied byte for byte, replay through `parse`.
- **The grammar.** The filters and page size a `list` sends, and each refusal of the registry.
- **Recorded answers through the actual CLI.** The shared fake Runtime serves Swift's recorded
  `show`, `list` and `reconcile` and checks that the CLI sends exactly the recorded parameters. All
  three are emitted as answered.
- **Refusals.** The corpora's refusals, the Rust foundation's `rejected`, and `unknownMethod`, each
  with Swift's code and exit. An invalid identity is refused before any connection.

## Checks

| Check | Command | Result |
| --- | --- | --- |
| The leaves | `cargo test -p arkdeck-cli --test control_actions` | 4 passed. They cover the three argv fixtures, the grammar, the recorded show, list and reconciliation emitted as answered, and each refusal with Swift's code and exit. An invalid identity is never sent |
| Every CLI test | `cargo test -p arkdeck-cli` | 145 passed, none failed: 141 before this slice, plus the 4 above |
| Union merge | `python3 scripts/check_union_merge.py` | ok |
| Lint | `cargo fmt --all -- --check`; `cargo clippy --workspace --all-targets -- -D warnings` for `aarch64-apple-darwin`, `x86_64-unknown-linux-gnu` and `x86_64-pc-windows-msvc` | formatted; clean for all three |

The first run failed in two places:
- Clippy on Linux rejected the test's control-action constant, which only the macOS module used. It
  now lives in that module.
- The HAR CLI's refusal test failed once. That was the shared fake's race: it closed its end before
  the bounded client's next read. The HAR CLI slice fixes the race below this one.

The rerun passed (2026-09-15, with #1962's fix picked locally beneath the stack; main has carried
#1962 since). The race fix lived in the retired HAR CLI branch's fake, which the status slice moved
into `tests/support`, so the rehung stack keeps it.

### Rehang (2026-09-19)

Two conflicts, both from the retired `749969c9` context: the lost-reply message table in
`src/job_plan.rs` (only the three control-action methods join the HDC arm; the retired
`agent.resume` arm is not brought back) and the help text in `src/main.rs` (main's lines kept,
the two `control-action` lines inserted after `runtime hdc restart`). The `rust/README.md` union
merge produced only this slice's paragraph. Rerun on the rehung tree in a fresh target:

| Check | Command | Result |
| --- | --- | --- |
| The leaves | `cargo test --locked -p arkdeck-cli --test control_actions` | 4 passed |
| Every CLI test | `cargo test --locked -p arkdeck-cli` | 150 passed, none failed |
| The leaves against the isolated Rust daemon | fresh development root; `control-action list` and `control-action show --control-action hca-00000000-0000-4000-8000-000000000000` | both reach the daemon, which answers the foundation's `rejected` without the zero-dispatch proof; the CLI reports `outcomeUnknown`, exit 75, as Swift classes these methods |
| Format | `cargo fmt --all -- --check` | formatted |

Log of the cargo runs: `/private/tmp/claude-501/-Users-fuhanfeng-Dropbox-Code-Github-ArkDeck--claude-worktrees-macos-agent-branches-20260919-7896b5/e4ca8ae5-02b3-4669-8ede-6d7975251bb2/scratchpad/logs/ctlaction-cli-targeted.log`.

## Unified local gate

`python scripts/ci/plan.py --repo-root . --base-revision origin/main --head-revision HEAD
--merge-base --include-worktree --run-local`, with `ARKDECK_PYTHON` and the planner from a
virtual environment carrying PyYAML 6.0.3 and jsonschema 4.26.0:

| Run | Head | Result | Log |
| --- | --- | --- | --- |
| 2026-09-19 14:11:20–14:15:02 CST, merge base `81957589` (the diff includes both slices below) | `54b8b2f7` | **exit 0**. Lanes: rust only. Every cargo test summary sums to 891 passed, 0 failed, 15 ignored; published and candidate contract checks, `check-sdd`, `cargo deny` and `cargo vet` pass | `/private/tmp/claude-501/-Users-fuhanfeng-Dropbox-Code-Github-ArkDeck--claude-worktrees-macos-agent-branches-20260919-7896b5/e4ca8ae5-02b3-4669-8ede-6d7975251bb2/scratchpad/logs/ctlaction-cli-gate.log`, SHA-256 `af4c5f11bd783f29acaddf2a3567bb12d0d958bd0d00f94cbe8094ddf273273c` |

The gated head sat on the restart slice's pre-evidence commit `e3f42c85`; the slice was then
moved onto that PR's pushed head `065cf39c`, which differs only by four lines of that slice's run
record, and this row was added. `cargo clippy --workspace --all-targets --locked --target <t> --
-D warnings` for `x86_64-unknown-linux-gnu` and `x86_64-pc-windows-msvc`: both exit 0.

Re-stacked on protected main `2a4a3441` (after #1987 merged):
- Runs 2 and 3 (heads `94e555c7`, 14:47–14:56 and 15:05–15:09 CST): exit 1, **invalid runs**. Each
  failed only in `arkdeck-platform --test verified_process::output_overflow_kills_and_reaps_the_child`,
  a "< 2 s" timing assertion outside this diff, while five gates shared the host (load 16→44, then
  28/43/49 at start). Logs `…/scratchpad/logs/cli3-gate-r2.log` (SHA-256
  `1d6a5e30bb1284f9dedd9d6da233139f942cff5c44e78d489c8193005ecfa320`) and `cli3-gate-r3.log`
  (`dcf69e582421dd23838f78a05c2d96aac0ee942b0ba175d16a52e8d72c6dc077`).
- Run 4 on `7d6065c6` (the same code over the restart slice's pushed head), 15:13:47–15:20:26 CST:
  **exit 0**, rust lane; cargo 906 passed, 0 failed, 16 ignored. Log
  `/private/tmp/claude-501/-Users-fuhanfeng-Dropbox-Code-Github-ArkDeck--claude-worktrees-macos-agent-branches-20260919-7896b5/e4ca8ae5-02b3-4669-8ede-6d7975251bb2/scratchpad/logs/cli3-gate-r4.log`,
  SHA-256 `35da3c896c6260245098a2dd22d700b5ef5c081836f35fc035d25892e044ae85`. Linux and Windows
  target clippy (with run 2, same Rust sources) exit 0.

## Not run, and why

- **A served control action from the Rust daemon.** On main the daemon answers the three methods
  with the foundation's `rejected` (shown above); its control-action owner comes with the
  `runtime.hdc.*` routes, and reconciliation waits for the recovery ruling (design §L.1 item 13).
- **Human output.** Without `--output json`, the leaves print the answer as pretty JSON (T2).
- No device, no real HDC.

After #1992 merged, re-stacked on the restart slice (#1995, `72b452d0`) over protected main `521c8fad`:
- Run 5 on `8f934a34`, 16:09:26–16:10:27 CST: exit 1, **invalid run**. The only failure was
  `arkdeck-cli --test human_action_resources::runtime::recorded_swift_success_projections_pass_through_the_binary`:
  that file's fake Runtime panicked with `ENOTCONN` on `shutdown(Write)` after the CLI had already
  closed its end. The file is not in this diff; the test passed five times in a row alone; the
  fake's race is fixed separately (`agent/xpa-018-cli-fake-shutdown-20260919`). Log
  `…/scratchpad/logs/cli3-gate-r5.log`, SHA-256 `2e4160bb214ad4f9b025ad7fb03428ad21ef999de7edf8a29e43968133a9890b`.
- Run 6 on `8acd0901` (same code, over #1995's pushed head), 16:11:50–16:16:04 CST: **exit 0**, rust
  lane; cargo 921 passed, 0 failed, 16 ignored. Log
  `/private/tmp/claude-501/-Users-fuhanfeng-Dropbox-Code-Github-ArkDeck--claude-worktrees-macos-agent-branches-20260919-7896b5/e4ca8ae5-02b3-4669-8ede-6d7975251bb2/scratchpad/logs/cli3-gate-r6.log`,
  SHA-256 `fc9059001fb8a86d63f720c6233fd468e5bf1960c42228b82f59358239b01081`.
- Run 7 on `c243d771` (rebased onto protected main `b5f9d6a6` after #1995 merged), 16:18:59–16:23:57
  CST: **exit 0**, rust lane; cargo 925 passed, 0 failed, 16 ignored. Log
  `/private/tmp/claude-501/-Users-fuhanfeng-Dropbox-Code-Github-ArkDeck--claude-worktrees-macos-agent-branches-20260919-7896b5/e4ca8ae5-02b3-4669-8ede-6d7975251bb2/scratchpad/logs/cli3-gate-r7.log`,
  SHA-256 `c97d807c0afd67bb3dea3bc6f5b0649fca669d92ca5276c2e0588438f6f6c5b9`.
