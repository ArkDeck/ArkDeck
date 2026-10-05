# TASK-XPA-012 — Windows signed CLI tool-selection fixture

Change: CHG-2026-074-shared-rust-runtime-core. GJ-1. Run: 2026-10-05 on the
Windows 11 x64 reference host, non-elevated, NTFS.

The real `arkdeck.exe` reads a candidate selection through a signed test account
daemon, its production Bootstrap/tool-selection owners and managed lifecycle.
The daemon peer's Authenticode identity and signer pin remain real. The account
is a private fake profile; two distinct stand-in executables are admitted only
by the existing test-only tuple port. No installed HDC, device, live account
Runtime or capability records are used. This is host fixture measurement, not
Windows hardware acceptance or `REAL_DEVICE_PASS`.

## Behavior measured

- Register a second stand-in through `runtime tool register --kind hdc`.
- `runtime tool select` answers the immutable `awaitingImpactApproval` preview
  with the candidate's identity, current managed process generation and zero
  dispatch. Repeating the same request returns the same action.
- The existing owner-test foreground-console port issues and consumes the
  fixture approval. The real CLI's console-review function checks the preview
  digest and bindings. This approval is test input, not a real human-console
  acceptance claim.
- The production lifecycle executes the retained selected tool's `kill -r`
  once, proves its replacement process identity and records the durable launch
  window. The old provider graph drains; the action remains `outcomeUnknown`
  with dispatch count one until startup and status settlement.
- Restart with an absent absolute configured path. The composition opt-in
  remains present, while the durable pending selection supplies the actual
  executable. Startup verifies/launches the candidate and publishes generation
  two. `control-action show` settles the action from that registry outcome.
- The signed CLI reads the same `succeeded` action through select, reconcile
  and unfiltered control-action list. Tool list names exactly one selected tool,
  with the candidate digest and active selection generation two. Repeated
  select returns the same settled action and never replays the restart.
- The existing registration/idempotency/untupled-refusal test still passes.
  Without the fixture health port, selection of the stand-in still drifts with
  zero dispatch. Call recording proves exactly one `kill -r` in the selected
  path; other calls are bounded fixture server/version/list calls.

The CLI's current `control-action list --kind` vocabulary names only
`hdcLifecycle`. This measurement uses its existing unfiltered list; no CLI
vocabulary or operation semantics are changed.

## Test boundary and contract correction

The existing macOS owner-test `Host::test_hdc_impact` port is compiled on Windows
test builds too. Its fixture supplies health/version/empty impact participants
only after verifying the actual retained executable, listener lease, process
birth, launch receipt and managed supervisor generation. The managed restart
driver, process verifier, durable audit and startup transaction are production
code. The production registered HDC tuple list, trust policy and health families
are unchanged; no production environment switch is added. The waiting approval
thread is cancelled on an early drain so a failed test still cleans its own
managed server.

Delegated minor decision (user authorization of 2026-10-05, for the next
consolidated rulings batch): use the existing test-only tuple/impact ports to
measure selected behavior rather than register another production HDC identity.
This does not approve a new production trust policy.

The already-emitted tool-selection projection was missing from the closed
`human-action.resume` challenge/result and `control-action` show/reconcile/list
schemas. The generator now adds separate closed alternatives from actual Swift
tool-selection store projections and recorded select answers. Inference uses
an isolated path to avoid inheriting agent-execution shared samples. Every added
action schema equals the published `runtime.tool.select` result exactly; the
regression tests refuse agent-only selection schemas, next-action fields and
unknown preview fields, both directly and inside the challenge.

Every prior request, error, result alternative and schema metadata remains
identical after removing the additive branches. The corpus still contains 110
methods and 1080 recorded shapes; no producer frame was fabricated and no oracle
was re-pinned. Existing agent next-action and HDC signature equality assertions
remain intact, with semantic traversal of their own result alternatives.

`check-contracts.py` also compiles current test sources against immutable
merge-base schemas. If that published view rejects the newly issued selection
challenge, the signed fixture asserts the exact `internalError` conformance
reply before console review or consumption. The waiting action's immutable
projection stays identical; only challenge issuance's generation and observation
time advance. A further select repeat is fully identical, dispatch remains zero,
the original tool stays selected at generation one and no `kill -r` occurs.
This branch requires both published-view metadata and an actual refused reply;
checkout/candidate views retain every selected/restart assertion above, and a
published view that already represents the challenge runs that full path too.

## Local targeted checks

Environment: `CARGO_TARGET_DIR=D:/cargo-target/tool-select`,
`CARGO_BUILD_JOBS=2`, host-trusted development signer configured. Logs below are
under `D:/src/ArkDeck-wt/tools/logs/` and remain local.

| Command | Exit | Log |
| --- | --- | --- |
| `cargo build --manifest-path rust/Cargo.toml -p arkdeck-cli --bin arkdeck` | 0 | `tool-select-build-cli-final.log` |
| `cargo test --manifest-path rust/Cargo.toml -p arkdeck-agentd --test spawning account_tool_selection:: -- --nocapture --test-threads=1` | 0 | `tool-select-account-suite-unfiltered.log` |
| Same selected-path test alone with verified 8.3 `TEMP`/`TMP` | 0 | `tool-select-selected-short-temp.log` |
| `cargo test --manifest-path rust/Cargo.toml -p arkdeck-contract` | 0 | `tool-select-contract-all-surfaces.log` |
| `cargo clippy --manifest-path rust/Cargo.toml -p arkdeck-contract -p arkdeck-agentd -p arkdeck-cli --all-targets -- -D warnings` | 0 | `tool-select-clippy-final.log` |
| `cargo test --manifest-path rust/Cargo.toml -p arkdeck-cli --test console_approval --test agent_resume` | 0 | `tool-select-cli-consumers.log` |
| `cargo fmt --all --check --manifest-path rust/Cargo.toml` | 0 | `tool-select-fmt-final.log` |
| `python -X utf8 rust/scripts/generate-contract.py --check` | 0 | `tool-select-generate-contract-check.log` |
| `python -X utf8 windows/scripts/generate-clientkit.py --check` | 0 | `tool-select-clientkit-check.log` |
| `sh scripts/check-sdd.sh` through the installed Git shell | 0 | `tool-select-sdd-check.log` |

`git diff --check` also passed (exit zero).

The published-view assertion follow-up reran only the candidate signed account
suite (three tests, exit zero; `tool-select-account-published-followup-candidate.log`),
spawning-target clippy with `-D warnings` (exit zero;
`tool-select-published-followup-clippy.log`) and formatting (exit zero;
`tool-select-published-followup-fmt.log`). The integration owner runs the same
source in the task-owned published input view; this subtask did not run the full
parity lane or claim a published-view pass.

Generation used `generate-control-contract.py --derive-method-schemas` with the
committed ControlFrames directory, `rust/scripts/generate-contract.py --write`,
`windows/scripts/generate-clientkit.py --write` and
`generate-clientkit-models.py`. Unrelated derivation writes were restored only
through an explicit generator-produced path list, with original Git blob bytes
verified and generated bytes saved locally. The intended four method schemas,
baseline/hash updates and all source/test edits were preserved.

Full daemon/CLI crate suites and Swift/WinUI/hardware acceptance suites were not run in this subtask;
the checks target the affected process path and contract consumers. Integration
owns final generated feature coverage and census updates.

## Final integration targeted checks

The linear integration tree also contains the preceding symbolize, static
provider inventory/continuation, flash-alias and debug-template increments.
Target: `D:/cargo-target/lead-symbolize`; two Cargo build jobs; heavy commands
used the host-wide `gate_slot.py`. Logs remain local under
`D:/src/ArkDeck-wt/tools/logs/`.

The initial eleven-crate test command completed the daemon checks, then stopped
at a Bootstrap fixture's `host snapshot refused` error (188 reported passes,
one failure, three ignored tests; `tool-layer-tests.log`, exit 101). Subsequent
Bootstrap checks exposed the same issue in bundle and tool registration roots.
All three fixture constructors now resolve the physical path after native
private creation. Production snapshot, canonical-path, identity and trust
checks are unchanged. The final Bootstrap crate passes all 13 tests.

| Final command/check | Exit | Local log |
| --- | --- | --- |
| CLI build, then `maintainer contracts export` | 0 | `tool-layer-build-final.log`, `tool-layer-export.log` |
| `cargo test -p arkdeck-bootstrap` | 0 | `tool-layer-bootstrap-ready.log` |
| Tests for contract, CLI, control, soak, rockchip-binding, provider-arkforge, client, hoststore and provider-hdc (1191 passes, eight existing ignores) | 0 | `tool-layer-remaining-tests.log` |
| Signed account suite on immutable protected-main schemas (three passes, no restart dispatch) | 0 | `tool-layer-published-account-tests.log` |
| Final signed account suite with verified 8.3 TEMP/TMP (three passes) | 0 | `tool-layer-short-accounts.log` |
| Bootstrap crate with verified 8.3 TEMP/TMP (13 passes) | 0 | `tool-layer-short-bootstrap.log` |
| All-target clippy for the eleven affected/direct-consumer crates, warnings denied | 0 | `tool-layer-clippy-final.log` |
| Workspace fmt check | 0 | `tool-layer-fmt-final.log` |
| Rust and ClientKit generator checks | 0 | `tool-layer-generators.log`, `tool-layer-clientkit.log` |
| CLI `maintainer contracts check` (242 contract fixtures) | 0 | `tool-layer-contracts-cli.log` |
| SDD check and `git diff --check` | 0 | `tool-layer-sdd-final.log`; diff check returned no output |

The initial integration build had a comment newline error, corrected before
the successful final build (`tool-layer-build.log`, exit 101). An accidental
full `check-contracts.py` invocation was stopped during published-view clippy;
it has no local pass claim (`tool-layer-contract-check.log`). The targeted
published account check above used that task-owned view, verified all four
method-schema bytes against `origin/main`, updated only current test sources
and built its own CLI. Full dual-view/macOS parity remains CI work. Existing
ignored live prerequisites do not count as device or installed-host acceptance.

Windows CLI coverage exported by the final CLI is 149 implemented, 11 partial
and two notImplemented of 162 required features; 101 features are macOS-only.
Only `runtime.tool.select` changes status in this layer. ArkTrace remains an
external trusted-distribution dependency; service install/update remain closed
under rulings 42/78; generic leaves retain their all-reachable-operation gate.

## CI

This layer's CI is pending its push; the result will be recorded in a later
slice without amending a green head. Preceding adjacent layers are green at the
exact heads listed below (both required checks passed); CI alone is not approval.

| PR | Head | SDD guard run | Swift aggregate run | Result |
| --- | --- | --- | --- | --- |
| #2579 | `cf13e6e1d5b9` | `37263980331` | `37263980574` | PASS |
| #2580 | `9ff969911316` | `37264532417` | `37264532739` | PASS |
| #2582 | `f5cff0e0e8ff` | `37265058050` | `37265058218` | PASS |
| #2583 | `e773ce5ee09c` | `37265636576` | `37265636814` | PASS |
