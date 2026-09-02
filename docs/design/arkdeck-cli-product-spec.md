# ArkDeck 全功能 CLI 产品规格

> 类型：产品实现规格，不是新的 OpenSpec Task、Change、Readiness、批准载体或平台符合性声明。
> 状态：目标规格；文中“目标命令”不代表当前版本已经实现。
> 规格版本：0.7（2026-09-02，按当前 digest 的 headless 真机复跑记录 §13 的 Golden Journey 四态与覆盖矩阵；0.6 同日按 `PRODUCT-LOOP.md` §6 重述 §15.3 的 GJ-1/GJ-3/GJ-5 判据，并在
> §13.2 要求 operation 真机覆盖矩阵；0.5 同日由 `TASK-AIN-026` 落地 §14 机器契约产物、§13 按
> protected `main` `4bde4749` 重算；0.4 同日按 DEC-013 让 `source` 族退役并新增 `platformService` 分类；
> 0.3 同日按 `d28d57a3` 重算 §13；0.2 为 2026-08-30）；盘点基线为 29 个 canonical Catalog operation、1 个 alias、
> local control protocol `1.0.0`。实现与验收仍必须 pin exact Catalog digest，不能只比较数量。
> 权威边界：Constitution Safety invariants / POL-*、`PRODUCT-LOOP.md`、accepted specs、
> contracts、当前 `Catalog/` 与 Runtime 行为高于本文。发生冲突时本文失效，不能用本文修改
> Core 语义、放宽 admission，或恢复 raw shell/HDC/argv 执行面。
> 平台范围：定义 macOS 与后续 Windows 实现必须共享的 CLI 产品语义；不声称 Windows 当前
> 已受支持，也不提前修改 Windows platform profile。

## 1. 产品决定

ArkDeck CLI 是 Device Agent Runtime 的完整 headless 产品面。它的目标不是复刻 App 的每个
像素，而是让外部 Agent 和人类在不打开 App 的情况下完成以下闭环：

```text
发现设备 → 建立 durable target/binding → 发现 operation → 生成精确 plan
→ submit/run/wait/cancel → HumanActionRequired/resume
→ status/result/evidence → Artifact read/export → reconcile/cleanup
```

“全功能”必须同时满足四个条件：

1. 每个已发布 Catalog operation 都能通过同一套 typed Job/Agent 入口执行，不需要新增
   operation-specific executor。
2. 每个稳定 Runtime 资源都有可发现、可查询、可等待、可恢复的 CLI 入口；daemon 已有的
   正式方法不能只供 App 使用。
3. 每个 daemon method、Catalog operation 与 App 产品能力都在同一 feature coverage
   manifest 中分类为 `direct`、`generic`、`local`、`presentation`、`platformService`、
   `internal`、`refused` 或 `blocked`；不得存在 `unclassified` 暗功能。
4. 命令、请求、JSON、错误、退出码和 conformance fixture 是语言无关契约；macOS 与 Windows
   只替换 transport、service、credential、filesystem、USB 等平台 adapter。

完整 CLI 仍然不是通用终端。operation/job/device request 不得接受或执行 raw executable、raw argv、
raw shell、raw HDC、任意设备远端路径、caller-provided trusted facts，或 RuntimeCapability 的
draft/install/revoke。本地主机配置可以通过 bounded import/registration 读取用户明确选择的文件，
但必须先校验 identity/hash/trust 并产出 typed reference；后续执行只消费 reference，不能把 path
当作执行指令。
缺少 typed operation 的能力应报告 `BLOCKED_BY_PRODUCT_DEFECT`，不能绕过 Runtime 补一个隐藏
host executor。

## 2. 目标与非目标

### 2.1 目标

- 成为 GJ-1～GJ-5 的默认验收入口，App 只在 AC 明确验证 UI 呈现时参与。
- 为外部 Agent 提供无歧义、可重试、可分页、可流式消费的机器接口。
- 让人类在同一命令树中完成诊断、HAP、native library、UI dump、trace、Flash、workspace、
  history、Artifact 和 recovery 工作流。
- 把当前手写 Swift CLI 中隐含的行为抽成可生成、可验证的语言无关契约。
- 允许未来 Windows 版本以原生实现复刻相同 argv、normalized request、JSON、错误和退出语义。

### 2.2 非目标

- 不在 CLI 内置模型、聊天或决策循环；外部 Agent 决策，ArkDeck Runtime 执行。
- 不把 CLI 变成 SSH/SFTP shell、HDC passthrough、PTY 或源码调试器。
- 不为每个 daemon RPC 创建用户命令；artifact chunk upload 等内部协议必须保持内部。
- 不要求终端复刻 Timeline、UI tree、视频播放器或 AppKit/WinUI 视觉呈现；CLI 必须能读取、
  检查和导出支撑这些视图的结构化数据与 Artifact。
- 不恢复 legacy Flash campaign executor、`agent chat` 或 capability admin。
- 不以 simulation、fixture、plan-only 结果代替 `REAL_DEVICE_PASS`。
- 不借本规格提前改变 Windows profile、Core baseline、provider 或 destructive admission。

## 3. 规范词与核心术语

本文的“必须”“不得”“应”“可以”分别对应 MUST、MUST NOT、SHOULD、MAY。

| 术语 | 含义 |
|---|---|
| live device | HDC 当前观察到的 candidate，可能 connected、unauthorized 或 offline；不是 durable target |
| target | Runtime 持久化的设备身份与 profile 引用 |
| binding | target 到当前真实设备事实的已确认绑定，带单调递增 revision |
| operation | protected `main` Catalog 中的 versioned typed operation |
| job | Runtime 持久化的 plan、dispatch、journal、terminal/recovery 状态 |
| Agent execution | 以 `executionId` 幂等标识的 durable 高阶编排；可在 Job 创建前进入 HAR |
| artifact | Runtime 管理的 immutable 本地内容；owner 是 Job 时可成为 result/evidence，owner 是 Import 时只是 typed input；隐私与导出规则由 Artifact contract 决定 |
| import | host file 经 schema/identity/digest 校验后形成的 durable typed-input owner；不是伪 Job |
| session | 由 Runtime/Storage 组合 Job、Artifact 与 retention/pin/export 状态的 durable 会话；不是 CLI 进程 |
| HumanActionRequired | Runtime 持久化并暂停 owner 的 typed 有限人类动作；不是聊天确认或新 authority |
| control action | 非 Job 的 durable 本机控制动作，例如 HDC lifecycle preview/restart；也必须有 owner、generation、audit 与 HAR |
| RuntimeCapability | Runtime 生成并消费的精确 authority；CLI 只能引用或只读检查，不能管理 |
| portable core | macOS/Windows 必须保持相同的命令、请求、结果、错误和状态语义 |
| platform extension | service、credential、update、host tool 等语义相同但实现依赖平台的命令 |
| presentation-only | App 的本地渲染/组合能力；CLI 以结构化读取或导出形成能力等价 |

## 4. 单一执行架构

```text
Human / external Agent
        │ argv + files/stdin
        ▼
declarative command registry
        │ parse + local validation
        ▼
typed request builder ────── domain convenience preset
        │                    (never an executor)
        ▼
local control client
  macOS: user-private Unix domain socket
  Windows: user-private named pipe
        ▼
transport-free daemon handler
        ▼
Runtime admission → Job/WAL → Provider lowering → device
        │
        └──────────────► immutable Artifact / evidence / recovery
```

CLI 的所有用户选择 device workflow/template 与 Catalog operation execution 必须落到以下二者之一：

- `job plan/submit/run/...`：精确控制 Runtime 资源生命周期；
- `agent run/resume`：为外部 Agent 提供 discovery、adoption、binding、HAR、evidence 和 Artifact
  inventory 的高阶组合入口。

唯一窄例外是 accepted contract 明确发布的 bounded read-only discovery/probe Runtime method，
例如 candidate/availability/prerequisite observation。它们只能返回带 freshness/reason 的观察，
不得产生 Job result、Runtime evidence 或冒充 operation 完成。只要 method 执行用户选择的
device workflow/template（即使是闭集且 read-only），就必须进入 Catalog + Job/WAL，不属于该例外。

target adoption、Artifact Import、HAR resume、control action、loader binding 等不是 operation
executor，而是具名 typed resource lifecycle；它们必须使用本文列出的 Runtime-owned durable
owner/WAL/CAS contract，不能直达 provider，也不能产生/冒充 operation result 或 device evidence。

领域命令只是 typed request builder。例如 `trace capture` 可以构造
`capture.diagnostics@1` 的输入，但不能拥有第二套 HDC 调用链。新增 Catalog operation 后，通用
`operation` + `job` + `agent` 入口必须自动可达；领域别名可以随后增加，不能成为 operation
可执行性的前置条件。

## 5. 命令模型

### 5.1 统一语法

```text
arkdeck [global-options] <command-path...> [arguments] [global-options]
```

规则：

- command、verb、option 名在所有平台使用小写 kebab-case，并按字节区分大小写。
- parser 接收操作系统已经拆分好的 argv 数组；规范和 fixture 不使用 shell command string。
- 每个 leaf 必须拒绝未知、重复、缺值、互斥和不适用参数，不得静默忽略。
- `command-path` 由一个或多个 registry token 组成，可以表达 `job status`、
  `runtime service install` 或 `debug template run`。global option 可以统一放在第一个 path token
  前，或完整 leaf arguments 后；同一 option 在两个区域重复仍然拒绝，path token 之间不插入
  global option。
- `arkdeck help <path>`、任意层级 `--help`、`-h`、`--version` 必须 exit 0。
- parser、help、completion、Markdown reference 和 option tests 必须由同一 command registry
  生成，不能继续维护一块手写 usage 字符串。
- registry 必须区分 executable leaf 与 parse-only compatibility tombstone。tombstone 可使旧 token
  得到 stable replacement/refusal，但不得持有 Runtime method/operation executor mapping。
- 无参数时显示 root help 并 exit 0；非法 command 才 exit 64。
- 稳定资源名使用 singular；返回 collection 的 verb 使用 `list` 或领域明确的
  `candidates`。`help`、`commands`、`completion` 是 registry meta-command，不是资源名例外。

### 5.2 全局参数

| 参数 | 语义 |
|---|---|
| `--output human\|json\|jsonl` | 输出模式；默认 `human` |
| `--endpoint default` | 使用当前用户的默认本地 Runtime endpoint |
| `--timeout <duration>` | 仅限制 CLI 等待；不得扩大 operation、plan 或 capability budget |
| `--no-color` | 禁用 human ANSI；machine 模式始终无 ANSI |
| `--quiet` | 隐藏非必要 human progress；不得隐藏 terminal error |
| `--control-request-id <id>` | 为本次 control-plane 调用指定可追踪 identity，不等于 Job request identity |
| `--help`, `-h` | 当前节点帮助 |
| `--version` | CLI product、command registry schema、control protocol、machine-contract bundle/组件版本与 build identity |

`--endpoint` 只能选择本地 transport。正式产品不得支持 `tcp://`、`http://` 或远程 daemon。
macOS 的 `--socket <absolute-path>` 只作为兼容别名；Windows 不把 named-pipe 路径暴露成业务
参数。测试可使用显式 `unix://` 或 `npipe://` endpoint，但必须验证本地性和当前用户访问边界。
“全局参数”只表示语法位置全局，不表示每个 leaf 都可忽略它。`--endpoint` 只能用于
registry 声明会连接 Runtime 的 leaf；`--socket` 又只能用于当前已声明该兼容别名的
Runtime-client leaf。Flash 历史解码、`update-feed`、`agentd` service 管理与 `signing`
等未宣布该 option 的路径必须拒绝它，不得静默丢弃。

duration 的完整语法是 `^[1-9][0-9]*(ms|s|m|h)$`；不接受零、负数、小数、组合单位、
空格或裸整数。每个 option 在 registry 中另行声明数值上限，解析时必须防止溢出。
`--timeout` 是本次 CLI 进程等待 local control 响应/事件的 wall-clock 上限；
`agent run --maximum-wait` 是持久在 execution 中、跨进程 re-entry/resume 消耗的 orchestration
budget。前者可以更短，但不会延长或重置后者，也不会改变 descriptor/plan/
capability budget。超时只停止客户端等待：

- 已经成功 submit 的 Job 继续由 Runtime 拥有；
- CLI 只有收到明确 cancel 请求时才调用 `job.cancel`；
- destructive dispatch 结果不明时返回 attention/unknown，绝不猜测失败后重放。

`maximum-wait` 在 AgentExecution 首次 durable commit 时开始，定义为包含 HAR 暂停、client
disconnect 和 Runtime restart 时间的 absolute elapsed wall-clock budget；Runtime 必须持久化
`createdAt`、`deadline` 与 `lastObservedAt`，resume/re-entry 不得暂停、续期或重算 deadline。
同一进程内同时使用 monotonic clock 防止 wall clock 调整延长等待；跨进程比较新的 UTC 与持久化
high-water。时钟倒退到 `lastObservedAt` 之前或无法取得可信时间时返回
`orchestrationClockUntrusted`、exit 77、dispatch 0，不以 clamp 后继续的方式暗中延长预算。
到达或超过 deadline 时返回 `orchestrationBudgetExpired`、exit 75、dispatch 0；已创建的 Job
仍由 Runtime 拥有，不被隐式取消。

### 5.3 输入来源与优先级

通用 Job/Agent 输入只允许两种互斥形式：

```text
--request-file <path|->

或

--operation <reference>
[--target <target-id>]
[--expected-binding-revision <positive-int>]
[--inputs-file <path|->]
[--request-id <id>]
[--idempotency-key <key>]
[--capability <capability-ref>]
[--reviewed-plan-digest <lowercase-sha256>]
```

高阶 Agent 入口另有以下 orchestration 字段：

```text
agent run ... [--execution-id <id>] [--maximum-wait <duration>]
agent resume --resume-reference <ref>
  [--selection <string> | --selection-file <path|->]
```

`--maximum-wait` 只限制 Agent 的 discovery/HAR orchestration 预算；它必须随同一
execution 持久化，不能被 re-entry 重置，也不能改变 operation descriptor timeout、
materialized plan budget 或 capability expiry；其 absolute deadline、暂停计时和 clock-drift
语义以 §5.2 为准。

- `-` 只表示从 stdin 读取一个无 BOM 的 UTF-8 JSON document；v1 上限为 3,145,728 bytes，
  并且编码后含 delimiter 的完整 control frame 也不得超过 4,194,304 bytes。
  超限在连接/派发前返回 `inputTooLarge`。
- v1 control request frame 上限是 4,194,304 bytes、response frame 上限是 8,388,608 bytes，
  两者都包含唯一末尾 LF 且不含 BOM；恰好等于上限可接受，`+1` 必须拒绝。CLI 对自己编码的
  oversized request 在连接前返回 `inputTooLarge`。server 对尚未形成完整 frame 就超限的 peer
  立即关闭该 connection、handler/dispatch 计数为 0；不得解析 prefix。response producer 必须用
  page/range/chunk/Artifact 保证单帧有界；若仍会超限，改发一个有界 `protocolMalformed` error。
  client 收到超限 response 或 delimiter 前断连也不得解析 prefix；只读请求映射
  `protocolMalformed`，mutation acceptance 不明则映射 `outcomeUnknown` 并只允许 status/reconcile。
- `--request-file` 与所有 flag-form request 字段互斥。
- operation reference 必须是 Catalog 发布的 exact token：canonical form 是 `<id>@<positive-version>`；
  unversioned token 只在 Catalog 明确发布为 alias（当前 `flash.dayu200`）时合法。CLI 不补默认/latest
  version、不把 alias 改写成 canonical request，也不接受大小写变体。
- `--inputs-file` 的根必须是 JSON object，并按 operation descriptor 验证。
- v1 不定义 `name=value` 或 shell-like inline JSON；这样 PowerShell、cmd.exe、zsh 与 bash
  的 quoting 差异不会进入产品契约。
- target Runtime request schema v2 对所有 operation 都要求 exact durable target：`job plan/submit`
  的 flag form 和 request-file 即使对 host-only operation 也必须携带 `targetID`，但 host-only 不得
  伪造 binding revision。device-bound operation 还必须携带 expected binding revision。只有高阶
  `agent run` 的 orchestration intent 可以省略 `--target`，再通过 typed discovery/HAR 得到二者后
  才构造 v2 Runtime request；未来若允许真正 target-less request，必须提高 request schema version。
- flag form 必须允许 caller 固定 request identity 与 idempotency key；自动生成值可以是交互式
  默认，但不得成为自动化重试的唯一行为。
- capability 只能是 reference。`--capability` 仅适用于 `job submit`、`agent run` 及其 domain run
  mapping；`job plan` 必须拒绝，因为 plan 只报告 required capability。CLI 不读取 authority
  document，不接受 trusted facts，也不生成、安装、扩大或撤销 capability。
- `--reviewed-plan-digest` 是 request-envelope precondition，只允许 `job submit`、`agent run` 及其
  domain run mapping；`job plan` 和其他 leaf 必须拒绝。它不属于 operation inputs、canonical
  request identity 或 authority。request-file 可携带同名顶层字段；flag/file 两种来源继续互斥。
- resume selection 的 `--selection <string>` 只适用于 HAR selection schema 根类型为 string 的
  enum/identifier，值是 OS argv 提供的 exact Unicode scalar sequence，不做 JSON parse/coercion；
  任意 JSON scalar/object/array 使用互斥的 `--selection-file <path|->`，读取恰好一个无 BOM UTF-8
  JSON value，沿用 3,145,728-byte document cap 并按 referenced HAR schema 验证。HAR 不接受
  selection 时两个 option 都拒绝；impact-approval HAR 也不得借 stdin/file 承载 confirmation。
- `--request-file`/`--inputs-file` 无论来自路径还是 stdin，JSON document 都使用相同的
  无 BOM/UTF-8 与 3,145,728-byte 上限；UTF-8 BOM 返回 `invalidInput`，不得剥离后改变
  canonical identity。文件读取还必须拒绝类型漂移，并在打开后校验稳定 file identity；实现不能先检查路径
  再跟随被替换的 symlink/reparse point。
- 所有 caller JSON（request、inputs、selection、registration、action）必须在 schema decode/normalization
  前拒绝 duplicate object key 和不能组成有效 Unicode scalar sequence 的 escaped surrogate（例如孤立
  `\uD800`）；不得依赖 Swift/.NET decoder 的 first/last-wins 或 replacement-character 行为。
  失败统一为 `invalidInput`、exit 65、dispatch 0；JCS 的相同限制只是该通用输入规则的子集。
- host tool、daemon bundle、signing material 等本地文件只能进入有 kind/schema/size/trust policy 的
  registration/import leaf。成功后返回 content-addressed typed reference；Runtime service、Job 和
  Provider 不得继续消费 caller path。
- password、private key material 和 credential/access/bearer token 不得经 argv、环境变量、
  JSON、日志或 shell history
  进入 CLI；需要秘密时只从 no-echo console 或平台 credential reference 获取。
  HAR `resumeReference` 是指向 Runtime-owned exact action 的 opaque local reference，不是 credential
  token 或 authority；仍必须避免写入无关诊断和 completion cache。

## 6. 目标命令树

目标命令树分为“稳定资源层”“领域工作流层”“平台/维护者扩展”。表中的命令是目标产品面，
不是当前实现清单。

### 6.1 稳定资源层

| 命令 | 语义 |
|---|---|
| `help <path>` | 从 registry 输出对应 node/leaf 帮助；未指定 path 时输出 root help |
| `commands` | 输出当前 command registry projection；`--output json` 是 Agent 发现入口 |
| `completion bash\|zsh\|fish\|powershell` | 从同一 registry 生成可直接加载的静态脚本；成功 stdout 只有脚本 bytes |
| `doctor [--deep] [--require-healthy]` | 汇总 Runtime、Catalog、provider、HDC、storage、target 和未决恢复问题；只读 |
| `runtime health` | 返回 control protocol、catalog digest、provider 和持久 store 健康 |
| `operation list` | 列出 canonical 与 alias reference、alias lineage、availability、effect、binding、profile |
| `operation describe --operation <ref> [--target <id>]` | 返回完整 descriptor；有 target 时再计算 target-dependent availability |
| `operation example --operation <ref>` | 输出可提交的 request/inputs 示例，不 dispatch |
| `operation validate --operation <ref> --inputs-file <path\|->` | 本地按 descriptor 验证，不访问设备 |
| `device candidates` | 固定 snapshot generation，列出 lifecycle-scoped observation ID、live candidate key、authorization/health、observed time 及 adopted-target 关联 |
| `device wait --candidate <key> --observation <id> --observation-generation <n> --state connected\|unauthorized\|offline` | bounded poll 同一 live observation lifecycle；只读，不自动 adopt 或跟随 key reuse |
| `device display-name set --candidate <key> --observation <id> --observation-generation <n> --name <text>` | 设置 exact 未 adopt observation 的有界本地显示名；不改 identity |
| `device display-name clear --candidate <key> --observation <id> --observation-generation <n>` | 仅清除 exact observed candidate 的本地显示名 |
| `target list` | 列出 durable targets 与 binding revision |
| `target show --target <id>` | 返回一个 target、profile、binding、last facts 和状态 |
| `target adopt --candidate <key> --observation <id> --observation-generation <n>` | 经 Runtime 重观察 exact snapshot 后建立/更新 durable binding；歧义/漂移时 fail closed |
| `target observe --target <id>` | 以 `observe.device@1` 读取并验证 tool/device/binding facts |
| `target availability --target <id>` | 聚合 operation/tool/profile availability；名称不与 RuntimeCapability 混淆 |
| `target display-name set --target <id> --expected-generation <n> --name <text>` | CAS 设置 durable target 的有界本地显示名 |
| `target display-name clear --target <id> --expected-generation <n>` | CAS 清除显示名；不改变 target/binding identity |
| `job plan ...` | materialize exact plan，不 dispatch |
| `job submit ...` | 幂等创建 Job，不隐式执行 |
| `job run --job <id>` | 执行 fresh Job，或从 Runtime 证明的安全边界继续 |
| `job wait --job <id>` | 等待 terminal/HAR/unknown，超时不取消 |
| `job events --job <id> [--after-cursor <cursor>] [--page-size <1..1000>]` | 返回一页 durable event；每个 request 恰好一个 response |
| `job watch --job <id> [--after-cursor <cursor>]` | 循环读取 `job events`，以 JSONL/human event 观察并支持恢复 |
| `job list` | 固定 page envelope，支持 order/cursor/include-current/include-timeline |
| `job status --job <id>` | 返回 compact state、progress、outcomeUnknown 与 next action |
| `job show --job <id>` | 返回完整稳定 Job snapshot；不替代 `status` 的脚本契约 |
| `job result --job <id>` | 聚合 terminal status、verified evidence 与 Artifact inventory |
| `job evidence --job <id>` | 验证并返回 trusted result evidence；不会创造新事实 |
| `job cancel --job <id>` | 请求 Runtime 在允许的边界取消；不把请求成功误报为已取消 |
| `job reconcile --job <id>` | 只按 accepted recovery 规则读回/结算；unknown destructive intent 不 replay |
| `artifact quota` | 返回 store total/used/remaining 与 policy identity |
| `artifact import <kind> --import-request-id <id> ...` | 幂等导入有注册 schema 的 host file；chunk RPC 保持内部 |
| `artifact import list [--target <id>] [--state <state>]` | 重新发现 in-progress/committed/released/aborted Import |
| `artifact import inspect (--import <id>\|--import-request-id <id>)` | 按 returned Import ID 或 caller-stable request ID 读取 upload/commit、target/digest/lease/generation 与引用状态 |
| `artifact import abort --import-request-id <id> --expected-generation <n>` | 显式终止 resumable in-progress upload 并回收 staging；不删除 committed Artifact |
| `artifact import release --import <id> --generation <n>` | 释放未被 Job 引用的 import pin；进入 retention，不直接删除任意 Artifact |
| `artifact list (--job <id>\|--import <id>)` | 按 exact tagged owner 返回固定分页 inventory |
| `artifact inspect (--job <id>\|--import <id>) --artifact <id>` | 返回 owner、media type、privacy、bytes、digest、publish 状态 |
| `artifact read ...` | bounded range read；sensitive 内容要求显式许可 |
| `artifact export ...` | 显式导出到 host destination；默认不覆盖 |
| `capability list` | 只读列出 Runtime capability diagnostic projection |
| `capability inspect --capability <id>` | 只读检查 exact scope、lineage、expiry、consume 状态 |
| `agent run ...` | discovery→binding→submit→run→evidence→Artifact 的高阶默认入口 |
| `agent list [--state <state>] [--operation <ref>] [--target <id>]` | fixed page 重发现 durable execution；不投影 typed inputs/secret |
| `agent status --execution-id <id>` | 查询可能尚未创建 Job 的 durable execution 与 `nextAction` |
| `agent abandon --execution-id <id> --expected-generation <n>` | 只终止尚未创建 Job 的 orchestration；不等于 Job cancel |
| `agent resume --resume-reference <ref> [--selection <string>\|--selection-file <path\|->]` | `human-action resume` 的 convenience wrapper；只消费 AgentExecution-owned、非 impact-approval 的 typed physical assistance |
| `human-action list [--owner-kind <kind> --owner <id>]` | 列出 Runtime-owned waiting/resolvedByFreshProbe/expired HAR |
| `human-action show --human-action <id>` | 读取 owner、minimum action、selection schema、expiry 与 resume reference |
| `human-action resume --human-action <id> --resume-reference <ref> [--selection <string>\|--selection-file <path\|->]` | 在 Job、Agent execution 或 control action owner 内消费 exact HAR |
| `control-action list [--kind <kind>] [--state <state>]` | 固定分页列出 durable host control action；用于 receipt 丢失后的重发现 |
| `control-action show --control-action <id>` | 返回 exact action/preview/generation/state/HAR/audit/`nextAction`；只读，不执行或确认 |
| `control-action reconcile --control-action <id>` | 只执行该 typed host action 已发布的 status/readback；unknown lifecycle intent 不 replay |
| `recovery cleanup list` | 列出 typed cleanup residue/debt |
| `recovery cleanup continue --job <id> ...` | 继续 Runtime 已记录且仍在 owner boundary 内的 cleanup |
| `recovery flash-invocation list` | 固定分页重发现 current protected Flash recovery invocation；不读取任意 archive path；实现见 `cli-flash-invocation-list.md` |
| `recovery flash-invocation start --invocation-request-id <id> ...` | 以 caller-stable request identity 幂等创建或返回同一 closed decision document；迁名不改变 admission |
| `recovery flash-invocation evaluate --invocation <id> ...` | 只在 exact invocation owner 内求值；不创建新 authority 或 replay intent |
| `recovery flash-invocation status (--invocation <id>\|--invocation-request-id <id>)` | 两种 identity 严格互斥；读取同一 owner，供 lost receipt 唯一重取 |
| `session list/show` | 资源化后的 Session 发现/检查；不得直接扫描 App 私有目录 |
| `session pin --session <id> --expected-generation <n>` | CAS pin，返回新 generation；阻止 retention cleanup |
| `session unpin --session <id> --expected-generation <n>` | CAS unpin；只恢复 retention eligibility，不立即删除 Session/Artifact |
| `session export preview/apply` | generation-bound 内容/隐私/脱敏预览后显式导出 |
| `session cleanup preview/apply` | generation-bound retention preview/apply；exact apply 请求本身是显式 confirmation，无独立 confirm leaf |
| `history filter list/save/delete` | 有 schema 的本地 query preset；不更改 Job/Artifact |

`job result` 是外部 Agent 的主要读取入口。它不把 App 的 view model 序列化出来，而是返回：

```json
{
  "job": {},
  "terminal": true,
  "outcomeUnknown": false,
  "evidence": {},
  "artifacts": [],
  "cleanup": [],
  "nextAction": null
}
```

非 terminal Job 调用 `job result` 返回结构化 `resultNotReady` 和 exit 75；`job status/show` 对
同一状态仍是成功的只读查询并 exit 0。

### 6.2 领域工作流层

领域命令必须由 registry 声明其精确 Catalog mapping 或 Runtime method。没有 mapping 时命令必须
不可用并明确报告产品缺口，不能在 CLI 内自行执行设备命令。

| 命令族 | 目标 leaf | 底层唯一事实源 |
|---|---|---|
| `screen` | `capture`, `record` | `capture.diagnostics@1` typed preset；`capture.screen-sequence@1` |
| `input` | `tap`, `long-press`, `swipe` | `input.*@1` |
| `diagnostics` | `capture`, `inspect`, `preview`, `export` | `capture.diagnostics@1` + Job/Artifact；preview 为纯本地派生 |
| `ui-dump` | `capture`, `inspect`, `hit-test`, `component-detail` | diagnostics typed preset + versioned parser；无 raw hidumper |
| `trace` | `probe`, `capture`, `inspect`, `export` | `trace.probe` + `capture.diagnostics@1` + Artifact |
| `analyze` | `trace`, `trace-summary`, `hilog-summary`, `crash-signature` | 四个 `analyzer.*@1` operation |
| `debug` | `probe`, `template list/run`, `hap`, `native deploy`, `logs` | bounded debug probe RPC（CLI contract 见 `cli-debug-probe.md`）；`template list` 是闭集模板表的本地投影、`template run` 映射 `debug.template@1`（见 `cli-debug-template.md`）；`logs` 是 `capture.diagnostics@1` 的 HiLog-only typed preset（见 `cli-debug-logs.md`）；`debug.hap@1`、deploy operation |
| `port-forward` | `create`, `remove` | `port-forward.*@1` |
| `flash` | `device-access`, `bootloader-status`, `prerequisites`, `lane-preview`, `bind-loader`, `run` | Flash Runtime methods + `flash.full-restore@1`；plan 使用 generic `job plan`，当前 major 的 `flash plan` 保持 tombstone；没有 legacy executor |
| `workspace` | `project list/show/register/update/remove`, `preset list/show/register/update/remove`, `status`, `diff`, `inspect`, `read`, `isolate`, `checkpoint`, `patch`, `revert`, `build`, `test`, `sign`, `symbolize`, `sweep`, `continuation inspect/submit/run` | 注册 workspace/project/preset resource + 已发布 `workspace.*@1` operations + 从原记录构造的新 typed request/Job |
| `trace cache` | `status`, `purge` | 本地派生数据库的 typed lease/retention surface；不删除原始 trace Artifact |

当前 Catalog 到目标领域命令的 canonical mapping 如下。这个表用于证明现有 operation coverage；
所有 operation 同时保留 generic `agent run --operation ...` 和 `job ... --operation ...` 入口。

| Catalog reference | 目标 convenience command |
|---|---|
| `observe.device@1` | `target observe` |
| `capture.diagnostics@1` | `diagnostics capture`；screen/UI dump/trace typed preset |
| `capture.screen-sequence@1` | `screen record` |
| `input.tap@1` | `input tap` |
| `input.long-press@1` | `input long-press` |
| `input.swipe@1` | `input swipe` |
| `debug.hap@1` | `debug hap` |
| `debug.template@1` | `debug template run` |
| `deploy.native-library.app-owned@1` | `debug native deploy` |
| `port-forward.create@1` | `port-forward create` |
| `port-forward.remove@1` | `port-forward remove` |
| `analyzer.analyze-trace@1` | `analyze trace` |
| `analyzer.summarize-trace@1` | `analyze trace-summary` |
| `analyzer.summarize-hilog@1` | `analyze hilog-summary` |
| `analyzer.extract-crash-signature@1` | `analyze crash-signature` |
| `flash.full-restore@1` | `flash run` |
| `flash.dayu200` | legacy alias；convenience 不生成，但 generic caller 的 exact explicit alias request 仍交已发布 Runtime contract，历史引用原样展示 |
| `workspace.inspect-git-status@1` | `workspace status` |
| `workspace.inspect-diff@1` | `workspace diff` |
| `workspace.inspect-source@1` | `workspace inspect` |
| `workspace.read-source-range@1` | `workspace read` |
| `workspace.prepare-isolated-copy@1` | `workspace isolate` |
| `workspace.create-checkpoint@1` | `workspace checkpoint` |
| `workspace.apply-patch@1` | `workspace patch` |
| `workspace.revert-patch@1` | `workspace revert` |
| `workspace.build-openharmony@1` | `workspace build` |
| `workspace.run-tests@1` | `workspace test` |
| `workspace.sign-openharmony-hap@1` | `workspace sign` |
| `workspace.symbolize-crash@1` | `workspace symbolize` |
| `workspace.sweep-isolated-copies@1` | `workspace sweep` |

`flash.dayu200` 与 `flash.full-restore@1` 的 input schema 不同。CLI convenience command 只生成
canonical `flash.full-restore@1` request；若 caller 在 generic surface 显式提交 legacy alias，CLI
必须保持原 reference/request 并交给已发布 Runtime alias contract 处理，不能在客户端猜测字段映射。
历史 Job、plan、evidence 与 Artifact 必须保留其原始 operation reference。任何 alias migration
都必须是独立、versioned、带 canonical fixture 的 typed transform，不能以“归一化显示”改写
destructive intent。

领域命令遵循以下约束：

- `screen capture`、`ui-dump capture` 和 `trace capture` 是
  `capture.diagnostics@1` 的不同 typed preset；effective effect 仍由 materialized plan 决定。
- `flash run` 等价于构造 `flash.full-restore@1` request 后调用 `agent run`，不得复活
  `flash execute` 的旧 host path。
- `workspace` 命令只能使用已注册 workspace reference、artifact reference 和 typed relative
  range；不得接收 raw remote root 或 raw build command。
- 远端构建来源（App 的 Remote Build Source）按 DEC-013 归 `platformService`，不进入本命令树：
  CLI 以 `artifact import native-library` + `debug native deploy` 达到同一产品结果，不把 App 的
  SSH/SFTP 代码包装成 CLI；只有 accepted Golden Journey 明确要求 headless 远端取件时才另起
  source resource change。
- `ui-dump inspect/hit-test`、diagnostics preview 和 trace inspect 属于 deterministic local
  derivation；必须记录 parser/version/source Artifact digest，不能把派生结果冒充新设备证据。
- `trace export` 不是派生或新 evidence；它要求 exact Job/Artifact reference，并在导出前验证
  `capture.diagnostics@1`、`trace.htrace`、`application/octet-stream` 与 `sensitive` 四个 typed
  metadata 字段，实际字节写入和 overwrite 仍由 Runtime Artifact policy 拥有。
- 单帧/序列转视频是 presentation convenience；frame archive、index、时间和 digest 可读取即满足
  portable core。平台可另加 derive/export，但不能改变源 Artifact。

五个 capture preset 共用 `ArkDeckWorkflows.DiagnosticCapturePreset` 作为 App/CLI 唯一输入 owner。
它们继续使用通用 domain leaf 的 `--inputs-file`，但只接受各自的 descriptor 子集，并在连接 Runtime
前拒绝其他 recipe 的字段：

| 命令 | `--inputs-file` projection |
|---|---|
| `screen capture` | 可省略；仅可选 `screenshotImageType: "png"|"jpeg"`，其余截图选择由 preset 固定 |
| `ui-dump capture` | 可省略或 `{}`；固定选择 screenshot、UI dump 与 component tree |
| `ui-dump component-detail` | 必须只含 `windowId`、`componentId` 两个 1...20 位十进制字符串 |
| `trace capture` | 必须含 `durationSeconds`、`traceCategories`、`traceBufferKB`；仅可另带 boolean `ringBuffered` |
| `debug logs` | 必须含 `durationSeconds`（1...600）；仅可另带 `hilogFilters`（≤16 个 typed component filter）；其余 leg 固定关闭，与 App Debug workspace 的 `submitLogs` 共用同一 preset |

这组 projection 不替代完整 operation schema。需要其他 `capture.diagnostics@1` 组合的 caller 仍通过
generic `agent run --operation capture.diagnostics@1 --inputs-file ...` 提交 descriptor-validated inputs。

### 6.3 平台与维护者扩展

| 命令族 | 目标 leaf | 便携语义 |
|---|---|---|
| `runtime service` | `install`, `update`, `restart`, `status`, `verify`, `uninstall` | 管理当前用户的 local Runtime；实现由 platform profile 选择 service/broker adapter |
| `runtime tool` | `register`, `list`, `inspect`, `select`, `remove` | bounded 校验 host tool 后生成 typed tool reference；active selection 使用 lifecycle preview/control action；不是 executable passthrough |
| `runtime bundle` | `register`, `list`, `inspect`, `remove` | bounded 校验 signed daemon bundle 后生成 typed bundle reference；service install/update 只消费 reference |
| `runtime hdc` | `status`, `impact-preview`, `restart` | 展示 exact tool/server facts；preview 建立 control action，mutation 必须 generation-bound、typed、audited |
| `runtime signing` | `install-sdk-release`, `install`, `normalize`, `migrate-deveco`, `status`, `remove` | 安装边界读取 bounded 本地材料并只发布 path-free `credential:sha256-*` resource；秘密由平台 credential adapter 持有，后续 workspace/Job 只传 credential ref |
| `runtime storage` | `status`, `policy`, `root` | 未来 typed storage surface；不能直接修改 App preference 文件。`status` 必须来自 Runtime 拥有的单一 store owner，并把 Session 输出域与 Runtime artifact 域分开报告（不同 root、不同 quota、不同保留策略），不得合并成一个数字；owner 化之前该 leaf 保持 `unavailable`，不得基于 per-process 偏好副本报告 status。这是有范围的延期而不是空白：Runtime artifact 域已有一等 leaf `artifact quota`（total/used/remaining），延期只扣住没有可信来源的 Session 输出域，caller 不必为此另建第二条路径 |
| `runtime support-bundle` | `preview`, `export` | 先预览清单/隐私，再显式导出 |
| `runtime update` | `check`, `download`, `handoff`, `status`, `cancel`, `cleanup` | 用户同意与验证边界一致；不得静默安装 |
| `maintainer update-feed` | `prepare`, `assemble` | 发布维护工具；不接触 private key |
| `legacy flash` | `status`, `reconcile` | macOS historical archive compatibility；仅解码/结算，不创建新 campaign/dispatch，Windows portable core 不要求 |

平台扩展可以因当前 platform profile 不支持而返回 `unsupportedOnPlatform`，但同一 leaf 的输入、
状态、错误和成功语义不能因平台而变化。Windows 不需要实现 macOS-only historical archive 工具
才能声称 portable core conformance；支持范围必须在 feature coverage manifest 中明确。

## 7. 资源行为契约

`doctor` 是 diagnostic query：只要完成了 bounded 检查并产出结构化
`overall`/`ready`/`findings`，即使发现 unavailable 也 exit 0。`--require-healthy` 用于 merge/
automation gate；发现 blocker 时返回 `healthRequirementFailed` 与 exit 69。只有连最小报告都
无法完成时才返回 transport/protocol/internal error。

报告使用 `arkdeck.doctor-report/1`。finding 的 `severity` 固定为 `info|warning|blocker`，CLI 只读取
Runtime 计算出的 `ready`，不得解析 summary 或复制 blocker registry。`--deep` 增加有界的 live HDC
identity、Runtime Artifact quota 与 cleanup-debt 检查；每个子检查失败形成 blocker finding，不得抹掉
其他已完成检查。storage 必须分别投影 Runtime Artifact 与 Session output 两个 owner 域；Session owner
发布前明确返回 unavailable，不能把进程本地 App 偏好或两个 root 的数字拼成一个健康结论。

### 7.1 Device 与 Target

`device` 和 `target` 必须分开：

- `device candidates` 只描述本次 discovery snapshot；结果必须有 generation/observedAt、
  Runtime-issued lifecycle-scoped opaque observation ID、candidate key、authorization state、health 和
  adopted target link。generation 对该 observation 的 facts 版本化；只有 Runtime 能持续证明同一
  canonical candidate relation 时 observation ID 才可跨 generation 保持。relation 中断、无法证明或
  connect-key reuse 必须签发新 observation ID，不能把 ID 当作 durable target identity。
- `device wait --state` 的 v1 枚举只是 `connected`、`unauthorized`、`offline`，分别投影
  provider 当前的 `Connected`、`Unauthorized`、`Offline`；拒绝未知值和大小写别名。
- `target list/show` 只描述 durable identity、profile 与 binding revision。
- `target adopt` 与 candidate display-name mutation 必须携带 candidate key + observation ID + exact
  snapshot generation。Runtime 在 adopt 前重新观察并核对 snapshot relation；generation 漂移返回
  `resourceConflict`，同 generation 下 identity/fresh facts 不匹配返回 `factsDrifted`，两者都零
  binding/local mutation，绝不跟随 connect-key reuse。standalone `target adopt` 已收到 exact
  observation，因此不得用 `targetSelectionRequired`/`targetAmbiguous` 假装仍需选择：unauthorized
  返回 `targetTrustPending` + exact observation details，human mode 指引调用同 observation 的
  `device wait` 后以新 generation 重试；identity 无法验证返回 `admissionDenied` +
  `newDispatchCount: 0`。它不创建 ownerless HAR；只有先建立 AgentExecution 的 `agent run` 才能在
  zero/multiple/unauthorized discovery 分支持久化 selection/trust HAR。
- `device wait` 是只读 transition wait：从 caller 的 observation ID/generation 开始，可以跟随较新
  generation，但仅当 Runtime 证明 observation ID 和 canonical candidate relation 持续为同一
  lifecycle；成功返回 final generation。observation 被替换、key reuse 或 relation 无法证明时返回
  `resourceConflict`，不能把新 device 的状态当成旧 wait 完成。
- Agent selection HAR 对 candidate 不暴露裸 key 作为 selection value，而返回 Runtime-issued opaque
  `candidateSelectionRef`，durable 绑定 candidate key、observation ID/generation 与 expiry；resume
  仍执行同一 reobserve/CAS，漂移时重新产生 selection action，不默认采用新 observation。
- 任意 device-bound plan/dispatch 前都重新核对 fresh facts 与 expected binding revision。
- 不存在“默认第一台设备”。`--target` 缺失只允许高阶 `agent run` 进入 typed selection flow。
- `device wait` 只轮询；等待 unauthorized device 变为 available 不等于用户批准任何 mutation。

当前 `device list`/`device show` 都调用 `target.list` 的行为不属于目标语义，见兼容章节。

### 7.2 Operation 与 Availability

`operation describe` 必须完整投影 Agent 做决定所需的已发布信息：

- canonical/alias reference、title、provider、profiles；
- minimum/permitted effect、authorization mode、binding、concurrency key；
- typed input constraints/defaults 与 output fields；
- steps、cancellation、compensation、retry、timeout、output budget；
- Artifact name/role/media/privacy/required；
- unknown-outcome/recovery contract；
- 当前 target/tool/profile facts 下的 availability 与 evidence timestamp；
- example request。

不带 `--target` 时，`operation describe` 只返回静态 descriptor、host/tool availability 与
target-dependent `unresolved` reason；带 `--target` 时才可依据 Runtime 的 fresh binding/profile/
tool facts 计算 target-dependent availability。`target availability` 是未来聚合 Runtime surface，
不能由 CLI 用陈旧的多次查询自行宣称设备可用。

CLI 不复制 Catalog validator。生成的 descriptor model、Runtime validator、CLI local validator 与
Windows validator 必须运行同一 canonical vectors。

### 7.3 Job

- `plan` 只 materialize，返回 authoritative `materializedPlanDigest`、catalog digest、binding revision、
  effects、steps、budgets、required capability、availability 和 blocking reasons；exit 0 不代表设备
  验收通过。v1 没有 durable plan resource/plan ID/list/show，CLI/Windows 不得从 digest 伪造一个。
- caller 将 `plan` 返回的 lowercase plan digest 作为 `reviewedPlanDigest` 提交时，Runtime 必须在
  preauthorization/admission 之前重新 materialize 并精确比较。mismatch 返回
  `reviewedPlanMismatch`、exit 65、零新 admission/Job/dispatch；同 idempotency key 命中 existing Job
  时也必须比较 existing materialized digest。该 precondition 不进入 intent fingerprint，不能变成
  capability 或改变 operation semantics。
- `submit` 以 idempotency key 创建或返回同一 Job。相同 key + 不同 canonical request 必须 conflict。
- `run` 只接受 Job ID。它不得允许 caller 替换 plan、facts、capability 或 resume point。
- `wait/watch` 观察 Runtime 状态，不通过重复 `run` 实现轮询。
- `cancel` 是请求；结果必须区分 requested、accepted、safe-boundary pending 与 terminal cancelled。
- `reconcile` 只执行 accepted readback。destructive outcome unknown 时不得重新 dispatch。
- `result` 只有在 Job terminal 且 evidence 可验证时才报告 completed outcome；Artifact 缺失或 digest
  不匹配必须作为 evidence failure 暴露。
- retry 自动化必须复用 request identity/idempotency key 或 existing Job ID，不能每次随机生成新 Job。
- list 的 JSON shape 不得因是否传 cursor 而从 array 变成 object；始终返回 page envelope。
- `job events` 是按 opaque cursor 读取的 unary page RPC；`job watch` 只负责重复读页、
  按 stable event ID 去重并渲染。旧 timeline string array 不是 event store。
- target `job plan`、`job submit`、`job run` 默认协商 control protocol 2.x，并共享一个有界的
  client wait deadline；`--timeout` 只限制 CLI 等待，不取消或延长 Runtime Job。plan 返回闭合的
  `arkdeck.job-plan/1`，submit 返回闭合的 `arkdeck.job-acceptance/1`（含 `jobId`、
  `deduplicated`、`newDispatchCount: 0`），run 返回与 `job status` 相同的
  `arkdeck.job-status/1`。CLI 必须验证完整 shape 后才输出，不能把未知/缺失字段当成功。
- 已 terminal 或不存在的 Job 若在 `run` 的 Runtime-owned pre-dispatch check 被拒绝，返回 exact
  owner identity、`phase: "preAdmission"` 与 `newDispatchCount: 0`；进入 shared driver 后的
  任何 ambiguous failure 不得沿用该证明，按 mutation unknown 处理。

所有 list/events 的 `result` 必须使用固定 page shape：

```json
{
  "schemaVersion": "arkdeck.cli.page/1",
  "pageKind": "snapshot",
  "items": [],
  "order": "createdAtDescJobIdAsc",
  "snapshotRevision": "rev-...",
  "hasMore": false,
  "nextCursor": null
}
```

普通 list 使用 `pageKind: "snapshot"`，cursor 绑定 method、filter、order 与 snapshot
revision；`hasMore: false` 时
`nextCursor` 为 `null`。event cursor 则绑定 Job stream 与 exclusive event position，
event page 必须使用 `pageKind: "eventStream"`、固定 `order: "streamPositionAsc"`，其
`snapshotRevision` 是本页的 monotonic high-water mark。每个 item 带同一 Job stream 内严格递增、
以 canonical decimal string 编码的 `streamPosition`；cursor 位置是 exclusive，下一页只能返回
严格位于该 position 之后的事件。`eventId` 只提供稳定 identity/去重，不承担排序语义。即使
`hasMore: false`，`nextCursor`
也必须返回可用于下一次 bounded poll 的 high-water cursor。cursor 不透出 store path/offset；
malformed/forged/cross-query/filter/order cursor 返回 `invalidCursor`；认证有效但 stream position 已被
retention 回收则返回 `eventHistoryUnavailable` + earliest retained position。两者都不猜测从头/
earliest/tail 继续。
`--after-cursor` 缺省表示从 retained Job stream origin 开始，不是“从现在 tail”；若 origin 已因
已发布 retention policy 回收，首次读取返回 `eventHistoryUnavailable` 并在 bounded details 给出
earliest retained position，不静默跳过历史。需要 tail-only 行为必须以后作为独立、显式 registry
option 发布。
每个 snapshot list 的 registry order token 必须代表 total order，不允许依赖 SQLite rowid、dictionary
iteration 或本地 filesystem order。`job list` 的 v1 token `createdAtDescJobIdAsc` 明确先按
`createdAt` descending、timestamp 相同时按 ASCII `jobId` ascending；其他 list 同样声明 stable
identity tie-break，cursor 与 fixture 固定完整 compound order。
event log 与可恢复 cursor 的 retention 不得短于可 query 的完整 Job record；不能给 active/
non-terminal Job 设置独立短 TTL。只有 schema 明确标成 summary-only 的 retained Job 才可缺历史，
并必须走上述 gap reason；Job record 已整体回收则正常返回 `resourceNotFound`。
`pageSize` 是 item count 上限而非最低保证；producer 为遵守 8,388,608-byte response frame cap
可以返回更少 item，但只要仍有数据就必须 `hasMore: true` 并给出 advancing cursor。单个 item 本身
无法有界编码时返回 schema-specific reference/Artifact，而不是截断 JSON 或无限缩小到零进展页。

`job status` 与 `agent status` 共用 `nextAction` projection；没有下一动作时为 `null`，
否则 shape 固定为：

```json
{
  "kind": "humanAction",
  "owner": {"kind": "agentExecution", "id": "exec-..."},
  "resource": {"kind": "humanAction", "id": "har-..."},
  "reasonCode": "device.trustPending",
  "resumeReference": "resume-...",
  "expiresAt": "2026-08-30T12:00:00Z"
}
```

所有非空 `nextAction` 都必须包含 `kind`、tagged `owner`、tagged `resource` 和 stable
`reasonCode`；branch 外字段拒绝。各分支的闭合 schema 为：

| `kind` | `owner.kind` | `resource.kind` | branch 必需字段 | 禁止/说明 |
|---|---|---|---|---|
| `wait` | `job`、`agentExecution` 或 `controlAction` | 与 owner 相同 | `retryAfter` | 不得含 resume reference 或 expiry；只建议 bounded poll |
| `humanAction` | `job`、`agentExecution` 或 `controlAction` | `humanAction` | `resumeReference`、`expiresAt` | `expiresAt` 可为 `null`；只有此分支可以含 resume reference |
| `reconcile` | `job` 或 `controlAction` | 与 owner 相同 | 无 | 表示 existing owner 的 accepted readback，不授权 replay |
| `cleanup` | `job` | `cleanupDebt` | 无 | cleanup resource 必须归属该 Job |
| `readResult` | `job` | `job` | 无 | 只表示 terminal result 可读 |

`retryAfter` 使用 §5.2 duration 语法；它是 client poll hint，不延长任何 budget。
v1 minimum `reasonCode` mapping 是：`humanAction` exact 复制 referenced HAR 的 accepted reason code；
`wait` 使用 `job.running`、`agent.orchestrationPending` 或 `lifecycle.pending`；`reconcile` 使用
`recovery.outcomeUnknown`（Job）或 `lifecycle.outcomeUnknown`（control action）；`cleanup` 使用
`recovery.cleanupDebt`；`readResult` 使用 `job.resultAvailable`。新增值必须先进入 versioned
next-action schema vocabulary/fixture，不能由平台自由造词。
`nextAction` 是可发现 reference，不是 authority；selection schema 和 minimum action 必须从
referenced resource 读取。unknown `kind`、owner/resource 配对或 branch 字段必须以
`recordUnreadable` fail closed，而不是降级为 human prose。

### 7.4 Agent execution 与 HumanActionRequired

`agent run --execution-id <id>` 先创建或重入 Runtime-owned durable Agent execution。其 canonical
request 包含 operation、typed inputs、target/binding/capability reference 与 orchestration budget：

canonical identity 只包含 caller 首次提交的 intent；target/binding 只在 caller 显式提供时入参。
Runtime 后续 discovery/HAR 得到的 resolved target、fresh facts、Job ID 和 progress 是该 execution 的
durable state，不得反写 canonical request digest，否则无 target 的合法 re-entry 会伪冲突。
首次 execution commit 还必须把 optional `reviewedPlanDigest` 作为 immutable execution precondition
单独持久化。它不进入 intent fingerprint/authority，但同 execution re-entry 的 present/missing 与
exact value 必须和 stored precondition 一致，否则 `idempotencyConflict`、零进展/dispatch；不能在
pre-Job HAR 后省略/替换 digest 来弱化检查。创建 Job 时仍以 fresh materialized plan 执行
`reviewedPlanMismatch` 比较。

- 同 execution ID + 同 canonical request 必须返回同一 execution、当前 HAR/Job 和结果，
  绝不产生新 dispatch；
- 同 execution ID + 不同 canonical request 返回 `idempotencyConflict`、exit 65 与 dispatch 0；
- terminal execution 重入返回原 terminal result；paused execution 重入返回原 HAR，不自动 resume；
- 丢失 stdout 后可用 `agent status --execution-id` 恢复，即使 HAR 发生在 Job 创建之前；
- 交互式调用可生成 ID，但必须在首个 machine/human receipt 中输出并持久化。
- `agent list` 必须投影 execution ID/generation、created time、operation ref、可公开 target、state 与
  `nextAction`，不投影 inputs/capability/selection。这样 auto-generated ID 的首个 receipt 丢失时仍可
  bounded 重发现；自动化仍应主动指定 ID，不能按“最近一个”猜测。
- `agent abandon` 与 Job creation 在同一 execution owner transaction 串行。abandon 先线性化则标记
  terminal abandoned、停止 discovery，并把 waiting HAR/resumeReference 原子标为 `expired`（后续
  resume 为 `humanActionExpired`）且零新 dispatch；Job 先线性化则 abandon 返回
  `resourceConflict` + Job identity，caller 必须显式 `job cancel`。client disconnect、`--timeout`、
  deadline expiry 都不等于 abandon/cancel；expired/abandoned execution 的 re-entry 返回原状态。
  `agent abandon` transition 成功返回 `ok:true`/exit 0，`agent status` 查询 abandoned 也 exit 0；
  `agent run` 对 terminal abandoned execution 的 replay 返回 `ok:true` bounded execution result、
  `executionOutcome:"abandoned"` 与 exit 1。

HAR 是 Runtime 资源，owner 必须是 tagged union：`job`、`agentExecution` 或
`controlAction`。现有 `HumanActionRequired` document 类型可作为 Job-backed contract 输入，但
生产持久化/list/show/resume 必须经 Runtime owner boundary；CLI 本地 pending file 不满足本规格。

HAR receipt 至少包含：

- stable action identity 与 tagged owner identity；
- execution/job/control-action identity（如适用）；
- stable reason code；
- 用户要做的有限物理动作；
- typed selection schema（如适用）；
- `resumeReference`/action identity；
- expiry 与等待预算；
- 当前没有新 dispatch 的明确状态。

receipt、`nextAction.resumeReference`、`human-action show` 与两个 resume leaf 必须使用同一个 exact
opaque `resumeReference`；CLI 不派生、重编码或另发一套 token。`agent resume` 仅是对
AgentExecution-owned、非 impact-approval HAR 的 typed convenience mapping，其余 owner/category
必须引导到 `human-action resume` 或稳定拒绝。

human 模式可以在 stderr 显示可复制的 resume 示例；JSON 模式不得把 prompt 文字混入 stdout。
用户确认不能扩大 capability、覆盖 facts drift 或让 unknown destructive intent replay。

### 7.5 Session export 与隐私

- Session `pin/unpin` 必须由 App/CLI 共用的 typed owner 执行 generation CAS；generation drift 返回
  `resourceConflict`，不得 last-write-wins。重复 intent 只有携带当前 generation 才可形成新变更；
  unpin 不等于 cleanup，也不改变 Artifact evidence/privacy。
- `session cleanup preview` 返回 generation、preview ID/digest、将回收/保留的 Session/Artifact refs、
  bytes/privacy/reasons/expiry；`apply --preview-id <id> --preview-digest <digest>` 是唯一显式确认与
  mutation leaf，执行前重验 generation/leases/pins。target registry 不存在独立 `confirm` token；
  任何 App 的三阶段 view-state confirm 只是在调用同一 apply contract 前的 presentation。
- `session export preview` 必须返回 generation、preview ID/digest、每项内容的 Artifact identity、
  privacy、预计 bytes、脱敏策略、默认排除项与 expiry。
- raw UI dump、trace、HiLog、截图和其他 sensitive device evidence 默认排除；选择纳入时必须显式
  标记，并继续受 Artifact export policy 约束。
- `session export apply --preview-id <id> --preview-digest <digest>` 只能导出 exact preview；
  generation、Artifact、privacy policy 或 destination facts 漂移时拒绝。
- preview/apply 不能修改源 Session 或 Artifact，不能把派生脱敏包冒充原始设备证据。

### 7.6 Artifact 与隐私

- `artifact read` 必须支持 `--offset` 与 `--max-bytes`，并返回实际 offset、bytes、EOF、digest
  identity；默认有界。
- `--offset` 是 `[0, totalByteCount]` 内 non-negative safe integer。`--max-bytes` 缺省
  1,048,576，显式值只接受 `1...4,194,304`；0、负数、overflow 或超限返回 `invalidInput`，不得
  silent clamp。JSON result 固定包含 `artifactId`、`artifactDigest`、`offset`、`nextOffset`、
  `totalByteCount`、`eof`、`byteCount`、`base64`；`base64` 使用
  [RFC 4648](https://www.rfc-editor.org/rfc/rfc4648) standard alphabet + `=`
  padding、无 whitespace，decoded length 必须等于 `byteCount`，`nextOffset = offset + byteCount`。
  4 MiB chunk 编码后仍必须满足 8 MiB response frame cap。
- `artifact read --raw` 时 stdout 只能是原始 bytes，不能混入 JSON 或 progress；Windows 必须使用
  binary stdout mode；bytes 必须是同一 range result 的 strict base64 decode，并在输出前验证
  byteCount/range/digest identity，不能走第二套 store read 语义。
- `artifact list/inspect/read/export` 必须接受恰好一个 tagged owner：`--job <id>` 或
  `--import <id>`。Import-owned Artifact 不出现在 Job list/status/result/evidence，也不能因
  可 read/export 就被标为真实设备证据。
- `--raw` 与 `--output json/jsonl` 互斥。脚本若需要 metadata，先调用 `artifact inspect`。
- sensitive Artifact 的 read/export 必须显式 `--allow-sensitive`；human warning 不是 authority，
  也不能改变 Artifact privacy。
- `artifact export` 默认拒绝覆盖。`--overwrite` 只授权 exact destination file，且不能绕过
  sensitive export 许可。
- import 必须流式、有 size/digest 校验、commit/abort；begin/append/commit 不作为公开 leaf。
- public import 必须要求 caller-stable `importRequestId`。CLI 在 upload 前计算 canonical metadata：
  kind、target/binding、registered schema/profile ref、logical name（schema 要求时）、byte count 与
  content SHA-256；host path 不入 identity。相同 request ID + 相同 metadata 对 in-progress/committed
  Import 返回同一 Import ID/current state/最终 receipt，不重传或再 pin；不同 metadata 返回
  `idempotencyConflict`。begin 必须先 durable 记录 request→Import mapping 再接收 bytes；aborted
  request 重试仍返回原 aborted state，重新导入必须用新 request ID，不能复活 generation。
- client timeout/interruption 不自动 abort resumable import。`artifact import abort` 与 append/commit
  在同一 Import owner 串行；abort 先线性化则回收 staging 并保留 request tombstone，commit 先线性化
  则 abort 返回 `resourceConflict`，caller 后续使用 generation-bound `release`。
- public import retry 必须重新打开并验证 stable file identity/size/full digest，再读取 durable
  `nextOffset`；只从该 offset 继续。internal append frame 绑定 import ID/generation、exact offset、
  chunk byte count + SHA-256：同 offset/same chunk 幂等返回同一 nextOffset，不同 bytes/overlap/gap
  返回 `resourceConflict`，绝不 silent overwrite。lost append response 先 inspect nextOffset，再决定重试
  exact chunk 或继续；commit 对同 request/metadata 幂等。source full digest 漂移返回
  `artifactIntegrityFailed`，durable staged prefix 自检不一致返回 `recordUnreadable`；两者都不自动
  abort/重头覆盖。begin/append/commit 仍是 CLI 内部 protocol，不成为 public leaf。
- 每个 append 的完整 chunk bytes、chunk digest 与 durable `nextOffset` 必须在同一 Import owner
  transition 中线性化：crash 后要么该 chunk 全部 committed，要么 recovery 在暴露 state 前截断/回滚到
  last committed offset。partial chunk 永不成为可 inspect 的 prefix，不能让 exact retry 因 crash
  落入 overlap 或 `recordUnreadable`；mid-chunk crash 必须有恢复 fixture。
- 当前注册导入种类的目标语法是：

  ```text
  artifact import hap|workspace-patch|flash-bundle|native-library \
    --import-request-id <id> --target <id> --file <path>
  ```

  Flash profile 必须真实参与 validation/pinning；不能保留一个被 parser 接受但随后丢弃的
  `--device-profile`。
- commit 必须返回 durable Import ID、Import-owned Artifact identity、target、digest、lease 与
  generation。`artifact import list/inspect` 必须在输出丢失后可重新发现它，不要求 caller
  永久保存首次 receipt；尤其 `inspect --import-request-id` 必须在 commit response 丢失后唯一找回
  同一 Import，而不是按 target/kind/digest 猜多个 owner。
- 当前 import receipt 中用于 Artifact store namespace 的 synthetic `jobId` 只是
  `legacyArtifactOwnerId` 兼容字段，不对应 Job engine record；目标 client 不得用它调用
  `job status/list/result/evidence`，Windows 也不得为它创建伪 Job。
- `artifact import release` 只释放 exact generation 的 import lease/pin。仍被 active Job/plan 引用、
  generation 漂移或 retention 不允许时必须拒绝；成功也只表示可由后续 retention 回收，
  不是立即删除 immutable evidence 的后门。
- 同一 Import ID + 已成功释放的同一 generation 重试必须幂等返回原 release receipt，且不再次
  改变 generation/refcount；不同 generation 返回 `resourceConflict`。这样 lost response 在 macOS/
  Windows 上不需要二选一猜测“幂等或拒绝”。
- Job/plan 对 imported input 的 acquire 与 release 必须在同一 Runtime store owner/transaction 内原子
  串行，不得先查引用再单独 unpin。acquire 先线性化则 release 以 `resourceConflict`
  拒绝；release 先线性化则后续 acquire 拒绝并要求重新 import，不复活已释放 lease。
- device path 永不出现在 CLI input。provider-owned remote path 只可作为受限 evidence/diagnostic
  projection，并按隐私规则处理。

### 7.7 Capability 与 Recovery

- `capability list/inspect` 只用于诊断。executable registry 与 default help/completion 中不得出现
  `draft/install/revoke`；现存 wire refusal 必须留在 coverage，旧 CLI token 如需识别只能是
  parse-only `refused` tombstone，绝无 executor mapping。
- caller 可以提交已有 capability reference；Runtime 仍必须验证 exact operation/target/plan/facts/
  expiry/reservation。
- legacy record、聊天确认、CLI flag 或本规格不得生成 authority。
- cleanup continuation 只能引用 Runtime 已记录的 residue key/bundle identity；看似路径的字段也
  不能变成自由远端路径。
- current protected destructive Flash recovery 从 `debug` 命名空间迁到
  `recovery flash-invocation ...`；迁名不改变其 closed decision document 或 authority。`start` 必须
  要求 caller-stable `invocationRequestId`：same ID + same canonical request 返回同一 invocation，
  different request 返回 `idempotencyConflict`。`list` 与按 request ID/Invocation ID 的 `status`
  必须在首次 receipt 丢失后唯一重发现 owner；不得按“最近一次”猜测，也不得因重试生成第二份
  decision document。

### 7.8 Runtime 与 HDC lifecycle

- 为避免 fresh install 的 daemon bootstrap paradox，tool/bundle registration 由 current-user、
  versioned local bootstrap registry 持有，App/CLI 共用同一 owner；它可以在 Runtime 未运行时完成
  bounded copy/hash/signature/trust 并返回 typed ref。`runtime service install` 重新验证 registry
  record/content identity/permissions 后才交给 platform service adapter，启动后的 Runtime 只 adopt/
  consume ref。该 registry 不是 authority store，不接受 executable argv，也不得让 caller path 在
  registration 后继续参与 install/update。
- `runtime bundle register --kind daemon-bundle --file <path>` 必须执行 kind/platform/schema/size、
  stable file identity、content hash、signature/trust 校验并返回 content-addressed bundle ref +
  generation。`runtime service install/update --bundle <ref>` 只消费该 ref；不得接收 caller path。
  bundle remove 只允许 exact generation 且当前 install、rollback slot、pending service action 与 durable
  audit/reference 均不再依赖；acquire/remove 使用与 tool 相同的 store-owner serialization，历史 record
  引用的 bytes 按 retention 保留。
- `runtime service restart/update/uninstall` 必须先读取 active/unclosed Job、HAR、cleanup、unknown
  outcome 与 catalog identity；会破坏这些 owner boundary 时拒绝，不能用 `--force` 绕过。只有
  未来正式发布的 typed handoff contract 才能改变这一条件。
- 任意 service/bundle/tool/update action 若可能停止、重启、替换或重新绑定 ArkDeck-managed HDC
  child/server，必须组合或复用本节同一个 HDC impact preview → control action → HAR → accepted
  `mutateHDCServerLifecycle` 路径；无法证明无 HDC lifecycle effect 时拒绝。generic service action
  不得间接 kill/restart shared HDC 来绕过 owner、generation、critical Job 或确认 gate。
- `runtime hdc status` 必须报告 exact executable path/source/hash/signature、client/server/daemon
  version、endpoint、ownership 与 generation；unknown 字段不能用默认值填充。
- `runtime tool register` 的 kind 决定唯一 input schema：single executable（如 HDC）使用 `--file`；
  existing SDK/toolchain（如 DevEco SDK）使用 `--root` 并验证 root file identity、versioned manifest、
  allowlisted child tool identity/hash/trust。两者互斥且只在 registration 接收 host path，返回 typed
  ref/generation；preset/service/Job 后续不得重新解析 caller root 或接受 raw argv。
- `runtime tool select --tool <ref> --expected-active-generation <generation>
  --action-request-id <id>` 是 tool-selection preview 的唯一入口，首次调用只创建/返回 durable
  control action，不直接改 preference。preview 必须包含 old/new exact tool refs、content hash、
  signature/version/trust、active generation，以及受影响 endpoint/device/Job/client 和预期 HDC
  interruption/recovery；action request id 遵守与 HDC preview 相同的幂等规则。若改变 active
  HDC/daemon toolchain，必须返回 owner-bound impact-approval HAR，并经 §7.8 的 interactive carrier
  后按 WAL 三段执行：先原子持久化并 pin old/new facts 与 typed lifecycle intent，再 dispatch 并
  记录外部 lifecycle outcome，只有验证 exact outcome 后才原子发布新 active selection。不得只改
  preference 就把新 executable 当成 trusted active tool；失败/unknown 时保留旧 published
  selection、pending control action 与 reconcile path，不能留下“已选新 tool、仍运行旧 server”
  的伪健康状态。
- `runtime tool remove --tool <ref> --expected-generation <generation>` 只能移除未被选中的 exact
  generation，且 Runtime store owner 必须证明没有 non-terminal Job、AgentExecution、recovery、
  control action 或 active lease 的 durable reference。当前 active selection 必须先经上述 typed
  control action 选择另一 tool；不得由 remove 隐式切换。reference acquire/remove 必须在同一
  owner transaction 串行：acquire 先线性化则 remove 返回 `resourceConflict`，remove 先线性化则
  acquire 拒绝。被历史/terminal record 引用的 content bytes 按 retention 保留，任何已持久化 owner
  都不得产生 dangling tool reference。
- `runtime hdc impact-preview --action restart --server-endpoint-ref <ref>
  --expected-server-generation <generation> --action-request-id <id>` 以零 lifecycle mutation
  计算影响并持久化 preview/control-action record。相同 action request ID + 相同 canonical request
  返回同一 control action，不同 request 返回 `idempotencyConflict`；交互式调用可生成 ID，但首个
  receipt 必须输出。receipt 至少包含 `controlActionId`、`previewId`、canonical `previewDigest`、
  exact lifecycle action、endpoint、server ownership/generation、affected device/target 与 Job、
  detected other clients，以及“未检测到不证明不存在”的 unknown-client warning、预期中断、恢复/
  reconcile path、owner、expiry、`confirmationRequired: true` 和 `dispatchCount: 0`。未 adopt
  device 使用 typed `affectedDeviceObservations`，每项含 Runtime-issued lifecycle-scoped
  `observationId`、exact observation generation 与 authorization/health；observation ID durable 绑定
  Runtime 能证明持续的 canonical internal candidate relation，generation 对 facts 版本化。relation
  中断或 key reuse 后的新 observation 必须使用新 ID；该 ID 不是 target identity，也不暴露易变 raw
  transport string。preview 还必须含
  `criticalJobGate`：`clear | blocked | unknown`、blocking Job/Step、safe-boundary/recovery action；
  `blocked`/`unknown` 都禁止确认与 dispatch。这些字段的
  canonical value 集合一起进入 preview digest；`control-action list/show/reconcile` 必须能在输出丢失后
  重取同一 record。
- control-action request fingerprint 也固定使用 `sha256-jcs`，但和 preview digest 是两个字段。
  HDC request intent object 只含 schema version、kind/action、typed server endpoint ref 与 expected
  server generation；tool-selection intent object 只含 schema version、kind、new tool ref 与 expected
  active generation。action request ID 是 idempotency key，controlAction/preview ID、timestamp、owner、
  resolved impact 等 derived fields 都不进 intent fingerprint。same ID + different fingerprint 必须
  `idempotencyConflict`，不能返回或覆盖旧 preview。
- 新 control-action preview 的 `previewDigest` 固定为 §8.2 `sha256-jcs`：digest input 是去掉
  `previewDigest` 自身后的 versioned preview object，至少含上述
  `controlActionId`/`previewId`/action/endpoint/ownership/generation、typed interruption/recovery、
  owner/expiry、`affectedDeviceObservations`、`criticalJobGate` 和三个 ID collection。
  `affectedTargetIds`、`affectedJobIds`、
  `detectedOtherClientIds` 先按 ASCII ID bytes 升序且去重，unknown-client warning 编码为稳定 boolean
  `otherClientsMayExist: true`；`affectedDeviceObservations` 按 `observationId` ASCII bytes 升序且去重，
  `criticalJobGate.blocking` tuple 按 `jobId` 再 `stepId` ASCII bytes 升序且去重。human prose 不进
  digest。只有 value 全等的 duplicate 可 collapse；相同 observation ID 或 `(jobId,stepId)` key
  携带不同 generation/health/gate/recovery value 时返回 `factsDrifted`、不生成可确认 preview，不能由
  dictionary last-write-wins。tool-selection preview 另加入 old/new tool
  ref/hash/signature/version/trust 与 expected active generation，使用同一算法。任何 accepted contract
  已定义的现存 digest 仍按 §8.2 opaque pass-through；这里仅定义本规格新增 product record。
- `runtime hdc restart --control-action <id> --preview-id <id> --preview-digest <digest>` 只能请求
  exact action。需要人类确认时它返回绑定 HAR 与 dispatch 0，不因 TTY/调用者存在
  就直接 restart。执行前必须重新观察并 canonicalize preview 中的完整 impact projection，包括
  executable/endpoint ownership + generation、所有 affected device observation/target/Job/client 集合、
  unknown-client warning、expected interruption/recovery 和完整 critical Job gate；除 preview 自身的
  immutable ID/digest/owner/expiry 外，每个 canonical value 都必须与已确认 preview exact equal。
  任一集合成员或成员 value 新增、消失、漂移、无法精确投影，或出现 active mutation/digest mismatch/
  expiry，均返回 `previewDrifted`、零 lifecycle mutation并写 host-wide audit；旧 confirmation/HAR
  立即失效，caller 必须用新 action request ID 创建并重新确认新 preview，不能原地改写旧 record。
- host-wide audit 必须记录 durable intent、实际 executable identity + provider-owned argument array、
  endpoint、dispatch result、generation before/after 与全部 affected Job/control action；argument
  array 只作为受隐私/secret redaction 的 Runtime audit fact，绝不回流成 caller 输入或普通 help。
- restart 的 owner 是 `controlAction`，不伪造 Job。non-interactive Agent 必须收到 owner 精确指向
  `controlActionId` + preview ID/digest/generation 的 impact-approval HAR。该 HAR 必须声明
  `category: "impactApproval"`、`reasonCode: "policy.impactApprovalRequired"` 与
  `prohibitedAutomation: ["selfApproval"]`；external Agent 只能展示/等待，不得自行调用
  `agent resume` 或 `human-action resume` 代人确认。由人类发起的 `human-action resume`
  是唯一 confirmation transition，它触发同一 control action 的 dispatch-time revalidation；
  最终 mutation 只能经 accepted `mutateHDCServerLifecycle` typed step。App 和交互式 CLI 也必须使用
  同一 typed action；不得把普通 restart RPC 的调用者存在本身当作人类确认。
  确认不是 authority，不能覆盖 owner/facts/critical-Job gate。
- `category: "impactApproval"` 且 `reasonCode: "policy.impactApprovalRequired"` 的 HAR 只能由
  App 的 explicit confirmation UI，或真实前台
  TTY/Console 中的 `human-action resume` 消费。CLI 必须在 argv/JSON 完成解析后显示 Runtime
  新签发且绑定 controlAction/preview/digest/generation 的 one-time challenge；confirmation 不得从
  argv、stdin JSON、环境变量、文件、配置或 preseed response 提供。无 interactive console、
  challenge 不匹配或 stdin 被重定向时返回原 HAR、dispatch 0；`agent resume` 对该 reason 必须
  返回 `admissionDenied`。confirmation receipt 必须持久化 exact action/preview/generation/challenge、
  `interactionOrigin: "appExplicitUI" | "interactiveConsole"` 与确认时间，并在 mutation 前再次消费
  one-time challenge。此 carrier 只证明一次显式交互，不产生 authority；accepted HDC contract
  仍是准入事实源。
- external/unknown owner 禁止自动 lifecycle mutation，但 accepted HDC contract 允许用户对 exact
  generation-bound preview 显式确认一次手动 restart。该动作不得转移 ownership，也不授权随后
  stop/start/restart 或其他 lifecycle action。
- shared endpoint restart 失败或 outcome unknown 时，Runtime 必须向所有受影响 coordinator/Job
  持久 broadcast 同一 lifecycle outcome、阻止新 dispatch，并按 preview 中的 recovery path 进入
  status/readback/`control-action reconcile`；任何 client 都不得把局部连接恢复等同于 server
  mutation 成功。reconcile 只读 exact endpoint/generation/ownership/tool facts 并结算原 action，
  永不再次 dispatch lifecycle intent。
- CLI 不得提供 `hdc kill/start/restart --force`、raw HDC 参数或 executable override。需要新的
  lifecycle 语义时先补 typed audited product surface。

### 7.9 Workspace 发现与安全续跑

- fresh host 必须能用 CLI 建立 workspace 配置，不依赖 App/预置 daemon flags。
  `workspace project register --registration-request-id <id> --kind <kind> --root <path>` 是允许 host
  root path 的 bounded registration leaf：打开后验证 directory/file identity、no-follow/reparse、
  scope/schema/size policy，并在 private Runtime config 中持久化 root grant，公开只返回 stable
  `projectRef` + generation，不回显 root。same request ID + same canonical registration 返回同一
  project，different request conflict。`update/remove` 必须 expected-generation CAS，active Job/
  continuation 引用时拒绝；remove 只删 grant/config，不删用户源码。
- `workspace preset register/update/remove` 同样 request-idempotent/generation-bound，并按
  `build|test|signing|symbol` kind 接受 typed constraints。SDK/toolchain 必须先形成 registered toolchain
  ref，signing 只接受 credential ref；preset 永不接受 raw executable/argv。project/preset remove 与
  Job acquire 在同一 owner transaction 串行，不能产生 dangling ref。
- macOS signing credential owner 把现有 measured receipt/Keychain envelope 包装成独立
  `arkdeck.signing-credential/1` resource。content ref 不含 host path、Keychain account 或秘密；owner
  使用跨进程锁和 crash marker 串行 install/replace/remove。workspace signing preset 注册必须在同一
  durable dependency transaction 同时 pin exact toolchain ref 与 credential ref；update 先 acquire 新
  dependency set、发布 preset generation，再幂等释放旧 set；remove/restart 在服务任何读取前结算未完成
  release。任一 active preset 引用存在时，credential replace/remove 必须稳定拒绝。
- `runtime signing normalize` 和 daemon identity refresh 只能执行保持 content ref 的维护；可能改变
  key alias 的 `migrate-deveco` 属于 replace，必须遵守 active-reference gate 并返回新 ref。`status`、
  maintenance 与 removal projection 不得回显 receipt path、材料 path、Keychain account 或秘密。
- `workspace project list/show` 必须从 daemon 当前注册配置投影 stable `projectRef`、kind、
  availability、supported operation 与 preset refs，不暴露 host root、executable、argv 或秘密。
- `workspace preset list/show --project <ref> [--kind build|test|signing|symbol]` 必须输出 kind-tagged
  stable preset reference 及 typed constraints，并精确映射 descriptor 的 `buildPresetRef`、
  `testPresetRef`、`signingPresetRef` 或 `symbolPresetRef`。signing preset 可来自独立 credential-backed
  store，不得因此伪造为 build preset。Catalog descriptor 里的 free-form string 和描述性示例不是可发现性。
- 未知 project/preset 返回 `workspaceReferenceNotFound`；已知但当前不可用返回带 reason 的
  availability，不使用 host path 作为临时逃生参数。
- workspace continuation 必须从原 Job 建立新 typed request/identity/Job，重新核对 target、
  binding、Catalog 与 read-only/effect gate。它不 replay 原 authority，不直接调用 App view model。
- `workspace continuation inspect|submit|run --source-job <job-id>` 必须协商 control protocol 2.x，
  并让 health、source/target readback、submit、run 与 accepted-Job readback 共享同一个有界 deadline
  （默认 30 秒）。source 必须 terminal、outcome known、无 human wait/residue/superseding recovery，
  且 source/Runtime/CLI Catalog digest、当前 provider、device binding revision 与 stable physical identity
  全部精确一致；只允许 effective `hostOnly|readOnly`，不复制 capability、campaign reservation、
  session 或 provider lowering，含历史时间的非空 capture markers 必须拒绝。
- `inspect` 只返回闭合的 `arkdeck.workspace-continuation/1` eligibility projection，不创建 Job 或
  dispatch。`submit|run` 要求 caller-stable `--continuation-request-id`，用它同时作为 fresh request ID
  与 idempotency key；收到闭合的 `arkdeck.job-acceptance/1` 后必须重新读取并精确匹配 accepted Job
  的 request、Catalog 与 materialized binding。`run` 只对 Runtime 声明可运行的同一 Job 调用
  `job.run`；同 identity 的 terminal retry 重新发现原 Job，返回 `deduplicated: true`、
  `dispatched: false`，不得再次调用 run 或产生新 dispatch。

### 7.10 Local product resources

target display name、History saved filter 和 Trace derived cache 会改变本机产品状态，但不改变
Runtime identity/evidence/admission。它们必须通过 bounded、versioned local resource 由 App/CLI
共用；不能从 CLI 直接读写 `UserDefaults`、App 私有目录或 Trace DB。显示名必须和
target/binding alias 在 schema 中分离。candidate 显示名只绑定 exact candidate key + observation ID +
observation generation 并会过期；adopt 时只能在 Runtime 证明同一 candidate/target relation 后原子迁移，
否则清除，绝不能参与设备选择或 identity compare。Trace purge 只能回收无 active lease 的派生 DB，永不删除
原始 Trace Artifact。target display-name 与其他 mutable local resource 必须返回单调 generation，
set/clear 使用 compare-and-swap；漂移返回 `resourceConflict`，不 last-write-wins。App icon、
菜单布局与快捷键则是 `presentation`，不要求 CLI 等价 leaf。

## 8. 机器输出契约

### 8.1 stdout / stderr

| 模式 | stdout | stderr |
|---|---|---|
| `human` | 最终结果的可读摘要 | progress、warning、HAR prompt、terminal error |
| `json` | 恰好一个无 BOM 的 UTF-8 JSON document，以 LF 结束 | 默认静默；可有不影响机器读取的诊断，但不得含秘密 |
| `jsonl` | 每行一个无 BOM 的 UTF-8 versioned event，最后一行必须是 terminal event | 同 `json` |
| `artifact read --raw` | 仅原始 bytes | terminal error/progress；成功不得追加换行 |

machine 模式禁止 ANSI、localized key、spinner、日志前缀和 human prose 混入 stdout。JSON 编码失败
必须返回结构化/terminal error，不能 fallback 到 human renderer。

output mode 与 renderer kind 由 registry 对每个 executable leaf 显式声明。除下述 stream/raw
闭合例外外，portable
leaf 至少支持 `human` 和 `json`；v1 只有已有 Job identity 的 `job wait` 与 `job watch` 支持
`jsonl`，其中 `job watch`
只支持 `human|jsonl`。`agent run` 的 pre-Job discovery/HAR 没有 durable event stream，因此 v1
只支持 `human|json`；domain run alias 不得把 ephemeral progress 冒充 JSONL。其他 leaf 与
`--output jsonl` 组合必须在
parse 阶段返回 `invalidOption`；`artifact read --raw` 与所有 machine mode 互斥。
`completion` 使用 `completionScript` renderer，拒绝 `--output`：成功 stdout 是对应 shell 可直接
加载的 UTF-8/LF script，stderr 只放诊断，不包 human summary 或 JSON envelope。请求不支持的
output mode 时，bootstrap 仍可按下述规则返回 machine parse error，但不得产生半段脚本。

为保证 argv 错误也可被 Agent 读取，完整 parser 前先运行共享的最小 renderer bootstrap：

- argv 中恰好一次 exact `--output` 且紧随 `json` 或 `jsonl` 时，后续 parse/domain error 使用该
  renderer；缺失时使用 human；重复、缺值或非法 output value 本身使用 human + exit 64，避免
  在不确定 mode 中输出伪 machine frame；
- command path 尚未解析时，error envelope/event 的 `command` 固定为 `registry.parse`；合法 path
  解析后使用 canonical command token；
- `--control-request-id` 值语法是 `^[A-Za-z0-9][A-Za-z0-9._:-]{0,127}$`。恰好一个合法值才回显；
  缺失、重复或非法时生成新的 bounded error-correlation ID，绝不回显未经验证的 caller bytes；
- bootstrap 识别 output mode 不表示接受该 option；完整 registry parser 仍负责位置、重复、leaf
  support 和全部 strict argv 校验。有效 `jsonl` mode 下的 parse error 只输出一个 terminal error
  event。

### 8.2 单结果 envelope

成功：

```json
{
  "schemaVersion": "arkdeck.cli.result/1",
  "command": "job.result",
  "ok": true,
  "result": {},
  "meta": {
    "controlRequestId": "ctl-...",
    "cliVersion": "...",
    "controlProtocolVersion": "2.0.0",
    "runtimeCatalogDigest": "..."
  }
}
```

失败：

```json
{
  "schemaVersion": "arkdeck.cli.result/1",
  "command": "job.result",
  "ok": false,
  "error": {
    "code": "resultNotReady",
    "message": "The job has not reached a terminal state.",
    "controlRequestRetryable": true,
    "attentionRequired": true,
    "details": {}
  },
  "meta": {
    "controlRequestId": "ctl-...",
    "cliVersion": "..."
  }
}
```

规则：

- `schemaVersion`、`command`、`ok`、`meta.controlRequestId` 必须存在。
- `controlRequestId` 只关联一次 CLI invocation/envelope/JSONL stream，不是 Runtime idempotency key，
  也不等于 daemon frame `request.id`。`job watch`、negotiation 或其他复合 leaf 发出的每个 unary wire
  request 必须使用本次连接内唯一的 bounded child request ID，并只接受 exact matching response；
  Runtime audit 可以另带 validated parent `controlRequestId`。不得为多页读取复用一个 wire request ID，
  也不得从该 correlation ID 派生 Job/Import/execution identity。
- success 只能有 `result`；failure 只能有 `error`。
- `ok` 表示命令是否成功取得其 contract projection，不等同于 Job/device outcome。`job result`、
  `job wait` 或已有 Job 的 `agent run` 读取到 terminal failed/cancelled/interrupted 时必须返回
  `ok: true` + 完整 bounded result（其中 `job.outcome` 给出状态），process exit 1；required evidence
  完整性失败也保留 result projection、在 `evidence.status` 给出 stable reason 并 exit 2。只有无法
  取得该 projection、或请求自身被拒绝/失败时才使用 `ok: false` + `error`。因此 consumer 必须同时
  检查 process exit、`ok` 和 result 中的 outcome/evidence，不可假定 `ok: true` 必然 exit 0。
- terminal abandoned AgentExecution 遵守同一原则：`agent run` replay 是 `ok:true` result + exit 1，
  `agent status` 只是成功 query，仍 exit 0。
- `error.code` 是稳定、非本地化的 machine reason；`message` 可读但不作为 branching contract。
- `controlRequestRetryable` 只表示可以重试同一个只读/control request、用同一 idempotency key
  恢复 lost response，或查询已有 AgentExecution/Job/control action。它永远不授权创建新 Job、
  再次 `job run` 或 replay intent；
  destructive outcome unknown 时只允许 status/evidence/reconcile contract 指定的读取路径。
- `details` 必须是有 schema 的 bounded object，不能直接转储 Swift/.NET exception、host path、
  stdout/stderr 或秘密。
- 对没有 Runtime/Catalog 的本地命令，相应 meta 字段可以省略，不能伪造 digest。
  `runtimeCatalogDigest` 表示响应时 Runtime 当前 digest；Job 自己锁定的 digest 属于 Job/result，
  二者不得混名。
- machine consumer 对 JSON 做 schema/值语义比较，不得依赖 object property order。只有 schema
  明确要求 canonical bytes/digest 的 CLI-owned 字段才使用
  [`arkdeck.cli.canonical-json/1`（RFC 8785 JCS）](https://www.rfc-editor.org/rfc/rfc8785)：
  I-JSON 输入、duplicate key 拒绝、property 按 JCS 排序、primitive 按 ECMAScript serialization，
  输出是无 BOM/无额外 whitespace 的 UTF-8 bytes。stdout 末尾 LF 是 frame delimiter，不进入
  canonical bytes 或 digest。
- JCS 输入不得包含 unpaired surrogate、NaN、positive/negative Infinity。`-0` canonicalize 为
  `0`。schema 中要求 exact `Int64`/`UInt64` 且可能超出 `[-9007199254740991,
  9007199254740991]` 的字段必须定义为 canonical decimal string，不能先经 binary64 舍入；合法
  floating-point field 只接受 finite IEEE 754 binary64。字符串保持 exact Unicode scalar sequence，
  不做 Unicode normalization。
- 只有字段 schema 明确声明 `sha256-jcs` 时，CLI-owned digest 才是上述 UTF-8 canonical bytes 的
  SHA-256 lowercase hex。Catalog digest、materialized plan/hash、Artifact digest、capability/facts
  digest 继续使用各自 accepted authoritative canonicalization；CLI 把它们作为 opaque value
  传递，不以 JCS 重算。任何迁移都必须提高所属 contract component version，不能改变历史 identity。

最小 canonical fixture（左侧是 semantic input，右侧是 exact UTF-8 text，不含 frame LF）：

| input | canonical output/result |
|---|---|
| `{"b":1,"a":2}` | `{"a":2,"b":1}` |
| `{"s":"a\/b"}` | `{"s":"a/b"}` |
| `{"n":-0.0}` | `{"n":0}` |
| `{"n":333333333.33333329}` | `{"n":333333333.3333333}` |
| composed `{"s":"é"}` / decomposed `{"s":"é"}` | 两组不同 bytes，均不 normalization |
| numeric `{"n":9007199254740992}` | exact-integer schema 拒绝；该 schema 必须使用 `{"n":"9007199254740992"}` |
| typed NaN/Infinity 或 duplicate property | `invalidInput`、exit 65、无 canonical output |

### 8.3 JSONL event

本节是目标 event contract。当前 `job.status` 的可变 timeline string array 没有 durable event ID、
revision 或 cursor，App 与 CLI 都没有 lossless event surface；在新的 unary daemon
`job.events(afterCursor, pageSize)` 落地前，`job watch` 必须报告 unavailable。`job wait`
可以 bounded poll snapshot，但不得把轮询结果伪装成可恢复 event stream。

```jsonl
{"schemaVersion":"arkdeck.cli.event/1","sequence":1,"type":"snapshot","command":"job.watch","controlRequestId":"ctl-1","eventId":"evt-1","streamPosition":"1","runtimeRevision":"rev-7","cursor":"cur-1","data":{}}
{"schemaVersion":"arkdeck.cli.event/1","sequence":2,"type":"stateChanged","command":"job.watch","controlRequestId":"ctl-1","eventId":"evt-2","streamPosition":"2","runtimeRevision":"rev-8","cursor":"cur-2","data":{}}
{"schemaVersion":"arkdeck.cli.event/1","sequence":3,"type":"terminal","command":"job.watch","controlRequestId":"ctl-1","lastCursor":"cur-2","ok":true,"exitCode":0,"result":{}}
```

- `sequence` 从 1 开始且严格递增，只是本次 CLI stream 序号。Runtime event 另带跨连接
  稳定的 `eventId`、strictly increasing `streamPosition`、`runtimeRevision` 和 exclusive
  `cursor`；CLI terminal 带 `lastCursor`。
- 每一行都带同一个 validated/generated `controlRequestId`。非 terminal event 必须有 `data`，
  不得有 `ok`/`result`/`error`/`exitCode`；terminal event 必须有 `ok` 和 exact process
  `exitCode`，`ok:true` 只能有 `result`，`ok:false` 只能有与 §8.2 同 schema 的 `error`。terminal
  failed Job 可以按 §8.2 使用 `ok:true` + result + `exitCode:1`；本次尚无 Runtime event 时
  `lastCursor` 为 `null`。
- reconnect 后只提交公开的 opaque exclusive cursor；cursor 自身绑定 Job stream、position 与读取时的
  high-water relation，`runtimeRevision` 只用于 event/诊断投影，不是第二个恢复参数。重复 `eventId`
  允许 consumer 去重，但不允许丢 event。
- `job watch` 和 `job wait --output jsonl` 使用同一 Runtime event 源。`watch` 在用户超时/
  中断时结束；`wait` 在 Job terminal、HAR、unknown/reconcile 或客户端等待超时时结束。
- `job events --output json` 返回一个 page envelope；`job wait --output json` 只返回一个最终
  result/error envelope。`job watch` 只允许 `human`/`jsonl`；与 `--output json` 组合在
  parse 阶段返回 `invalidOption` 和 exit 64，不静默降级。
- CLI 自己的 progress 不是 Runtime event，不得写入 JSONL。
- event type `terminal` 在每次 JSONL 调用中恰好一个，表示本次 CLI stream 已结束，
  不必然表示 Job terminal；HAR、timeout、unknown 以 `ok:false` 与 exit 75 结束，
  client interrupt 以 `ok:false` 与 exit 130 结束，Job 状态仍由 event payload 决定。
- target `job submit` 不接受 `--wait` 或 `jsonl`；需要 durable event 时依次调用 `job submit`、
  `job run`，再以返回的 Job ID 调用 `job watch`/`job wait --output jsonl`。`agent run` 只返回
  bounded terminal/current result；若未来增加 pre-Job stream，必须先发布 unary `agent.events`
  page/cursor contract。

`job.events` 沿用 control plane 的 unary 语义：每个 request 恰好一个 response frame，
同一 connection 仍可顺序承载多个 request。CLI 在多次请求之间保存 cursor。
因此 durable watch 本身不要求 multi-frame 或协议 major 升级；新 method 仍须按 control
protocol 的兼容规则发布。任何未来 server-push、同请求多响应 frame 或 framing 改变
都必须提高 control protocol major。

### 8.4 最小错误 registry

`error.code` 是跨平台 branching contract，v1 至少包含下表。同义词、拼写修整或依靠
`message` 匹配均不兼容；新 code 必须先进入 versioned registry 和 macOS/Windows fixture。

| `error.code` | exit | 必要语义 |
|---|---:|---|
| `invalidCommand`, `invalidOption` | 64 | argv grammar 错误，dispatch 0 |
| `commandRemoved` | 64 | registry 识别出的 parse-only tombstone；details 固定给出 removal lifecycle 与 exact replacement/no-replacement，dispatch 0 |
| `invalidInput`, `inputTooLarge`, `invalidCursor` | 65 | JSON/schema/bounded input/cursor 无效，dispatch 0 |
| `idempotencyConflict` | 65 | 同 request/execution identity 与不同 canonical request 冲突，不创建新资源 |
| `reviewedPlanMismatch` | 65 | fresh/existing materialized plan digest 与 caller reviewed digest 不同；零新 admission/Job/dispatch |
| `resourceConflict` | 65 | 资源存在但与请求的 generation/state 冲突；不默认覆盖 |
| `resourceNotFound`, `workspaceReferenceNotFound` | 65 | 显式引用不存在；不退回默认资源 |
| `protocolVersionUnsupported`, `controlMethodUnavailable` | 69 | client/Runtime 不兼容或未发布 method |
| `runtimeUnavailable`, `operationUnavailable`, `unsupportedOnPlatform` | 69 | Runtime/provider/tool/platform 当前不可用 |
| `quotaExceeded` | 69 | bounded import/local product resource 超出已发布 quota；零 dispatch，不自动删除其他 owner 数据 |
| `blockedByProductDefect` | 69 | 缺少本规格要求的 typed 产品面；human status 为 `BLOCKED_BY_PRODUCT_DEFECT` |
| `healthRequirementFailed` | 69 | doctor 已完成但 `--require-healthy` 发现 blocker |
| `targetSelectionRequired`, `targetAmbiguous` | 75 | Agent execution 需要 typed selection/HAR；不默认选第一台 |
| `targetTrustPending` | 75 | standalone exact observation 尚 unauthorized；无 owner/HAR、零 mutation，使用 `device wait` 后携新 generation 重试 |
| `humanActionRequired`, `humanActionExpired`, `resultNotReady` | 75 | owner 已持久化；expired resume reference 零 dispatch，其余可从 `nextAction`/返回 identity 恢复 |
| `clientTimeout` | 75 | 仅表示 client wait deadline；已知 owner 才返回其 identity/`nextAction`，不能推断请求未被接受或自动 cancel |
| `eventHistoryUnavailable` | 75 | retained Job stream origin 已回收，无法证明 lossless replay；不静默从 earliest/tail 继续 |
| `orchestrationBudgetExpired` | 75 | durable AgentExecution 的 absolute orchestration deadline 已到；不取消已有 Job |
| `outcomeUnknown`, `reconcileRequired`, `previewExpired` | 75 | 需要读回/新 preview/人类 attention；不 replay |
| `orchestrationClockUntrusted` | 77 | durable deadline 的 clock high-water 倒退或可信时间不可得；零新 dispatch |
| `fileIdentityChanged` | 77 | opened host file/root 的 file ID、type 或 no-follow/reparse trust relation 漂移；零 admission/dispatch |
| `bindingRevisionStale`, `factsDrifted`, `previewDrifted` | 77 | dispatch-time identity/facts/generation 不再匹配，零新 dispatch |
| `admissionDenied`, `sensitiveAccessDenied` | 77 | policy/authority/privacy 拒绝，人类 warning 不能 override |
| `operationFailed` | 1 | 没有可返回 stable Job result projection 的 execution/validator 明确失败；已有 terminal Job 按 §8.2 返回 `ok:true` result + exit 1 |
| `artifactIntegrityFailed`, `recordUnreadable` | 2 | immutable/local record 完整性失败 |
| `ioFailure` | 74 | bounded local I/O 失败 |
| `protocolMalformed` | 70 | local control frame 违反已协商 schema/framing；不将原始 frame 写入诊断 |
| `internalError` | 70 | 已证明没有任何不确定 resource/lifecycle/device/external mutation 或 effect 的未预期内部错误；details 不泄露 exception/path |
| `clientInterrupted` | 130 | 客户中断；不表示 Job 已取消 |

当前 wire 只有下列粗粒度 code。目标 handler 必须返回结构化 domain reason，CLI 再由生成的
显式映射得到上表 code；不得解析 wire `message` 猜测。缺少 domain reason 时 fallback 必须逐项
固定如下，不能有 default branch：

| current wire code | target fallback `error.code` |
|---|---|
| `unsupportedProtocolVersion` | `protocolVersionUnsupported` |
| `malformedFrame` | `protocolMalformed` |
| `unknownMethod` | `controlMethodUnavailable` |
| `invalidParams` | `invalidInput` |
| `rejected` | 按下述 closed phase/effect fallback；禁止无条件映射 `admissionDenied` |
| `conflict` | `resourceConflict` |
| `notFound` | `resourceNotFound` |
| `recordUnreadable` | `recordUnreadable` |
| `internalError` | 按下述 closed phase/effect fallback；禁止在 mutation outcome 不明时无条件保留 `internalError` |

legacy `rejected` 被现有 handler 用于 pre-admission、read-only execution failure、resource mutation
以及可能已 dispatch 的路径，不能声称统一零 dispatch。缺少 domain reason 时只按 generated method
registry + structured phase/effect evidence 映射：

- closed handler contract 同时证明 `phase: "preAdmission"` 与 `newDispatchCount: 0` 才可
  `admissionDenied`；
- registry 证明 method 是 bounded read-only 且不执行 resource/lifecycle/device mutation 时映射
  `operationFailed`；
- 其余 mutation-capable、effect unknown 或 phase evidence 缺失一律 `outcomeUnknown`、exit 75，
  返回已有 owner identity 时只允许 status/evidence/reconcile，绝不从 wire message 推断或重试 intent。

目标 handler 必须逐步消除无 domain reason 的 `rejected`；conformance 对每个 current method/error
path 穷举上述三路，不能有默认 `admissionDenied`。

同一不确定性规则适用于 legacy `internalError`、收到无法归类但有效的 wire error、malformed/lost
response、transport disconnect 与 client timeout：registry 证明 bounded read-only，或 structured
phase/effect evidence 证明 mutation acceptance 前失败且 `newDispatchCount: 0` 时，才保留对应的
`internalError`/`protocolMalformed`/transport code；否则 mutation-capable request 一律以顶层
`outcomeUnknown`、exit 75 返回已知 owner identity 与 status/evidence/reconcile 路径，原始失败只作为
bounded `cause`。不得因底层错误“看起来是内部/网络问题”就假定资源不存在或重试创建/dispatch。

## 9. 退出码契约

退出码是粗粒度 process contract；具体 branching 以 `error.code`、Job state 和
`outcomeUnknown` 为准。macOS 与 Windows 使用同一数值。

| code | machine category | 语义 |
|---:|---|---|
| 0 | `ok` | 命令语义成功；query 非 terminal Job 也可成功 |
| 1 | `operationFailed` | Job terminal failed/cancelled/interrupted，或验证器明确失败 |
| 2 | `integrityFailed` | immutable Artifact、required evidence、record、host feed/signature 等完整性验证失败；兼容保留 |
| 4 | `legacyAttention` | 仅 legacy Flash archive 仍有 unresolved debt；不得用于新 core command |
| 64 | `usage` | command/option/argument grammar 错误或 removed tombstone |
| 65 | `invalidData` | input/cursor/reference 无效或幂等/资源 conflict；本次请求零新 admission/resource/dispatch，不否定 existing owner 的历史/并发 dispatch |
| 69 | `unavailable` | local Runtime、provider、tool、platform capability 或 typed 产品面不可用 |
| 70 | `internal` | 未预期内部错误或已协商 control frame 不合法；不得泄露 exception/frame |
| 74 | `io` | bounded local I/O 失败 |
| 75 | `attentionRequired` | HAR、等待超时、outcome unknown、waiting for reconcile、result not ready |
| 77 | `admissionDenied` | policy/identity/facts/authority 拒绝且零 dispatch |
| 130 | `clientInterrupted` | CLI 收到用户中断；不等于 Runtime 已取消 Job |

补充规则：

- `job show/status` 查询成功时，即使 Job running，exit 0；状态在 result 中。
- `job result/wait` 遇到 non-terminal、HAR、unknown 或 timeout 时 exit 75。
- `job result/wait` 成功读取 terminal failed/cancelled/interrupted 时使用 §8.2 的 `ok:true` full
  result + exit 1；evidence integrity failure 同理保留 result 并 exit 2，不改写成缺字段的 error。
- `job cancel` 的请求被接受可以 exit 0；随后 `job result` 看到 terminal cancelled 时 exit 1。
- `job reconcile` 若仍 unresolved 必须 exit 75；不得因为 RPC 本身成功而 exit 0。
- malformed input、unavailable、admission denied 对本次 request 都发生在新 dispatch 前；machine
  result 应明确 `newDispatchCount: 0` 或等价证据（若对应 contract 已提供），但 existing owner 的
  并发/历史 dispatch 仍以其 identity/status 为事实源。
- 信号/console interruption 由平台 adapter 映射到 exit 130 与同一 cancellation policy；不能直接
  杀掉 daemon 或把 client disconnect 当成 Job cancel。已经返回 Job ID 时，human error/JSON
  envelope 必须提示用 `job status` 继续查询。

## 10. Help、发现与 completion

- root help 先展示 Golden Journey 主路径：`doctor`、`device candidates`、`target adopt`、
  `operation describe`、`agent run`、`job result`、`artifact export`。
- 每个 leaf help 必须包含 effect/binding 摘要、是否可能 HAR、input schema 来源、输出 schema、
  示例和 safety notes。
- `operation describe` 是 operation-specific 参数的事实源；领域命令不得在 help 中复制一套会
  漂移的 input definition。
- `arkdeck completion bash|zsh|fish|powershell` 从 registry 生成静态 completion。动态 target、
  execution、Job、HAR/control action、Artifact identity 和 resume reference 默认不补全，避免将
  敏感历史写入 shell cache；显式 opt-in 后也只能走本地
  bounded query。
- `arkdeck commands --output json` 可以导出当前 command registry projection，供外部 Agent
  discover，不需要解析 help 文本。

## 11. 可移植契约与平台映射

### 11.1 必须共享的 portable core

macOS 与 Windows 实现必须共享：

- command/option AST 与 strict parsing rules；
- Runtime request/response models；
- Catalog descriptor schema 与 canonical digest；
- result/error/event schemas；
- exit-code registry；
- Job/Artifact/Target/HAR 状态与 reason codes；
- normalization、hash、ID、timestamp、duration、budget 规则；
- 同一组 argv-array → normalized request → normalized result fixtures。

共享的是语言无关契约，不要求共享 Swift binary 或源代码。Windows 可以使用 C#/.NET、C++ 或
其他 approved native implementation，只要 conformance 相同。

registry 的 portable AST 必须共享；历史 platform compatibility token 只能作为同一 registry 中
显式标注的 scoped metadata，不能分叉手写 parser。`--socket` 标记为
`macosCompatibilityOnly`：macOS 仅在已声明的 Runtime-client leaf 将其映射为本地 UDS endpoint；
Windows parser 识别该 metadata 但固定返回 `unsupportedOnPlatform`、exit 69、dispatch 0，且不在
默认 help/completion 中显示，也绝不把值解释为 named-pipe path。portable argv equivalence fixture
不包含该 alias，另有 platform-scoped positive/negative fixture 锁定差异。

### 11.2 平台 adapter

| 边界 | macOS | Windows | 不变语义 |
|---|---|---|---|
| local transport | user-private Unix domain socket | user-private named pipe | local-only、versioned frame、peer/user boundary、request/response limits |
| service manager | LaunchAgent | platform profile 选择的 per-user broker/service | install/update/restart/status/verify/uninstall |
| credential store | Keychain | Credential Manager/DPAPI-backed store | secret 不经 argv/env/log，使用 credential ref |
| console secret | no-echo TTY | no-echo Console | 无回显、不可重放到日志 |
| file identity | file descriptor + inode/device checks | handle + file ID/volume + reparse checks | open 后 identity 稳定、no-follow、bounded read |
| process/tool | POSIX/Darwin adapter | Win32 process adapter | descriptor/tool-ref 解析 executable + argument array；无 caller raw path/shell string |
| HDC/server | macOS tool/server port | Windows tool/server port | exact path/source/hash/version/ownership/generation |
| USB/loader | IOKit adapter | approved Windows device-access adapter | same typed facts、binding、admission、evidence |
| service secrets | owner-only files/Keychain ACL | current-user/service SID DACL | least privilege、fail closed |
| reveal/open | Finder/AppKit | Explorer/WinUI | presentation-only，不进入 Runtime evidence |
| machine output | UTF-8/LF | UTF-8/LF，raw 时 binary mode | byte-stable schema and fixtures |

正式 endpoint 不得退化成 localhost TCP。Named pipe 需要 current-user/service identity DACL 与
server/peer identity validation；“在本机”本身不是充分信任证明。

### 11.3 Path 与 shell 差异

- fixture 直接提供 argv array，不比较 shell quoting。
- Windows implementation 必须把 OS 提供的 UTF-16 argv 严格转为 Unicode scalar sequence，
  再编码为 UTF-8；unpaired high/low surrogate 必须在连接 Runtime 前以 `invalidInput`
  和 exit 65 拒绝，不得用 replacement character 修复。
- CLI 默认不做 NFC/NFD/NFKC/NFKD normalization。command/option/ID 由 ASCII/pattern
  schema 限定；合法的人类文本按 exact scalar sequence 保留，canonical fixture 也按该序列比较。
- CLI 不自行展开 `~`、`%USERPROFILE%`、glob、command substitution 或环境变量。
- host path 保持平台原生 Unicode 表达；跨平台 fixture 用 logical placeholder，不把 `/` 或 `\`
  纳入业务 digest。path identity 来自打开后的 file handle/ID，不依赖文本 normalization。
- Runtime JSON 中的 device identity、operation reference、Artifact ID 等仍使用平台无关格式。
- CLI-owned machine timestamp 固定为 RFC 3339 UTC、恰好三位 fractional second
  (`YYYY-MM-DDTHH:mm:ss.SSSZ`)，生成时向零截断到 millisecond；Runtime/Catalog/Artifact accepted
  record 中的 timestamp 先按其 authoritative schema 验证，再保留 exact string pass-through，CLI
  不为美化而改 precision 或重写 identity。digest 为 lowercase hex，整数范围按 schema 固定。
- PowerShell/cmd.exe 示例只负责正确产生同一 argv；不能拥有不同命令语义。

## 12. 版本、兼容与弃用

CLI 同时存在四个独立版本：

1. CLI product version；
2. command registry schema；
3. local control protocol；
4. machine-contract bundle，其内分别 pin result、page、event、next-action 和 error-registry
   以及 canonical-JSON component version。

升级一个版本不能暗中改变另一个。破坏 command/option、machine field、exit code 或状态语义时，
必须提高相应 major，并提供 migration/tombstone。

`arkdeck --version --output json` 必须在一个 result 中分别输出 `cliProductVersion`、
`commandRegistrySchemaVersion`、`preferredControlProtocolVersion`、
`supportedControlProtocolExactVersions`、`resultSchemaVersion`、
`machineContractVersion`、`pageSchemaVersion`、`eventSchemaVersion`、`nextActionSchemaVersion`、
`errorRegistryVersion`、`canonicalJsonVersion` 与 `buildIdentity`；human 模式也必须列全，不只打印
App/CLI build。它们是本地 client capability，不声称已连接 daemon；普通 Runtime-backed response 的
`meta.controlProtocolVersion` 才是本次实际协商的 exact version，且必须属于上述 supported set。
`supportedControlProtocolExactVersions` 与 bootstrap 使用同一 numeric-descending canonical list；
`preferredControlProtocolVersion` 是其中最高 2.x exact version，且必须存在于该 list。

control protocol 1.x 已发布的 method token 按字节冻结，包括 camelCase
`flash.lanePlanPreview` 与 `cleanupDebt.list`/`cleanupDebt.continue`。CLI 继续使用
kebab-case `flash lane-preview`/`recovery cleanup ...` 做 registry mapping；Windows handler 不得自行
“统一” wire 拼写。更改 token 或同一 token 的语义必须提高 control protocol major。

本规格的盘点基线仍是当前 `1.0.0`，但完整 target Runtime surface 的最低协议代际是协商后的
control protocol `2.x`。本文不追溯重定义 1.x：1.x request/response/effect shape 必须保持原样，
2.x 才能在相同 token 下发布下表的破坏性目标语义。exact released minor/patch 由单一 generated
control registry 声明；示例中的 `2.0.0` 仅表示该 major 的初始 contract。新 method token 和仍保持
旧字段/语义的 optional field 可以 additive 发布，但不能借“JSON 可忽略未知字段”替换 required
field、array/object shape、ordering、idempotency 或 effect。

| 现有 1.x wire surface | target 2.x 语义 | 兼容决定 |
|---|---|---|
| `device.candidates` 返回无 snapshot generation/observation ID 的 array | lifecycle observation + exact generation 的 snapshot/page projection | 破坏 response/identity；只在 2.x 发布 |
| `target.adopt` 可省 candidate，并返回 `needsSelection`/`waitingForHuman` | 必填 candidate + observation ID/generation 的 reobserve/CAS；standalone 不创建 HAR | 破坏 request/effect/result；只在 2.x 发布 |
| `job.list`/`job.list-page` 的 array/object、隐式 rowid tie-break | 固定 page schema、snapshot revision、完整 total order/cursor | 破坏 page/order；只在 2.x 发布 |
| `job.status` 的 legacy snapshot | versioned compact status + closed `nextAction` union | 若不能纯 additive 保留全部 1.x 语义，则只在 2.x 发布；target coverage 以 2.x fixture 为准 |
| `artifact.read` 只接受 Job owner、clamp `maxBytes`、缺 digest | tagged Job/Import owner、strict bounds、digest-bound range | 破坏 validation/request/result；只在 2.x 发布 |
| kind-specific `artifact.import*.begin/append/commit/abort` transient upload | caller-stable request identity、durable Import owner、atomic resumable append 与 list/inspect/release | 旧 token/shape 留在 1.x compatibility；2.x target contract 使用 generated durable-import method set |
| legacy `artifact.list/inspect/export` Job-only projection | tagged Job/Import owner 与 fixed page/privacy contract | 不能由 1.x 忠实合成的部分只在 2.x 发布 |
| 无 `job.events`、AgentExecution/HAR/control-action/import discovery method | 本规格新增的 unary/resource methods | additive method 本身不要求 major；随 target 2.x registry 一起 pin，不得改成 server-push |

精确版本选择使用独立于 1.x/2.x domain schema 的 bootstrap unary method，不能解析 human error
message 或在各平台自选策略：

- target 2.x daemon 必须在 normal protocol decode/dispatch 前识别 version-neutral
  `protocol.negotiate`。request 是单个 LF-delimited JSON object，只允许
  `bootstrapVersion: "arkdeck.control.negotiation/1"`、本连接唯一的 `id`、
  `method: "protocol.negotiate"`、非空 `supportedExactVersions` 和 `requiredMajor`；不得含
  domain `protocolVersion`、command request、credentials 或 idempotency key。request/response 各自
  最多 65,536 bytes，并沿用 duplicate-key、Unicode scalar 与 UTF-8/LF strict decode；
- exact version 只接受无 leading-zero/prerelease/build metadata 的 ASCII SemVer `major.minor.patch`。
  两端列表必须 unique，并按 numeric `(major, minor, patch)` descending canonical order；daemon 在
  双方列表且 major 等于 `requiredMajor` 的交集中选择最高 exact version。success response 只允许同一
  `bootstrapVersion`/`id`、`ok: true`、`selectedExactVersion` 和完整
  `daemonSupportedExactVersions`；无交集时返回 `ok: false`、
  `error: {"code":"protocolVersionUnsupported"}` 与同一 daemon list，且不得含 selected。client
  必须验证 selected 确在交集中；
- negotiation 永远是 bounded read-only，必须在 method lookup/admission/resource mutation/dispatch 前
  完成，失败有 `newDispatchCount: 0`。每个后续 domain request 仍携 selected exact
  `protocolVersion`，daemon 在任何 effect 前 exact compare；selection 不是 authority 或 mutation
  idempotency；
- canonical target leaf 固定 `requiredMajor: 2`；显式 legacy compatibility leaf 固定
  `requiredMajor: 1`。无共同版本时绝不尝试另一 major。只有连接到尚不认识 bootstrap frame 的当前
  1.x daemon 时，legacy leaf 才可在 version-neutral negotiation 无 effect 地失败后发送一次 generated
  compatibility registry 唯一允许的 direct `1.0.0` request；target leaf 此时直接
  `protocolVersionUnsupported`、dispatch 0，不 probe 1.x domain method；
- 2.x daemon 在当前 CLI product 仍发布 legacy leaf 的期间，必须同时保留冻结的 1.0.0 handler table
  与 target 2.x table；何时移除 1.x 由 CLI/control compatibility lifecycle 同车提高 major，不能由
  platform 单独决定。除上述 pre-bootstrap 1.0.0 例外外，任何新 supported exact version 都必须实现
  negotiation，不能靠顺序试发多个 domain request；
- selected version 可按 endpoint identity + daemon build identity 缓存在一次 CLI invocation 内；每个
  request 仍由 daemon 重验。收到结构化 version mismatch 且证明 request 在 effect 前以
  `newDispatchCount: 0` 拒绝时，client 才可在同一 required major 重新协商；mutation request 已发送而
  phase/effect 不明时遵守 §8.4，返回 `outcomeUnknown`，不得以 renegotiation 自动 replay。

`protocol.negotiate` 在 coverage 中分类为 `internal`，没有 public CLI leaf；`--version` 只投影 client
列表，不能触发连接。bootstrap registry/schema/vector 与 domain control registry 必须同车生成并由
macOS/Windows 共用。

2.x CLI 必须在任何 mutation 或 target machine output 前完成 protocol negotiation。daemon 只支持
1.x 时，target leaf 返回 `protocolVersionUnsupported`/exit 69/dispatch 0；不得静默降级到 1.x 的
auto-adopt、clamp、array shape 或 transient import。显式 legacy compatibility leaf 可以调用 1.x，
但其 machine lifecycle 必须标记 `legacy`，coverage 不能记为 target `implemented`。macOS 与 Windows
必须运行同一 1.x-preservation、1.x↔2.x negotiation 和 2.x target fixture；client/daemon version
都只能从 generated shared contract 读取，禁止硬编码第二真相源。

同理，新增必填 option、改变 argv 语义或 legacy command 的 effect 必须进入下一 CLI product/command
registry major；不能因 control protocol 已升 major 就在当前 CLI major 静默改 argv。下表所称“当前
major 保留”只表示 explicit legacy compatibility，不能满足 target machine/coverage conformance；
下一 major 的 parse-only tombstone 必须在任何 Runtime connection 前结束。

当前命令迁移目标：

| 当前表面 | 目标表面 | 兼容策略 |
|---|---|---|
| `agentd ...` | `runtime service ...` | 当前 major 保留 alias，human 模式警告；下一 major tombstone |
| `agentd install/update --hdc/--daemon <path>` | `runtime tool register` + `runtime bundle register`，再传 typed refs | compatibility reader 先做同等 hash/trust 校验；新 service contract 不消费 caller path |
| `agentd install --workspace-project/--deveco-sdk <path>` | `workspace project register` + registered toolchain ref + `workspace preset register` | compatibility reader 可完成一次 bounded migration；target service install 不持有 raw project/SDK flags |
| `agentd update` 省略 `--workspace-project/--deveco-sdk` | `runtime service update` + Runtime-owned workspace resources | legacy 拼写在当前 major 保留已安装 path pair；target 拼写省略 pair 时移除 legacy LaunchAgent 注入，显式 paired paths 仍可完成兼容周期；两者均不删除已注册 project/preset |
| `signing ...` | `runtime signing ...` | 同上 |
| `update-feed ...` | `maintainer update-feed ...` | 同上；仍是 platform/maintainer extension |
| `device list` | `target list` | 当前 major 保留 exact 1.x target-array legacy result 且不计 target conformance；下一 CLI/registry major 为 `commandRemoved` tombstone，绝不静默改成 candidate list/page |
| `device show` | `target show --target <id>` | 当前 major 保留 exact 1.x target-list legacy behavior 且不计 target conformance；下一 CLI/registry major 为 `commandRemoved` 并给 exact replacement，不能同 major 暗改成 single-target shape |
| `device adopt` | `target adopt --candidate ... --observation ... --observation-generation ...` | 当前 major 只保留原 1.x legacy behavior；下一 CLI/registry major 为 `commandRemoved` parse-only tombstone 并给 exact replacement，绝不把旧 argv dispatch 到 2.x adopt |
| `cleanup-debt ...` | `recovery cleanup ...` | 保留 alias |
| `debug start/evaluate/status` | `recovery flash-invocation ... --invocation-request-id ...` | 当前 major 仅为 accepted legacy recovery compatibility，不计 target idempotency conformance；下一 major 为具名 tombstone，把 `debug` 还给正常 Debug 产品 |
| `artifact import-hap/import-workspace-patch/import-flash-bundle/import-native-library` | `artifact import <kind> --import-request-id ...` | 当前 major 仅保留 legacy compatibility，不宣称 durable Import/lost-receipt contract；下一 major tombstone；内部 chunk 方法始终不公开 |
| `flash install-binding` | 无直接重解释 | 保留 macOS compatibility leaf，待 current Loader binding 路径闭合后 tombstone |
| `flash status/reconcile` | `legacy flash status/reconcile` | decode/export-only；不迁到新 executor |
| operation ref `flash.dayu200` | 新 convenience command 只生成 `flash.full-restore@1` | generic caller 的显式 alias request 原样交 Runtime；CLI 不改字段，历史记录保持原 ref |
| `flash plan` | `job plan --operation flash.full-restore@1 ...` | 当前 major 保持 tombstone 并显示 exact replacement；未来重用同名 convenience leaf 必须提高 CLI major |
| `flash preview` | `flash lane-preview` | 当前 major 保持 historical-preview tombstone；新命令只读 Runtime lane projection |
| `flash execute` | `agent run --operation flash.full-restore@1 ...` | 永久 tombstone；不恢复 legacy executor |
| `flash continue` | 无直接 replacement | 永久 tombstone；只能用 `job status` 查询，或在 accepted contract 允许时用 `job reconcile` |
| `flash postflight` | `job evidence --job <id>` | 永久 tombstone；不再接受 legacy observation file |
| `agent chat` | 无 | 永久 tombstone |
| `agent resume --resume-token <token>` | `agent resume --resume-reference <ref>` | 当前 major 保留 exact-value deprecated option alias；machine lifecycle metadata 标记迁移，下一 major tombstone |
| `job submit --wait` | `agent run`，或显式 `job submit` → `job run` → `job wait` | 当前 major 仅保留 deprecated compatibility compound；不属于 target `job submit` contract，不接受新 `jsonl` shape；下一 major 变为 `commandRemoved` tombstone |
| `--socket` | `--endpoint` | 只在 registry 明确声明的 Runtime-client leaf 保留 `macosCompatibilityOnly` alias；其他 leaf 拒绝，Windows 固定 `unsupportedOnPlatform` 且 help/completion 不展示 |
| `--json` | `--output json` | 必须在 CLI major 迁移期明确 legacy-result 与 envelope 模式，不能静默改 shape |

`--json` 当前存在错误非 JSON、wait 多文档等缺陷。实现 target envelope 时必须选择显式迁移：

- 当前 major 增加 `--output json/jsonl` 作为新契约；
- `--json` 暂时映射 `legacy-json`，但修复编码失败 fallback 和多文档问题；
- 下一 major 才允许 `--json` 成为 `--output json` 的纯别名。

deprecated alias 一旦完成 registry resolution，无论 domain success/failure，human warning 只写
stderr；`--output json/jsonl` target machine stdout 不写 warning，而在 envelope/terminal event
`meta.lifecycle` 固定返回
`{"status":"deprecated","replacementArgvPattern":"...",
"removalVersion":"..."}`。尚未安排 removal 时 `removalVersion` 为 `null`，不得猜日期。
`--json` 的显式 `legacy-json` compatibility mode 保持旧 shape，不能塞入该 meta；这是当前 major
唯一例外，且不计入 target machine conformance。它只依赖文档/human warning 迁移，下一 major
随 `--json` 语义切换一起消失。
所有 removed leaf 的 human/machine parse-only tombstone 返回 `commandRemoved`、exit 64、dispatch 0；
`error.details.lifecycleStatus` 固定为 `removed`，并包含 `replacementArgvPattern`（无 replacement 时为
`null`）和 `removalVersion`。`invalidCommand` 只用于 registry 从未认识的 token；removed token
不得退化成 typo。tombstone 不能持有 Runtime method 或 operation mapping，也不能只说“retired”
让 Agent 猜测。

## 13. 当前实现差距

> 本节按 protected `main` `4bde4749`（2026-09-02）重算。命令面的事实源是
> `arkdeck commands --output json`（`arkdeck.cli.command-registry/1`），coverage 的事实源是
> `openspec/contracts/cli-feature-coverage.json`；本节的数字都可以由它们重新得出，不再手数 Swift。

### 13.1 已实现面

- registry：33 个一级入口、219 个 leaf = 210 个 executable + 6 个 parse-only tombstone
  （`agent chat`、`flash plan/preview/execute/continue/postflight`）+ 3 个永久拒绝桩
  （`capability draft/install/revoke`）；lifecycle 182 `current`、16 `deprecated`、15 `legacy`、
  6 `removed`，projection 对每个 leaf 都投影 `lifecycleStatus`/`replacementArgvPattern`。
  executable 中包含 §12 的 legacy/deprecated 兼容拼写
  （`device list/show/adopt`、`artifact import-*`、`flash install-binding/status/reconcile`、
  `legacy flash *`、`debug start/evaluate/status`、`cleanup-debt *`、`agentd/signing/update-feed *`）；
  它们运行时在 `meta.lifecycle` 报告 `legacy|deprecated` 与 replacement，但按 §12 不计 target
  conformance。
- Catalog：29 个 canonical operation + `flash.dayu200` alias，digest
  `508783acdf9e9b13d2d4a969e7e26f6fd60094a39d1cc9e02d2198e02ea13684`（本 change 发布 `debug.template@1` 后的 digest；此前为
  `b8c7148f…`）。§6.2 mapping 表中 29 个
  canonical 均已有一等领域 leaf（registry 的 `catalogOperation` 字段即契约），alias 只保留 generic
  `job/agent --operation` 入口，符合 §6.2 的设计。
- Slice A 已落地：declarative registry、strict parser、help/commands/completion、`--output json/jsonl`、
  error registry 与 exit registry、control protocol 2.x 协商（保留 1.x）、
  `operation list/describe/example/validate`、`runtime health`、`runtime hdc status`、
  `device candidates/wait`、`target show/availability`、`job events/watch/wait/result/evidence`、
  `artifact quota` 与 bounded range read、durable AgentExecution（`agent list/status/abandon`）、
  `human-action list/show/resume`、process-level golden 合约测试（`CLIProcessGoldenContractTests`）。
- Slice B 已落地：`flash device-access/bootloader-status/prerequisites/lane-preview/bind-loader/run`、
  `recovery flash-invocation list/start/evaluate/status`、`debug probe/hap`、`debug native deploy`、
  `debug template list/run`（`debug.template@1`，实现见 `cli-debug-template.md`，随 `CHG-2026-073` 交付）、
  `debug logs`（`capture.diagnostics@1` 的 HiLog-only preset，实现见 `cli-debug-logs.md`，同随 `CHG-2026-073` 交付）、
  screen/input/diagnostics/ui-dump/trace/analyze/port-forward/workspace 的全部 convenience mapping、
  workspace project/preset lifecycle 与 `workspace continuation inspect/submit/run`、
  `artifact import *` durable lifecycle、`runtime hdc impact-preview/restart` + `control-action *`、
  `runtime tool/bundle *`、`runtime service/signing`、`maintainer update-feed`、canonical 命名迁移与
  tombstone。
- Slice C 已落地：`session list/show/pin/unpin`、`session cleanup preview/apply`、
  `session export preview/apply`（实现见 `cli-session-export.md`，随 `CHG-2026-072` 交付）、
  `runtime storage status/policy/root`（Runtime 单一 owner，Session 输出域与 Artifact 域分开报告）、
  `runtime support-bundle preview/export`、`runtime update *`、`device/target display-name`、
  `history filter *`、`trace cache status/purge`、`ui-dump inspect/hit-test`、
  `diagnostics inspect/preview/export`、`trace inspect/export`。各面的实现契约见
  `docs/design/cli-*.md`。
- §14 机器契约产物已落地（`TASK-AIN-026`，实现见 `cli-machine-contracts.md`）：
  `arkdeck maintainer contracts export|check` 从 Swift 事实源生成全部十项
  `openspec/contracts/` 产物与 `Packages/ArkDeckKit/Tests/ArkDeckContractTests/Fixtures/CLI/**`
  （219 个 argv fixture、envelope/page/`nextAction` 样本），`CLIMachineContractTests` 以零漂移、
  fixture 回放与 schema 正反例把产物钉在 protected `main` 上；`--version` 的
  `pageSchemaVersion`/`nextActionSchemaVersion` 为 `arkdeck.cli.page/1`/`arkdeck.cli.next-action/1`。
  `cli-feature-coverage.json` 共 279 条（daemon 119、Catalog 30、App 68、CLI 62）：
  `direct` 131、`local` 94、`presentation` 21、`internal` 18、`refused` 10、`platformService` 4、
  `generic` 1（`flash.dayu200` alias），`blocked` 0，`summary.fullFunction = true`。
- Golden Journey headless 闭环：2026-09-02 在 digest `508783ac…` 上按 `cli-golden-journey-headless-runbook.md` headless 复跑：GJ-1/GJ-2/GJ-3/GJ-4/GJ-5 均 `REAL_DEVICE_PASS`（含 §2.1 HAR crash-resume 与 `debug.template@1` smoke）；2026-09-03 用最终候选补齐其余 17 个 operation 后，29 个 canonical operation 的真机覆盖矩阵为 29 `realDevicePass` / 0 `notExercised`，记录见 `references/v1.6-goal/gj-headless-rerun-2026-09-02.json` 与 `real-device-validation.md`。
- 0.2 版 §13.2 列出的 12 个 daemon-ready 方法均已有一等 leaf。App 的 Debug Commands 与
  Overview 也经 `debug.template@1` 的 Runtime Job 路径运行模板；App XPC 不再转发
  `debug.template.run`。该方法只作为 Unix control plane 的 deprecated 兼容面保留，CLI 与 App
  均不调用。

### 13.2 尚未闭合的目标面

macOS「全功能」结论已由 §14 机器门、当前 digest 上 29/29 operation 真机覆盖和 App
Debug template 生产投影闭合。下表只保留跨平台范围，不得在 CLI 内补隐藏执行器绕过 Runtime。

| 目标面 | 现状 | 解除条件 | slice |
|---|---|---|---|
| Windows（Slice D） | 未开始 | 不阻断 macOS-only claim；阻断跨平台 claim | D |

### 13.3 已发布 leaf 的残留缺陷

不阻断命令面存在，但计入 conformance 差距，必须在对应 slice 内修，不能靠文档解释掉：

2026-09-03 `TASK-AIN-021` 经 #1703/#1707 闭合五类产品差距：preflight rejection 投影、USB 重插 HAR、
legacy Runtime workspace root 清理、派生 Job 的来源项目引用，以及 App Debug template 的 Job
投影。current domain leaf 保留 frozen 1.x read projection，
但在 admission boundary 上协商 2.x `job.submit` owner。同一 `workspace patch` stale
`expectedWorkspaceRevision` 负向用例现在返回 `ok:false`、`error.code: invalidInput`、exit 65，
并逐项发布 `phase: preAdmission`、`newDispatchCount: 0` 与 `wireCode: invalidInput`；2.x
`job list` 的 newest Job 在调用前后保持同一 ID/时间戳。fresh exact stable-identity + binding
proof 现在会直接解决 `physicalConnection` action，不再追加冗余 `ambiguousIdentity` action；
终态也由合约钉为 superseded/resolved 语义。五项均不再计入下列残留。

同日后续候选把 `legacy flash reconcile` 的 Session 根解析切到与 `runtime storage`/Session
resource 共用的 daemon-owned `RuntimeSessionStorageStore`；读取持有同一文件锁，不再查看 CLI
进程自己的 `UserDefaults`。该 leaf 仍是本地历史归档读取、保持冻结参数面且零设备派发；候选
结论待维护者 review 后进入 protected `main`。

- `job list` 的 newest/oldest 分页仍以 SQLite `rowid` 作 cursor 与同 timestamp tie-break
  （`RuntimeJobRepository.listJobs`）；§7.3 compound order 未落地，Windows portable 前必须替换。
- 1.x 兼容 wire path 的 `artifact.read` 仍把 `maxBytes` clamp 到 1…4 MiB；2.x target handler 已按
  §7.6 拒绝越界。前者按 §12 冻结，不再修改。
- `help device` 中 `show` 的 summary 与 `list` 相同（"list durable targets…"），registry 文案错误。

### 13.4 纯展示与平台服务，不是 CLI 阻塞项

- Timeline/native tree/window chrome；
- Finder/Explorer reveal；
- App 的本地视频播放与视图状态；
- Overview 卡片排列和 workspace navigation；
- App Remote Build Source（Settings › Servers、Debug › Artifacts 的只读 SSH 浏览、Overview 的
  source 绑定）：按 DEC-013 归 `platformService`，CLI 等价路径是本地
  `artifact import native-library` + `debug native deploy`。

CLI 能按 schema inspect/export 源数据与派生数据，并明确 parser/version/digest，即满足功能等价；
`platformService` 条目以其 CLI 等价路径满足功能等价。

## 14. 机器可读规格产物

实际实现时应在同一 P4/GJ 垂直产品任务中增加并生成以下产物；不要先做一轮只有文件没有产品
入口的 governance PR：

```text
openspec/contracts/cli-command-registry.yaml
openspec/contracts/cli-result.schema.json
openspec/contracts/cli-page.schema.json
openspec/contracts/cli-event.schema.json
openspec/contracts/cli-next-action.schema.json
openspec/contracts/cli-error-registry.yaml
openspec/contracts/cli-canonical-json-vectors.json
openspec/contracts/cli-feature-coverage.json
openspec/contracts/app-product-capability-registry.yaml
openspec/contracts/runtime-control-plane.schema.json
Packages/ArkDeckKit/Tests/ArkDeckContractTests/Fixtures/CLI/**
```

0.5 起这些产物由 `arkdeck maintainer contracts export` 从 Swift 事实源生成，
`arkdeck maintainer contracts check` 与 `CLIMachineContractTests` 钉零漂移；fixture 目录放在合约测试
target 既有的 `Fixtures/` 下，与其他 fixture 族共用同一 `#filePath` 相对定位。实现契约、每项产物的
事实源与 fixture case 清单见 `cli-machine-contracts.md`。

`cli-feature-coverage.json` 为每个能力记录：

```json
{
  "feature": "job.evidence",
  "source": "daemon:job.evidence",
  "classification": "direct",
  "targetClassification": "direct",
  "lifecycle": "current",
  "targetCommand": "arkdeck job evidence --job <job-id>",
  "equivalentCommands": [],
  "requiredPlatforms": ["macos", "windows"],
  "implementationStatusByPlatform": {
    "macos": "implemented",
    "windows": "notImplemented"
  },
  "conformanceFixture": "argv/job.evidence.json"
}
```

`source` 是唯一键（`daemon:`/`catalog:`/`app:`/`cli:` 四个前缀），`feature` 是自然名；
`targetCommand` 是完整 argv pattern（path + required option 占位符），`equivalentCommands`
列出到达同一能力的兼容拼写或替代 leaf；App 条目另带 `owner`，其余可选 `note`。同一 daemon
method 缺 CLI 而只能记 `blocked` 时，`macos` 为 `partial`：

`classification` 只使用下列闭集，并表示当前产品事实；`targetClassification` 表示本规格
要求的落点，不能把 target 写成已实现：

| classification | 含义 |
|---|---|
| `direct` | 已有稳定 public CLI + typed Runtime/control resource |
| `generic` | 已可经 Catalog `operation/job/agent` 泛化执行，只缺领域 convenience |
| `local` | 已有 App/CLI 共用的 bounded、versioned 本地产品资源，不改 Runtime authority |
| `presentation` | 只是视觉/导航/播放器行为，底层数据已可 inspect/export，不需要 CLI leaf |
| `platformService` | App 拥有的宿主平台服务（凭据、远端主机、host-key 固定），其产品结果 CLI 经 bounded local import/registration 可达；不需要 CLI leaf，条目必须写明 App owner 与 CLI 等价路径（DEC-013） |
| `internal` | 只是公开 leaf 的封闭 protocol plumbing，例如 artifact chunk frame；不应出现在 help |
| `refused` | 为兼容/安全而保留的具名 method/tombstone，每次都以 stable reason 拒绝且零 effect |
| `blocked` | 缺少达到目标的完整公开产品面/所有者边界；即使已有部分 typed daemon method 也可属此类，并会阻止相应的“全功能”结论 |

deprecated/legacy 是额外 lifecycle metadata，不是第九种可达性分类。raw command、capability admin
管理效果、legacy executor 等 forbidden effect 必须从 executable registry 缺席；旧 CLI token 可仅作为
parse-only compatibility tombstone 存在。若为拒绝旧 caller 而保留了具名 wire method，则只能标
`refused`。`requiredPlatforms` 是目标，
`implementationStatusByPlatform` 是现状；Windows 不得因出现在前者就被标为 implemented。
status 闭集及机械含义为：

| status | 判定 |
|---|---|
| `implemented` | 该平台完整 target contract、registry mapping 和 required fixture 全通过；`blocked` 或 classification/target 不同不得使用 |
| `partial` | 至少一层真实 surface/method/resource 已实现，但 target contract 或 required fixture 未闭合；仍阻断 claim |
| `notImplemented` | 该平台没有可执行 target surface；仅文档/schema/fixture 不算实现 |
| `deferred` | manifest 指向明确后续 slice/task，但当前仍按未实现阻断；不能借排期获得通过 |
| `nonConformant` | 有可执行实现，但已知违反 target/Core/safety contract；不得发布/support claim |
| `unsupportedByProfile` | 仅 platform extension 且该平台 ratified profile 明确不要求；Core 和 required extension 不可使用 |

generator 必须校验 classification↔status：任一 required platform 的 `implemented` 都要求
`classification == targetClassification` 和 fixture pass；已有 daemon method但缺 CLI（示例
`job.evidence` on macOS）是 `partial`，不是 `notImplemented`。

coverage 不是人工维持的任意清单。generator 必须取以下可枚举输入的并集：daemon method
registry、generated Catalog index、declarative CLI registry，以及
`app-product-capability-registry.yaml`。每个 App route、menu action、用户可触发 command/action
必须引用 registry 中的 stable feature ID；纯 layout/render helper 不登记。任何输入新增 feature ID
但 coverage 没有 exact entry、出现重复/孤儿 ID 或引用未知 ID，CI 都 fail closed。
新 canonical Catalog operation 的默认 `targetClassification` 可以是 `generic`；只有 accepted GJ/
产品 workflow 明确要求一等 convenience/resource 时才是 `direct`。因此“generic”与 `platformService` 都不是缺口，
`classification != targetClassification` 和任何 `blocked` 才是该平台的覆盖缺口。

覆盖检查必须保证：

- daemon/Catalog/App/CLI 四个 registry 的每个 feature ID 都使用上述闭集，不存在
  `unclassified`、orphan 或 duplicate；
- `capability.draft/install/revoke` 必须是 `refused`，并有持续证明 stable rejection 和零副作用的 negative fixture；
- 每个 canonical Catalog operation 可经 generic surface 发现、plan、submit、run 和读取 result；
- capability admin、raw command、legacy executor 等 forbidden effect 没有 executable mapping；兼容 token
  只能出现在 parse-only tombstone metadata；
- generated help、completion、docs、Swift parser 和未来 Windows parser 对同一 registry 零漂移。

## 15. Conformance 与验收

### 15.1 共享 fixture

每个 portable leaf 至少覆盖：

1. valid argv → normalized typed request；
2. missing/unknown/duplicate/conflicting option → exit 64；
3. file bytes/type/UTF-8/JSON/schema 不合法 → `invalidInput`/65；path 不存在或 open/read/write 失败 →
   `ioFailure`/74；打开后的 file identity/no-follow/reparse relation 漂移 →
   `fileIdentityChanged`/77；三者均零新 dispatch；
4. success JSON envelope schema；
5. structured daemon error → error envelope + stable exit；
6. human output 不参与跨平台 byte equivalence；平台 path/service/tool diagnostics 可以不同，但
   safety state、reason 与下一动作语义必须一致；
7. registry 声明 event-enabled 的 leaf 覆盖 JSONL sequence/terminal；其他 leaf 覆盖
   `--output jsonl` 的 `invalidOption`；
8. timeout、Ctrl-C 和 daemon disconnect；
9. sensitive/redacted/secret negative cases；
10. macOS/Windows normalized request/result equivalence。

fixture 输入是 argv array、stdin bytes、logical files、daemon response frames 与预期 stdout/stderr/
exit；不得以 shell script 的 quoting 作为共享事实源。0.5 起第 1、2、4、5、7 条与 tombstone/
lifecycle 行由 `Fixtures/CLI/**` 的生成基线覆盖（每个 leaf 一个 argv fixture，`expected` 只记
invocation 种类或 error code/category/exit，不记 prose）；第 3、8、9 条仍由
`CLIProcessGoldenContractTests` 与各族合约测试覆盖，第 10 条等 Windows port。

### 15.2 契约测试

- command registry → parser/help/completion/docs 全生成且零漂移；
- CLI public command → daemon method allowlist parity；
- Catalog descriptor → operation describe/validate/example parity；
- 所有 Job state 与 daemon error code 的 exit mapping 穷举；
- `--output json` 恰好一个 document，错误也能过 schema；
- event-enabled leaf 的 `jsonl` 每行独立可解析并有唯一 terminal；non-event leaf 明确拒绝；
- page/cursor/`nextAction` 所有 union 分支和 reconnect/high-water vector；
- RFC 8785 canonical JSON property/string/number/Unicode/rejection vectors，以及 existing
  Catalog/plan/Artifact digest 不被重算的 pass-through vectors；
- artifact range/raw/export 的 byte、digest、EOF、privacy 与 overwrite；
- target/candidate/binding revision/facts drift negative matrix；
- idempotency same-key/same-request、same-key/different-request、lost-response retry；
- Agent execution list/lost-output、same-ID re-entry/conflict/terminal replay，以及 pre-Job abandon vs
  Job-creation race；
- `maximum-wait` deadline boundary、HAR pause、client disconnect、Runtime restart、wall-clock
  rollback/untrusted clock 与 existing Job non-cancellation；
- HAR owner union、resume reference expiry/selection/facts drift；
- legacy Flash alias 保留原 request/reference，CLI 不做隐式 destructive field transform；
- HDC impact preview ID/digest/generation/expiry/confirmation 与 dispatch 前 drift matrix；
- HDC/tool control-action lost-receipt rediscovery、action-request idempotency、interactive
  App/TTY challenge、non-TTY/preseed/self-approval 拒绝、tool acquire/remove race 与 shared-endpoint
  outcome broadcast/reconcile；
- Session export preview/apply 的 generation、privacy/default exclusion 与 destination drift；
- Session pin/unpin generation CAS、active cleanup exclusion 与 unpin-no-delete；
- forbidden operation/job raw executable/argv/HDC/shell/remote path、capability admin、network endpoint；
- host tool/bundle registration 的 pre-daemon bootstrap、kind/size/file-identity/hash/signature/trust/
  reference/remove negative matrix；
- workspace project/preset registration/idempotency/CAS/remove、discovery/availability/drift 与无
  host-path projection；
- imported input request idempotency/resume/abort/rediscovery、lease generation、active-reference
  release/quota 回收，以及 crash-after-begin/append/commit + lost append response；
- UDS 与 named pipe transport 运行同一 handler fixture；
- Windows/macOS Unicode argv、file identity、console secret、service lifecycle adapter vectors；
- control method token 字节级冻结与非法 multi-frame negative fixture；
- control protocol 1.x preservation、1.x↔2.x negotiation、2.x breaking-shape/effect matrix，以及 2.x
  client 对 1.x target leaf 的零 dispatch refusal fixture；
- `protocol.negotiate` bootstrap 的 strict field/frame/size/SemVer/order/intersection vectors、highest-common
  exact selection、cross-major refusal、old-daemon legacy direct-1.0.0 sole fallback 与 mutation-unknown
  no-renegotiation/no-replay fixture；
- deprecated machine lifecycle metadata、每个 removed tombstone 的 `commandRemoved` exact
  replacement/no-replacement，以及 unknown typo `invalidCommand` distinction。

### 15.3 Golden Journey 验收

只有当前 Catalog digest 的真实设备结果可以记 `REAL_DEVICE_PASS`。Journey 的跳数与顺序以
`PRODUCT-LOOP.md` §6 为准；判据只包含 CLI/Runtime 可验的确定性事实（terminal state、evidence、
Artifact digest、台账计数、HAR 状态）。执行者是人还是外部 Agent，以及执行者的修复智能，都不进入
四态：

- GJ-1：`doctor` → `device candidates` → `target adopt` →
  `agent run --operation observe.device@1` →
  `agent run --operation capture.diagnostics@1`（设备级 bounded HiLog + UI Dump，`readOnly`）
  → `job result` → daemon 重启后仍可读；并在同一 Journey 内证明 HAR crash-resume：zero-candidate
  discovery 产生的 `physicalConnection` HAR，客户进程丢弃 receipt 后仅凭 execution ID 经
  `agent status` / `human-action show` / `agent resume` 继续到 terminal；
- GJ-2：import HAP → `agent run --operation debug.hap@1` → liveness/evidence/Artifact；
- GJ-3：import native library → `debug native deploy`（`deploy.native-library.app-owned@1`）→
  ELF/ABI/hash、staging、原子发布、进程重启、`hashProcessAndMaps` 全部 verified → 失败 rollback 腿
  同样 verified；
- GJ-4：Flash bundle import → prerequisites/plan →
  `agent run --operation flash.full-restore@1`
  → postflight evidence；
- GJ-5：外部 Agent 只用 operation/device/target/job/agent/artifact/HAR 完成有界闭环：发现
  project/preset refs → 复现 → `analyzer.extract-crash-signature@1` → workspace isolate/patch/build/sign
  → 部署修补构建并一次复验 → 负向 `revisionConflict` 零派发；补丁是固定输入物料，
  `PRODUCT-LOOP.md` §6 的九项预算随任务书保存并记录实际消耗；不打开 App，不使用任何未发布面；
  客户进程崩溃后的 execution 重取复用 GJ-1 已证明的同一机制。

每次复跑另附当前 digest 的 operation 真机覆盖矩阵（§13.2）。
机器契约测试不替代真机；真机不替代 contract/negative test。

## 16. 分阶段落地

### Slice A：P4 机器契约与 GJ-1 闭环

- declarative command registry、strict parser、help/version/completion；
- generated control registry、1.x preservation 与 2.x target negotiation；先消除 client hard-coded
  protocol version，再迁移破坏性 method shape/effect；
- `--output json/jsonl`、error envelope、exit registry；
- 完整 `operation list/describe/example/validate` descriptor/availability projection；
- `runtime health`、HDC status、device candidates、真正的 target show；
- job evidence/result、Artifact quota/range read；
- stable request identity/idempotency、page/`nextAction` schema（§14 十项产物与 fixture 基线已由
  `TASK-AIN-026` 交付，见 §13.1）；
- Runtime-owned AgentExecution/HAR persistence、`agent list/status/abandon`、`human-action list/show/resume`；
- process-level golden 与 GJ-1 真机验收。

### Slice B：现有 daemon 与 Catalog 的领域全覆盖

- Flash prerequisites/access/bootloader/lane/bind；
- Debug probe、template-run Catalog/Job 迁移与 normal Debug namespace；
- screen/input/diagnostics/UI dump/trace/analyze/port-forward/workspace convenience mapping；
- workspace project/preset bounded registration/discovery 与 typed continuation；
- target availability aggregate Runtime projection；
- job wait、unary durable events/watch contract、fixed pagination、Artifact raw/export；
- imported-input request idempotency/rediscovery/resume/abort/release 与 HDC durable
  control-action/HAR carrier；
- `control-action list/show/reconcile`、idempotent HDC impact preview 与 generation-bound runtime tool
  register/list/inspect/select/remove、runtime bundle register/list/inspect/remove lifecycle；
- `runtime service/signing`、`maintainer update-feed`、Artifact/cleanup/debug/Flash 的 canonical 命名迁移、
  parse-only tombstone 与 compatibility fixture；
- GJ-2～GJ-5 对应真机验收。

### Slice C：本地产品能力资源化

- Session retention、storage/support bundle；
- device/target display name、History saved filter、Trace derived-cache purge；
- offline parser/schema；
- update 平台服务（remote source 按 DEC-013 归 `platformService`，不资源化）；
- 每项都先有 typed contract，再由 App/CLI 共用，不直接包装私有 facade。

### Slice D：Windows W0/W1

- 在当时 ratified Core 上更新 Windows profile；
- 实现 named-pipe、service、credential、process、file identity、HDC/USB adapters；
- 运行完全相同的 portable CLI fixture 和 Core conformance suite；
- 只有 W0/W1 gate 与真实硬件证据成立后，才声明 Windows 支持。

每个 slice 仍遵守“一个问题 = 一个垂直产品任务 = 一个 PR”。不能为了显得完整拆出
readiness/status/done-only PR，也不能为 Windows 预先做与当前 Golden Journey 无关的代码重构。

## 17. Normative requirements

### CLI-REQ-001：单一 typed 执行面

所有用户选择的 device workflow/template 与 Catalog operation execution 必须经已发布 operation、
typed request、Runtime admission、Job/WAL 与 Provider；CLI 不得拥有 raw executor。accepted bounded
read-only discovery/probe method 只能返回观察，
不能执行用户选择的 workflow/template，也不能产生 Job result/evidence。

**Acceptance：** 对任意 operation workflow/template/execution leaf，测试能追踪到一个 Catalog
operation/Job；绕过 Job 的此类 device method 必须是 accepted bounded read-only observation，并有
“不发 Job/result/evidence”fixture。target/adopt、Artifact Import、HAR/control action、loader binding
等 typed resource lifecycle method 必须映射到本文列出的 durable owner/WAL contract，也不得冒充
operation result/evidence；raw shell/HDC/argv/device path 输入均在 dispatch 前拒绝。

### CLI-REQ-002：全能力可分类

每个 daemon method、Catalog operation 与用户可见 App 能力必须在 coverage manifest 中被分类，且
只能使用 `direct/generic/local/presentation/internal/refused/blocked`，不存在
`unclassified`。

**Acceptance：** CI 对新增 method/operation/App capability 产生未分类差异时 fail closed；
capability admin 拒绝桩始终标为 `refused` 且 negative fixture 证明零副作用。

### CLI-REQ-003：Catalog 自动可达

任意新 canonical operation 合入后，必须无需新增手写 CLI executor 即可 list、describe、validate、
plan、submit/run 和读取 result。

**Acceptance：** fixture 注入一个测试 descriptor 后，generic surface 自动出现且 typed validation
生效；domain alias 缺失不影响可执行性。

### CLI-REQ-004：单一命令 registry

parser、help、completion、docs 与 tests 必须由同一 language-neutral registry 生成。

**Acceptance：** 手工加入实现但未更新 registry，或 registry leaf 无 parser/help/test 时 CI 失败。

### CLI-REQ-005：严格 argv

所有 leaf 必须拒绝未知、重复、缺值、互斥与不适用 option。

**Acceptance：** 每个 option-class 的 positive/negative matrix 在 macOS 与 Windows 得到相同
normalized error code 和 exit 64。

### CLI-REQ-006：版本化机器输出

JSON success/error 与 registry 声明的 JSONL event 必须符合 versioned schema，并遵守
stdout/stderr 边界。

**Acceptance：** 每个支持 JSON 的 leaf 的成功和失败进程测试均通过 schema；`json` 恰好一个
无 BOM UTF-8/LF document。event-enabled leaf 的 `jsonl` 每行同样无 BOM/LF 且恰好一个 terminal
event，其他 leaf 与 `jsonl` 组合稳定
拒绝；completion script/raw renderer 不被 envelope 污染；bootstrap 的 missing/duplicate/invalid
output 与 control-request-id argv error 也通过相应 renderer fixture，编码失败不会 fallback 到 human。

### CLI-REQ-007：稳定错误与退出码

相同语义在所有平台必须返回相同 machine reason category 和 exit code；unknown outcome 永不为 0。

**Acceptance：** §8.4 最小 code 和所有 Job state/wire error 的 registry 穷举测试无 default
branch；新增状态/reason 没有映射时编译或 CI 失败；任何映射不解析 human message。

### CLI-REQ-008：可重试身份

CLI 必须允许自动化固定 request identity、idempotency key 与 Agent execution ID，并支持
lost-response 后安全查询同一 execution/Job。

**Acceptance：** 同 key/same canonical request 返回同一 Job；同 key/different request conflict；
同 execution ID/same request 返回同一 execution/HAR/Job/result，不同 request conflict；网络断开
或进程崩溃后重试不产生第二次 dispatch。`maximum-wait` 从首次 durable commit 起含 HAR pause/
disconnect/restart，deadline re-entry 不重置；时钟倒退 fail closed，已有 Job 不被隐式取消。
reviewed plan digest 匹配才能在 preauthorization/admission 前继续；mismatch 为
`reviewedPlanMismatch` 且零新 admission/Job/dispatch。
auto-generated execution receipt 丢失可经 `agent list` 重发现；pre-Job abandon 与 Job creation
线性化，后者胜出后只能显式 `job cancel`。Flash recovery invocation 的 same request ID 重试/按
request ID status 也必须返回同一 owner，不能生成第二份 decision document。

### CLI-REQ-009：显式 target/binding

device-bound operation 必须绑定 exact durable target 与 fresh binding revision；不得选择默认设备。

**Acceptance：** zero/one/multiple/unauthorized/facts-drift candidate matrix 都有确定结果；歧义进入
HAR 或拒绝；stale observation generation 与 connect-key reuse 不产生 binding mutation/dispatch。

### CLI-REQ-010：完整 Job result

CLI 必须提供 status、page/`nextAction`、wait/events/watch、result、evidence、Artifact
inventory、cancel 与 reconcile 的闭环。

**Acceptance：** 外部 Agent 不解析 App 状态、不访问 store 文件，仅凭 CLI 即可区分 success、
failed、cancelled、HAR、unknown、cleanup debt 和 evidence failure。

### CLI-REQ-011：Artifact 安全

Artifact read/export 必须 bounded、digest-addressed、privacy-aware，且 raw stdout 与 machine metadata
严格互斥。

**Acceptance：** 大 Artifact 可通过 range 完整重组并核对 digest；sensitive 未显式许可、越界、
替换文件、覆盖 destination 全部 fail closed。

### CLI-REQ-012：HAR 与 recovery 不扩权

resume、reconcile 和 cleanup 只能在 Runtime 记录的同一 Job/AgentExecution/controlAction
owner boundary 内继续，不能
生成 authority 或 replay unknown destructive intent。

**Acceptance：** expired resume reference（`humanActionExpired`）、facts drift、capability mismatch、unknown destructive outcome 和
arbitrary residue path 全部零新 dispatch。

### CLI-REQ-013：本地 transport

CLI control plane 必须是 current-user local-only transport，handler 与业务 contract 不依赖 UDS 或
named-pipe API。

**Acceptance：** 同一 handler suite 分别通过 UDS 和 named-pipe harness；TCP/HTTP endpoint、peer
identity 不明、ACL 过宽均拒绝启动或连接。

### CLI-REQ-014：平台语义一致

Windows 只替换 approved platform adapters，不得修改 Core command、request、Job/Artifact/HAR、
error、exit 或 safety semantics。

**Acceptance：** macOS/Windows 对同一 argv-array 和 fixture 得到相同 normalized request、result、
reason code 与 exit；差异仅出现在 schema 明确允许的 platform diagnostic fields。

### CLI-REQ-015：兼容可见

旧命令和 JSON shape 的迁移必须有 version、alias/tombstone、replacement 和 removal window；不得
静默重新解释。

**Acceptance：** deprecated leaf 在 human 模式给出 replacement，machine 模式 shape 不被 warning
污染且 target `--output` mode 的 `meta.lifecycle` 完整；显式 `legacy-json` 保持旧 shape、缺该 meta
并且不计 target conformance。removed leaf 返回 `commandRemoved` + exact replacement/no-replacement，
unknown typo 仍是 `invalidCommand`，dangerous tombstone 永远不能 dispatch。

### CLI-REQ-016：真实设备结论

CLI 的“全功能”完成结论必须以当前 Catalog digest 上的 GJ 真机证据为准。

**Acceptance：** fixture/simulation/plan-only 标记不会被验收工具接受为 `REAL_DEVICE_PASS`；每个
需要设备的 slice 都记录 exact target、binding、Catalog digest、Job、evidence 与 Artifact identity。

### CLI-REQ-017：bounded host registration

host tool、daemon bundle 和 credential material 只能通过 kind/schema/size/file-identity/hash/trust
校验的 registration/import 进入系统；operation/job/service execution 只消费 typed reference。

**Acceptance：** caller path 在 registration 后被替换不会改变已注册 identity；Job request 中的
executable/argv/path 被拒绝；macOS/Windows 对同一注册内容得到相同 content identity 与 trust reason。

### CLI-REQ-018：HDC/tool lifecycle 两阶段执行

HDC server lifecycle mutation 与 active HDC tool selection 必须由 `impact-preview` 以 caller-stable
action request ID 幂等、原子创建同时包含 generation-bound preview 的 durable control action；
`restart` exact 引用该 control action + preview ID/digest，并以 owner-bound HAR 取得/消费所需用户确认；
dispatch 前重算完整 canonical impact 并要求 exact equality，同时重验证 owner、generation、critical
Job 与 expiry。

**Acceptance：** preview mismatch、owner/facts drift、owner/generation 无法精确投影、
任意 affected device/target/Job/client、unknown-client、interruption/recovery 或 gate 集合/value 变化、
criticalNonInterruptible/尚未到 safe boundary 的 Job、expiry，或自动路径/缺少 exact 用户确认时
lifecycle dispatch 为 0；成功和拒绝都产生
host-wide audit record。经 exact 用户确认的 external/unknown manual restart 保持原 ownership，且
不能被复用为下一次 lifecycle authority。receipt 丢失可经 control-action 重取；App explicit UI/
interactive TTY challenge 以外的 argv/stdin/env/file/preseed/self-approval 全部拒绝；shared-endpoint
unknown outcome 向所有受影响 owner broadcast 并只进入 reconcile。

### CLI-REQ-019：durable watch

`job watch` 必须建立在有 stable event identity、revision/cursor 与 reconnect contract 的 unary
`job.events` page surface 上；client-side snapshot polling 不能冒充 lossless stream。

**Acceptance：** disconnect/reconnect fixture 不丢失或重复消费 event；旧 timeline array 只能用于
snapshot display，不能满足本 requirement。

### CLI-REQ-020：Session 导出预览

Session export 必须使用 generation-bound preview/apply，列出 privacy、bytes、redaction 与默认排除
内容；sensitive device raw 默认不进入导出包。

**Acceptance：** 未 preview、digest/generation 漂移、默认 raw inclusion、Artifact privacy 漂移或
destination 替换全部拒绝，源 Session/Artifact 保持不变。

### CLI-REQ-021：legacy intent 保真

CLI 不得把 input schema 不同的 legacy operation alias 静默改写为 canonical destructive request。

**Acceptance：** explicit `flash.dayu200` generic request 原样到达 Runtime alias contract；历史
Job/plan/evidence 保留原 reference；只有独立 versioned migration transform 可以产生新 canonical
request，且输出新的 request identity/idempotency lineage。

### CLI-REQ-022：Workspace typed bootstrap/discovery

CLI 必须能在 fresh host 通过 bounded registration 建立、更新、移除并发现 project/preset
reference、typed constraints 与 availability；注册后不得暴露 host root/executable/argv，Catalog 中
的字符串示例不是 discovery API。

**Acceptance：** 不打开 App/不使用 legacy daemon path flag 即可注册 project + typed toolchain/
signing preset，经 list/show 发现并用于 GJ-5 request；same registration ID retry 幂等，generation/
active-reference drift 有稳定 reason；registration 外 caller path 和 raw build command 全部在 dispatch
前拒绝，remove 不删除源码。

### CLI-REQ-023：Imported input lifecycle

committed imported input 必须建立 durable Import owner + Import-owned Artifact，可按 Import ID 重新
发现/inspect/read/export 并释放 exact generation lease；release 不能删除仍被引用的
Artifact 或绕过 retention，legacy synthetic `jobId` 不得被当作 Job。

**Acceptance：** 首次 import receipt 丢失后仍能找回同一 digest/target/lease；active reference、
generation drift 与同 generation 重复 release 的幂等 receipt 有 fixture；quota 不因永久无法释放的
`pinnedUntilVerified` input 无限增长。same import request ID + same canonical metadata 恢复同一
Import/commit receipt，same ID + different metadata 为 `idempotencyConflict`，均不重复 upload/pin。
begin、mid-append、append durable commit 与 final commit 各 crash point 都只能暴露 last fully committed
chunk/offset；resume 不接受或遗留 partial chunk。

### CLI-REQ-024：Unicode 与 bounded machine I/O

macOS/Windows 必须对同一 Unicode scalar argv/JSON 产生同一 normalized request，不隐式归一；
stdin/request/response frame/duration 必须有共享的数值语法与上限。

**Acceptance：** Windows argv/JSON escape 的 unpaired surrogate、任意 caller JSON duplicate key、
invalid UTF-8、3 MiB stdin、4 MiB request frame 与
8 MiB response frame 边界±1 byte、duration overflow/
fraction/compound、RFC 8785 string/number/order/rejection 和 NFC/NFD distinct vectors 全部与本规格
一致；existing Catalog/plan/Artifact digest 保持 authoritative pass-through，dispatch 0 的 case 有证据。

### CLI-REQ-025：Control protocol 保真

control protocol 1.x 必须保持已发布 method token、request/response/effect shape 与“每个 request 恰好
一个 response”语义。本规格对 existing token 的破坏性 target shape/effect 只在协商后的 2.x 发布；
CLI 可在 unary event page 之上实现 watch，但不得把新增 method 当成在 1.x 改写旧 method，或在任一
major 暗中改为 server-push/multi-frame。exact version 必须经 §12 version-neutral bootstrap 按
required major 的 highest-common 规则选择；target/legacy 不得互相 fallback。

**Acceptance：** macOS/Windows 对 `flash.lanePlanPreview`、`cleanupDebt.list/continue` 的字节级
method fixture 一致；1.x legacy shape/effect 保持不变；2.x client 与 1.x daemon 的 target leaf 在
dispatch 前稳定拒绝；bootstrap malformed/no-common/cross-major/old-1.0.0 matrix 与 2.x negotiated
fixture 对 §12 breaking matrix 完全一致。wire rename、同 token
破坏性变化或同一 request 的第二响应 frame 在未升 major 时 conformance fail closed。

## 18. 设计完成定义

“全功能”是 platform-scoped claim。当且仅当以下条件在被声明的平台全部成立，才可以把该平台的
CLI 称为“全功能”；macOS 达成不表示 Windows 已实现，Windows 的 `deferred`/`notImplemented`
也不阻止准确的 macOS-only claim，但该状态禁止 Windows support claim：

- Slice A/B 已实现，Slice C 中所有非纯展示且属于既有产品的能力已经资源化，coverage manifest
  在该平台没有 `classification != targetClassification`，也没有任何 `blocked`、`partial`、
  `notImplemented`、`deferred` 或 `nonConformant`；以 `generic` 为目标且已 generic 可达的 Catalog
  operation 是完成态，不要求无产品价值的别名；`platformService` 条目（DEC-013）不是缺口，但
  必须写明其 CLI 等价路径；
- GJ-1～GJ-5 都能从 CLI headless 完成，且当前 digest 的适用真机证据成立；
- JSON/error/exit/help/completion/argv conformance 全通过；
- App/local 能力均已资源化或明确证明为 presentation-only，不存在隐式私有绕行；任何仍为
  `BLOCKED_BY_PRODUCT_DEFECT` 的既有产品能力都会阻止“全功能”结论；
- capability admin、raw command、legacy executor 和 remote control plane 仍然不可达；
- Windows 复刻可以只阅读 language-neutral registry/schema/fixtures 和 platform port 文档，而不
  需要反向推断 Swift CLI 的手写 parser、App facade 或 macOS API。

在此之前，准确表述是“Runtime operation coverage 完整，CLI 产品面尚未完全闭合”，不能只因为
`agent run` 能泛化调用 Catalog 就声称 CLI 已全功能。第一条的机器判据是
`cli-feature-coverage.json` 的 `summary.fullFunction`（0.5 起在 macOS 为 `true`）；第二条仍以
§13.2 的真机记录为准，机器门成立不等于 Journey 成立。

## 19. 权威参考

后续实现与 Windows 复刻必须直接读取以下事实源，不能把本文当作它们的副本：

- [`PRODUCT-LOOP.md`](../../PRODUCT-LOOP.md)：Golden Journey、P4、垂直任务与产品闭环规则；
- [`openspec/constitution.md`](../../openspec/constitution.md)：Safety invariants 与 POL-*；
- [`core-portability.md`](../../openspec/architecture/core-portability.md)：语言无关 Core 与原生实现；
- [`platform-ports.md`](../../openspec/architecture/platform-ports.md)：允许替换的平台 adapter；
- [`0005-agentd-uds-control-plane.md`](../adr/0005-agentd-uds-control-plane.md)：本地 control plane、
  transport-free handler 与 Windows named-pipe 方向；
- [`operation.schema.json`](../../Catalog/schema/operation.schema.json) 与
  [`Catalog/operations`](../../Catalog/operations)：已发布 operation 事实源；
- [`device-targeting-auth`](../../openspec/specs/device-targeting-auth/spec.md)、
  [`workflow-journal-recovery`](../../openspec/specs/workflow-journal-recovery/spec.md)、
  [`session-artifact-storage`](../../openspec/specs/session-artifact-storage/spec.md)：
  Target/Job/Artifact/recovery 语义；
- [`HumanActionRequired.swift`](../../Packages/ArkDeckKit/Sources/ArkDeckRuntime/HumanActionRequired.swift)：
  当前 HAR document/vocabulary 的盘点来源，不是 accepted Core 或 production owner contract；目标 HAR
  owner union 与 wire 语义必须先固化到 §14 的 language-neutral generated control contract，Windows
  不得以该 Swift 文件作为规范；
- [`debug-workbench`](../../openspec/specs/debug-workbench/spec.md)、
  [`toolchain-hdc-server`](../../openspec/specs/toolchain-hdc-server/spec.md)、
  [`flashing`](../../openspec/specs/flashing/spec.md)、
  [`trace`](../../openspec/specs/trace/spec.md)、
  [`ui-dump`](../../openspec/specs/ui-dump/spec.md)：领域边界。
