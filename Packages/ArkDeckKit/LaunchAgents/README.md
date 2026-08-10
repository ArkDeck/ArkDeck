# macOS 无头设备 Runtime

`arkdeck-agentd` 可作为当前登录用户的 LaunchAgent 常驻运行。它继续使用同一个
Runtime、用户私有 Unix socket 和只读 XPC 门；不需要管理员权限，也不会建立第二套
HDC 执行路径。

## 首次准备与安装

1. 安装 DevEco/OpenHarmony 工具，并在设备侧完成一次 USB 信任。需要系统授权时先在
   登录用户会话中完成；调试 HAP 还必须把当前设备 UDID 加入其签名 profile。刷入新系统后
   若包管理器报告 `9568423`，应重新完成设备授权并重新签名/构建 HAP。LaunchAgent 不绕过
   macOS、设备信任或应用签名授权。
2. 构建 `arkdeck` 与 `arkdeck-agentd`，确认 HDC 的真实绝对路径。不要传目录、相对路径
   或依赖 `PATH`。
3. 从同一构建目录运行：

   ```text
   arkdeck agentd install --hdc /absolute/path/to/hdc
   arkdeck agentd status
   arkdeck doctor
   ```

`install` 会验证并哈希 daemon/HDC，把 daemon 复制到
`~/Library/Application Support/ArkDeck/bin/arkdeck-agentd`，生成
`~/Library/LaunchAgents/com.arkdeck.agentd.plist`，再用 `gui/$UID` 启动服务。plist
明确传入 `ARKDECK_HDC_PATH`；Runtime 在启动时固定 HDC 摘要，并在每次 spawn 前重新验证
文件身份，缺失或漂移都会 fail closed。

指定另一份 daemon 可使用 `--daemon /absolute/path/to/arkdeck-agentd`。更新当前构建时运行：

```text
arkdeck agentd update
```

HDC 路径变化时同时传 `--hdc /new/absolute/path/to/hdc`。

要让内置 WaterFlow ProjectProfile、workspace operations 和本地 analyzer 在关闭 Terminal 后
继续可用，安装时一次性传入两个受验证的绝对目录：

```text
arkdeck agentd install --hdc /absolute/path/to/hdc \
  --workspace-project /absolute/path/to/WaterFlowLayoutDemo \
  --deveco-sdk /Applications/DevEco-Studio.app/Contents/sdk
```

两项必须同时出现；project 必须包含 `build-profile.json5` 与
`entry/src/main/module.json5`，SDK 必须包含 `default/openharmony`。安装器把现有
`demo-app` profile、SDK、`/usr/bin/grep` inspector 和同一已安装 daemon 的 analyzer 路径
固化进用户 LaunchAgent，并在 `status` 中检查配置漂移。`update` 未重述这两个参数时保留
已安装值；不会从 `PATH`、当前目录或 Terminal 环境猜测。

project 不得位于 `~/Desktop`、`~/Documents` 或 `~/Downloads`。这些目录由 macOS
隐私/TCC 按可执行身份授权：Terminal 中可读不代表独立 LaunchAgent 可读，后台枚举还可能
等待系统授权而无法返回。请先把工程放到例如
`/Users/your-name/Developer/WaterFlowLayoutDemo`，再把这个绝对路径传给 `install`/`update`；
无需管理员权限或 Full Disk Access。

Harness 默认不读取 sensitive Artifact。GJ-5/debugCrash 的成功标准需要本机读取
`crash-index.txt`（需要分析 HiLog 时再加入 `hilog.txt`），因此必须由操作者明确把所需的
Artifact basename 固化到 LaunchAgent：

```text
arkdeck agentd update --sensitive-evidence crash-index.txt,hilog.txt
```

该设置只允许同一 daemon 内的 Harness 按 Artifact ID 读取这些精确名称；不会允许任意路径、
不会开启 Artifact 导出，也不会开启模型网络 egress。`status --json` 与安装收据会显示并核对
这份排序后的 allowlist。使用
`arkdeck agentd update --sensitive-evidence none` 可撤销；默认值和撤销后均为空。无需 sensitive
证据的任务不应启用此项。

## 锁屏运行与诊断

在登录用户仍处于登录状态时，CLI 或 Agent 可继续通过默认 socket 提交 published typed
operation；SwiftUI 窗口和 Terminal 都可关闭。锁屏和显示器熄灭不终止 LaunchAgent。真实
Job 执行期间 Runtime 仅持有 idle-system-sleep assertion：它允许锁屏和显示器熄灭，不修改
`pmset`，也不阻止合盖或用户主动睡眠。

```text
arkdeck agentd status --json
arkdeck operation list
arkdeck agentd verify --target <target-id> --json
```

状态命令会核对 plist、launchd load 状态、daemon/HDC 当前 SHA-256、安装收据、socket 和
daemon health。`verify` 进一步固定走完整的无头产品链：identity-checked LaunchAgent → 默认
用户私有 UDS → native Agent executor → published `observe.device@1` → daemon-owned terminal
receipt → immutable Artifact inventory 与 Runtime postflight。它不接受自定义 socket、raw HDC、
argv 或 capability 管理参数；多台已采用设备时必须显式传 `--target`，不会猜测设备。
显式 target 只会使用 daemon 当前 `device.candidates` 中与该 durable target 精确关联的唯一
transport face；Flash 后的 HDC 地址变化也必须已有 Runtime 写入的完整 alias proof。映射缺失
或歧义时命令会要求重新连接且不创建 Job，不会把其他设备的 connect key 当作可选捷径。
daemon 启动时会先恢复 durable Job；更新后第一次 `status` 若只报告 socket 尚未出现，可再次
运行 `status`，持续不就绪再查看错误日志。

`runtimeVerified: true` 只表示该次 Runtime receipt、Artifact 和 postflight 机械闭合。仓库中的
fake/simulation 测试仍不得据此声称真实硬件通过；只有命令确实连接真机时，才可把脱敏 target、
Job、时间与 Artifact hash 如实记录为真实设备证据。需要运行其他已发布 typed operation 时，
仍使用同一个 native Agent 入口，例如：

```text
arkdeck agent run --operation capture.diagnostics@1 --target <target-id> \
  --inputs-file <typed-inputs.json> --json
```

日志位于：

```text
~/Library/Logs/ArkDeck/agentd.log
~/Library/Logs/ArkDeck/agentd.error.log
```

服务只属于 Aqua 登录会话；本说明不声称登出后、重启后的登录前阶段或合盖睡眠期间仍能
执行设备 Job。

## 卸载

```text
arkdeck agentd uninstall
```

卸载会 bootout 当前用户服务并删除生成的 plist、已安装 daemon 和身份收据。为避免误删
诊断或运行历史，`~/Library/Application Support/ArkDeck/Agentd` 与日志目录会保留，并在
命令结果中明确报告其路径。
