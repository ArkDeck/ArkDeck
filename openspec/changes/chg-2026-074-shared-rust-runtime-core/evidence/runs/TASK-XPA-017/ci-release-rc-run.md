# TASK-XPA-017 — notarized release candidate built in GitHub Actions (macOS, 2026-09-29)

The signed and notarized RC used to come only from the maintainer's own logged-in terminal: the
Developer ID key and the `notarytool` Keychain profile live in the maintainer's login keychain, which a
locked session or the agent sandbox cannot use, and the agent must not handle credentials. This change
moves the same build (`scripts/release/build_macos_release.py release`) into a GitHub Actions workflow
whose credentials are secrets of the `release` environment. **Nothing was signed with Developer ID,
notarized or sent to Apple, no credential, keychain item, certificate or Apple account was used, and no
GitHub environment or secret was created.** The workflow's first real run follows the maintainer's
one-time setup and a merged version bump.

## What changed

- **`.github/workflows/release-rc.yml`** (new), one job `release-rc` on `macos-26` in environment
  `release`, Xcode 26.6 as the App lane uses:
  - Triggers: push to `main` changing `scripts/release/release-version.json`, and `workflow_dispatch`;
    the first step fails any ref but `refs/heads/main`. No `pull_request` trigger, so code that has not
    merged never runs with the secrets. Top-level `permissions: contents: read`; the job adds
    `actions: read` for the duplicate check. `concurrency: release-rc`, never cancelled.
  - Duplicate check: a non-expired artifact `arkdeck-rc-<version>-<build>` or a GitHub Release asset
    `ArkDeck-<version>-<build>.dmg` ends the job green with a notice; every later step except the cleanup
    is conditioned on `steps.existing.outputs.exists == 'false'`.
  - Fetches before any credential exists: `cargo fetch --locked` in `rust/`; ArkForge (public) checked
    out exactly at the `rust/Cargo.toml` pin into `$RUNNER_TEMP/ArkForge` (pin read through
    `build_macos_release.arkforge_pin()`) and `cargo fetch --locked` there (its packager builds offline).
  - Credential install: the five file-shaped secrets are required non-empty; the `.p12` goes into a
    temporary keychain with a random `openssl rand -hex 32` password masked before first use
    (`create-keychain`, `set-keychain-settings -lut 21600`, `unlock-keychain`,
    `import -T /usr/bin/codesign -T /usr/bin/security`, `set-key-partition-list -S
    apple-tool:,apple:,codesign:`), which is prepended to the user search list; the `.p12` is deleted
    once imported; the two profiles and the `.p8` are decoded to files under
    `$RUNNER_TEMP/arkdeck-release-credentials` (umask 077); only paths go to `GITHUB_ENV`.
  - Build: `build_macos_release.py release --output "$RUNNER_TEMP/rc" --arkforge-checkout ...` with the
    key ID and issuer from secrets in that step's env only.
  - `Remove release credentials` directly after the build, `if: always()`: deletes the keychain (which
    also takes it off the search list) and the credential directory, before anything is uploaded.
  - Upload artifact `arkdeck-rc-<version>-<build>` (DMG, `release-receipt.json`, both notary logs;
    `if-no-files-found: error`, 90 days) and a summary with the DMG SHA-256.
  - Secrets (environment `release`): `ARKDECK_DEVELOPER_ID_P12_BASE64`,
    `ARKDECK_DEVELOPER_ID_P12_PASSWORD`, `ARKDECK_CLI_PROVISIONING_PROFILE_BASE64`,
    `ARKDECK_DAEMON_PROVISIONING_PROFILE_BASE64`, `ARKDECK_NOTARY_API_KEY_P8_BASE64`,
    `ARKDECK_NOTARY_API_KEY_ID`, `ARKDECK_NOTARY_API_ISSUER_ID`.
- **`build_macos_release.py`**: notary credentials are exactly one of `ARKDECK_NOTARY_KEYCHAIN_PROFILE`
  (optionally with `ARKDECK_NOTARY_KEYCHAIN`) or the API key triple `ARKDECK_NOTARY_API_KEY_PATH`
  (absolute, regular file), `ARKDECK_NOTARY_API_KEY_ID`, `ARKDECK_NOTARY_API_ISSUER_ID`
  (`notarytool --key --key-id --issuer`); both, neither, a partial triple, a relative key path, or
  `ARKDECK_NOTARY_KEYCHAIN` with an API key are refused before anything runs. The preflight
  `notarytool history`, every `submit` and every `log` use the same arguments; `run` still names no
  argument past the subcommand when a call fails, so neither kind reaches an error message. Optional
  `ARKDECK_CODESIGN_KEYCHAIN` (absolute, no whitespace): preflight requires it on
  `security list-keychains -d user` (the export and ArkForge's packager find the identity only there)
  and looks the identity up in it; the DMG `codesign` gets `--keychain`; the App archive gets
  `OTHER_CODE_SIGN_FLAGS=--timestamp --keychain <path>` (a command-line setting replaces the Release
  configuration's `--timestamp`, so it is restated). All existing refusals are unchanged.
- **`build-helpers.sh`**: the same exactly-one-of notary rule (exit 64/66), an argument array for
  `notarytool submit`; nothing prints the key, its ID or the issuer.
  **`package-rust-helpers.sh`**: `--keychain "$ARKDECK_CODESIGN_KEYCHAIN"` on both signatures when set
  and the identity is not ad hoc (bash 3.2-safe empty-array expansion); its six positional arguments and
  its other callers are unchanged.
- **Tests**: `scripts/release/test_build_macos_release.py` adds the API-key path end to end (every
  notarytool call carries `--key/--key-id/--issuer`, none `--keychain-profile`; key bytes never in the
  call log or output; key ID and issuer never in output), the five refusal cases before any tool runs,
  `build-helpers.sh` refusing both/neither/partial with exit 64 and no tool call, the codesign keychain
  reaching the three signatures this repository makes and the archive, and a keychain off the search
  list refused before any build. `scripts/test_agent_pr_workflow.py` adds `validate_release_rc_contract`
  and 21 mutations it must reject (a `pull_request`/`pull_request_target` trigger, other branches or
  paths, no or another environment, no main check, cancellable, write permission, cleanup on success
  only / keeping the keychain / after the upload, a secret in the job env or another step, an eighth
  secret, unmasked password, `set -x`, a printed secret, the `.p12` kept, rebuilding an existing RC,
  an upload that may be empty), and asserts no other workflow names the environment or the secrets.
  It runs in the Swift CI `plan` job on every push, so a PR that edits only the workflow is covered.
- **Docs**: `docs/release/macos-install.md` gains «维护者：从 CI 产出 RC（Release candidates from CI）»
  (one-time setup: environment `release` restricted to `main`; App Store Connect Team Key with the
  Developer role; the seven `gh secret set ... --env release` commands; what the workflow does; producing
  an RC by merging a `release_version.py bump-build` PR and fetching it with `gh run download`), and the
  local section documents both notary kinds and `ARKDECK_CODESIGN_KEYCHAIN`.

Not verified here, only on the first real run: the hosted runner's `security`/`codesign` behaviour with
the temporary keychain, `xcodebuild -exportArchive` finding the identity through the search list, and
ArkForge's packager signing through it. The fixture tests cannot exercise those, and actionlint is not
installed on this host.

## Local targeted checks

| Command | Exit | Result |
| --- | --- | --- |
| `python3 scripts/release/test_build_macos_release.py` | 0 | 24 tests OK (19 before, 5 new) |
| `python3 scripts/test_agent_pr_workflow.py` | 0 | 17 tests OK (1 new with 21 mutation subtests) |
| `python3 scripts/ci/test_plan.py` | 0 | 40 tests OK (planner untouched) |
| PyYAML 6.0.3 `safe_load` of `release-rc.yml` (scratch venv) | 0 | events `push` (`branches: [main]`, `paths`), `workflow_dispatch`; 13 steps |
| `bash -n` on `build-helpers.sh`, `package-rust-helpers.sh` | 0 | syntax OK |
| `sh scripts/check-sdd.sh` | 0 | 0 errors, 0 warnings |

Not run: the workflow itself (needs the `release` environment and its secrets, maintainer-only), Rust or
Swift builds (no Rust or Swift source changed).

## CI

PR and run ids are recorded by the follow-up that records this PR's CI.
