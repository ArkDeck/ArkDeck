# CHG-2026-026 Design — macOS Rockchip Flash UI

## Context and constraints

- Proposal revision：r9；r1-r8 已由维护者 merge。r9 接受 001F read-only bookmark
  metadata PASS，但不把它推断为 v1 product-entitlement external-process PASS；新增
  TASK-RKFUI-001G，以 inert external fixture 验证 exact product six-entitlement +
  read-only bookmark 的 canonical child-launch boundary。
- r9 不改变 typed operation、target/firmware/transport、discovery binary
  version/hash/upstream、binding、window、maxRuns、rebind 或 Safety 设计；HDC server 仍
  必须是 pre-existing external same-UID pinned executable，Agent server lifecycle mutation
  为 0。pre-existing RockUSB candidate 是独立 physical/identity gate，不因 provenance
  closure 被过滤或放行。r9 不修改 App/ADR/platform/registry/product code，也不运行真实
  tool、USB 或 device command。
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
| REQ-UX-007 | DeviceAccessAdvisor presentation; zero elevation/install calls | signed Sandbox E0 + r7/r8 bookmark + r9 external-fixture launch characterization |

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
   r7 不把 PR #509 的 symlink selection metadata transition 解释为 canonical-path 事实；
   001E 仅在 disposable wrong-hash fixture 上隔离 `user-selected.read-only` 这一变量，
   其结果不替代真实 pinned tool 或产品 App evidence。
   r8 同样不把 #512 bookmark failure 归类为真实 tool failure；001F 仅在同一 disposable
   read-only candidate 上验证 Apple-documented bookmark creation option。
   r9 把产品选择边界收紧为 canonical regular file，不允许 symlink/alias product
   selection；001G 先以 wrong-hash control 验证 exact product entitlement 下 metadata
   不变，再允许一个 task-local compiled-hash inert fixture 进入一次固定 child launch。
2. r6 loader-transition probe 从受保护 `main` 的 registry 读取 typed
   `sourceProvenance`。该对象把 exact `bbd7bdc0…9923`、`304f0737…`、source acceptance
   `PR#445@cbad982…` 和 reviewed evidence path/SHA-256 绑定为一个不可分 tuple。probe
   同时验证顶层 tool tuple 与 provenance tuple 完全一致、evidence bytes 命中；它不把
   executable parent、安装前缀、附近 `.git` 或 live checkout HEAD 视为 artifact source。
3. 只读 probe 使用绝对 executable URL 和 `arguments: ["ld"]`；不使用 PATH、shell 或
   `/usr/bin/git`。binary version/hash、ad-hoc signature 与 quarantine absent 仍须 runtime
   精确验证，source provenance closure 不替代这些 artifact/trust checks。
4. parser 只接受注册 fixture family：`DevNo`、VID、PID、LocationID、Mode。整份 stdout
   必须被消费；重复 DevNo/location、字段缺失、未知 mode、截断或额外设备行均给出 typed
   diagnostic，而不是退化为空列表。
5. UI 可显示多台候选；用户必须选择一台。只有 `2207:350a + Loader` 可进入当前 Provider。
   Maskrom/其他 PID 仅显示 blocked reason。
6. normal/HDC 设备只能从已 durable 保存的 `OriginalTargetSnapshot` 与
   `CurrentDeviceBinding` 进入 software transition；UI 当前选择、WMI、VID/PID 或 HDC 默认
   target 均不能 materialize 命令。
7. execute 前重新运行 `ld`/HDC observation 并核对 selected observation、durable binding
   revision 和物理确认；LocationID 只能寻址，不能替代设备 identity。

## r7 signed Sandbox selection characterization

001E 使用现有 Probe 的 preflight ordering，但 selected fixture 永远不能进入 child
execution。实验保持 App source、Hardened Runtime、bundle ID 与其余五项 entitlement 不变，
只替换 user-selected file entitlement：

```text
control (#509): user-selected.read-write
r7 candidate:  user-selected.read-only
forbidden:     user-selected.executable
```

fixture 在 private temp 从可审查 inert source 构建，basename 为 `rkdeveloptool`，ad-hoc
签名且无 quarantine；其 byte hash 必须与 registry pin 不同。host 在 App launch 前记录
target hash/signature/quarantine boolean；App 只执行 `NSOpenPanel`、security-scoped bookmark
round-trip 和现有 hash/signature/quarantine preflight。hash mismatch 必须终止流程，固定
`["ld"]` adapter 不得到达 Process。

两个 fresh App run 不共享 bookmark/container-derived selection state：

1. 直接选择 fixture canonical URL；
2. 选择 private-temp 单层 symlink，且 resolving-symlinks 后精确指向同一 fixture。

host 在每次退出后重新核验 target bytes/signature/quarantine；symlink 自身另记 semantic
boolean。receipt 不保存 locator 或 raw xattr。只有两个 run 都满足 bookmark/scope 成功、
target quarantine 前后 absent、`executableHashMismatch`、child/USB/device/network 0，
characterization 才 PASS。该 PASS 只为后续 D1 提供输入，不能证明真实 external executable
执行、PowerBox extension 跨进程转移、ArkDeckApp read-write shape 或产品 broker/helper。

## r8 read-only bookmark option remediation

#512 证明 PowerBox selection extension 已取得（两个 run 均
`securityScopeStarted=true`），但现有 creation call 只使用 `.withSecurityScope`，在
bookmark creation/resolution catch 内失败，未到 fixture hash gate。Apple 将
`.withSecurityScope` 定义为 read/write bookmark；对后续不需写入的资源，文档要求同时
包含 `.securityScopeAllowOnlyReadAccess`。因此 001F 验证下列单变量假设：

```text
#512 candidate creation: [.withSecurityScope]
r8 candidate creation:   [.withSecurityScope, .securityScopeAllowOnlyReadAccess]
resolution (unchanged):  [.withSecurityScope, .withoutUI]
```

这是平台 API hypothesis，不是 root-cause 结论。由于 #512 按 fail-only boundary 未合入
candidate code，001F implementation 从 current main 重新应用 read-only entitlement 与
fixture harness，但行为差异必须严格等于新增 creation option。其他五项 entitlement、
Hardened Runtime、bundle ID、signature/hash/quarantine ordering、fixed `["ld"]` adapter
均不变。允许拆分 bookmark creation 与 resolution error stage，只输出稳定 stage、
Foundation error domain/code；message、path、locator、bookmark bytes 不得进入 receipt。

两个 fresh App run 仍为：

1. picker 内 exact canonical fixture entry；
2. picker 内 host-proven one-layer symlink entry，launch 前证明它解析到同一 fixture。

`NSOpenPanel` 可返回 canonicalized URL；receipt 必须分别记录 picker input link semantic、
returned URL lexical-match boolean 与 resolving 后 target equality。lexical preservation
不是 PASS gate，resolving 后 exact target equality 才是 identity gate。两个 run 都必须
bookmark creation/resolution/scope 成功，App 观察到 same wrong hash、valid signature 与
quarantine absent，随后以 `executableHashMismatch` 在 Process 前停止；host pre/post
target bytes/CDHash/signature/quarantine 不变，所有 selected-process/external/device/
network/mutation counters 为 0。

001F PASS 仍只是一条 host-only platform evidence：它不证明 bookmark extension 可传给
其他进程、不证明真实 external executable 可启动或访问 USB，也不决定 main App
read-write output entitlement 与产品 broker/helper。

## r9 v1 product-entitlement external-fixture launch characterization

v1 分发决定与 current App 都固定以下六项 entitlement：

```text
com.apple.security.app-sandbox
com.apple.security.device.serial
com.apple.security.device.usb
com.apple.security.files.bookmarks.app-scope
com.apple.security.files.user-selected.read-write
com.apple.security.network.client
```

001F 的 `user-selected.read-only` Probe 因而不是 product-shape launch evidence。Apple
macOS App Sandbox 文档也说明 user-selected file entitlement 不能被假定为运行 App
bundle/container/app-group 外程序的授权。001G 以二阶段 closed gate 验证这一边界，不先
引入 helper/broker、bundle/copy 或真实 tool：

1. **Product-shape metadata control**：fresh App 使用 exact product six entitlements 与
   001F 的 creation/resolution options，picker 内只有一个 canonical regular-file fixture。
   App 仍 pin production tool hash，所以必须以 `executableHashMismatch` 在 Process 前
   停止。selection/bookmark/scope、App/host quarantine absent 与 pre/post bytes/CDHash/
   signature unchanged 全部 PASS，才可进入第二阶段。
2. **Task-local inert launch**：fresh fixture 从 reviewable `return 0` source 构建，
   deterministic/no UUID、ad-hoc signed、quarantine absent；fresh App 在编译期绑定该 exact
   fixture hash，运行时不接受 caller hash/path/argv/environment。选择同样只允许 canonical
   regular file，bookmark options 不变，唯一 child argv 固定为 `["ld"]`。

launch receipt 必须显示 `childLaunchAttempted=true`、`termination=exited`、
`exitCode=0`、stdout/stderr size 0，且 target pre/post metadata 不变。fixture linked
libraries/imported symbols 必须排除 libusb、IOKit、network 与 shell；selected fixture
process/fixture-`ld` 计数各为 1，真实 `rkdeveloptool`、USB/HDC/device/network/E1/E2/
mutation/destructive/privilege/helper/install/system/xattr-write 计数全部为 0。

Stage A failure 时 Stage B 不构建/不运行。Stage B launch error、quarantine transition、
非空 output、timeout/nonzero exit 或 metadata drift 都是有效 fail-closed platform
evidence；candidate implementation 不保留，也不自动尝试 symlink、entitlement 扩权、
copy 或 helper。全 PASS 也只证明 exact host tuple 的 inert external process，不证明真实
tool/USB 或 product delivery。后续仍需独立 D1 + fresh exact non-quarantined artifact
批准真实 E0。

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
- r6 只在 loader-transition registry 增加 typed
  `protectedMainArtifactDigestToUpstreamCommit` provenance closure；artifact SHA-256、
  upstream commit、source acceptance 与 evidence path/SHA-256 任一缺失、不一致或漂移，
  均在任何 `ld`/USB/device command 前 blocked。该对象不是新 artifact repin，也不改变
  rockusb-discovery registry、destructive Provider/Profile 或 Core schema。
- r4 line-termination revision 仅登记 complete stdout 的 homogeneous LF 与 homogeneous
  CRLF 两种 family。parser 必须先在 raw bytes 上确认末尾 terminator、全输出同族与完整
  消费，再把 CRLF record 的单个 CR 去掉并复用同一 record grammar；bare CR、mixed
  LF/CRLF、missing-final-terminator、empty record 与其他额外字节继续 blocked。该
  normalization 不改变 VID/PID/mode 或 candidate 数量，Maskrom 仍是明确的 wrong-mode
  observation。
- r7 不修改 registry、Swift discovery adapter、locked schema 或 executable identity。它只
  允许 signed E0 Probe 的 entitlement expectation 做一项替换：
  `user-selected.read-write` → `user-selected.read-only`，并以 host-only wrong-hash
  fixture 验证 PowerBox/bookmark/quarantine metadata。fixture hash mismatch 必须先于任何
  child/USB/device access 生效；characterization receipt 是 platform evidence，不是
  realHardware 或 product-delivery evidence。
- r8 仍不修改 registry、production adapter、schema 或 executable identity。它只允许
  001F 在 #512 read-only candidate 上把 bookmark creation options 精确扩为
  `[.withSecurityScope, .securityScopeAllowOnlyReadAccess]`，resolution options 保持不变；
  stage-specific bookmark diagnostic 只增加 sanitized observation，不增加持久 contract。
- r9 仍不修改 registry、production adapter、schema、ADR、platform profile 或 real-tool
  identity。001G 的 task-local fixture hash 只存在于 host-only build/receipt closure，
  必须明确 `pinnedRegistryHashMatched=false`，不得写入 Rockchip discovery registry、
  Provider/Profile 或任何产品 tool allowlist。
- r2 discovery identity revision 只修改 read-only `ld` registry family，不修改
  `RockchipFlashProfile.pinnedToolchainFingerprint`、destructive authorization 或既有硬件
  support matrix。后续 execute 若要采用新 build，必须另行 readiness/change 并重新验证
  Provider 全命令面。
- 安全解包产物是 Session-owned staging，不是 raw Artifact 的原地修改；archive raw 保持
  不变，成员来源/hash 可追溯。

## Failure, cancellation, and recovery

- tool missing/untrusted/quarantined/permission denied：零 probe 或零 mutation（取决于失败
  阶段），显示 typed remediation owner；不自动修复系统。
- 001E read-only direct/symlink selection 任一 bookmark/scope 失败、选择前后 quarantine
  metadata 改变、fixture 意外命中 pinned hash、child launch 非零或 receipt 泄漏 locator：
  characterization blocked；不提交 entitlement substitution，不升级到
  `user-selected.executable`，不接触真实 tool/device。
- 001F canonical/symlink 任一 bookmark creation/resolution/scope、resolved target、
  App/host quarantine、wrong-hash 或 zero-counter gate 失败：remediation blocked；不保留
  entitlement/API change，不回退 implicit-only access，不扩大 entitlement，也不接触真实
  tool/device。symlink lexical URL 未保留本身只作 observation，不单独构成失败。
- 001G Stage A 任何 selection/bookmark/canonical-target/quarantine/wrong-hash/metadata
  gate 失败：Stage B dispatch 0。Stage B 任何 hash/signature/quarantine、fixed argv、
  exited/0/empty-output 或 pre/post metadata gate 失败：characterization blocked；不重试、
  不切 symlink、不改 entitlement、不复制/下载/重建真实工具，也不进入 USB/device。
- loader-transition source provenance missing/unknown kind、tuple/evidence drift：在
  `ld`/USB/binding/intent 前 fail closed；不回退到 executable parent HEAD，不通过相同
  version/hash 之外的第二 pin，也不在线获取或构建 replacement。
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
- r7/r8/r9 还禁止 `LSFileQuarantineEnabled`/excluded-path 配置、
  `com.apple.security.files.user-selected.executable`、fixture/pinned-tool xattr 写入、
  复制/重建 pinned artifact 规避 assessment，以及修改
  `ArkDeckApp/ArkDeckApp.entitlements`。001E/001F 的 disposable fixture 可在 private temp
  目录确定性构建并 ad-hoc sign；001G Stage A 仍禁止 fixture 执行，Stage B 只允许同类
  `return 0` fixture 的一次 fixed-argv launch，且永不冒充 registry tool。
  document-scope、implicit-only bookmark 与 raw bookmark bytes persistence 也不属于
  001F/001G。
- probe runtime 禁止对 executable parent/ancestor 执行 Git source discovery。source
  attribution 只来自 reviewed registry + exact evidence digest；actual executable bytes 和
  platform trust 仍在本地独立重核。
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
- **把 `/opt/homebrew` HEAD 当 upstream**：拒绝。安装目录可能位于无关、可变 repository，
  与 binary source 无密码学绑定。
- **删除 upstream/source check，只看 binary hash**：拒绝。采用 protected-main reviewed
  artifact-digest ↔ upstream-commit ↔ evidence tuple，使相同 binary bytes 只在已登记
  provenance 下可用。
- **要求 executable 紧邻 exact upstream checkout**：本窗口不采用。它会改变用户选择的
  artifact path/packaging 前提；若未来选择该方案，须另起 readiness 并精确 pin checkout
  root、commit 与 build/output relation。
- **直接清除 quarantine、设置 exclusion 或复制/重建 pinned tool**：拒绝。它会把
  assessment blocker 变成 host metadata 绕过，且无法回答用户选择边界是否安全。
- **给现有 Probe 增加 `user-selected.executable`**：拒绝。Apple 将该 entitlement 定位为
  sandboxed App 写入非 quarantined executable 的能力；001E 不写 selected executable，
  无需也不得扩大此权限。
- **立即修改 ArkDeckApp 的 read-write entitlement**：拒绝。macOS platform profile 仍要求
  output directory read-write；#509 也没有 canonical direct-selection 对照。全局修改会把
  characterization 扩成产品文件/输出回归决策。
- **先做 read-only 单变量 host characterization**：采用。保留其余五项 entitlement，
  用 wrong-hash inert fixture 让 child launch 结构性为 0，分别观察 canonical/symlink
  selection 的 bookmark 与 quarantine metadata。PASS 仍不自动选择 product
  broker/helper；该架构须后续 D1 ADR/readiness。
- **在 read-only entitlement 下继续只用 `.withSecurityScope` 重试**：拒绝。#512 两个
  fresh selector 已在相同 creation shape 下失败；无 API 变量的重复不能增加证据。
- **加入 `.securityScopeAllowOnlyReadAccess`**：采用为 001F。它是 Apple 对只读
  security-scoped bookmark 明示的 creation option，且不扩大 entitlement 或进入 Process；
  仍须用两个 wrong-hash run 证伪/证实，不能预判成功。
- **从 001F 直接运行真实 `rkdeveloptool`**：拒绝。001F 使用 read-only entitlement 且
  child launch 0，与 ADR-0002 的 read-write product shape 和 external-process boundary
  都不相同；current exact real artifact 也已 quarantined。
- **立即选择 helper/XPC/broker 或 bundled/copied tool**：本轮拒绝。Apple 文档给出明确
  风险信号，但现有仓库同时有历史 fake-child/selection 分离证据；先用 001G 的 canonical
  inert fixture 取得二值 product-shape launch fact。失败后再以新 ADR 比较 broker、
  reviewed bundled component、plan-only 或分发调整，不能在 characterization 中预选。
- **canonical inert external-fixture 两阶段 characterization**：采用为 001G。先用
  wrong-hash control 证明 product entitlement selection 不改写 metadata，再在另一个 fresh
  App 中只放行编译期绑定的 `return 0` fixture。它最小化权限与副作用，同时直接回答
  real-tool E0 readiness 前缺失的 child-launch 问题。
- **删除 app-scope bookmark，依赖 picker implicit scope**：本轮拒绝。它放弃产品所需的
  persistent selection seam，也无法回答 bookmark round-trip blocker；若产品选择
  session-only access，须另起 D1 ADR。
- **只保留物理按键**：作为可靠 fallback 保留，不作为唯一产品路径；已验证软件进态组合
  默认可从同一 Start Job 流程进入 Loader。
- **先交付 plan-only UI**：接受为分阶段交付；execute 仍以 E0 non-elevated USB access 和
  `REQ-FLASH-015` 审查为硬前置，不把 plan-only 宣称为一键真机刷机完成。

若 001G 不能在 signed Sandbox product shape 下运行 inert external fixture，新的
helper/entitlement/bundled-component/分发决策必须新增 ADR/change；不得直接重试真实工具。
若 001G PASS，真实 `rkdeveloptool`/USB 也仍须后续独立 D1 readiness。r9 不隐含产品架构、
真实 external-tool、USB/device 或 destructive 执行授权。
