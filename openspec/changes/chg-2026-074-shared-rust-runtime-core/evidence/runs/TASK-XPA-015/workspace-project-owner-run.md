# macOS workspace project registration owner

Status: implementation, targeted verification and the unified gate on the
`81957589` merge passed (last section). This record does not claim Task,
workspace integration, installation cutover, or hardware acceptance completion.

Task: TASK-XPA-015. The branch's working commits carried TASK-XPA-014, but the r11
card (`tasks.md` TASK-XPA-015, "lane D ... the `workspace.preset/project.*`
methods (M3)") assigns these methods to XPA-015; the record and its native
recording moved from `runs/TASK-XPA-014/` and the final commit declares XPA-015
only.

Base: protected `main` `2a4a3441` (merges `c4ce3c1c` and the rehang merge after #1986/#1988 below);
owner checkpoint `58ea9b71`, recording and client verification `94d76ccf`.

| Already on `main` | This slice | Still remaining (M3) |
|---|---|---|
| Swift `RuntimeWorkspaceProjectStore` behind the façade; no Rust workspace owner | Rust `workspace.project.register/list/show` owner (`arkdeck-hoststore`), isolated-daemon Control routes, `arkdeck workspace project register/list/show`, the three method schemas re-derived from 15 recorded native frames | `workspace.project.update/remove`, the five `workspace.preset.*` methods, the 13 `workspace.*` operations (build/sign only after SPK-10), GJ-5 on the isolated Rust daemon |

## Scope and compatibility

The Rust owner implements `workspace.project.register`, `.list`, and `.show`
using the existing Swift `RuntimeWorkspaceProjectStore` registration identity,
root identity, private document, request idempotency, and resource projection.
The Control host and CLI consume this actual durable owner. No workspace Job,
preset mutation, toolchain/credential recovery, signing, or device execution is
added. Registering a root does not authorize execution on it.

A registered project is a real persisted resource. Since this slice does not
compose a workspace execution provider, its configuration remains
`runtimeRestartRequired`, with unavailable operation configuration and empty
operation/preset references, matching Swift's uncomposed resource branch. A
restart preserves the registration; it does not claim to activate a provider.

Existing schema 1–3 project documents and fully validated preset records are
preserved. Definition, registration, and last-mutation digests remain checked.
A pending toolchain mutation requires the missing dependency owners and returns
`operationUnavailable` without rewriting its document. It is not discarded,
completed, or represented as recovered.

## Planned verification and precise limits

The added owner tests cover nonempty registration/list/show after reopening,
request identity and root replacement conflicts, concurrent identical
registration, symlink/private-file/duplicate-JSON refusal, retained preset
validation, and byte-preserving pending mutation refusal. CLI process tests
cover closed arguments, actual framed requests, nonempty resources, and a lost
registration response with no replay. Actual daemon Control/Host tests exercise
the durable owner rather than substituting a canned resource.

The new Swift contract test invokes the existing production handler and owner
for successful registration/show, deterministic parameter/identity/conflict/
quota/unreadable/dependency failures, and staging/rename storage failures using
the existing injected clock and test-owned files. No production fault hook or
hardware fact is added. The native test passed after correcting its test-owned root canonicalization
to use `realpath`: Foundation URL normalization retained `/var`, which the
production owner correctly refused as symbolic ancestry in the initial run.
The successful run recorded 15 actual handler frames. The existing generators
merged those frames with the corpus and regenerated the three method schemas
and baseline pins; `workspace-project-native-recording/provenance.json` records
the source, exact command, test patch, and frame hashes. Contract identity and
method registry remain unchanged. No manually authored frame or error enum was
introduced.

`factsDrifted` during root inspection requires an actual concurrent identity
change. No probabilistic CI race or encoder-only frame is introduced to pretend
this was observed. The owner retains this failure; until a real dispatched
Swift frame extends the sampled vocabulary, the external contract validator
continues its strict `internalError` fallback for the unsupported wire shape.
This is an explicit sampling/observable-error gap, never a success response.

All tests are host filesystem/client fixtures. They provide no real-device or
GJ acceptance evidence. Full repository validation is pending a coordinated
build window; static formatting and diff checks alone are not acceptance.

## Development validation

- Integrated protected main `510b46508d8719318114a17c2567b701297efb65` into
  checkpoint `58ea9b71`, merge `6c17117f`.
- `CARGO_BUILD_JOBS=1 cargo check --manifest-path rust/Cargo.toml --workspace --all-targets`:
  PASS, 34.73 seconds; `/private/tmp/arkdeck-workspace-check-20260919.log`.
- Native Swift wrapper `test --jobs 2 --filter AgentDaemonContractTests/testWorkspaceProjectControlFramesPreserveRegistrationAndStorageFailures`:
  PASS, one test / zero failures;
  `/private/tmp/arkdeck-workspace-swift-sampling-fixed-20260919.log`.
  The preceding root-canonicalization failure is retained at
  `/private/tmp/arkdeck-workspace-swift-sampling-20260919.log`.
- Rust targeted owner (6), actual CLI process (2), and Control (18) tests passed.
  `/private/tmp/arkdeck-workspace-targeted-20260919.log` retains the initial
  daemon test failure: its test adapter incorrectly supplied the LF delimiter to
  `Control.handle_frame`, whose API accepts only the payload. The adapter now
  matches existing daemon tests; its focused rerun passed (one test / zero
  failures), `/private/tmp/arkdeck-workspace-host-fixed-20260919.log`.
- Both contract generators' `--check` drift checks pass. Full repository unified
  validation has not run for this slice.

## Unified gate on the 81957589 merge

`ARKDECK_PYTHON=/private/tmp/arkdeck-validation-venv/bin/python
/private/tmp/arkdeck-validation-venv/bin/python scripts/ci/plan.py --repo-root .
--base-revision origin/main --head-revision HEAD --merge-base --include-worktree
--run-local` on `5cb09fac` (merge base `81957589`), 2026-09-19 13:35:07–13:49:42 CST:
**exit 0**. Lanes: swift, rust and design-system (the diff includes a Swift contract
test and the ControlFrames corpus; no App file, so no App build-for-testing). The
full SwiftPM lane ran 2688 tests without failure (one more than main: the new
producer test); every cargo test summary sums to 2532 passed, 0 failed, 45 ignored;
design-system 83/83; published and candidate contract checks, `generate-contract.py
--check`, `check-sdd` (0 errors), `cargo deny` and `cargo vet` passed. Log:
`/private/tmp/claude-501/-Users-fuhanfeng-Dropbox-Code-Github-ArkDeck--claude-worktrees-macos-agent-branches-20260919-7896b5/e4ca8ae5-02b3-4669-8ede-6d7975251bb2/scratchpad/logs/workspace-gate-5cb09fac.log`,
SHA-256 `38faf1d62e48868bfc6a94845203e34187c05a12f70167e0f45d20b2e736fd0a`. The
commit recording this section changes only this file.

Overlap resolved after the fact: #1986 (ClientKit History models) and #1988 (development USB
relations) merged first. Merging protected main `2a4a3441` conflicted in two places:
`spec/baselines/swift-single-v1.json` was taken from main and regenerated with
`rust/scripts/generate-contract.py --write` (`--check` clean; the only remaining difference from
main is the three workspace methods' pins), and `rust/crates/arkdeck-agentd/src/main.rs` keeps
#1988's `let host = …; match development_usb … {}` composition with this slice's
`with_workspace_projects` after `with_history`. `AgentDaemonContractTests.swift`, the host and
the CLI files merged without conflict. The gate was rerun on the merged tree (below).

Gate on the merged tree (`1f1b1860`, merge base `2a4a3441`), 2026-09-19 14:49:25–15:29:15 CST (load
108/44/22 at start while five gates shared the host): **exit 0**. Lanes: swift, rust, design-system.
SwiftPM full lane 2692 tests without failure; cargo 2577 passed, 0 failed, 48 ignored across every
summary; design-system 83/83; published and candidate contract checks, `generate-contract.py
--check`, `check-sdd`, `cargo deny` and `cargo vet` passed. Linux and Windows target clippy exit 0.
Log: `/private/tmp/claude-501/-Users-fuhanfeng-Dropbox-Code-Github-ArkDeck--claude-worktrees-macos-agent-branches-20260919-7896b5/e4ca8ae5-02b3-4669-8ede-6d7975251bb2/scratchpad/logs/workspace-gate3.log`,
SHA-256 `5e0e38fb3a2170ede121fcfaef47345b66a40e1f57391d3651e92d487d8253f9`.

## CI run 1 and the test-root fix

PR #1989 at `c3fc2e02`: `Rust workspace (macos-26)` failed in
`workspace_project::completed_presets_are_validated_and_preserved_without_acquiring_dependencies`
at `Root::new` with `EEXIST` (job 105849540400). Every test of the file names its
temporary root from the process id and `SystemTime` nanoseconds; the tests run as
threads of one process and the macOS wall clock is coarser than their start spacing,
so two roots could get the same name. The local gate had passed by timing alone.
Fix (test-only): each root name also takes a process-wide `AtomicUsize` sequence
number, so names are unique within a run regardless of the clock. The fixed test
binary passed 60 consecutive runs locally. No production code changed.

Gate rerun on the fixed head `a9dddfaa` (merge base `81957589`), 2026-09-19
14:00:54–14:12:45 CST: **exit 0**, the same lanes; SwiftPM full lane 2688 tests without
failure; cargo 2532 passed, 0 failed, 45 ignored; design-system 83/83. Log:
`/private/tmp/claude-501/-Users-fuhanfeng-Dropbox-Code-Github-ArkDeck--claude-worktrees-macos-agent-branches-20260919-7896b5/e4ca8ae5-02b3-4669-8ede-6d7975251bb2/scratchpad/logs/workspace-gate2.log`,
SHA-256 `84be24fcd12e8d5bb77ee84c5b509694d302da9614e108e86884dbcc0ace8fd9`. Linux and
Windows target clippy with `-D warnings`: exit 0.

Not run: no device, installed Runtime or GJ-5; UI lanes (no App change).
