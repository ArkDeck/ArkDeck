# Tasks — CHG-2026-006 DAYU200 M0B bring-up

> V2 治理:本文件是任务的唯一事实源。change 已于 2026-07-18 经 approval-only PR
> approved(先例 #14/#40/#45,批准由维护者 review/merge 构成);任务状态变更仅在
> 维护者 review/merge 后生效。全部真机操作由人类维护者执行,Agent 不执行真实
> `hdc`。

## TASK-M0B-001 — 人类真机发现/授权/工具链特征化与受控采集

- Status:done
- Completion evidence:`evidence/runs/TASK-M0B-001/run.md`
  (`EVD-M0B-DAYU200-20260718-001`;操作者 fuhanfeng 于 2026-07-18 亲自对物理
  DAYU200(RK3568)执行 runbook 全部 11 条白名单命令,Agent 零真实 `hdc` 执行;
  evidence 与 hardware-matrix 首条 `observed` 行经 PR #58 由维护者 review/merge
  合入 main `f8817d9`)。四个 Test ID 均已执行并二值记录:
  `TEST-HW-M0B-DAYU200-DISCOVERY-001` PASS、`TEST-HW-M0B-DAYU200-RAWCAPTURE-001`
  PASS、`TEST-HW-M0B-DAYU200-UIDUMP-PROBE-001` PASS、`TEST-HW-M0B-DAYU200-AUTH-001`
  **FAIL(as written)**——该 DAYU200 build 无 on-device 信任 UI,未授权态不可
  观察,负路径不可重现性已按 AC 条款如实记录(run.md D1/R2);AC 前提修订留给
  后续 change,本 done 不覆盖该 FAIL 也不构成 AUTH-001 通过。evidence JSON 经
  schema 2.0.0 校验(provider `none`);evidence 仅支持 `observed`,不构成支持
  声明。`ready→done` 由本独立状态 PR 执行,仅在维护者 review/merge 后生效。
- Requirements/AC:`HW-M0B-DAYU200-DISCOVERY-001`、`HW-M0B-DAYU200-AUTH-001`、
  `HW-M0B-DAYU200-RAWCAPTURE-001`、`HW-M0B-DAYU200-UIDUMP-PROBE-001`
  (见 acceptance-cases.yaml)
- Depends on:none(change approved 即可;不依赖 M1-006)
- Allowed paths:
  - `scripts/m0b_capture/**`(runbook 与只读采集脚本;Agent 起草,不执行)
  - 本 change `evidence/**`(runs/TASK-M0B-001/run.md、hardware-evidence JSON、
    capture hash 清单)
  - `openspec/verification/hardware-matrix.md`(仅新增 `observed` 行,与 evidence
    同 PR)
  - 本 change `tasks.md`(仅更新本任务状态与 completion evidence)
- Forbidden paths:产品代码、`openspec/specs/**`、`openspec/contracts/**`、
  `openspec/baselines/**`、`openspec/integrations/**`、`openspec/platforms/**`、
  其他 change/task evidence。
- Risk:medium(真实设备在场;但命令封闭为只读白名单,唯一设备端状态变化为
  人工授权信任确认;无 flash、无写设备、无网络外联)
- Hardware required:yes(物理 DAYU200,USB;操作者=人类维护者)
- Deliverables:runbook + 受控采集脚本;发现/授权/工具链/hidumper 探测观察记录;
  分 stream 逐字节 capture(hash 固定,敏感字节存仓库外受控位置);符合
  `hardware-evidence.schema.json` 的 evidence JSON(provider:none);
  hardware-matrix `observed` 行草案;run.md(二值 AC 结论、偏差、遗留风险)。
- Verification:按 acceptance-cases.yaml 四个 Test ID 执行;runbook 白名单合规性
  由 run.md 逐命令记录 argv/exit code 自证;evidence JSON 经 schema 校验;缺任一
  项不得标记 `done`。evidence 只支持 `observed`,不构成支持声明。

## TASK-M0B-002 — ArkDeck HDC supervisor 真机只读观察

- Status:blocked(fresh readiness r3 audit,2026-07-29;仅在维护者 review/merge
  本独立 readiness PR 后生效。CHG-2026-043 已 verified，r2 的 exact
  3.2.0d/3.2.0f 单候选冲突已解除；但 production App 只在 view `.task` 启动时
  调用一次 diagnostics `refresh()`，HDC UI 没有可达的显式 refresh action。
  选择 executable、recovery preview/confirm 等现有 UI 动作只读取
  `currentEvents()`，不会在同一 device-observation session 再 poll。因而一次
  人类 App 窗口不能同时取得 Connected→`appeared` 与 Offline→`disappeared`
  的差分证据，`HW-M0B-DAYU200-SUPERVISOR-001` 仍不可二值判定；本任务保持
  blocked，零 HDC/device/window dispatch。)
- Fresh readiness r3 audit(2026-07-29；host-only static/source/build audit，base =
  protected main `7a7f9db3de389b94c72e9a0d0a57fe4e0c488788`):
  - **Approval/dependency/remediation gate:satisfied,但不充分。**CHG-2026-043
    verification-only PR #762 exact head
    `60cac06c995345abf036079a7492c0770d4109e3` 由维护者 `lvye`
    APPROVED 后 merge 为本 audit base；其 proposal/verification current blobs =
    `2c124bd781c4efba5da71b1349cdb23979e04325` /
    `abebdd8b72a7d57cd9e14eed9ac755b1526593b1`，状态为
    `verified` / `passed`。TASK-HSO-001/002 均 done，run blobs =
    `db56cd004dd78295ab7129ee01f4f658cba71c9c` /
    `ba399ffb99dc3d67808c2500bcafb16ff3ff9047`。原依赖
    TASK-M1-006 与 TASK-M0B-001 的 done 结论未漂移；#762 后至 current base
    唯一新增 commit 为 #763 exact head
    `8f3f791ba937e0b7fd88118e249dae4bea4bcdf4` / merge
    `7a7f9db3de389b94c72e9a0d0a57fe4e0c488788`，只修改 CHG-2026-025 的
    proposal/tasks/verification/evidence，与本 task/readiness/product 输入零交集。
  - **Exact tool/registry gate:satisfied statically。**SDK 扫描只找到
    `/Applications/DevEco-Studio.app/Contents/sdk/default/openharmony/toolchains/hdc`；
    未启动 executable 的 SHA-256 =
    `05b2bf7ad30201c082da336db28f8856952a2b2f49ac3404b96fdb4bf1a68f83`，
    `codesign --verify --strict` PASS。它逐字命中 exact 3.2.0f supervisor 与
    device registries；canonical supervisor/device/readonly blobs =
    `b202b9d34680a0e7bbdba1d02637279ca4819d3f` /
    `399c5a102c7737bf6466e8a2c4c6a1d1b1bc0b6a` /
    `99e8cc3d9929f9502a3e978a53cd56ad285d2aad`，三者 authority 继续分离，
    未把 3.2.0d facts 拼入本候选。
  - **Single-candidate supervisor path:satisfied statically。**production facade /
    supervisor observer / HDC production blobs =
    `fa0bc651382c9b5d1a36a46c59a11af65bc84249` /
    `589dfec329044b58f4fefec3a70d4af7f9cfd15e` /
    `c7f71e5af90bc3d468d5f0817734d297f0c339a2`。一次
    `attachSessionIfConfigured()` 只 discovery 一个 candidate/endpoint；exact
    3.2.0f candidate 进入 commandless supervisor observation，再由同一 local
    value 构造 device session。稳定 receipt 只进入既有 four-evidence
    classifier；health/version 保持 typed unknown；supervisor identity leg 的 HDC
    child/lifecycle/subserver/device mutation 均为 0。r2 的 hard blocker 已实质解除。
  - **Production refresh reachability:blocked。**App composition root
    `ArkDeckApp.swift` blob
    `1ec424df02550cc9f79780b7a4b61af28d7faf30` 只在 `AppShellView.task`
    调用一次 `hdcDiagnostics.refresh()`；`HDCStatusView.swift` blob
    `476769d4b5b242a91b2bb4d0661cdb0fb7359d44` 没有 diagnostics refresh
    callback/button。Workflows 只有 public provider `refresh()` 会调用
    `deviceObservationSession.refresh()`；选择 executable 会清空/替换 session 后
    只 overlay `currentEvents()`，recovery preview/confirm/dispatch 也只 overlay
    current events。contract DP14 证明同一 actor 被连续显式调用时可以逐次 poll，
    但 App 用户没有到第二次调用的 production route。
  - **AC consequence:blocked。**registered 3.2.0f presence rule 要用同一 session 的
    连续 snapshots 才能把 Connected 集合差分为 `appeared`，再把全 Offline
    差分为 `disappeared`。单次 startup refresh 至多产生其中一边；重启 App、
    重建 window、重选 executable 或跨 session 拼接均会重置 session/buffer/HMAC，
    且权威文件没有把这些未定义生命周期技巧登记为观察方法。fixture、直接调用
    private view model、contract fake 或两个 session 拼接都不能充当 realHardware
    App 证据。ownership、两项仪表计数、endpoint source 与现有单次 device event
    虽可展示，缺 `disappeared` 仍使整条 Test ID FAIL/不可判定。
  - **Build/revalidation:**macOS 26.6(25G72)/arm64、Xcode 26.6(17F113)、
    Apple Swift 6.3.3；与 current base 产品树逐字相同的 #762 merge base 上，
    ad-hoc signed Debug App build PASS，
    `codesign --verify --deep --strict` PASS，arm64 executable SHA-256
    `0a908f0a9e47c00f7fbb0e1020baac4d012392e72c98defd560eaec5e2ad4bbc`
    （仅 readiness compile proof，不是后续 hardware execution pin/support
    artifact）。四个 HDC 聚焦 suites = 114/114 PASS；ArkDeckKit 全量 =
    506 tests / 1 个既有人工 sleep-wake skip / 0 failures / 0 unexpected；
    `check-sdd` = 0 errors / 0 warnings / 111 acceptance IDs，
    checker/path contracts = 56/56 与 50/50 PASS；`git diff --check` PASS。
  - **Execution boundary:**installed HDC process、HDC server lifecycle、App
    production launch、device discovery/identity、USB/device、App/product
    non-loopback network、mutation、destructive dispatch 均为 0；未声称 DAYU200
    当前在线或固件未漂移，未创建、安排或消费 named D2 window。HDC 检查仅为
    filesystem hash/codesign；GitHub control-plane 审计不计入产品执行面。
  - **Unblock gate:**须先由独立 approved change 在 production HDC UI 增加明确的
    user-triggered diagnostics refresh route，并以 signed App contract 证明每次动作
    复用同一 selected candidate/endpoint/device-observation session、至多执行一次
    已登记的 `list targets -v`、能在同一 bounded buffer 形成
    appeared→disappeared，且无 timer/background poll、第二 discovery/candidate、
    fixture 或 lifecycle/mutation 扩权。该 remediation done/verified 后仍须另起
    fresh D2 readiness，在当时 current main 重钉 signed App build、exact HDC
    tuple、DAYU200 identity/firmware/USB 与 named exclusive human-operated window。
  - **PR boundary:**本 readiness 载体只修改本 `tasks.md` 的 TASK-M0B-002 段；
    不修改 proposal/design/verification/acceptance、product/test、integration/
    platform profile、hardware-matrix 或既有 evidence，不自行夹带 remediation
    proposal。下方 r2/r1 记录保留为历史。
- Fresh readiness r2 audit(2026-07-28;host-only static/source audit，base =
  protected main `80ce41e2eea89b1746cfb49fa6cdda1033a5bc8e`):
  - **Approval/dependency gate:satisfied,但不充分。**CHG-2026-022 的三个任务均
    done，独立 verification closure PR #734 exact head
    `947d7b9a7301cfd783e7e92aeb0242a59fe6ca42` 由维护者 `lvye` APPROVED 后
    squash merge 为 `f6c9619d121e2f5d5b3a0da1bfcdc2c1f9e9a6fd`；该 merge 是
    audit base ancestor。其后至 audit base 唯一 commit 只修改
    CHG-2026-025 `tasks.md`，与本任务及观察输入零交集。CHG-2026-022 的
    proposal/verification/task blobs =
    `a5c8ae5397e452821def7dbce12cfb6a533b216a` /
    `6702df7cb7a492d509ed8a0dc9a0125b33ec393f` /
    `4745a88453b54a296dcff238a1c7c757fb1f262a`；OBS-001/001R/002 run blobs =
    `4148b50a8d5ef6614058fdf24972d3d921f01de0` /
    `2beee035ff96d50a795b79a9677e7e6a3efb2b11` /
    `50acb503146f258d3bdce25626a7115f840e0927`。
  - **Current tool gate:blocked for the historical 3.2.0d leg。**未启动 executable
    的静态 hash 复核得到
    `/Applications/DevEco-Studio.app/Contents/sdk/default/openharmony/toolchains/hdc`
    = `05b2bf7ad30201c082da336db28f8856952a2b2f49ac3404b96fdb4bf1a68f83`，
    `codesign --verify --strict` PASS；该 exact hash 已由 protected-main
    device-observation registry 登记为 3.2.0f。`/Applications` 全量文件名扫描、
    用户目录 metadata 搜索与已知 SDK 位置扫描只找到这一枚 HDC；未找到历史
    3.2.0d / `48395ba8d87115dffca47df2a640a6c868bc9a2bd4eb49611e4138ff88d8d260`
    executable。本结论只描述已扫描位置，不推断其他受控存储。
  - **Single-candidate production proof:blocked。**App facade
    `HDCApplicationDiagnosticsFacade.swift` blob
    `4f32e1f6e4c9142f332f35d0001e67f379304dba` 在一次
    `attachSessionIfConfigured()` 中只发现一个 `candidate`，并把同一值同时传给
    `observeRegisteredExistingServer(...)` 与
    `HDCDeviceObservationApplicationSession.makeProduction(...)`；产品没有第二
    tool/session 拼接入口。server observation 在 `HDCProduction.swift` blob
    `8055fc65dde7b95c1ab87fa52bb54ed002b024ad` 中要求 candidate hash 精确等于
    readonly registry 的 3.2.0d pin，否则在任何 HDC child 前返回 unsupported；
    device session 则要求同一 candidate 精确等于 3.2.0f pin，否则追加
    unavailable 且 runner invocation = 0。两枚 hash 不同，不存在同时满足的
    candidate。
  - **Registry/AC boundary:blocked。**readonly registry/code blobs =
    `99e8cc3d9929f9502a3e978a53cd56ad285d2aad` /
    `2dfe8e9d8290d6e939b4e3531ac81bb332a7cc29`，只批准 3.2.0d 的
    `serverIdentityGeneration`；device registry blob =
    `399c5a102c7737bf6466e8a2c4c6a1d1b1bc0b6a`，只批准 3.2.0f 的
    `deviceObservationSnapshot`，并明文禁止把两工具合并解释。现有
    `TEST-HW-M0B-DAYU200-SUPERVISOR-001` 要求 production supervisor 同时给出
    external ownership、两项 0 计数、endpoint isolation 与 device fan-out；
    hardware-matrix 既有 observed 行仍钉 3.2.0d。权威文件未定义可接受的双工具/
    双 session 证据与 matrix 归属；Agent 不自行把 AC 改释为分腿拼接。
  - **Host revalidation:**macOS 26.6(25G72)/arm64、Apple Swift 6.3.3；
    `HDCSupervisorObservabilityContractTests` 25/25 PASS；
    `HDCDeviceObservationPresentationContractTests` 18/18 PASS(含 DP8 wrong
    candidate → unavailable / zero runner)；
    `HDCSupervisorContractTests/testRegisteredServerIdentityPreconditionRejectsFakeExecutableBeforeAnyChildLaunch`
    1/1 PASS。上述测试确认两条 production gate 按设计 fail closed，不构成
    realHardware evidence。
  - **Execution boundary:**installed HDC process、HDC server lifecycle、
    device discovery/identity、App production observation、device、mutation、
    destructive dispatch 均为 0；未声称 DAYU200 当前在线、固件状态或 exclusive
    window 可得，未安排/消费 D2 设备窗口。
  - **Unblock gate:**须先由独立 approved change 登记并接线 exact 3.2.0f
    readonly server identity/ownership，使单 candidate 覆盖四观察点；或由
    CHG-2026-006 approved revision 明确定义双工具/双 session AC 与 matrix
    归属。两方案均属维护者 D1 判断，任何产品/integration/AC 修改均不得塞入本
    readiness。所选 remediation done 后仍须另起 fresh D1/D2 readiness，在当时
    current main 重钉 App build、tool hash/version、exact DAYU200 identity/
    firmware/USB 与 named exclusive human-operated window。
  - **PR boundary:**本 readiness 载体只修改本 `tasks.md` 的 TASK-M0B-002 段；
    不修改 proposal/design/verification/acceptance、integration/platform profile、
    product/test、hardware-matrix 或既有 evidence，不自行创建后续 remediation
    proposal。原 #243 readiness 与下方 2026-07-21 fail-closed 记录只作历史。
- Historical Status:blocked(fail-closed 回退,2026-07-21 晚;仅在维护者 review/merge 本独立
  状态 PR 后生效。#243 readiness 的"M1-006 实际交付形态与四观察点逐项对应"复核经
  执行前深查(host-only 源码级取证路径核对)被证伪——四观察点中两点无只读取证
  路径、一点语义落差、一点仅部分可观察,而任何补暴露面的修复均越本任务 forbidden
  paths(`Packages/**`、`ArkDeckApp/**`),按本任务自身条款"若观察需要代码变更,
  停止并走独立 change"回退。缺口清单:
  ① **[硬]仪表化计数无载体**:产品无任何自动 lifecycle/subserver 调用计数器,
  App/presentation/日志/导出均不暴露;现有保证是结构性的(supervisor 无自动
  executor),而本任务 Verification 明文"计数为仪表化实测而非分支常量"——无法经
  只读观察取证;
  ② **[硬]设备出现/消失 fan-out 无生产 feed**:participant registry 生产恒
  `.complete([])`、无设备 recipient 注册,App 无设备列表/事件流,`HDCServerEvent`
  仅含 server 事件;
  ③ **[语义]ownership 落差**:三条生产 observe 路径恒判 `unknown`(带 known
  generation、从不 managed),`.external` 仅存在于 UI 夹具;acceptance 字面
  "classifies … as external ownership"在生产面不可达;
  ④ **[部分]endpoint 隔离不可视**:App 仅显示解析后 endpoint 字符串,不暴露
  endpoint source 与子进程 env,"显式 endpoint 只进子进程环境"的隔离性无 App 面
  证据;
  另:M1-009 诊断导出未在 App 接线且日志目录无 HDC 事件,不能作取证载体。
  解除前置(须独立 PR 逐项落实):(a) 独立 supervisor-observability change 立项
  并 done——补仪表化计数暴露、设备 fan-out feed/展示、endpoint source 暴露,并
  处置 ownership 语义(产品补 external 判定或经 CHG-006 revision 把 AC 双分支化,
  AUTH-001 r2 先例,由维护者裁决);(b) 其后新 readiness PR 重钉交付形态与 pins。
  原 #243 readiness 记录保留于下,作历史;其 pins(hdc 3.2.0d)不因本回退失效。)
- Readiness review(2026-07-21;host-only,零设备命令):
  - 前置 ①:`TASK-M1-006` done(状态 PR #207 squash `466f42a`,实现 #191 squash
    `c61e10e`)。实际交付形态与本任务观察目标逐项对应:生产 supervisor
    (`HDCProduction.swift` 接线 ProcessExecutor/语义评估)+ readonly probe registry
    0.3.0 采用(**server 观察仅对 pinned hdc 3.2.0d(sha256 `48395ba8…d260`)
    supported,其他 build 一律 unsupported fail-closed**)+ participant registry feed
    (CHG-2026-019 PI-001,#205/#206)+ endpoint 隔离与授权 probe 面——分别承载
    ownership/generation 分类、lifecycle/subserver 仪表计数、endpoint 隔离、
    设备出现/消失 fan-out 四个观察点。
  - 前置 ②:`TASK-M0B-001` done(状态 PR #59 `b3414e5`,evidence #58 `f8817d9`):
    设备/授权/工具链事实与 capture 先行已在案(DAYU200 OpenHarmony 7.0.0.34、
    hdc 3.2.0d、AUTH-001 r2 分支 B 无信任 UI 设备族、matrix observed 行
    `EVD-M0B-DAYU200-20260718-001`)。
  - 执行时 pins(本 readiness 实测复核):hdc = DevEco toolchains 路径,SHA-256
    `48395ba8d87115dffca47df2a640a6c868bc9a2bd4eb49611e4138ff88d8d260`、`Ver: 3.2.0d`
    ——与 M0B/I15 pinned tuple 及 M1-006 registry 唯一 supported build 逐字一致;
    执行前须再复核,任一漂移即停(registry 会将其他 build 判 unsupported,观察
    无法产生 supported-family 事实)。
  - 执行模型:物理 DAYU200 + USB,App 由人类维护者启动,Agent 零设备命令;观察
    全程只读,supervisor 自动 lifecycle/subserver 调用计数须为仪表化实测 0(分支
    常量不构成证据,M1-010/004 准则);外部启动的 host server 应分类为 external
    ownership。设备窗口与其他设备任务(如 CHG-2026-008 Phase A)不得同窗口并行,
    可同日先后;中止如实记录为 blocked-attempt。
  - 竞争面:复核时仓库 open PR 为 0(除本批次两 PR);allowed paths(本 change
    `evidence/**`、hardware-matrix 既有 observed 行 supervisor 观察列、本任务状态)
    与任何活跃线零交集。
  - Review boundary:本 readiness 只翻转状态并记录依赖/pins/执行模型;`ready→done`
    须观察 evidence(逐观察点记录 + 仪表计数 + run.md)全部可判定后另用独立状态
    PR;若观察需要任何代码变更,停止并走独立 change(allowed paths 约束不变)。
- Requirements/AC:`HW-M0B-DAYU200-SUPERVISOR-001`(见 acceptance-cases.yaml)
- Depends on:`TASK-M1-006`(CHG-2026-002;生产 supervisor/授权工作流/endpoint
  隔离)、`TASK-M0B-001`(设备/授权/工具链事实与 capture 先行)
- Allowed paths:本 change `evidence/**`、`openspec/verification/hardware-matrix.md`
  (仅补充既有 `observed` 行的 supervisor 观察列)、本 change `tasks.md`(仅本任务
  状态)。不修改任何产品源码/测试;若观察需要代码变更,停止并走独立 change。
- Forbidden paths:同 TASK-M0B-001,另加 `Packages/**`、`ArkDeckApp/**`。
- Risk:medium(真机在场运行生产 supervisor 只读路径;App 由人类启动;自动
  lifecycle/subserver 调用计数须为仪表化实测 0)
- Hardware required:yes(物理 DAYU200,USB;操作者=人类维护者)
- Decision-Grade:D2。
- Deliverables:supervisor 真机观察记录(ownership/generation、lifecycle 计数、
  endpoint 隔离、设备出现/消失 fan-out)、evidence JSON 增补、run.md。
- Verification:按 acceptance-cases.yaml `TEST-HW-M0B-DAYU200-SUPERVISOR-001`;
  计数为仪表化实测而非分支常量(M1-010/004 准则);缺任一项不得标记 `done`。
