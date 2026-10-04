# TASK-XPA-011 — Windows system tool trust for `tar` and `git` (WM3 GJ-5, ruling 69), 2026-10-04

- Task: TASK-XPA-011, WM3 slice GJ-5. This is the external-tool half of maintainer ruling 69
  (#2463's gate). `tar` is `System32\tar.exe` (Microsoft-signed bsdtar). `git` is Git for
  Windows. Each is trusted by its Authenticode publisher and its registered absolute path,
  never through PATH. The in-process `grep`/`sed`/`patch` and the reshaped code-owned tool
  table are another teammate's slice. That slice wires the two slots this PR provides: the
  archive tool and the optional source-control tool. This PR leaves `code_owned_tools`
  refusing on Windows, so no operation's availability changes.
- Base: one commit on `origin/main` `1f05dce0` (#2477).
- Host: the Windows 11 x64 reference host (Windows 11 Pro 10.0.26200), non-elevated. The tests
  read the host's own `C:\Windows\System32\tar.exe` (10.0.26100.9278) and its Git for Windows
  2.51.0.windows.2 (`C:\Program Files\Git`). Nothing was installed, elevated or reconfigured.
  No board, `hdc`, DevEco or credential was used.

## What changed

| Area | macOS / Linux (unchanged) | Windows (new) |
| --- | --- | --- |
| `arkdeck-platform` `windows/system_tool.rs` | — | `SystemTool { Tar, Git }`, `trusted_system_tool(tool) -> TrustedSystemTool { path, sha256 }` |
| `arkdeck-platform` `windows/identity.rs` | — | `catalog_chain`: `WinVerifyTrust` over the system catalog that lists the image's Authenticode hash, computed by `CryptCATAdminCalcHashFromFileHandle2` from the held handle. `authenticode_chain` and the catalog path share one `verified_signer_chain` (same policy, no behaviour change for existing callers) |
| `arkdeck-platform` `host_fs.rs`, `publisher.rs`, `account.rs` | — | `Access::system_write_only` (owned by `SYSTEM`/`Administrators`/`TrustedInstaller`, not by the caller, and nobody else may change it), `subject_organizations_and_names`, and `known_folder` made crate-visible |
| `arkdeck-hoststore` `workspace_profile.rs` | — | `WorkspaceCommandPreset::trusted_system(preset_id, tool, timeout)`: a preset pinned by the verified path and digest. A failure reads `workspace.toolchainUnavailable: <tool> is not trusted on Windows: <reason>` |

How `trusted_system_tool` measures a tool, through one handle:

1. **Path.** The registered path is code-owned. `tar` is `GetSystemDirectoryW` + `tar.exe`.
   `git` is the `FOLDERID_ProgramFiles` Known Folder + `Git\mingw64\bin\git.exe`. No
   environment variable or PATH is read. The root is opened without following a reparse
   point and must not be one. Its spelling is the system's final path. Each directory below
   it and the file are then opened the same way, and each must be named by the system with
   exactly that spelling: no link, junction, short name or other case.
2. **Ownership.** The root, each directory and the file must be `system_write_only`.
3. **The file.** It is held with writes and deletion denied (`open_locked_file`). It must be
   a regular file of at most 256 MiB, and a PE image the caller may execute.
4. **Signature.** `WinVerifyTrust` (generic Authenticode policy, whole-chain revocation from
   cache only) must accept the embedded signature or the catalog signature. The accepted
   chain must be the tool's pinned publisher.
5. **Digest.** The SHA-256 is read from the same held handle, which must not have moved
   (same file id, size and times).

The pinned preset is launched by the existing `VerifiedToolDispatch` → `VerifiedTool::open(path,
sha256)`. That launch locks the namespace, checks the digest and resumes the suspended image
only once it is proven to be the retained file. So what runs is the image whose signature was
verified, and no new launcher was needed.

## Delegated minor decisions, pending the next rulings batch

The lead approved the shape on 2026-10-04. These details are recorded for the rulings batch:

1. **Which `git.exe`.** The pinned image is `Git\mingw64\bin\git.exe`, the real git. The
   `Git\cmd\git.exe` launcher is not used: it would start a second image that no pin covers.
   Git's own helpers (`libexec\git-core`) and DLLs beside the image are not measured. They are
   covered by requiring every directory from Program Files down to be system-owned and
   unchangeable by the caller. The workspace only runs builtins (`status`, `diff`,
   `stash create`). Only the x64 layout (`mingw64`) is registered. An ARM64 Git for Windows
   (`clangarm64`) is refused until it is registered.
2. **Publisher pins.**
   - `tar` must be signed by `O=Microsoft Corporation`. `tar.exe` carries two signatures that
     each verify, and either is accepted. Its embedded signature is `CN=Microsoft Windows Third
     Party Application Component`, rooted at Microsoft Root Certificate Authority 2011 (DER
     SHA-256 `847df6a7…7c61`). The system catalog's signature is `CN=Microsoft Windows`,
     rooted at Microsoft Root Certificate Authority 2010 (`df545bf9…163e`).
     `Get-AuthenticodeSignature` reports only the catalog one.
   - `git` must be signed by `O=Johannes Schindelin, CN=Johannes Schindelin`, Git for Windows'
     release signer. No root is pinned: its Sectigo chain (Public Code Signing CA R36 → Root
     R46) is cross-signed to more than one root (`AAA Certificate Services` on this host).
   - In both cases the leaf must carry exactly one `O=` and one `CN=`.
   - A change of signer fails closed. The update path is to edit the pin in `system_tool.rs`.
3. **Catalog signatures.** An image with no embedded signature that verifies is checked
   against the system catalog. The member hash is computed from the held handle, never from
   the path. An image the catalog database cannot hash, such as a malformed PE, is treated as
   listed by no catalog.
4. **Writability.** Every directory and the file must be owned by a trusted principal and
   unchangeable by anyone else, the caller included. This rule is stricter than the Bootstrap
   tool rule, which also accepts the caller as owner. A per-user Git for Windows
   (`%LOCALAPPDATA%\Programs\Git`) is therefore refused.
5. **Refusal wording.** A refusal reads `workspace.toolchainUnavailable: <tool> is not trusted
   on Windows: <reason>`.

## Measurements

| Check | Result |
| --- | --- |
| `cargo test -p arkdeck-platform --lib system_tool` (8 tests) | The registered `tar` and `git` are trusted, with the SHA-256 of their bytes. Both `tar.exe` signatures verify and match Microsoft's pin, and they come from different leaves. The trusted `git` is not the `cmd` launcher. Each tool is refused under the other's publisher. `TAR.EXE` and `GIT\…` spellings are refused. A copy in a user directory still verifies as signed but is refused for its ownership. A `tar.exe` with 8 appended bytes, a `git.exe` with one flipped byte and this unsigned test binary are refused. A junction to System32 as the root is refused. A swapped signer/root pin, a near-miss organisation and a one-certificate chain do not match |
| `cargo test -p arkdeck-hoststore --lib workspace_profile::windows_tests` (5 tests) | `trusted_system` presets for `tar` and `git` carry the platform's path and digest. Run through `VerifiedToolDispatch`, they print `bsdtar 3.8.8 - libarchive 3.8.8 …` and `git version 2.51.0.windows.2`. A launch by another digest is `dispatch refused` and runs nothing. In a child process with a shadow directory first on PATH, holding a `tar.exe` (`whoami`) and a `git.exe` (a `tar` copy), both presets resolve and run the registered images |

## Gates

| Check | Result |
| --- | --- |
| `cargo fmt --all --check` | exit 0 |
| `cargo clippy --workspace --all-targets -- -D warnings` (Windows) | exit 0 |
| `cargo clippy --target aarch64-apple-darwin --workspace --all-targets -- -D warnings` (stubbed `xcrun`/`ar`/`cc`; type and lint only) | exit 0 |
| `cargo clippy --target x86_64-unknown-linux-gnu --workspace --all-targets -- -D warnings` (same stubs) | exit 0 |
| `cargo test -p arkdeck-platform`, `-p arkdeck-hoststore`, `ARKDECK_DEV_SIGNER_THUMBPRINT` set | exit 0: platform 35 `test result: ok` (246 passed), hoststore 110 (483 passed), 0 failed. The only `SKIPPED` lines are the two known wildcard-listener skips (platform) |
| the same tests with `TEMP`/`TMP` on an 8.3 short path on C: (`…\Temp\LONGTE~1`) | exit 0, the same counts, the same two skips |
| `PYTHONUTF8=1 sh scripts/check-sdd.sh`; `git diff --check` | `check_sdd: 0 error(s), 0 warning(s)`; diff check clean |

No contract input, Catalog or coverage file changed, so no generator ran.

## Left out, and why

- **Wiring `tar` and `git` into the profile's code-owned tool table**, and so every
  profile-served operation. The teammate reshaping the table does this, as agreed with the
  lead. `code_owned_tools` and `ark_deck` still refuse with the existing reason.
- **CLI leaves, `WINDOWS_MEASURED_LEAVES` and coverage.** No leaf changes behaviour in this
  PR.
- **SwiftPM** (the ArkDeck profile's build/test). This is not part of ruling 69.
