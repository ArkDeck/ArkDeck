# TASK-XPA-011 — Windows DevEco files reader and pinned signing files, 2026-09-30

- Task: TASK-XPA-011 prerequisite, WM3 slice D2: gate-inventory group G15 ("Property lists and
  DevEco resources", `../TASK-XPA-004/windows-gate-inventory-20260930.md`) and the Unix-only
  `file_identity` / `canonical_json` the signing leaves use (G36 items named there). Platform
  layer and the portable manifest facts only.
- Base: protected `main` (developed on `b20827ab`, rebased onto `812dd324` before push; every
  check below was rerun on the rebased head).
- Host: the Windows 11 x64 reference host (Windows 11 Pro 10.0.26200), non-elevated. Nothing
  was installed, elevated or reconfigured; no hdc, board or signing tool was run. The host's
  DevEco Studio installation was only read (layout listing, ACL listing, and the ignored
  shape-only probe below); no file of it was copied into the repository, and no keystore,
  password, certificate or profile content was read.
- Relation to open PRs: reuses the store-owned `HostFileIdentity` of the NTFS host store as the
  identity type (unchanged by #2356, which is still open; this slice only makes its
  constructor `pub(crate)`). Does not touch `pty_exchange` (G19) or the credential store
  (#2354).

This is host evidence for a Rust port. It is not GJ-5 and not Windows platform acceptance: no
signing leaf is composed on Windows (see "What stays gated").

## What changed

| Area | macOS / Unix (unchanged behaviour) | Windows (new) |
| --- | --- | --- |
| DevEco child roles | `host_deveco_files.rs`: `DevEcoRoot` over `<X>.app/Contents`, five roles, `openat(O_NOFOLLOW)` walk from `/`, owner euid or root, no group/other write | `src/windows/deveco_files.rs`: the same names (`DevEcoRoot`, `DevEcoRole`, `DevEcoFileFacts`, `DevEcoFileRead`, `DevEcoIdentityChanged`, `DevEcoInputTooLarge`) over a Windows DevEco directory; four roles; `NtCreateFile` relative walk from the drive root with `FILE_OPEN_REPARSE_POINT`; owner and DACL read per level |
| Resource envelope, property lists | `host_deveco_resources`, `property_list` (CoreFoundation) | stay macOS-only: Windows DevEco ships no property list and has no `_CodeSignature` |
| Manifest facts | parsed inside `arkdeck-hoststore::deveco_content` | moved to the portable `arkdeck-hoststore::deveco_manifest` (`parse_deveco_manifests`), used by `deveco_content` on macOS with the same checks and error classes; the launch entry is chosen per host |
| Pinned signing files | `file_identity.rs` `measure`/`remeasure`/`foundation_resolved_path` (`cfg(unix)`) | the same functions on Windows over `arkdeck_platform::measure_host_file`/`host_resolved_path` (`src/windows/pinned_file.rs`) |
| `canonical_json` | `cfg(target_os = "macos")` | un-gated: pure Rust over `serde_json`, no platform reason; its tests now run on every host (its writers are still macOS-only, so it carries `allow(dead_code)` off macOS) |
| `SigningPresetStore::load_validated`, `remeasure_for_dispatch` | `cfg(unix)` | `cfg(any(unix, windows))`: all their dependencies now exist |
| Owner/DACL reading | `host_fs::Access` (owner is user, rights of user/others) | adds `owner_trusted`/`untrusted` and the rules `trusted_write_only`, `trusted_write_only_but_add`, `owner_private` beside the existing ones (no existing rule changed) |

## Windows DevEco layout (read from this host's installation, recorded as the mapping)

| Role | macOS (`<X>.app/Contents/…`) | Windows (`<root>\…`) |
| --- | --- | --- |
| `productManifest` | `Resources/product-info.json` | `product-info.json` |
| `sdkManifest` | `sdk/default/sdk-pkg.json` | `sdk\default\sdk-pkg.json` |
| `node` | `tools/node/bin/node` | `tools\node\node.exe` |
| `hvigor` | `tools/hvigor/bin/hvigorw.js` | `tools\hvigor\bin\hvigorw.js` |
| `signedResourceEnvelope` | `_CodeSignature/CodeResources` | none |

Other facts of the layout, not roles of the reader (the signing layer pins these by
`measure`, as on macOS): the bundled Java is `jbr\bin\java.exe`; the signer JAR is
`sdk\default\openharmony\toolchains\lib\hap-sign-tool.jar`; the toolchains directory carries
its own manifest `oh-uni-package.json` (same keys as the SDK manifest's `data` plus `meta`) and
`hdc.exe`. The product manifest's launch entry is `{"os":"Windows","arch":"amd64",
"launcherPath":"bin/devecostudio64.exe",…}`; both manifests have the macOS key set (extra keys
are ignored as on macOS). The installation directory and its files are owned by the system
principals and grant `Users`/`Authenticated Users` read and execute only.

## Decisions (proposals for the maintainer's review)

1. **Trusted principals = Unix root.** `SYSTEM` (`S-1-5-18`), `Administrators`
   (`S-1-5-32-544`) and `TrustedInstaller` hold root's place: an entry may be owned by them or
   by the token user, and write grants to them are not "group/other write". Everything an
   installer places under `Program Files` is owned and writable by these alone, and they can read
   and replace any file anyway (backup/restore privileges). Any other principal with a write
   right (`WRITE_DATA`, `APPEND_DATA`, `WRITE_EA`, `WRITE_ATTRIBUTES`, `DELETE_CHILD`, `DELETE`,
   `WRITE_DAC`, `WRITE_OWNER`) refuses the entry. The owner is checked too (stricter than the
   macOS `measure`, which reads only mode bits): an untrusted owner could rewrite the DACL.
2. **Drive root exception.** A drive root may let others add entries (`C:\` grants
   `Authenticated Users` "create folders"), the counterpart of the `/Applications` and sticky
   `/private/tmp` exceptions of the macOS walk: adding an entry never replaces, renames or
   removes an existing one. No other level has an exception.
3. **Private = no untrusted grant at all.** "Owned by this user, `mode & 0o077 == 0`" becomes
   "owned by the token user, and nobody but the user and the trusted principals is granted
   anything". A file inheriting the profile's DACL (user, `SYSTEM`, `Administrators`) is private;
   one any other principal may read is not.
4. **Executable = `.exe` + `FILE_EXECUTE`.** `access(X_OK)` becomes "the name ends in `.exe`
   and the kernel grants this caller `FILE_EXECUTE` on a `ReOpenFile` of the measured handle".
   A JAR is never "executable", as on macOS where it is not `+x` either.
5. **Canonical path.** The signing layer's standard absolute path on Windows is `X:\a\b`: a
   drive letter, `\` separators, no empty/`.`/`..` component, no trailing `\`, no `/`, stream
   (`:`) or reserved character, no component ending in `.` or space. `foundation_resolved_path`
   is `GetFinalPathNameByHandleW` of a following open without the `\\?\` prefix, so a pinned
   path must be the spelling on disk (case, long names) with no link or junction anywhere —
   the same "resolved == given" rule as Foundation's.
6. **Unknown layouts fail closed.** The DevEco root must be a canonical drive path holding the
   Windows launcher `bin\devecostudio64.exe`; a macOS tree copied onto a Windows disk, a
   relative, UNC, `.`/`..`, other-case or short-name spelling, and a junction anywhere are
   refused. There is no Windows `signedResourceEnvelope` role, so a caller cannot ask for one.
7. **Identity type.** A child's facts are `HostFileIdentity` (volume serial, `FileIdInfo` file
   id, size, last-write and change times — what macOS records as dev/ino/size/mtime/ctime), the
   link count (must be 1, as on macOS) and `executable` (where macOS reads the mode's execute
   bits). No new identity type.

## Tests (Windows)

| Target | What it proves |
| --- | --- |
| `arkdeck-platform/tests/windows_deveco_files.rs` (3 + 1 ignored) | the four roles read from a fixture tree in the Windows layout with pinned identities, node executable and the others not, a write moving the identity; refusals: macOS layout, relative/UNC/upper-case/`\bin\..`/`\.` spellings, a root reached through a junction, a junction inside the root, a second hard link, node without execute right, `Everyone` write on a child, on a role directory, on the SDK directory and on an ancestor, a manifest beyond its bound, a replaced root (`require_linked`); `measure_host_file`: SHA-256 and identity, `.exe` + execute right, read-only DACL not executable, readable-by-others not private, writable-by-others not trusted, and empty/over-bound/directory/relative/other-case/`..`/junction-component/absent paths unreadable; `host_resolved_path` follows a junction to the target spelling |
| `arkdeck-provider-workspace/tests/windows_file_identity.rs` (2) | Swift `measure`/`remeasure` on Windows with the Unix messages: private keystore measured and re-measured, write → drift, readable by `Users` → "must be owned by this user and private", writable by `Everyone` → "group/world writable", `java.exe` executable and a JAR not, eight non-canonical spellings (relative, `/`, `\\?\`, `.`, `..`, trailing `\`, stream, lower case) and a junction path → "not canonical absolute", absent/empty/directory → "not a bounded regular file"; a receipt with Windows paths passes `load_validated` and a changed certificate is drift |
| `arkdeck-hoststore` `deveco_manifest` unit tests (2) | the same manifest bytes give the same facts for `macOS`/`aarch64`, `macOS`/`x86_64` and `Windows`/`amd64`; another host's or architecture's launch entry is unsupported; malformed and foreign manifests keep the macOS error classes |
| `arkdeck-provider-workspace` `canonical_json` unit tests (2) | now run on Windows: the Foundation spellings hold off macOS |

The fixture manifests are synthetic documents in the recorded key set (no recorded macOS
fixture of these files exists under `rust/tests/fixtures`; none was taken from an installation).
The DevEco fixtures live under the account's `LocalAppData`: on this host the temporary
directory grants several sandbox groups modify and delete-child rights through inheritance,
which the reader correctly refuses as an unsafe ancestor. Every test removes its scratch tree.

Negative control, run once and reverted: with `trusted_write_only` answering `true`, the
platform refusal tests and the provider "group/world writable" case fail.

Live probe (ignored test, run once with the installation's root in `ARKDECK_LIVE_DEVECO_ROOT`):
the installation opens, the SDK directory is safe, all four roles read within their bounds,
only `node` is executable, both manifests have the recorded key shape with a
`Windows`/`amd64` launch entry, and the root is still linked. Result: pass. No path, version
or identity is printed or recorded.

## Checks

Run from `rust/` with `CARGO_TARGET_DIR=D:/cargo-target/d2-deveco CARGO_BUILD_JOBS=2`:

| Command | Result |
| --- | --- |
| `cargo fmt --all --check` | clean |
| `cargo clippy --workspace --all-targets -- -D warnings` | clean |
| `cargo test -p arkdeck-platform` | pass (lib 64 + 1 ignored; `windows_deveco_files` 3 + 1 ignored; every other target unchanged) |
| `cargo test -p arkdeck-provider-workspace` | pass (lib 11, incl. the 2 `canonical_json` tests now on Windows; `windows_file_identity` 2) |
| `cargo test -p arkdeck-hoststore` | pass (lib 52 + 2 ignored, incl. 2 new; every other target unchanged) |
| `sh scripts/check-sdd.sh` (`PYTHONUTF8=1`) | pass |
| `git diff --check` | clean |

The macOS `deveco_content` change (manifest parsing moved to `deveco_manifest`, same checks,
same error classes, same record) is compiled and tested by the macOS CI job; this host has no
macOS target.

## What stays gated

- `signing_install`, `signing_rekey`, `signing_removal`: every entry point is `pub(crate)` and
  reached only through `credential_owner`; un-gating them alone would be dead code. They wait
  for `credential_owner`.
- `credential_owner`: depends on `sdk_release` (`prepare`, `remove_material`) for the managed
  SDK release preset.
- `sdk_release`: depends on `signer` (the `hap-sign-tool` PTY exchange, G19, ConPTY — another
  slice) and on Unix private-directory creation (`DirBuilderExt`/`PermissionsExt`); its managed
  material paths are `/`-joined (`signing_preset::validate_fields`, `is_managed_sdk_release`),
  which needs the Windows spelling when it is ported.
- `keychain_secrets`: `trusted_daemon_fingerprint` (Authenticode identity, G12) and the Windows
  daemon install path; the Credential Manager store itself is #2354.
- `SigningPresetStore::default_root`: the Windows preset root location is a design decision of
  the WM3 install shape, not taken here.
- `deveco_password::material_layout` (DevEco's password material directory): not measured on
  Windows (it would mean reading signing secret material); stays refused.
- `host_deveco_resources`, `property_list`, and the hoststore `deveco_registry`/`deveco_content`
  read owner: the registry's content digest binds the macOS publisher signature and resource
  envelope; the Windows counterpart is the Authenticode trust of G12.
