# TASK-XPA-018 — CI: 50 minutes for the macOS Rust workspace job (macOS, 2026-09-26)

TASK-XPA-018 remains in progress. The hub reassigned this CI fix from M4,
where it sat unclaimed inside Flash F3. It changes CI only. Base: `main`
`1bfa52054`. It changes a workflow, so its own PR runs every lane once.

Nothing here is device evidence (POL-VERIFY-001, POL-MODE-001). No Runtime,
CLI, contract input, Catalog, `openspec/contracts`, `openspec/specs` or
constitution change. No check is removed or weakened; only the macOS job's
time bound grows.

## What failed

S28's contract PR #2197 (run 36152711471, job 108129760102) was cancelled in
the macOS Rust workspace job at `timeout-minutes: 30`
(`.github/workflows/rust-ci.yml`). A rerun cannot help, because a run uses
the workflow at the PR's own commit. Every later PR that changes the contract
inputs would fail the same way.

When the contract inputs change, `check-contracts.py` builds both views in
full, each in its own `CARGO_TARGET_DIR`. Each view runs clippy,
`cargo test --workspace`, the `windows_spk3` example,
`cargo build --workspace --bins` and the read-only recordings. On macOS the
candidate view also runs the twelve owner checks and the façade test. So one
job runs the workspace tests three times. All three hosts run both views;
macOS is the host whose tests take long. The macOS job, from its API record
and log:

| Step or command (macOS, job 108129760102) | Start → end (UTC) | Minutes |
| --- | --- | --- |
| Job start to the end of the dependency fetch | 15:13:49 → 15:14:09 | 0.3 |
| Lint (`cargo clippy --workspace --all-targets`) | 15:14:09 → 15:15:19 | 1.2 |
| Workspace tests (`workspace-tests.py`) | 15:15:19 → 15:26:33 | 11.2 |
| Contract step setup (inputs, Catalogs, view copies) | 15:26:33 → 15:26:49 | 0.3 |
| Published view: clippy | 15:26:49 → 15:27:40 | 0.9 |
| Published view: `cargo test --workspace` | 15:27:40 → 15:37:32 | 9.9 |
| Published view: example, build, read-only recordings | 15:37:32 → 15:38:28 | 0.9 |
| Candidate view: clippy | 15:38:28 → 15:39:15 | 0.8 |
| Candidate view: `cargo test --workspace` | 15:39:15 → cancelled 15:44:07 | 4.9 |

The rest of the job is an estimate. The candidate view's tests would take
about as long as the published view's, 9.9 minutes, and its example, build
and recordings about the published view's 0.9. The owner checks and the
façade test took 0.3 minutes (16:37:56 → 16:38:11) in #2202's macOS job (run
36160601321, job 108155995130). So the job would have ended at about
15:50:30, after about 37 minutes, 7 over the bound.

In the same run the other two hosts ran both views and finished well inside
the bound:

| Host | Job | Workspace tests | Contract step |
| --- | --- | --- | --- |
| macos-26 | 30.5 min, cancelled | 11.2 min | 17.6 min, cancelled |
| ubuntu-latest | 4.0 min | 0.9 min | 2.6 min |
| windows-latest | 7.5 min | 1.6 min | 4.5 min |

## What changes

The `workspace` matrix job's bound is now
`${{ startsWith(matrix.os, 'macos') && 50 || 30 }}`. That is 50 minutes on
macOS and 30 on Linux and Windows. A comment in the workflow gives the
reason.

- Only macOS changes. The other hosts need at most a quarter of 30 minutes
  even for a two-view run, and 30 still stops a hung job there early.
- 50 minutes leaves about 13 minutes, a third, above the 37 this run needed.
  One more minute of macOS workspace tests costs about three minutes in a run
  that changes the contract inputs, so the bound should be revisited if those
  tests grow by several minutes.
- The expression matches the `macos` prefix. GitHub's context availability
  table lists `matrix` for `jobs.<job_id>.timeout-minutes`, and a prefix
  match keeps the longer bound when the runner label moves on from
  `macos-26`.

## Local targeted checks

| Check | Command | Result |
| --- | --- | --- |
| Workflow YAML | PyYAML `safe_load` of every `.github/workflows/*.yml` (validation venv) | All parse; `workspace` carries the expression, `policy` keeps 30 |
| Workflow contract tests | `python scripts/test_agent_pr_workflow.py` | 13 tests, OK, including the Rust CI contract |
| Planner tests | `python -m unittest scripts/ci/test_plan.py` | 38 tests, OK |
| Records | `ARKDECK_PYTHON=<validation venv> sh scripts/check-sdd.sh` | 0 errors, 0 warnings; exit 0 |

`actionlint` is not installed on this host, so this PR's own CI is the first
to evaluate the expression.

## CI

- This PR: pending. It runs every lane, since it changes a workflow. Its
  macOS job changes no contract input and runs one view, so it stays far
  under 30 minutes. The next contract-input PR is the first to use the longer
  bound; #2197 does once it is rebased onto this change.
