# Rockchip bundled component distribution record

> **CHG-2026-065 retirement (2026-08-19):** the component is no longer built
> or distributed in any role — the Maskrom-rescue copy NRU-004 (2026-08-18)
> had retained is removed from the App bundle, the build, and CI. The source,
> license, SBOM and notice obligations recorded below were obligations of
> distribution and 已随分发停止而卸除; copies already shipped keep their
> embedded notices, and the pinned upstream/recipe identity remains
> reproducible from git history should a future change reintroduce it with
> its own evidence. This record is preserved as the accepted distribution
> history of the component while it shipped.

> Task：`TASK-BRC-001`
> Change：`CHG-2026-036-macos-bundled-rockchip-component@r1`
> Core baseline：`CORE-2.1.0`（零 Core delta）
> Decision class：D1 / `documentReview`
> Decision owner：protected-main CODEOWNER `@lvye`
> proposedDisposition：`accept`
> Effective condition：仅在 `@lvye` 对承载本文件的 exact PR head APPROVED 并
> merge 后生效；Agent 起草、CI 通过或 source signature 均不构成接受

## 1. Decision

ArkDeck 提议接受下述封闭 envelope，用于后继任务构建并分发一个 App-owned、
direct-child `rkdeveloptool` component：

- `rkdeveloptool` 固定在
  `rockchip-linux/rkdeveloptool@304f073752fd25c854e1bcf05d8e7f925b1f4e14`；
- component 支持格固定为 `macOS 14.0+ / arm64`，与 ArkDeck v1 现有 release/feed
  contract 一致；
- `libusb` 固定为 `1.0.30`，从 official signed source 静态链接；
- `libiconv` 选择 Apple `systemProvided`，不得 bundling GNU libiconv 或使用
  Homebrew path；
- source、license、notices、build scripts、SBOM 必须与每份 DMG 同一 GitHub
  Release 原子发布；complete corresponding source 采用 GPL-2.0 §3(a) 的
  machine-readable source 分发，不使用 written offer；
- component 不独立下载或更新；App/component/source/dependency/SBOM 是一个 release
  tuple。无法维持该 tuple 时保持 execute-disabled。

该接受只决定 source/license/dependency/distribution envelope。它不证明 binary
可构建、可复现、可签名、可 launch、可访问文件或 RockUSB，更不授权 Flash/E1/E2。
任何后继 machine gate 失败都会阻止 packaging/release，不能退回 external tool、
helper、download、copy、PATH 或 Homebrew fallback。

## 2. Decision ancestry and repository pins

- CHG-2026-035 archive merge：
  `5fc517f7ecfccd61ed0d140f9080e4b49e2cad95`
- CHG-2026-036 proposal merge：
  `16b3dbc7f7d2c565f15388bc1ca0f2aef41dd867`
- CHG-2026-036 approval merge：
  `9bbc51313af9575c3d762db0f15692da753a3e01`
- TASK-BRC-001 readiness exact head：
  `34aa3d140e6e094d811550354a29df55a74215a1`
- TASK-BRC-001 readiness merge / decision audit base：
  `e32cdaba9f465fc2e264f8b61ad135efab3487a8`
- Decision input blobs：
  - `tasks.md`：
    `824b0daea22df803fa4c84ab6849420942e376e7`
  - `proposal.md`：
    `7c9cf2815927ac1d8dfda2a5eac8788a1d10621b`
  - `design.md`：
    `c343320d00de2a22d6993325000997e7f5f7c1e1`
  - `verification.md`：
    `86f82516a2b8bd1de91dffb282499d68ebdba3cf`
  - ADR-0003：
    `cef2cbe1190e05b591c13396e7ef5daf9fb90ef4`
  - `docs/release/macos-auto-update.md`：
    `ecc8d8a02dbe37d66ca1716aeeafa1491f3a7af8`
  - `ArkDeck.xcodeproj/project.pbxproj`：
    `e7943096688728a22f4b940e536a32f3b8eaaf98`
  - `Packages/ArkDeckKit/Package.swift`：
    `292135a2c80c63ddf7182f58e2f81ff7c7d6104d`
  - `UpdateFeed.swift`：
    `9df02e20e6b4f824db2fc27318affbc9956fcbaf`

Decision/evidence PR 不修改这些 inputs。任一 pin 或语义在本 PR merge 前漂移时，本
decision 不得合入；merge 后漂移按第 11 节重新验证。

## 3. Authoritative source acquisition

### 3.1 rkdeveloptool

| Field | Accepted value |
| --- | --- |
| Upstream | `https://github.com/rockchip-linux/rkdeveloptool` |
| Commit | `304f073752fd25c854e1bcf05d8e7f925b1f4e14` |
| Tree | `9908d5bd43d32659500e6f0d0734755ee557122e` |
| Commit time | `2025-03-07T07:34:30Z` |
| GitHub commit verification | `verified` |
| Source URL | `https://codeload.github.com/rockchip-linux/rkdeveloptool/tar.gz/304f073752fd25c854e1bcf05d8e7f925b1f4e14` |
| Size | `59310` bytes |
| SHA-256 | `389ba41af6986c16f1eeebdc1febcb0bf4b8acb7abd694d3d652e78504215843` |
| Archive shape | one top-level directory；regular files/directories only |
| Source version | `1.32` from `configure.ac` `AC_INIT` |

Task 002 必须先下载到 OS temp，按 size/hash 验证后再解包。解包器必须拒绝 absolute
path、`..` traversal、duplicate normalized path、symlink、hardlink、device/FIFO、
owner/mode 特权位和第二个 top-level root；不得 clone、submodule、branch/tag resolve
或跟随 archive 内链接。网络在 input fetch/verification 后必须关闭。

### 3.2 libusb

| Field | Accepted value |
| --- | --- |
| Version | `1.0.30` |
| Release/tag commit | `87a55632db62c9bdc58cd31d3ccfa673f1bb017f` |
| Tree | `1dab476e854bb3605113e4ff3e78f9130aac5d95` |
| Commit time | `2026-05-17T14:37:21Z` |
| Source URL | `https://github.com/libusb/libusb/releases/download/v1.0.30/libusb-1.0.30.tar.bz2` |
| Size | `656112` bytes |
| SHA-256 | `fea36f34f9156400209595e300840767ab1a385ede1dc7ee893015aea9c6dbaf` |
| Signature URL | source URL plus `.asc` |
| Signature size / SHA-256 | `833` / `7e8916e689a399b98df1087cfc48eab33a6bfd8027291c5af00c3fbba90a2cec` |
| KEYS URL | `https://raw.githubusercontent.com/libusb/libusb/v1.0.30/KEYS` |
| KEYS size / SHA-256 | `7048` / `52b20b8f44c0912fdbd0c7f53c14629b9b72834118dd52ecff3fec671ba50ff3` |
| Signing primary | `C68187379B23DE9EFC46651E2C80FF56C6830A0E` |
| Signing subkey | `9C7EA94939C69C4FBC3DBFA8AA0639079EFB61B9` |
| Signature verdict | `GOODSIG` + `VALIDSIG` for Tormod Volden |
| Archive shape | one top-level directory；regular files/directories only |

`1.0.22` is rejected. Its release archive is unsigned and current NVD records
`CVE-2026-23679` and `CVE-2026-47104` as affecting libusb versions before
`1.0.30`. The decision run's NVD query timestamp is
`2026-07-25T08:37:16.053Z`; exact-commit OSV queries returned no matches for the
selected rkdeveloptool/libusb commits. Empty OSV output is not a permanent safety
claim: every release must requery the sources in section 9.

Task 002 applies the same archive extraction rules as rkdeveloptool. The detached
signature is mandatory in addition to size/hash; signature success never replaces
the exact SHA-256 check.

## 4. License inventory and accepted distribution position

### 4.1 rkdeveloptool

The accepted package-level concluded license is `GPL-2.0-or-later`, with
file-level exceptions retained:

| File group | File license / evidence |
| --- | --- |
| `main.cpp`, `RKComm.cpp`, `boot_merger.h`, `RKLog.cpp`, `RKDevice.cpp`, `RKImage.cpp`, `RKBoot.cpp`, `RKScan.cpp`, `crc.cpp` | literal `SPDX-License-Identifier: GPL-2.0+` |
| `Property.hpp` | `LicenseRef-Rockchip-Property-permissive`; exact header permits change/modify/redistribute only if the header is kept |
| `.gitignore`, `99-rk-rockusb.rules`, `CMakeLists.txt`, `DefineHeader.h`, `Endian.h`, `Makefile.am`, `RKBoot.h`, `RKComm.h`, `RKDevice.h`, `RKImage.h`, `RKLog.h`, `RKScan.h`, `Readme.txt`, `autogen.sh`, `cfg/.gitignore`, `cfg/Makefile.am`, `config.h.in`, `config.ini`, `configure.ac`, `gpt.h`, `parameter_gpt.txt` | package-level GPL context; preserve all existing copyright/header text and do not invent per-file copyright |
| `license.txt` | verbatim GPL version 2 text; Git blob `25e216a7063f10f19bf5b77b3a351f5bbd62e268` |

The App and component remain technically separate works: rkdeveloptool is a distinct
child executable; no rkdeveloptool/libusb code is copied into ArkDeck-owned modules;
the parent invokes only the closed typed argv/process seam. This record does not
silently relicense ArkDeck-owned code. Acceptance of this distribution position is
the maintainer's exact-head review/merge of this D1 record.

### 4.2 libusb

- Package license：`LGPL-2.1-or-later`，as stated by upstream README；
- archive `COPYING` SHA-256：
  `5df07007198989c622f5d41de8d703e7bef3d0e79d62e24332ee739a452af62a`；
- libusb is linked statically only into the separately licensed GPL
  `rkdeveloptool` child；
- the corresponding-source bundle includes complete libusb source, complete
  rkdeveloptool source and the exact build/relink scripts. No ArkDeck-owned object
  file is linked with libusb. This is the accepted LGPL relink/source mechanism；
- no libusb dylib, Homebrew bottle, header or cache may be copied from the host.

### 4.3 libiconv

`libiconvChoice: systemProvided`.

- Accepted provider：Apple macOS SDK/runtime `/usr/lib/libiconv.2.dylib`；
- audit SDK：macOS SDK 26.5 (`25F70`)；
- SDK `usr/include/iconv.h` SHA-256：
  `3fcec709f204ac60c7941488b9e49d8536150d356beff1f8cf8926cdfef7456d`
  and `SPDX-License-Identifier: BSD-2-Clause`；
- SDK `usr/lib/libiconv.2.tbd` SHA-256：
  `b257056db07bac43cd4d2f6fd806605ad3462fa0bb99918dc43c64176a018cea`，
  install name `/usr/lib/libiconv.2.dylib`，current/compatibility version `7`，
  reexport `/usr/lib/libcharset.1.dylib`；
- exact rkdeveloptool source has zero iconv API/include references; the upstream
  CMake link is nevertheless replaced with explicit SDK `-liconv` so the ADR's
  `systemProvided` disposition is unambiguous and no GNU/Homebrew bytes enter the
  tuple；
- Task 002 must target `arm64-apple-macos14.0`, then prove the exact load command
  and absence of a bundled iconv payload. Link failure or an unexpected provider
  blocks; it does not permit GNU libiconv fallback.

GNU libiconv 1.19 is rejected for this envelope. Its source/signature facts remain
review inputs, but bundling it would add an unnecessary LGPL/GPL payload and requires
a fresh D1 decision.

### 4.4 Required notices

Every release tuple must carry a UTF-8 `THIRD-PARTY-NOTICES.txt` inside the App's
Resources, in the DMG documentation surface and in the source bundle. It must include:

1. exact rkdeveloptool upstream/commit/source URL；
2. all existing Rockchip/source copyright headers；
3. full GPL v2 text plus the literal `GPL-2.0+` file declarations；
4. the complete `Property.hpp` custom header；
5. exact libusb version/source/signature fingerprints, upstream AUTHORS and full
   LGPL 2.1 text；
6. the system-provided libiconv decision, making clear that ArkDeck redistributes no
   Apple/GNU libiconv binary；
7. the corresponding-source URL, SHA-256, availability window and modification
   statement；
8. an explicit no-warranty statement carried from the licenses.

Task 002 must machine-generate the notice from pinned inputs and compare it byte for
byte on two clean builders. Hand-edited release notices are forbidden.

## 5. Modifications and build scripts

`upstreamSourceModifications: none`.

- rkdeveloptool's eight compiled `.cpp` files are fixed to:
  `main.cpp`, `crc.cpp`, `RKBoot.cpp`, `RKComm.cpp`, `RKDevice.cpp`,
  `RKImage.cpp`, `RKLog.cpp`, `RKScan.cpp`；
- the repo-owned recipe generates `config.h` from pinned metadata with
  `PACKAGE_VERSION "1.32"` and invokes the compiler directly. Generating this build
  file and replacing the upstream hard-coded Homebrew CMake invocation are build
  plumbing, not edits to upstream source；
- libusb uses its signed release archive's pre-generated `configure`, with static
  library output only；
- every repo-owned build/source-package script is complete corresponding source and
  must be included verbatim in the source bundle with its Git blob and SHA-256；
- any patch to a rkdeveloptool/libusb source file, version-string change, source-file
  set change or new dependency requires returning TASK-BRC-001 to `blocked` and a
  fresh D1 decision. Task 002 cannot approve a patch opportunistically.

## 6. Exact successor build envelope

```yaml
component:
  name: rkdeveloptool
  versionOutput: "rkdeveloptool ver 1.32"
  architectures: [arm64]
  minimumMacOS: 14.0.0
  upstreamSourceModifications: none
libusb:
  version: 1.0.30
  linkMode: static
  configure: "--disable-shared --enable-static"
libiconv:
  disposition: systemProvided
  sdkInstallName: /usr/lib/libiconv.2.dylib
  linkMode: dynamic-system
builder:
  os: "macOS 26.5.2 (25F84) arm64"
  xcode: "26.6 (17F113)"
  sdk: "macOS 26.5 (25F70)"
  clang: "Apple clang 21.0.0 (clang-2100.1.1.101)"
  make: "GNU Make 3.81"
  shell: "Apple /bin/bash 3.2.57(1)"
  sourceDateEpoch: 1779028641
environment:
  LC_ALL: C
  LANG: C
  TZ: UTC
  ZERO_AR_DATE: "1"
  umask: "022"
  networkAfterFetch: denied
  homebrewPaths: denied
  callerPATH: ignored
  callerEnvironment: ignored
reproducibility:
  cleanBuilders: 2
  verdict: byte-identical unsigned Mach-O and byte-identical manifests
  normalization: forbidden
```

The Task 002 recipe must use absolute tools resolved from the pinned Xcode/OS image,
an empty repo-owned build root, explicit `-arch arm64`,
`-mmacosx-version-min=14.0`, no debug information, no absolute build paths, fixed
locale/time/umask and a closed environment. It must not invoke upstream CMake,
Homebrew, pkg-config, PATH search, shell-composed external commands or unpinned
download.

The direct final Mach-O dependency allowlist is:

- `/usr/lib/libSystem.B.dylib`
- `/usr/lib/libc++.1.dylib`
- `/usr/lib/libobjc.A.dylib`
- `/usr/lib/libiconv.2.dylib`
- `/System/Library/Frameworks/IOKit.framework/Versions/A/IOKit`
- `/System/Library/Frameworks/CoreFoundation.framework/Versions/A/CoreFoundation`
- `/System/Library/Frameworks/Security.framework/Versions/A/Security`

`/usr/lib/libcharset.1.dylib` is the accepted system reexport of libiconv. Bundled
non-system dylib count must be zero; libusb symbols must resolve from the statically
linked `1.0.30` archive. Any extra load command, `@rpath`, absolute build path,
Homebrew path, unsigned source input or missing allowlisted dependency is a binary
FAIL. The Task 002 registry must pin the exact compiler/link command, source list,
generated `config.h`, output SHA-256, `otool -L`, Mach-O load commands, exported/
undefined symbols and SBOM relationships.

## 7. Corresponding source and public release layout

Distribution mode：GPL-2.0 §3(a), complete corresponding machine-readable source
published in the same GitHub Release before the DMG/feed becomes visible. No
written-offer mode is used.

For App version `<appVersion>`, where the value must exactly equal the signed update
feed payload version:

- binary：
  `https://github.com/ArkDeck/ArkDeck/releases/download/v<appVersion>/ArkDeck-<appVersion>.dmg`
- source：
  `https://github.com/ArkDeck/ArkDeck/releases/download/v<appVersion>/ArkDeck-rockchip-component-source-<appVersion>.tar.gz`
- SBOM：
  `https://github.com/ArkDeck/ArkDeck/releases/download/v<appVersion>/ArkDeck-rockchip-component-sbom-<appVersion>.spdx.json`
- notices：
  `https://github.com/ArkDeck/ArkDeck/releases/download/v<appVersion>/ArkDeck-rockchip-component-notices-<appVersion>.txt`

The source archive must contain:

```text
MANIFEST.sha256
sources/rkdeveloptool-304f073752fd25c854e1bcf05d8e7f925b1f4e14.tar.gz
sources/libusb-1.0.30.tar.bz2
sources/libusb-1.0.30.tar.bz2.asc
sources/libusb-v1.0.30-KEYS
build/                         # exact reviewed Task 002 recipe
licenses/GPL-2.0.txt
licenses/LGPL-2.1.txt
licenses/Property.hpp.notice.txt
THIRD-PARTY-NOTICES.txt
ArkDeck-rockchip-component-sbom-<appVersion>.spdx.json
```

`MANIFEST.sha256` covers every other regular file in sorted UTF-8 path order. The
release procedure must upload source/SBOM/notices first, fetch them back, verify
size/hash/content, and only then upload DMG and finally the signed update feed.
Missing/unavailable/mismatched source, SBOM or notice blocks the release exactly like
a DMG signature failure.

Availability/retention window：
`max(binary public availability, five years after release issuedAt)`. The release
owner must retain the exact public assets and two clean-builder receipts for that
entire window. Removing a binary does not permit early removal of its source. The
owner must restore an unavailable source asset before any further release.

## 8. SBOM contract

`sbomFormat: SPDX-2.3 JSON`.

Task 002 must generate a deterministic SPDX 2.3 JSON document that includes:

- rkdeveloptool package + every source file and file-level concluded license；
- libusb 1.0.30 package + source/signature/KEYS external references；
- `LicenseRef-Rockchip-Property-permissive` with complete extracted text；
- exact source/archive/Git/tree/recipe/output SHA-256 and supplier/origin；
- `GENERATED_FROM`, `BUILD_TOOL_OF`, `STATIC_LINK`, `DEPENDS_ON` and
  `DESCRIBES` relationships needed to reproduce the component；
- Apple system dependencies as `scope: provided`, never as redistributed files；
- compiler, SDK, minimum OS, architecture and unsigned artifact identity；
- no user path, device identifier, credential, signing identity secret or build
  cache path.

The schema, canonical key ordering, namespace construction and timestamp
normalization must be fixed in Task 002's versioned registry. Invalid SPDX, missing
file inventory, missing license text or graph disagreement with `otool`/symbol
inspection is a FAIL.

## 9. Vulnerability response

| Field | Accepted value |
| --- | --- |
| vulnerabilityOwner | `@lvye` |
| releaseOwner | `@lvye` |
| updateOwner | `@lvye` |
| rollbackOwner | `@lvye` |
| retentionOwner | `@lvye` |
| Sources | upstream GitHub commits/releases/security advisories, OSV exact-commit query, NVD CVE 2.0 API, CISA KEV |
| Pre-release freshness | every query completed within 24 hours before release candidate approval |
| Critical/high SLA | triage within 24 hours；block release immediately；fixed/disable decision within 72 hours |
| Medium/low SLA | triage within 7 calendar days；record next-release or accepted-risk decision in a reviewed PR |

An advisory, upstream force replacement, signature-key change, withdrawn release,
OSV/NVD match, unsupported upstream status or source hash mismatch invalidates the
candidate tuple. Existing installed copies enter an actionable vulnerable-component
state; no automatic component download occurs. Recovery is a higher App version with
a complete new tuple, or execute-disabled.

## 10. Update and rollback

- The component has no independent updater, URL, mutable data directory or PATH
  fallback. It changes only when the containing signed/notarized App changes.
- The signed feed continues the existing `check + download + verify + Finder
  handoff`; ArkDeck does not mount the DMG, replace itself, install on exit or claim
  automatic rollback.
- Update verifies one tuple:
  App version/sequence + DMG hash/signature/notary + component registry/hash/version +
  source archive + SBOM + notices. A mixed tuple is never reachable.
- Primary rollback is a strictly higher patch version/sequence that restores a known
  good complete tuple or removes bundled production reachability. If no such tuple is
  ready, execute remains disabled.
- A retained older notarized DMG may be offered only as an explicit manual support
  action with its exact retained source/SBOM/notices and compatibility receipt; it is
  not an update-feed downgrade and cannot convert an unknown Job outcome to success.
- Rollback never selects the external executable, replays an unknown effect, changes
  entitlement/system rules or silently installs a helper/driver.

## 11. Revalidation triggers

A fresh TASK-BRC-001 D1 decision is mandatory before any of:

- rkdeveloptool commit/tree/archive/version/source-file set changes；
- libusb version/source/signing key/link mode changes；
- GNU/bundled libiconv, removal of the explicit system disposition, or a different
  system install-name；
- any upstream source patch or generated version change；
- architecture, minimum macOS, builder OS/Xcode/SDK/compiler or deterministic build
  contract changes；
- new non-system dependency, extra Mach-O load command or bundled dylib；
- GPL/LGPL/property notice interpretation, corresponding-source mode/location/
  availability or release retention changes；
- SBOM schema/ownership/SLA/update/rollback policy changes；
- App/component separation, direct-child topology, distribution channel or
  entitlement architecture changes；
- any source/signature/CVE fact that makes the current acceptance uncertain.

Task 002 may not treat one of these as a local implementation detail. It must fail
closed, leave ArkDeck execute-disabled and return to a reviewed decision.

## 12. Successor handoff

After this record is merged and TASK-BRC-001 receives a separate D0 `done` merge,
only `TASK-BRC-002` may seek fresh D1 readiness. Its readiness must pin this decision
merge, both source archives/signatures, exact toolchain/build envelope, source-package
layout, SPDX contract, dependency graph and two-clean-builder procedure.

This record does not create `vendor/`, build scripts, registry, SBOM, source package,
binary, signature, App bundle changes or hardware evidence. CHG-2026-026 and real
one-click Flash remain unchanged and blocked behind their own later gates.
