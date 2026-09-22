# TASK-XPA-018 — Rust CLI foreground impact approval

Base: protected main `d4b56cb6b` (#2104). The CLI change is independent of
#2105 source edits; a running executor is still required to complete a restart.
This completes the Rust CLI interaction needed to consume the HDC lifecycle
challenge implemented by TASK-XPA-014. It does not retire the Swift CLI or
claim full CLI parity, C2b/GJ-1 acceptance, or G5 completion.

Previously `human-action resume` rejected even a valid Runtime console
challenge as unsupported. On macOS it now validates the published response,
preview digest and action/approval/preview bindings, prints the entire immutable
preview and generation to stderr, and reads the exact one-time challenge from
terminal stdin. The bounded read follows the existing Swift console behavior:
no more than 65 bytes inspected, newline/CR or EOF terminates input, control
bytes and mismatches refuse. It exposes no argv, environment, file or JSON
input carrier for the answer. The Runtime still independently proves the
foreground console origin and owns admission, freshness and receipt consumption.

Only matching console input produces a second `human-action.resume`, with the
original parameters plus `challengeResponse`. The existing overall deadline is
checked again before that request. A lost response is unknown and is never
replayed. A normal non-console HAR remains attention-required. A challenge
unexpectedly delivered to redirected stdin fails closed before any input read.

The terminal control action is emitted as one existing CLI JSON result, with
exit 0 for succeeded, 1 for failed, and 75 for outcomeUnknown; other states
retain admission/unknown attention. Preview and challenge text stay on stderr.
The client does not reinterpret Runtime lifecycle semantics or issue authority.
The recorded challenge binds generation 3 while its returned action is already
generation 4 after challenge publication; the client preserves this distinction.

Tests use committed Swift ControlFrames and, on macOS, a real PTY driving the
actual Rust CLI against an isolated fake Runtime socket. They verify the full
rendered preview, exact second request, success/failure/unknown exits, redirected
stdin, wrong/oversized/control-byte input, deadline expiry before consumption,
and no replay after a lost response. Byte tests also cover EOF and rebound
preview/digest/identity refusal before rendering or reading. These are client
process checks, not real-device or installed-Runtime/IPC-identity evidence.

## Local targeted checks

All Rust checks use `CARGO_BUILD_JOBS=2` and independent
`CARGO_TARGET_DIR=/private/tmp/arkdeck-1330-rust-target`.

- Final `cargo test --manifest-path rust/Cargo.toml -p arkdeck-cli --test console_approval`:
  exit 0, 6 passed; `/private/tmp/arkdeck-1330-console-pty.log`.
- `cargo test --manifest-path rust/Cargo.toml -p arkdeck-cli`: exit 0,
  205 passed, 0 failed/ignored; `/private/tmp/arkdeck-1330-console-cli-tests.log`.
- `cargo clippy --manifest-path rust/Cargo.toml -p arkdeck-cli --all-targets -- -D warnings`:
  exit 0; `/private/tmp/arkdeck-1330-console-clippy.log`.
- `cargo fmt --all --check --manifest-path rust/Cargo.toml` and `sh scripts/check-sdd.sh`:
  exit 0; `/private/tmp/arkdeck-1330-console-fmt.log` and
  `/private/tmp/arkdeck-1330-console-sdd.log` (zero errors/warnings).
- No contract inputs, argv fixtures or generated vocabulary changed, so the
  contract generator check is not applicable.
- No full local unified gate, performance measurement, installed Runtime
  mutation, LaunchAgent change or hardware operation was performed.

## CI

Pending this CLI PR. #2105's review correction passed all four selected Rust
jobs and the swift aggregate in `35701423731`; guards `35701423514` and
`35701443334` passed. App/Swift tests/design-system interactions were skipped,
not counted as passes. Maintainer review/merge is separate from these results.
