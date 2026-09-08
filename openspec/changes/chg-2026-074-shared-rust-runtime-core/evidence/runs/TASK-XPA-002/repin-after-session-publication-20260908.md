# Re-pinning after the Session publication merge — 2026-09-08

- Task: TASK-XPA-002
- Base: protected `main` `2ae759f3` (#1787).

#1787 changed twelve recorded frame files and ten method schemas, which is a
legitimate contract change and leaves the committed Swift development baseline
behind `main`. Under the old lane that drift was invisible until a later branch
tripped over it — the #1773 pattern. `rust/scripts/workspace-tests.py`, added by
#1790, now asks the question directly, and it fired on the first branch to run
after #1787 merged:

```text
the committed Swift baseline is stale against origin/main for 20 file(s), so
this checkout cannot be judged against it. Re-pin with
`python3 rust/scripts/generate-contract.py --write --baseline-revision origin/main`
```

This is that re-pin, verbatim from the message.

| Before | After |
| --- | --- |
| commit `8151907b` | `2ae759f38f4cddbb3396dc282118c98723e82dc5` |
| 382 recorded shapes | 422 |
| 96 methods | 96 |

The generated Rust, the contract identity and the Catalog digest are unchanged;
only the pin moved.

## Verification

- `python3 rust/scripts/generate-contract.py --check` → exit 0.
- `python3 rust/scripts/workspace-tests.py` → exit 0, and because the checkout
  now matches the pin it ran `cargo test --workspace` rather than deferring to
  the candidate view. That is the path #1778 added and #1790 kept.
