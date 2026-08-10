# macOS 无头设备 Runtime

`arkdeck-agentd` 可作为当前登录用户的 LaunchAgent 常驻运行。它继续使用同一个
Runtime、用户私有 Unix socket 和只读 XPC 门；不需要管理员权限，也不会建立第二套
HDC 执行路径。

## 首次准备与安装

1. 安装 DevEco/OpenHarmony 工具，并在设备侧完成一次 USB 信任。需要系统授权时先在
   登录用户会话中完成；LaunchAgent 不绕过 macOS 或设备授权。
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
