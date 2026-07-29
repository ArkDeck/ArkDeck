# TASK-BRC-003 fresh D1 readiness — 2026-07-29

- Evidence class: `platform`（readiness/preflight；不是 package/notary acceptance）
- Core baseline: `CORE-2.1.0`
- Scope: `BRC-PACKAGE-001` readiness only；canonical AC 均未在本记录判定通过
- Base: `333eec928cbbd7f273abffeebb3970f15ed33554`
- Producer → consumer: accepted BRC-002/BRC-002R repository + GitHub artifact
  handoff + maintainer-configured local release environment → TASK-BRC-003
  implementation gate；尚未生成 signed App/DMG 或 notary ticket
- Evidence currency: `current`
- Opaque release environment ref:
  `maintainer-local-release-env-2026-07-29`

## Purpose and authority boundary

本记录补齐 r1 blocked-readiness 明列的三个 D2 前提：Developer ID identity、
notary authentication 与 exact unsigned artifact handoff。credential/permission
configuration 由维护者亲手在隔离 release environment 完成；Agent 只在用户确认后
执行只读、sanitized preflight 与临时 artifact inspection。

本 readiness PR 只提议 `blocked → ready`。只有维护者 review/merge exact head 后
才生效；本记录不批准或执行 package/sign/notary/staple/install/upload，不证明
`BRC-PACKAGE-001`，也不形成 macOS distribution/support claim。

## Protected-main and dependency audit

GitHub API 返回的 protected `main` OID 与本地 `origin/main`、branch base 一致：
`333eec928cbbd7f273abffeebb3970f15ed33554`。以下 OID 均通过
`git merge-base --is-ancestor <oid> <base>`：

| Carrier | OID | Result |
| --- | --- | --- |
| TASK-BRC-002 implementation/evidence | `182757cdc9ca191f2ce0a2d61dfce78440c74cd9` | PASS |
| TASK-BRC-002 done | `e9848ba274123bea46b98e39cbf989bd93dfc225` | PASS |
| TASK-BRC-002R readiness | `90085a9fc1341e13a5b59ba1afb676b10907d976` | PASS |
| TASK-BRC-002R implementation | `9ff769d79df261f72c2b4dbcef5e48d68d8e520e` | PASS |
| TASK-BRC-002R evidence | `01e6f9a6605f4a3a9463dcab2bf5731bd012ef48` | PASS |
| TASK-BRC-002R done | `5a40e8968586232468a8691039d674c9e83d7526` | PASS |

readiness capture 时 `gh pr list --state open` 返回空集合。未发现与本 carrier 或
后继 implementation surface 重叠的 open PR。

## Repository pins

r1 readiness YAML 中的 11 个产品/集成/发布输入逐项重算，全部保持原 blob；r2
另把 current component workflow 作为第 12 行新 pin：

| Path | Blob |
| --- | --- |
| `openspec/integrations/rockchip/bundled-component/1.0.0/registry.yaml` | `505122327e877900d7fdb2b908cf6914f207b70f` |
| `openspec/integrations/rockchip/bundled-component/1.0.0/recipe.json` | `fa4289b73880540b0db19d24242d039053ae8916` |
| `openspec/integrations/rockchip/bundled-component/1.0.0/sbom.spdx.json` | `e66e3d7f22a4d2079e59edcc51c2682650362689` |
| `openspec/integrations/rockchip/bundled-component/1.0.0/THIRD-PARTY-NOTICES.txt` | `6d1f7bf4624972fdb8559d203fd89163c3003c43` |
| `openspec/integrations/rockchip/bundled-component/1.0.0/source-distribution-manifest.json` | `bbce240466dedfc7de3ebb19d1db5fe8b0f3a865` |
| `openspec/changes/chg-2026-036-macos-bundled-rockchip-component/evidence/runs/TASK-BRC-002/run.md` | `94108fb6f1f0a4d86b027e03ef9885c7360f9c56` |
| `ArkDeck.xcodeproj/project.pbxproj` | `e7943096688728a22f4b940e536a32f3b8eaaf98` |
| `ArkDeck.xcodeproj/xcshareddata/xcschemes/ArkDeck.xcscheme` | `29d0fb995dd3a28ad535569a4cdc4c3964311def` |
| `ArkDeckApp/ArkDeckApp.entitlements` | `6435d00f8493ce4fbca24a806ca7f320db9fbfa6` |
| `docs/release/rockchip-component-distribution.md` | `60dd039582b216d0b2fb21336fe4ee0abc9b0f7c` |
| `docs/release/macos-auto-update.md` | `ecc8d8a02dbe37d66ca1716aeeafa1491f3a7af8` |
| `.github/workflows/rockchip-component.yml` | `6242d0b4f3a1b8b15020803073b017c6a6911a61` |

current `tasks.md` base blob =
`de23d56688e713d90a2b12706e8d44651cffa164`。任一 implementation base 或 pin
不等，readiness 失效并返回 fresh D1。

## Exact unsigned artifact handoff

GitHub API/authenticated download 复核：

| Field | Value |
| --- | --- |
| workflow run | `30233237693` |
| event / conclusion | `workflow_dispatch` / `success` |
| run head | `01e6f9a6605f4a3a9463dcab2bf5731bd012ef48` |
| artifact | `rockchip-builder-a` / ID `8640763234` |
| archive size | `125046` bytes |
| archive digest | `sha256:3dc014b6e81a68942d9415a1bdb73faabbbb2472297d1ae14d7648a547628e67` |
| created / expires | `2026-07-27T02:53:56Z` / `2026-08-26T02:53:55Z` |
| API expiry verdict | `expired=false` |

artifact 被下载到 `mktemp -d` 创建的 fresh `/private/tmp` root；绝对路径不记录。
检查后该 root 已删除。独立结果：

| Check | Result |
| --- | --- |
| component SHA-256 | `3caee2136551b4b849daf7e9a906813354f354f8adb61e5f092de49ec7a2e56a` |
| component size/type | `247488` bytes；regular Mach-O 64-bit executable |
| architecture | `arm64` only |
| `LC_BUILD_VERSION` | platform macOS；minimum `14.0` |
| signature | `code object is not signed at all`（expected unsigned input） |
| dependencies | system `/usr/lib` 与 `/System/Library` only；non-system count 0 |
| generated registry/SBOM/notices/source manifest | each byte-equal to committed copy |

archive digest 是 GitHub artifact container digest；component SHA-256 是 extracted
Mach-O identity，二者不混用。implementation 只接受上述 exact artifact。artifact
过期/不可下载、API digest 不等、extracted file 非 regular/出现 symlink，或任一
binary/metadata field 不等时，archive/sign/notary dispatch 必须为 0，并回到 fresh
D1。不得 rebuild-on-package、改用另一 builder/run、从 PATH/Homebrew/cache/
network fallback 或仅凭 self-reported receipt 继续。

## Maintainer D2 release-environment preflight

环境：

| Field | Value |
| --- | --- |
| OS / architecture | macOS `26.6` (`25G72`) / `arm64` |
| Xcode | `26.6` (`17F113`) |
| `notarytool` | `1.1.2 (41)` |
| release environment | opaque ref `maintainer-local-release-env-2026-07-29` |

Developer ID identity 的 sanitized independent inspection：

| Field | Result |
| --- | --- |
| valid identity count | exactly `1` |
| type | `Developer ID Application` |
| certificate SHA-1 | `38E3B7650DF0CE1DEC0CC8C403614AA0C38B0B4C` |
| Team ID / leaf OU | `8AQTYW5FKR` |
| validity | `2026-07-29T01:38:03Z`–`2027-02-01T22:12:15Z` |
| issuer | Apple Developer ID Certification Authority |
| key + chain usability | `security find-identity -v -p codesigning` valid verdict PASS |

notary credential 的 sanitized read-only preflight：

| Check | Result |
| --- | --- |
| Keychain profile authentication | PASS |
| returned submission count | `0`（新账号正常；不构成 notarization acceptance） |
| credential/private material exposed | `0` |

证书私钥与本机 credential reference 由维护者控制；本 readiness 未把它们写入
repository、GitHub Actions、environment variable、CLI password argument、日志或
evidence。
本记录不保存 Apple account、credential value、private key、password、token、
Keychain/profile path/name 或 raw notary history。每次 signing/notary 前重跑
identity count/SHA-1/Team/expiry/chain 与 authentication preflight；任一不等即停。

## Apple primary-source revalidation

`2026-07-29` 重读：

- Apple `Embedding a command-line tool in a sandboxed app`；
- Apple `Creating distribution-signed code for macOS`；
- Apple `Customizing the notarization workflow`；
- Apple TN2206 `macOS Code Signing In Depth`。

current contract 与 r1 无冲突：nested executable 使用 standard code location；
Xcode/手工流程均须 inside-out；独立分发使用 Developer ID Application、secure
timestamp 和 Hardened Runtime；签名不得使用 `--deep` 代替逐项签名；App Sandbox/
Hardened Runtime entitlement 是 unrestricted entitlement，本任务 exact entitlement
集不要求 Developer ID distribution provisioning profile；outermost DMG 由
`notarytool` 提交、取 log、require Accepted、staple/validate，并以 Gatekeeper
复核。DMG 只使用 Developer ID Application identity。

本机 system/Xcode tool availability PASS：
`xcodebuild`、`codesign`、`security`、`hdiutil`、`spctl`、`shasum`、`file`、
`otool`、`notarytool`、`stapler`、`vtool`、`lipo`。该结论不授权使用
Homebrew/PATH/dynamic-download fallback。

## Commands and sanitized results

| Command shape | Result |
| --- | --- |
| `gh api .../commits/main --jq .sha` | API/local base equality PASS |
| `git merge-base --is-ancestor <dependency-oid> <base>` | 6/6 PASS |
| `git rev-parse <base>:<pinned-path>` | repository pins PASS |
| `gh api .../actions/runs/<run>` + `.../artifacts/<id>` | run/artifact/expiry/digest PASS |
| `gh run download <run> --name rockchip-builder-a --dir <fresh-temp>` | PASS |
| `shasum -a 256` / `stat` / `file` / `lipo` / `vtool` / `otool` / `codesign -dvv` | exact unsigned identity PASS |
| `cmp <artifact-metadata> <committed-copy>` | 4/4 byte-equal PASS |
| `security find-identity -v -p codesigning` + sanitized certificate inspection | one exact valid Developer ID identity PASS |
| `notarytool history --keychain-profile <opaque> --output-format json` + count-only projection | authentication PASS；count 0 |
| `gh pr list --state open` | `[]` |

## Readiness carrier verification

| Check | Result |
| --- | --- |
| `sh ./scripts/check-sdd.sh` | PASS；0 error / 0 warning / 111 acceptance IDs |
| `python3 ./scripts/test_check_pr_paths.py` with Python 3.14.6 | PASS；50/50 |
| `git diff --check` | PASS |
| exact changed-path audit | PASS；仅 current `tasks.md` + 本 readiness record |
| sensitive literal scan | PASS；Apple account、notary profile literal、temporary absolute path、credential/private-key material 均无命中 |

第一次误用 `/usr/bin/python3` 3.9.6 运行 path test，因仓库代码使用 Python 3.10+
union type syntax，在 import 阶段以 `TypeError` 停止、测试数 0；它不构成测试结果。
按当前仓库工具环境改用 `python3` 3.14.6 后 50 项全部 PASS。该偏差未修改环境、代码
或测试，也未被隐去或计为成功。

## AC conclusion

- `BRC-PACKAGE-001`: `pending` — readiness prerequisites are closed, but no signed
  App/DMG, notary submission, ticket, staple, Gatekeeper result or package receipt
  exists yet.
- `AC-FLASH-013-01`, `AC-JOB-005-01`, `AC-UX-007-01`: `pending` for this task
  slice；本 readiness 不替代 implementation/platform evidence。

## Deviations and residual risk

- Deviations: none.
- Credential/private-key/profile-path disclosure: 0.
- Package/sign/notary/staple/install/upload/update dispatch: 0.
- Component/App launch、HDC/USB/device、E1/E2/deviceMutation/destructive dispatch: 0.
- 临时 artifact materialization 已删除；artifact 本身未入仓。
- readiness 有时效：certificate/revocation/expiry、notary authentication、
  artifact availability/expiry、Apple contract、repository pins、toolchain 或 open
  PR concurrency 任一漂移都使本 readiness 失效，必须 fail closed 并 fresh D1。
