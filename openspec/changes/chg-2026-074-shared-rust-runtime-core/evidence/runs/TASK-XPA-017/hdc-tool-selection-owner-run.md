# HDC tool-selection production owner

Initial base: protected main `5825e91fb5d8bd9cbb42c252a796e4ec3b9b34db`.
Submission base: protected main `56c321bec2c6e0e82a1e4453fc50fc393e370ddf`.

The published `runtime.tool.select` route previously returned the missing-owner
refusal even when production had registered HDC tools. This change composes its
existing durable records and bootstrap selection ledger with the managed HDC
lifecycle. Control-action discovery, show/reconcile and foreground interactive
approval resolve the HDC-restart and tool-selection owners without accepting
caller-supplied lifecycle commands or audit facts.

The owner preserves the Swift record vocabulary, impact preview, challenge,
request identity and final Job interlock. The actual command rechecks the
registered old/new tool facts and managed endpoint. A durable launch marker
permanently closes admission in the old process and requests its normal drain.
The selected replacement retains its own verified executable identity, including
when its SHA matches the old tool but its inode differs. Unknown replacement
identity is not terminated or adopted. The drain exits 70 so launchd can compose
the selected tool into a fresh provider graph; no selection is published by the
old graph.

Startup verifies and starts the pending selection before publication. A failed
selected startup or uncommitted publication restores the prior active tool only
through the durable registry; an ambiguous publication reads its recorded
outcome. A prepare without a durable launch is cancelled before any selected
start. A failed cancellation write remains Pending, and show/list or expiry
cannot erase that transaction's pre-launch evidence. These failure cases do not
invent a settled result or replay a lifecycle launch.

The implementation uses the existing requirements in `toolchain-hdc-server`
(REQ-HDC-001/002/003/010), existing control wire and bootstrap ledger. It adds no
operation, trust identity, capability policy, selected-tool exemption or device
authority. Trace deferral, Flash composition and ArkForge pin work remain owned
by their corresponding changes.

## Local targeted checks

The coordinating task assigned the local build window. Commands use
`CARGO_BUILD_JOBS=2` and the private
`CARGO_TARGET_DIR=/private/tmp/arkdeck-tool-selection-target`.

- `cargo clippy --manifest-path rust/Cargo.toml -p arkdeck-platform -p
  arkdeck-hoststore -p arkdeck-agentd -p arkdeck-bootstrap -p arkdeck-cli -p
  arkdeck-client -p arkdeck-provider-arkforge -p arkdeck-provider-hdc -p
  arkdeck-provider-workspace -p arkdeck-rockchip-binding -p arkdeck-soak
  --all-targets -- -D warnings`: exit 0, repeated after the final changes and
  rebase. Logs: `/private/tmp/arkdeck-tool-selection-clippy.log` and
  `/private/tmp/arkdeck-tool-selection-clippy-final.log`.
- All 13 owner behavior tests cover Swift facts, idempotence, preview drift, approval,
  the Job interlock, failure writes, union ownership, launch identity and unreadable
  post-launch records. All seven startup tests cover success, selected failure, publication
  ambiguity, prior-tool restoration and missing launch evidence.
- Native C fixture executables and a private real bootstrap registry cover
  distinct-tool selection, same-SHA/different-inode cleanup, unknown-identity
  preservation, and failure-write/expiry/query/startup recovery with zero selected
  launch. The first native attempt was stopped after local socket binding was
  proved denied by the sandbox (`EPERM`); the approved loopback-only run passed.
  Logs: `/private/tmp/arkdeck-tool-selection-process-tests.log` and
  `/private/tmp/arkdeck-tool-selection-process-tests-sandbox-refused.log`.
- The first complete targeted run exposed an obsolete unit expectation that
  `registered_hdc` always refuses Pending. The updated test verifies the exact
  pending identity reaches startup and still refuses without its durable control
  action. Repeating `cargo test --manifest-path rust/Cargo.toml` with the same
  eleven `-p` selectors above and `--no-fail-fast` exited 0: 2,004 passed,
  zero failed, 23 existing ignored cases across 239 test/doc-test targets.
  Logs: `/private/tmp/arkdeck-tool-selection-regression.log` and
  `/private/tmp/arkdeck-tool-selection-regression-final.log`.
- After rebasing onto the submission base and retaining the actual selected
  `VerifiedTool` by ownership transfer rather than reopening its path:
  `cargo test --manifest-path rust/Cargo.toml -p arkdeck-agentd --test spawning
  managed_hdc_server`: exit 0, all 10 managed-server tests passed, including the
  new selection and recovery cases. Log:
  `/private/tmp/arkdeck-tool-selection-hdc-final.log`.
- `cargo test --manifest-path rust/Cargo.toml -p arkdeck-platform --test
  internal_stop --test stop_signal`: exit 0, five passed. The internal-request
  fixture has its own process; the original SIGTERM/SIGINT tests are unchanged.
  Log: `/private/tmp/arkdeck-tool-selection-stop-final.log`.
- `sh scripts/check-sdd.sh`: exit 0, 0 errors, 0 warnings, 121 acceptance IDs.
  Logs: `/private/tmp/arkdeck-tool-selection-sdd.log` and
  `/private/tmp/arkdeck-tool-selection-sdd-final.log`.
- `cargo fmt --all --check --manifest-path rust/Cargo.toml` and
  `git diff --check`: exit 0. Final formatter log:
  `/private/tmp/arkdeck-tool-selection-fmt-final.log`.

No installed Runtime, real HDC, device, Keychain, signed distribution artifact
or broker was modified or executed. These are private fixture results, not
hardware acceptance or `REAL_DEVICE_PASS`. No full local unified gate was run.
Swift and wire generation inputs are unchanged.

## CI

Pending at this implementation commit. The coordinating maintainer reviews the
actual PR and its required `guard`/`swift` checks before merge. This change alone
does not retire a Swift target or complete the installed Runtime cutover.
