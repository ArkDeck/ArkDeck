# TASK-XPA-011 — Windows signing leaves and daemon-bound receipts, 2026-09-30

- Task: TASK-XPA-011 (XPA-015 signing layer), WM3 slice G2b. Covers:
  - binding a Windows signing receipt to the installed daemon's code identity;
  - the CLI signing leaves on Windows;
  - the installed Windows daemon's credential pinning.
- Follows on from `windows-signing-owners-run.md` (G2, #2369) and from maintainer ruling 17
  (daemon identity pins, #2352).
- Base: this branch sits on #2369 (head `75834606`) and #2352 (head `faaf473d`); both
  were open when it was pushed. `origin/main` `2fb64e36` was merged in; it now includes
  #2354 (credential store) and #2366 (workspace project owner on Windows).
- Every check below was rerun on the merged head.
- Merge repairs: the squash merges of #2354 and #2366 left two artefacts, both repaired here:
  - a duplicated `[[test]]` target in `arkdeck-platform/Cargo.toml`;
  - a lost `InspectedDirectory` re-export.
  - One further stray README paragraph was removed.
- Host: the Windows 11 x64 reference host, non-elevated.
  - Nothing was installed, elevated or reconfigured, and no certificate was created or trusted.
  - The signed-image tests sign copies of `System32\whoami.exe`/`hostname.exe` in private
    scratch trees with the development signer the host already had (`CurrentUser\My`,
    created before this slice; `rust/scripts/windows-dev-identity.ps1 sign`). No signed
    image was run.
  - No DevEco material, keystore, real password or production credential was read or written.
  - Credential Manager was used only under per-run `ArkDeck-fixture/…` namespaces.
  - The account's `LocalAppData\ArkDeck` did not exist before the runs and did not exist after
    them.

This is host evidence for a Rust port. It is not GJ-5 and not Windows platform acceptance, and
no real hap-sign-tool was run.

## What changed

| Area | macOS (unchanged) | Windows (new) |
| --- | --- | --- |
| Daemon identity for receipts | `trusted_daemon_fingerprint`: `SHA-256(domain ‖ kSecCodeInfoUnique ‖ SHA-256(bytes))` of a daemon valid under the ArkDeck code requirement | `arkdeck-platform/src/windows/daemon_fingerprint.rs`: `SHA-256("arkdeck-keychain-trusted-application-windows-v1\0" ‖ SHA-256(signer leaf DER) ‖ SHA-256(bytes))`. The image must be accepted by `WinVerifyTrust` (the pipe client's policy). The file must be a plain canonical `.exe`, executable by the caller, single-link, and owned by the user or a trusted principal with no untrusted write. It is held (file + namespace) and hashed from that handle. |
| `KeychainSigningSecrets` | `installed`, `for_maintenance`, `over`, `default_daemon_executable` | `installed`/`for_maintenance` over Credential Manager, bound to the named daemon. New `bound_to(daemon)` (both platforms) binds a fixture scope to a fixture daemon. `default_daemon_executable` stays macOS (the Windows daemon is named by the CLI's installation inputs). |
| CLI `runtime signing …` / `signing …` | unchanged | `status`, `install`, `install-sdk-release` and `remove` serve the macOS documents. The daemon is `runtime_service_windows::installed_identity()` in its canonical spelling. The maintenance leaves first require `verify_daemon_image` to answer `ImagePin::Signer` (dev certificate pin or publisher identity), before any preset root or Credential Manager access. `migrate-deveco` and `install --build-profile` are `unsupportedOnPlatform`. Absolute-path checks use the host rule (`Path::is_absolute`, the same as `starts_with('/')` on macOS). |
| Feature coverage | — | the served leaves leave `MACOS_HOST_LEAVES`; `migrate-deveco` stays. The generated contract is unchanged (`generate-contract.py --check`), because signing is still a macOS-only family in the coverage manifest (see open questions). |
| Workspace credential pinning | `keychain_credential_pinning` in the production composition | `arkdeck-hoststore::workspace_signing` is built on Windows. It carries `credential_pinning` and `keychain_credential_pinning`; `SigningSetup` stays with the macOS workspace composition. `arkdeck-hoststore` now depends on `arkdeck-provider-workspace` on Windows too. The installed Windows daemon (not the development root) composes the pinning over `<LocalAppData>\ArkDeck\Signing\OpenHarmony`, bound to its own canonical image. |
| Attempt root | `<state>/workspace-signing-attempts` (daemon composition) | `SigningPresetStore::attempts_root()` = `<preset root>\Attempts`, created owner-only (`HostDirectory::open_or_create_private`), for the Windows signing dispatch when it is composed |

## Decisions (proposals for the maintainer's review)

1. **What the receipt binds.**
   - The receipt binds to the signer leaf and the image bytes of a daemon that `WinVerifyTrust`
     accepts. It does not bind to the configured pin itself.
   - The pin is the maintenance CLI's gate: it binds a receipt only to an image that satisfies
     `ARKDECK_DAEMON_SIGNER_SHA256` or the publisher identity.
   - The daemon then only has to prove it is still that image, so it needs no pin configuration
     of its own.
   - A daemon update changes the identity. The credential is then refused until
     `refresh_daemon_identity` rebinds it, as on macOS.
   - Artifact Signing leaves rotate every 72 hours, but a given signed image embeds one leaf, so
     the identity is stable per image.
2. **MSIX daemon.** An image vouched for only by a package family is refused as a signing
   daemon (`satisfies no signing pin`). Binding a receipt to an MSIX package (the per-file
   signature lives in the package) is a follow-up for the MSIX slice.
3. **DevEco password material stays unread on Windows.** The Windows build-profile `storeFile`
   spelling and DevEco's `material/{fd,ac,ce}` layout have not been sampled. Porting them would
   mean reading real secret material or guessing, so `--build-profile` and `migrate-deveco` are
   refused. Interactive console entry works, and so does a password that is not DevEco
   ciphertext. The adapter needs a sanitised sample through a maintainer crib; this is a
   follow-up.
4. **Attempt root** under the preset root: `<LocalAppData>\ArkDeck\Signing\OpenHarmony\Attempts`
   (lead's instruction). The credential owner never touches `Attempts`; removal removes only the
   receipt and managed material.

## Tests (Windows)

| Target | What it proves |
| --- | --- |
| `arkdeck-platform/tests/windows_daemon_fingerprint.rs` (2) | Unsigned copy → `Other`. Absent, other case, `\\?\`, relative, directory, non-`.exe`, and `Everyone`-writable → `PermissionDenied`. A signed copy → a 64-hex identity that is stable and path-independent. Another signed image → a different identity. One image byte changed after signing → `Other`. |
| `arkdeck-provider-workspace/tests/windows_daemon_binding.rs` (1) | Uses `KeychainSigningSecrets::over(fixture namespace).bound_to(signed fixture daemon)`. The owner records the fingerprint at install, and the receipt validates with the secret present. With another signed image at the daemon path, `load_validated` is `IdentityDrift` and `resolve` fails; an unsigned image fails too. `refresh_daemon_identity` rebinds the credential to the new image while keeping its public reference and its secret. Removal leaves the account `Absent`. |
| `arkdeck-cli/tests/windows_signing_leaves.rs` (4) | `install_document`/`status_document`/`remove_document` over a fixture root give the macOS documents: prompts, projection, readiness, removal counts, no password in the receipt. A relative or Unix path and a `--build-profile` are refused before any prompt, with no root created. Process level: `runtime signing remove`, `signing remove`, `runtime signing install-sdk-release` with an unsigned daemon and no pin (and with only a package family) exit 1 naming the daemon. `migrate-deveco` in both spellings is refused. The account's preset root is not created by any of them. |
| Existing | `windows_signing_flow` (6), `windows_verified_source` (3), `windows_credential_store` (6), `windows_signed_runtime` (2, with the development signer), `windows_workspace_projects_process` (3, now composing the credential pinning) all pass. |

The signed parts are gated by `ARKDECK_DEV_SIGNER_THUMBPRINT`, as #2352's are, and were run
with it set. The hosted runner creates its own development signer for the workspace job
(#2352).

## Checks

Run from `rust/` with `CARGO_TARGET_DIR=D:/cargo-target/g2-signing-leaves` on the merged head:

| Command | Result |
| --- | --- |
| `cargo fmt --all --check` | clean |
| `cargo clippy --workspace --all-targets -- -D warnings` | clean |
| `cargo test --no-fail-fast -p arkdeck-platform -p arkdeck-provider-workspace -p arkdeck-hoststore -p arkdeck-cli -p arkdeck-agentd` (with `ARKDECK_DEV_SIGNER_THUMBPRINT` set, after `cargo build --workspace`) | pass (exit 0, 235 test binaries ok, none failed) |
| the same, again after merging `origin/main` `755f449f` (#2352 merged) | 234 binaries ok, 1 failed: `windows_credential_store::concurrent_writers_keep_each_others_credentials` (see below) |
| `generate-contract.py --check` | pass (no contract change) |
| `sh scripts/check-sdd.sh` (`PYTHONUTF8=1`) | pass |
| `git diff --check` | clean |

The one failure is #2354's churn measurement. In its `ForeignUser` phase (8 threads × 40
rounds), 3 credentials that had been read back were later `Absent`. This is the loss the
credential-store run record describes on the hosted runner, and here it appeared once on the
reference host. Other agents' test runs were loading the host at the same time.

The four criteria for an unrelated failure hold:
- neither the store nor its test is changed by this branch;
- it is the recorded load-sensitive loss;
- the file then passed 3 of 3 runs alone;
- no code in this diff writes that phase's credentials.

The product answers such a loss with the typed `Absent` / `Status(1168)`, never a value, and
`set` refuses a write it cannot read back. The observation is recorded here for the
credential-store follow-up.

macOS and Linux were not built here. The macOS code is unchanged except for three things, which
the macOS and ubuntu CI legs check:
- `is_absolute()` in the CLI path checks;
- the `build_profile_passwords` extraction (same body);
- the hoststore dependency move, which is the same dependency on macOS.

## What stays gated, and open questions

- **The daemon's signing dispatch** (`workspace.sign-openharmony-hap@1`) is not composed on
  Windows: it lives in the macOS-only workspace composition (`WorkspaceComposition`, the
  build/patch/isolation owners). It needs:
  - the Windows Job owner (#2361, open);
  - the DevEco toolchain registry.

  `SigningPresetStore::attempts_root` is ready for it. Today no workspace mutation reaches the
  pinning on Windows, because the Job census refuses them (#2366).
- **DevEco password material** (decision 3).
- **MSIX daemon binding** (decision 2).
- **Coverage manifest.** `signing` is still one of the macOS-only families in
  `feature_coverage.rs` (`MACOS_ONLY_ROOTS`/`MACOS_ONLY_RUNTIME_GROUPS`, "no Windows form until
  a Windows profile is ratified"). Giving the served leaves a Windows status changes the
  contract export. That is left to the maintainer, with the Windows profile.
