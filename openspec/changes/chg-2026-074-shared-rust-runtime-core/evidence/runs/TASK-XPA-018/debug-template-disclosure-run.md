# TASK-XPA-018 — Offline Debug template disclosure

Initial validation base: protected main `fcfa9893e3350a3215386818686d9bc950436c04` (#2120).
Final base: `9acccf8496360045054d7a26d17a7e7498aeee0f` after #2122 merged.
Rebase preserved both the Job verifier and shared template lowering without conflict.
Branch: `agent/xpa-018-debug-template-cli`.

`arkdeck debug template list` now works without a Runtime connection and publishes
all four template identities, titles, fixed remote tokens, output budgets and
typed inputs. It checks the ordered identity set against the current Catalog on
every call and refuses drift. The exact result members match Swift
`CLIDebugTemplates.runDebugTemplateList`; human JSON and the standard machine
result envelope are supported. Registry help/completion now expose this leaf;
unsupported endpoint/options/jsonl are still refused.

The CLI and HDC provider read one pure-data definition in `arkdeck-contract`.
Provider lowering retains its bound connect key, timeout and command budgets;
the existing frozen command vectors exercise those values. The CLI gains no
Provider or process dependency. The only added dependency is the HDC provider's
workspace-local contract crate; there is no new external package or wire field.

The five Swift argv cases are copied unchanged. A CLI subprocess test selects an
invalid endpoint and a nonexistent daemon to prove the list works offline while
checking every result field against the shared definition. The initial CLI run
found the now-stale assertion that `debug template --help` was unavailable; it
was replaced with positive list help and continued refusal of the unimplemented
run leaf.

`debug template run` is not claimed complete. Its existing Swift domain handler
uses a dedicated execution receipt and physical-assistance semantics; returning
an `agent.run` projection under that name would not establish output parity.
The underlying Rust Job implementation has merged in #2122. No real hardware, installed
Runtime, launchd service or capability record was touched by this slice.

## Local targeted checks

Cargo uses `CARGO_BUILD_JOBS=2` and the isolated target
`/private/tmp/arkdeck-1330-rust-target`.

- `cargo test` for contract, provider-hdc, cli, client, control, hoststore,
  agentd and soak: exit 0, 1,016 passed, 14 existing ignored;
  `/private/tmp/arkdeck-template-disclosure-tests.log`. These are the changed
  crates and direct consumers, not the full local unified gate.
- `cargo clippy` for those same crates, `--all-targets -- -D warnings`: exit 0;
  `/private/tmp/arkdeck-template-disclosure-clippy.log`.
- `cargo fmt --all --check`, `generate-contract.py --check`, and SDD: exit 0;
  `/private/tmp/arkdeck-template-disclosure-{fmt,contract,sdd}.log`.
- Current CLI argv files were byte-compared with their Swift source: pass.
  The actual offline subprocess and all five newly served argv cases passed.

The 14 ignored tests are not counted as passes; no physical-device or signed
IPC acceptance is claimed.

## CI

Pending branch push and maintainer review. No synthetic run, pending CI job or
ignored fixture constitutes REAL_DEVICE_PASS. G5 remains incomplete.


After the base update, only the intersecting paths were rerun: Provider's
`closed_templates_preserve_commands_and_capture_budgets`, CLI `--test
debug_templates`, and hoststore `--test debug_template_run`: exit 0, three tests;
`/private/tmp/arkdeck-template-disclosure-rebase-{provider,cli,job}.log`.

## CI crate-boundary repair

CI run `35721863071` on `f4053f94314e0e6c87dfce71e7e0d7857da82b54` failed the
three Rust workspace lanes (macos-26, ubuntu and windows) in the same step.
This slice changes no contract input, so `check-contracts.py` recorded the
published view as covered and ran only the candidate view. Its
`check-readonly.py` stopped in `assert_boundaries`, which pins every internal
crate edge: `unexpected dependency edge: arkdeck-provider-hdc`. The HDC
provider's new dependency on `arkdeck-contract` was missing from that
allow-list, and the local checks above had not run the black-box check. The
ubuntu artifact upload 403 came after that failure.

The coordinating session accepted the edge. `arkdeck-contract` has no internal
dependency, performs no I/O and holds no Runtime authority. The design keeps
platform and I/O dependencies out of the contract crate and forbids
provider-to-provider edges; a provider reading pure contract data breaks
neither rule, and the crate graph stays acyclic. One template definition read
by both the provider and the CLI is preferred over a data copy in the CLI.
`check-readonly.py` now allows `arkdeck-contract` for `arkdeck-provider-hdc`
with that reason, and the boundary paragraph of `rust/README.md` states the
edge. No other file pins the Rust crate edges: the Python and CI scripts,
workflows, Swift boundary tests, `design.md` and the cross-platform
architecture's dependency rules were checked, and `deny.toml` lists crate
versions rather than edges.

The branch was rebased onto main `86cb81c1c3cc81787ff5114105f1731558c38e74`
(#2127, after #2126, #2121 and #2116) without conflict. None of this slice's
files changed on main, and `git range-diff` shows the feature commit unchanged.
The checks below ran on that base. Before the push, #2124 merged as
`7cf20b7b289c8d125fcb8ddfc994d7cb8d34a213`; it changes no file under `rust/`
and no contract input, so the branch was rebased onto it without rerunning them.

Local targeted checks used `CARGO_BUILD_JOBS=2` and the target
`/private/tmp/arkdeck-1330-rust-target`. `cargo clean -p arkdeck-contract` ran
first, so no contract build from a materialized published view could be reused.

- `assert_boundaries` alone: the previous allow-list reproduces the CI
  `AssertionError` on this manifest; the new one passes.
- `cargo fmt --all --check`: exit 0.
- `cargo test --no-fail-fast` for contract, provider-hdc, cli, control and
  client: exit 0, 452 passed, 0 ignored;
  `/private/tmp/arkdeck-s4-2125-test-core-r2.log`.
- hoststore `--test debug_template_run --test job_plan`, the agentd
  `debug_read`/`debug_template` unit tests, and soak: exit 0, 4 + 3 + 4 passed;
  `/private/tmp/arkdeck-s4-2125-test-dependents.log`.
- `cargo clippy --all-targets -- -D warnings` for those eight crates: exit 0;
  `/private/tmp/arkdeck-s4-2125-clippy.log`.
- `generate-contract.py --check`: exit 0. The copied argv file is byte-identical
  to its Swift source.
- `check-contracts.py` (the failed CI step), with its own output directory:
  exit 0. As in CI, the published view is covered by the candidate because
  the contract inputs equal the merge base's. All 17 candidate commands exited
  0, including `check-readonly.py` (PASS on macOS, 288 recorded files) and the
  owner harnesses after it; `/private/tmp/arkdeck-s4-2125-check-contracts.log`.
- `test_contract_checks.py`: exit 0, 42 tests.
- `cargo deny --locked check` and `cargo vet --locked --no-registry-suggestions`
  come after it in the lane and never ran on the failed head: exit 0.
- `scripts/check-sdd.sh`: exit 0.

The first test run, without `--no-fail-fast`, stopped at the unchanged
provider-hdc `tests/lifecycle.rs`.
`a_confirmed_restart_succeeds_only_with_a_strictly_newer_generation` panicked
at line 177: just after its reachability probe connected, the lease found no
process of the test's own fake owning the endpoint (`NotFound`). The fake
server is spawned without a readiness proof, so a listener of another process
on that port cannot be told from the started server. That binary then passed
in four of four runs on its own, and the complete run above passed. The
failure is outside this diff (lifecycle executor and platform lease), so that
first run was recorded as invalid, not as a result of this change.
