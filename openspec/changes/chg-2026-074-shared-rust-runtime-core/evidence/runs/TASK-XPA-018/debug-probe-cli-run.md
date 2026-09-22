# TASK-XPA-018 — Rust CLI target-bound Debug probe

Base: protected main `e101c836f508b0875fdb592e71dc4f01334f2615` (#2118).
Branch: `agent/xpa-018-debug-probe`.

`arkdeck debug probe --target <id>` now reaches the existing Rust Debug owner
instead of failing as an unknown command. It verifies Runtime identity on the
same connection and sends exactly one `debug.probe` request containing only
`targetId`. It accepts no command, template, capability, caller observation or
execution inputs. Missing and oversized target identities fail before connecting.

Human output, the `--output json` result envelope and legacy `--json` raw result
are supported. The existing registry refuses jsonl and conflicting output modes.
Discovery, help and shell completion expose the executable leaf; its seven existing
Swift argv cases are copied unchanged. The old assertion that the entire Debug
node was unavailable is replaced with positive probe help/completion coverage and
continued refusal of the unimplemented template node.

The response remains a bounded target-bound portrait: schema, target, positive
binding revision, ordered package names, bounded ports and closed warnings are
validated before emission. Partial observations retain their warnings. Wrong
identity, foreign-target/malformed portraits, remote errors and a lost reply never
produce a successful empty portrait, Job or reconnect/replay. Template execution
is not routed to the deprecated control RPC; its current CLI contract requires Job
execution and remains separate work.

## Local targeted checks

Cargo uses `CARGO_BUILD_JOBS=2`,
`CARGO_TARGET_DIR=/private/tmp/arkdeck-1330-rust-target`, and
`--manifest-path rust/Cargo.toml`.

- `cargo test -p arkdeck-cli`: exit 0, 207 passed, no ignored tests;
  `/private/tmp/arkdeck-cli-debug-tests.log`. Includes actual CLI subprocesses
  against a private synthetic endpoint, all output modes, identity rejection,
  malformed/foreign facts, lost reply and no replay. The initial argv run exposed
  the stale Debug-node help assertion; it was corrected with behavior coverage.
- `cargo clippy -p arkdeck-cli --all-targets -- -D warnings`: exit 0;
  `/private/tmp/arkdeck-cli-debug-clippy.log`.
- `cargo fmt --all --check`: exit 0;
  `/private/tmp/arkdeck-cli-debug-fmt.log`.
- `python3 rust/scripts/generate-contract.py --check`: exit 0;
  `/private/tmp/arkdeck-cli-debug-contract.log`.
- `cargo build -p arkdeck-cli -p arkdeck-agentd`: exit 0;
  `/private/tmp/arkdeck-cli-debug-build.log`.
- `/private/tmp/arkdeck-validation-venv/bin/python rust/scripts/check-readonly.py
  --bin-dir /private/tmp/arkdeck-1330-rust-target/debug
  --output-dir /private/tmp/arkdeck-cli-debug-readonly-20260922-final`: exit 0;
  129 control responses, 13 CLI envelopes, 120 valid requests;
  `/private/tmp/arkdeck-cli-debug-readonly-final.log`. The actual isolated daemon
  reports `internalError`/exit 70 when Debug probing is unconfigured, rather than
  manufacturing facts. Initial system Python lacked jsonschema; the existing
  validation environment was used. The initial new assertion expected the wrong
  error mapping and was corrected to the actual published internalError mapping.
- `sh scripts/check-sdd.sh`: exit 0;
  `/private/tmp/arkdeck-cli-debug-sdd.log`.

These are host/synthetic checks, not physical-device acceptance, signed production
IPC or REAL_DEVICE_PASS. No hardware was probed or modified.

## CI

The agent-branch push creates the reviewable PR. CI status and run IDs are read
from that PR; no skipped or pending job is claimed as a pass. The unified gate is
not run locally. G5 remains incomplete.
