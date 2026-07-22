# BlueTool Loader 进态借鉴与 ArkDeck 对齐

> 证据类别：BlueTool 3.3.0 本地主机静态分析 + ArkDeck 现行 specs/code/evidence
> 对照。未运行 BlueTool，未连接或修改真实设备，device dispatch = 0。本文件描述 proposed
> design，不把 `hdc ... reboot loader` 在 DAYU200 上的可用性写成已验证事实。

## 1. BlueTool 的完整进态调用链

BlueTool 不模拟物理按键。其 RK3568/`dayu200` 路径按以下顺序工作：

1. `upgrade_tool.exe LD` 枚举设备，并解析 `VID/PID/LocationID/Mode`。
2. 刷机入口要求当前 RK 列表**恰好一台**，把该记录作为 `device` 传入后台任务。
3. 先检查 `.tar.gz` 存在并解压，再调用 `_get_loader_id(device)`。
4. 若 `device.mode == "Loader"`，显示“设备已处于Loader模式”，直接返回当前
   `LocationID`，不发送 HDC reboot。
5. 否则 `get_device_sn(device)`：
   - 枚举 Windows WMI `Win32_PnPEntity`；
   - 找第一个 `Name` 包含 `HDC Device` 且 `DeviceID` 包含原记录
     `VID_xxxx&PID_xxxx` 的项；
   - 取 `DeviceID` 最后一个反斜杠分量并转小写，作为 HDC target。
6. `_reboot_loader(sn)` 执行拼接字符串：

   ```text
   hdc -t <sn> shell reboot loader
   ```

   该函数有 20 秒函数级 timeout，命令返回后固定 `sleep(5)`。
7. 再执行一次 `upgrade_tool.exe LD`。只有结果恰好一台且 `Mode=Loader` 才返回新的
   `LocationID`；否则返回 `None`。
8. 调用方收到空值时抛出“进入Loader模式失败，请查看控制台信息！”，不会开始 `UL/DI`。
9. 成功后，全部后续命令都用 `-s <LocationID>` 寻址。

因此 BlueTool 的“免按键”只覆盖两个入口：设备**已经在 Loader**，或正常系统仍能通过
HDC 接收 `reboot loader`。设备未启动、HDC offline、命令不受固件支持时，它没有自动替代
物理按键的第三条通路。

## 2. 可借鉴点与 ArkDeck 对齐

| BlueTool 观察 | 可借鉴意图 | ArkDeck 对齐方式 |
| --- | --- | --- |
| 已在 Loader 时直接复用 | 避免无意义重启 | `ld` 严格确认 `2207:350a + Loader` 后把 `enterUpdater` 记为 `skippedSatisfied`，HDC mutation 0 |
| HDC 软件进入 Loader | 正常开机设备免物理按键 | 仅对具名、真机验证的 Profile 启用 typed `enterUpdater(providerOperationId=rockusb.enter-loader)`；固定 argv `[-t, connectKey, shell, reboot, loader]` |
| 先检查/解压镜像再切模式 | 缩短设备离线窗口 | ArkDeck 更严格：archive 全量流式校验、空间 claim、安全 staging、exact plan 和确认全部完成后才允许 E1 mode transition |
| 进态有独立阶段文本 | 用户知道正在切模式 | UI 显示 `Normal(HDC) → Switching → Waiting for RockUSB → Loader confirmed`，每一状态带时间和 typed reason |
| 命令设 timeout | 避免永远挂住 | 分离 command deadline、disconnect deadline、RockUSB reconnect deadline；全部来自 Profile pin，并进入 plan/journal |
| 重启后重新枚举 | 不假设 endpoint 跨模式不变 | bounded polling `rkdeveloptool ld`，直到 deadline；每次输出严格解析，不使用固定一次扫描 |
| Loader 后保留 LocationID selector | 后续命令明确指定目标 | LocationID 只作当前 RockUSB 寻址 key；写前还需 durable binding revision 与 identity evidence，不能把位置当身份 |
| 非 Loader 不继续刷 | mode gate fail closed | 只有 `2207:350a + Loader` 且 rebind 已 durable 确认，`ppt/wlx/rd` 才可 dispatch |
| 单设备约束避免明显串写 | 认识到歧义危险 | ArkDeck 允许显示多设备，但必须显式选中；0/多候选或证据不足进入 `awaitingRebindConfirmation`，不会用“现在只有一台”证明同一设备 |
| 后台线程 + UI busy | 避免重复启动和中途改输入 | Job actor + exclusive device mutation lane；运行后 target/image/mode 输入锁定，跨导航仍显示 Job |
| 时间戳阶段日志和 console | 可诊断进度 | 结构化阶段日志默认展示；有界 raw stdout/stderr 进入本地 Artifact，路径/serial 默认脱敏 |
| 进态失败给出明确错误 | 失败不静默 | typed failure：HDC unavailable、command rejected、disconnect timeout、RockUSB timeout、wrong mode、ambiguous candidate、binding mismatch |
| 刷机中提示保持连接 | 降低误操作 | 从进态前到 postflight 持有 power activity，并提示勿拔线/断电/合盖；不承诺系统一定不会 sleep |

## 3. 必须替换、不能照搬的点

| BlueTool 做法 | 风险 | ArkDeck 要求 |
| --- | --- | --- |
| WMI `VID/PID + HDC Device` 猜 SN | VID/PID 不是唯一身份，first match 可能串设备 | 使用已 durable 保存的 HDC `CurrentDeviceBinding`；不得从 UI 当前项或 WMI first match 临时派发 |
| HDC target 可能为空仍拼命令 | 可能命中错误/default target 或产生含混失败 | 缺 connectKey/binding/revision 时 command materialization 失败，process launch 0 |
| `shell=True` 字符串 | 引号/元字符解释和旁路 | executable descriptor + 固定 `[String]` argv；无 shell/PATH fallback |
| 不检查 HDC exit/语义 | 发出命令不等于设备已切换 | 记录 dispatch receipt；最终成功只由 HDC disconnect + 目标 RockUSB mode + rebind gate 共同确认 |
| 固定等待 5 秒、只扫一次 | 快慢设备和 USB 抖动误判 | 有界 polling + backoff + deadline；sleep/wake 进入 reconcile |
| 重启后“恰好一台 Loader”即原设备 | 无跨模式 identity 证明 | 使用 pre-transition serial/daemon fingerprint、USB topology、expected mode 等 Core evidence；不足时必须人工确认 identity diff |
| LocationID 当设备身份 | USB 拓扑变化/复用可误选 | 仅作为 connectKey；dispatch 前对 durable binding revision 和当前 observation 双复核 |
| 点击 Run 后直接切模式并刷 | 无独立 mode-transition 影响确认 | exact plan 中明确显示“设备将退出 HDC 并进入 Loader”；取消确认时 updater/flash dispatch 均为 0 |
| traceback 直接显示 | 可能泄露用户路径和内部细节 | typed 用户错误 + 受控 raw Artifact，默认日志脱敏 |
| 失败只有 console，无物理兜底 | HDC 不可用时用户无下一步 | UI 自动切到经真机验证的物理按键向导，并继续只读观察 mode gate |

## 4. ArkDeck 对齐后的三条入口

### Route A — already Loader

- `rkdeveloptool ld` = exactly selected `0x2207:0x350a Loader`；
- 持久化 Loader observation/binding；
- `enterUpdater` = `skippedSatisfied(alreadyInExpectedMode)`；
- HDC reboot dispatch = 0，继续 `ppt` precheck。

### Route B — software transition from HDC

仅当具名 Profile 的 E1 capability evidence 为 `supported` 时可选：

1. 从 durable HDC binding revision materialize exact `-t <connectKey>`；
2. exact plan、影响说明与用户确认包含 mode transition；
3. durable `stepIntent` 后执行 `hdc -t <connectKey> shell reboot loader`；
4. 记录 receipt，等待原 HDC endpoint 断开；
5. bounded polling `rkdeveloptool ld`，只接受 expected mode；
6. Core rebind policy 评估 pre/post evidence；
7. 强证据满足最低阈值时 durable 保存新 binding revision；否则展示 identity diff，等待用户
   确认；
8. 新 revision 落盘前 `ppt/wlx/rd` dispatch = 0。

### Route C — physical fallback

以下任一情况直接进入 fallback，不尝试“相似命令”：

- HDC offline、binding/connectKey 缺失；
- Profile 没有已验证的软件进态 capability；
- HDC command rejected/timeout，设备未断开；
- deadline 内未出现 Loader、出现 `0x5000`/Maskrom/未知 mode；
- 多个 Loader 或 identity evidence 不足且用户拒绝 rebind。

UI 展示已验证的 DAYU200 序列：按住 `VOL/RECOVERY` → 按下并松开 `RESET` →
`VOL/RECOVERY` 继续保持约 2–3 秒再松开。向导只负责提示和只读 `ld` 观察；不会假装 App
完成了物理动作。达到 `0x350a Loader` 后仍走同一 rebind/mode gate。

## 5. Proposed 状态机

```text
observing
  ├─ expected Loader ──────────────> loaderConfirmed
  ├─ verified HDC capability ──────> awaitingModeTransitionConfirmation
  │                                  -> transitionIntentDurable
  │                                  -> waitingForHDCDisconnect
  │                                  -> waitingForRockUSB
  │                                  -> evaluatingRebind
  │                                     ├─ strong evidence -> loaderConfirmed
  │                                     └─ ambiguous -> awaitingRebindConfirmation
  └─ HDC unavailable/unsupported ──> physicalFallback

any wrong/unknown mode, timeout, rejected confirmation or binding mismatch -> blocked
loaderConfirmed -> ppt precheck -> destructive flash steps
```

## 6. 真机 characterization 前不得宣称的事实

BlueTool 静态代码只能证明它**尝试**命令，不能证明当前 DAYU200 固件/ArkDeck macOS HDC
组合一定支持。`TASK-RKFUI-001A` 必须由维护者在具名 E1 窗口确认：

- exact HDC/firmware/build 是否接受 `shell reboot loader`；
- 命令 exit/stdout/stderr 与 HDC 断开时序；
- USB VID:PID/mode/topology 的逐时观察，是否直接到 `0x350a Loader`；
- normal HDC identity 与 Loader observation 能否达到 Core auto-rebind evidence 阈值；
- unsupported、`0x5000`、无设备、多个候选和 timeout 的真实分类；
- 软件路径失败后物理按键 fallback 是否仍能恢复到已验证 Loader 路线。

任一关键事实为 unknown/unsatisfied 时，产品默认 Route C；不得以 BlueTool 可用、设备型号
相似、当前只有一台或聊天确认替代硬件 evidence。
