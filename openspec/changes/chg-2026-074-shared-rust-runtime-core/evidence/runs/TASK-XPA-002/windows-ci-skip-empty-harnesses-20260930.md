# Rust CI: stop building cfg-empty test harnesses on Windows and Linux — 2026-09-30

- Task: TASK-XPA-002 (CI slice CI2, PR 2 of 2)
- Authority: the maintainer approved options B, C and E of
  `windows-ci-speed-analysis-20260930.md` on 2026-09-30. This PR is E; B and C
  are #2368.
- Base: protected `main` `755f449f` (#2352), which includes #2364.
- Author: Repo Agent on the maintainer's Windows 11 x64 reference host.

## Why

On Windows, 169 of 230 test executables printed `running 0 tests` on
2026-09-30 (171 of 227 on Linux): most integration-test files start with
`#![cfg(target_os = "macos")]` or `#![cfg(unix)]`, so on the other hosts each
compiles and links (with MSVC `link.exe` and a PDB on Windows) to a harness
that runs nothing. At `755f449f` the workspace has 254 integration-test
targets; their crate-level cfg is false for 163 on Windows, 176 on Linux and
15 on macOS.

## Design

`rust/scripts/workspace-tests.py` now always hands the tests to
`rust/scripts/run-workspace-tests.py`. With two workers (macOS CI) that runs
the two queues exactly as before; macOS scheduling is unchanged. With one
worker (Windows and Linux CI, and local runs) it:

1. reads `cargo metadata --no-deps` (every package target, with its `test`
   flag and `src_path`) and the workspace manifests (`harness = false`);
2. reads the host's cfg set from `rustc --print cfg`, in `rust/`, so the
   pinned toolchain answers;
3. for every integration test target Cargo would build by default
   (`test = true`), parses the crate root's inner attributes (comments,
   nested block comments, doc comments, other attributes and multi-line
   predicates allowed; parsing stops at the first item) and evaluates every
   `#![cfg(...)]` three-valued over `all`/`any`/`not`: the target keys
   (`unix`, `windows`, `target_os`, `target_family`, `target_arch`,
   `target_env`, `target_vendor`, `target_pointer_width`, `target_endian`,
   `target_abi`) are decided by `rustc --print cfg`, `test` is true in a
   libtest harness, anything else (a feature, `debug_assertions`, a custom
   cfg) is unknown;
4. excludes a target only when the verdict is **false**. A verdict of unknown,
   a crate-level `cfg_attr`, or a malformed attribute **fails the run** and
   names the target: nothing undecided is skipped or silently run;
5. always runs `harness = false` targets;
6. runs every default target through Cargo, with `--workspace` so feature
   unification does not change:
   - `cargo test --workspace --no-fail-fast --locked --lib --bins --test <each kept target>`;
   - `cargo test --workspace --no-fail-fast --locked --doc`;
   - `cargo build --workspace --examples --locked`, because plain `cargo test`
     also builds every example outside test mode;
   all three run even when one fails;
7. requires every kept target to appear in Cargo's own `Running <path>`
   lines (colour codes stripped), and fails the run when one is missing;
8. writes `host-selection.json` (kept and excluded targets, stage logs) to the
   test report directory.

It falls back to the plain `cargo test --workspace --no-fail-fast --locked`
when explicit flags cannot reproduce the default selection: a lib or bin with
`test = false`, an example or bench with `test = true`, a `required-features`
target, an un-harnessed lib/bin/example/bench, or an unknown target kind. It
also falls back when `RUSTFLAGS`, `CARGO_ENCODED_RUSTFLAGS`,
`CARGO_BUILD_RUSTFLAGS` or `CARGO_BUILD_TARGET` is set, since those can change
the target or add cfgs. (A `--cfg` injected through a Cargo config file is not
detected; the repository has none and CI sets none.)

A new integration test is included automatically: the inventory comes from
`cargo metadata` on every run, never from a list in the repository.

Unchanged: `cargo clippy --workspace --all-targets -- -D warnings` still
type-checks every target, the excluded ones included, on every host; the
macOS queues; the contract-view jobs (`check-contracts.py` keeps its own
invocations); `guard`, the required checks and the `plan.py` lanes.

Tests (`rust/scripts/test_ci_execution.py`, `HostSelectionTests`): the
three-valued evaluator over Windows and Linux cfg sets (15 predicates,
comments, multiple attributes, module-level cfgs ignored) and six undecidable
or malformed shapes that must raise; the plan runs every default target except
the provably empty ones and the run and excluded sets together are exactly the
default integration targets; an undecidable cfg fails naming the target;
custom harnesses always run and unusual shapes fall back; a selected target
missing from Cargo's `Running` lines fails; and a native Cargo fixture proves
the excluded harness is never built, the kept one, the unit test, the doctest
and the example are, and a failing test does not suppress the doctests.
`rust/scripts/test_contract_checks.py` pins the new `workspace-tests.py`
command.

## Measured (local) and expected (CI)

Windows 11 x64 reference host, 16 cores, `CARGO_BUILD_JOBS=4
CARGO_INCREMENTAL=0` (the hosted runner's 4 vCPUs and #2364's setting),
target `D:\cargo-target\ci2-harness`. The host was **not quiet**: other agents
were building in parallel (10 `rustc` processes when the runs started), so
the rounds were interleaved A/B/B/A/A/B/B/A. Each round deleted the 13
workspace members' products (`cargo clean -p ...`) and rebuilt them over
warm dependencies, as after a cache restore with changed sources.

| build (workspace members only) | round 1 | 2 | 3 | 4 | median |
| --- | ---: | ---: | ---: | ---: | ---: |
| default `cargo test --workspace --no-run` | 93.6 s | 78.0 | 75.2 | 84.4 | 81.2 |
| host-selected tests `--no-run` + `cargo build --examples` | 106.4 | 76.2 | 61.6 | 58.8 | 68.9 |

Excluding the first, load-disturbed round: 79.2 s against 65.5 s on average,
about 14 s (17%) less, consistent with the analysis' 15.6 s for rebuilding the
169 zero-test targets alone. Neither shape recompiles anything the other
built (a no-op rebuild of each compiled 0 crates), so the examples build and
the explicit selection share the dependency graph and features of the default
build.

End-to-end on this host (`workspace-tests.py` with `ARKDECK_RUST_TEST_WORKERS=1`,
same settings, warm target): exit 0 in 149.8 s; 91 integration targets kept
and 163 excluded; the tests stage (build and run) 144.2 s, doctests 3.4 s, the
examples build 0.2 s; Cargo ran 114 test executables, all 91 kept integration
targets among them (the `Running`-line check passed), and 20 of the 114 still
print `running 0 tests` (libraries and binaries without unit tests, and
integration files whose cfg sits below the crate root).

Expected on the hosted runners: the analysis estimated 0.3-0.4 min per
Windows workspace job for the harness compile and link, plus the runtime of
163 empty executables; a similar share on Linux (176 excluded). Neither is on
the Swift CI critical path today (macOS is, and macOS scheduling is
unchanged), so this is runner time and time-to-red for Windows and Linux, and
headroom for #2355/#2352-style additions to the Windows job.

## Local targeted checks

| command | exit | note |
| --- | ---: | --- |
| `python rust/scripts/test_ci_execution.py HostSelectionTests CargoSchedulingTests` | 0 | 11 tests, native fixtures included |
| `python rust/scripts/test_contract_checks.py` (`PYTHONUTF8=1`) | 1 | 47 tests; the one failure, `RunDirectoryTests.test_a_passing_run_removes_its_directory_without_a_word`, asserts a POSIX `0o700` mode and fails on any Windows host, unrelated to this change (the suite runs on Ubuntu in CI) |
| `python scripts/test_agent_pr_workflow.py` (`PYTHONUTF8=1`) | 0 | |
| `python scripts/ci/test_plan.py` | 0 | |
| `sh scripts/check-sdd.sh` | 0 | |

`python rust/scripts/test_ci_execution.py` as a whole has the failure the
task brief names, which also happens on unmodified main on this host
(`test_restored_git_authority_is_replaced_without_inheriting_credentials_or_environment`,
caused by the git-ai wrapper); the suite runs on Ubuntu in CI.

## CI

To be recorded by the follow-up (PR number, run id, Windows and Linux
workspace job durations against the analysis' medians).
