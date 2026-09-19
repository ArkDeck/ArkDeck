# TASK-XPA-018 — the CLI tests' fake Runtime tolerates a peer that already closed (2026-09-19)

Base: protected main `521c8fad`. Test-only; no production code changes.

## Why

Five Rust CLI test files (`agent_resume.rs`, `human_action_resources.rs`, `target_adoption.rs`,
`trace_purge.rs`, `workspace_projects.rs`) serve recorded answers from an in-test fake Runtime that,
after writing its answer, calls `shutdown(Shutdown::Write).unwrap()`. When the CLI binary has
already read the answer and closed its end, macOS returns `ENOTCONN` from that `shutdown`, the
fake's thread panics and the test fails although the CLI behaved correctly. It happened on
2026-09-19 in a unified gate at load 3 (`human_action_resources::runtime::recorded_swift_success_
projections_pass_through_the_binary`, "Socket is not connected" at the `shutdown` line), in a slice
that does not touch that file; the test passed five times in a row alone.

## Change

Each fake now treats `NotConnected` from that `shutdown` as the CLI having closed first and still
fails on any other error. The following `read_to_end` and its "the CLI never replays a request"
assertion are unchanged, so a replayed request is still caught.

## Checks

| Check | Command | Result |
| --- | --- | --- |
| Every CLI test | `cargo test --locked -p arkdeck-cli` | 145 passed, none failed |
| Format | `cargo fmt --all -- --check` | formatted |

Unified gate on `7f1c7278`, merge base `521c8fad`, serialized, 2026-09-19 16:31:08–16:36:39 CST:
**exit 0**, rust lane; cargo 913 passed, 0 failed, 16 ignored; contract checks, `check-sdd`,
`cargo deny` and `cargo vet` passed. Linux and Windows target clippy with `-D warnings`: exit 0. Log
`/private/tmp/claude-501/-Users-fuhanfeng-Dropbox-Code-Github-ArkDeck--claude-worktrees-macos-agent-branches-20260919-7896b5/e4ca8ae5-02b3-4669-8ede-6d7975251bb2/scratchpad/logs/cli-fake-shutdown-gate.log`,
SHA-256 `06e73816e6c502e3f6d376e9cb155a389f440e079b6efe355d79ded7f271a4d2`. A trial merge with
protected main `0fe9bb57` (after #1995, #1996, #1998) is conflict-free; none of those touches the five
files.
