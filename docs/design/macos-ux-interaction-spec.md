# ArkDeck macOS UX 与交互定义

> Status：draft v0.1（design input，非 normative）  
> 交互原型：`docs/design/prototype.html`（可点击,与本文档同版本演进）  
> 行为事实源：`openspec/specs/desktop-ux-observability/spec.md` 及各 capability spec——本文档只定义 HOW(布局/组件/流转),行为冲突时以 spec 为准  
> Promotion 规则：本目录是**草稿区**(非 protected,可自由迭代);被采纳的版本在起草 M2+ 功能 change 前移入 `openspec/platforms/macos/design/` 并由该 change 的 design.md hash-pin。设计过程中发现的**行为级**缺口必须走 behavior delta,不得只画进稿子。

## 1. 设计 token

| Token | Light | Dark | 用途 |
| --- | --- | --- | --- |
| ground | `#F5F6F8` | `#1E2126` | 窗口底 |
| panel | `#FFFFFF` | `#262A31` | 卡片/栏 |
| ink | `#23272E` | `#E8EAED` | 主文本 |
| ink-2 | `#5A6270` | `#9AA3AF` | 次级文本 |
| accent | `#0E7C86` | `#4CC4CF` | 选中/可交互(唯一强调色) |
| ok / warn / danger | `#2F855A` / `#B7791F` / `#C0392B` | 提亮变体 | 语义状态,独立于 accent |
| planned | `#6D5BD0` 描边 chip | 同 | plan-only 徽标 |
| simulated | `#B7791F` 虚线描边 chip | 同 | simulated 徽标 |

字体:UI = 系统 SF(`-apple-system`);代码/路径/hash/日志 = `ui-monospace`。危险语义 = 图标 + 文字 + 边框形态,永不只靠颜色(AC-UX-005-01)。

## 2. 信息架构(REQ-UX-001)

```text
macOS 窗口
├── 左侧栏:设备列表(状态点+transport 标)、TCP/UART 显式添加入口、功能导航
│   Overview / Flash / Debug / UI Dump / Trace / History / Settings
├── 内容区:当前功能
├── 底部 Job Drawer(全局,跨页面常驻,可展开):任务、阶段、进度、日志尾部、取消/恢复
└── 启动时若有未 finalize Job:Recovery Banner 置顶于内容区之上(REQ-UX-003)
```

## 3. 横切交互模式(所有功能页复用)

### 3.1 全局 Job Drawer(AC-UX-001-01)
- 折叠态:一行 = 运行中任务数 + 最高风险任务的阶段与进度;展开态:任务列表,每项显示阶段序列、当前步、CancellationPolicy 语义化的取消按钮(「取消(在安全边界)」)、日志尾部 200 行窗口。
- 任务在任何页面可见;切页不丢失状态。plan-only/simulated 任务永久带徽标(REQ-UX-006)。

### 3.2 Recovery Banner(REQ-UX-003)
- 区分四种条目:resume-safe(主按钮「从安全边界继续」)、waiting(等待设备回连)、outcomeUnknown(仅展示中断阶段+RecoveryGuide)、可归档。
- 「结束恢复并归档为已中断」= 二次确认模态,正文明确三个「不会」:不证明设备已恢复/不停止远端任务/不回滚参数;critical child 未到安全边界时该按钮禁用并说明原因(AC-UX-003-01)。

### 3.3 危险确认模态(REQ-UX-005)
- 结构固定:标题(动词+对象)、影响范围清单(设备身份、擦除内容、不可逆项)、逐项 checkbox(erase/format 类需勾选两项)、确认按钮文字 = 完整动作(「刷写 rk3568 的 3 个分区」),不是「确定」。
- 键盘可达,VoiceOver 读出风险等级;默认焦点在「取消」。

### 3.4 执行模式徽标(REQ-UX-006)
- execute 无徽标;plan-only = 紫描边「PLANNED」;simulated = 琥珀虚线「SIMULATED + fixture id」。徽标出现在:Flash 页模式选择、Job Drawer、History 行、Session 详情、导出预览,任务结束后不消失(AC-UX-006-01)。

## 4. 各页面定义(布局→组件→关键交互→AC)

### 4.1 Overview(REQ-UX-002)
- 工具链卡:HDC path/source(external/DevEco)/client/server/daemon 版本/hash/endpoint/ownership;mismatchUnverified 显示双方版本与降级说明(AC-UX-002-01)。
- 通道保护卡:authorized 与 encrypted 分离展示;无证据 = 「未验证,按未保护通道处理」chip(REQ-HDC-008)。
- 能力矩阵:hidumper/hitrace/bytrace/param/flashd,unknown = 「无法确认」+ raw 查看入口,不显示为不存在(AC-DEV-007-01 语义)。
- 设备权限引导:permissionDenied/driverUnavailable 与 offline/unauthorized 分列,给出修复责任方,零自动提权(AC-UX-007-01)。

### 4.2 设备与授权(REQ-HDC-007)
- Unauthorized 设备点击 → 引导页:解锁设备→点「信任」;有界轮询进度;E000002(等待信任)与 E000003(拒绝/超时)分状态;重试路径不含静默 kill server。

### 4.3 UI Dump
- 三段:窗口清单(刷新;解析失败时 raw 视图+安全手输 ID)→ Recipe 四选一 + Debug 参数策略(不改变/临时开启后恢复/保持开启需二次确认)→ 产物列表(stdout/sidecar/merged 分行,标注来源与 hash,敏感提示)。
- 页内固定注明:Fault/Crash 与整机诊断快照首版不支持(scope 区分)。

### 4.4 Trace
- Preset 表 + 自定义(仅设备已确认支持的 tag 可选);duration/buffer;附件兼容 buffer 显示资源警告。
- 参数快照 diff 面板:name/before/desired/恢复策略(value 可恢复;missing/unreadable 只允许不改变或显式持久);需重启时先展示影响。
- 抓取中:无可靠总量 → indeterminate 阶段条,不伪造百分比;停止/取消区分;完成后 raw/filtered/capture.log 分列。

### 4.5 Debug 工作台
- 四 Tab:Logs(等级/tag/关键字过滤、暂停 UI、host 分片轮转状态;「清空设备 buffer」为独立危险动作,走 3.3 模态)/ Apps / Network(forward 列表增删)/ Commands(模板+精确命令回显+退出码)。

### 4.6 Flash
- 顶部模式分段控件:Execute / Plan only / Simulated(徽标即时出现)。
- Profile+Image 表(路径、size、SHA-256);Prerequisite 清单(satisfied/unsatisfied/unknown;required 未满足 → Execute 按钮禁用并指向原因,AC-FLASH-002-01)。
- Exact Plan 表:步骤、参数摘要、effect 列(hostOnly/readOnly/deviceMutation/destructive 用形状+文字);plan-only 下 destructive 行标 `notExecuted(planned)`。
- Execute → 3.3 危险确认(设备身份+分区+擦除数据);执行中:临界区提示「正在写分区——取消只停止后续步骤」+ 电源提示「请勿合盖/断电」(AC-FLASH-009-01);断连进入 rebind 确认而非静默续刷(AC-FLASH-010-01)。

### 4.7 History(REQ-UX-004)
- 过滤:状态(succeeded/failed/cancelled/planned/interrupted)、executionMode、设备、时间。
- 行:状态 chip + 模式徽标 + 设备 + 摘要;interrupted 与 failed 视觉可分(AC-UX-004-01),interrupted 带 needsAttention/unknown outcome 标记。
- 详情:manifest 摘要、参数 before/after、Artifact 列表(role/origin/hash)、「在访达中显示」、显式导出(导出前敏感提示)。

### 4.8 Settings
- HDC 候选列表(source/path/version,切换不影响运行中 Job);输出根目录;保留配额/pinned;诊断导出(默认不含设备 raw,可预览勾选,AC-DIAG-002-01)。

## 5. 原型内「AC 标注模式」
工具栏开关,打开后界面元素浮出对应 REQ/AC 编号 chip——设计走查=对照规格逐条核对。该模式是评审工具,不进产品。

## 6. 留给产品决策的视觉项
图标风格(SF Symbols 直用 vs 定制线性)、密度档位(紧凑/舒适)、Job Drawer 默认展开策略、暗色是否默认。原型当前取:SF Symbols 语义近似、舒适密度、折叠、跟随系统。
