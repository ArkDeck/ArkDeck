# TASK-XPA-011 — Windows registration of node and hvigor as a registered toolchain reference, 2026-09-30

- **Task.** TASK-XPA-011 (WM3). node and hvigor register on Windows as the child roles of one
  content-addressed DevEco toolchain (`toolchain:sha256:<digest>`), as on macOS. A build then
  runs them by that reference's pinned identities, never from PATH. This builds on:
  - the D2 DevEco reader (#2362);
  - the signing owners (#2369) and signing leaves (#2372);
  - the install-shape crib (#2401).
- **Base.** Protected `main` at `86d2f2b8`; `origin/main` was merged before push.
- **Host.** The Windows 11 x64 reference host, non-elevated.
  - Nothing was installed, elevated or trusted.
  - The fixtures sign copies of `System32` executables with the host's existing development
    signer. Nothing is run.
  - The host's real DevEco Studio installation was read once, by the ignored live test: its
    files were read and hashed, and its signatures checked. The registry it wrote went into a
    scratch root, since deleted. No signing material was read.

This is host evidence for a Rust port. It is not GJ-5 and not Windows platform acceptance, and no
hvigor build ran.

## What changed

| Area | macOS (unchanged) | Windows (new) |
| --- | --- | --- |
| Native signature (`arkdeck-platform`) | `inspect_native_code_signature` / `inspect_deveco_publisher_signature` over `SecStaticCode` | `src/windows/code_signature.rs`, with the same names and answer type (`NativeCodeSignature`). `verified` when `WinVerifyTrust` accepts the image (the pipe client's policy); `identifier` = the signer leaf's single `O=`, else its `CN=`; `code_directory_sha256` = the leaf certificate's SHA-256; `team_identifier` none. `unsigned` only for `TRUST_E_NOSIGNATURE`; any other failure is refused (`PermissionDenied`). The DevEco check requires `bin\devecostudio64.exe` to be `verified` by `DEVECO_PUBLISHER` = `Huawei Technologies Co., Ltd.` (the macOS check pins the bundle identifier and team). `identity::authenticode_chain` exposes `WinVerifyTrust`'s status; `trusted_signer_chain` is a wrapper over it and is unchanged for the pipe client. `publisher::signer_name` reads the subject name. |
| DevEco content (`arkdeck-hoststore::deveco_content`) | `.app/Contents`, five roles, bundle publisher signature, resource envelope | The DevEco Studio directory with four roles: `productManifest`, `sdkManifest`, `node`, `hvigor` (D2's reader). node must be executable and Authenticode `verified`; the launcher must be the DevEco publisher's. Manifests are parsed for `Windows`/`amd64`. Children are pinned by the host store's file identity (volume serial, file id, size, write/change times) and their SHA-256. The content digest adds `"platform":"windows"` to the macOS digest input, so a Windows reference can never equal a macOS one. |
| Index (`deveco_registry`) | `arkdeck.bootstrap-deveco-toolchains/1`, macOS record form | The same schema and keys. Each host accepts only its own record form: on Windows a standard `X:\…` root and exactly the four roles; the projection says `"platform":"windows"`. A macOS record is refused on Windows, and a Windows record on macOS (the macOS check `starts_with('/')` and five roles is unchanged). |
| Owner (`deveco_registry_owner`) | `register`, `inspect`, `list` over the Bootstrap store root | Built on Windows. The registration source is the DevEco Studio directory as a standard `X:\…` path; relative, `/`-spelled, `.`/`..`, `\\?\` and macOS spellings are `invalidInput`. The reader refuses any other layout, link or junction. Retirement (`tool_retirement.rs`) stays macOS-only. |

**Not from PATH.** A registered record names node and hvigor by the DevEco root and each role's
relative path, identity and SHA-256. Every inspect or list re-measures them, and a changed byte
makes the reference fail. Nothing in the registry or the reader consults PATH. On this host PATH
resolves `node` to another Node.js installation, which is never considered.

## Delegated minor decisions (pending the next rulings batch)

1. **Trust vocabulary on Windows.** The record keeps the macOS trust fields. `signingIdentifier`
   carries the Authenticode signer's name (single `O=`, else `CN=`), and
   `codeDirectoryIdentitySHA256` carries the signer leaf certificate's SHA-256, which changes
   when the publisher re-signs, as a code directory hash changes on re-signing.
   `teamIdentifier` is absent.
2. **DevEco publisher pin.** The launcher's signer must be exactly
   `Huawei Technologies Co., Ltd.`, verified here on the installed DevEco Studio. A change of
   publisher name is a reviewed constant change, as the macOS team identifier is.
3. **Host-tagged digest.** `"platform":"windows"` is in the content digest. The schema stays
   `arkdeck.deveco-toolchain-content/2`, because the CLI's resource projection checks that
   version.

## Tests (Windows)

| Target | What it proves |
| --- | --- |
| `arkdeck-platform/tests/windows_code_signature.rs` (2) | An unsigned copy is `unsigned`, and an absent file is an error. A signed copy is `verified`, with the signer's name and leaf SHA-256; another image by the same signer names the same leaf. An image byte changed after signing is refused, never reported as `unsigned`. The launcher check refuses an unsigned launcher and another publisher. |
| `arkdeck-hoststore` `deveco_registry_owner::windows_registration_tests` (4 + 1 ignored) | **Register** a fixture DevEco Studio directory (signed launcher and node, synthetic manifests, a script hvigor): `platform: windows`, the four roles, node `verified` and executable, hvigor pinned by bytes and not executable. The index reads back byte for byte; re-registration writes nothing; `inspect` and `list` re-measure. Other hvigor bytes make the reference fail, with the index left unchanged. **Refusals**: an unsigned node, or a launcher of another publisher, gives `admissionDenied`, with the index still empty. Relative, `/`, `.`, `..`, `\\?\` and macOS sources give `invalidInput`; an absent or non-DevEco directory gives `fileIdentityChanged`. **Index**: a macOS record, a Windows path with five roles, or a `/`-spelled or `..` root is refused on Windows. **Live** (ignored, `ARKDECK_LIVE_DEVECO_ROOT`): the installed DevEco Studio registers, with node verified as `OpenJS Foundation` and the launcher as `Huawei Technologies Co., Ltd.`; run once here, passed. |

The signed cases are gated by `ARKDECK_DEV_SIGNER_THUMBPRINT`, which was set for every run. No
"not exercised" line appears in the gate logs.

## Checks

Run from `rust/` with `CARGO_TARGET_DIR=D:/cargo-target/g2-deveco` and the development signer
set:

| Command | Result |
| --- | --- |
| `cargo fmt --all --check` | clean |
| `cargo clippy --workspace --all-targets -- -D warnings` | clean |
| `cargo test --no-fail-fast -p arkdeck-platform -p arkdeck-hoststore` | see the commit message |
| the same, with `TEMP`/`TMP` set to an 8.3 short path on C: | see the commit message |
| `PYTHONUTF8=1 sh scripts/check-sdd.sh`, `git diff --check` | pass |

macOS and Linux were not built here. The macOS paths are unchanged behind
`cfg(target_os = "macos")` / `cfg(not(windows))` (the reader, the digest, the five roles, the
`/`-root and `.app/Contents` checks, and the existing registration tests). The macOS and ubuntu
CI legs check them.

## What stays gated, and why

- **The daemon and CLI surface** (`bootstrap.register` / `runtime tool register --kind deveco`,
  `bootstrap.inspect`, `bootstrap.list`). The daemon's `BootstrapReaders` composes the HDC tool
  registry and the bundle registry together with this one, and both are macOS-only. The HDC
  tool registry waits for the Windows HDC tuple (CHG-2026-078, gate G17a), and bundles belong
  to GJ-4. So no CLI leaf becomes end-to-end here, and `WINDOWS_MEASURED_LEAVES` and the
  coverage manifest are unchanged.
- **Retirement** (`tool_retirement.rs`): it is composed with the same readers.
- **The consumers.** The workspace presets' toolchain pinning (`deveco_pins.rs`) and the hvigor
  build (`workspace_build.rs`) run node on hvigorw.js by these identities. They are part of the
  macOS-only workspace composition and need the Windows Job owner.
- **The install-shape crib (#2401).** It may change the role set or the publisher. This code
  fails closed on any other shape.
