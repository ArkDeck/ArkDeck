# Re-pinning after the published-method merge — 2026-09-08

- Task: TASK-XPA-002
- Base: protected `main` `161447ce` (#1794).

#1794 published `flash.reconcile-alias`, which moved the contract identity and
re-derived all 97 per-method schemas and 59 corpus files. That is a legitimate
contract change, and it leaves the committed Swift development baseline behind
`main` — 157 pinned files, including `control-protocol.json` and the generated
Rust. `rust/scripts/workspace-tests.py` reported it on the next branch to run
and named the re-pin command; this is that command's output.

| Before | After |
| --- | --- |
| commit `2ae759f3` | `161447ce22b9538764a5d8cfd8e4baec940d780d` |
| 96 methods | 97 |
| 422 recorded shapes | 429 |

## The recurring cost this makes visible

`generate-contract.py --write` accepts only a commit already in `origin/main`,
so a branch can never pin to itself. Every merge that changes the recorded
corpus therefore leaves `main` inconsistent until a re-pin lands, and while it
is inconsistent the currency check refuses to judge any branch — correctly, but
it means corpus-changing PRs have to be sequenced with a re-pin between them.
This is the second such re-pin today (#1793 was the first, after #1787).

That is a property of the pin design, not of any one change: the alternative
would be a pin that names an unpublished tree, which is what the
merge-base guard exists to prevent. The practical rule is to file the re-pin
immediately after each corpus-changing merge rather than batching them, so the
window in which `main` is unjudgeable stays short.

## Verification

- `python3 rust/scripts/generate-contract.py --check` → exit 0.
- `python3 rust/scripts/workspace-tests.py` → exit 0, and because the checkout
  now matches the pin it ran `cargo test --workspace` rather than deferring to
  the candidate view.
