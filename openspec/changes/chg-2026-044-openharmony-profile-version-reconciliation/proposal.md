---
id: CHG-2026-044-openharmony-profile-version-reconciliation
revision: 1
status: proposed
class: integration
core_change_level: none
owner: lvye
core_baseline: CORE-2.1.0
platforms: [macos]
---

# Reconcile the living OpenHarmony profile version with its lock

## Why

CHG-2026-043 `TASK-HSO-001` 的 fresh readiness PR #740（merge
`b314d6dd586744480e7a66c2fa71c4d51199ab40`）确认 current OpenHarmony integration
authority 自相矛盾：

- `openspec/integrations/openharmony/profile.md` header 仍声明
  `OPENHARMONY-TOOLS@0.4.0`；
- 同一文件的 device-observation 章节声明该能力属于
  `OPENHARMONY-TOOLS@0.5.0`；
- `INTEGRATION-PROFILES-0.6.0` lock 把该 living profile 登记为 `0.5.0`；
- device-observation registry 也精确绑定 `OPENHARMONY-TOOLS@0.5.0`。

lineage 显示 header 的 `0.4.0` 来自早期 trace registration，而 CHG-2026-024
implementation PR #664（merge
`ffca996f41be37d27137e7245c8fba3645fb0fb4`）增加 0.5.0 device-observation
语义并 bump lock 时漏改了 header。现有 `check-sdd` 与 contract tests 仍为绿色，
因为它们只检查路径/registry closure，没有比较 living profile header 与 lock entry。

两个权威文件冲突时 Agent 不能自行选择解释。本 change 把候选裁决与防回归机制交给
维护者 review：接受 CHG-2026-024 已登记的 `0.5.0` lineage，精确修正 header，并让
后续同类漂移在 SDD Guard 中变红。

## What changes

### In scope

- 只把 `openspec/integrations/openharmony/profile.md` header 的 version 从
  `0.4.0` 修正为 `0.5.0`；profile 正文、命令语义、registry mapping 与其他 metadata
  保持 byte-for-byte 不变；
- 在 `scripts/check_sdd.py` 的 integration lock 校验中，要求
  `INTEGRATION-PROFILES.lock.yaml` 每个 `profiles[]` entry 的 `id`、`version` 与
  `path` 所指 Markdown profile header 精确一致；
- 缺失/重复/格式错误的 header metadata、重复 profile id/path、id/version mismatch
  都报告为确定性 SDD error，而不是异常退出或静默通过；
- 在 `scripts/test_check_sdd.py` 增加 clean baseline、header version mutation、
  header id mutation、missing/duplicate metadata 与 duplicate lock entry tests；
- 记录 host-only run evidence，并证明 lock、device registry、Core conformance、
  production source 与 archived evidence 均未修改。

### Out of scope

- 修改 `INTEGRATION-PROFILES.lock.yaml`、device/readonly/trace registry、resource pack、
  macOS profile 或 `core-conformance.yaml`；
- 新建或占用 `OPENHARMONY-TOOLS@0.6.0`、
  `INTEGRATION-PROFILES-0.7.0` 或 CHG-2026-043 的 supervisor registry/resource；
- 改写 archived CHG-2026-024 proposal、tasks、evidence 或历史 commit；
- 修改 Core Requirement/AC、contracts/schema、baseline、platform conformance、
  hardware/support/release 状态；
- 修改 production code，运行 installed HDC，连接真实设备，或触发 server/device
  lifecycle、mutation、destructive effect；
- 把本 remediation 自动解释为 CHG-2026-043 `TASK-HSO-001` ready。

### Observable behavior before/after

- Before：living profile header 报 `0.4.0`，lock/body/device registry 报 `0.5.0`；
  SDD Guard 对该冲突仍返回 success。
- After：living profile header、lock/body/device registry 都指向既有
  `OPENHARMONY-TOOLS@0.5.0` lineage；任意 header/lock id 或 version mutation 都使
  SDD Guard fail。runtime、HDC 与设备行为不变。

## Scope

- Canonical Core Requirements claimed:none
- Canonical Acceptance claimed:none
- Change-local acceptance:`OPVR-HEADER-LOCK-001`、`OPVR-MUTATION-001`、
  `OPVR-NONINTERFERENCE-001`
- Contracts/schemas:none
- Core baseline bump:no；保持 `CORE-2.1.0`
- Candidate profile after reconciliation:`OPENHARMONY-TOOLS@0.5.0`
- Current lock retained byte-identical:`INTEGRATION-PROFILES-0.6.0`

本 change 不创建新 profile version。`0.5.0` 已由受保护 main 上的 lock、profile 正文与
device registry 登记；这里修复的是遗漏的 living header。提前 bump 到 `0.6.0` 会占用
CHG-2026-043 尚待 fresh readiness 重钉的 candidate，并错误暗示本修复新增 integration
语义。

## Platform impact

| Platform | Disposition | Reason |
| --- | --- | --- |
| macOS | metadata/guard correction；无 conformance transition | 当前 0.5.0 device-observation family 只登记 macOS exact tuple |
| Windows | deferred / unchanged | port 未启动；本 change 不新增 integration support |
| Linux | deferred / unchanged | port 未启动；本 change 不新增 integration support |

## Safety, privacy, and compatibility

- guard 只读取仓库内 lock 与 profile header，不运行外部工具、不产生 authority 或 effect；
- mismatch、missing、duplicate 或 malformed input 全部 fail closed 为 SDD error；
- 不读取 raw device identifier、用户路径、secret 或仓外 evidence；
- 0.3.0 readonly、0.4.0 trace 与 0.5.0 device registry 的历史 adoption boundary
  保持不变；header 表示 living profile current version，不改写历史 consumer pin；
- rollback 必须把 header 与 guard/tests 作为同一原子 remediation 回退；回退后冲突重现，
  CHG-2026-043 `TASK-HSO-001` 继续 blocked。

## Approval and flow

本 proposal PR 只创建 change package：零 profile/script/test 实现、零 task 状态推进、
零 HDC/设备调用。正式批准须由后续独立 approval-only PR 完成；`TASK-OPVR-001`
初始 `blocked`。批准后仍需独立 D1 readiness 固定当时 protected-main inputs 与
mutation matrix；implementation/evidence、`ready→done`、change `verified` 各自使用
独立 PR。

只有本 change verified 后，CHG-2026-043 `TASK-HSO-001` 才可另起 fresh D1 readiness；
本 change 的任一合入都不自动接受 HSO provenance、candidate versions 或实现范围。
