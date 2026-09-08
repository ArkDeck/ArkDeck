# Re-pinning after the export-disclosure merge — 2026-09-09

- Task: TASK-XPA-002
- Base: protected `main` `2b16e2fc` (#1795).

#1795 changed the two `session.export` method schemas and their corpus, which
leaves the committed Swift development baseline behind `main`. This is the third
re-pin in this sequence — after #1787 (#1793) and #1794 (#1796) — and the last
one it needs.

| Before | After |
| --- | --- |
| commit `161447ce` | `2b16e2fcb810c55238d71b94f0fb6b8550e5f8ac` |
| 429 recorded shapes | 432 |
| 97 methods | 97 |

The generated Rust, the contract identity and the Catalog digest are unchanged;
only the pin moved.

## Verification

- `python3 rust/scripts/generate-contract.py --check` → exit 0.
- `python3 rust/scripts/workspace-tests.py` → exit 0, on the matching-pin path,
  so it ran `cargo test --workspace` against the checkout.
