# Windows 更新源发布规程

ArkDeck 在 Windows 上的更新通道是 **App Installer 更新源**（`ArkDeck.appinstaller`），只服务 MSIX 形态。
下载、校验签名、安装和替换都由 Windows 的 App Installer 完成；ArkDeck 自己不下载、不替换自身。
xcopy 形态没有更新通道，升级即卸载旧目录、安装新目录（见 [`windows-install.md`](windows-install.md)）。

## 信任与隐私

- Windows 只安装签名有效、签名者 subject 等于包 `Publisher` 的 MSIX。更新源本身不签名；它只指向包，
  信任来自包的 Authenticode 签名（正式包为 Azure Artifact Signing，ruling 17）和 HTTPS。
- 包的 `Publisher` 就是签名证书的 subject：`package-rc.ps1 -MsixPublisher` 从 `Package.appxmanifest` 的副本构建，
  跟踪中的清单保持 `CN=ArkDeck Development`（ruling 12）。**签名证书的 subject 一旦变化，包族名随之变化**，
  已安装的用户不会经更新源迁移到新发布者，需要重新安装。
- 检查更新由 Windows 发起，只请求更新源 URI，ArkDeck 不附加任何设备或用户标识、遥测或凭据。

## 更新源的内容

`package-rc.ps1 -FeedBaseUri https://<主机>/<路径>/` 在 MSIX 旁写出 `ArkDeck.appinstaller`
（schema `http://schemas.microsoft.com/appx/appinstaller/2021`）：

- `MainPackage` 的 Name、Publisher、Version、ProcessorArchitecture 取自本次构建的 MSIX 内的 `AppxManifest.xml`，
  脚本核对两者一致，所以更新源和包总是同一修订。
- `OnLaunch`：每次启动都检查（`HoursBetweenUpdateChecks="0"`），`ShowPrompt="true"` 提示用户，
  `UpdateBlocksActivation="false"` 不阻塞启动；另开 `AutomaticBackgroundTask` 后台检查。
- `ForceUpdateFromAnyVersion` 为 false：不降级。
- 更新源与包的 URI、SHA-256 和版本记在 `rc-manifest.json` 的 `msix.appInstaller` 下。
- 基地址必须是以 `/` 结尾、无 query 与 fragment 的 `https` URI，否则构建前即被拒绝。

## 发布前提

- 本次 `Identity/@Version` 严格高于已发布的版本：App Installer 只升级到更高版本。
- 正式签名的 RC 已按 `windows-install.md` 的维护者一节从干净检出构建，`rc-manifest.json` 中
  `msix.signing.installable` 为 true、`timestamped` 为 true。
- 签名证书的 subject 与上一版相同（否则见上文的包族名变化）。

## 封闭发布顺序

以下步骤不得重排。任一步失败即停止，不覆盖上一份有效的更新源。

1. 核对 MSIX：`Get-AuthenticodeSignature` 为 `Valid` 且带时间戳，签名者 subject 等于包的 `Publisher`；
   SHA-256 等于 `rc-manifest.json` 的 `msix.sha256`。
2. 在参考主机上跑 `package-rc.ps1 -SmokeZip <同一次运行的 zip>`，确认 daemon、CLI 与 App 以发布者身份工作。
3. 上传 MSIX 到 `msix.appInstaller.mainPackageUri`，再下载回读，逐字节核对长度与 SHA-256。
4. 最后上传 `ArkDeck.appinstaller` 到 `msix.appInstaller.uri`，下载回读，核对 SHA-256 等于
   `msix.appInstaller.sha256`。
5. 在装有上一版的主机上重启 App：App Installer 应提示更新，接受后 `Get-AppxPackage` 显示新版本。

回滚：重新上传上一版的 MSIX 与更新源不会让已升级的用户降级（`ForceUpdateFromAnyVersion` 为 false）。
要修复问题，发布一个版本号更高的修订。
