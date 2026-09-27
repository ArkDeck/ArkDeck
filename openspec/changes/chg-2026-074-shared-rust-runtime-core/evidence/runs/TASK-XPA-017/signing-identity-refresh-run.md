# TASK-XPA-017 — Refresh signing identity during helper installation

Rust service install/update no longer refuses every installed signing preset.
The credential owner ports Swift's `maintain` plus
`refreshDaemonKeychainIdentity`: under the existing owner lock, it validates
public signing files and the ledger, obtains the installed daemon's platform
code-signature fingerprint, checks envelope presence, and durably replaces
only the receipt's public fingerprint. Credential references, owner pins,
passwords, envelope accounts and source material remain unchanged. An
unchanged fingerprint does not rewrite the receipt.

Known-absent envelopes refuse maintenance. An unreadable envelope does not:
like Swift, the maintenance process need not decrypt or rewrite the secret to
repair its public daemon binding. Actual signing still validates the recorded
identity and reads the envelope before dispatch. No caller-supplied digest or
new credential authority is introduced.

The service installer first validates public preset material, before any
installation mutation or Bootstrap registry pin. This retains an early,
non-mutating refusal for invalid material. After the installed helper is
verified and the plist/installation receipt are durable, it refreshes the
credential, then bootstraps. Both typed initial install and update use this
path, including Swift/Rust helper updates.

Current Swift `LaunchAgentService.install` deliberately attempts bootstrap of
the verified replacement even when credential refresh fails: read-only Runtime
availability is restored before returning the maintenance error, while signing
continues to fail closed. Rust now mirrors that behavior. If recovery bootstrap
also fails, its diagnostic retains both causes. There is no silent success,
credential deletion, state repair or automatic rollback.

## Scope and evidence

Source owners: `OpenHarmonySigningCredentialOwner.maintain`,
`OpenHarmonyLocalSigning.refreshDaemonKeychainIdentity`,
`ArkDeckRuntimeCommands.refreshSigningAccessIfInstalled`, and
`LaunchAgents/LaunchAgentService.install` (including its refresh-failure
recovery). The existing Swift contract tests explicitly cover replacement
startup after credential refresh failure.

New tests use bounded public files, temporary homes, recording launchd, and
secret sources whose value reader panics. They cover pinned credential
continuity, unreadable versus absent envelopes, untrusted identity, material
drift, idempotence, receipt permissions, refresh-before-bootstrap ordering for
Swift/Rust helpers, dual failure diagnostics and typed-install pin finalization.
These are host fixtures, not real Keychain, launchd, device or GJ-5 acceptance.
No installed helper, credential or service was changed.

Signing preset `install`, `install-sdk-release` and `migrate-deveco` remain
unported; this does not complete TASK-XPA-017 or authorize the installation
window. The cutover runbook now distinguishes early validation refusal,
credential maintenance recovery and other post-snapshot failures.

## Local targeted checks

Worktree-private `CARGO_TARGET_DIR=/private/tmp/arkdeck-takeover-d79c-target`,
`CARGO_BUILD_JOBS=2`.

- `cargo test --manifest-path rust/Cargo.toml -p arkdeck-provider-workspace
  -p arkdeck-hoststore -p arkdeck-cli`: exit 0; 1,162 passed / 18 ignored.
  Log: `/private/tmp/arkdeck-signing-refresh-all-tests.log`.
- After aligning the failure recovery with current Swift and adding the final
  typed-install/invalid-ledger regressions: `cargo test --manifest-path
  rust/Cargo.toml -p arkdeck-cli --test signing_refresh --test runtime_service`:
  exit 0; 45 service tests and four credential tests passed.
  Log: `/private/tmp/arkdeck-signing-refresh-final-tests.log`.
- `cargo clippy --manifest-path rust/Cargo.toml -p arkdeck-provider-workspace
  -p arkdeck-hoststore -p arkdeck-cli --all-targets -- -D warnings`: exit 0.
  Log: `/private/tmp/arkdeck-signing-refresh-clippy.log`.
- `cargo fmt --all --check --manifest-path rust/Cargo.toml`, `git diff --check`
  and `sh scripts/check-sdd.sh`: exit 0; SDD 121 acceptance IDs.
  Log: `/private/tmp/arkdeck-signing-refresh-sdd.log`.
- Rebased the single slice onto main `fbbf925d0` after #2270 merged; no
  conflicts. Repeated affected service/signing tests: exit 0, 46 + 4 passed,
  including main's explicit cutover rollback regression.
  Log: `/private/tmp/arkdeck-signing-refresh-rebased-tests.log`.
- No full local unified gate, App build, performance capture or actual
  installed-service/Keychain acceptance was run for this Rust-only slice.

## CI

Not submitted yet. CI and maintainer review remain required before merge.
