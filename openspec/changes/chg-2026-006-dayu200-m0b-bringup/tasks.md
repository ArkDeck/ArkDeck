# Tasks — CHG-2026-006 DAYU200 M0B bring-up

> V2 治理:本文件是任务的唯一事实源。change 已于 2026-07-18 经 approval-only PR
> approved(先例 #14/#40/#45,批准由维护者 review/merge 构成);任务状态变更仅在
> 维护者 review/merge 后生效。全部真机操作由人类维护者执行,Agent 不执行真实
> `hdc`。

## TASK-M0B-001 — 人类真机发现/授权/工具链特征化与受控采集

- Status:ready(change approved;执行需物理 DAYU200 在场与维护者时间窗,执行与
  `ready→done` 分别经独立 PR 由维护者 review/merge 生效)
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

- Status:blocked(等待 `TASK-M1-006` done 合入 main,且 `TASK-M0B-001` done;
  解除须独立 readiness/status PR 复核两依赖与 M1-006 实际交付形态后生效)
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
