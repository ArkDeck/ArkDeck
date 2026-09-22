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
