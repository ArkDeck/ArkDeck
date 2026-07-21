---
id: CHG-2026-022-hdc-supervisor-observability
revision: 1
status: approved # 2026-07-21 本 approval-only PR(先例 #55/#89/#171/#195/#226);r1 proposal 经 #252 合入 main `bb67f22`;批准由维护者 review/merge 本 PR 构成
class: platform
core_change_level: none
owner: lvye
core_baseline: CORE-2.1.0
platforms: [macos]
---

# HDC supervisor 可观察性:仪表化计数、设备 fan-out 面、endpoint source 与 ownership 判定

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
  - 自动 lifecycle/subserver dispatch 计数器:在真实 dispatch 调用点计数(非分支
    常量),快照可读,contract 测试以变异实验证伪(注入一次自动 dispatch → 计数
    必须 >0 且测试红,绿对照在案);
  - ownership 判定:在"observed pre-existing server + 本会话零 lifecycle
    dispatch"证据下生产判 `.external`(证据不足保持 `.unknown`;判定升级零
    lifecycle 语义变更、零安全门放宽——external/unknown 门语义同等保持);
  - endpoint source 暴露:presentation 增加 endpoint 来源(explicit/inherited/
    default)与子进程 env 注入状态(父进程 env 零修改的既有契约不变,仅暴露);
  - 设备 fan-out feed:只读 device-observation recipient(设备出现/消失事件进
    supervisor fan-out 与 presentation;不引入任何设备 mutation 路径)。
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

## Approval

- r1 proposal 经 PR #252 合入 main(squash `bb67f22`,status:proposed)。
- 正式批准:2026-07-21 由本 approval-only PR(先例 #55/#89/#171/#195/#226)将本
  change 置为 `approved`;批准由维护者 review/merge 本 PR 构成。merge 即批准:
  - **两任务分期 scope 与边界**:TASK-OBS-001(Kit 仪表化与分类面)与
    TASK-OBS-002(App 观察面 + signed XCUITest,依赖 OBS-001)的 objective/scope/
    allowed-paths;
  - **design §0 硬不变量**:纯可观察性——零 lifecycle/授权门语义变更
    (external/unknown 门等价性本身为测试用例)、仪表化真实性(计数器落真实调用
    点、变异可证伪、拒绝分支常量)、ownership 三证据矩阵判 external 缺一保持
    unknown 的 fail-closed 方向、零新增设备 mutation 路径;
  - **验收面**:五条 change-local contract AC(OBS-COUNTER/OWNERSHIP/ENDPOINT/
    FANOUT/APPFACE-001);canonical Core AC 零认领;不改写 CHG-2026-006
    acceptance;M1-009 导出接线明确 out of scope。
- 本批准不产生任务执行:两任务保持 `blocked`,各须独立 readiness PR 转 `ready`
  (OBS-002 另需 OBS-001 done);本 change done 后 TASK-M0B-002 以新 readiness PR
  重钉交付形态(#250 解除前置 (b)),真机观察仍属 M0B-002 + 设备窗口 + 维护者
  执行。
