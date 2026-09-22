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
- Unix temporary-directory correction: `console_approval` 6 passed, exit 0;
  `/private/tmp/arkdeck-1330-console-unix-temp.log`. CLI clippy, fmt and SDD
  also exit 0 (`...-unix-temp-clippy.log`, `...-unix-temp-fmt.log`,
  `...-unix-temp-sdd.log`). No full local gate was repeated.
- Final transport-scope correction: all 6 macOS console tests passed;
  `/private/tmp/arkdeck-1330-console-macos-scope.log`. CLI clippy, fmt and SDD
  exit 0 (`...-macos-scope-clippy.log`, `...-macos-scope-fmt.log`,
  `...-macos-scope-sdd.log`). The three pure tests remain platform-independent.
- No contract inputs, argv fixtures or generated vocabulary changed, so the
  contract generator check is not applicable.
- No full local unified gate, performance measurement, installed Runtime
  mutation, LaunchAgent change or hardware operation was performed.

## CI

#2106 first head `82b7dd3c4` failed its Ubuntu CLI test in run
`35702341935`, job `106663141998`: the shared Unix socket harness hard-coded
macOS `/private/tmp`, absent on Ubuntu (`ENOENT`). This is a test-path defect,
not a load flake. The harness now canonicalizes Unix `/tmp` before creating
its random 0700 directory and 0600 socket, retaining the existing permission
and no-extra-request assertions. The macOS-only PTY coverage remains unchanged.
Head `694b63737` then failed Ubuntu job `106665416499` in run `35703051435`:
CLI `--socket` is intentionally macOS-only, so the actual socket test cannot
run on every Unix host. The real non-terminal test and its socket harness are
now gated to macOS, alongside the PTY tests. The three pure logic tests still
run cross-platform. This matches existing product scope without extending
Linux transport or dropping any macOS assertion. Fresh CI is required.

#2105's review correction passed all four selected Rust
jobs and the swift aggregate in `35701423731`; guards `35701423514` and
`35701443334` passed. App/Swift tests/design-system interactions were skipped,
not counted as passes. Maintainer review/merge is separate from these results.
