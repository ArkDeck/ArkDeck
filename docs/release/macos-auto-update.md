# macOS 自动更新发布规程

ArkDeck v1 的更新通道是最小自研的 `check + download + verify + Finder handoff`。
应用不会挂载 DMG、替换自身、退出时安装或声明自动回滚。维护者必须先完成
Developer ID 签名、公证和静态验证，最后才发布签名 feed。

## 固定信任与隐私合同

- feed key ID：`arkdeck-update-2026-07-b949b102`
- Ed25519 raw public key：
  `c5Ho0xkWFQ3Ovzjx98dQhF3n5sytJjffqD3a+ftgP8c=`
- SPKI DER SHA-256：
  `b949b102c5eb266084c3d59ee2e05de45681947841a4864afa0fc4136a1e7ddf`
- feed URL：
  `https://github.com/ArkDeck/ArkDeck/releases/latest/download/arkdeck-update-feed-v1.json`
- 自动检查默认开启，只在 App 启动且距上次尝试至少 24 小时时发生。检查不会自动
  下载。初始检查请求只发送 query `appVersion`、`osVersion`、`arch`；不发送
  设备或用户标识、用户路径、locale、遥测、cookie 或凭据。

私钥只可存在于与 Agent、仓库和 CI 隔离的维护者发布环境中。私钥内容、路径和
passphrase 都不得成为 CLI 参数、环境变量、shell history、CI secret、日志或
evidence。签名命令必须让 OpenSSL 在终端交互读取加密私钥的口令。仓库工具只接触
payload、signature input、64-byte signature、feed 和内置公钥。

## 发布前提

在隔离维护者环境中准备：

- 已完成 Release 构建的 `ArkDeck.app`；
- 加密的 Ed25519 私钥（不位于 repo、CI workspace 或临时目录）；
- 本次严格递增的正 `sequence` 和严格递增的稳定版本 `major.minor.patch`；
- UTC RFC3339 的 `issuedAt`/`expiresAt`，有效窗口为正且不超过 30 天；
- GitHub Release 的最终 HTTPS DMG URL。

v1 的 30 天有效期是强制 freshness 边界，不支持同版本续期：相同 `sequence`
只能重放逐字节相同的 payload，而更高 `sequence` 必须携带严格更高的稳定版本。
因此维护者必须监控当前 feed 的 `expiresAt`，并在到期前发布一个更高版本（必要时
发布只含维护修订的 patch 版本）和新的 feed。不得只延长同版本的 `expiresAt`。

如果 key 需要轮换，必须先通过独立 change 发布同时信任新 key 的 App，再切换
feed；feed 自身不能下发新的信任根。

## 封闭发布顺序

以下步骤不得重排。任一步失败都停止，不覆盖上一份有效 feed。

1. 构建归档并使用 Developer ID Application identity 签名 App 和 DMG。
2. 提交公证并 stapling。
3. 验证 App、DMG、staple 和 Gatekeeper 结果；确认 DMG 的 Team identifier 与
   发布中的 ArkDeck App 相同。
4. 使用仓库构建出的 `arkdeck update-feed prepare` 流式计算最终 DMG 的长度和
   SHA-256；该命令先验证版本、时间窗口、架构与 artifact URL，再生成确定性
   payload 与签名输入。失败时不得进入隔离签名步骤。
5. 在隔离维护者终端使用本地 OpenSSL 私钥签名 signature input。
6. 使用 `arkdeck update-feed assemble` 以 App 内置公钥组装并完整自验 feed。
7. 先上传 DMG，再下载回读并逐字节核对长度和 SHA-256。
8. 最后上传 feed，下载回读并逐字节核对 feed SHA-256。
9. 从已发布 App 手动检查一次；下载和 Finder handoff 仍分别需要用户动作。

示例中的路径必须替换为隔离环境的真实路径。不要把私钥路径赋给环境变量：

```bash
arkdeck update-feed prepare \
  --sequence 42 \
  --version 1.4.0 \
  --minimum-system 14.0.0 \
  --issued-at 2026-07-24T03:00:00Z \
  --expires-at 2026-08-20T03:00:00Z \
  --artifact /release/ArkDeck-1.4.0.dmg \
  --artifact-url https://github.com/ArkDeck/ArkDeck/releases/download/v1.4.0/ArkDeck-1.4.0.dmg \
  --notes "Security and reliability improvements." \
  --out /release/feed-work

openssl pkeyutl -sign -rawin \
  -inkey /maintainer-only/arkdeck-update-feed-ed25519-private.pem \
  -in /release/feed-work/arkdeck-update-signature-input-v1.bin \
  -out /release/feed-work/arkdeck-update-signature-v1.bin

arkdeck update-feed assemble \
  --payload /release/feed-work/arkdeck-update-payload-v1.json \
  --signature /release/feed-work/arkdeck-update-signature-v1.bin \
  --out /release/arkdeck-update-feed-v1.json
```

`assemble` 要求 raw 64-byte Ed25519 signature，并在写 feed 前执行 envelope、
canonical payload、签名、时间窗口、版本、架构和 artifact URL 的完整自验。它不
接受私钥参数，也不读取任何私钥。

上传前与 fetch-back 后分别记录公开产物的校验值：

```bash
wc -c /release/ArkDeck-1.4.0.dmg
shasum -a 256 /release/ArkDeck-1.4.0.dmg
shasum -a 256 /release/arkdeck-update-feed-v1.json
```

release evidence 可记录版本、sequence、公开 URL、长度、公开 SHA-256、公证与
Gatekeeper 结论以及 feed 自验结论；不得记录私钥路径、口令、私钥输出或终端捕获。

## 失败与恢复

- DMG 上传或 fetch-back 不一致：删除该候选 release asset，保持旧 feed。
- feed 组装、自验、上传或 fetch-back 不一致：不发布/不覆盖 feed。
- feed 已发布后发现问题：旧 sequence 不能重放，旧版本不能降级发布。修复产物后
  使用更高版本和更高 sequence 重新走完整流程。
- 当前 feed 即将到期但没有功能发布：仍须在 `expiresAt` 前发布更高 patch 版本；
  同版本 re-issue/续期会被客户端按 replay/non-increasing release 拒绝。
- 客户端验签、长度、摘要、Team identity 或最终复验失败：删除不可信缓存，安装
  动作为零。支持人员只可建议重新检查或改用已记录的手动公证 DMG 过渡通道。
