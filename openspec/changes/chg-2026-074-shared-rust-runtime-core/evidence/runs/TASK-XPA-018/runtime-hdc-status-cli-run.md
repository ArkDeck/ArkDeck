# TASK-XPA-018 — the Rust CLI's `runtime hdc status` (macOS, 2026-09-15, rehung 2026-09-19)

TASK-XPA-018 remains in progress. Base: protected main `2a4a3441` (rebased again after #1987 merged; only the help-text line conflicted, and main's new `artifact import release` line is kept); no stack. The slice was
written on 2026-09-15 (commit `3e2afda1`) above the Rust CLI's `agent resume`/`human-action`
leaves of branch `agent/xpa-014-agent-human-action-cli-20260915` (`749969c9`). Main implemented
those leaves differently (#1973, #1974, #1981), so that branch was retired and this slice was
rehung with `git rebase --onto origin/main 749969c9`. It now declares TASK-XPA-018 (Rust CLI
parity) instead of TASK-XPA-014; the record moved from `runs/TASK-XPA-014/`. Every recorded answer
here is one Swift's daemon gave; nothing is device evidence (POL-VERIFY-001, POL-MODE-001). No
Swift file changes.

## Already on main / this slice / still remaining

| Already on main | This slice | Still remaining |
| --- | --- | --- |
| Swift's CLI argv fixture and frame corpus for `runtime.hdc.status`; the Rust HDC status observer and the isolated daemon's `runtime.hdc.status` (#1956); the Rust CLI's `target` and `human-action` leaves (#1967, #1974, #1981) | `runtime hdc status` in the Rust CLI; its argv fixture in `rust/tests/fixtures/current-cli-argv/`; `tests/runtime_hdc_status.rs`; the fake Runtime `tests/support` that the next two CLI slices share | `runtime hdc impact-preview` and `runtime hdc restart` (next slice), the HDC control-action leaves (the slice after), the daemon's `runtime.hdc.restart/impact-preview` routes; `runtime service status`, `verify` and `restart` |

## What the leaf does

It follows Swift's `CLICommandRegistry` (`runtime hdc status`, client options only) and its
dispatch in `ArkDeckRuntimeCommands.swift`.
- **The request.** `arkdeck runtime hdc status` sends `runtime.hdc.status` with no parameters.
  The leaf takes only the global options: `--output human|json`, `--control-request-id` and, on
  macOS, `--socket`.
  - A `--timeout` is `invalidOption` (64), as Swift gives this read no wait of its own.
  - A missing subcommand is a usage error (64).
- **The answer.** The status is a bounded read, emitted as the Runtime answered it.
  - An `unavailable` or `unknown` status is still an answer, so the leaf exits 0, as Swift's does.
  - Refusals map as Swift maps a bounded read. Four are tested: `rejected` without the
    zero-dispatch proof is `operationFailed` (1); `invalidParams` is `invalidInput` (65);
    `unknownMethod` is `controlMethodUnavailable` (69); `internalError` stays `internalError` (70).
  - Each refusal keeps its `wireCode`.

## Tests

`crates/arkdeck-cli/tests/runtime_hdc_status.rs`:
- **The argv fixture.** Swift's `runtime.hdc.status.json`, copied byte for byte into
  `rust/tests/fixtures/current-cli-argv/`, replays through `parse`. Its five cases are dispatch,
  leaf help, an unknown option, `jsonl` refused, and the macOS `--socket`.
  - Every dispatch carries no parameters and no client wait.
  - The test also checks that a `--timeout` and a missing subcommand are refused.
- **Recorded answers through the actual CLI.** A fake Runtime (`tests/support`) serves each of the
  six statuses in Swift's `runtime.hdc.status` frame corpus and checks that the request carries
  no parameters. The CLI emits each status as the Runtime answered it and exits 0.
- **Refusals.** The fake also answers with each of four refusals; the CLI returns Swift's code and
  exit for each, including the corpus's refusal of caller facts.

## Rehang (2026-09-19)

- `rust/crates/arkdeck-cli/src/main.rs` (help text) conflicted: main's text is kept and only this
  slice's `runtime hdc status` line is inserted, after `runtime bundle remove`.
- `tests/human_actions.rs` had been created by the retired `749969c9` and never reached main (main
  tests the human-action leaves in `human_action_resources.rs`). This slice's edit to it — moving
  its fake Runtime into `tests/support` — therefore became a plain addition of `tests/support`.
- `rust/README.md` is `merge=union`. The union driver resolved the conflicting hunk by keeping the
  commit's whole side, which reintroduced the retired branch's `agent resume`/`human-action`
  paragraph (naming the non-existent `tests/human_actions.rs`) as context. That paragraph was
  removed by hand; the README diff is only this leaf's paragraph.

## Checks (on the rehung tree)

| Check | Command | Result |
| --- | --- | --- |
| The leaf | `cargo test --locked -p arkdeck-cli --test runtime_hdc_status` | 3 passed |
| Every CLI test | `cargo test --locked -p arkdeck-cli` | 142 passed, none failed |
| The leaf against the isolated Rust daemon | `arkdeck-agentd` with `ARKDECK_DEVELOPMENT_STATE_ROOT` and `ARKDECK_ENDPOINT` in a fresh temporary root and no development HDC, then `arkdeck runtime hdc status --output json --socket <endpoint>` | exit 0; `availability: unavailable`, `reasonCode: hdc.notConfigured`, `healthReasonCode: hdc.commandlessIdentityDoesNotProveHealth`, `newDispatchCount: 0`. With `--timeout 5s`: `invalidOption`, exit 64, nothing sent |
| Format | `cargo fmt --all -- --check` | formatted |

Log of the cargo runs: `/private/tmp/claude-501/-Users-fuhanfeng-Dropbox-Code-Github-ArkDeck--claude-worktrees-macos-agent-branches-20260919-7896b5/e4ca8ae5-02b3-4669-8ede-6d7975251bb2/scratchpad/logs/hdcstatus-cli-targeted.log`.
The daemon run's root was deleted afterwards; its two answers are quoted above.

## Unified local gate

`python scripts/ci/plan.py --repo-root . --base-revision origin/main --head-revision HEAD
--merge-base --include-worktree --run-local`, with `ARKDECK_PYTHON` naming a virtual environment
carrying PyYAML 6.0.3 and jsonschema 4.26.0:

| Run | Head | Result | Log |
| --- | --- | --- | --- |
| 2026-09-19 13:57:27–14:02:28 CST, merge base `81957589` | `196d8cf0` (the evidence-only amend recording this row follows) | **exit 0**. Lanes: rust only. Every cargo test summary sums to 883 passed, 0 failed, 15 ignored; published and candidate contract checks, `check-sdd`, `cargo deny` and `cargo vet` pass | `/private/tmp/claude-501/-Users-fuhanfeng-Dropbox-Code-Github-ArkDeck--claude-worktrees-macos-agent-branches-20260919-7896b5/e4ca8ae5-02b3-4669-8ede-6d7975251bb2/scratchpad/logs/hdcstatus-cli-gate-196d8cf0.log`, SHA-256 `6de4723aa12517029b3e157c5b02607271911647b274b34aeae10abd00a735b6` |

`cargo clippy --workspace --all-targets --locked --target <t> -- -D warnings` for
`x86_64-unknown-linux-gnu` and `x86_64-pc-windows-msvc`: both exit 0.

Rebased onto protected main `2a4a3441` (after #1987 merged), head `8d009d2e`:
- Run 2, 14:47:14–14:56:48 CST: exit 1, **invalid run**. The only failure was
  `arkdeck-platform --test verified_process::output_overflow_kills_and_reaps_the_child` (asserts the
  kill happens within 2 s) while five gates and three builds shared the host (load
  16.27/14.01/9.55 at start, 44 by the end). The test is outside this diff (the slice touches only
  `arkdeck-cli`), passed in the concurrent gate of the next slice on the same base, and belongs to
  the known load-sensitive timing family; it is not relaxed here.
  Log `…/scratchpad/logs/cli1-gate-r2.log`, SHA-256 `77b4f15c40a87fbd4f29b521fe296bb5936bd97fcb353c46cb32710f7e4bd7c8`.
- Run 3, 15:05:11–15:12:39 CST: **exit 0**, rust lane; cargo 898 passed, 0 failed, 16 ignored.
  Log `/private/tmp/claude-501/-Users-fuhanfeng-Dropbox-Code-Github-ArkDeck--claude-worktrees-macos-agent-branches-20260919-7896b5/e4ca8ae5-02b3-4669-8ede-6d7975251bb2/scratchpad/logs/cli1-gate-r3.log`,
  SHA-256 `be56f991fa41fd4914501cf1fa558c113aba2cc3e6294df8bb262d503a0e5e9a`. Linux and Windows
  target clippy (run with run 2) exit 0.

## Not run, and why

- **A configured HDC.** The daemon run above has no development HDC, so it shows the leaf end to
  end but only the `notConfigured` status; the six configured statuses come from Swift's corpus.
- **Human output.** Without `--output json`, the leaf prints the answer as pretty JSON, as every
  leaf of this CLI does. Swift's `key: value` layout is wording (T2).
- **Swift's legacy `--json` flag.** This CLI has none, and Swift's fixture exercises none.
- No device, no real HDC.
