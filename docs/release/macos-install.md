# ArkDeck macOS 安装说明

本页随发布 DMG 一起分发（DMG 里的 `INSTALL.md` 就是本页），也是维护者构建发布候选版（RC）的说明。
构建入口：`scripts/release/build_macos_release.py`（CHG-2026-074 TASK-XPA-017，阶段 S 第 S5 刀）。

## DMG 里有什么

| 项 | 内容 |
|---|---|
| `ArkDeck.app` | 桌面 App。沙盒应用，**不能**自己安装或升级后台 Runtime。 |
| `ArkDeckCLI.app` | Rust CLI（`Contents/MacOS/arkdeck`）。其中 `Contents/Helpers/ArkDeckAgent.app` 是 Rust daemon，由 CLI 装成 LaunchAgent。 |
| `ArkForge.bundle` | 刷机机械层（`arkforge`、`arkforged` 与设备 profile），由 `rust/Cargo.toml` pin 的 ArkForge 修订构建。它单独放，不嵌在任何 `.app` 里。 |
| `INSTALL.md` | 本页。 |

App、CLI 与 daemon 属同一个 release，版本号（`CFBundleShortVersionString`）与 build 号（`CFBundleVersion`）完全相同。
App 连 daemon 时要求两者都相等，所以**每次升级都必须把 App 与 Runtime 一起换**：只换其一，App 会报告版本不匹配。

## 安装与升级

首装与每次升级的步骤相同。所有命令都在终端里执行；ArkDeck 不会替你做。

1. 挂载 DMG，把两个 App 复制到 `/Applications`：

   ```sh
   VOLUME="/Volumes/ArkDeck <版本>"
   ditto "$VOLUME/ArkDeck.app" /Applications/ArkDeck.app
   ditto "$VOLUME/ArkDeckCLI.app" /Applications/ArkDeckCLI.app
   ```

2. **先把 `ArkForge.bundle` 复制出 DMG，放到一个稳定、按版本区分的路径**，再把这个路径传给 CLI。
   CLI 记录的是绝对路径；DMG 推出后 `/Volumes/...` 就不存在了。

   ```sh
   FORGE="$HOME/Library/ArkForge/ArkDeck-<版本>-<build>/ArkForge.bundle"
   mkdir -p "$(dirname "$FORGE")"
   ditto "$VOLUME/ArkForge.bundle" "$FORGE"
   ```

   - 用 `ditto`（或 `cp -R`）复制，不要在 Finder 里打开 bundle 内部：bundle 里多出任何 manifest 没有声明的文件
     （例如 `.DS_Store`），加载器会拒绝整个 bundle。
   - 不要覆盖或删除上一版的 bundle 目录。回滚时旧的 LaunchAgent 配置仍指向旧路径。

3. 安装或升级 Runtime（替换 LaunchAgent；首装与升级是同一条命令）：

   ```sh
   ARKDECK=/Applications/ArkDeckCLI.app/Contents/MacOS/arkdeck
   "$ARKDECK" runtime service update \
     --daemon /Applications/ArkDeckCLI.app/Contents/Helpers/ArkDeckAgent.app \
     --hdc <hdc 可执行文件的绝对路径> \
     --arkforge-bundle "$FORGE" \
     --output json
   ```

   - `--daemon` 省略时取 CLI 所在 `.app` 里的 helper，结果相同；显式写出便于核对。
   - `--hdc` 首装必须给；升级时省略则沿用已安装的值。
   - 装着 ArkTrace 时按原值传 `--arktrace-descriptor <路径>`，没有就传 `none`（省略时只在 descriptor 未漂移时沿用）。
   - 升级会把被替换的 helper 留一代在 `~/Library/Application Support/ArkDeck/Helpers/.rollback/ArkDeckAgent.app`，
     并在 stdout 的回执里给出路径。
   - `agentd install` 是同一安装路径的兼容拼写；`runtime service install` 是另一条按 bootstrap registry 的
     `--bundle`/`--bundle-generation` 安装的路径，从 DMG 安装不用它。

4. 打开 `/Applications/ArkDeck.app`。

从 Swift Runtime 首次切换到 Rust Runtime 时，第 3 步之前另有切换预检与回滚副本的步骤，按
`docs/design/cross-platform/macos-rust-cutover-runbook.md` 执行，由维护者本人完成。

## 维护者：从 CI 产出 RC（Release candidates from CI）

签名、公证与 staple 用维护者的证书与凭据执行，有两处：GitHub Actions 的
[`release-rc.yml`](../../.github/workflows/release-rc.yml)（凭据是 `release` environment 的 secret），或维护者本机
（见下一节）。两处跑的是同一个 `build_macos_release.py release`。Agent 不接触任何凭据：它维护脚本与 workflow、
在 CI 跑无签名结构检查，并通过合入版本号变更触发 CI 产出 RC，再对产物做只读验签。

### 一次性设置（维护者）

1. 建 environment `release`，只允许 `main` 部署（Settings → Environments → New environment → Deployment
   branches and tags → Selected branches → `main`）。secret 只放在这个 environment 里，不放仓库级：未合入
   `main` 的代码拿不到它们，workflow 也没有 `pull_request` 触发。
2. 建 App Store Connect API key 供公证用：App Store Connect → Users and Access → Integrations → Team Keys，
   角色 Developer。记下 Key ID 与 Issuer ID，下载一次性的 `AuthKey_<KeyID>.p8`。
3. 从钥匙串导出 Developer ID Application 证书与私钥为 `DeveloperID.p12`（设一个导出口令）；备好两个 helper
   的 provisioning profile（`com.arkdeck.cli` 与 `com.arkdeck.agentd`）。
4. 写入七个 secret（`gh` 需对本仓有 admin 权限；值从文件或标准输入读，不出现在命令行与 shell history）：

   ```sh
   base64 -i DeveloperID.p12 | gh secret set ARKDECK_DEVELOPER_ID_P12_BASE64 --env release
   gh secret set ARKDECK_DEVELOPER_ID_P12_PASSWORD --env release          # 交互输入导出口令
   base64 -i cli.provisionprofile | gh secret set ARKDECK_CLI_PROVISIONING_PROFILE_BASE64 --env release
   base64 -i daemon.provisionprofile | gh secret set ARKDECK_DAEMON_PROVISIONING_PROFILE_BASE64 --env release
   base64 -i AuthKey_<KeyID>.p8 | gh secret set ARKDECK_NOTARY_API_KEY_P8_BASE64 --env release
   gh secret set ARKDECK_NOTARY_API_KEY_ID --env release                  # 交互输入 Key ID
   gh secret set ARKDECK_NOTARY_API_ISSUER_ID --env release               # 交互输入 Issuer ID
   ```

   写完删除本地的 `.p12` 与 `.p8` 副本（`.p8` 在 App Store Connect 只能下载一次，需要时吊销重建即可）。

### workflow 做什么

- 触发：`main` 上 `scripts/release/release-version.json` 有变更的 push（即版本号或 build 号变更的 PR 合入），
  或手动 `workflow_dispatch`（只接受 `main`，别的 ref 在第一步失败）。同时只跑一个 RC，且不会被后来者取消。
- 同一版本与 build 已有未过期 artifact `arkdeck-rc-<版本>-<build>`，或某个 GitHub Release 已带
  `ArkDeck-<版本>-<build>.dmg` 时，不再构建，job 以 notice 结束；要新 RC 就递增 build 号。
- 先在无凭据时拉取依赖：本仓 `rust/` 的 `cargo fetch --locked`；ArkForge（公开仓库）按 `rust/Cargo.toml` 的 pin
  精确 checkout 到 `$RUNNER_TEMP/ArkForge` 并 `cargo fetch --locked`。
- 构建缓存也在装凭据之前恢复：cargo registry 与 git 源、`rust/target` 与 ArkForge 的 `target`（两个打包脚本都把
  二进制复制出来再签副本，target 里没有签过名的东西）、xcodebuild 的 SwiftPM clones（按已提交的两份
  `Package.resolved` 取键，archive 只用其中钉住的修订）。key 含 runner 镜像版本与 rustc；DerivedData 每次全新，
  不用 Xcode compilation caching。只在 `main` 上成功构建了 RC、凭据清理之后，精确 key 未命中时才保存。
- 再装凭据：Developer ID 身份导入本 job 新建的临时钥匙串（口令在 job 内随机生成并 mask，`set-key-partition-list`
  允许 codesign 无提示使用，并加入用户钥匙串搜索列表，因为 `xcodebuild -exportArchive` 与 ArkForge 打包脚本
  只从搜索列表找身份）；`.p12` 导入后即删；两个 profile 与 `.p8` 写成 `$RUNNER_TEMP` 下的文件，后续步骤只拿路径。
- 构建：`ARKDECK_CODESIGN_KEYCHAIN`、两个 profile 路径、API key 三元组与 SwiftPM clones 目录
  （`ARKDECK_XCODE_SOURCE_PACKAGES`）交给
  `build_macos_release.py release --output "$RUNNER_TEMP/rc" --arkforge-checkout "$RUNNER_TEMP/ArkForge"`。
- 构建之后、上传之前的清理步骤无论成败都执行（`if: always()`）：删临时钥匙串与全部凭据文件。
- 成功时上传 artifact `arkdeck-rc-<版本>-<build>`（DMG、`release-receipt.json`、两份公证日志，保留 90 天），
  job summary 给出 DMG 的 SHA-256。

### 产出一个 RC

```sh
python3 scripts/release/release_version.py bump-build     # 在 agent/** 分支上，提交并开 PR
# PR 合入 main 后 release-rc.yml 自动运行
gh run list --workflow release-rc.yml --branch main --limit 1
gh run download <run-id> -n arkdeck-rc-<版本>-<build> -D /abs/arkdeck-rc-<版本>-<build>
```

下载后按下文「产出目录」核对：`release-receipt.json` 的 `source.revision` 等于合入提交，DMG 的 SHA-256 与
receipt 一致；`xcrun stapler validate` 与 `spctl --assess --type open --context context:primary-signature` 可在任意
Mac 上只读复核。

## 维护者：本机构建 RC

凭据在维护者本人已登录的钥匙串里；锁屏或 Agent 沙盒里取不到，所以这条路径只由维护者在自己的终端执行。

前提：

- 本仓 checkout 干净，位于要发布的 `main` 提交；`python3 scripts/release/release_version.py check` 通过。
- ArkForge checkout 干净，`HEAD` 等于 `rust/Cargo.toml` 的 pin（脚本核对，不等即失败），且已
  `cargo fetch`（其打包脚本用 `--offline` 构建）。
- 钥匙串里有 Developer ID Application 身份；两个 helper 的 provisioning profile；公证凭据二选一：
  `notarytool store-credentials` 存好的 keychain profile，或 App Store Connect API key。

版本号：`scripts/release/release-version.json` 是唯一来源，`release_version.py` 把它同步到 pbxproj 与两个
helper Info.plist。发 RC 前由维护者决定是否递增 build 号：

```sh
python3 scripts/release/release_version.py bump-build     # 0.1.0 (1) -> 0.1.0 (2)
python3 scripts/release/release_version.py set 0.1.0 2    # 或显式指定
```

改动后提交再构建（构建要求 checkout 干净）。

构建：

```sh
ARKDECK_CLI_PROVISIONING_PROFILE=/abs/cli.provisionprofile \
ARKDECK_DAEMON_PROVISIONING_PROFILE=/abs/daemon.provisionprofile \
ARKDECK_NOTARY_KEYCHAIN_PROFILE=<profile 名> \
python3 scripts/release/build_macos_release.py release \
  --output /abs/arkdeck-rc-<版本>-<build> \
  --arkforge-checkout /abs/ArkForge
```

公证凭据恰好给一种，两种都给或都不给时预检失败：`ARKDECK_NOTARY_KEYCHAIN_PROFILE`（可加
`ARKDECK_NOTARY_KEYCHAIN`，profile 不在默认钥匙串时），或 API key 三元组 `ARKDECK_NOTARY_API_KEY_PATH`（`.p8` 的
绝对路径）、`ARKDECK_NOTARY_API_KEY_ID`、`ARKDECK_NOTARY_API_ISSUER_ID`（传给 `notarytool --key --key-id --issuer`，
只有路径进参数，key 内容不进日志）。

可选：`ARKDECK_CODESIGN_IDENTITY`（缺省 `Developer ID Application: Hanfeng Fu (8AQTYW5FKR)`）；
`ARKDECK_CODESIGN_KEYCHAIN`（身份所在钥匙串的绝对路径，路径不含空白：本仓的 codesign 调用带 `--keychain`，App
archive 经 `OTHER_CODE_SIGN_FLAGS` 带上；它还必须在用户钥匙串搜索列表里，预检核对）；
`ARKDECK_XCODE_SOURCE_PACKAGES`（xcodebuild 的 SwiftPM clones 目录，绝对路径）。

脚本先预检（版本一致、checkout 干净、ArkForge pin、签名身份、notary 凭据），再**同时**构建三个组件（输入互不
相干；任一失败即停下其余组件的进程组，报出失败的组件名，什么都不产出）：`build-helpers.sh` 的 Rust 模式
（helper 对签名、公证、staple、spctl）；ArkForge 的 `packaging/macos/package-arkforge.sh`（Developer ID、
hardened runtime、timestamp，按签名后字节写 manifest）；App 的 Release archive（所有 target 含 SwiftPM 包都只编
arm64：`ARCHS=arm64 ONLY_ACTIVE_ARCH=NO` 在命令行给出，因为项目里的 `ARCHS` 管不到包 target；包只用
`Package.resolved` 钉住的修订）与 Developer ID 导出（`scripts/release/ExportOptions.plist`），核对每个 Mach-O 都是
单一 arm64 切片后单独公证、staple、spctl。三者都成功后 → 组装 DMG → DMG 签名（timestamp）→
`notarytool submit --wait` → `stapler staple` 与 `validate` → DMG 的 `spctl` → 挂载 DMG 核对：各项目录树与暂存时
逐字节一致、严格验签、App 的身份要求、App 对 daemon 的完整要求（身份、Team、版本号与 build 号）、挂载后 App 与
CLI 的 `spctl` 与 staple、ArkForge 两个可执行文件的 Team、三个组件的每个 Mach-O 都是单一 arm64 切片。

ArkForge.bundle 不单独 staple（它不是 `.app`，也不能多出文件），由 DMG 的公证覆盖；把它从已 staple 的 DMG
复制出来即可。

产出目录（任何一步失败都不产出）：

- `ArkDeck-<版本>-<build>.dmg`
- `release-receipt.json`：源码提交、版本与 build 号、ArkForge pin 与构建修订、ArkForge manifest 与成员摘要、
  DMG 的 SHA-256、App/CLI/daemon 的目录树与主程序摘要、App 与 DMG 的公证 submission id
- `notary-log-app.json`、`notary-log-dmg.json`

无签名结构检查（不需要任何凭据，不联系 Apple，产物不可分发）：

```sh
python3 scripts/release/build_macos_release.py unsigned \
  --output /abs/out --app /abs/ArkDeck.app \
  --helpers <build-unsigned-rust-helpers.sh 的输出根> \
  --arkforge-bundle /abs/ArkForge.bundle
```

它走同一套组件检查、DMG 组装和挂载核对，输出与 DMG 里都带 `UNSIGNED-STRUCTURE-CHECK-ONLY.txt`。

更新通道（`maintainer update-feed prepare|assemble`）与 GitHub Release 是发布之后的事，见
`docs/release/macos-auto-update.md`。
