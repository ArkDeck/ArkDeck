# TASK-XPA-014 — runtime.hdc.status on the isolated Rust daemon (macOS, 2026-09-14)

TASK-XPA-014 remains in progress. Base: protected main `438434ef`; no stack. That main carries
#1954. The control layer rewrites any answer outside its method's schema to `internalError`, and
only #1954's schema admits the live status the replay test sends through it. The slice was built
and first gated stacked on #1954, replayed onto `68e8241a` once #1954 merged, onto `5e966172`
after the next batch merged, and onto `438434ef` once #1962 fixed that main's build (below).
Every answer here is synthetic host data over lane B's oracle; nothing is device evidence
(POL-VERIFY-001, POL-MODE-001). No Swift file changes.

## Already on main / this slice / still remaining

| Already on main | This slice | Still remaining for M1 |
| --- | --- | --- |
| Lane B's status oracle and observer (#1947); the managed HDC server (SPK-6); the live status's shapes (#1954) | `HostServices::runtime_hdc_status` and the `runtime.hdc.status` arm; the macOS daemon's unconfigured answer; every oracle case through `Control` | The observer over a managed HDC server that the daemon starts; the CLI's `runtime hdc status`; `runtime.hdc.restart` and `runtime.hdc.impact-preview`; `target.adopt` and `target.availability`; the HAR path |

## What changes

Swift's handler (`AgentDaemon.swift`, `case "runtime.hdc.status"`) refuses any parameter, then
answers from the observer its HDC host gives it, or `HeadlessHDCStatusObserver.unconfigured()`
without one. The Rust port does the same:

- **`arkdeck-control`.** `HostServices::runtime_hdc_status` is a host's answer. A host without it
  keeps the foundation's refusal, so `read_only.rs`'s unimplemented methods still read `rejected`.
  The arm sends a request with no parameters to the host. It refuses any other request with
  `invalidParams`, "live HDC status does not accept caller facts or paths", before the host is
  asked. The answer then passes the method's schema like any other.
- **`arkdeck-agentd` (macOS).** The isolated development composition starts no managed HDC server,
  so its host answers `unconfigured_status(None)`. That is the answer Swift's daemon gives without
  its HDC host: `daemonVersion` null and `hdc.notConfigured`. The observer lives only in lane B's
  macOS module, so on other platforms the method keeps the foundation's refusal.

## Tests

`hdc_status_control.rs` (agentd, macOS) has two tests.

`the_control_layer_answers_every_status_oracle_case_as_its_snapshot`:
- It takes the oracle's fixed root and lock, as lane B's replay and both Swift tests do, and writes
  the shared fake driver there.
- It composes a host whose `runtime_hdc_status` builds `HdcStatusObserver` per request from the
  current case's recorded inputs, with the production signature inspection. It then sends each of
  the 22 cases as a frame through `Control::handle_frame`.
- Every answer passes the control layer's schema check and is the oracle's snapshot byte for byte.
  Under main's schema, 17 of the 22 would have been rewritten to `internalError`. Validating the 22
  snapshots with jsonschema showed this: main's `runtime.hdc.status` result definition admits only
  `00` and `16`–`19`, and #1954's admits all 22.
- A request naming `path` is `invalidParams` with Swift's message, and the host is not asked.

`the_daemon_without_a_managed_server_answers_the_unconfigured_status`: the daemon's own host,
through `Control`, answers the oracle's `00-unconfigured` snapshot byte for byte.

`read_only.rs` adds the refused request to its table of semantic refusals: it is refused before
any observation. `check-readonly.py` now expects the macOS daemon to answer the method. Its answer
is checked against the published schema with every other response.

## Checks

| Check | Command | Result |
| --- | --- | --- |
| The replay through the control layer | `cargo test -p arkdeck-agentd hdc_status_control` | 2 passed: all 22 cases byte for byte, the refusal before the host, the daemon's unconfigured answer |
| Owner and control units | `cargo test -p arkdeck-control -p arkdeck-agentd` | agentd 12 passed (the two above among them), control 1, `read_only` 15 of 15 |
| The snapshots against both schemas | jsonschema over the 22 snapshots, with main's and #1954's `runtime.hdc.status` result definition | main's admits 5 (`00`, `16`–`19`); #1954's admits all 22 |
| Real processes | `python3 rust/scripts/check-corpus-replay.py --fixture rust/tests/fixtures/<oracle>` for `agent-execution`, `agent-lifecycle`, `observe-device` and `capture-diagnostics` | PASS on all four (29, 25, 28 and 28 exchanges; 57, 58, 57 and 57 checks); every summary byte-identical to #1953's last runs |
| Read-only host check | `rust/scripts/check-readonly.py` (from the virtual environment carrying jsonschema) | PASS: 124 control responses, 12 CLI envelopes, 115 valid requests; the macOS daemon's `runtime.hdc.status` answer validates against #1954's schema |
| Union merge | `python3 scripts/check_union_merge.py` | ok |
| Lint | `cargo fmt --all`; `cargo clippy --workspace --all-targets -- -D warnings` for `aarch64-apple-darwin`, `x86_64-unknown-linux-gnu` and `x86_64-pc-windows-msvc` | formatted; clean for all three |

## Unified local gate

`python scripts/ci/plan.py --repo-root . --base-revision origin/main --head-revision HEAD
--merge-base --include-worktree --run-local`, with `ARKDECK_PYTHON` naming `.venv-sdd` and the
planner run from a virtual environment carrying PyYAML 6.0.3 and jsonschema 4.26.0:

| Run | Head | Result | Log |
| --- | --- | --- | --- |
| r1 | `31375adb`, stacked on #1954 over merge base `c1cd1ea4` | Stopped by hand after a failure in the published contract view. The Swift lane had passed (2,675 tests). `hdc_status_control::the_control_layer_answers_every_status_oracle_case_as_its_snapshot` failed, and the cause is the stack's dependency, not a defect: that view builds this Rust code against the merge base's contract, whose `runtime.hdc.status` schema still pinned the live members to null, so the control layer rewrote 17 of the answers to `internalError`. #1954 then merged as `68e8241a`, and the slice was replayed onto it: the frames commit dropped as already upstream, and nothing conflicted | `/private/tmp/xpa014-hdc-status-wiring-gate-20260914-r1.log` |
| r2 | `69c73290` | `gate exit=0`: the common checks and SDD, the Rust lane on the development and candidate views (format, Clippy, the workspace tests — 764 passed in all over the workspace run and both views, none failed — and the contract checks), `cargo deny --locked check` and `cargo vet --locked --no-registry-suggestions` | `/private/tmp/xpa014-hdc-status-wiring-gate-20260914-r2.log`, SHA-256 `e72993d6ace230080f4797af1509d5add90046d8aa13da952839d551c67ae7c2` |
| r3 | `8d9c78fa` | Invalid: the build directory was not this checkout's alone. Local checks of two other worktrees had built into this worktree's `rust/target`, and cargo keys a workspace member by its path relative to the workspace root and judges it fresh by mtime. Clippy therefore linked another checkout's `arkdeck-control`, which predates this slice's `runtime_hdc_status` (E0407 in `arkdeck-agentd`). Nothing of this slice was reached; it is rerun in a fresh build directory | `/private/tmp/xpa014-hdc-status-wiring-gate-20260915-c.log`, SHA-256 `8b04766be2a0d855ad480f9f2e3dfe44c53e0b2a0e3d94cab4c9a417dd322db7` |
| r4 | `0c2bf27d` | `gate exit=0`: the common checks and SDD, the Rust lane on the development and candidate views (format, Clippy, the workspace tests — 795 passed in all over the workspace run and both views, none failed — and the contract checks), `cargo deny --locked check` and `cargo vet --locked --no-registry-suggestions` | `/private/tmp/xpa014-hdc-status-wiring-gate-20260915-d.log`, SHA-256 `a3d47fa28f7ae7a7b62c30b12dcbc4f78684ae41ea8f494c6a08d9b6ae1e7ee1` |

## Not run, and why

- **A managed HDC server that the daemon starts.** Swift's daemon starts `hdc -s <endpoint> -m`
  when a tool is configured and composes the observer over its launch record. The Rust daemon does
  not start one yet, so a configured status is proven only through the oracle's seams. The next
  slice starts `ManagedHdcServer` behind an explicit opt-in, so that the other oracles' fake calls
  do not change.
- **The exit-70 relaunch after the server ends, and the supervisor.** Restart semantics stay out
  of the Rust port until L.1 item 13 is decided.
- **The CLI's `runtime hdc status`.** It is still refused by the Rust CLI.
- No device, no real HDC.
