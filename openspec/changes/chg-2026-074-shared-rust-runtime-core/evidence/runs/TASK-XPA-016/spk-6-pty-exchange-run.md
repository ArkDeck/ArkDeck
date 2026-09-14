# TASK-XPA-016 — SPK-6 phase 4 run record: the PTY prompt/secret exchange

Change: CHG-2026-074-shared-rust-runtime-core@r11. Spike recorded here: SPK-6 (design §J.3),
phase 4 of lane B and the last of its primitives; phases 1–3 are `spk-6-run.md` (#1914),
`spk-6-tool-runner-run.md` (#1915) and `spk-6-shell-channel-run.md`. Host measurement only — not
hardware, platform or conformance evidence (POL-VERIFY-001, POL-MODE-001). No device was
contacted and no signer was launched: every "signer" here is a shell script under a scratch
directory that prints the OpenHarmony signer's prompts.

Base: protected main `5a078b23` (#1915), written on top of phase 3 (`7a894c20`) because both
extend `spawn_pty` and the module list. Branch `agent/xpa-016-spk6-pty-exchange-20260914`.

## What was missing

`workspace.sign-openharmony-hap@1` (M3, GJ-5) answers hap-sign-tool's keystore and key password
prompts. Swift never passes a password through argv, environment or a receipt: `IdentityBoundPTYExecutor`
(`Sources/ArkDeckProcess/IdentityBoundPTYExecutor.swift`, used by
`WorkspaceProvider/OpenHarmonyLocalSigning.swift:1455` and `OpenHarmonySDKReleaseSigning.swift:289`)
runs the signer on a pseudo-terminal with echo disabled by the parent, answers each exact prompt in
order, returns no transcript, and classifies a non-zero exit into a closed failure vocabulary from
the bytes after the last prompt. Nothing in `arkdeck-platform` could hold a secret away from every
receipt while still answering a terminal prompt.

## What Rust now does

- `rust/crates/arkdeck-platform/src/pty_exchange.rs`: `VerifiedTool::run_pty_exchange(&PtyRequest
  { arguments, environment, working_directory, timeout }, interactions, output_byte_budget,
  cancelled) -> PtyExecution { termination, completed_interactions, observed_output_byte_count,
  failure_category }`. Swift's rules: one to four interactions, each prompt 1..512 bytes and each
  secret 1..4096 bytes without NUL, LF or CR, a budget of at least 1 KiB (`InvalidInteraction`); the
  environment and working directory validated as the tool runner validates them (`Refused`); the
  child spawned through `spawn_pty` with echo off but output translation kept (the signer's
  diagnostics keep their CRLF), in its own group on the retained inode; the master polled every
  25 ms; a secret seen in the output ends the exchange (`SecretEchoDetected`); a prompt seen twice,
  or a later prompt seen before its turn, is `PromptProtocolViolation`, as is a child that exits
  before every prompt was answered; the budget (`OutputBudgetExceeded`), the deadline (`TimedOut`)
  and the cancellation probe (`Cancelled`) terminate the group (TERM, 100 ms, KILL); a non-zero
  exit is classified with Swift's `classifyFailure` vocabulary in Swift's order
  (`keystorePasswordRejected` … `signerRejected`, spelled by `PtyFailureCategory::as_str`). The
  transcript is wiped when the exchange is over and no byte of it is returned.
- `rust/crates/arkdeck-platform/src/macos_process.rs`: `spawn_pty` takes the child-only working
  directory and whether to keep the terminal's output translation; the shell channel passes
  `None, false`.
- `tool_process.rs`: the environment and working-directory validators are shared.
- Not changed: no consumer yet; the signing flow (keystore, profile, DevEco password decoding,
  hap-sign-tool through a registered toolchain reference) is lane D's SPK-10 and M3 work.

## Tests

- `cargo test -p arkdeck-platform --lib pty_exchange` (1): the closed vocabulary classified from the
  diagnostic after the last prompt, text before the last prompt ignored, the whole output used when
  no prompt was seen, and the Swift spelling of a category.
- `cargo test -p arkdeck-platform --test pty_exchange` (its own binary; it spawns children), 5/5: two
  exact prompts answered in order with the right secrets end in `Exited(0)`, two completed
  interactions and `None`, while the wrong second secret ends in `Exited(1)` classified
  `keystorePasswordRejected` from the script's diagnostic; a signer that echoes the secret back is
  `SecretEchoDetected`; a prompt printed twice, prompts in the wrong order and a signer that never
  prompts are `PromptProtocolViolation`; `yes` under a 1 KiB budget is `OutputBudgetExceeded`,
  `sleep 30` under a 1 s deadline is `TimedOut` in well under ten seconds, and a cancellation seen
  while it runs is `Cancelled`; no interaction, five interactions, an empty prompt, an empty secret,
  a secret with a newline and a budget under 1 KiB are `InvalidInteraction` with a marker proving
  no child ran. A first draft used one-letter secrets and met `SecretEchoDetected` because the
  letter occurred in the prompt itself — the same order of checks Swift applies.
- `cargo test -p arkdeck-platform`: 127 passed, 0 failed; warnings-denied clippy on
  aarch64-apple-darwin, x86_64-unknown-linux-gnu and x86_64-pc-windows-msvc.

## Not run, and why

- No hap-sign-tool, keystore or profile: the exchange is driven by shell scripts that print the
  signer's prompts; the real signer is exercised by lane D's SPK-10 with the credentials of
  runbook §1.
- No device.

## SPK-6 conclusion

All four primitives the r11 spike named exist in `arkdeck-platform` on macOS without a Swift
sidecar: the commandless server identity proof, the budgeted runner with environment and working
directory, the persistent shell channel and the PTY secret exchange. The go/no-go fact for design
§G.1 r11 ("if SPK-6, SPK-9 and SPK-10 pass, the executor sidecar is never built"): SPK-6 passes;
SPK-9 and SPK-10 are lane D's.
