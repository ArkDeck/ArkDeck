# TASK-XPA-011 — Windows DevEco / hvigor / hap-sign-tool / node install-shape crib (maintainer-run), 2026-09-30

WM3 platform fact of the Windows phase (`docs/design/cross-platform/windows-phase-agent-prompt.md`,
WM3: "DevEco、hvigor、hap-sign-tool、node 在 Windows 上的安装形态，先用一份 crib 让维护者确认"). The agent wrote this crib and the read-only capture script
`rust/scripts/windows-deveco-sample.ps1`. **The maintainer runs it** on each Windows DevEco
installation to be supported, and hands back the output root. The agent never opens signing
material, never runs hvigor, a build or hap-sign-tool, and only processes the returned file.

This crib is not Windows acceptance, not a toolchain registration and not signing evidence. It
confirms, or corrects, the install shape that the Windows registration of node and hvigor as
registered toolchain references (TASK-XPA-011) and the signing leaves (#2369, #2372) are built
against.

## What is sampled and why

On macOS a DevEco Studio installation is registered as one content-addressed toolchain
(`toolchain:sha256:<digest>`, `arkdeck.deveco-toolchain-content/2`). The registration is
`<X>.app/Contents` with five sealed child roles:

- `productManifest`, `sdkManifest`: the two manifests;
- `node`: `tools/node/bin/node`, which must be natively signed and `verified`;
- `hvigor`: `tools/hvigor/bin/hvigorw.js`;
- `signedResourceEnvelope`.

The bundle's publisher signature and resource envelope bind them together. The product never
takes node, hvigor, java or hap-sign-tool from PATH. A workspace build runs node on hvigorw.js by
the registered identities, and signing runs the preset's registered Java and JAR.

On Windows the reader (D2, #2362) already opens four roles: `product-info.json`,
`sdk\default\sdk-pkg.json`, `tools\node\node.exe` and `tools\hvigor\bin\hvigorw.js`. There is no
resource envelope and no property list. Before the registration's trust and content rules are
fixed for Windows, the maintainer confirms on real installations:

| Question | Why it matters | Where the script answers |
| --- | --- | --- |
| Where DevEco Studio installs, and who may write it | The reader refuses a root any principal but the user, SYSTEM, Administrators or TrustedInstaller may write (ruling 24) | `root`, `files[].access`, `files[].directoryAccess` |
| The exact relative paths of node, hvigor, the JDK, hap-sign-tool and the SDK manifests | The role paths are compiled in; a different shape must fail closed, not be searched | `files[].present`, `tools` |
| node.exe's Authenticode signer, and whether the launcher is signed | The Windows counterpart of the macOS "node must be `verified`" and "bundle publisher signature" (G12). A registration pins the signer, not a path | `files[].authenticode`, `signerSubject`, `signerSha256`, `timestamped` |
| Mark-of-the-Web on the installed files | A downloaded SDK component may carry MotW; the registration must not depend on it | `files[].markOfTheWeb` |
| The versions: SDK components, hvigor, node, JDK | They name what a registration covers, and they go into the XPA-011 run record | `sdkComponents`, `hvigorPackages`, `versionProbes` |
| What PATH would resolve | This shows that a user's `node` or `hdc` can differ from DevEco's. The product ignores PATH; this is evidence for that rule | `path` |
| The signing material's layout under `%USERPROFILE%\.ohos\config` (names and sizes only) | The DevEco password decoder (`deveco_password::material_layout`) is refused on Windows until this shape is confirmed | `signingConfig.entries` |
| How a project's `build-profile.json5` spells `storeFile` (separators, escaping) and whether the passwords are DevEco ciphertext (length, hex only) | `install --build-profile` and `migrate-deveco` are `unsupportedOnPlatform` on Windows until this spelling is known | `buildProfile` |

## Expected shape (from the reference host's installation; the sample confirms or corrects it)

Recorded read-only by D2 and by a script self-test on the reference host (DevEco Studio's SDK
toolchains 26.0.0.43, API 26, Beta). Only shapes are given here: no hash of a DevEco file, and no
path with an account name.

| Relative path (under `C:\Program Files\Huawei\DevEco Studio`) | Present | Authenticode | Notes |
| --- | --- | --- | --- |
| `bin\devecostudio64.exe` | yes | Valid, `O="Huawei Technologies Co., Ltd."` | the launcher; the D2 reader requires it |
| `product-info.json` | yes | not a PE (`UnknownError`) | launch entry `{"os":"Windows","arch":"amd64","launcherPath":"bin/devecostudio64.exe"}` |
| `sdk\default\sdk-pkg.json` | yes | not a PE | SDK manifest, the macOS key set |
| `tools\node\node.exe` | yes | Valid, `O=OpenJS Foundation` | node v24.14.1; beside it `npm.cmd`, `npx.cmd`, `corepack.cmd`, `node_modules\` |
| `tools\hvigor\bin\hvigorw.js` | yes | not a PE (script) | hvigor packages `tools\hvigor\hvigor` and `tools\hvigor\hvigor-ohos-plugin`, `@ohos/hvigor` 5.14.2-td-rc.2908 |
| `jbr\bin\java.exe` | yes | Valid, `O=JetBrains s.r.o.` | OpenJDK 25.0.2 (JBR) |
| `sdk\default\openharmony\toolchains\lib\hap-sign-tool.jar` | yes | not a PE | **carries Mark-of-the-Web (ZoneId=3)** |
| `sdk\default\openharmony\toolchains\hdc.exe` | yes | NotSigned | **MotW ZoneId=3**; see the HDC crib |
| `tools\ohpm\bin\ohpm.bat` | yes | not a PE | not a role |

Every entry is owned by `Administrators`, with no untrusted write, and the user has no write. On
the reference host PATH resolves `node` to a separate Node.js installation outside DevEco, and
`hdc` to a hand-placed copy. Both are ignored by the product.

## Preconditions (maintainer)

1. A Windows 11 x64 host with DevEco Studio installed, and PowerShell 7 (`pwsh`) in a normal,
   non-elevated terminal. No admin rights are needed.
2. A checkout that contains this commit.
3. DevEco Studio may stay open; the script only reads. To sample the signing material and a
   build profile, have one project whose signing config DevEco generated ("Automatically
   generate signature" or a configured release key).
4. An output root outside every git work tree. The script refuses an existing root, and a root
   inside a work tree.

## Steps

1. Go to the checkout and choose the output root:

   ```powershell
   cd D:\src\ArkDeck
   $root = Join-Path $env:LOCALAPPDATA 'ArkDeck-samples\deveco-shape-20260930'
   ```

2. Installation shape, versions and PATH (read-only; the two version probes run `node.exe
   --version` and `java.exe -version` from the DevEco root only):

   ```powershell
   pwsh -NoProfile -File .\rust\scripts\windows-deveco-sample.ps1 `
     -DevEcoRoot 'C:\Program Files\Huawei\DevEco Studio' -OutputDirectory $root -RunVersionProbes
   ```

3. Optional, with the signing material's shape and one build profile. The script lists names
   and sizes under `%USERPROFILE%\.ohos\config` without opening any file. From the build profile
   it records only how `storeFile` is spelled, and the passwords' lengths and hex-ness:

   ```powershell
   pwsh -NoProfile -File .\rust\scripts\windows-deveco-sample.ps1 `
     -DevEcoRoot 'C:\Program Files\Huawei\DevEco Studio' -OutputDirectory "$root-signing" `
     -BuildProfile '<project>\build-profile.json5'
   ```

   Skip step 3 if you prefer not to have signing material listed at all. The signing leaves stay
   `unsupportedOnPlatform` for DevEco ciphertext until it is sampled.

4. Repeat steps 2–3 for every other DevEco Studio version or install location to be supported
   (for example a per-user install under `%LOCALAPPDATA%\Programs`), each with a new root.

### Hand back

5. Tell the agent the root(s), and anything unusual: a refusal, a missing file, a prompt. The
   `sample.json` replaces the profile directory, the DevEco root, the account and the host names
   with placeholders. Still, **do not paste it into a chat, issue or commit**: project names can
   appear as lengths only, but file sizes and hashes of the signing config directory are still
   host-specific.

## What the agent does with the file

Only file processing; nothing is run.

1. **Redact** before anything enters the repository:
   - keep role paths, versions, signer subjects and Authenticode states;
   - drop the SHA-256 of the signing-material entries, and the sizes of `.p12` / `.jks` / `.cer`
     / `.p7b` files;
   - keep the fixed material layout (`material\fd\<n>\…`, `ac`, `ce`) with its file counts and
     sizes. The sizes are the fixed 16-byte parts, which the decoder checks, never content.
2. **Compare** with the expected shape above and with the macOS registration:
   - role paths;
   - node's signer: stable across versions? This decides whether a Windows registration pins the
     signer's subject (`O=OpenJS Foundation`) or a leaf;
   - the launcher's signer;
   - MotW on the SDK's JAR and `hdc.exe`: the registration must measure the file and not trust
     the zone;
   - write access;
   - the `storeFile` spelling: `\\`-escaped absolute path, forward slashes, or relative;
   - the `material` layout beside the keystore.
3. **Record** a sanitized run record next to this crib (`deveco-windows-install-shape-<date>-run.md`),
   and state every difference from the expected shape as found.

## What this sample feeds

- The Windows DevEco registration (TASK-XPA-011): which roles a Windows toolchain record carries,
  node's trust (Authenticode signer) in place of the macOS native signature, and no resource
  envelope. The content schema's Windows form is a delegated minor decision recorded in that
  slice's run record, pending the next rulings batch.
- The DevEco password material adapter on Windows (`material_layout`), and the
  `install --build-profile` / `migrate-deveco` leaves. Both stay refused until the sample confirms
  the layout.
- The clean-host runbook's DevEco steps, if any, for GJ-5 in phase A.
