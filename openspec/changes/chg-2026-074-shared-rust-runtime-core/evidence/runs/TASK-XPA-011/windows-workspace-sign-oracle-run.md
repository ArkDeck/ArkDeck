# TASK-XPA-011 — `workspace.sign-openharmony-hap@1` on Windows against the Swift oracle (WM3 GJ-5), 2026-10-04

- Task: TASK-XPA-011, WM3 slice GJ-5, signing. This PR does two things:
  - It runs the Swift `workspace.sign-openharmony-hap@1` oracle on Windows through the Rust
    planner, admitter, runner, reconciler and result reader.
  - It records that signing has no presence gate on Windows, as on macOS, and corrects the
    design text that promised a "HAR console challenge" gate.
- Base: one commit on `origin/main` `587c938b` (#2483). It shares no file with the open GJ-5
  code-owned tool layers (#2482 and its successor), so it is its own stack. The
  registered-project replay and the CLI leaf need those layers and will stack on them.
- Host: the Windows 11 x64 reference host (Windows 11 Pro 10.0.26200), non-elevated. Nothing
  was installed, elevated or reconfigured. No DevEco, JDK, keystore, real password,
  Credential Manager item, board or `hdc` was used. The secrets are the recording's in-memory
  fakes.

## What changed

| Area | macOS (unchanged) | Windows (new) |
| --- | --- | --- |
| `arkdeck-hoststore/tests/windows_workspace_sign_oracle.rs` (`harness = false`) | `workspace_sign_oracle.rs` replays the oracle at `/private/tmp/…` with `hap-signer.sh` | the same 19 frames, records, ledger and products, replayed over `<TEMP>\arkdeck-workspace-sign-oracle` with the test binary as `tools\java.exe` |
| Design text | — | `rust-core-cross-platform-architecture.md` (the WorkspaceProvider row, the XPA-011 reachability line, R13), `windows-phase-agent-prompt.md` WM3, and the two `tasks.md` "Production reachability" lines (TASK-XPA-011, TASK-XPA-015): the "presence gate through the HAR console challenge" wording is replaced by what ships. No status line changed |
| `rust/README.md` | — | the Windows signing section names the replay, and the stale "the signing dispatch stays macOS-only" is removed (the workspace composition has run on Windows since #2463) |

No product code changed. The Rust signing path on Windows already existed (#2369, #2372,
#2463). This PR proves that it answers as Swift does.

### The stand-in signer

When the test binary is run as `java.exe -jar <jar> <command> …`, it follows `hap-signer.sh`
statement for statement:

- the same exit codes;
- the two prompts, read with the platform's echo-cleared console entry;
- the `unknown-prompt`, `repeat-prompt`, `echo-secret`, `sign-failure`, `verify-failure` and
  `verify-once:` modes, read from the input HAP's `mode=` line;
- the `.hap` suffix check, and the refusal of an existing output;
- the `arkdeck-signed-fixture` marker and the two readbacks.

The recorded marker path `/tmp/arkdeck-workspace-sign-oracle/verify-once.marker` inside the
`verify-once` input is read as the same name below this root. The input bytes stay as recorded.

### Labels (rulings 48 and 61)

The receipt is the recorded one, with two differences:

- Each path is the host spelling of the same name below this root.
- The Java launcher is the stand-in, with its own SHA-256 and byte count.

Everything the Runtime derives from those values differs from the recording. A lowercase hex run
of at least 32 digits, at the same place in an otherwise equal string, is therefore learned as
the recording's value, one to one. Then the content is compared byte for byte. One run learned 9
values:

- the credential reference's digest;
- the Java SHA-256;
- three materialized plan digests;
- the two signing reports' SHA-256 and their two Artifact IDs.

The test refuses to relabel any other recorded file's digest: the inputs, the signed HAPs, the
ledger and parked records as files, and the four material files. It also checks that
`credential_reference` over the recorded receipt is the recorded reference.

Only these host spellings are read as the recording's:

- a path below this root, where the recording names the same entry below its root (`/tmp/…` or
  Foundation's `/private/tmp/…`), with `tools\java.exe` read as `tools/java`;
- `javaExecutable.byteCount`;
- `observedOutputBytes=<n>` in a signer diagnostic (see below);
- the Base64 payload of a durable typed action, whose JSON is read the same way and must then
  equal the recording's.

`the_labels_read_only_host_derived_values` pins these rules: text around a run that differs, a
run shorter than 32 digits, a second reading of one value, a path naming another entry, and the
diagnostic's other fields are never relabelled.

## Delegated minor decisions, pending the next rulings batch

1. **No presence gate for signing secrets on Windows (option (a), the lead's decision of
   2026-10-04).** The design (R13) planned a "HAR console challenge" presence gate as the
   Windows counterpart of Keychain + `LAContext`. Nothing on macOS gates on presence:
   - Swift's `LoginKeychainSigningSecretStore` (`OpenHarmonyLocalSigning.swift` at
     `57ba8e36f^`, lines 274-359) answers `presence(of:)` with an attribute-only query. Its
     reads use `nonInteractiveReadOptions()`, an `LAContext` with
     `interactionNotAllowed = true`, unless the store was built with
     `allowsUserInteraction: true`.
   - Only the maintenance CLI builds the store with `allowsUserInteraction: true`. There the
     only prompt is the operating system's own Keychain dialog.
   - The Rust port keeps exactly this (`arkdeck-platform/src/keychain.rs`:
     `NonInteractiveContext`, `data_protection_for_maintenance`).
   - No workspace or signing code, Swift or Rust, creates a human action, and the sign
     oracle's 19 frames carry none.

   On Windows `CredReadW` never prompts, so the Runtime path is the same. Signing gets no
   presence gate and no new human action or console challenge. The console challenge stays what
   it is: the answer to `human-action.resume` approvals (HDC control actions, tool selection).
   The design text promising otherwise is corrected (see "What changed"). Options (b), a
   CLI-local console challenge before maintenance reads, and (c), a daemon HAR before a signing
   Job, were ruled out: each would add behaviour macOS does not have.
2. **`observedOutputBytes` on Windows.** It counts what the pseudo console renders, VT control
   sequences included: 305 bytes where macOS's terminal gave 160 for the `sign-failure` case.
   The PTY exchange's recorded Windows decision ("the prompts are matched in what the console
   renders") already implies this count. The replay reads the number as a label. The
   termination, the completed prompts and the diagnostic code are compared exactly.
3. **The stand-in Java is the test binary**, as in `windows_signing_flow.rs`. This replaces the
   oracle's POSIX `hap-signer.sh`. The replay therefore relabels the Java digest and everything
   derived from it, and nothing else.

## Measurements

| Check | Result |
| --- | --- |
| `cargo test -p arkdeck-hoststore --test windows_workspace_sign_oracle` | 2 passed. All 19 frames match Swift's: two plan refusals (unregistered preset, not a ZIP) and a plan; a signed Job; a rejected keystore password and an echoed secret, each parked on an unknown outcome and reconciled to `failed`; and a `verify-once` Job, parked, reconciled to `resumeAtConfirmedSafeBoundary` and then signed by readback. Every Job's result matches as well. Both parked records and both Jobs' published `signed.hap` and `signing-report.json` match Swift's byte for byte through the labels, and so does the ledger before and after. Running a parked Job again is refused with nothing written. A certificate drifted after admission makes the Job `failed` with `workspace.presetUnavailable` and no intent. No attempt directory is left. Neither password appears, as UTF-8 or UTF-16, in any file below the root apart from the stand-in itself. The results read back after the owners close |

## Gates

| Check | Result |
| --- | --- |
| `cargo fmt --all --check` | exit 0 |
| `cargo clippy --workspace --all-targets -- -D warnings` (Windows) | exit 0 |
| `cargo clippy --target aarch64-apple-darwin --workspace --all-targets -- -D warnings` (stubbed `xcrun`/`ar`/`cc`; type and lint only) | exit 0 |
| `cargo clippy --target x86_64-unknown-linux-gnu --workspace --all-targets -- -D warnings` (same stubs) | exit 0 |
| `cargo test -p arkdeck-hoststore`, `ARKDECK_DEV_SIGNER_THUMBPRINT` set | exit 0: 111 `test result: ok` (494 passed), 0 failed, no `SKIPPED` line |
| the same with `TEMP`/`TMP` on an 8.3 short path on C: (`…\Temp\LONGTE~2`) | exit 0, the same counts |
| `PYTHONUTF8=1 sh scripts/check-sdd.sh`; `git diff --check` | `check_sdd: 0 error(s), 0 warning(s)`; diff check clean |

No contract input, Catalog, generated file or coverage changed, so no generator ran.

## Left out, and why

- **The registered-project replay** and **the CLI leaf** needed the code-owned tool table. They
  follow in layer 2, below. The leaf is measured as a refusal and stays `partial` (decision 4).
- **A presence gate.** Decided against; see decision 1.

## Layer 2: a registered signing preset, and the development root's refusal

This layer stacks on the GJ-5 workspace-lanes layer, which resolves a registered OpenHarmony
project's profile on Windows through the code-owned tools (the in-process `grep`/`sed`/`patch`
and the trusted `tar`/`git`).

| Area | macOS (unchanged) | Windows (new) |
| --- | --- | --- |
| `windows_workspace_sign_oracle.rs` | `registered_signing_preset` in `workspace_sign_oracle.rs` | the same two cases (signing project first and last), over the Windows root |
| `arkdeck-cli/tests/windows_signed_runtime.rs` | — | `workspace_sign_is_unavailable_on_a_development_root`, against the dev-signed daemon |

The registered-preset replay goes through these steps:

1. Two projects are registered.
2. A credential pin from the foreign project is refused as `resourceConflict` before anything
   is written. The preset list and the ledger stay empty.
3. `workspace.preset.register --kind signing` pins the credential in the owner's ledger.
4. Composition without the credential owner refuses a plan with "workspace preset
   configuration changed; restart the Runtime before submitting a Job".
5. Composition with the owner releases the orphaned `preset-retired` pin and composes the
   project's profile and signing preset. The stand-in stands for Node and Hvigor, which never
   run here.
6. The Job signs to `signed.hap` and `signing-report.json`, and leaves no attempt directory.
7. Removing the preset releases its pin.
8. No password appears in any file, and the results read back after the owners close.

The development root's refusal:

- A development root composes no signing credential owner (`windows_lifecycle.rs`
  `signing_setup`), as the macOS development composition does not.
- `operation list` reports `workspace.sign-openharmony-hap@1` as `unavailable` with
  `workspace_preset_unavailable` and `workspace.presetUnavailable`.
- `workspace preset register --kind signing` exits 69 with `operationUnavailable`, "signing
  credential reference owner is unavailable", phase `workspacePresetOwner` and
  `newDispatchCount` 0. The preset list stays empty.
- `workspace sign` exits 65 with `invalidInput`, "workspace preset is not registered for this
  project", phase `preAdmission` and `newDispatchCount` 0.
- These answers come from the code shared with macOS (`workspace_project_document.rs`, the
  composition's availability).

### Delegated minor decision, pending the next rulings batch

4. **`workspace.sign` stays Windows `partial` in the coverage.**
   - macOS counts a direct leaf as `implemented` by its classification
     (`feature_coverage.rs` `implementation_status`), not by a measurement. Windows counts only
     the leaves in `WINDOWS_MEASURED_LEAVES`, each measured end to end through a signed CLI.
   - Only an installed daemon signs, over the account's own preset root
     (`<LocalAppData>\ArkDeck\Signing\OpenHarmony`) and the production Credential Manager
     namespace. A development root composes none, and no test touches the account's state.
     The lead ruled out a daemon input for this on 2026-10-04 (same spirit as rulings 26 and 51).
   - So the leaf is measured here as a refusal and through the owner-level replays, and stays
     `partial`. No coverage file or pin changes.
   - Measuring it end to end later would follow #2479: a `cfg(all(windows, test))` seam on the
     in-process signed test daemon that composes signing over a fixture preset root and the
     `ArkDeck-fixture/…` namespace, never compiled into `arkdeck-agentd.exe`.

### Layer 2 gates

On the workspace-lanes head `12937add`:

| Check | Result |
| --- | --- |
| `cargo fmt --all --check`; `PYTHONUTF8=1 sh scripts/check-sdd.sh`; `git diff --check` | exit 0; `check_sdd: 0 error(s), 0 warning(s)`; clean |
| `cargo clippy --workspace --all-targets -- -D warnings` (Windows) | exit 0 |
| the macOS and Linux cross-check clippy (stubbed toolchain; type and lint only) | exit 0, both |
| `cargo test -p arkdeck-hoststore`, `-p arkdeck-cli`, `ARKDECK_DEV_SIGNER_THUMBPRINT` set | exit 0: hoststore 112 `test result: ok` (502 passed); CLI 70 (254 passed), plus the `harness = false` `windows_signed_runtime` (7 ok, among them `workspace_sign_is_unavailable_on_a_development_root`); 0 failed; no `SKIPPED` line |
| the same with `TEMP`/`TMP` on an 8.3 short path on C: (`…\Temp\LONGTE~3`) | exit 0, the same counts |

No contract input, Catalog, generated file or coverage changed, so no generator ran.
