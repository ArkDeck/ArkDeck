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

## CI

Not run for this subtask: no push or PR was created. The integration layer must
record the actual PR/run result separately; local fixture passes do not grant
maintainer approval.
