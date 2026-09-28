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

## 维护者：构建 RC

签名、公证与 staple 只由维护者用自己的证书与凭据执行。Agent 只维护脚本、在 CI 跑无签名结构检查，
并在维护者产出 RC 后做只读验签。

前提：

- 本仓 checkout 干净，位于要发布的 `main` 提交；`python3 scripts/release/release_version.py check` 通过。
- ArkForge checkout 干净，`HEAD` 等于 `rust/Cargo.toml` 的 pin（脚本核对，不等即失败），且已
  `cargo fetch`（其打包脚本用 `--offline` 构建）。
- 钥匙串里有 Developer ID Application 身份；两个 helper 的 provisioning profile；`notarytool store-credentials`
  存好的 keychain profile。

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

可选：`ARKDECK_CODESIGN_IDENTITY`（缺省 `Developer ID Application: Hanfeng Fu (8AQTYW5FKR)`）、
`ARKDECK_NOTARY_KEYCHAIN`（notary profile 不在默认钥匙串时）。

脚本依次：预检（版本一致、checkout 干净、ArkForge pin、签名身份、notary 凭据）→ `build-helpers.sh` 的 Rust 模式
（helper 对签名、公证、staple、spctl）→ ArkForge 的 `packaging/macos/package-arkforge.sh`（Developer ID、
hardened runtime、timestamp，按签名后字节写 manifest）→ App 的 Release archive 与 Developer ID 导出
（`scripts/release/ExportOptions.plist`），App 单独公证、staple、spctl → 组装 DMG → DMG 签名（timestamp）→
`notarytool submit --wait` → `stapler staple` 与 `validate` → DMG 的 `spctl` → 挂载 DMG 核对：各项目录树与暂存时
逐字节一致、严格验签、App 的身份要求、App 对 daemon 的完整要求（身份、Team、版本号与 build 号）、挂载后 App 与
CLI 的 `spctl` 与 staple、ArkForge 两个可执行文件的 Team。

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
