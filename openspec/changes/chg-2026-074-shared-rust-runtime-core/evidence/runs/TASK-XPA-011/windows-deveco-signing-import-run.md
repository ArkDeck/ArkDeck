# TASK-XPA-011 — DevEco signing import on Windows (`install --build-profile`, `migrate-deveco`), 2026-10-05

- **Task.** TASK-XPA-011, gap G8 of the phase A runbook (#2525). The lead's decision of
  2026-10-04: port `runtime signing install --build-profile` and `runtime signing migrate-deveco`
  to Windows at macOS parity, so that the maintainer handles no plaintext password beyond the
  console prompt.
- **Base:** one commit on `origin/main` `70bc3f86` (#2523).
- **Host:** the Windows 11 x64 reference host, non-elevated.
  - This host's DevEco material was read only by the live-gated test. That test decodes in memory
    and checks the shape only; nothing was printed, logged or written.
  - The material layout was sampled by name and size only.
  - No board, `hdc` or production credential was used. Credential Manager was not opened (the
    library tests use an in-memory secret source).

## What DevEco writes on Windows (sampled 2026-10-05)

- **Keystores.** `%USERPROFILE%\.ohos\config\default_<project>_<hash>.p12` (with `.cer`, `.csr`,
  `.p7b`), and the same under `config\openharmony\`.
- **Material beside each keystore directory.** `material\fd\{0,1,2}\<32-hex name>` (16 bytes each),
  `material\ac\<name>` (16 bytes) and `material\ce\<name>` (48 bytes). This is the macOS layout.
- **DACLs.** Inherited from the profile: the user, SYSTEM and Administrators have full control,
  and one local sandbox group has read and execute. This is trusted-write-only (the macOS
  `mode & 0o022 == 0`).
- **Build profile.** `build-profile.json5` names `"storeFile": "C:\\Users\\…\\default_….p12"`, a
  JSON-escaped drive path. `storePassword` and `keyPassword` are hex ciphertext (82 hex digits in
  the sample).

## What changed

| Area | macOS (unchanged) | Windows (new) |
| --- | --- | --- |
| `arkdeck-platform` | — | `trusted_write_only_directory(path)`: a directory opened without following a reparse point, in its spelling on disk, that only its owner and the trusted principals may change |
| `arkdeck-provider-workspace` `deveco_password` | the Unix material layout | the same layout through the platform's reads. A directory is trusted-write-only and canonical. A file is measured (trusted-write-only, size, single link) and read as the file it measured (SHA-256 compared). The decoder itself is shared and unchanged |
| `arkdeck-cli` `signing_inputs` | the Unix build-profile reader | built on Windows. The profile is measured trusted-write-only and read as the same file. `storeFile` is read as a JSON string whose only escapes are `\\` and `\/`, and must be a canonical drive path (`X:\…`, no empty, `.` or `..` component) |
| `arkdeck-cli` `signing_leaves` | unchanged | `install --build-profile` and `migrate-deveco` served. `migrate-deveco --daemon` must name the installed daemon the CLI pinned, by its spelling and by the file it resolves to. The `unsupportedOnPlatform` refusals are removed |
| Coverage | — | the two `migrate-deveco` spellings leave `MACOS_HOST_LEAVES`. The export changes no entry: the leaves map to no Windows `implemented` feature on their own, and stay unmeasured through a signed daemon |

## Measurements

| Check | Result |
| --- | --- |
| `cargo test -p arkdeck-provider-workspace --test deveco_password` (now on Windows too) | 6/6. The three Swift vectors decode to their plaintexts. Swift's re-encoding of ill-formed key material and the PBKDF2 vectors match. Ciphertext decodes through the material tree beside the keystore, and `.DS_Store` is ignored. The material refusals hold: zeroed, tampered, missing slot, second salt; a directory granting Users write ("directory is absent or unsafe"); a second name of a material file, which is a hard link here ("file is absent or unsafe"); a short part; absent material |
| `cargo test -p arkdeck-cli --test windows_signing_leaves` | 8/8. A Windows-spelled build profile (`\\`-escaped storeFile) with the Swift vector material: `read_deveco_profile` reads it, and the ciphertext decodes to the Swift plaintext. `install --build-profile` asks for no password and stores the decoded pair in the envelope. `migrate-deveco` replaces the installed envelope with the decoded pair and keeps the credential. A profile naming another keystore is refused before any secret. Refused profiles: two storeFiles, a relative path, a non-`\\` escape, a `..` component, a missing keyPassword, a profile granting Users write, another spelling. `migrate-deveco --daemon` accepts only the installed daemon. The process-level `migrate-deveco` (both spellings) with an unpinned daemon is refused with exit 1 before the preset root or Credential Manager is touched, and no longer answers `unsupportedOnPlatform` |
| Live: `ARKDECK_LIVE_DEVECO_BUILD_PROFILE=<a DevEco build-profile.json5 on this host>` | `a_live_deveco_build_profile_decodes_through_its_own_material` passed: both of the host's passwords decode through DevEco's own Windows material. Only their shape is checked, nothing is printed, and the secrets are wiped |
| `cargo test -p arkdeck-cli --lib signing_inputs` | the `storeFile` reading and canonical rules on Windows (`\\`, `\/`, refused escapes, drive, UNC, `..`, `/`) |

## Delegated minor decisions, pending the next rulings batch

1. **Windows `storeFile` spelling.** DevEco writes a JSON-escaped drive path. The reader accepts
   only the `\\` and `\/` escapes and refuses any other. The result must be a canonical `X:\…`
   path. A UNC path is refused.
2. **A second name of a material file** (a hard link) is refused on Windows, as macOS refuses a
   symbolic link to it. A symbolic link needs a privilege on Windows; a hard link does not.
3. **Trusted-write-only** stands for the Unix `mode & 0o022 == 0`. The owner is the user or a
   trusted principal, and nobody else may change the file. Read access by others (such as the
   host's sandbox group) does not matter, as on macOS.
4. **`migrate-deveco --daemon` on Windows** names the installed daemon the CLI pinned
   (`ARKDECK_DAEMON_PATH` or the sibling `arkdeck-agentd.exe`, satisfying the signing pin). This
   stands in for the macOS "canonical installed LaunchAgent daemon".

## Gates

| Check | Result |
| --- | --- |
| `cargo fmt --all --check`; `git diff --check` | exit 0; clean |
| `cargo clippy --workspace --all-targets -- -D warnings` (Windows) | exit 0 |
| the macOS and Linux cross-check clippy (stubbed toolchain; type and lint only) | exit 0, both |
| `cargo test -p arkdeck-platform`, `-p arkdeck-provider-workspace`, `-p arkdeck-cli`, `ARKDECK_DEV_SIGNER_THUMBPRINT` set | exit 0: platform 248 passed, provider-workspace 35, CLI 262; 0 failed. The only `SKIPPED` lines are the two known wildcard-listener skips (platform). The first CLI run failed only because `arkdeck-agentd.exe` was not yet built in this target directory (`windows_signed_runtime` says so); after `cargo build -p arkdeck-agentd` it passed |
| the same with `TEMP`/`TMP` on an 8.3 short path on C: | exit 0, the same counts |
| `PYTHONUTF8=1 sh scripts/check-sdd.sh` | 0 errors, 0 warnings |
| `arkdeck maintainer contracts export` | no change to `cli-feature-coverage.json` |

## Left out, and why

- **The signed-CLI measurement of `runtime signing *`.** The installed account daemon's
  Credential Manager scope is the production one, so a process test would touch the user's real
  credential. The leaves stay unmeasured on Windows, as before. The library tests cover the
  documents.
- **The phase A runbook's §4.5 and gap G8.** The runbook PR (#2525) is not on `main` yet. Once
  it is, a docs follow-up switches §4.5 to `runtime signing install … --build-profile <DevEco
  build-profile.json5>` and closes G8.
