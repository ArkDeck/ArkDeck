# TASK-XPA-009 — WM2: the native code-sign helper on Windows

Change: CHG-2026-074-shared-rust-runtime-core. Milestone WM2, GJ-3. This is the first slice of
XPA-009 on Windows: the bundled OpenHarmony code-sign helper that
`deploy.native-library.app-owned@1` sends to the device. The HAP signing domain (XPA-011) is not
touched.

Host: the Windows 11 x64 reference host, non-elevated, NTFS. The limits of this run:

- No device was contacted, no HDC or board was used, and no `hdc` was run.
- Nothing installed was read or written, and no system setting was changed.
- Host tests are not Windows acceptance.

## What the helper is

`arkdeck-code-sign-enable`
(`Packages/ArkDeckKit/Resources/OpenHarmonyNativeCodeSign/`, source
`Packages/ArkDeckKit/Tools/OpenHarmonyNativeCodeSignHelper/main.c`) is a static arm64 ELF.
The native deployment sends it to the device and runs it there to enable the library's existing
code signature (`FS_IOC_ENABLE_CODE_SIGN`). It never runs on the host. The daemon only finds it,
verifies it as Swift's `HDCNativeCodeSignHelperArtifact.bundled()` does (an arm64 ELF the
library validator accepts, carrying no mutable input signature, a static executable), and pins
its Build-ID, SHA-256 and byte count into every deployment action.

## What

- **`arkdeck-agentd`.**
  - `code_sign_helper.rs` builds on Windows. The bundle's resource is joined one component at a
    time, so the three candidate layouts are spelled with the OS's own separator. The candidates
    are unchanged on macOS: the macOS test still spells them byte for byte, and a Windows test
    spells `C:\ArkDeck\…`.
  - The daemon composes the bundled helper on Windows, before the owners, so the census the
    composition reports names it.
  - The census adds `codeSignHelper` in its macOS position, after `usbRegistryRelations`, in
    `Host::owner_census`.
  - A helper that does not verify is reported (`native deployment stays unavailable: …`), and the
    daemon serves without it, as on macOS.
  - The development override (`ARKDECK_DEVELOPMENT_CODE_SIGN_HELPER`) stays refused on Windows.
    On macOS only a development HDC's admission names one, and no Windows HDC tuple is
    registered (CHG-2026-078 is a draft). The account's daemon refuses it at startup, as the
    macOS standalone and production daemons do.
- **Packages.**
  - `rust/scripts/windows-package-xcopy.ps1` stages the checked-in resource at the recorded
    revision beside `arkdeck-agentd.exe`, at
    `ArkDeckKit_ArkDeckWorkflows.bundle/OpenHarmonyNativeCodeSign/arkdeck-code-sign-enable`. It
    is never Authenticode-signed (it is an ELF, data on the host), and the manifest's `files`
    pins its bytes.
  - `windows/scripts/package-rc.ps1` copies the bundle beside the daemon in the xcopy form.
    `windows/App/ArkDeck.App.csproj` puts it at the MSIX root, and the RC script requires the
    MSIX entry and that it is the runtime package's bytes.
- **Behind the gate.** With no HDC composition, `operation.list` still answers
  `deploy.native-library.app-owned@1` `provider_not_registered`. The helper is ready for the
  tuple, and nothing is dispatched.

## Rebuilding the helper on Windows

The Windows DevEco SDK (OpenHarmony native 26.0.0.43, `OHOS (dev) clang version 15.0.4`)
builds the helper from `main.c` with the README's flags. The SDK's
`aarch64-unknown-linux-ohos-clang` is a POSIX shell wrapper, so its three arguments are passed
to `clang.exe` directly:

```
<sdk>\native\llvm\bin\clang.exe -target aarch64-linux-ohos --sysroot=<sdk>\native\sysroot -D__MUSL__ ^
  -O2 -g0 -static -Wl,--build-id=sha1,--strip-all ^
  -o arkdeck-code-sign-enable Tools\OpenHarmonyNativeCodeSignHelper\main.c
```

| Build | Bytes | SHA-256 |
| --- | --- | --- |
| Checked-in resource (device-proved, GJ-3) | 214,016 | `86497e1a8f9b586169218df912895785c1c0f2d8bb3f87b2b700f6f86264f5c1` |
| This host, SDK 26.0.0.43 | 214,088 | `c481f3be8c995522aac9dbad300af25c514e342630d0fe45d8c77278102cd440` |

The Windows build verifies. A copy of the daemon with it beside it composes it (the census names
`codeSignHelper`), so the validator accepts it as a static arm64 ELF with a Build-ID. It is not
byte-identical: the SDK differs from the one the resource was built with. Every deployment
action pins the helper's SHA-256 and Build-ID, and only the checked-in resource has been run on a
device. So the packages ship the checked-in bytes, and the Windows rebuild is reproducibility
evidence only. Delegated minor decision, pending the next rulings batch: the checked-in resource
stays the one pinned helper, and a Windows-built one is not substituted.

## Local targeted checks

The environment set `CARGO_TARGET_DIR=D:/cargo-target/m1-gj23` and
`ARKDECK_DEV_SIGNER_THUMBPRINT` (the host-trusted development signer). All checks ran on `origin/main`
`86d2f2b8` with this change.

| Command | Exit |
| --- | --- |
| `cargo fmt --all --check` | 0 |
| `cargo clippy --workspace --all-targets -- -D warnings` | 0 |
| `cargo test -p arkdeck-agentd -p arkdeck-cli -- --nocapture` | 0 |
| The same tests with `TEMP`/`TMP` set to an 8.3 short path on C: (`…\Temp\M1STAC~1`) | 0 |
| `sh scripts/check-sdd.sh` | 0 |
| `git diff --check` | 0 |
| `rust/scripts/windows-package-xcopy.ps1 -SigningMode development -AllowDirty -Smoke` | 0 |

The last row is the xcopy smoke. The package's `files` pins
`ArkDeckKit_ArkDeckWorkflows.bundle/OpenHarmonyNativeCodeSign/arkdeck-code-sign-enable` at 214,016
bytes and SHA-256 `86497e1a…64f5c1`. The smoke passed: the client started the daemon, and
`doctor` and `runtime service verify` both passed.

- **`windows_code_sign_helper_process.rs`.** 3 tests, all passed:
  - the bundled helper is composed, and the census ends `…, traceCache, codeSignHelper`;
  - a non-ELF and a truncated helper are both reported, and the daemon serves without them;
  - a named helper is refused over a development root and over a private endpoint.
- **Signed CLI tests.** Every dev-signed CLI process test ran and passed, with no SKIPPED line.
- **Account locations.** The four account-location tests (`windows_account_locations_*`) printed
  SKIPPED in both runs. An account daemon the user started from an installed package serves this
  account's pipe on this host, and those tests refuse to take its guard. They are outside this
  change, and the daemon was not stopped.
- **RC package.** `windows/scripts/package-rc.ps1 -SigningMode none` could not be run to the end
  on `86d2f2b8`: the trimmed publish of the App fails at `windows/App/Controls/FocusWalk.cs(58)`
  (IL2026, `JsonSerializer.Serialize` without a type info), which is unrelated and was reported to
  the lead. The project change was evaluated instead:
  `dotnet msbuild windows/App/ArkDeck.App.csproj -getItem:Content -p:ArkDeckRuntimeDirectory=<the
  xcopy stage>` resolves the helper to the bundle-relative link, with `PreserveNewest` publishing,
  beside the daemon and the CLI.
- **Not verifiable here.** macOS and Linux cannot be built on this host. On macOS the candidate
  spelling is unchanged (joining the same components yields the same path) and the macOS test
  spells it byte for byte, and Linux does not build `code_sign_helper`. CI's macOS and Ubuntu lanes
  are the check.

## CI

This is recorded by the next slice.
