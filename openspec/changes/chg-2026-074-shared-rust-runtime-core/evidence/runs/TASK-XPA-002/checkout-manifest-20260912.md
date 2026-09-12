# The Swift baseline manifest now describes the checkout — 2026-09-12

- Task: TASK-XPA-002
- Base: protected `main` `dda29070` (#1864).

## What was wrong

`spec/baselines/swift-single-v1.json` named a protected-main commit, and
`rust/scripts/workspace-tests.py` (#1790) failed any checkout whose pin did not
match `origin/main` file for file. That check depended on the live tip of
`main`, not on the branch being tested, so every merge that touched a contract
input turned every other open branch red, and `main` itself, until someone
re-pinned. Measured from the day the pin arrived (2026-09-08) to this base:

| Since 2026-09-08 | Count |
| --- | --- |
| merges to `main` | 87 |
| merges that touched the pin | 17 |
| pull requests whose only content was a re-pin | 9 |
| lines changed per re-pin | 20 to 345 |

On 2026-09-12 both `6be27ace` (#1861) and `9558c7d6` (#1862) were red on all
three rust hosts for this reason alone, and a branch cut from either could not
pass the lane without carrying a re-pin of somebody else's merge.

The pin also made the checkout itself inconsistent whenever it lagged:
`control_generated.rs` took its method table and `CONTRACT_IDENTITY` from the
pinned commit but embedded the checkout's schema bytes through `include_str!`,
so `cargo build` in a lagging checkout produced a daemon that advertised one
identity and validated with another contract. The published view in
`check-contracts.py` only avoided that by materializing the pinned inputs into a
temporary tree. That is why the pin had to be forced to track `main`, and why
deleting the gate alone would not have been safe.

## What this changes

The manifest describes the checkout it is committed in, and consistency is a
property of the commit:

- `generate-contract.py --write` regenerates the manifest and
  `control_generated.rs` from the working tree; `--check` fails when either
  differs from such a regeneration. Neither consults another commit, and
  `--baseline-revision` is gone. The manifest schema is
  `arkdeck.swift-development-baseline/2` and the committed one carries no
  `commit`: it cannot name the commit it is part of and needs no other.
- A change that edits a consumed input regenerates in the same change. The
  failure is attributed to that change, by name, with the command to run.
- `workspace-tests.py` verifies the checkout against its manifest and runs
  `cargo test --workspace`. It never reads `origin/main`.
- `check-contracts.py` keeps both views. The published inputs now come from
  Git at `git merge-base origin/main HEAD` (`published_base`), a property of
  the branch's own history: later merges to `main` do not move it. Its
  manifest names that commit, so `check-readonly.py`, the candidate manifest's
  `publishedBaselineCommit` and the recorded provenance keep their meaning.
- `corpus_parity` accepts a manifest without `commit` and still requires the
  checkout's inputs to match it byte for byte, which now holds by construction.

Nothing compares the checkout with the tip of `main` any more. A branch is
green or red on its own tree, and `main` is green after every merge whose
checks were green.

## Verification

All on this base, macOS, rustc 1.98.1, Python 3.14 with the pinned
`PyYAML==6.0.3` and `jsonschema==4.26.0`:

| Check | Result |
| --- | --- |
| `generate-contract.py --write`, then `--check` | manifest `arkdeck.swift-development-baseline/2` without `commit`; `control_generated.rs` byte-identical to before; 105 methods, 574 recorded shapes |
| `cargo test -p arkdeck-contract --test corpus_parity` | 8 passed |
| `rust/scripts/test_contract_checks.py` | 29 passed: checkout manifest, edit-without-regenerate refusal, merge-base published base, missing `origin/main`, tampering, view isolation, wrapper |
| `scripts/ci/test_plan.py` / `scripts/test_agent_pr_workflow.py` | 31 / 12 passed; the workflow's pinned step-name prefixes and commands are unchanged |
| `rust/scripts/workspace-tests.py` | ran `cargo test --workspace`, exit 0 |
| `rust/scripts/check-contracts.py` | published view at merge-base `dda29070` (equal to HEAD here) and candidate view both pass |
| simulated contract change: one recorded `health` shape appended on a throwaway branch | `--check` and `workspace-tests.py` refused by name with the `--write` command and ran no cargo; after `--write` and a commit of two files (the frame and 16 manifest lines) `--check` passed, the workspace tests passed, and `check-contracts.py` passed with published = `dda29070` (574 shapes, `health` 2) and candidate = that commit (575 shapes, `health` 3); the merge-base stayed `dda29070` throughout |
| `scripts/ci/plan.py --run-local` for this diff (all four lanes, because the workflow and planner changed) | planner, workflow, SDD, catalog, design-system, Swift full, App, `generate-contract.py --check`, fmt, fetch, clippy, workspace tests and `test_contract_checks.py` passed; `check-contracts.py` lost the pre-existing `check-hdc-register.py` startup race in its candidate view (`quota` fixture this time), the race #1865 fixes; it had passed twice on this tree before |
| after the `bounded.rs` change below: `workspace-tests.py` and `check-contracts.py` | on a quiet host (load average below 10): `cargo test --workspace` exit 0; published view at merge-base `dda29070` and candidate view both pass, including the owner process checks |

The first simulated `check-contracts.py` run lost the pre-existing startup race
in `check-hdc-register.py` (the daemon binds its socket before creating the
bootstrap directory); the rerun passed. That race is independent of this change
and is being fixed separately.

## The macOS timing flake fixed on the way

The first CI run of this change was red only on macos-26, in
`rust/crates/arkdeck-client/tests/bounded.rs`: `legacy_connect_keeps_its_original_per_io_behavior`
(a per-IO read timed out instead of returning the recorded `notFound`) and
`health_and_status_share_one_budget_and_timeout_prevents_replay` (the server saw
only `health`, because the health reply had exhausted the shared budget before
the status request was sent). The first of these had already failed the same
way on #1863's macos-26 run the day before; neither PR touched the client.

The `Delay::Pair` fixture slept 250 ms before each response against a 400 ms
client budget, so both outcomes were decided inside a 150 ms window that the
hosted runner's scheduling jitter can consume. The fixture now decides by whole
seconds: responses wait 2 s, the budget is 3 s (one response fits, two do not),
the chunked replies take 8 × 500 ms, the server's read timeout is 15 s so it
only bounds a hung fixture, and the renewal backstop is expressed as
`RESPONSE_DELAY + CLIENT_BUDGET` instead of a bare 750 ms. Every assertion keeps
its meaning; only the margins changed, from 150 ms to 1 s on both sides.

| Check | Result |
| --- | --- |
| `cargo test -p arkdeck-client --test bounded`, 20 runs on a quiet 8-core host | 20 passed, 0 failed; suite wall time about 6 s |
| the same, 3 runs with eight CPU burners and a parallel `cargo clippy --workspace --all-targets` (load average about 24 on 8 cores) | 3 passed, 0 failed |
| `cargo fmt --all --check`, `cargo clippy -p arkdeck-client --all-targets -- -D warnings` | pass |

## What this does not do

It does not remove the published view or the temporary source views;
dropping the published view is a possible later simplification once the
merge-base semantics have been in use. It does not change any Swift semantics,
the Catalog generator, installed Runtime state or device acceptance.
