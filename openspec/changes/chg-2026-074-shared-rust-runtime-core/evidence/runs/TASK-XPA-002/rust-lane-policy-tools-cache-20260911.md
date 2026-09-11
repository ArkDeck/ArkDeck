# The rust lane's policy tools were the Swift CI critical path — 2026-09-11

- Task: TASK-XPA-002
- Base: protected `main` `b3fe9a7b` (#1846).

## What was measured

The 20 most recently merged PRs (#1827..#1846) and every push workflow run
attached to their head commit and to their merge commit on `main`: 40 Swift CI
runs, 40 SDD Guard runs, 20 Agent PR runs and the Performance lane runs the
planner selected. Timings come from the Actions API (`created_at`,
`started_at`, `completed_at` per job and step). Queue time was 0.0-0.2 minutes
on every job, so runner availability is not the problem.

Swift CI wall clock on `main`, successful push runs only (the p90 column is the
run that decides how slow CI feels):

| day | runs | median | p90 | max |
| --- | ---: | ---: | ---: | ---: |
| 2026-09-01 | 19 | 7.2 min | 8.9 min | 10.0 min |
| 2026-09-05 | 25 | 0.5 min | 7.4 min | 8.6 min |
| 2026-09-07 | 8 | 6.6 min | 7.8 min | 7.8 min |
| 2026-09-08 | 21 | 5.4 min | 11.9 min | 12.7 min |
| 2026-09-10 | 9 | 6.0 min | 14.6 min | 14.6 min |
| 2026-09-11 | 1 | 14.6 min | 14.6 min | 14.6 min |

The step up is 2026-09-08, the day #1768 added the hosted rust lane. Before it
the longest Swift CI job was `swift-tests` (ArkDeckKit full suite, 4.4-8.4
minutes). After it the longest job is the Windows member of the rust lane, and
the aggregate waits for it:

| job | runs | median | max |
| --- | ---: | ---: | ---: |
| Rust workspace (windows-latest) | 13 | 11.7 min | 14.3 min |
| Rust workspace (macos-26) | 13 | 7.4 min | 9.6 min |
| Rust workspace (ubuntu-latest) | 13 | 5.3 min | 5.6 min |
| swift-tests | 12 | 5.9 min | 8.4 min |
| app-build | 9 | 3.5 min | 5.3 min |

Inside the rust job one step dominates on every host: `Install pinned
dependency policy tools`, which compiles cargo-deny 0.20.2 and cargo-vet
0.10.2 from source on each run because nothing memoized them.

| step (median over successful jobs) | windows | macos | ubuntu |
| --- | ---: | ---: | ---: |
| Install pinned dependency policy tools | 7.5 min | 4.8 min | 3.7 min |
| Published consumer and candidate contract parity | 1.7 min | 1.2 min | 0.9 min |
| Contract isolation and provenance regression tests | 1.1 min | 0.6 min | 0.1 min |
| Workspace tests | 0.4 min | 0.2 min | 0.2 min |
| Lint the workspace, its tests and its examples | 0.2 min | 0.2 min | 0.1 min |
| everything else combined | < 1 min | < 1 min | < 1 min |

The install is 64 % of the Windows job, 65 % of macOS and 70 % of Linux, and
it re-runs on 1-file re-pin PRs (#1842, #1845, #1846 changed only
`spec/baselines/swift-single-v1.json` and still paid 12-14 minutes).

## What changes

`.github/workflows/rust-ci.yml` memoizes the output of the two `cargo install
--locked` lines and nothing else:

- `actions/cache/restore` before the install, under one exact key that names
  both pinned tool versions and the pinned toolchain
  (`hashFiles('rust/rust-toolchain.toml')`). No `restore-keys` prefix
  fallback exists, so a different version can never be restored as a near miss.
- The install step is the miss path (`if: steps.policy-tools.outputs.cache-hit
  != 'true'`) and is otherwise unchanged.
- A read-back step runs on hit and on miss and requires `cargo deny --version`
  and `cargo vet --version` to equal the pinned strings, so a restored binary
  that is not the pinned tool fails the lane before either policy check runs.
- `actions/cache/save` only when `github.ref == 'refs/heads/main'`, the trust
  rule the Swift caches already use; a branch can neither write nor read
  another branch's entry.

`scripts/test_agent_pr_workflow.py` pins the four steps, their order relative
to `cargo deny --locked check`, the exact key on both sides, the main-only save
condition and the absence of `restore-keys`, with mutations for each.

## Expected effect

The first `main` run after this merges installs the tools once per host and
writes three entries (about 20 MB each; the local macOS binaries are 7.4 MB and
13 MB). Every later selected run restores them in seconds, which takes the rust
job to roughly 4 minutes on Windows, 2.5 on macOS and 1.5 on Linux, and
returns the Swift CI critical path to `swift-tests`. The branch run of the PR
that carries this change does not see a hit; only `main` writes.

## Observed but not changed here

- The repository's Actions cache is at its 10 GB cap (10,300,155,948 bytes in
  10 entries on 2026-09-11). The Swift lanes key every `main` save with
  `github.sha`, so each Swift-touching merge writes a new 1.3 GB SwiftPM entry
  and a 0.5 GB perf entry (plus 1.65 GB for the Xcode lane when it runs), and
  GitHub evicts the least recently used entries to stay under the cap. The
  policy-tool entries are read on every selected run, which keeps them fresh
  under that eviction; the churn itself costs about a minute of upload per
  `main` run and is a separate decision.
- `check-contracts.py` compiles the workspace a second time inside its
  candidate view (clippy, test, example, build under its own
  `CARGO_TARGET_DIR`), which is the next-largest Windows step at 1.7 minutes.
  A shared compilation cache would need the same trust rule and is not part
  of this change.
- Provenance is unchanged: the binaries on a hit are the ones the same
  `cargo install --locked` produced on protected `main`. Replacing the
  install with published release binaries would be faster still but changes
  what the lane trusts, so it is left as a maintainer decision.
