# The isolated development HDC through `ProcessDispatch` — macOS, 2026-09-14

TASK-XPA-014 remains in progress. Base: protected main `3d880989`, which carries the agent execution
slice this composition serves (#1932), #1928's `ProcessDispatch`, #1930's managed HDC server and
#1931's lifecycle executor; no stack. Lane B built that dispatch
(TASK-XPA-016, SPK-6); composing it is lane A's, as the two lanes agreed on 2026-09-14. Nothing
installed changes and no device is reached: the isolated owner still runs a fixture HDC only.

## What changed

- **Composition** (`arkdeck-agentd`): the development HDC — named by
  `ARKDECK_DEVELOPMENT_HDC_PATH`, accepted only beside `ARKDECK_DEVELOPMENT_STATE_ROOT`, pinned by
  the digest of its bytes at startup, and refused when it is a registered HDC — is dispatched
  through `ProcessDispatch::new(tool, ProcessDispatch::inherited_server_port())`: the verified tool
  runner with its clean base environment plus `OHOS_HDC_SERVER_PORT` when the daemon inherited a
  valid port, as Swift's `DescriptorBoundProcessDispatcher.hdc(resolver:)` dispatches every HDC plan.
- **Replays**: the in-process `observe.device@1` and agent execution replays dispatch through
  `ProcessDispatch` as well (no inherited port), so both oracles now prove the dispatch a
  registered HDC will take.
- **Removed** (`arkdeck-provider-hdc`): `FixtureDispatch`, which ran the fixture through
  `VerifiedTool::run_read_only` and classified its errors itself; nothing uses it any more.
- **README**: the Device observation and HDC process dispatch sections name the dispatch.

## Checks

| Check | Command | Result |
| --- | --- | --- |
| Provider | `cargo test -p arkdeck-provider-hdc` | passed on main `382c5a30`: 12 in the library, 5 in `tests/managed_server.rs` (#1930), 7 in `tests/process_dispatch.rs`, 11 in `tests/swift_fixture_parity.rs`; `FixtureDispatch` had no tests of its own |
| Observe replay | `cargo test -p arkdeck-hoststore --test observe_device` | 1 passed: every answer and every file and mode the four Jobs leave byte for byte, as with `FixtureDispatch` |
| Agent replay | `cargo test -p arkdeck-hoststore --test agent_execution` | 1 passed: the 21 replayed exchanges and every file, as with `FixtureDispatch` |
| Control and daemon | `cargo test -p arkdeck-agentd -p arkdeck-control` | passed |
| Real processes | `python3 rust/scripts/check-corpus-replay.py` on `tests/fixtures/agent-execution` and `tests/fixtures/observe-device` | PASS: 21 exchanges and 35 checks, and 28 exchanges and 57 checks; both summaries byte-identical to the agent slice's runs through `FixtureDispatch` (`/private/tmp/xpa014-dispatch-wiring-harness-{agent,observe}-r1.json` on the stack over `eedc0a0a` and `-r2.json` on `382c5a30`, against `/private/tmp/xpa014-agent-run-harness-{agent,observe}-r5.json`, SHA-256 `a0dbac542fe4f2c9016d702b463f82ec98be6f4277901a262e5acedb5f9950ef` and `3d23fca5670c853f80bb1f45d655abcf7624dd0eeb63d4d6dd2486033887d885`) |
| Lint | `cargo fmt --all`; warnings-denied Clippy of `arkdeck-provider-hdc`, `-hoststore`, `-control`, `-agentd`, `-cli` for `aarch64-apple-darwin`, `x86_64-unknown-linux-gnu` and `x86_64-pc-windows-msvc` | passed |

## Unified local gate

`python scripts/ci/plan.py --repo-root . --base-revision origin/main --head-revision HEAD
--merge-base --include-worktree --run-local` over the three commits of the stack (merge base
`eedc0a0a`; r1), then over the two on main `382c5a30` (r2), with `ARKDECK_PYTHON` naming `.venv-sdd` and the planner run from a virtual
environment carrying PyYAML 6.0.3 and jsonschema 4.26.0:

| Run | Head | Result | Log |
| --- | --- | --- | --- |
| r1 | `cf33a177` (the stack over `eedc0a0a`) | `gate exit=0`: the common checks and SDD, the Swift lane (full parallel, 2,668 tests, then the serialized lanes), the Rust lane on the development and candidate views (format, Clippy, the workspace tests — 1,746 passed in all over the workspace run and both views, none failed — and the contract checks), `cargo deny --locked check` and `cargo vet --locked --no-registry-suggestions` | `/private/tmp/xpa014-dispatch-wiring-gate-20260914-r1.log`, SHA-256 `981aa49b71052a74f65d61d4b6ab5e20254b18ccc2a4f7d69fe3e4fd6bca1ba3` |
| r2 | `9139cc67` | `gate exit=0`: the common checks and SDD, the Rust lane on the development and candidate views (format, Clippy, the workspace tests — 634 passed in all over the workspace run and both views, none failed — and the contract checks), `cargo deny --locked check` and `cargo vet --locked --no-registry-suggestions` | `/private/tmp/xpa014-dispatch-wiring-gate-20260914-r2.log`, SHA-256 `69510aac5a6fab07fdfcd8d8a0b0f329c77fb6569ab0d3c0a5454b2f00b41b1d` |
| r3 | `333a1a5e` | `gate exit=0`: the common checks and SDD, the Rust lane on the development and candidate views (format, Clippy, the workspace tests — 634 passed in all over the workspace run and both views, none failed — and the contract checks), `cargo deny --locked check` and `cargo vet --locked --no-registry-suggestions` | `/private/tmp/xpa014-dispatch-wiring-gate-20260914-r3.log`, SHA-256 `6941de6d98cffa6721b0d0940af09172e7e241a197e206d7c48300b1e9d580fb` |

The amend after r1 fills in this row and moves this commit onto the agent slice's `89826998` on
main `382c5a30` (#1930, then #1925, merged); the README conflict with #1930's new section keeps
both. r2 gates the rebased commit; the amend after r2 fills in its row and moves this commit onto
the agent slice's `3653a66c` (#1932), whose only change since `89826998` is its evidence. CI's
Linux lane then made #1932 expect `operationUnavailable` for the agent methods on macOS only
(`f759a8c9`); r3 gates this commit on that, and the amend after r3 moves it onto #1932's final
`05a7fd39`, whose only change since is its evidence. After #1931 and #1929 merged, #1932 was
replayed onto main `b0806334` (`338cbdce`) and this commit onto it without conflict (`lib.rs` keeps
`mod dispatch`, `mod lifecycle` and `mod managed_server`); on that head: `cargo fmt`, the provider-hdc tests (12 in the library, 7 `lifecycle` from #1931, 5 `managed_server`, 7 `process_dispatch`, 11 parity), both in-process replays, the agentd and control tests, `check-corpus-replay.py` on both oracles (summaries byte-identical to the `FixtureDispatch` runs) and warnings-denied Clippy for macOS, Linux and Windows pass. CI gates the
rebased commit. After #1932 merged (as `3d880989`), this commit was replayed onto main;
its tree is byte-identical to the gated `c321db11`'s.

## Differences from the dispatch it replaces

- A receipt now carries the runner's truncation flag (`FixtureDispatch` never reported one) and a
  signal death reads in Swift's wording; a timeout still leaves the outcome unobservable.
- The child's environment is the runner's clean base plus an inherited valid server port, where
  `FixtureDispatch` gave it none.
- None of these reach the oracles: their fake exits normally within every budget and reads no
  environment, which is why the replays and the harness leave the same bytes.

## Not run, and why

- A registered HDC: the isolated owner still refuses one; it needs the existing-server identity
  proof in the composition.
- A daemon-owned server: lane B's `ManagedHdcServer` (#1930) is for the `runtime.hdc.*` slice.
- No device: DAYU200 is not attached to this host.
