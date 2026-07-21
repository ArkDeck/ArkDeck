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

- Status:ready(readiness;仅在维护者 review/merge 本独立状态 PR 后生效。两依赖均
  已 done 并经复核,单文件、不含实现、不产生 evidence)
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
- Deliverables:supervisor 真机观察记录(ownership/generation、lifecycle 计数、
  endpoint 隔离、设备出现/消失 fan-out)、evidence JSON 增补、run.md。
- Verification:按 acceptance-cases.yaml `TEST-HW-M0B-DAYU200-SUPERVISOR-001`;
  计数为仪表化实测而非分支常量(M1-010/004 准则);缺任一项不得标记 `done`。
