# CHG-2026-026 Design — macOS Rockchip Flash UI

## Context and constraints

- Proposal revision：r3；r1 已由 PR #298 批准，r2 已由 PR #440 批准。r3 只修正
  discovery/destructive identity namespace 与 allowed paths，不改变 r2 tool values、
  TASK-RKFUI-001A D2 window 或 Core/AC/schema。r3 合入前对应实现 blocked，零 E1 dispatch。
- Core baseline：`CORE-2.0.0`，叠加实现开始时已批准并适用的 scoped delta。
- Related specs：flashing、desktop UX、device targeting、workflow journal/recovery、
  session/artifact/storage、macOS platform profile。
- Existing product seam：`RockchipRockUSBFlashProvider` + `RockchipFlashProfile` +
  `RockchipFlashAuthorizationGate` + `GzipTarArchiveReader` + `FoundationProcessExecutor` +
  App `NavigationSplitView`。
- BlueTool 是 non-authoritative UX reference；其 Windows 二进制和协议不成为依赖。

## Requirement mapping

| Requirement / AC | Design component | Verification |
| --- | --- | --- |
| REQ-FLASH-001 / AC-FLASH-001-01 | strict `rkdeveloptool ld` discovery parser + existing Provider probe | golden/fault contract |
| REQ-FLASH-002/003 / AC-FLASH-002-01/003-01 | machine observations + streaming archive validation before confirmation | contract + UI test |
| REQ-FLASH-004/005、REQ-UX-006 | plan-only application facade + persistent mode badge/plan Artifact | integration + UI test |
| REQ-FLASH-007、REQ-UX-005 | exact-plan sheet + digest phrase + userdata strong confirmation | UI/contract negative test |
| REQ-FLASH-008/009/011 | safe-boundary executor + power/storage claims + honest progress | fake process/fault tests |
| REQ-FLASH-010/015 | durable selected binding + interactive authority/standing gate | binding/authorization contract |
| REQ-DEV-001/002/003/006/008 | durable HDC original binding + typed mode transition + Core rebind + exclusive mutation lane | contract/fault + E1 characterization |
| REQ-FLASH-012/013 | semantic marker parser + reconnect postflight + RecoveryGuide | fake success/failure + real hardware |
| REQ-UX-001、REQ-I18N-001 | Flash page + global Job card + zh-Hans/en strings | XCUITest + localization lint |
| REQ-UX-007 | DeviceAccessAdvisor presentation; zero elevation/install calls | signed Sandbox E0 spike |

## Architecture and data flow

```text
FlashView / FlashViewModel (MainActor)
        |
        v
RockchipFlashApplicationFacade (actor, presentation values only)
        |-----------------------------|
        v                             v
Rockchip discovery adapter       Existing Provider/Profile
(selected tool + ["ld"])        (validate + typed exact plan)
        |                             |
        v                             v
FoundationProcessExecutor        Session/Journal/Artifact/Storage/Power
        |                             |
        +------ mode/rebind gate ------+
        |  Rockchip Loader transition |
        |  HDC typed argv + polling   |
        +---------- execute gate ------+
                         |
                         v
            Rockchip typed step executor
            ["ld"], ["ppt"], ["wlx", ...], ["rd"]
```

UI 只消费不可变 presentation 并发送用户意图，不拥有 executable、Process、journal writer
或 authorization bypass。production composition 在 Workflows facade 中注入受信任工具、
process executor、storage/power/binding/authorization ports；fixture composition 不得接收
真实路径或启动外部工具。

## Discovery and identity

1. 用户通过文件选择器选择 `rkdeveloptool`；App 持久化 app-scoped bookmark，并验证
   executable、version、SHA-256、platform trust。仅 pinned/approved family 可进入
   production discovery。
   r2 的 discovery successor 精确为 `rkdeveloptool ver 1.32` /
   `bbd7bdc0…9923` / upstream `304f0737…`；它必须在 registry、Swift adapter/tests 与
   signed probe 中原子采用。旧 `038a8a0e…3611` 继续属于既有 destructive
   Provider/Profile，r2 不让两个 identity 互相替代。
2. 只读 probe 使用绝对 executable URL 和 `arguments: ["ld"]`；不使用 PATH 或 shell。
3. parser 只接受注册 fixture family：`DevNo`、VID、PID、LocationID、Mode。整份 stdout
   必须被消费；重复 DevNo/location、字段缺失、未知 mode、截断或额外设备行均给出 typed
   diagnostic，而不是退化为空列表。
4. UI 可显示多台候选；用户必须选择一台。只有 `2207:350a + Loader` 可进入当前 Provider。
   Maskrom/其他 PID 仅显示 blocked reason。
5. normal/HDC 设备只能从已 durable 保存的 `OriginalTargetSnapshot` 与
   `CurrentDeviceBinding` 进入 software transition；UI 当前选择、WMI、VID/PID 或 HDC 默认
   target 均不能 materialize 命令。
6. execute 前重新运行 `ld`/HDC observation 并核对 selected observation、durable binding
   revision 和物理确认；LocationID 只能寻址，不能替代设备 identity。

### Identity namespace separation

r2 implementation preflight 证明现有 `RockchipDiscoveryIntegrationProfile.pinnedProduction`
被两条语义不同的 lane 共享：standalone E0 discovery 与 destructive Flash
admission/execution。直接改其 hash 会让 destructive manifest 从历史 pin 漂移。r3 固定如下
单向依赖：

```text
read-only discovery registry/probe
        -> Rockchip read-only discovery identity (bbd7…9923, ["ld"])

destructive Flash Profile
        -> Rockchip Flash toolchain identity (038a…3611)
        -> authorization / execution / manifest validation
```

- read-only discovery source 不再承载或导出 destructive hash；canonical registry、fixture、
  Swift adapter、Python harness 与 Sandbox probe app 必须一致。
- destructive identity 的唯一 Workflows source 位于 `RockchipFlashProfile.swift`；它保留现有
  profile identifier、reported version、hash 与 path source。authorization/execution 只能
  引用该 source，不得借用 discovery default。
- destructive lane 为确认既有工具/Loader observation 而执行的 `ld` 使用 Flash toolchain
  identity；它不是 standalone E0 discovery successor，也不能让 clean discovery hash 获得
  `ppt/wlx/rd` authority。
- `ArkDeckStorage` locked manifest validator 保持独立、只读且继续固定旧 destructive hash，
  防止 Workflows 常量误改被同层自证。
- regression 必须同时证明 discovery closure 无旧 pin、destructive closure 无新 pin，并跑
  完整 Swift suite；仅跑 discovery 定向测试不足以关闭该边界。

## Enter Loader routes and rebinding

完整逐项对齐见 `loader-entry-alignment.md`。产品提供三条明确路线：

1. **Already Loader**：严格 `ld` 已是 selected `0x2207:0x350a Loader`，typed
   `enterUpdater` 记录为 `skippedSatisfied`，HDC dispatch 0。
2. **Verified software transition**：只有 `TASK-RKFUI-001A` 对 exact
   device/firmware/HDC/tool combination 形成 E1 supported evidence 后启用。现有 Provider
   `enterUpdater(providerOperationId=rockusb.enter-loader)` 由专用 adapter 映射为 executable
   descriptor + `[-t, <durable-connect-key>, shell, reboot, loader]`。命令没有 caller argv、
   shell 或默认 target 面。
3. **Physical fallback**：HDC unavailable/unsupported、transition/reconnect 失败或 identity
   歧义时，UI 展示 CHG-2026-016 已验证按键序列，并继续只读观察 `ld`。App 不把提示记为
   自动执行。

r2 修正 characterization 顺序：001 的 parser/adapter contract 已合入，但其 E0 hardware
receipt 需要先得到 Loader。维护者选择 Route B 作为本轮 Loader 来源，因此 001A 可在 001
最终 `done` 前先执行一次具名 E1；成功后 001 的 signed Sandbox probe 仍须独立运行并生成
自己的 receipt。001A 的 command/USB observation 不会被复制或重分类为 001 E0 PASS。

软件路线顺序固定为：

1. archive 全量校验/staging、exact plan、影响说明和用户确认全部完成；
2. 获取 device mutation lane/power activity，persist `enterUpdater` intent + binding revision；
3. typed HDC command dispatch 并保存 receipt；
4. 等待原 HDC endpoint disconnect；
5. 在 Provider deadline 内 bounded poll `rkdeveloptool ld`，解析每个 observation；
6. 用 pre-transition serial/daemon fingerprint、USB topology、expected mode 等 evidence 运行
   Core rebind policy；
7. 自动 threshold 满足则 durable 保存新 binding revision；证据不足则进入
   `awaitingRebindConfirmation` 展示 diff；
8. 新 revision 和 `0x350a Loader` mode gate 均 durable 后才进入 `ppt`。

固定 `sleep(5)`、只扫一次、取唯一 Loader、LocationID 即 identity 都被禁止。command
deadline、disconnect deadline、reconnect deadline 分开记录；任何 timeout/wrong mode/multiple
candidate 均不开始 destructive step。

## Archive and plan

- 用户选择本地 `images.tar.gz` 后，在 background task 中流式计算 archive/member hash；
  security-scoped access 生命周期由 facade 管理。
- 只调用 `RockchipFlashProfile.dayu200.validate` 和 Provider `makePlan`；validation blocked 时
  plan-only/execute 都不可宣告 planned/succeeded。
- UI 展示 Provider/Profile、selected device evidence、tool identity、archive path（UI 可见，
  日志脱敏）、archive hash/size、九分区/成员 hash、userdata data impact、全部 typed steps、
  plan/step-set digest 与 execution-mode badge。
- plan-only 生成 owned Session 和 plan Artifact，所有 mutation/destructive step 标为
  `notExecuted(planned)`；finalization 失败则 Job failed。

## Execute gate and executor

执行顺序固定为：

1. 刷新 tool/device/binding/archive facts；任何漂移使旧 plan/confirmation 失效。
2. 取得 device mutation lane、host storage claim 和 power activity。
3. 机器确认 recoveryPath/unlocked 与 software-transition capability；unknown/unsatisfied 在强
   确认前阻断相应路线，仍可选择 physical fallback。
4. 展示 exact plan；要求 `FLASH <digest12>` 与 `ERASE-USERDATA` 两个可访问确认控件，并明确
   normal 设备将退出 HDC、进入 Loader。
5. `RockchipFlashAuthorizationGate` 复核 authority、binding、plan、prerequisites 和确认载体。
6. 安全解包九个已验证成员到 owned Session staging；逐文件 hash 与 Profile 再比对，不接受
   path traversal、symlink/hardlink/device entry、duplicate name 或 trailing payload。
7. 执行 `enterUpdater`：already Loader 则 skip；verified HDC route 则走 durable typed command +
   disconnect/poll/rebind；否则进入 physical fallback，Loader mode gate 未满足时暂停。
8. executor 仅从 typed steps 映射固定 argv：
   - `ld`
   - `ppt`
   - `wlx <partition> <owned-absolute-image-path>`（九次）
   - `rd`
9. 每个外部副作用前 journal `stepIntent` 并 fsync；完成后记录 stdout/stderr raw Artifact、
   executable identity、exit、语义 marker 和 `stepOutcome`。
10. `wlx` 为 criticalNonInterruptible。用户取消/退出只设置 durable pending-cancel，当前写完成
   后停止下一步；Process 不在 critical write 中 force kill。
11. `rd` 后执行 bounded reconnect/postflight；只有九写、reset 和 postflight 语义全部确认才
    succeeded。否则 failed/waitingForRecovery/outcomeUnknown，并展示 Provider RecoveryGuide。

任何执行均不得通过字符串 handoff 再交给 shell。`RockchipHumanHandoff.commandLines` 仅供人类
可读显示，不是 executor 输入。

## Data and contract changes

- locked Core schema：无变化。
- 新增内部 presentation/device observation/parser diagnostic 类型；持久字段只使用现有
  journal/manifest contract 能表达的值。
- 新增 Rockchip Loader transition capability registry/receipt/presentation；复用现有
  `enterUpdater` schema，不增加 step kind。若现有 journal 不能表达 transition/rebind evidence，
  implementation 立即 blocked，不自行扩 schema。
- 新增版本化 RockUSB `ld` fixtures/registry，pin `rkdeveloptool` family/version/hash 与 exact
  argv。若需要扩展未知输出 family，必须走 integration revision，不在 parser 中宽松接受。
- r2 discovery identity revision 只修改 read-only `ld` registry family，不修改
  `RockchipFlashProfile.pinnedToolchainFingerprint`、destructive authorization 或既有硬件
  support matrix。后续 execute 若要采用新 build，必须另行 readiness/change 并重新验证
  Provider 全命令面。
- 安全解包产物是 Session-owned staging，不是 raw Artifact 的原地修改；archive raw 保持
  不变，成员来源/hash 可追溯。

## Failure, cancellation, and recovery

- tool missing/untrusted/quarantined/permission denied：零 probe 或零 mutation（取决于失败
  阶段），显示 typed remediation owner；不自动修复系统。
- device list malformed/multiple-selection stale/identity mismatch：清除旧确认，重新 preflight。
- HDC unavailable/unsupported：选择 physical fallback；typed command rejected、原 endpoint 未
  断开、deadline 内无 `0x350a Loader`、出现 `0x5000`/Maskrom/未知 mode 或多候选：保留
  receipt/observations，进入 blocked/fallback，flash dispatch 0。
- normal→Loader evidence 达不到 Core auto-rebind threshold：进入
  `awaitingRebindConfirmation`；拒绝/未确认时后续 mutation 0。
- archive drift/corrupt/path traversal/space claim failure：confirmation 前阻断。
- app crash before intent：该 step 未 dispatch；intent 无 outcome：destructive outcomeUnknown，
  绝不自动重放。
- disconnect/sleep/wake：journal event + reconcile；不从 exit 0 或重新出现相似设备推断成功。
- cancellation during `wlx`：延迟到 safe boundary；取消后不开始下一分区。
- postflight failure：非 succeeded，保留 device hazard 和 CHG-2026-016 RecoveryGuide。

## Security and privacy

- 禁止 `sudo`、shell、AppleScript、Authorization Services、helper/driver 自动安装、ACL/group/
  rule 修改、quarantine 清除和 tool 自动下载。
- 仅持久化 bookmark、工具/镜像 hash、脱敏 device/location 标识和关联 ID；原始用户路径、
  serial、业务字符串不进默认日志/evidence。
- BlueTool 资源不复制进 repo，不用其 bundled 8G uboot，不执行其网络/API 路径。
- 所有 raw output 本地保存且有界；导出仍需用户主动预览。

## Alternatives and ADRs

- **复制 BlueTool/upgrade_tool**：拒绝。Windows-only、供应链/许可证未知，且协议与已验证
  Provider 不同。
- **App 调 shell/sudo 脚本**：拒绝。违反 typed argv、权限和审计边界。
- **UI 直接包装 `arkdeck flash` CLI**：拒绝。当前 CLI 以文本 handoff 为终点，不提供
  Session-owned typed executor，也会形成文本解析旁路。
- **BlueTool 式 HDC reboot 后取唯一 RockUSB**：拒绝其 identity 规则；接受软件进态产品目标，
  但必须先有具名 E1 evidence，并走 durable typed intent、bounded polling 和 Core rebind。
- **只保留物理按键**：作为可靠 fallback 保留，不作为唯一产品路径；已验证软件进态组合
  默认可从同一 Start Job 流程进入 Loader。
- **先交付 plan-only UI**：接受为分阶段交付；execute 仍以 E0 non-elevated USB access 和
  `REQ-FLASH-015` 审查为硬前置，不把 plan-only 宣称为一键真机刷机完成。

若 signed Sandbox 内直接运行外部 `rkdeveloptool` 需要新的 helper/entitlement/分发决策，
必须新增 ADR/change；本 design 不隐含授权。
