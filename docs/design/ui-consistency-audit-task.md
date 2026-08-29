# UI 稿与实现一致性核对任务（TASK-AIN-021）

> 类型：产品一致性核对任务 brief，不是新的 OpenSpec Task、Readiness Task 或批准载体。
>
> 归属：复用 protected `main` 已存在的 `TASK-AIN-021` 作为路径护栏。本文件不改变该
> Task 的状态、Acceptance、Allowed paths，不新增治理流程，也不重启已退役的
> Automation/task 平面（CHG-2026-064）。
>
> 执行形态：**可重复执行的核对回合**。每轮以执行时的 reviewed `main` commit 为基线，
> 产出逐行台账与修正 PR；未闭合项如实继承上一轮结论，不重判已登记事实。

## 1. 任务目标

设计稿/可交互原型必须与实际实现保持一致。每一轮核对回答两个问题，并以**一一核对**
的粒度留痕——枚举框架里的每一行都要有结论，不允许抽查代替全量，也不允许把
「没查」记成「通过」：

1. **组件复用**：设计系统的每个受控组件是否都有 preview、消费方与 App 对应物；
   同一视觉模式是否在原型、组件库或 App 里存在本应复用却各写一份的重复实现；
   是否有孤儿组件（导出了但无人使用、无 preview、无实现对应物）。
2. **功能实现**：设计稿呈现为「当前能力」的每个界面单元、动作、状态，实现里是否
   真实存在且行为一致；反向，App 已有的功能是否都有设计镜像。
   **稿有而实现无 = 过度承诺；实现有而稿无 = 设计漂移。两者都是缺陷。**

## 2. 事实源与权威顺序

- 产品表面的事实源 = 当前 SwiftUI 实现、本地化 `.xcstrings` 与 accessibility
  identifiers；Catalog、contracts、Runtime 返回事实与仓库安全不变量决定生产行为
  （既定规则见[《Viewer UI 实现交接任务》§2](viewer-ui-implementation-task.md)）。
- 设计侧权威顺序 = [`macos-ux-interaction-spec.md`](macos-ux-interaction-spec.md) →
  [`prototype.html`](prototype.html) → [`arkdeck-ds`](arkdeck-ds/) →
  `.design-sync/previews`（见 `.design-sync/conventions.md`）。preview 与 spec/原型
  冲突时，preview 过期。
- 不一致时的处置：
  - **稿有实现无**：先沿 View → ViewModel → facade → XPC/RPC → Catalog 调用链证实该
    能力是否真实存在于 protected `main`。不存在 → 稿改为 unavailable / 移除 / 挪入
    显式 concept 样本，或登记为产品缺口（见 §6）。**不得默认「补实现」**——是否实现
    是产品判断，不因对齐反向在 App 伪造能力。
  - **实现有稿无**：同车把原型、spec、brief 与组件镜像补齐到实现。
  - **双向禁伪造**：不得在 App 造占位成功凑齐设计；不得在稿中保留已移除的路径；
    样本数据必须明示为样本，不充当真实证据。
  - **brief↔spec 互相冲突**：单列待裁决，不静默改任何一侧（先例见审计记录既有
    冲突清单）。

## 3. 枚举框架（台账的行从哪里来）

台账的行必须从机器清单派生，**本文不重抄清单**——第二份手抄清单只会漂移：

- **界面单元**：[`implementation-coverage.json`](implementation-coverage.json) 的
  `surfaceIDs`（当前 62 个，含八页导航、动态设备页、独立 Settings / Trace Viewer /
  帮助、子标签与关键弹层），以及 `navigation` / `debugTabs` / `viewerTabs` /
  `settingsTabs` / `traceSettingsSections` 各子清单。逐单元的现行结论就是
  [审计记录 §3 全入口矩阵](implementation-audit-2026-08-27.md)——交互测试强制矩阵行
  ID 与覆盖表逐一相等，本任务直接在矩阵上更新结论，不另建平行表。
- **设计组件**：[`arkdeck-ds/src/index.ts`](arkdeck-ds/src/index.ts) 的受控导出集 +
  `.design-sync/previews/*.tsx`（覆盖表 `previewFiles`，当前 31 个）。
- **App 视图**：覆盖表 `appViewFiles`（当前 20 个）+ `ArkDeckApp/DesignSystem/` 下的
  共享实现（当前唯一共享件 `WorkspaceChrome.swift`）。
- **设计输入**：覆盖表 `designInputs`（当前 21 个文件）。
- 清单本身与 reviewed `main` 不符时（inventory equality 由
  [`workspace-interactions.test.mjs`](arkdeck-ds/scripts/workspace-interactions.test.mjs)
  强制），**先修清单再核对**。

## 4. 界面单元核对协议（每个 surfaceID 六项）

对照双侧打开同一单元：原型用 `?page=…` 加显式 state token（如
`?page=dump&viewerState=captured`、`?page=diagnostics&hilogSummary=partial`），App 用
对应 View 文件与（必要时）fixture 启动参数。逐项核对：

1. **信息结构**：区块、字段、排序与分组一致；
2. **动作集**：按钮 / 菜单 / 快捷键 / 上下文动作逐个对应，enabled·disabled 语义与
   破坏性确认流一致；
3. **状态覆盖**：empty / loading / error / partial / unknown / disabled / unavailable
   在双侧都可达，且语义相同；
4. **文案与本地化**：zh/en 成对（含 placeholder 与 AX label）、mono 字段用法、
   单位与数值边界一致；
5. **边界诚实性**：unavailable 如实呈现、无占位成功、无假状态、样本明示为样本；
6. **可达性**：spec 要求的 accessibility identifier / label / 焦点行为双侧在位。

六项全过该行才记 pass；任何一项不过，按 §6 分类登记。

## 5. 组件复用核对协议

**设计侧（每个 `index.ts` 受控导出四问）**：

1. `.design-sync/previews/` 有对应 preview？
2. 原型或组件画廊（[`session-components.html`](session-components.html)）里有消费或
   语义等价物？——机制事实：`prototype.html` 是自包含 HTML，不 import 组件库，
   判**语义等价**（同一模式的结构 / token / 状态语义一致），不判 import。
3. App 对应物是哪一个文件、哪种 SwiftUI 惯用法？逐个记到 `文件:模式` 粒度；
   对不上的记 C-UNMAPPED。
4. 是否存在应收敛的重复实现？——原型 / 组件库 / App 任一侧，同一视觉模式手写
   ≥2 份且已有（或显然应建）共享件的，记 C-DUP（先例：F43 把共享动作行的尾部
   对齐收敛到八处既有写法）。

**App 侧重复模式扫描**：横扫 20 个 View 文件，找跨 Feature 重复出现、未经共享件
承载的模式（动作行、状态徽章、campaign/job 摘要卡、筛选条、危险确认等）。收敛与否
是产品判断：收敛记 fixed，保留要写明理由记 exception，不许静默放过。

## 6. 缺陷分类与处置

| 类别 | 含义 | 处置 |
| --- | --- | --- |
| P-OVER | 稿呈现为当前能力，实现无 | 稿改 unavailable/移除/挪 concept；真实产品缺口登记进[审计记录 §5](implementation-audit-2026-08-27.md)，不建 readiness/status-only 载体 |
| P-DRIFT | 实现有，稿无或过时 | 同车更新原型/spec/brief/组件镜像 |
| C-ORPHAN | 组件无消费方、无 preview、无对应物 | 删除或写明保留理由 |
| C-DUP | 同一模式重复实现未复用 | 收敛为共享件，或记 exception 及理由 |
| C-UNMAPPED | 组件缺 preview 或缺 App 映射 | 补齐映射或降级为非受控组件 |
| H-HONESTY | 占位成功、假状态、移除路径残留、样本冒充证据 | 立即修正，优先级最高 |

每个缺陷照既有格式在[审计记录](implementation-audit-2026-08-27.md)登记为新的 F 项
（延续现有编号），**修正与登记同一 PR 同车**；需要维护者裁决的（brief↔spec 冲突、
C-DUP 的收敛取舍）单列，不静默改。

## 7. 每轮产出物

1. **逐行台账**：`docs/design/references/ui-consistency/<YYYY-MM-DD>-ledger.md`，
   一行一个核对对象（surfaceID / 受控导出 / preview / App View 文件），列 =
   对象、核对结论摘要、verdict、证据（F 项 / PR / 测试名；截图照惯例只留本机）。
   verdict 取值：`pass` / `fixed`（同车已修，链接 F 项）/ `registered`（已登记待
   裁决或待产品任务，链接 F 项或 §5 条目）/ `exception`（写明理由）。
   **全部行必须有 verdict，不留待核。**记录当轮基线 commit。
2. **矩阵与覆盖表**：§3 全入口矩阵的结论列就地更新；清单变化同步
   `implementation-coverage.json`（含 `lastReviewedRevision`），由交互测试守护。
3. **修正本身**：设计侧改动落 `docs/design/**` 与 `.design-sync/**`；确需动
   App/测试时才触 `ArkDeckApp/**`、`ArkDeckAppUITests/**` 等 TASK-AIN-021 已授权
   路径，并带上对应原生回归。

## 8. 验证

- 设计侧：`docs/design/arkdeck-ds/` 下 `npm test`（交互 + 覆盖测试）、`npm run build`
  与 `npm run build:review` 两种构建全绿。
- 原生侧：统一本地闸
  `python3 scripts/ci/plan.py --repo-root . --base-revision origin/main --head-revision HEAD --merge-base --include-worktree --run-local`
  （SDD、catalog、zero-drift 恒跑；触碰 Swift/App 时含全量并行测试与
  `build-for-testing`）。纯设计/文档轮不分配编译车道属正常分类，不是跳过验证。
- 触碰的 App 表面跑对应语言 sweep 的 XCUITest（macOS UI 套件是本地门禁，不在 CI）。
- 浏览器实测改动的原型页：同一标签核对中英文与全部 state token。
- **验证只证稿与代码一致，不构成真机验收，不翻转任何 Golden Journey 状态，
  不声称远程设计库已更新（未连接）、不声称浏览器与原生逐像素等价。**

## 9. 交付纪律

- 分支 `agent/*`；commit 与 PR 声明 `TASK-AIN-021`；push 前用 base-tree 的
  `scripts/check_pr_paths.py --preflight` 覆盖完整 diff。
- 不得在核对 PR 里修改 TASK-AIN-021 定义或扩张 Allowed paths；不发布新
  operation/provider/profile，不改 Runtime admission、Catalog digest 或设备命令
  lowering。
- PR 摘要用英文；以 draft PR 交维护者审查，合入不替代剩余真机验收。

## 10. 完成判据

一轮核对完成 = 台账全行有 verdict；组件复用与功能实现两类问题都扫过；全部缺陷
`fixed` 或 `registered`；§8 验证全绿；上一轮遗留项已继承并注明当前状态。
之后每当设计稿或 App 表面发生实质改动，重跑一轮（增量轮可只核对受影响行，但必须
在台账里写明增量范围与未重核行的依据基线）。
