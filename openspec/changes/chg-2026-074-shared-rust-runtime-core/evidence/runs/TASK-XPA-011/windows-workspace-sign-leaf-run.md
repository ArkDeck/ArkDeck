# TASK-XPA-011 — `workspace sign` end to end through the real CLI on Windows (WM3 GJ-5)

Change: CHG-2026-074-shared-rust-runtime-core. Milestone WM3 (GJ-5), signing.

Base: protected `main` `7756c9d6d`.

Host: the Windows 11 x64 reference host, non-elevated, with DevEco Studio installed
(`ARKDECK_LIVE_DEVECO_ROOT`). The run measured DevEco and never ran it. No HDC, device or board
was used. Nothing installed was read or written. Credential Manager was written only under
`ArkDeck-fixture/<run>/`, and that item was removed at the end. Host tests are not Windows
acceptance.

## What

`arkdeck-agentd/tests/spawning/workspace_sign_leaf.rs` runs the real signed `arkdeck.exe`
against the signed test daemon (`signed_daemon.rs`). The flow:

1. **A daemon that signs nothing registers:**
   - the host's DevEco Studio (`runtime tool register --kind deveco`);
   - a minimal OpenHarmony project (`workspace project register`), whose profile resolves through
     the code-owned tools.
2. **The test installs the fixture's signing:**
   - the Swift signing oracle's receipt (`rust/tests/fixtures/workspace-sign-oracle/preset-v1.json`)
     over the oracle's material, its paths in the host's spelling and its project the registered
     one, in a preset store below the test's scratch directory;
   - the oracle's fake passwords as the secret envelope under `ArkDeck-fixture/<run>/`.
3. **The next daemon composes that signing and registers the preset.**
   `workspace preset register --kind signing --template openharmony.local-sign@1` pins the DevEco
   toolchain and the receipt's credential.
4. **The next start signs.**
   - `operation list` reports `workspace.sign-openharmony-hap@1` as `available`.
   - `workspace sign --target workspace-host --inputs-file …` signs the oracle's `good.hap` Import
     (`job-input-hap`, seeded into the root's Artifact store as the recording published it):
     exit 0, `succeeded`, not `outcomeUnknown`, both Artifacts read back with their bytes
     verified.
   - `artifact list --job` names `signed.hap` and `signing-report.json`. The signed HAP's digest
     is the input's with the stand-in's marker appended.
5. **Afterwards:**
   - no attempt directory is left;
   - neither password, in UTF-8 or UTF-16, is in any file below the scratch directory, apart from
     the test binaries that define them;
   - the fixture's credential is gone from Credential Manager.

**The signer.** It is #2508's stand-in for `hap-signer.sh`, not DevEco's `hap-sign-tool`:
- No keystore, certificate or real password is used.
- The stand-in now lives in one shared file (`arkdeck-hoststore/tests/sign_stand_in/mod.rs`),
  used by #2508's oracle replay and by a new `harness = false` test binary of this crate
  (`windows_sign_stand_in`). The fixture receipt names that binary as its Java launcher, and the
  daemon runs it on a pseudo console.
- #2508's replay is unchanged apart from calling the shared stand-in.

## The test-build seam (delegated decision, pending the next rulings batch)

The lead decided this on 2026-10-05: option (b), delegated.

**What it is.** A development root composes no signing, and the installed daemon signs only over
the account's preset store and Credential Manager, which no test may touch. So the signed test
daemon takes a fixture's signing:
- `ARKDECK_TEST_SIGNED_DAEMON_SIGNING=<preset store>|<namespace>`, read by `signed_daemon.rs`;
- `windows_lifecycle::TEST_SIGNING`, which composes the workspace provider's signing and the
  preset owner's credential pinning over that store and Credential Manager's
  `ArkDeck-fixture/<namespace>/` scope (`arkdeck_hoststore::fixture_signing`), bound to no daemon
  identity.

**Not in the production daemon.** The static and the code that reads it are
`cfg(all(windows, test))`. Every other build, `arkdeck-agentd.exe` included, compiles a
`test_signing` that answers `None`. The lead's ruling of 2026-10-04 was about production daemon
inputs, and this one exists in test builds only, as `CLOCK`, `MUTATION_ROOT` and `HELPER` do.

**Proved absent.** `workspace_sign_leaf::the_daemon_build_has_no_fixture_signing` reads the
daemon's own build (`CARGO_BIN_EXE_arkdeck-agentd`, compiled without `cfg(test)`):
- it carries the production signing composition's text ("the signing credential store is
  unusable");
- it carries neither the seam's ("the test build's fixture signing is unusable") nor the
  variable's name.

## Measured

| test | result |
| --- | --- |
| `workspace_sign_leaf::the_real_cli_signs_a_hap_with_a_registered_signing_preset` (`ARKDECK_LIVE_DEVECO_ROOT` set) | pass: as above |
| `workspace_sign_leaf::the_daemon_build_has_no_fixture_signing` | pass |
| `arkdeck-hoststore` `windows_workspace_sign_oracle` over the shared stand-in | GATES_ORACLE |

**Coverage.** `workspace.sign` joins `WINDOWS_MEASURED_LEAVES`. The regenerated coverage moves
`workspace.sign-openharmony-hap@1` to `implemented` on Windows, and nothing else changes. The
census drops its row.

**What CI covers.** Without `ARKDECK_LIVE_DEVECO_ROOT` the signing test says SKIPPED, so the
signing itself is live-only. CI still runs the seam-absence check, the oracle replay and the
development root's refusal (`windows_signed_runtime.rs`).

## Leftover fixture credentials on this host

Before this run, Credential Manager held 22 `ArkDeck-fixture/race-11176/svc/…` items (`kept-*`,
`keep-*`, `churn-*`). No committed test writes that namespace:
- `windows_credential_store.rs` names its namespaces `test-<pid>-<token>` and deletes them on
  drop;
- `race-` appears in no revision of any ArkDeck ref.

They came from an uncommitted race-reproduction build, so there is no leak in the tree to fix.
They were removed, and nothing outside `ArkDeck-fixture/` was touched. This run's own namespace
(`sign-<nonce>`) is removed by the test, which checks that it is gone.

## Local targeted checks

Rust 1.99.0, `CARGO_BUILD_JOBS=2`, `CARGO_TARGET_DIR=D:/cargo-target/s1-sign`, with
`ARKDECK_DEV_SIGNER_THUMBPRINT` set; heavy commands through the host's gate slot.

| command | result |
| --- | --- |
| `cargo fmt --all --check` | GATES_FMT |
| `cargo clippy --workspace --all-targets -- -D warnings` | GATES_CLIPPY |
| `cargo test -p arkdeck-cli -p arkdeck-agentd -p arkdeck-hoststore --no-fail-fast` | GATES_TEST |
| the same with `TEMP`/`TMP` on an 8.3 short path on C: | GATES_SHORT |
| macOS (`aarch64-apple-darwin`) and Linux (`x86_64-unknown-linux-gnu`) clippy `-D warnings`, stub toolchain | GATES_CROSS |
| `PYTHONUTF8=1 sh scripts/check-sdd.sh` | GATES_SDD |
| `git diff --check origin/main...HEAD` | GATES_DIFF |
| `arkdeck maintainer contracts check` | GATES_CONTRACTS |

## CI

To be recorded by the next slice.
