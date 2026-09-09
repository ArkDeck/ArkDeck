# Re-pinning after the export `outcomeUnknown` merge — 2026-09-09

- Task: TASK-XPA-002
- Base: protected `main` `a61848f9` (#1825).

#1815 (`TASK-SVC-002`) recorded the post-publication export refusal so that
`spec/control/methods/session.export.apply.json` publishes `outcomeUnknown`,
and re-derived three corpus files (`session.export.preview`, `session.list`,
`session.show`). That leaves the committed Swift development baseline four
files behind `main`: `rust/scripts/workspace-tests.py` on `main` reports
`the committed Swift baseline is stale against origin/main for 4 file(s)` and
names exactly those four, so the Rust lane would refuse the next branch that
reaches it. The other merges since `2b16e2fc` touch no pinned input. Same
remedy as #1793, #1796 and #1797.

| Before | After |
| --- | --- |
| commit `2b16e2fc` | `a61848f970cf448393bb594a183b085e1920b90e` |
| 432 recorded shapes | 435 |
| 97 methods | 97 |

The generated Rust (`control_generated.rs`), the contract identity
`8a662759…` and the Catalog digest `508783ac…` are unchanged; only the pin
moved.

## Verification

- `python3 rust/scripts/generate-contract.py --check` → exit 0.
- `python3 rust/scripts/workspace-tests.py` → exit 0 on the matching-pin
  path, so it ran `cargo test --workspace` against the checkout.
- `python3 rust/scripts/test_contract_checks.py` → exit 0.
- `python3 rust/scripts/check-contracts.py` → exit 0.
