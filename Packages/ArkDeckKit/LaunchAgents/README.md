# macOS 无头设备 Runtime

`arkdeck-agentd` 可作为当前登录用户的 LaunchAgent 常驻运行。它继续使用同一个
Runtime、用户私有 Unix socket 和只读 XPC 门；不需要管理员权限，也不会建立第二套
HDC 执行路径。

## 首次准备与安装

1. 安装 DevEco/OpenHarmony 工具，并在设备侧完成一次 USB 信任。需要系统授权时先在
   登录用户会话中完成；调试 HAP 还必须把当前设备 UDID 加入其签名 profile。刷入新系统后
   若包管理器报告 `9568423`，应重新完成设备授权并重新签名/构建 HAP。LaunchAgent 不绕过
   macOS、设备信任或应用签名授权。
2. 为 `com.arkdeck.cli` 和 `com.arkdeck.agentd` 准备同一 Team 的 Developer ID provisioning
   profile；两份 profile 都必须授权 `8AQTYW5FKR.com.arkdeck.shared` Keychain access group。
   将路径分别传入 `ARKDECK_CLI_PROVISIONING_PROFILE` 与
   `ARKDECK_DAEMON_PROVISIONING_PROFILE`；先用 `xcrun notarytool store-credentials`
   保存公证凭据，再把 profile 名称传入 `ARKDECK_NOTARY_KEYCHAIN_PROFILE`，运行
   `Distribution/macOS/build-helpers.sh`。脚本会核对两份 profile 的 Team、application
   identifier 和共享 Keychain group，生成带 hardened runtime 的 `ArkDeckCLI.app`，在
   `Contents/Helpers` 内嵌、逐层签名 `ArkDeckAgent.app`，最后完成 notarization、staple 和
   Gatekeeper assessment。未提供 Apple 授权的 profile 或公证凭据时不会产出发布 helper。
3. 从已签名 CLI helper 运行：

   ```text
   arkdeck runtime service install --hdc /absolute/path/to/hdc
   arkdeck runtime service status
   arkdeck doctor
   ```

只在当前 Mac 上验证工作树代码时，不需要把开发构建上传公证服务，也不应手工拼装 bundle。
使用独立的本地构建入口，并显式传入同一 Team 的两份 profile：

```text
ARKDECK_CLI_PROVISIONING_PROFILE=/absolute/com.arkdeck.cli.provisionprofile \
ARKDECK_DAEMON_PROVISIONING_PROFILE=/absolute/com.arkdeck.agentd.provisionprofile \
ARKDECK_LOCAL_HELPER_OUTPUT=/absolute/output-directory \
Distribution/macOS/build-local-helpers.sh
```

该脚本固定构建 Debug `arkdeck`/`arkdeck-agentd`，复用发布路径相同的 Info.plist、资源、
entitlements、Developer ID 和 hardened runtime，逐层执行严格 codesign 校验。它明确使用
`timestamp=none`，不执行 notarization、staple 或 Gatekeeper distribution assessment，并在输出根
写入 `LOCAL-DEVELOPMENT-BUILD.txt`；产物只可用于当前 Mac 的 `agentd install/update`、签名预设和
CLI 真机验证，绝不是发布物。正式发布仍只能运行 `build-helpers.sh`，其公证要求没有本地绕过开关。

`install` 会严格验证 helper bundle 的 Developer ID、Team、bundle ID、hardened runtime、
embedded provisioning profile 和共享 Keychain entitlement，再哈希 daemon/HDC，把完整 daemon
bundle 复制到 `~/Library/Application Support/ArkDeck/Helpers/ArkDeckAgent.app`，生成
`~/Library/LaunchAgents/com.arkdeck.agentd.plist`，再用 `gui/$UID` 启动服务。plist
明确传入 `ARKDECK_HDC_PATH`；Runtime 在启动时固定 HDC 摘要，并在每次 spawn 前重新验证
文件身份，缺失或漂移都会 fail closed。daemon 会用同一份 identity-bound HDC 在
`127.0.0.1:8710` 持有前台 server 子进程，先完成 typed `checkserver` 兼容性验证，再开放
UDS；因此不需要 DevEco Studio、Terminal 或另一个后台脚本托管 HDC。更新、卸载或登录会话
结束时，该子进程随 LaunchAgent 的进程组一起释放；ArkDeck 不修改系统级 HDC 或 `pmset`
配置。

指定另一份已签名 daemon bundle 可使用
`--daemon /absolute/path/to/ArkDeckAgent.app`。更新当前构建时运行：

```text
arkdeck runtime service update
```

HDC 路径变化时同时传 `--hdc /new/absolute/path/to/hdc`。

验证 daemon 进程重启与 Runtime 历史持久化时只走 CLI：先用 `agentd verify` 产生一个
`observe.device@1` Job，随后重启同一份已安装 helper，再按 Job ID 重开其状态、可信证据和
Artifact 清单：

```text
arkdeck runtime service verify --target <target-id> --json
arkdeck runtime service restart --json
arkdeck runtime service verify --job <observe-or-full-restore-job-id> --json
```

`restart` 不复制 helper、不重写 plist/install receipt，也不删除 Runtime state；它会拒绝 active、
等待人工或带 cleanup residue 的 current Job。已经 durable 终止的
`waitingForRecovery + outcomeUnknown` Job 不可能靠重启变成 known，restart 允许并在新 daemon 中逐一
核对它们仍原样保留，永不 replay。随后以不同进程 PID、相同 catalog digest 和新进程 UDS health
闭合结果。`verify --job` 对 `observe.device@1` 和已发布的 ArkForge full-restore operation 使用
各自固定的 effect、authority、必需 Step 与 Artifact profile；它仅调用 `health`、`job.status`、
`job.evidence` 与 `artifact.list`，不会 submit/run/cancel/reconcile Job，也不会产生设备 dispatch。
若 daemon 不健康、仍有活动或未闭合 Job，
历史 unknown 集合在重启中漂移，或既有 Job/Artifact 证据不完整，命令 fail closed，不回退到 App/UI。

要启用已合入的 ArkTrace typed analyzer profile，请把已审阅、版本化 ArkTrace
distribution 的 owner-controlled descriptor 交给同一个安装边界，而不是手工编辑 plist：

```text
arkdeck runtime service update \
  --arktrace-descriptor /absolute/path/to/distribution-descriptor.json
arkdeck operation list --json
```

安装器逐组件拒绝 symlink，要求 descriptor 及其祖先只能由当前用户或 root 控制、不可由
group/other 写入，并锁定 descriptor 的 SHA-256 和 byte count 到 install receipt/status。
`update` 未重述参数时只在 live bytes 与上次 install receipt 完全一致时保留当前选择，漂移时
必须显式重新选择；`--arktrace-descriptor none` 显式撤销。daemon 启动后仍会
执行 ArkTrace profile 自身更强的完整 distribution、Developer ID/notarization、tree、parser、
doctor 与 runtime drift 验证；operation 只有在这些检查全部通过后才会标为 available。

要让内置 WaterFlow ProjectProfile、workspace operations 和本地 analyzer 在关闭 Terminal 后
继续可用，安装时一次性传入两个受验证的绝对目录：

```text
arkdeck runtime service install --hdc /absolute/path/to/hdc \
  --workspace-project /absolute/path/to/WaterFlowLayoutDemo \
  --deveco-sdk /Applications/DevEco-Studio.app/Contents/sdk
```

两项必须同时出现；project 必须包含 `build-profile.json5` 与
`entry/src/main/module.json5`，SDK 必须包含 `default/openharmony`。安装器把现有
`demo-app` profile、SDK、`/usr/bin/grep` inspector 和同一已安装 daemon 的 analyzer 路径
固化进用户 LaunchAgent，并在 `status` 中检查配置漂移。`update` 未重述这两个参数时保留
已安装值的行为只冻结在 legacy `agentd update` 兼容拼写中。当前
`runtime service update` 未重述这两个参数时会移除这组 legacy LaunchAgent 注入；显式同时传入
两项仍可在兼容期重新选择。该迁移不会删除 `workspace project register` / `workspace preset
register` 管理的 Runtime-owned 资源，也不会从 `PATH`、当前目录或 Terminal 环境猜测替代值。

project 不得位于 `~/Desktop`、`~/Documents` 或 `~/Downloads`。这些目录由 macOS
隐私/TCC 按可执行身份授权：Terminal 中可读不代表独立 LaunchAgent 可读，后台枚举还可能
等待系统授权而无法返回。请先把工程放到例如
`/Users/your-name/Developer/WaterFlowLayoutDemo`，再把这个绝对路径传给 `install`/`update`；
无需管理员权限或 Full Disk Access。

### ArkDeck 默认的无 UI 本地签名

上游 [`deveco-cli`](https://gitcode.com/openharmony-sig/deveco-cli) 当前提供工程构建、运行、
设备与文档等 CLI 能力，但没有可复用的本地 HAP 签名或 Provision profile 生成表面。ArkDeck
不会为了补齐它而直接枚举 HDC、读取 raw UDID 或建立云账号侧的第二执行栈。

对标准 OpenHarmony 开发板，ArkDeck 首选官方 OpenHarmony SDK 随附的 release signing
bundle。安装器只读取显式的 canonical SDK/Java 绝对路径，在 owner-private 目录生成当前有效、
与 bundle name 精确绑定、无设备 UDID allowlist 的 release profile，用 SDK hapsigner 完成
`sign-profile` 和精确 `verify-profile` readback，再安装为现有唯一 closed preset
`openharmony-release@1`。整个维护步骤离线、不调用 HDC、不启动 DevEco Studio，也不把密码、
shell 字符串或 mutable SDK 路径交给 Runtime Job：

```text
arkdeck runtime signing install-sdk-release \
  --sdk /Applications/DevEco-Studio.app/Contents/sdk/default/openharmony \
  --java /Applications/DevEco-Studio.app/Contents/jbr/Contents/Home/bin/java \
  --bundle-name com.example.waterflowdemo \
  --project-ref demo-app \
  --json
arkdeck runtime signing status --json
```

ArkDeck 会复制并固定 SDK release keystore/profile material 的身份；SDK profile 模板只携带
application leaf，安装器会从同一份已测量的 SDK profile certificate bundle 组装完整的
root/application CA/application leaf 三证书链，避免 hapsigner 的 `11013004` 拒绝。SDK source
保持不变，托管副本权限为 `0600`、目录为 `0700`。SDK 共享 keystore 的官方口令本身是公开值；
ArkDeck 仍用 Data Protection Keychain 单信封记录其可逆安装事实，但 Runtime 不再为该公开值解密 Keychain，
而是在校验信封存在、receipt schema 与精确 daemon 二进制身份后，通过无回显 PTY 交给
hapsigner；它不进入 argv、环境、receipt 或日志。CLI 与 daemon 通过 provisioning profile
授权的同一 access group 访问该信封；daemon 更新只刷新独立的可执行文件身份收据，不读取或
替换 Keychain item，因此正常更新无需密码弹框。登录 Keychain 被锁定时 Runtime fail closed
且禁止弹 UI。

已有自有证书/Provision profile 的安装仍可使用兼容入口。keystore 必须属于当前用户且权限为
`0600`；两个密码只从真实 Terminal 的无回显 TTY prompt 输入，不接受 password flag、环境变量
或管道 stdin：

```text
arkdeck runtime signing install \
  --java /absolute/path/to/java \
  --jar /absolute/path/to/hap-sign-tool.jar \
  --keystore /absolute/private/path/release.p12 \
  --certificate /absolute/path/release.cer \
  --profile /absolute/path/release.p7b \
  --key-alias <alias> \
  --project-ref demo-app
arkdeck runtime signing status --json
arkdeck operation list --json
```

DevEco Studio 写入 `build-profile.json5` 的 `storePassword`/`keyPassword` 可能是 76 字符的
加密值。LaunchAgent 安装完成后，可让 ArkDeck 从受限的 build-profile 一次性迁移；它严格使用
profile 自己的 `storeFile` 同级 `material/` 做认证解密，把两个明文合并进一个 Data Protection
Keychain 信封。该 `storeFile`
必须存在、保持 owner-private，且内容身份与 ArkDeck preset 中已安装的 keystore 完全一致；
缺失、陈旧或指向另一 keystore 的 profile 会在改写 Keychain 前 fail closed：

```text
arkdeck runtime signing migrate-deveco \
  --build-profile /absolute/project/build-profile.json5 \
  --daemon "$HOME/Library/Application Support/ArkDeck/Helpers/ArkDeckAgent.app/Contents/MacOS/arkdeck-agentd" \
  --key-alias <actual-private-key-alias-if-profile-is-stale> \
  --json
```

`--key-alias` 是可选的非秘密修复参数：仅当 DevEco profile 中的 alias 已陈旧、而实际
PKCS#12 私钥 alias 已由只读诊断确认时提供。ArkDeck 会校验其闭合集合格式并原子更新 preset，
复用已有 Keychain 信封与 access group；错误 alias 仍会在签名时 fail closed 为 `keyAliasRejected`。

Runtime Job 此后不再读取 DevEco material，也禁止唤起 Keychain UI；Keychain 锁定或可信应用
身份漂移会立即 fail closed。私有 signing preset 继续只使用 Keychain。首次从旧版 file-based
Keychain 升级时，`agentd update` 会在显式维护边界读取旧信封并迁入 Data Protection Keychain，
最多可能要求一次 macOS Keychain 授权；之后 daemon 更新不再搬迁秘密。status 和 Runtime Job
永不弹框。若旧版 ArkDeck 已把密文原样存入两项 Keychain，可用上述命令迁移为单信封；`signing normalize` 仅保留给同一
keystore/material 布局的旧安装修复。两条命令都只报告迁移状态，不返回密码。

登录 Keychain 通常随用户登录自动解锁；若私有 preset 迁移返回 Keychain `-60008`，只在自己的
Terminal 执行一次 `security unlock-keychain "$HOME/Library/Keychains/login.keychain-db"`，不要把
密码放进 argv、配置或日志。SDK 默认 preset 的 daemon 更新不读取旧信封；私有 preset 只有在
旧式 access schema 存在时才进入一次显式维护读取。Runtime/status 始终使用禁止 UI 的
Data Protection Keychain 查询。未包装、未 provision 的 SwiftPM build 二进制不能访问生产信封。

`status` 显示非秘密路径、SHA-256、Keychain item 是否存在及漂移诊断，不返回也不解密密码，
因此健康检查不会触发 Keychain 授权。私有 preset 只在真实签名 Job 的 signer 启动前执行一次
禁止 UI 的 Keychain value read；读取失败即在任何 signer 副作用前 fail closed。daemon
在每次 Job 前重测 Java/JAR/keystore/certificate/profile；任一文件缺失、权限或摘要漂移，或
Keychain 不可读时，operation 都会 `UNAVAILABLE`/fail closed，不会猜 `PATH`、默认口令或
DevEco 安装位置。

安装 preset 后，本地签名也是 GJ-5 repair route 的默认方式：外部 agent 在 build 与
`debug.hap@1` 之间提交 `workspace.sign-openharmony-hap@1`，并把 verify-app 确认的
`signed.hap` lease 交给 debug。daemon 不会把 unsigned lease 当成已签名产物，也不会
跳过 Runtime 直接调用工具。下面的手动 typed sign 命令同样适用于诊断场景。

把 Hvigor 产生的 unsigned HAP 导入同一个 Runtime Artifact store，记录命令返回的 lease，
再用同一个 UDS 运行 typed sign（JSON 中只能出现这三个 published inputs）：

```text
arkdeck artifact import-hap --target <target-id> --file <unsigned.hap> --json

# signing-inputs.json
{
  "projectRef": "demo-app",
  "signingPresetRef": "openharmony-release@1",
  "unsignedHapArtifactLease": "<import 返回的 lease-v1:...>"
}

arkdeck agent run \
  --operation workspace.sign-openharmony-hap@1 \
  --target <target-id> \
  --inputs-file /absolute/path/to/signing-inputs.json \
  --json
```

只有 pinned hapsigner 的 `verify-app` 同时产出非空 certificate-chain/profile readback 后，Runtime
才发布 `signed.hap` 与 `signing-report.json`。signed lease 精确继承 unsigned lease 的 target、
binding revision 与 stable identity，然后作为现有 `debug.hap@1` 的 `hapArtifactLease` 输入；
设备重绑或 identity 漂移会在 HDC dispatch 前拒绝。锁屏后只要登录用户会话、LaunchAgent 和
Keychain 权限仍可用，这条签名→debug 路径不依赖 SwiftUI 或 Terminal 前台；Keychain 被锁定时
会如实失败，不弹出或伪造人工批准。

Runtime 不把 Artifact store 的无扩展名 payload path 直接交给 hapsigner，而是在 owner-only
attempt 目录复制为 `unsigned.hap`，复制前后校验同一 SHA-256/大小并在 spawn 前再次核对文件
身份；源 Artifact 与 lineage 不变。标准 `sign-app` 调用省略 `-signCode`（hapsigner 默认启用
code signing），非零退出只发布闭合的无秘密诊断码，并要求 typed reconcile 后才能释放 lane。

签名配置可逆撤销：

```text
arkdeck runtime signing remove --json
```

该命令删除 ArkDeck receipt、当前单一 Keychain 信封及 receipt 记录的旧版 secret。SDK release
默认方式还会删除 ArkDeck 的 owner-private 托管副本，但保留官方 SDK source；兼容手工安装则
保留操作者提供的原始 keystore/certificate/profile。
签名 lane 不调用 HDC；产物文件名、fake/simulation 或 `sign-app` exit 0 都不构成真机通过证明。

HarmonyOS 商用设备仍应使用其账号/UDID Provision 流程；OpenHarmony release profile 不是
绕过 HarmonyOS 授权的通用方案。无论哪一种签名来源，设备信任、签名身份和 profile 漂移都
必须 fail closed。

## CHG-2026-064:进程内决策平面已移除(操作者迁移注记)

`arkdeck task ...`、daemon 的 `task.*` 方法、`--sensitive-evidence` 与
`--harness-model-provider/--harness-model-name/--harness-cli/--harness-cli-timeout-seconds`
安装 flag 均已移除:有界调试循环由**外部 agent**(如 headless Claude Code / codex)
通过已发布的 job/artifact/workspace 面驱动,证据见
`openspec/changes/chg-2026-064-agent-native-decision-plane/evidence/runs/TASK-AND-002/`。

- **plist 迁移**:旧安装的 LaunchAgent env 若仍带 `ARKDECK_HARNESS_*` 网关键,
  运行一次 `arkdeck runtime service update` 即可再生成不含这些键的 plist(update 读取旧
  配置时会忽略并丢弃它们)。手工编辑保留这些键的 plist 会让 daemon 启动时
  具名 fail-loud(exit 78)。`ARKDECK_HARNESS_MODEL_*` 同样在这个列表里:
  `arkdeck agent chat` 已删除,仓内无人再读这些键,而旧 plist 里可能还躺着一枚
  API key——`agentd update` 会把它一并洗掉,这是升级到本版本后应当立即跑一次
  `update` 的实际理由。
- **历史数据**:daemon state 下的 `harness/` 私有 SQLite 目录不再被读取;
  保留在盘上作只读历史,操作者可自行删除。
- **存量隔离工作区**(CHG-2026-067):被合法修补过的 `evolution-*` 树在重启后
  由血统收养自动恢复;安静的树用已发布的
  `workspace.sweep-isolated-copies@1`(先 `dryRun: true` 复核 findings)清扫,
  审计元数据在摧毁后保留。
- **host-loop**:若本机曾安装 `com.arkdeck.host-loop.runtime` LaunchAgent
  (每 900 秒驱动一轮旧循环),它已无对象可驱动,建议
  `launchctl bootout gui/$UID/com.arkdeck.host-loop.runtime` 并删除其 plist。
