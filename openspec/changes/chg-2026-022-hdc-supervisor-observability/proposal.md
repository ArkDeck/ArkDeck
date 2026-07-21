---
id: CHG-2026-022-hdc-supervisor-observability
revision: 2
status: approved # r1 经 main `1e4a7c4027ecdd1142ceab2b80f4423eec586d6d` 批准;r2 review-remediation 仅在对应治理 PR 由维护者 review/merge 后生效
class: platform
core_change_level: none
owner: lvye
core_baseline: CORE-2.1.0
platforms: [macos]
---

# HDC supervisor 可观察性:仪表化计数、设备 fan-out 面、endpoint source 与 ownership 判定

## Revision r2 review remediation

TASK-OBS-001 r1 readiness(`f3c9685ea70b32099c20bf7fe022bbc9aa688709`)
后的实现审查发现四个 prerequisite 缺口，prototype PR #265 因此只保留为 draft，
不得作为实现或 evidence 合入：

1. macOS profile 仅批准与既有 durable binding 精确匹配的 registered
   `list targets -v` capture；它不是任意设备枚举，不能为真机插拔 fan-out 提供
   生产快照。该能力必须先经独立 integration change 注册参数化 raw family。
2. r1 的“防御性 automatic executor 入口”没有生产调用方；caller-supplied origin
   也可伪造。r2 将计数语义收紧为：在 identity-bound `posix_spawn` 成功后的唯一
   hook，根据 supervisor 铸造的 opaque permit 区分 confirmed/managed 与
   unpermitted automatic dispatch；测试只能通过同一 spawn hook 的 mutation seam
   证伪，不能直接调用 monitor。
3. r1 三证据不能排除既有 `.arkDeckManaged` provenance。r2 增加 managed-provenance
   disposition；既有 managed claim 未经显式 reconcile/retire 时不得被 bracketed
   observation 直接改判 `.external`。
4. r1 readiness 把 8-hex 文件 SHA-256 前缀误称为 blob pin。r2 记录完整 historical
   commit/blob/SHA-256，并要求未来 readiness 对实际实现 base 重新给出完整 pin。

本 r2 只修订治理、设计和验证并把 TASK-OBS-001 恢复为 `blocked`；不包含实现、
不产生新的 AC evidence、不执行 HDC/设备命令。TASK-OBS-002 继续 blocked。

## Why

TASK-M0B-002(生产 supervisor 真机只读观察)于 2026-07-21 fail-closed 回退
blocked(#250):执行前源码级深查证伪了四个观察点的取证路径——

1. **仪表化计数无载体**:产品无任何自动 lifecycle/subserver 调用计数器,App/
   presentation/日志/导出均不暴露。现有"零自动 dispatch"保证是结构性的
   (supervisor 无自动 executor),而 M0B-002 Verification 明文"计数为仪表化实测
   而非分支常量"(M1-010/004 准则)——观察目标要求的证据形态在产品里不存在。
2. **设备出现/消失 fan-out 无生产 feed**:supervisor 的 broadcast/recipient 机制
   存在,但 `HDCServerEvent` 仅含 server 事件;participant registry 生产诚实地为
   `.complete([])`,无设备 recipient 注册;App 无设备列表/事件面。
3. **ownership 语义落差**:三条生产 observe 路径恒写 `.unknown`,`.external` 仅
   存在于 UI 夹具——acceptance 字面 "classifies … as external ownership" 在生产面
   不可达;而 M1-006 design 既定 external 与 unknown 在 lifecycle 门上同等对待,
   即标签升级不涉及任何安全门变化。
4. **endpoint 隔离不可视**:App 仅显示解析后 endpoint 字符串,不暴露 endpoint
   source(explicit/inherited/default)与"显式 endpoint 只注入子进程 env"的
   隔离性证据。

修复以上任何一点都越 M0B-002 的 forbidden paths(`Packages/**`、`ArkDeckApp/**`),
故按其任务条款立项本独立 change(#250 记录的解除前置 (a);维护者 2026-07-21 选定
方案 a:四点全部纳入本 change,含 ownership 判定的产品侧实现)。

## What changes

两任务分期,均 host-only(零设备、零真机;真机观察本身留在 TASK-M0B-002):

- **TASK-OBS-001 — Kit 仪表化与分类面**(`Packages/ArkDeckKit`):
  - 自动 lifecycle/subserver dispatch 计数器:只在 identity-bound spawn 成功后
    的唯一 hook 计数；origin 由 opaque supervisor permit 与 typed argv family
    决定，普通 caller 不能传 enum/string 自报来源；confirmed/managed dispatch
    单独计数且不得混入 automatic；
  - ownership 判定:在"observed pre-existing server + 本会话零 automatic
    lifecycle dispatch + observation-minted generation + 无 active/unreconciled
    managed provenance"四项证据下生产判 `.external`；任一不足保持 `.unknown`
    或保留经验证的 `.arkDeckManaged`，不得直接 managed → external；
  - endpoint source 暴露:presentation 增加 endpoint 来源(explicit/inherited/
    default)与子进程 env 注入状态(父进程 env 零修改的既有契约不变,仅暴露);
  - 设备 fan-out feed:只读 device-observation recipient(设备出现/消失事件进
    supervisor fan-out 与 presentation;不引入任何设备 mutation 路径)；其生产
    producer 必须来自先行 approved/done 的独立 OpenHarmony integration change，
    不得把 selected-device authorization capture 当成任意设备枚举。
- **TASK-OBS-002 — App 观察面**(`ArkDeckApp`,依赖 OBS-001):
  - HDCStatusView 增加计数快照、endpoint source、ownership 判定依据字段与设备
    事件列表(全部 static-text 可访问,Accessibility 可读、截图可取证);
  - signed XCUITest 覆盖新字段(M1-006 XCUITest 模型)。

## Out of scope / Non-goals

- 零 Core REQ/AC/contract/schema 变更;零 lifecycle 语义变更、零安全门放宽、
  零新增设备 mutation 路径(纯可观察性);
- 不修改 CHG-2026-006 的 SUPERVISOR-001 acceptance(其 ownership 字面在本 change
  落地 external 判定后即可达,无需 AC 修订);
- M1-009 诊断导出的 App 接线(独立关注点,防范围膨胀;M0B-002 取证以 App 面
  截图/Accessibility 读值为载体已足);
- M0B-002 真机观察本身(其解锁 = 本 change done 后另行新 readiness PR)。

## Approval and flow

V2 治理:本 propose PR 合入仅登记提案;批准须独立 approval-only PR;两任务各自
独立 readiness/实现/done PR(OBS-002 依赖 OBS-001 done)。本 change done 后:
TASK-M0B-002 以新 readiness PR 重钉交付形态与 pins(#250 记录的解除前置 (b)),
再约设备窗口。

## Approval history and r2 effect

- r1 proposal 经 PR #252 合入 main(squash `bb67f22`,status:proposed)。
- r1 正式批准:2026-07-21 由 approval-only commit
  `1e4a7c4027ecdd1142ceab2b80f4423eec586d6d` 将本 change 置为 `approved`:
  - **两任务分期 scope 与边界**:TASK-OBS-001(Kit 仪表化与分类面)与
    TASK-OBS-002(App 观察面 + signed XCUITest,依赖 OBS-001)的 objective/scope/
    allowed-paths;
  - **design §0 硬不变量**:纯可观察性——零 lifecycle/授权门语义变更
    (external/unknown 门等价性本身为测试用例)、仪表化真实性(计数器落真实调用
    点、变异可证伪、拒绝分支常量)、r1 ownership 三证据矩阵、零新增设备
    mutation 路径。r2 review 已证明三证据与原调用点定义不足，合入后由本文件
    r2 四证据/opaque-permit/successful-spawn 规则替换；
  - **验收面**:五条 change-local contract AC(OBS-COUNTER/OWNERSHIP/ENDPOINT/
    FANOUT/APPFACE-001);canonical Core AC 零认领;不改写 CHG-2026-006
    acceptance;M1-009 导出接线明确 out of scope。
- 本批准不产生任务执行:两任务保持 `blocked`,各须独立 readiness PR 转 `ready`
  (OBS-002 另需 OBS-001 done);本 change done 后 TASK-M0B-002 以新 readiness PR
  重钉交付形态(#250 解除前置 (b)),真机观察仍属 M0B-002 + 设备窗口 + 维护者
  执行。
- r2 是批准后 scope/design remediation；维护者 review/merge 本 r2 PR 即批准
  收紧后的 AC 与 blocker，并使 TASK-OBS-001 的 `ready→blocked` 生效。它不恢复
  readiness，也不批准 #265。

## Revision history

- r1 proposal 经 PR #252 合入 `bb67f22`，change 经
  `1e4a7c4027ecdd1142ceab2b80f4423eec586d6d` 批准；TASK-OBS-001 readiness
  经 `f3c9685ea70b32099c20bf7fe022bbc9aa688709` 生效。
- r2(2026-07-21)依据 prototype review remediation 收紧 counter/ownership/fan-out
  与 pin 规则，并把 TASK-OBS-001 恢复为 blocked。本 revision 仅在维护者
  review/merge 对应治理 PR 后生效；#265 不构成实现完成或 acceptance evidence。
