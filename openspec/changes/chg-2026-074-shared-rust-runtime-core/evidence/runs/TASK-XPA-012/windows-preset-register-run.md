# TASK-XPA-012 on Windows — `workspace preset register` pins the DevEco toolchain (2026-10-04)

- **Kind:** host-only, on the Windows 11 x64 reference host. No hdc was run and the DAYU200 was
  not touched. Every daemon ran over a fresh development root below the temporary directory.
  The host's DevEco Studio was only measured and registered, never run.
- **Base:** protected `main` `3efba88c` (#2444), after #2428 composed the Bootstrap registry
  owners on the Windows daemon.

## What changed

- `arkdeck-hoststore`: the workspace preset's toolchain pin (`deveco_pins.rs`, Swift's
  `RuntimeWorkspaceToolchainPinning` over `BootstrapDevEcoToolchainRegistry`) builds on Windows.
  `acquire` and `release` are unchanged; the index is encoded as the retirement encodes it on
  each host (canonical JSON on macOS; on Windows as the registration encodes it, since an NTFS
  file id may exceed canonical JSON's exact integer range). `resolve` stays macOS-only, as the
  workspace composition that runs a preset is macOS-only.
- `arkdeck-agentd`: the Windows daemon gives the workspace project owner the toolchain pinning
  over its own Bootstrap registry (`Authority::bootstrap_root`), the same registry
  `runtime.tool.*` serves; the installed daemon keeps its Credential Manager signing credential
  pinning beside it. The census is unchanged.
- `arkdeck-cli`: `workspace.preset.register` joins `WINDOWS_MEASURED_LEAVES`;
  `cli-feature-coverage.json` was regenerated with `arkdeck maintainer contracts export`
  (Windows `implemented` 84 → 85). The six coverage-digest pins in
  `rust/tests/fixtures/maintainer-contracts/oracle.json` were substituted
  (`84c03b90…` → `c268c9a6…`).

## T0 and the Swift oracles

- The macOS index bytes are unchanged: `pins_and_releases_leave_swift_s_index_byte_for_byte`
  still replays the recorded Swift pin/release corpus (`tests/fixtures/deveco-toolchain-pins`) on
  macOS. Its recorded indexes hold macOS records, which a Windows registry refuses to read as its
  own, so that replay stays macOS-only; the macOS-record tests (retired toolchain, resolution)
  stay macOS-only with it.
- Windows (`deveco_registry_owner::windows_registration_tests::
  a_preset_pins_a_windows_toolchain_until_it_releases_it`), over the signed fixture DevEco the
  registration tests build: a pin is held and repeated without a write, a pin at a stale
  generation is `resourceConflict`, a pinned toolchain is not retired, a release lets it retire, a
  second release writes nothing, and the DevEco content is untouched.
- `arkdeck-agentd/tests/windows_workspace_projects_process.rs`, over the real daemon:
  - `a_preset_pins_its_toolchain_in_the_daemon_s_bootstrap_registry`: with no registered
    toolchain the registry's own refusal is answered (`resourceNotFound`, "toolchain reference
    does not exist"), and a signing preset on a development root is refused
    `operationUnavailable` ("signing credential reference owner is unavailable"), as the macOS
    isolated owner refuses it. Nothing is written.
  - `build_and_test_presets_pin_the_host_s_deveco_through_the_cli` (needs
    `ARKDECK_DEV_SIGNER_THUMBPRINT` and `ARKDECK_LIVE_DEVECO_ROOT`; it skips without them, so it
    does not run on CI): the real CLI against a development-signed daemon registers the host's
    DevEco Studio, registers a build and a test preset that pin it, `runtime tool inspect` names
    both presets as holders, a pinned toolchain's removal is `resourceConflict`, the presets read
    back after a restart, removing both releases the pins, and the toolchain then retires. The
    leaf is `implemented` in the manifest the CLI renders.

## Delegated minor decisions (pending the next rulings batch)

1. **The Windows pin index encoding.** The pin writes the same index the retirement and the
   registration write on Windows, in their encoding, rather than canonical JSON, which cannot
   carry every NTFS file id exactly. macOS bytes are unchanged.
2. **The measured leaf's CLI proof needs a live DevEco.** A preset can only pin a registered
   toolchain, and a Windows toolchain registers only over a real DevEco Studio whose Node is
   publisher-signed. The signed-CLI process test therefore runs only with
   `ARKDECK_LIVE_DEVECO_ROOT` (run on this host over `C:\Program Files\Huawei\DevEco Studio`);
   CI runs the refusal process test, and the Windows pin/release unit test over the signed
   fixture DevEco wherever the registration tests can sign it.

## Checks

- `ARKDECK_DEV_SIGNER_THUMBPRINT=AAC23CA4D38D100996C861D9E1A68DEECD69B149`,
  `CARGO_TARGET_DIR=D:/cargo-target/a1-preset`, `CARGO_BUILD_JOBS=2`.
- See the commit message for the local results and the macOS/Linux cross-check.
