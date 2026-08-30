# ArkDeck 全功能 CLI 产品规格

> 类型：产品实现规格，不是新的 OpenSpec Task、Change、Readiness、批准载体或平台符合性声明。
> 状态：目标规格；文中“目标命令”不代表当前版本已经实现。
> 规格版本：0.1（2026-08-30）；盘点基线为 28 个 canonical Catalog operation、1 个 alias、
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
3. 每个 App 产品能力的底层数据或动作都被分类为“直接 CLI”“Catalog 泛化可达”“纯展示”或
   “缺少 typed Runtime 产品面”；不得存在未分类的暗功能。
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
| artifact | Job 发布的 immutable 本地证据；隐私与导出规则由 Artifact contract 决定 |
| HumanActionRequired | Runtime 暂停并要求有限人类动作的 typed 状态，不是聊天确认或新 authority |
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

CLI 的所有设备动作必须落到以下二者之一：

- `job plan/submit/run/...`：精确控制 Runtime 资源生命周期；
- `agent run/resume`：为外部 Agent 提供 discovery、adoption、binding、HAR、evidence 和 Artifact
  inventory 的高阶组合入口。

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
- 无参数时显示 root help 并 exit 0；非法 command 才 exit 64。
- 稳定资源名使用 singular；返回 collection 的 verb 使用 `list` 或领域明确的
  `candidates`。

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
| `--version` | CLI、control protocol、result schema 和 build identity |

`--endpoint` 只能选择本地 transport。正式产品不得支持 `tcp://`、`http://` 或远程 daemon。
macOS 的 `--socket <absolute-path>` 只作为兼容别名；Windows 不把 named-pipe 路径暴露成业务
参数。测试可使用显式 `unix://` 或 `npipe://` endpoint，但必须验证本地性和当前用户访问边界。

`--timeout` 使用 `250ms`、`30s`、`15m` 这类无歧义 duration；裸整数被拒绝。超时只停止或
暂停客户端等待：

- 已经成功 submit 的 Job 继续由 Runtime 拥有；
- CLI 只有收到明确 cancel 请求时才调用 `job.cancel`；
- destructive dispatch 结果不明时返回 attention/unknown，绝不猜测失败后重放。

### 5.3 输入来源与优先级

通用 Job/Agent 输入只允许两种互斥形式：

```text
--request-file <path|->

或

--operation <id@version>
[--target <target-id>]
[--expected-binding-revision <positive-int>]
[--inputs-file <path|->]
[--request-id <id>]
[--idempotency-key <key>]
[--capability <capability-ref>]
```

高阶 Agent 入口另有以下 orchestration 字段：

```text
agent run ... [--execution-id <id>] [--maximum-wait <duration>]
agent resume --resume-token <token> [--selection <typed-value>]
```

`--maximum-wait` 只限制 Agent 的 discovery/HAR orchestration 等待预算；它不能改变 operation
descriptor timeout、materialized plan budget 或 capability expiry。

- `-` 只表示从 stdin 读取一个有明确字节上限的 UTF-8 JSON document。
- `--request-file` 与所有 flag-form request 字段互斥。
- `--inputs-file` 的根必须是 JSON object，并按 operation descriptor 验证。
- v1 不定义 `name=value` 或 shell-like inline JSON；这样 PowerShell、cmd.exe、zsh 与 bash
  的 quoting 差异不会进入产品契约。
- device-bound operation 必须携带 exact target 和 expected binding revision；host-only operation
  不得伪造 binding revision。高阶 `agent run` 可通过 typed discovery/HAR 获取二者。
- flag form 必须允许 caller 固定 request identity 与 idempotency key；自动生成值可以是交互式
  默认，但不得成为自动化重试的唯一行为。
- capability 只能是 reference。CLI 不读取 authority document，不接受 trusted facts，也不生成、
  安装、扩大或撤销 capability。
- 文件读取必须有上限、拒绝类型漂移，并在打开后校验稳定 file identity；实现不能先检查路径
  再跟随被替换的 symlink/reparse point。
- host tool、daemon bundle、signing material 等本地文件只能进入有 kind/schema/size/trust policy 的
  registration/import leaf。成功后返回 content-addressed typed reference；Runtime service、Job 和
  Provider 不得继续消费 caller path。
- password、private key material 和 token 不得经 argv、环境变量、JSON、日志或 shell history
  进入 CLI；需要秘密时只从 no-echo console 或平台 credential reference 获取。

## 6. 目标命令树

目标命令树分为“稳定资源层”“领域工作流层”“平台/维护者扩展”。表中的命令是目标产品面，
不是当前实现清单。

### 6.1 稳定资源层

| 命令 | 语义 |
|---|---|
| `doctor [--deep]` | 汇总 Runtime、Catalog、provider、HDC、storage、target 和未决恢复问题；只读 |
| `runtime health` | 返回 control protocol、catalog digest、provider 和持久 store 健康 |
| `operation list` | 列出 canonical reference、availability、effect、binding、profile |
| `operation describe --operation <ref> [--target <id>]` | 返回完整 descriptor；有 target 时再计算 target-dependent availability |
| `operation example --operation <ref>` | 输出可提交的 request/inputs 示例，不 dispatch |
| `operation validate --operation <ref> --inputs-file <path|->` | 本地按 descriptor 验证，不访问设备 |
| `device candidates` | 列出 live candidate、authorization/health、observed time 及 adopted-target 关联 |
| `device wait --candidate <key> --state <state>` | bounded poll live discovery；只读，不自动 adopt |
| `target list` | 列出 durable targets 与 binding revision |
| `target show --target <id>` | 返回一个 target、profile、binding、last facts 和状态 |
| `target adopt --candidate <key>` | 经 Runtime 建立/更新 durable binding；歧义时 fail closed |
| `target observe --target <id>` | 以 `observe.device@1` 读取并验证 tool/device/binding facts |
| `target capabilities --target <id>` | 聚合 operation/tool/profile availability；不得与 RuntimeCapability 混名 |
| `job plan ...` | materialize exact plan，不 dispatch |
| `job submit ...` | 幂等创建 Job，不隐式执行 |
| `job run --job <id>` | 执行 fresh Job，或从 Runtime 证明的安全边界继续 |
| `job wait --job <id>` | 等待 terminal/HAR/unknown，超时不取消 |
| `job watch --job <id>` | typed event surface 落地后，以 JSONL/human event 观察状态并支持 cursor 恢复 |
| `job list` | 固定 page envelope，支持 order/cursor/include-current/include-timeline |
| `job status --job <id>` | 返回 compact state、progress、outcomeUnknown 与 next action |
| `job show --job <id>` | 返回完整稳定 Job snapshot；不替代 `status` 的脚本契约 |
| `job result --job <id>` | 聚合 terminal status、verified evidence 与 Artifact inventory |
| `job evidence --job <id>` | 验证并返回 trusted result evidence；不会创造新事实 |
| `job cancel --job <id>` | 请求 Runtime 在允许的边界取消；不把请求成功误报为已取消 |
| `job reconcile --job <id>` | 只按 accepted recovery 规则读回/结算；unknown destructive intent 不 replay |
| `artifact quota` | 返回 store total/used/remaining 与 policy identity |
| `artifact import <kind>` | 导入有注册 schema 的 host file；chunk RPC 保持内部 |
| `artifact list --job <id>` | 返回固定分页 inventory |
| `artifact inspect --job <id> --artifact <id>` | 返回 media type、privacy、bytes、digest、publish 状态 |
| `artifact read ...` | bounded range read；sensitive 内容要求显式许可 |
| `artifact export ...` | 显式导出到 host destination；默认不覆盖 |
| `capability list` | 只读列出 Runtime capability diagnostic projection |
| `capability inspect --capability <id>` | 只读检查 exact scope、lineage、expiry、consume 状态 |
| `agent run ...` | discovery→binding→submit→run→evidence→Artifact 的高阶默认入口 |
| `agent resume --resume-token <token>` | 在同一 execution 中消费 typed physical assistance |
| `human-action list/show/resume` | HAR 资源化后的稳定入口；实现前继续使用 `agent resume` |
| `recovery cleanup list` | 列出 typed cleanup residue/debt |
| `recovery cleanup continue --job <id> ...` | 继续 Runtime 已记录且仍在 owner boundary 内的 cleanup |
| `session list/show/pin` | 资源化后的 Session 管理；不得直接扫描 App 私有目录 |
| `session export preview/apply` | generation-bound 内容/隐私/脱敏预览后显式导出 |
| `session cleanup preview/apply` | generation-bound retention preview/confirm/apply |

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
| `debug` | `probe`, `template list/run`, `hap`, `native deploy`, `logs` | debug probe/template RPC + `debug.hap@1`、deploy/diagnostics operation |
| `port-forward` | `create`, `remove` | `port-forward.*@1` |
| `flash` | `device-access`, `bootloader-status`, `prerequisites`, `lane-preview`, `plan`, `bind-loader`, `run` | Flash Runtime methods + `flash.full-restore@1`；没有 legacy executor |
| `workspace` | `status`, `diff`, `inspect`, `read`, `isolate`, `checkpoint`, `patch`, `revert`, `build`, `test`, `sign`, `symbolize`, `sweep` | 已发布 `workspace.*@1` operations |
| `source` | `list`, `add`, `probe`, `remove`, `ls`, `fetch`, `bind`, `unbind` | 未来 typed source resource；只接受 source ref 与绑定根内 relative path |

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
| `deploy.native-library.app-owned@1` | `debug native deploy` |
| `port-forward.create@1` | `port-forward create` |
| `port-forward.remove@1` | `port-forward remove` |
| `analyzer.analyze-trace@1` | `analyze trace` |
| `analyzer.summarize-trace@1` | `analyze trace-summary` |
| `analyzer.summarize-hilog@1` | `analyze hilog-summary` |
| `analyzer.extract-crash-signature@1` | `analyze crash-signature` |
| `flash.full-restore@1` | `flash run` |
| `flash.dayu200` | legacy alias，只用于识别/展示历史引用；新提交使用 `flash.full-restore@1` |
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
- `source` 在正式 source resource/integration/profile 获批并落入 Runtime 前保持 unavailable。
  它不得把现有 App SSH/SFTP 代码直接包装成 CLI。
- `ui-dump inspect/hit-test`、diagnostics preview 和 trace inspect 属于 deterministic local
  derivation；必须记录 parser/version/source Artifact digest，不能把派生结果冒充新设备证据。
- 单帧/序列转视频是 presentation convenience；frame archive、index、时间和 digest 可读取即满足
  portable core。平台可另加 derive/export，但不能改变源 Artifact。

### 6.3 平台与维护者扩展

| 命令族 | 目标 leaf | 便携语义 |
|---|---|---|
| `runtime service` | `install`, `update`, `restart`, `status`, `verify`, `uninstall` | 管理当前用户的 local Runtime；实现由 platform profile 选择 service/broker adapter |
| `runtime tool` | `register`, `list`, `inspect`, `remove` | bounded 校验 host tool 后生成 typed tool reference；不是 executable passthrough |
| `runtime hdc` | `status`, `impact-preview`, `restart` | 展示 exact tool/server facts；mutation 必须 generation-bound、typed、audited |
| `runtime signing` | `install`, `normalize`, `migrate`, `status`, `remove` | 只传 credential refs；秘密由平台 credential adapter 持有 |
| `runtime storage` | `status`, `policy`, `root` | 未来 typed storage surface；不能直接修改 App preference 文件 |
| `runtime support-bundle` | `preview`, `export` | 先预览清单/隐私，再显式导出 |
| `runtime update` | `check`, `download`, `handoff`, `status`, `cancel`, `cleanup` | 用户同意与验证边界一致；不得静默安装 |
| `maintainer update-feed` | `prepare`, `assemble` | 发布维护工具；不接触 private key |

平台扩展可以因当前 platform profile 不支持而返回 `unsupportedOnPlatform`，但同一 leaf 的输入、
状态、错误和成功语义不能因平台而变化。Windows 不需要实现 macOS-only historical archive 工具
才能声称 portable core conformance；支持范围必须在 capability manifest 中明确。

## 7. 资源行为契约

### 7.1 Device 与 Target

`device` 和 `target` 必须分开：

- `device candidates` 只描述本次 discovery snapshot；结果必须有 generation/observedAt、
  candidate key、authorization state、health 和 adopted target link。
- `target list/show` 只描述 durable identity、profile 与 binding revision。
- `target adopt` 必须针对显式 candidate；多个候选或 identity 不明时返回 HAR 或拒绝。
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
tool facts 计算 target-dependent availability。`target capabilities` 是未来聚合 Runtime surface，
不能由 CLI 用陈旧的多次查询自行宣称设备可用。

CLI 不复制 Catalog validator。生成的 descriptor model、Runtime validator、CLI local validator 与
Windows validator必须运行同一 canonical vectors。

### 7.3 Job

- `plan` 只 materialize，返回 plan ID/hash、catalog digest、binding revision、effects、steps、
  budgets、required capability、availability 和 blocking reasons；exit 0 不代表设备验收通过。
- `submit` 以 idempotency key 创建或返回同一 Job。相同 key + 不同 canonical request 必须 conflict。
- `run` 只接受 Job ID。它不得允许 caller 替换 plan、facts、capability 或 resume point。
- `wait/watch` 观察 Runtime 状态，不通过重复 `run` 实现轮询。
- `cancel` 是请求；结果必须区分 requested、accepted、safe-boundary pending 与 terminal cancelled。
- `reconcile` 只执行 accepted readback。destructive outcome unknown 时不得重新 dispatch。
- `result` 只有在 Job terminal 且 evidence 可验证时才报告 completed outcome；Artifact 缺失或 digest
  不匹配必须作为 evidence failure 暴露。
- retry 自动化必须复用 request identity/idempotency key 或 existing Job ID，不能每次随机生成新 Job。
- list 的 JSON shape 不得因是否传 cursor 而从 array 变成 object；始终返回 page envelope。

### 7.4 HumanActionRequired

HAR receipt 至少包含：

- execution/job identity；
- stable reason code；
- 用户要做的有限物理动作；
- typed selection schema（如适用）；
- resume token/action identity；
- expiry 与等待预算；
- 当前没有新 dispatch 的明确状态。

human 模式可以在 stderr 显示可复制的 resume 示例；JSON 模式不得把 prompt 文字混入 stdout。
用户确认不能扩大 capability、覆盖 facts drift 或让 unknown destructive intent replay。

### 7.5 Session export 与隐私

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
- `artifact read --raw` 时 stdout 只能是原始 bytes，不能混入 JSON 或 progress；Windows 必须使用
  binary stdout mode。
- `--raw` 与 `--output json/jsonl` 互斥。脚本若需要 metadata，先调用 `artifact inspect`。
- sensitive Artifact 的 read/export 必须显式 `--allow-sensitive`；human warning 不是 authority，
  也不能改变 Artifact privacy。
- `artifact export` 默认拒绝覆盖。`--overwrite` 只授权 exact destination file，且不能绕过
  sensitive export 许可。
- import 必须流式、有 size/digest 校验、commit/abort；begin/append/commit 不作为公开 leaf。
- 当前注册导入种类的目标语法是
  `artifact import hap|workspace-patch|flash-bundle|native-library --target <id> --file <path>`。
  Flash profile 必须真实参与 validation/pinning；不能保留一个被 parser 接受但随后丢弃的
  `--device-profile`。
- device path 永不出现在 CLI input。provider-owned remote path 只可作为受限 evidence/diagnostic
  projection，并按隐私规则处理。

### 7.7 Capability 与 Recovery

- `capability list/inspect` 只用于诊断。正式 help、completion 和 registry 中不得出现
  `draft/install/revoke`。
- caller 可以提交已有 capability reference；Runtime 仍必须验证 exact operation/target/plan/facts/
  expiry/reservation。
- legacy record、聊天确认、CLI flag 或本规格不得生成 authority。
- cleanup continuation 只能引用 Runtime 已记录的 residue key/bundle identity；看似路径的字段也
  不能变成自由远端路径。
- current protected destructive Flash recovery 从 `debug` 命名空间迁到
  `recovery flash-invocation ...`；迁名不改变其 closed decision document 或 authority。

### 7.8 Runtime 与 HDC lifecycle

- `runtime service restart/update/uninstall` 必须先读取 active/unclosed Job、HAR、cleanup、unknown
  outcome 与 catalog identity；会破坏这些 owner boundary 时拒绝，不能用 `--force` 绕过。只有
  未来正式发布的 typed handoff contract 才能改变这一条件。
- `runtime hdc status` 必须报告 exact executable path/source/hash/signature、client/server/daemon
  version、endpoint、ownership 与 generation；unknown 字段不能用默认值填充。
- `runtime hdc impact-preview` 只读计算受影响 Job/target/server owner，并返回
  `previewId`、canonical `previewDigest`、server `generation`、`affectedJobs`、owner、expiry 和
  `confirmationRequired: true`、`dispatchCount: 0`。
- `runtime hdc restart --preview-id <id> --preview-digest <digest>` 只能消费 exact preview；执行前
  重读 generation、owner 与 critical Job gate。owner 相对 preview 漂移、owner/generation 无法被
  精确投影、active mutation、digest mismatch 或过期时零 lifecycle mutation，并写 host-wide
  audit result。
- 调用 restart 是对 exact preview 的显式用户确认；non-interactive Agent 必须通过对应
  HumanActionRequired/resume contract 取得该确认，不能自行合成。确认不是 authority，不能覆盖
  owner/facts/critical-Job gate。
- external/unknown owner 禁止自动 lifecycle mutation，但 accepted HDC contract 允许用户对 exact
  generation-bound preview 显式确认一次手动 restart。该动作不得转移 ownership，也不授权随后
  stop/start/restart 或其他 lifecycle action。
- CLI 不得提供 `hdc kill/start/restart --force`、raw HDC 参数或 executable override。需要新的
  lifecycle 语义时先补 typed audited product surface。

## 8. 机器输出契约

### 8.1 stdout / stderr

| 模式 | stdout | stderr |
|---|---|---|
| `human` | 最终结果的可读摘要 | progress、warning、HAR prompt、terminal error |
| `json` | 恰好一个 UTF-8 JSON document，以 LF 结束 | 默认静默；可有不影响机器读取的诊断，但不得含秘密 |
| `jsonl` | 每行一个 versioned event，最后一行必须是 terminal event | 同 `json` |
| `artifact read --raw` | 仅原始 bytes | terminal error/progress；成功不得追加换行 |

machine 模式禁止 ANSI、localized key、spinner、日志前缀和 human prose 混入 stdout。JSON 编码失败
必须返回结构化/terminal error，不能 fallback 到 human renderer。

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
    "controlProtocolVersion": "1.0.0",
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
- success 只能有 `result`；failure 只能有 `error`。
- `error.code` 是稳定、非本地化的 machine reason；`message` 可读但不作为 branching contract。
- `controlRequestRetryable` 只表示可以重试同一个只读/control request、用同一 idempotency key
  恢复 lost response，或查询已有 Job。它永远不授权创建新 Job、再次 `job run` 或 replay intent；
  destructive outcome unknown 时只允许 status/evidence/reconcile contract 指定的读取路径。
- `details` 必须是有 schema 的 bounded object，不能直接转储 Swift/.NET exception、host path、
  stdout/stderr 或秘密。
- 对没有 Runtime/Catalog 的本地命令，相应 meta 字段可以省略，不能伪造 digest。
  `runtimeCatalogDigest` 表示响应时 Runtime 当前 digest；Job 自己锁定的 digest 属于 Job/result，
  二者不得混名。
- canonical JSON 使用 UTF-8、LF、确定字段编码和明确 number bounds；不依赖 dictionary order 做
  语义比较。

### 8.3 JSONL event

本节是目标 event contract。当前 `job.status` 的可变 timeline string array 没有 durable event ID、
revision 或 cursor，不能实现 lossless watch/reconnect；在新的 daemon `job.events/watch` typed surface
落地前，`job watch` 必须报告 unavailable。`job wait` 可以 bounded poll snapshot，但不得把轮询结果
伪装成可恢复 event stream。

```json
{"schemaVersion":"arkdeck.cli.event/1","sequence":1,"type":"snapshot","command":"job.watch","data":{}}
{"schemaVersion":"arkdeck.cli.event/1","sequence":2,"type":"stateChanged","command":"job.watch","data":{}}
{"schemaVersion":"arkdeck.cli.event/1","sequence":3,"type":"terminal","command":"job.watch","ok":true,"result":{}}
```

- `sequence` 从 1 开始且严格递增。
- reconnect 后必须用 cursor/revision 恢复；重复 event 带稳定 event identity，consumer 可去重。
- CLI 自己的 progress 不是 Runtime event，不得写入 JSONL。
- event type `terminal` 表示本次 CLI stream 已结束，不必然表示 Job terminal；HAR、timeout、unknown
  以 `ok:false` 的 terminal event 和 exit 75 结束，Job 状态仍由 event payload 决定。
- `submit --wait --output json` 只能输出一个 terminal envelope；需要 submit 与 run 的中间事件时
  使用 `jsonl`。

## 9. 退出码契约

退出码是粗粒度 process contract；具体 branching 以 `error.code`、Job state 和
`outcomeUnknown` 为准。macOS 与 Windows 使用同一数值。

| code | machine category | 语义 |
|---:|---|---|
| 0 | `ok` | 命令语义成功；query 非 terminal Job 也可成功 |
| 1 | `operationFailed` | Job terminal failed/cancelled/interrupted，或验证器明确失败 |
| 2 | `integrityFailed` | host artifact/feed/signature 等本地完整性验证失败；兼容保留 |
| 4 | `legacyAttention` | 仅 legacy Flash archive 仍有 unresolved debt；不得用于新 core command |
| 64 | `usage` | command/option/argument grammar 错误或 removed tombstone |
| 65 | `invalidData` | JSON/schema/file content 不合法，但尚未 dispatch |
| 69 | `unavailable` | local Runtime、provider、tool 或 platform capability 不可用 |
| 70 | `internal` | 未预期内部错误；不得泄露 exception |
| 74 | `io` | bounded local I/O 失败 |
| 75 | `attentionRequired` | HAR、等待超时、outcome unknown、waiting for reconcile、result not ready |
| 77 | `admissionDenied` | policy/identity/facts/authority 拒绝且零 dispatch |
| 130 | `clientInterrupted` | CLI 收到用户中断；不等于 Runtime 已取消 Job |

补充规则：

- `job show/status` 查询成功时，即使 Job running，exit 0；状态在 result 中。
- `job result/wait` 遇到 non-terminal、HAR、unknown 或 timeout 时 exit 75。
- `job cancel` 的请求被接受可以 exit 0；随后 `job result` 看到 terminal cancelled 时 exit 1。
- `job reconcile` 若仍 unresolved 必须 exit 75；不得因为 RPC 本身成功而 exit 0。
- malformed input、unavailable、admission denied 都发生在 dispatch 前；machine result 应明确
  `dispatchCount: 0` 或等价证据（若对应 contract 已提供）。
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
- `arkdeck completion bash|zsh|fish|powershell` 从 registry 生成静态 completion。动态 target、Job、
  Artifact identity 默认不补全，避免将敏感历史写入 shell cache；显式 opt-in 后也只能走本地
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

### 11.2 平台 adapter

| 边界 | macOS | Windows | 不变语义 |
|---|---|---|---|
| local transport | user-private Unix domain socket | user-private named pipe | local-only、versioned frame、peer/user boundary、request limit |
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
- CLI 不自行展开 `~`、`%USERPROFILE%`、glob、command substitution 或环境变量。
- host path 保持平台原生 Unicode 表达；跨平台 fixture 用 logical placeholder，不把 `/` 或 `\`
  纳入业务 digest。
- Runtime JSON 中的 device identity、operation reference、Artifact ID 等仍使用平台无关格式。
- machine 模式时间固定为 RFC 3339 UTC，digest 为 lowercase hex，整数范围按 schema 固定。
- PowerShell/cmd.exe 示例只负责正确产生同一 argv；不能拥有不同命令语义。

## 12. 版本、兼容与弃用

CLI 同时存在四个独立版本：

1. CLI product version；
2. command registry schema；
3. local control protocol；
4. result/event schema。

升级一个版本不能暗中改变另一个。破坏 command/option、machine field、exit code 或状态语义时，
必须提高相应 major，并提供 migration/tombstone。

当前命令迁移目标：

| 当前表面 | 目标表面 | 兼容策略 |
|---|---|---|
| `agentd ...` | `runtime service ...` | 当前 major 保留 alias，human 模式警告；下一 major tombstone |
| `agentd install/update --hdc/--daemon <path>` | `runtime tool register` + typed tool/bundle refs | compatibility reader 先做同等 hash/trust 校验；新 service contract 不消费 caller path |
| `signing ...` | `runtime signing ...` | 同上 |
| `update-feed ...` | `maintainer update-feed ...` | 同上；仍是 platform/maintainer extension |
| `device list` | `target list` | 保留现有 target-list 语义的 deprecated alias，绝不静默改成 candidate list |
| `device show` | `target show --target` | 旧命令因没有 identity 而 deprecated；不得继续伪装 show |
| `device adopt` | `target adopt` | 保留 alias |
| `cleanup-debt ...` | `recovery cleanup ...` | 保留 alias |
| `debug start/evaluate/status` | `recovery flash-invocation ...` | 保留具名 alias/tombstone，把 `debug` 还给正常 Debug 产品 |
| `artifact import-hap/import-workspace-patch/import-flash-bundle/import-native-library` | `artifact import <kind>` | 当前 major 保留 alias；内部 chunk 方法仍不公开 |
| `flash install-binding` | 无直接重解释 | 保留 macOS compatibility leaf，待 current Loader binding 路径闭合后 tombstone |
| `flash status/reconcile` | `legacy flash status/reconcile` | decode/export-only；不迁到新 executor |
| operation ref `flash.dayu200` | 新 convenience command 只生成 `flash.full-restore@1` | generic caller 的显式 alias request 原样交 Runtime；CLI 不改字段，历史记录保持原 ref |
| `flash execute/continue/postflight` | 无 | 永久 tombstone，提示 `agent run --operation flash.full-restore@1` |
| `agent chat` | 无 | 永久 tombstone |
| `--socket` | `--endpoint` | macOS compatibility alias；Windows help 不推荐 |
| `--json` | `--output json` | 必须在 CLI major 迁移期明确 legacy-result 与 envelope 模式，不能静默改 shape |

`--json` 当前存在错误非 JSON、wait 多文档等缺陷。实现 target envelope 时必须选择显式迁移：

- 当前 major 增加 `--output json/jsonl` 作为新契约；
- `--json` 暂时映射 `legacy-json`，但修复编码失败 fallback 和多文档问题；
- 下一 major 才允许 `--json` 成为 `--output json` 的纯别名。

deprecated warning 只写 human stderr；machine stdout shape 不得被 warning 污染。

## 13. 当前实现差距

### 13.1 已有骨架

当前 CLI 已有 14 个一级命令、约 48 个可执行 leaf。以下底座可以保留并演进：

- `operation list/describe`；
- `job plan/submit/run/list/status/cancel/reconcile`；
- `agent run/resume`；
- target adoption、trace probe；
- HAP/workspace patch/Flash bundle/native library import；
- Artifact list/inspect/read/export；
- capability read-only inspection；
- cleanup debt continuation；
- macOS runtime service、signing 与 maintainer feed 工具。

所有当前 Catalog descriptor 已经可以经 generic Job/Agent surface 理论触达。因此重设计的重点是
补齐产品资源面、消除语义混名，并把隐式行为变成机器契约，而不是重写 Runtime executor。

### 13.2 daemon-ready、CLI 缺失

以下正式 daemon 方法应作为首批 vertical slice 的实现输入；多数只需补 CLI，但目标 projection
仍必须逐项核对，不能把“方法存在”等同于“目标 contract 已完成”：

| daemon method | 目标 CLI |
|---|---|
| `health` | `runtime health` |
| `runtime.hdc-status` | `runtime hdc status` |
| `device.candidates` | `device candidates` |
| `artifact.quota` | `artifact quota` |
| `job.evidence` | `job evidence` / `job result` |
| `debug.probe` | `debug probe` |
| `debug.template.run` | `debug template run` |
| `flash.lanePlanPreview` | `flash lane-preview` |
| `flash.prerequisites` | `flash prerequisites` |
| `flash.device-access` | `flash device-access` |
| `flash.bootloader-status` | `flash bootloader-status` |
| `flash.bind-current-loader` | `flash bind-loader` |

其中 `device.candidates` 当前已有 observed time/health 等事实，但没有本规格要求的 durable snapshot
generation；第一版可以先忠实暴露现有字段，达到 target contract 前必须扩正式 response schema。
`target show` 所需的单 target/profile/last-facts projection 也不是当前 `target.list` 的简单别名。

同时修复：

- `device list/show` 当前都调用 `target.list`；
- `operation describe` 当前没有完整投影 effect/authorization、step/recovery、Artifact/privacy 等
  Agent decision fields；
- `artifact read` 未暴露 daemon 已有的 offset/maxBytes；
- `job list` 未暴露 order/includeTimeline/includeCurrent，且 page shape 随 flags 改变；
- `job submit` flag form 默认随机 idempotency，无法安全重试；
- `job submit --wait --json` 输出多个 pretty JSON documents；
- 未知、重复和不适用 option 在多条路径被静默忽略；
- 没有 `--help`、`--version`、completion、process-level golden 或完整 exit registry；
- 当前 `debug` 实际是 protected destructive Flash recovery，名字与产品 Debug 冲突。

### 13.3 Catalog 泛化可达、缺一等领域入口

- screenshot/UI dump/HiLog/trace capture；
- screen sequence、tap/long-press/swipe；
- HAP debug、native library deploy、port forward；
- 四个 analyzer；
- 全部 workspace inspect/edit/build/test/sign/symbolize operation；
- Flash current Runtime execution。

这些不是执行缺口。一等领域命令只需 registry mapping、typed preset、统一 renderer 与测试；它们
不得复制 provider lowering。

### 13.4 需要新的 typed 产品面

以下能力当前主要在 App facade、package-internal 或平台服务中，不能由 CLI 直接读写私有状态：

- durable HAR list/show；
- Session pin、export preview/apply、retention preview/apply；
- durable `job.events/watch` cursor/revision surface；
- storage policy/root 与 support-bundle preview/export；
- HDC manual lifecycle 的 generation-bound impact preview/restart；
- target-dependent operation availability 与 `target capabilities` 聚合 projection；
- registered remote source resource；
- consumer auto-update lifecycle；
- UI dump parser/hit-test、Trace/diagnostics offline inspection 的稳定跨平台 schema。

实现它们时先建立 bounded Runtime/local service contract，再接 App 与 CLI。同一 vertical task 内
提交代码、contract、tests 和必要文档。若引入新 operation、provider、integration/device profile
或 destructive admission 变化，仍须按仓库规则提交对应 OpenSpec change；本规格不能代替审批。

### 13.5 纯展示，不是 CLI 阻塞项

- Timeline/native tree/window chrome；
- Finder/Explorer reveal；
- App 的本地视频播放与视图状态；
- Overview 卡片排列和 workspace navigation。

CLI 能按 schema inspect/export 源数据与派生数据，并明确 parser/version/digest，即满足功能等价。

## 14. 机器可读规格产物

实际实现时应在同一 P4/GJ 垂直产品任务中增加并生成以下产物；不要先做一轮只有文件没有产品
入口的 governance PR：

```text
openspec/contracts/cli-command-registry.yaml
openspec/contracts/cli-result.schema.json
openspec/contracts/cli-event.schema.json
openspec/contracts/cli-error-registry.yaml
openspec/contracts/runtime-control-plane.schema.json
Packages/ArkDeckKit/Tests/Fixtures/CLI/**
```

建议另生成 `cli-feature-coverage.json`，为每个能力记录：

```json
{
  "feature": "job.evidence",
  "source": "daemon:job.evidence",
  "classification": "direct",
  "command": "job evidence",
  "platforms": ["macos", "windows"],
  "conformanceFixture": "job-evidence-success"
}
```

覆盖检查必须保证：

- 每个 daemon method 被分类为 public CLI、internal protocol 或 App-only defect；
- 每个 canonical Catalog operation 可经 generic surface 发现、plan、submit、run 和读取 result；
- 每个 App 用户能力有 direct/generic/presentation/blocked 分类；
- capability admin、raw command、legacy executor 等 forbidden surface 不出现在 registry；
- generated help、completion、docs、Swift parser 和未来 Windows parser 对同一 registry 零漂移。

## 15. Conformance 与验收

### 15.1 共享 fixture

每个 portable leaf 至少覆盖：

1. valid argv → normalized typed request；
2. missing/unknown/duplicate/conflicting option → exit 64；
3. invalid JSON/schema/file → exit 65 且 dispatch 0；
4. success JSON envelope schema；
5. structured daemon error → error envelope + stable exit；
6. human output 不参与跨平台 byte equivalence；平台 path/service/tool diagnostics 可以不同，但
   safety state、reason 与下一动作语义必须一致；
7. JSONL sequence/terminal event；
8. timeout、Ctrl-C 和 daemon disconnect；
9. sensitive/redacted/secret negative cases；
10. macOS/Windows normalized request/result equivalence。

fixture 输入是 argv array、stdin bytes、logical files、daemon response frames 与预期 stdout/stderr/
exit；不得以 shell script 的 quoting 作为共享事实源。

### 15.2 契约测试

- command registry → parser/help/completion/docs 全生成且零漂移；
- CLI public command → daemon method allowlist parity；
- Catalog descriptor → operation describe/validate/example parity；
- 所有 Job state 与 daemon error code 的 exit mapping 穷举；
- `--output json` 恰好一个 document，错误也能过 schema；
- `jsonl` 每行独立可解析并有唯一 terminal；
- artifact range/raw/export 的 byte、digest、EOF、privacy 与 overwrite；
- target/candidate/binding revision/facts drift negative matrix；
- idempotency same-key/same-request、same-key/different-request、lost-response retry；
- HAR resume token expiry/selection/facts drift；
- legacy Flash alias 保留原 request/reference，CLI 不做隐式 destructive field transform；
- HDC impact preview ID/digest/generation/expiry/confirmation 与 dispatch 前 drift matrix；
- Session export preview/apply 的 generation、privacy/default exclusion 与 destination drift；
- forbidden operation/job raw executable/argv/HDC/shell/remote path、capability admin、network endpoint；
- host tool registration 的 kind/size/file-identity/hash/trust/reference negative matrix；
- UDS 与 named pipe transport 运行同一 handler fixture；
- Windows/macOS file identity、console secret、service lifecycle adapter vectors。

### 15.3 Golden Journey 验收

只有当前 Catalog digest 的真实设备结果可以记 `REAL_DEVICE_PASS`：

- GJ-1：`doctor` → `device candidates` → `target adopt` →
  `agent run --operation observe.device@1`
  → `job result`；
- GJ-2：import HAP → `agent run --operation debug.hap@1` → liveness/evidence/Artifact；
- GJ-3：typed workspace inspect/patch/build/test/sign → deploy/debug → diagnostics/analysis；
- GJ-4：Flash bundle import → prerequisites/plan →
  `agent run --operation flash.full-restore@1`
  → postflight evidence；
- GJ-5：外部 Agent 只用 operation/device/target/job/agent/artifact/HAR 完成闭环，不打开 App。

机器契约测试不替代真机；真机不替代 contract/negative test。

## 16. 分阶段落地

### Slice A：P4 机器契约与 GJ-1 闭环

- declarative command registry、strict parser、help/version/completion；
- `--output json/jsonl`、error envelope、exit registry；
- `runtime health`、HDC status、device candidates、真正的 target show；
- job evidence/result、Artifact quota/range read；
- stable request identity/idempotency；
- process-level golden 与 GJ-1 真机验收。

### Slice B：现有 daemon 与 Catalog 的领域全覆盖

- Flash prerequisites/access/bootloader/lane/bind；
- Debug probe/template 与 normal Debug namespace；
- screen/input/diagnostics/UI dump/trace/analyze/port-forward/workspace convenience mapping；
- job wait、durable events/watch contract、fixed pagination、Artifact raw/export；
- GJ-2～GJ-5 对应真机验收。

### Slice C：App-only 能力资源化

- HAR、Session retention、storage/support bundle；
- target capability projection；
- offline parser/schema；
- source/update 等平台服务；
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

所有设备动作必须经已发布 operation、typed request、Runtime admission、Job/WAL 与 Provider；CLI
不得拥有 raw executor。

**Acceptance：** 对任意领域 leaf，测试能追踪到一个 Catalog operation 或正式 Runtime method；
raw shell/HDC/argv/device path 输入均在 dispatch 前拒绝。

### CLI-REQ-002：全能力可分类

每个 daemon method、Catalog operation 与用户可见 App 能力必须在 coverage manifest 中被分类，且
不存在 `unclassified`。

**Acceptance：** CI 对新增 method/operation/App capability 产生未分类差异时 fail closed。

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

JSON success/error 与 JSONL event 必须符合 versioned schema，并遵守 stdout/stderr 边界。

**Acceptance：** 每个 leaf 的成功和失败进程测试均通过 schema；`json` 恰好一个 document，
`jsonl` 恰好一个 terminal event，编码失败不会 fallback 到 human。

### CLI-REQ-007：稳定错误与退出码

相同语义在所有平台必须返回相同 machine reason category 和 exit code；unknown outcome 永不为 0。

**Acceptance：** Job state/error registry 穷举测试无 default branch；新增状态没有映射时编译或 CI
失败。

### CLI-REQ-008：可重试身份

CLI 必须允许自动化固定 request identity 与 idempotency key，并支持 lost-response 后安全查询同一
Job。

**Acceptance：** 同 key/same canonical request 返回同一 Job；同 key/different request conflict；
网络断开后重试不产生第二次 dispatch。

### CLI-REQ-009：显式 target/binding

device-bound operation 必须绑定 exact durable target 与 fresh binding revision；不得选择默认设备。

**Acceptance：** zero/one/multiple/unauthorized/facts-drift candidate matrix 都有确定结果；歧义进入
HAR 或拒绝，dispatch 为 0。

### CLI-REQ-010：完整 Job result

CLI 必须提供 status、wait/watch、result、evidence、Artifact inventory、cancel 与 reconcile 的闭环。

**Acceptance：** 外部 Agent 不解析 App 状态、不访问 store 文件，仅凭 CLI 即可区分 success、
failed、cancelled、HAR、unknown、cleanup debt 和 evidence failure。

### CLI-REQ-011：Artifact 安全

Artifact read/export 必须 bounded、digest-addressed、privacy-aware，且 raw stdout 与 machine metadata
严格互斥。

**Acceptance：** 大 Artifact 可通过 range 完整重组并核对 digest；sensitive 未显式许可、越界、
替换文件、覆盖 destination 全部 fail closed。

### CLI-REQ-012：HAR 与 recovery 不扩权

resume、reconcile 和 cleanup 只能在 Runtime 记录的同一 execution/Job/owner boundary 内继续，不能
生成 authority 或 replay unknown destructive intent。

**Acceptance：** expired token、facts drift、capability mismatch、unknown destructive outcome 和
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
污染；removed dangerous leaf 永远不能 dispatch。

### CLI-REQ-016：真实设备结论

CLI 的“全功能”完成结论必须以当前 Catalog digest 上的 GJ 真机证据为准。

**Acceptance：** fixture/simulation/plan-only 标记不会被验收工具接受为 `REAL_DEVICE_PASS`；每个
需要设备的 slice 都记录 exact target、binding、Catalog digest、Job、evidence 与 Artifact identity。

### CLI-REQ-017：bounded host registration

host tool、daemon bundle 和 credential material 只能通过 kind/schema/size/file-identity/hash/trust
校验的 registration/import 进入系统；operation/job/service execution 只消费 typed reference。

**Acceptance：** caller path 在 registration 后被替换不会改变已注册 identity；Job request 中的
executable/argv/path 被拒绝；macOS/Windows 对同一注册内容得到相同 content identity 与 trust reason。

### CLI-REQ-018：host lifecycle 两阶段执行

Runtime/HDC lifecycle mutation 必须先生成 generation-bound impact preview，再以 exact preview
ID/digest 与所需用户确认执行；dispatch 前重验证 owner、generation、critical Job 与 expiry。

**Acceptance：** preview mismatch、owner/facts drift、owner/generation 无法精确投影、active/unclosed
Job、expiry，或自动路径/缺少 exact 用户确认时 lifecycle dispatch 为 0；成功和拒绝都产生
host-wide audit record。经 exact 用户确认的 external/unknown manual restart 保持原 ownership，且
不能被复用为下一次 lifecycle authority。

### CLI-REQ-019：durable watch

`job watch` 必须建立在有 stable event identity、revision/cursor 与 reconnect contract 的 Runtime
surface 上；client-side polling 不能冒充 lossless stream。

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

## 18. 设计完成定义

当且仅当以下条件全部成立，才可以把 CLI 称为“全功能”：

- Slice A/B 已实现，Slice C 中所有非纯展示且属于既有产品的能力已经资源化，coverage manifest
  没有 daemon-ready、Catalog-generic 或 typed-product-surface 缺口；
- GJ-1～GJ-5 都能从 CLI headless 完成，且当前 digest 的适用真机证据成立；
- JSON/error/exit/help/completion/argv conformance 全通过；
- App-only 能力均已资源化或明确证明为 presentation-only，不存在隐式私有绕行；任何仍为
  `BLOCKED_BY_PRODUCT_DEFECT` 的既有产品能力都会阻止“全功能”结论；
- capability admin、raw command、legacy executor 和 remote control plane 仍然不可达；
- Windows 复刻可以只阅读 language-neutral registry/schema/fixtures 和 platform port 文档，而不
  需要反向推断 Swift CLI 的手写 parser、App facade 或 macOS API。

在此之前，准确表述是“Runtime operation coverage 完整，CLI 产品面尚未完全闭合”，不能只因为
`agent run` 能泛化调用 Catalog 就声称 CLI 已全功能。

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
  Target/Job/Artifact/HAR/recovery 语义；
- [`debug-workbench`](../../openspec/specs/debug-workbench/spec.md)、
  [`toolchain-hdc-server`](../../openspec/specs/toolchain-hdc-server/spec.md)、
  [`flashing`](../../openspec/specs/flashing/spec.md)、
  [`trace`](../../openspec/specs/trace/spec.md)、
  [`ui-dump`](../../openspec/specs/ui-dump/spec.md)：领域边界。
