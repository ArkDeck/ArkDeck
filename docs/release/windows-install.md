# ArkDeck Windows 安装说明

本页说明 Windows x64 发布候选版（RC）怎样安装、配置、升级和卸载，也是维护者产出 RC 的入口说明。
构建入口：`windows/scripts/package-rc.ps1`（CHG-2026-074 TASK-XPA-022）。干净主机上的逐步验收见
`openspec/changes/chg-2026-074-shared-rust-runtime-core/evidence/runs/TASK-XPA-022/windows-clean-host-smoke-runbook.md`；
App Installer 更新源的发布顺序见 [`windows-update.md`](windows-update.md)。

ARM64 暂不发布（r13）。

## 两种包

同一次 `package-rc.ps1` 运行、同一个源码修订产出两种形态，内容相同：

| 形态 | 文件 | 内容 |
|---|---|---|
| xcopy | `arkdeck-rc-<版本>-windows-x64-<修订>.zip` | 一个目录：`ArkDeck.exe`（WinUI 3 App，自包含 Windows App SDK 与 .NET）、`arkdeck-agentd.exe`（Rust daemon）、`bin\arkdeck.exe`（Rust CLI）、`rc-manifest.json`（每个文件的大小与 SHA-256、工具链、签名身份）。 |
| MSIX | `ArkDeck.App_<版本>_x64.msix`，以及更新源 `ArkDeck.appinstaller` | 同样的布局：daemon 在包根目录，CLI 在 `bin\`。写虚拟化关闭（ruling 8），daemon 的状态落在真实的 `%LOCALAPPDATA%\ArkDeck`。 |

CLI 放在 `bin\` 是因为 NTFS 文件名不区分大小写：`arkdeck.exe` 不能与 `ArkDeck.exe` 同目录。

App、CLI 与 daemon 来自同一修订（`rc-manifest.json` 的 `sourceRevision`），**升级时三者一起换**。

## 信任：客户端怎样认 daemon

CLI 与 App 都不从管道上读 daemon 的身份，只认安装时给定的输入（环境变量），两者读同一组：

| 变量 | 用途 |
|---|---|
| `ARKDECK_DAEMON_PUBLISHER_ORGANIZATION`、`ARKDECK_DAEMON_PUBLISHER_EKU` | 正式签名（Azure Artifact Signing，ruling 17）。`WinVerifyTrust` 接受的证书链必须止于 Microsoft Identity Verification Root Certificate Authority 2020，叶证书的唯一 `O=` 等于前者，并带有 `1.3.6.1.4.1.311.97.<profile>` 形式的证书配置文件 EKU 等于后者。两个值要么都给，要么都不给；只给一个会被直接拒绝。不钉证书哈希：Artifact Signing 的叶证书每天换发。 |
| `ARKDECK_DAEMON_SIGNER_SHA256` | 开发签名（ruling 12 的主机信任开发证书）的叶证书 SHA-256。只用于开发主机。 |
| `ARKDECK_DAEMON_PACKAGE_FAMILY` | MSIX 包族名，可与发布者身份并列配置。 |
| `ARKDECK_DAEMON_PATH` | daemon 映像的绝对路径。App 默认取它旁边的 `arkdeck-agentd.exe`；CLI 在 `bin\` 里，必须给出。 |

正式包的这两个值写在 `rc-manifest.json` 的 `daemonConfiguration` 里。什么都没配置时，App 不连接任何东西，只显示恢复横幅；
CLI 拒绝启动或连接 daemon。

MSIX 形态也按发布者身份钉 daemon（委托的次要决定，待下一批裁定）：CLI 直接启动包内的
`arkdeck-agentd.exe` 时，这个进程没有包身份，单靠包族名无法证明它。包内的 daemon 与 CLI 和 xcopy 形态是同一组已签名文件，
所以两种形态用同一组发布者变量；包族名可以并列配置，不是必需。

## xcopy 形态

以下步骤都以标准用户执行，不需要提权。

1. 核对下载：zip 的 SHA-256 等于 `rc-manifest.json` 里 `zip.sha256`。
2. 解压到自己的目录，例如 `%LOCALAPPDATA%\Programs\ArkDeck`。保留网络下载标记（Mark of the Web）。
3. 配置（写进用户环境变量，或在启动前的同一个终端里设置）：

   ```powershell
   $rc = Get-Content .\rc-manifest.json -Raw | ConvertFrom-Json
   $root = "$env:LOCALAPPDATA\Programs\ArkDeck\<解压出的目录>"
   $env:ARKDECK_DAEMON_PUBLISHER_ORGANIZATION = $rc.daemonConfiguration.ARKDECK_DAEMON_PUBLISHER_ORGANIZATION
   $env:ARKDECK_DAEMON_PUBLISHER_EKU          = $rc.daemonConfiguration.ARKDECK_DAEMON_PUBLISHER_EKU
   $env:ARKDECK_DAEMON_PATH                   = "$root\arkdeck-agentd.exe"
   ```

4. 首次启动：`& "$root\bin\arkdeck.exe" --output json doctor`。CLI 校验 daemon 映像后启动它（decision 11：
   daemon 由客户端启动，不注册服务）。然后打开 `$root\ArkDeck.exe`。

## MSIX 形态

1. 打开维护者发布的 `https://<更新源主机>/…/ArkDeck.appinstaller`，或执行
   `Add-AppxPackage -AppInstallerFile <URI>`。App Installer 应显示证书里的发布者，无警告，无需提权。
2. 用与 xcopy 相同的两个发布者变量配置，`ARKDECK_DAEMON_PATH` 指向
   `(Get-AppxPackage -Name <包名>).InstallLocation` 下的 `arkdeck-agentd.exe`。
3. 从开始菜单打开 ArkDeck。之后的版本由更新源送达，见 [`windows-update.md`](windows-update.md)。

## 升级

- **MSIX**：App Installer 在每次启动 App 时检查更新源，提示后安装更高版本；不降级。
- **xcopy**：没有自动更新。先卸载旧目录（见下一节；daemon 的状态保留），再按上文安装新版本到新目录，更新
  `ARKDECK_DAEMON_PATH`。之后任何需要 Runtime 的命令都会在保留的状态上启动新 daemon。

## 卸载

在同一修订的检出里（或把脚本复制出来）执行：

```powershell
pwsh -NoProfile -File .\windows\scripts\uninstall-rc.ps1 -InstallDirectory <安装目录>   # xcopy
pwsh -NoProfile -File .\windows\scripts\uninstall-rc.ps1 -PackageName <包名>            # MSIX
```

- 目录里必须有 `rc-manifest.json`，否则什么都不删。
- 从该安装运行的 daemon 由该安装自己的 `bin\arkdeck.exe runtime service uninstall` 停止（钉住安装的
  daemon 映像及其签名证书）：有活动或未关闭的 Runtime Job 时拒绝卸载（CLI 退出 75），CLI 的其他拒绝同样
  拒绝卸载，什么都不删；未签名的映像无法由 CLI 证明身份，改为经它自己的停止事件请求停止并等待退出。
  从别的安装运行的 daemon 不受影响，答复里会写明。
  App 或 CLI 仍在运行时拒绝卸载：先关闭它们。任何进程都不会被强杀。
- 保留：`%LOCALAPPDATA%\ArkDeck` 下 daemon 的状态目录 `Agentd`、默认 Sessions 根 `Sessions`、Trace 缓存 `Trace`，
  以及签名预设目录 `Signing\OpenHarmony` 与其 Credential Manager 条目；答复里列出 `Agentd` 与签名预设目录是否存在。
  删除签名凭据用 `arkdeck runtime signing remove`，在卸载之前执行。

## 维护者：产出 RC

### CI（无签名）

`main` 上源码变更后，[`windows-rc.yml`](../../.github/workflows/windows-rc.yml) 用同一个 `package-rc.ps1`
构建**无签名**的两种形态，作为 artifact `arkdeck-windows-rc-<修订>` 保留。它只有仓库只读 token，不接触任何凭据。
两个客户端都拒绝无签名的 daemon，所以这份产物用于检查和维护者的签名运行，不用于安装。

### 正式签名（维护者本机）

凭据只由维护者在运行时提供；仓库和 CI 里没有任何密钥。签名命令是维护者自己的包装脚本，每个文件调用一次，
例如 `signtool sign /fd SHA256 /tr http://timestamp.acs.microsoft.com /td SHA256 /dlib <Azure.CodeSigning.Dlib.dll> /dmdf <metadata.json> <文件>`，
放在仓库之外。从干净检出执行：

```powershell
pwsh windows/scripts/package-rc.ps1 -OutputDirectory <输出目录> -SigningMode production `
  -ProductionSignCommand <签名单个文件的脚本> -MsixSignCommand <签名 MSIX 的脚本> `
  -ExpectedPublisherOrganization '<证书的 O=>' -ExpectedPublisherEku 1.3.6.1.4.1.311.97.<profile> `
  -MsixPublisher '<签名证书的完整 subject>' `
  -FeedBaseUri https://<更新源主机>/arkdeck/windows/
```

- 缺少任何输入、EKU 是 Public Trust 标记、`-MsixPublisher` 的 `O=` 不是预期组织、检出不干净，都在构建之前被拒绝。
- 每个可执行文件必须带时间戳，并带预期的发布者身份；MSIX 的签名者 subject 必须等于包的 `Publisher`。
- 每次发布的 RC 都要提高 `windows/App/Package.appxmanifest` 的 `Identity/@Version`：App Installer 只升级到更高版本。
- 发布前可在参考主机上跑 `package-rc.ps1 -SmokeZip <zip>`：安装、`doctor`、App 的 UIA 冒烟、卸载，全程以发布者身份配置。
- Store 与 winget 的提交由维护者负责。
