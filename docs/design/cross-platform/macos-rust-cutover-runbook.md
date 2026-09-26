# macOS Rust Runtime 切换窗口 runbook（G5 第 20c 刀）

> 状态：草案（2026-09-26 起草，未在真实主机上执行过）。Task：TASK-XPA-017（CHG-2026-074 M5）。
> 本文只写步骤，不代表任何一步已经执行、已被批准或已通过。源码位置以 `main` `5d42490da`（#2257，已含 #2255 = `8acfe6900`）
> 为准；
> 行号可能随后续合入移动，窗口前按附录 A 复核一遍。

维护者在一个切换窗口里照本文逐步执行：把安装态的 Swift Runtime（Swift daemon + Rust façade 对）换成
standalone Rust daemon，然后做正式验收。本文不另立验收规则，真机验收照
[验收指南](../../../scripts/agent-guides/acceptance.md) 与
[headless GJ runbook](../cli-golden-journey-headless-runbook.md) 执行；安全边界照 `AGENTS.md`
「Agent 禁令与设备执行边界」与 Constitution（`POL-AGENT-002`、`POL-RECOVERY-001`）。
两者与本文冲突时以它们为准，并把冲突写进窗口记录。

凡源码里找不到依据的命令或参数，本文一律写成「TBD（维护者定）」并说明缺什么，不作为确定命令。

## 0. 约定

### 0.1 执行者

| 标记 | 谁 | 允许做什么 |
|---|---|---|
| 【维护者】 | 维护者本人 | 一切改动安装态的动作：`runtime service update`（内部会 `launchctl bootout/bootstrap`）、手工 `launchctl`、Developer ID 签名与公证、GJ-4 的 go、所有「窗口前必须裁决」的事项 |
| 【协调会话】 | Claude 协调会话 | 只读核实（git、源码、已提交记录）、比对输出、整理窗口记录；不改安装态、不跑 launchctl、不做设备 mutation |
| 【Agent】 | 被派的子代理 | 同协调会话；另可在窗口后按记录起草 evidence 文件的 PR |

Agent 与协调会话在窗口内**不执行**任何 `runtime service update|install|uninstall|restart`、`launchctl`，
不执行设备 `agent run`（除非维护者当场授权，见第 5 步），也不改 trusted facts、capability、reservation、evidence
记录（`AGENTS.md`「Agent 禁令与设备执行边界」）。本文里凡是这些命令，执行者一律是【维护者】。

### 0.2 变量

下文命令用这些变量，窗口开始时由【维护者】在自己的 shell 里设好：

```sh
RUST_OUT=<20a 产出的发布目录（绝对路径）>        # build-helpers.sh 的 ARKDECK_HELPER_OUTPUT
ARKDECK="$RUST_OUT/ArkDeckCLI.app/Contents/MacOS/arkdeck"            # Rust CLI
HELPER="$RUST_OUT/ArkDeckCLI.app/Contents/Helpers/ArkDeckAgent.app"  # Rust daemon bundle
ROLLBACK="$RUST_OUT/rollback/ArkDeckAgent.app"                        # 保留一个周期的 Swift helper（Swift daemon + façade）
OLD_ARKDECK=<当前安装态配套的 Swift CLI>          # 例如 Toolchains/arkdeck-helpers-main-<sha>/ArkDeckCLI.app/Contents/MacOS/arkdeck
HDC=<当前已验证 HDC 的绝对路径>                    # 从切换前的 runtime hdc status 的 executablePath 读
OUT=/private/tmp/arkdeck-cutover-<YYYYMMDD>        # 原始输出目录，不入仓
SUPPORT="$HOME/Library/Application Support/ArkDeck"
```

发布目录布局（`$RUST_OUT/ArkDeckCLI.app/Contents/MacOS/arkdeck`、`…/Contents/Helpers/ArkDeckAgent.app`、
`$RUST_OUT/rollback/ArkDeckAgent.app`）见 `Packages/ArkDeckKit/Distribution/macOS/build-helpers.sh:88-121` 与
`package-rust-helpers.sh:118-136`。

### 0.3 输出与停止

- 每条命令的 stdout 原样存 `$OUT/<NN>-<step>.json`，stderr 存同名 `.err`，退出码写进窗口记录。
  这是输出目录，不是新的 Runtime state 目录。
- 「失败即停」：该步的停止判据命中时，不进入下一步，按该步「失败时」与 §4 处理，并在窗口记录里写明。
- 任何 `outcomeUnknown` / `reconcileRequired` / 真实设备不确定状态：只读回（`job show/evidence`、
  `job reconcile --job <id>` 的独立读回），**不重放、不为了消掉它而回滚或换 state 目录**（design §G.4、
  `AGENTS.md`）。

## 1. 目的与范围

一次切换窗口做这些事，顺序照 G5 队列第 20c 刀：

1. §G.4 切换预检（两遍）并记录快照摘要；
2. LaunchAgent 改指向 standalone Rust daemon（`main.rs` 第三种模式，production 组合），被替换的
   Swift helper（Swift daemon + façade）保留一个周期作回滚；
3. `runtime service verify`；
4. 签名 App ↔ Rust Mach service 的正向与负向验收（SPK-8）；
5. 用 Rust CLI 跑完整 headless runbook，拿 GJ-1…GJ-5 的 `REAL_DEVICE_PASS`（GJ-4 要维护者 go）；
6. App 呈现检查（headless runbook §6b）；
7. 回滚演练（XPA-AC-9）。

不在本窗口内做：

- 删除 Swift target、Swift CLI、ArkForge Swift SDK、CI 车道同步、结构测试、traceability 与 lock 翻转
  （第 20d 刀，TASK-XPA-017 收尾）；
- Developer ID 签名与公证本身（第 20a 刀的发布动作，由维护者在窗口前完成，见 §2 P3）；
- Rust 性能基线的测量（第 20b 刀，安静主机）；
- ArkForge 摘要域（F1/F2）的修复、Swift 缺陷的过渡版本发布（只在 §2 核对其裁决）；
- 任何 capability、trusted facts、reservation、hardware evidence 的手工创建或修改；
- Windows。

## 2. 前置条件清单

每条都要在窗口开始前核实并把结果写进窗口记录。标「窗口前必须由维护者裁决」的，本文不替维护者下结论；
未裁决即不开窗口（或只开不依赖它的部分，并在记录里写明）。

| # | 条件 | 如何核实 | 状态 |
|---|---|---|---|
| P1 | 切换所需 PR 已合入 protected `main`：production 组合 #2136/#2137、`runtime service status/verify --job/restart` #2141、§G.4 预检 #2142、`update/install/uninstall` 与无 `--job` 的 `verify` #2143、Rust `--analyze-crash-ledger` #2144、Bootstrap 注册表 #2216/#2217、Rust helper 打包 #2218、entitlements 口径 #2219、App 脱离 `ArkDeckWorkflows` #2139；GJ-4 用到的 M4 Flash 链（含 `flash install-binding` #2245、执行授权 #2252 等） | 【协调会话】`git fetch origin main && git log --oneline origin/main \| grep -E '\(#(2136\|2137\|2139\|2141\|2142\|2143\|2144\|2216\|2217\|2218\|2219\|2245\|2252\|2255)\)'`，逐条命中；M4 其余 PR 以 `evidence/macos-remaining.md` 仪表盘 M4 行为准 | 起草时列出的 14 个 PR 均已在 `main`（#2136 `51f8009df`、#2137 `86ea4d839`、#2139 `1267e465d`、#2141 `5b1df34ee`、#2142 `d41cc1fb1`、#2143 `527459240`、#2144 `ae404cc5c`、#2216 `c3c120513`、#2217 `3315a9cba`、#2218 `1dbe5acd0`、#2219 `167783bb1`、#2245 `61d95b10d`、#2252 `f9d6cac06`、#2255 `8acfe6900`）；窗口前按此重核，并补上之后合入的 M4/CLI 车道 PR |
| P2 | #2255（S36：预检的 `loaderTransitionAwaitingBinding` 与 `retainedSessions` 两条拒绝）已合入 | 同上 grep `(#2255)` | 起草期间已合入（`8acfe6900`）。仍要知道的残余：该拒绝只拦 Swift 的 `bind-current-loader` 能结算的那一类（判据见其 run 记录 :79-86，协调会话已接受这一收窄）；判据之外、停在 Loader 过渡上的 parked Flash Job 照旧原样带进 Rust。Rust daemon 启动时对这类过渡只打印一行「Loader transition … awaits settlement … its outcome stays unknown」并继续，但**同一 target 上有两个及以上时启动失败**（`rust/crates/arkdeck-agentd/src/main.rs:716-724`，`rust/crates/arkdeck-hoststore/src/rockchip_startup.rs:87-94`），launchd `KeepAlive` 会让它崩溃循环。窗口前由【协调会话】从第 1 步 1a 的 `carriedOver.parkedJobIds` 逐个 `job show` 只读核对有没有这种情况，有则交维护者裁决 |
| P3 | 20a 产物：用 `ARKDECK_HELPER_RUNTIME=rust` 从**窗口所用 `main` 提交**构建、Developer ID 签名（公证按 Q11）的 `$RUST_OUT`，含 `rollback/ArkDeckAgent.app`（当前发布的 Swift helper，Swift daemon + façade） | 【维护者】构建命令与只读验收命令照 `evidence/runs/TASK-XPA-017/rust-helper-packaging-run.md` §5：`codesign --verify --strict --deep`、`codesign -dv`（Identifier `com.arkdeck.agentd`、Team `8AQTYW5FKR`、hardened runtime、有 Timestamp）、`-R` 要求、`codesign -d --entitlements`（恰为 `ArkDeckAgent.entitlements` 三键，#2219）、`stapler validate` 与 `spctl`（仅在要求公证时）、以及临时 home + 记录型 launchctl 下的 `runtime service update` 自检。注意 `check-rust-helpers.py` **只检查无签名的结构产物**（要求 ad hoc 签名与 `UNSIGNED-STRUCTURE-CHECK-ONLY.txt`），对签名发布包必然失败，不能当发布验收 | 维护者执行；Q11（要不要公证）**窗口前必须由维护者裁决** |
| P4 | 20b：Rust 性能基线 `perf-baseline-<date>-rust.json` 已在安静主机上采集并提交，两级 RSS 分开记，预算不提 | 【协调会话】`ls scripts/bench/baselines/` 有该文件且已在 `main` | 起草时只有 `perf-baseline-2026-09-04.json`（Swift）。是否以「基线已提交」为开窗条件，**窗口前必须由维护者裁决** |
| P5 | 4h soak 绿 | 托管 4 小时 Rust soak run `36130214960`（#2185 之后），记录 `evidence/runs/TASK-XPA-025/snapshot-pager-bounded-run.md`；仪表盘 `evidence/macos-remaining.md` 的 Performance 行 | 已绿，但跑在较早的 `main` 上；是否要求在窗口所用提交上重跑，**窗口前必须由维护者裁决** |
| P6 | 签名 S-1 裁决与安装态签名预设 | 【维护者】只读检查 `test -e "$SUPPORT/Signing/OpenHarmony/preset-v1.json" && echo present`；`"$ARKDECK" runtime signing status --output json`。存在预设时 Rust CLI 的 `runtime service update` 在任何改动之前 exit 69 拒绝（`rust/crates/arkdeck-cli/src/runtime_service_install.rs:442-455`，文案含「the Rust CLI has no signing-credential owner yet (Q8); nothing was changed」） | S-1/S-2（签名写路径是否在 provider-workspace 新增写侧 API）**窗口前必须由维护者裁决**。S-1 落地前：(a) 装有签名预设的主机切不过去；(b) 该拒绝对 Rust CLI 的**每一次** `update` 都生效（调用点 `runtime_service_install.rs:427`，在判别 daemon 种类之前），包括 GJ-4 的 campaign staging（Rust→Rust）与第 7 步的回滚（Rust→Swift）；(c) Rust CLI 已服务 `runtime signing status|remove` 及旧 `signing` 拼法（见 `evidence/runs/TASK-XPA-018/signing-remove-run.md`），安装与迁移签名预设的叶子仍未移植，GJ-5 在 Rust CLI 上建不了预设。所以 S-1 实际上是完整窗口（含 GJ-5 与回滚演练）的前提；「先删预设再切」只能让切换本身通过，是否可接受由维护者定 |
| P7 | F1/F2（ArkForge 摘要域）裁决与随包 `arkforged` 版本一致 | ArkDeck Swift 与 Rust 仍用 `"arkforge/v1/device-facts\0"`（Rust `rust/crates/arkdeck-provider-arkforge/src/loader.rs:23`、`:203`）；ArkForge 自 `e437402` 起拆成 `usb-topology` 与 `admission-device-facts` 两个域；源码 pin 是 `eee578720c5b…`（`rust/Cargo.toml:23-29`、`Packages/ArkDeckKit/Package.swift:46-48`），已含拆分。**仓内没有 `arkforged` 二进制或版本的 pin**：daemon 用的是 `--arkforge-bundle` 指向的 `ArkForge.bundle`（`Contents/MacOS/arkforged`，manifest `version` 非空，`rust/crates/arkdeck-contract/src/arkforge_bundle.rs:295-296`、`:337`）。【维护者】核对当前 plist 里 `ARKDECK_ARKFORGE_BUNDLE_PATH` 所指 bundle 的 `arkforged` 由哪个 ArkForge 提交编出（枢纽 09-26 记：用户手上已验证 bundle 由 `3f5b48cd`（08-21）编出，仍是 device-facts 域，与 ArkDeck 一致） | F1/F2 修法与「修复须与 bundle 同步发布」**窗口前必须由维护者裁决**。在裁决前，切换时**不得更换** ArkForge bundle（沿用 live plist 的 bundle）；换成 `eee5787` 及以后编出的 `arkforged` 会让 Flash 选择与准入一律 fail closed，GJ-4 失败 |
| P8 | 过渡版本：是否先发一个带 #2204（workspace 墓碑，先删 preset 再删 project 后 daemon 起不来）、#2221（xcrun tool-shim 钉错工具）、#2227（macOS 27 上 update-feed 写入 EPERM）等已发布 Swift 缺陷修复的 Swift 版本 | 【协调会话】三者均已在 `main`（`9bd452b55`、`a9d840f0d`、`33c161b19`）；【维护者】核对 `$ROLLBACK` 的 Swift helper 是哪个提交构建的 | **窗口前必须由维护者裁决**。影响回滚：若 `$ROLLBACK` 不含 #2204，而 state 里已有「preset 已删、所指 project 也已删」的墓碑，回滚到它的 Swift daemon 会起不来（见 §3 第 7 步「不可逆与特别注意」） |
| P9 | 新 App：脱离 `ArkDeckWorkflows` 的签名 App 构建已安装，版本与 helper 同一 release | 【维护者】App 的 `MARKETING_VERSION`/`CURRENT_PROJECT_VERSION` 与 helper Info.plist 一致（`check-rust-helpers.py:157-162` 对结构产物比的就是这对值）；App 与 daemon 同 release 才配对 | 由谁安装、是否嵌入 App / 发 DMG 属产品决策，**窗口前必须由维护者裁决**（`rust-helper-packaging-run.md` §6 第 3 条） |
| P10 | Q6：只有 M5 切换之后、安装态纯 Rust daemon 上、用 Rust CLI 跑完整 runbook 的结果才算 `REAL_DEVICE_PASS` | 【协调会话】查维护者裁决记录 | G5 队列建议 A；未见裁决记录则**窗口前必须由维护者裁决** |
| P11 | Q3：SPK-8 正向验收在什么环境做 | 同上 | 本 runbook 按「M5 切换之后在本机做」写（队列选项 C）；未裁决则**窗口前必须由维护者裁决** |
| P12 | 备份 | 见下方「备份建议」 | 维护者执行 |
| P13 | 窗口条件：本机无其他 UI 跑道、无重构建（`cargo`、`xcodebuild`、`plan.py`）；DAYU200 已连且处于 hdc-normal；GJ 输入物料就位（headless runbook §1）；无阻断态 Job | 【维护者】`pgrep -fl 'xcodebuild\|cargo\|plan.py'` 为空；headless runbook §1 的前置命令；§3 第 1 步的预检 | — |

**备份建议（P12，由维护者决定采用哪种）**

切换命令本身只写快照**摘要**（每个文件的大小与 SHA-256、根摘要），不复制数据
（`evidence/runs/TASK-XPA-018/runtime-service-cutover-preflight-run.md`「Snapshot」一节），所以摘要不是备份。
design §G.4 也写明：快照恢复不能当作真实设备副作用的常规恢复路径。备份只用来防主机侧误删与损坏。

- 做法 A（推荐，无额外停机）：窗口前一刻在 APFS 上打一个 Time Machine 本地快照：
  `tmutil localsnapshot`，再用 `tmutil listlocalsnapshots /` 读回快照名写进记录。这是时间点一致的卷快照，
  不需要先停 daemon。快照会被系统按空间回收，窗口后若要长期保留，另做一次 Time Machine 备份。
- 做法 B（要一份独立拷贝时）：【维护者】`launchctl bootout gui/$(id -u)/com.arkdeck.agentd` →
  `ditto "$SUPPORT" <外部卷>/ArkDeck-<date>` → `launchctl bootstrap gui/$(id -u) ~/Library/LaunchAgents/com.arkdeck.agentd.plist`
  （标签、域与参数数组同 `rust/crates/arkdeck-platform/src/launchd.rs:25`、`:30`、`:45`、`:50`）。bootout 前先确认
  无阻断态 Job（第 1 步的预检）；bootout 后约 4 s 才释放 HDC 端口与 USB 接口。拷贝含签名凭据相关文件时，
  存放位置按维护者的敏感数据规则处理。
- 不做：在 daemon 运行时直接 `cp -R` state 目录（不一致拷贝）；把备份恢复当作撤销设备副作用的手段。

## 3. 步骤

### 第 0 步：开场读数（约 10 分钟）

- 执行者：【维护者】执行命令，【协调会话】比对与记录。
- 命令（旧 Swift Runtime 仍在运行；全部只读）：

  ```sh
  mkdir -p "$OUT"
  "$ARKDECK" runtime service status --output json   > "$OUT/00-status-before.json"
  "$OLD_ARKDECK" doctor --deep --output json        > "$OUT/00-doctor-before.json"
  "$OLD_ARKDECK" runtime hdc status --output json   > "$OUT/00-hdc-before.json"
  "$OLD_ARKDECK" operation list --output json       > "$OUT/00-operations-before.json"
  "$OLD_ARKDECK" job list --page-size 1000 --output json > "$OUT/00-jobs-before.json"   # 有后续 cursor 时读完所有页
  plutil -p ~/Library/LaunchAgents/com.arkdeck.agentd.plist > "$OUT/00-plist-before.txt"
  ```

- 预期：`status` 的 `launchAgent.ready: true`、`diagnostics: []`、`daemonHealth` 是 daemon 的 `health` 回答
  （`status` 没就绪也 exit 0，只能看字段，见第 3 步）；plist 的 `ProgramArguments` 指向
  `Helpers/ArkDeckAgent.app/Contents/MacOS/arkdeck-facade`（façade 对），环境里有 `ARKDECK_SWIFT_SHA256`；
  `HDC` 变量取 `runtime hdc status` 的 `executablePath`；记下 `launchAgent.arkTraceDescriptor` 与 `arkForgeLane`
  的现值（第 2 步要用）。
- 停止判据：`status` 不健康、`doctor` 有与本窗口相关的具名 finding、Job 台账读不全。
- 失败时：不开窗口，按 finding 处理后重来。

### 第 1 步：切换预检（两遍）与快照摘要（约 10 分钟）

**1a 手工预检（无锁、只读，旧 Runtime 在跑时执行）**

- 执行者：【维护者】（在真实账户上运行新 daemon 的一次性只读模式）；【协调会话】解读输出。
- 命令（`--cutover-preflight` 模式与环境要求见
  `evidence/runs/TASK-XPA-018/runtime-service-cutover-preflight-run.md:35-48`；只允许 production 组合，
  带开发根、`ARKDECK_ENDPOINT`、façade 配对、`ARKDECK_HDC_SHA256`、`ARKDECK_APP_INGRESS` 任一项即 exit 69）：

  ```sh
  env -i HOME="$HOME" ARKDECK_RUNTIME_COMPOSITION=production \
    "$HELPER/Contents/MacOS/arkdeck-agentd" --cutover-preflight \
    > "$OUT/01a-preflight-1.json" 2> "$OUT/01a-preflight-1.err"; echo "exit=$?"
  ```

  环境与 update 自己的探测一致：清空环境，只给 `HOME` 与 `ARKDECK_RUNTIME_COMPOSITION=production`
  （`rust/crates/arkdeck-cli/src/runtime_service_install.rs:756-768`）；被拒的组合输入清单见
  `rust/crates/arkdeck-agentd/src/production.rs:78-116`，模式的退出码见 `cutover_preflight.rs:53-56`、`:73-123`。
  CLI 没有单独的预检叶子；手工跑这一遍依据的是该模式「两遍都不写 record、journal、索引行」
  （`rust/crates/arkdeck-agentd/src/cutover_preflight.rs:49-51`）。
  开窗前约 30 分钟跑一遍，第 2 步前再跑一遍（`01a-preflight-2.json`），两遍的 `blocks` 应一致。
- 预期：exit 0，stdout 恰一份 canonical `arkdeck.cutover-preflight/1` 文档：`stateDirectory` 是本账户
  `Agentd`、`instanceLockHeld: false`、`clear: true`、`blocks: []`、`snapshot: null`；`carriedOver`
  列出原样承接的 `parkedJobIds`、`terminalJobCount`、`outcomeUnknownUseCount`；`counts` 给出 `jobs`、
  `agentExecutions`、`capabilityUses`（字段见 run 记录 :50-56）。
- 「只读」的精确含义（逐项核实见 `evidence/runs/TASK-XPA-017/cutover-runbook-appendix-b-run.md` 第 19 条）：
  - 这一遍不取任何锁（无 `flock`，也不开 SQLite 写事务），不建目录、不建锁文件，不写 record、journal、ledger、
    索引行或设置。
  - 读哪个账户的 state：`CFFIXED_USER_HOME`，未设时为运行用户 passwd 记录里的家目录
    （`rust/crates/arkdeck-platform/src/account.rs:7`）；`HOME` 不决定读哪里。
  - **会在 Job 索引 `runtime-jobs.sqlite3` 旁创建或触碰 `-wal`/`-shm`，不改数据库内容**：旁边已有 `-shm`（Swift daemon
    在跑或停过都会留下）时用只读连接，可能在 `-shm` 里记下读标记（触碰）；没有 `-shm` 时用一条不写的读写连接，可能在
    索引旁新建空的 `-wal` 与新的 `-shm`（创建，与数据库同权限）；两种情况数据库字节都不变（run 记录 :111-115；
    `rust/crates/arkdeck-agentd/tests/cutover_preflight.rs:862`）。#2142、#2255 记录里「两遍都不写」说的是 owner 数据
    （record、journal、索引行），不含这里的 `-wal`/`-shm`。能否接受由维护者判断（附录 B 第 19 条）；若要真正零写入
    （例如以 immutable 方式打开、或先复制一份再读），是另一刀的设计取舍，列为待定。
  - SQLite 报忙时不等待（busy timeout 为 0），直接记为 `unreadable` 的 `jobIndex`。
- 停止判据：exit 非 0；`clear: false`；两遍之间 `blocks` 不同且差异不能由「刚好在跑的 Job 已结束」解释。
- 失败时：按下表逐项处理，处理后重跑 1a，直到两遍都 `clear: true`。**`carriedOver` 里的 Job 不处理**：
  `waitingForRecovery`（outcomeUnknown lane）与终态 Job、outcome-unknown 的 capability use 按 design §G.4
  原样带进 Rust，只能经 `job reconcile` 读回或 `POL-RECOVERY-001` 的完整证明路径推进，绝不重放。

**预检拒绝种类与处理**（种类与字段见 `runtime-service-cutover-preflight-run.md:58-66`；#2255 新增两种见
`evidence/runs/TASK-XPA-017/cutover-preflight-legacy-refusals-run.md:18-35`）。第 2 步的 update 遇到同样的块时
exit 75，stderr 形如 `arkdeck runtime.service.update: runtime service update refused: the Runtime state cannot be carried
over as it is (<各块文案，以「; 」连接>); nothing was changed`（`runtime_service_install.rs:673-695`，各块文案
`:697-736`，例如 `Job <id> is <state>`、`Job <id> has an unresolved journal`、`agent execution <id> is <state>`、
`capability <id> use <n> of Job <id> is unsettled`、`HDC tool selection <id> is pending`、`<source> is unreadable: <reason>`）。

| `kind` | 含义 | 处理（执行者均为【维护者】，经已发布 CLI 面） |
|---|---|---|
| `jobState` {`jobId`,`state`} | Job 处于 13 个阻断态之一（`queued`、`preflight`、`running`、`waitingForDevice`、`awaitingRebindConfirmation`、`planning`、`cancelRequested`、`cancellingAtSafeBoundary`、`reconciling`、`recoveringByCompleteOverwrite`、`resumeAtConfirmedSafeBoundary`、`userAbandonRequested`、`finalizing`）或不在状态表里（含本读者自己的 `unreadableRecord`/`missingRecord`） | 在旧 Runtime 上让它走到终态或停放态：`"$OLD_ARKDECK" job wait --job <id> --output json`；等人工动作的走 `human-action show --human-action <id>` → `agent resume --resume-reference <ref>`；确需取消的用 `job cancel --job <id>`，是否取消由维护者判断（选项见 `rust/crates/arkdeck-cli/src/command_registry.json` 的 `job wait` :6701、`human-action show` :11649、`agent resume` :11375、`job cancel` :7350）。`unreadableRecord`/`missingRecord`：**停止**，不删不改，交协调会话只读排查 |
| `unresolvedJournal` {`jobId`} | 非停放 Job 的 journal 有未决 intent、unknown outcome、torn 尾或无法回放 | 让该 Job 在旧 Runtime 上结束（同上）；torn 尾或无法回放的：**停止**，不手改 journal，交协调会话排查，必要时维护者裁决 |
| `activeAgentExecution` {`executionId`,`state`} | 有活跃的 agent execution（被停放/终态 Job 名下的 `jobOwned` 除外） | `"$OLD_ARKDECK" agent status --execution-id <id> --output json`（`command_registry.json:10944`）读状态，按其 `nextAction` 走完（等待、`agent resume`）；不从外部改 execution 记录 |
| `unsettledCapabilityUse` {`capabilityId`,`useOrdinal`,`jobId`} | capability use 的 outcome 是 `pending` 或不在表里 | 让所属 Job 结算（同 `jobState`）；**不手工 settle、不删 ledger** |
| `pendingToolSelection` {`controlActionId`} | `Bootstrap/v1/tools.json` 有待定的 HDC 工具选择 | 没有「放弃待定选择」的已发布命令（核实见 `evidence/runs/TASK-XPA-017/cutover-runbook-appendix-b-run.md` 第 11 条）。待定选择只由 Swift daemon 自己结算：下一次启动时，所选 HDC 起得来就发布，起不来就判失败并回到原工具（`Packages/ArkDeckKit/Sources/ArkDeckAgentDaemonMain/main.swift:474-545`，只在配置了 HDC 时）。选择流程本身会让 daemon 重启，无锁那遍可能正好读到这个窗口，重启后即消失。持续存在时，让旧 daemon 再启动一次的已发布路径是 `"$OLD_ARKDECK" runtime service restart --output json`（`command_registry.json:1020`；有活动或未收尾的 Job 时 exit 75 拒绝）；之后 `"$OLD_ARKDECK" control-action reconcile --control-action <controlActionId> --output json`（`:12156`）结算该控制动作的记录（预检只读 `tools.json` 的待定项）。是否为此重启旧 Runtime，**维护者定** |
| `unreadable` {`source`,`reason`} | 某个来源读不了（`jobs`、`jobIndex`、`agentExecutions`、`capabilities`、`toolSelection`、`stateDirectory`、`instanceLock`、`snapshot`；#2255 起还有 `sessionStorage`） | **停止**。不删不改，交协调会话只读排查，维护者裁决 |
| `runtimeRunning` {`reason`} | 只在持锁那一遍出现：别的进程持有 `Agentd/instance.lock` | 第 2 步的 update 在「只因 runtimeRunning 被拒」时自己按 poll 间隔重问，最多 50 次，约 5 s（`runtime_service_install.rs:87`、`:628-648`）；仍拒则说明 bootout 后仍有进程持锁：**停止**，旧服务会被原样 bootstrap 回来（见第 2 步失败语义） |
| `loaderTransitionAwaitingBinding` {`jobId`,`targetId`,`expectedBindingRevision`}（#2255） | 一个从未被 ArkForge lane 驱动过的停放 DAYU200 Flash Job，其记录与 journal 恰好停在 Swift 的 `flash.bind-current-loader` 能结算的「进入 Loader」过渡上；Rust Runtime 不移植该结算（F7） | 板子接好并处于 **Loader** 时，在**旧 Swift Runtime** 上执行 `"$OLD_ARKDECK" flash bind-loader --target <targetId> --expected-binding-revision <expectedBindingRevision> --output json`（两个选项均必填，`command_registry.json:20059`；拒绝文案原文在 `rust/crates/arkdeck-cli/src/runtime_service_install.rs:702-711`），然后重跑 1a。bind-loader 被拒：**停止**，保留该 Job 与拒绝原文，交维护者裁决；不用 `--rebind` 覆盖缺失的身份/lineage 证明 |
| `retainedSessions` {`sessionsRoot`,`code`,`message`}（#2255） | 保留的 Session（默认 `Sessions` 根，以及 `Agentd/session-storage.json` 选中的根）会被设备 mutation 的连续性证明拒绝，`code`/`message` 即该证明自己的码与原话（`recordUnreadable`；`rust/crates/arkdeck-hoststore/src/mutation_state_continuity.rs:196-201`、`:214-219`） | 被拒的 Session 由这一块的 `message` 点名（`retained Session <yyyy/mm/名称> …`）。`"$OLD_ARKDECK" runtime storage status --output json`（无其他选项，`command_registry.json:3259`）只给 `usage.unaccountedSessionCount` 计数、不点名（`message` 里说 status 会点名，实际只计数）；`session cleanup preview --output json`（`:8118`）遇到这种无法归属的内容会整根拒绝（`operationUnavailable`「Session catalog contains unaccounted content: …」），在拒绝原文里点名。所以 `session cleanup apply`（`:8222`，须先有 preview）移除不了它，也没有移动或删除它的已发布命令（核实见 `evidence/runs/TASK-XPA-017/cutover-runbook-appendix-b-run.md` 第 12 条）。审阅后是否手工移出 Session 根、移到哪里，**维护者定**。第一遍无锁，Swift 正在原地发布的 Session 可能被一时点名，重跑即消失 |

**1b update 内部的两遍（第 2 步自动执行，这里只说明）**：Rust CLI 的 `runtime service update` 在装 Rust daemon
时先跑一遍无锁预检（不 clear → exit 75，零改动），然后 bootout，再持 `Agentd/instance.lock` 跑一遍并在读事实之前
先拍快照（不 clear 或快照不是持锁拍的 → 原样 bootstrap 旧 plist）；持锁这一遍才是「state 已静止」的证明，
无锁那遍只是提示（run 记录 :12-19、:124-125）。快照摘要写到
`$SUPPORT/LaunchAgent/cutover-snapshots/cutover-<takenAtUtc 的字母数字>-<rootSha256 前 12 位>.json`（canonical JSON、0600、
只新建；同名但内容不同即拒 `another cutover snapshot already holds <path>`，`runtime_service_install.rs:992-1029`）。
快照是逐文件的大小与 SHA-256 清单加根摘要 `rootSha256`，不是 state 的拷贝（`cutover_preflight.rs:300-324`）。
Swift 安装包（Rust→Swift 回滚）不走这两遍：新 helper 的 daemon 以 `unknown argument` exit 64 回答时即判为 Swift，
不再有任何预检门（`runtime_service_install.rs:812`）。

### 第 2 步：LaunchAgent 改指向 Rust，façade 保留一个周期（约 5 分钟）

- 执行者：【维护者】本人。该命令内部会对 `gui/<uid>/com.arkdeck.agentd` 执行 `launchctl bootout` 与
  `bootstrap`（`/bin/launchctl`，参数数组见 `rust/crates/arkdeck-platform/src/launchd.rs:23-56`），属于安装态操作。
- 前提：第 1 步两遍 1a 都 `clear: true`；P6 已放行（无签名预设或 S-1 已落地）；P7 裁决前沿用 live plist 的
  ArkForge bundle。
- 命令（用 **Rust CLI**；Swift CLI 的 update 不做预检、不写快照、不留 `.rollback`，不得用于切换）：

  ```sh
  "$ARKDECK" runtime service update --daemon "$HELPER" --hdc "$HDC" \
    --arktrace-descriptor <现值的绝对路径或 none> --output json \
    > "$OUT/02-update.json" 2> "$OUT/02-update.err"; echo "exit=$?"
  ```

  选项的取值规则（`rust/crates/arkdeck-cli/src/runtime_service_install.rs:303-437`；没有 `--dry-run`、`--plist`）：
  - `--daemon`：显式给 `$HELPER`。省略时取 CLI 所在 `.app` 的 `Contents/Helpers/ArkDeckAgent.app`
    （`runtime_service.rs:1664-1676`），与 headless runbook「显式固定已发布 helper」的要求不符，不省略。
  - `--hdc`：显式给 `$HDC`；省略时沿用已安装的 `hdcPath`（`:319-328`）。
  - `--arktrace-descriptor`：省略时只有 live plist 与 descriptor 字节仍和 receipt 一致才沿用，否则 exit 1
    「ArkTrace distribution descriptor drifted since installation; pass --arktrace-descriptor explicitly …」
    （`:374-386`；`runtime_service.rs:967-987`）。从第 0 步 `status` 的 `launchAgent.arkTraceDescriptor` 读现值显式传入，
    没有就传 `none`。
  - `--arkforge-bundle` / `--arkforge-campaign`：都省略时沿用 live plist 的 ArkForge lane（`:398-426`），P7 裁决前就这样做；
    `--arkforge-campaign` 必须同时显式给 `--arkforge-bundle`（`:418-420`）。
  - `--workspace-project` / `--deveco-sdk`：`runtime service` 拼写不沿用已安装的这一对（`:334-359`）；它们是旧版注入，
    按 headless runbook §1 省略。`--sensitive-evidence`、`--harness-*`、`--arkforged*`、`--arkforge-profile` 一律按名拒。
- 预期：exit 0；stdout 的回执带 `cutover` 成员：`snapshotPath`、`snapshotRootSha256`、`carriedOver`、`rollbackBundlePath`
  （`runtime_service_install.rs:581-585`、`:665-669`）。`cutover` **只出现在这次 stdout 里**，不写进磁盘上的
  `install-receipt.json`（`:578-585`），所以 `02-update.json` 必须保存；`$SUPPORT/Helpers/.rollback/ArkDeckAgent.app` 是被替换的 Swift helper；新 plist 的
  `ProgramArguments` 指向 `Helpers/ArkDeckAgent.app/Contents/MacOS/arkdeck-agentd`（无 façade 时选 daemon 本身，
  `runtime_service.rs:673-685`），环境里多了 `ARKDECK_RUNTIME_COMPOSITION=production`
  （`runtime_service_install.rs:1128-1130`），`MachServices` 仍是 `com.arkdeck.agentd`。
- 核对（【维护者】执行只读命令，【协调会话】比对）：

  ```sh
  plutil -p ~/Library/LaunchAgents/com.arkdeck.agentd.plist > "$OUT/02-plist-after.txt"
  shasum -a 256 "$HELPER/Contents/MacOS/arkdeck-agentd" "$SUPPORT/Helpers/ArkDeckAgent.app/Contents/MacOS/arkdeck-agentd"
  ls "$SUPPORT/Helpers/.rollback/ArkDeckAgent.app/Contents/MacOS/"      # 应见 arkdeck-agentd 与 arkdeck-facade
  ls -l "$SUPPORT/LaunchAgent/cutover-snapshots/"
  ```

- 停止判据：exit 非 0；或 exit 0 但回执没有 `cutover`（说明新 helper 被判成了 Swift）、`rollbackBundlePath` 为空、
  plist 仍指向 `arkdeck-facade`。
- 失败时，先按退出码与 stderr 判断安装态处在哪一段（`install()` 的顺序见 `runtime_service_install.rs:468-587`）：

  | 阶段 | 典型退出与原文 | 安装态 | 做什么 |
  |---|---|---|---|
  | 参数、签名预设、源 bundle 验签、分析器探测、façade 门、第一遍预检 | 64（参数）；69「… is refused while an OpenHarmony signing preset is installed …」（`:442-455`）；1（验签，`host_bundle_signature.rs:19` 的要求）；69「… does not answer --analyze-crash-ledger …」（`:492-506`）；69「a Rust daemon bundle carries no facade」（`:507-515`）；69 预检探测错误（`:775-823`）；75「… nothing was changed」 | 未改动，旧服务照常运行 | 按原文处理后重跑第 1、2 步，或关窗口 |
  | bootout 之后的持锁一遍（`:593-670`） | 75「… the state was left as it is」或 69「the helper's daemon stopped answering the cutover preflight」「the held cutover preflight answered no snapshot taken under the instance lock」，并带后缀「; the previous service was started again from its unchanged plist」或「; starting the previous service again failed: …」（`:599-625`） | 前一种后缀：旧服务已从未改的 plist 重新 bootstrap；后一种：**旧服务停着** | 前者同上一行；后者由【维护者】`launchctl bootstrap gui/$(id -u) ~/Library/LaunchAgents/com.arkdeck.agentd.plist` 拉起旧服务（plist 未改），再用第 0 步的命令核对 |
  | 快照写完之后：换 bundle、写 plist/回执、bootstrap（`:539-580`；换 bundle 见 `:1036-1066`） | exit 1，原文即底层错误；**没有自动恢复**：快照写入及之前的失败会从未改的 plist 拉起旧服务（`:599-625`），之后的各步没有（核实见 `evidence/runs/TASK-XPA-017/cutover-runbook-appendix-b-run.md` 第 18 条） | 旧服务已 bootout、未运行。视失败的那一步：已装的 helper 未换（旧的）或已换成 Rust；被换下的 helper 在 `.rollback/ArkDeckAgent.app`，若失败发生在对换之后、移入 `.rollback` 之前，则留在 `Helpers/.arkdeck-agentd-<UUID>.app`；plist 与回执都未改、只改了 plist，或都已改 | **停止**。【维护者】只读核对 `Helpers/ArkDeckAgent.app`、`.rollback/` 与有无 `Helpers/.arkdeck-agentd-*.app` 里各是哪个 helper（有无 `arkdeck-facade`）、plist 的 `ProgramArguments`，【协调会话】比对；然后按 §4 第 3 行处理，不手改 state |
- façade 保留一个周期：`$SUPPORT/Helpers/.rollback/ArkDeckAgent.app` 与 `$ROLLBACK` 都不删。「一个周期」到哪天
  结束 **TBD（维护者定）**；在 20d 删除 Swift target 之前不得删除。注意 `.rollback` 只存一代：之后每次
  `--daemon` 指向别处的 `runtime service update` 都会先删掉 `.rollback` 里原有的那一代、再把当时被替换的 helper 放进去；
  只有 `--daemon` 恰为已安装 helper 本身（`$SUPPORT/Helpers/ArkDeckAgent.app`，路径文本完全相同）时不换 bundle、
  `.rollback` 不动（`runtime_service_install.rs:1036-1066`）。第 5 步 GJ-4 的 campaign staging 与第 7 步都要用到这一点。

### 第 3 步：`runtime service verify`（约 5 分钟）

- 执行者：【维护者】（无 `--job` 的 verify 会经 daemon 新跑一次 `observe.device@1`，是真实设备读操作）。
- 命令：

  ```sh
  "$ARKDECK" runtime service status --output json > "$OUT/03-status.json"
  "$ARKDECK" runtime service verify --target <TGT> --output json > "$OUT/03-verify.json"; echo "exit=$?"
  "$ARKDECK" doctor --deep --require-healthy --output json > "$OUT/03-doctor.json"; echo "exit=$?"
  ```

  `status` 即使服务没就绪也 exit 0（`rust/crates/arkdeck-cli/src/runtime_service.rs:1424-1435`），**必须看字段**：
  `launchAgent.ready`、`launchAgent.diagnostics`、`launchAgent.daemonSHA256`、`daemonHealth`
  （字段 `:459-493`，判定 `:1011-1168`）。无 `--job` 的 `verify` 先经 daemon 跑 `agent.run` `observe.device@1`
  再重开该 Job 校验（`rust/crates/arkdeck-cli/src/runtime_service_verify.rs:85-169`），`--maximum-wait-seconds` 1–300、
  缺省 90（`runtime_service.rs:1538-1552`、`:1603-1605`）；等人工动作时 exit 75 并给出
  `arkdeck agent resume --resume-reference <ref>`（`:1645-1650`），照做后重跑 verify。
- 进程表核对（`status` 与 `verify` 都不查进程表，socket 对端在 macOS 上只核 UID、不核可执行身份，
  `rust/crates/arkdeck-platform/src/unix.rs:269`，所以要手工核）：

  ```sh
  launchctl print gui/$(id -u)/com.arkdeck.agentd | grep -m1 'pid ='   # 只读
  pgrep -lf 'arkdeck-(agentd|facade)'
  ps -p <pid> -o lstart=,comm=
  ```

  预期恰有一个 `arkdeck-agentd`，其 pid 等于 `launchctl print` 的 pid，启动时间晚于第 2 步，没有 `arkdeck-facade`
  （façade 对的 Swift daemon 与 Rust daemon 可执行名相同，只能靠「无 façade、pid 唯一且是新的」加上下面的哈希分辨）。
- 预期：`launchAgent.ready: true`、`diagnostics: []`；`launchAgent.daemonSHA256` 等于
  `shasum -a 256 "$HELPER/Contents/MacOS/arkdeck-agentd"`；`daemonHealth` 是 daemon 的 `health` 回答（不是
  `socket_absent` 或 `unreachable`）。`verify` exit 0 且 `runtimeVerified: true`。`doctor --deep --require-healthy` exit 0。
- 停止判据：任一预期不成立；daemon 崩溃循环（`status` 只报 `socket_absent`，诊断含「daemon socket is absent;
  service may still be starting …」，`runtime_service.rs:1159-1161`；看 `~/Library/Logs/ArkDeck/agentd.error.log`）。
- 失败时：见 §4 第 3 行（切换后 daemon 起不来）与第 4 行（切换后功能缺陷）。

### 第 4 步：签名 App ↔ Rust Mach service 的正向与负向验收（SPK-8，约 15 分钟）

- 执行者：【维护者】（App 与 UI 跑道是全机唯一的，窗口内不与其他 UI 跑道并行）。
- 正向：已安装的签名 App（P9）连上 Rust daemon 的 `com.arkdeck.agentd` Mach service，Overview 显示当前 DAYU200、
  History 列出切换前的 Job（与 `00-jobs-before.json` 同集合）。可复用的已登记 UI 冒烟是
  `ArkDeckHDCUITests/FacadeRollbackUITests`（Overview/History 只读冒烟，tasks.md TASK-XPA-003 Allowed paths 条目）：

  ```sh
  sh scripts/ci/run-ui-tests.sh -only-testing:ArkDeckHDCUITests/FacadeRollbackUITests
  ```

  该测试需要的开关与前提 **TBD（维护者定）**：本文未核实它对「standalone Rust daemon」形态是否适用；
  SPK-8 的判据是「History filter UI 测试对 Rust standalone daemon 绿、六项 entitlements 不变」
  （tasks.md SPK-8 行），对应的具体测试名也 **TBD（维护者定）**。
- 负向：身份不符的对端被拒且不挂起——(a) daemon 拒绝非本团队签名的客户端；(b) App 遇到非同一 release 或身份不符的
  daemon 时报告不匹配与补救办法、不挂起（XPA-AC-9 r5 的「另一 release 的 daemon」一条）。可执行的负向用例与
  harness **TBD（维护者定）**：仓内没有现成的「安装态负向」脚本，Q3 的环境裁决决定在哪里做。
- 停止判据：正向任一项失败；负向中出现挂起或放行。
- 失败时：记 `BLOCKED_BY_PRODUCT_DEFECT`，按原实现 Task（TASK-XPA-019）修；是否回滚见 §4。

### 第 5 步：GJ-1…GJ-5 `REAL_DEVICE_PASS`（约 70 分钟）

- 执行者：【维护者】执行设备命令（或维护者当场授权的执行方式）；GJ-4 需维护者明确的 go；【协调会话】核对判据与整理记录。
- 做法：照 [headless GJ runbook](../cli-golden-journey-headless-runbook.md) §1–§6 原样执行，`arkdeck` 一律是
  `$ARKDECK`（Rust CLI），不用 Swift CLI；每条 Journey 用 `agent run --operation <id@version>`，人工动作后
  `agent resume`（[验收指南](../../../scripts/agent-guides/acceptance.md)）。headless 路径缺失或失败即
  `BLOCKED_BY_PRODUCT_DEFECT`，不让维护者代跑，不拿 UI 点击替代。
- 当前 Catalog digest：从 `"$ARKDECK" operation list --output json` 的 `result.catalogDigest` 读（runbook §0 固定事实表），
  必须等于窗口所用 `main` 提交生成的 Catalog；`REAL_DEVICE_PASS` 只在该 digest 上成立（`AGENTS.md`「Agent 禁令与设备执行边界」末条）。
  切换前在 Swift Runtime 上的结果、fixture、开发根结果都不计入。
- GJ-1：runbook §2 与 §2.1（HAR crash-resume）；成功后 `"$ARKDECK" runtime service verify --job <observe-job-id> --output json`
  读回同一份结果（runbook §1 最后一段）。
- GJ-2、GJ-3：runbook §3、§4。
- GJ-4：runbook §5，**维护者 go 之后**才开始；P7 裁决未放行时不开始。若需要命名 campaign，runbook §5 的
  `runtime service update … --arkforge-campaign` 在 Rust daemon 上也会重跑预检（每次装 Rust daemon 都跑，含 Rust→Rust）
  并重启 daemon，前提是没有在途 Job，且受 P6 签名预设拒绝的约束。这里的 `--daemon` 传已安装 helper 本身
  `"$SUPPORT/Helpers/ArkDeckAgent.app"`（与 `$HELPER` 同一份已验证字节），`.rollback` 里的 Swift helper 才不会被 Rust helper
  顶掉（见第 2 步「façade 保留一个周期」）；结束 staging 时照 runbook §5 清回，同样这样传 `--daemon`。
  刷机后重读 `target show` 的 binding revision。
- GJ-5：runbook §6；依赖 P6（签名预设）。
- 记录：见 §5。

### 第 6 步：App 呈现检查（runbook §6b，约 10 分钟）

- 执行者：【维护者】。
- 做法：照 runbook §6b，经 `scripts/ci/run-ui-tests.sh` 跑真实 Runtime 的纯呈现 opt-in（开关必须带 `TEST_RUNNER_`
  前缀，否则跳过；XCUITest target 名是 `ArkDeckHDCUITests`），对象是第 5 步留下的真实 Job（例如 History viewer 用
  GJ-1 的 Job ID）。缺前提得到的 `XCTSkip` 记「未执行」。
- 记录：逐测试 `pass` / `fail` / `未执行`，附完整命令与 `xcresult` 路径；不套用 Journey 四态。

### 第 7 步：回滚演练（XPA-AC-9，约 30 分钟）

**先读口径**：tasks.md 里 XPA-AC-9 的 r5 演练（TASK-XPA-003 行 :377）是「`runtime service update --daemon <swift>`，
再用**更新后的 App** 对同一 release 的已回滚 Swift daemon 跑 `AgentXPCTransportContractTests` 黑盒子集、
App 冒烟（Overview/History）与 headless CLI 演练；另一 release 的 daemon 应报不匹配与补救、不挂起」。
r10/r11 的 `verification.md:43`、`:73` 把 XPA-AC-9 解释为「在 M5 一次切换中满足（§G.4 预检、快照摘要、
façade bundle 保留一个周期）」，并写明「no same-release Swift rollback」；design §G.4「故障退出」也写明开发版本
修复后重启即可、不要求切回 Swift。两者对「本窗口是否真的切回 Swift 再切回来」不一致：**演练做不做、做到哪一层，
窗口前必须由维护者裁决**。下面给出完整做法，供裁决后执行。

- 执行者：【维护者】本人（两次安装态切换）。
- 前提：第 5、6 步的记录已落盘；1a 手工预检（此时用 `$HELPER` 里的 Rust agentd）`clear: true`。Rust→Swift 的
  update 走 Swift 安装路径，**不会**自动跑预检（新 helper 的 daemon 以 `unknown argument` exit 64 回答即判为 Swift，
  `runtime_service_install.rs:812`），所以这里的手工预检是唯一的门。签名预设的拒绝对这次 update 同样生效（P6）：
  装有预设时 Rust CLI 回滚不了，改用 Swift CLI 的 `runtime service update` 回滚是否可行、是否可接受 **TBD（维护者定）**。
- 回滚命令（源用 `$ROLLBACK`，不用 `$SUPPORT/Helpers/.rollback/…`：后者会在这次 update 里被当前 Rust helper 顶替）：

  ```sh
  "$ARKDECK" runtime service update --daemon "$ROLLBACK" --hdc "$HDC" \
    --arktrace-descriptor <同第 2 步> --output json \
    > "$OUT/07-rollback.json" 2> "$OUT/07-rollback.err"; echo "exit=$?"
  ```

  按源码，这次 update 会：写不含 `ARKDECK_RUNTIME_COMPOSITION` 的 plist，`ProgramArguments` 重新选
  `arkdeck-facade` 并用 `ARKDECK_SWIFT_SHA256` 钉住同包的 Swift daemon（`runtime_service.rs:673-685`；
  `runtime_service_install.rs:1087-1092`）；把被替换的 Rust helper 放进 `Helpers/.rollback/`，放之前删掉原有的那一代
  （`:1036-1066`）。回执没有 `cutover`。源码没有「回滚」叶子，也没有保留旧 plist 或旧回执（二者都被原子覆盖，
  `:565-566`、`:578-579`）；「用 update 回滚」是按源码推出来的做法，Swift daemon 能否读 Rust 写下的 state 不在
  这些源码的覆盖范围内，正是本演练要验证的。
- 回滚后核实：
  1. `runtime service status`：receipt 的 daemon hash 等于 `$ROLLBACK/Contents/MacOS/arkdeck-agentd`，plist 指回
     `arkdeck-facade`；daemon 健康（崩溃循环时见下「特别注意」）。
  2. `job list --page-size 1000`（读完所有页）的 `jobId` 集合与第 5 步结束时相同；GJ-1 的 Job 用
     `"$OLD_ARKDECK" runtime service verify --job <observe-job-id>` 读回一致——这是 Rust 写下的 durable 格式
     （journal、`runtime_job` 索引、`job-record.json`、Session manifest、capability ledger、Artifact index）能被
     Swift 原样读回的直接证据（design §G.1 r11 的 T0 清单）。
  3. 已更新的 App 对回滚后的 Swift daemon：Overview/History 冒烟（第 4 步同一 UI 测试）。
     `AgentXPCTransportContractTests` 黑盒子集如何对安装态 daemon 运行 **TBD（维护者定）**。
  4. outcomeUnknown 的 Job 与 capability use 数量不变、未被重放（对照 `07` 前后的 `carriedOver` 与 `job list`）。
- 再切回 Rust：重复第 1 步 1a 与第 2 步（`--daemon "$HELPER"`），核对新快照摘要与新回执，再跑一次第 3 步。
- 停止判据：回滚后 Swift daemon 起不来、Job 集合或 durable 记录读回不一致、App 挂起。
- 失败时：立即切回 Rust（第 2 步命令），不修改 state；把失败原文记为 `BLOCKED_BY_PRODUCT_DEFECT` 或交维护者裁决。

**不可逆与特别注意**（参照 2026-09-05 SVC-001 升级阻塞：旧记录让新 daemon 启动恢复失败、launchd `KeepAlive`
每 5 s 重启、socket 不出现、所有 CLI 请求 `runtimeUnavailable`）：

- 切到 Rust 之后 Rust daemon 写下的 durable 状态不会因回滚消失：新 Job、capability ledger 行、recovery epoch、
  GJ-4 推进的 binding revision 与 Loader 别名都是真实事实；回滚只换进程，不撤销它们。
- Rust 独有的文件会留下：`$SUPPORT/LaunchAgent/cutover-snapshots/`，以及 Rust Job owner 在 state 里建的
  `.rust-job-owner.lock`（`rust/crates/arkdeck-hoststore/src/job_repository.rs:14`）与 `cli-job-snapshots/` 分页快照目录
  等。Swift daemon 能否容忍它们正是本演练要验证的，演练前不要删。
- 若 `$ROLLBACK` 不含 #2204（P8），而 state 里有「preset 已删、所指 project 也已删」的墓碑，Swift daemon 启动会
  `recordUnreadable` 而起不来。
- daemon 起不来时：`runtime service status` 只报 `socket_absent`，要看 `~/Library/Logs/ArkDeck/agentd.error.log`；
  崩溃循环里每次重启都会再跑一遍启动恢复，【维护者】先 `launchctl bootout gui/$(id -u)/com.arkdeck.agentd` 止住，
  再切回 Rust。不手改或删除 job-record、journal、ledger。
- 回滚之后第一次 update 回 Rust 时，`.rollback` 里是 Rust helper 还是 Swift helper，以该次回执的 `rollbackBundlePath`
  为准；想让「保留一个周期」的仍是 Swift helper，窗口结束时核对 `.rollback` 的内容（应含 `arkdeck-facade`）。

## 4. 回滚预案（窗口中任一步失败时）

| 失败发生在 | 状态 | 做什么 |
|---|---|---|
| 第 0、1 步 | 什么都没改 | 按表处理后重来，或关窗口 |
| 第 2 步 update 非 0 退出 | 取决于失败阶段，见第 2 步「失败时」表 | 读 `02-update.err` 原文，按该表判断阶段；`"$ARKDECK" runtime service status` 看 `launchAgent.ready` 与 `ProgramArguments`；旧服务健康则按原文处理后重跑第 1、2 步或关窗口；旧服务停着且 plist 未改则由【维护者】bootstrap 旧 plist；中间态见下一行 |
| 第 2 步成功，但 Rust daemon 起不来（第 3 步 `socket_absent`、崩溃循环）；或第 2 步在快照之后失败（中间态） | 安装态已是 Rust，或处于中间态 | 【维护者】先 `launchctl bootout gui/$(id -u)/com.arkdeck.agentd` 止住循环；读 `agentd.error.log`；用 `"$ARKDECK" runtime service update --daemon "$ROLLBACK" --hdc "$HDC" --arktrace-descriptor <同第 2 步> --output json` 回到 Swift（`$ROLLBACK` 的 Swift daemon 在解析参数时就以 exit 64 拒绝 `--cutover-preflight`，不碰 state，update 据此判为 Swift、不走预检门：`Packages/ArkDeckKit/Sources/ArkDeckAgentDaemonMain/main.swift:183-203`、`rust/crates/arkdeck-cli/src/runtime_service_install.rs:812`；第 7 步的前提、签名预设限制与核实同样适用；这条路径是按源码推出的，见附录 B 第 18 条）；不改 state |
| 第 3–6 步功能缺陷 | 安装态 Rust，daemon 健康 | 记 `BLOCKED_BY_PRODUCT_DEFECT`（原文、Runtime 引用、复现 argv）。两种走法由维护者当场定：(a) 停在 Rust，停止新执行、保留状态，修复后更新 Rust helper 再验（design §G.4「故障退出」）；(b) 回到 Swift（同上一行命令） |
| 任何一步出现真实设备不确定状态 | — | 只读回；只有 `POL-RECOVERY-001` 的完整机械证明成立时 Runtime 才能独立完整覆写恢复；缺证明时零新 dispatch。**不**为此回滚、不换 state 目录、不从备份恢复 |
| 第 7 步回滚演练失败 | 安装态 Swift 或半途 | 切回 Rust（第 2 步命令），不改 state，记录原文，交维护者裁决 |

任何情况下都不做：删除或手改 state 目录里的记录；用 Time Machine/拷贝恢复 state 去「撤销」设备副作用；手工创建或
修改 capability、trusted facts、reservation、evidence；绕过 Provider 的 raw HDC 或刷机命令。

## 5. 记录要求

- **窗口叙述记录**：`openspec/changes/chg-2026-074-shared-rust-runtime-core/evidence/runs/TASK-XPA-017/cutover-window-<date>-run.md`
  （窗口后由协调会话或 Agent 按原始输出起草，经 PR 交维护者 review）。
- **GJ 记录**：`docs/design/references/v1.6-goal/gj-headless-rerun-<date>-macos.json`（`verification.md:76` Golden Journeys 行），
  并给 `docs/design/references/v1.6-goal/real-device-validation.md` 加一节；记录形状沿用 `arkdeck.gj-headless-rerun/1`
  与 runbook §7 的字段（`catalogDigest`、`runtimeSourceRevision`、`runtimeExecutableSHA256`、`cliBuildIdentity`、
  `targetID`、binding revision 前后、`executionIDs`、`jobs[]`、`zeroDispatchChecks`）以及 `operationRealDeviceCoverage`。
- **App 呈现记录**：写进叙述记录的一节（逐测试结果、命令、`xcresult` 路径）。
- 叙述记录写这些：
  - 时间线（UTC）：每步的开始/结束、执行者；
  - 每条命令的 argv（`$HOME` 写成 `~`，不写个人绝对路径）与退出码；
  - 输出摘要：预检的 `clear`、`blocks`、`carriedOver` 计数与 `parkedJobIds`、`counts`；快照 `rootSha256` 与文件名；
    回执里 daemon 与 HDC 的 SHA-256、`rollbackBundlePath`；Catalog digest；窗口所用 `main` 提交；
    `$HELPER`、`$ROLLBACK` 可执行文件的 SHA-256 与 `codesign -dv` 的 Identifier/TeamIdentifier；
  - P1–P13 的核实结果与各项裁决的出处；
  - 每个 `BLOCKED_BY_PRODUCT_DEFECT` 的脱敏原文、Runtime 引用与复现 argv；
  - 回滚演练的每项核实结果。
- 不写：secret、钥匙串条目、provisioning profile 内容、notarytool 凭据名以外的账户信息；设备序列号、connectKey、
  原始设备输出；个人路径。原始输出留在 `$OUT`，不入仓。

## 附录 A. 命令与源码位置对照

| 命令 / 事实 | 源码或记录位置 |
|---|---|
| LaunchAgent 标签 `com.arkdeck.agentd`、域 `gui/<uid>`、`/bin/launchctl` 与 `print`/`bootout`/`bootstrap` 参数数组 | `rust/crates/arkdeck-platform/src/launchd.rs:23`、`:25`、`:30`、`:40`、`:45`、`:50` |
| 安装态路径（plist、`Helpers/ArkDeckAgent.app`、`Helpers/.rollback/`、`LaunchAgent/cutover-snapshots`、`install-receipt.json`、`Signing/OpenHarmony/preset-v1.json`、`Agentd`、socket、日志） | `rust/crates/arkdeck-cli/src/runtime_service.rs:119-138` |
| plist 渲染（`Label`、`ProgramArguments`、`MachServices`）与切换时加 `ARKDECK_RUNTIME_COMPOSITION=production` | `rust/crates/arkdeck-cli/src/runtime_service_install.rs:1071`、`:1128-1130`、`:1132-1147` |
| `ProgramArguments` 选 daemon 还是 façade | `runtime_service.rs:673-685`；`runtime_service_install.rs:552-554` |
| 签名预设在任何改动前拒绝（exit 69） | `runtime_service_install.rs:442-455` |
| 已退役的 `--arkforged`/`--arkforged-sha256`/`--arkforge-profile` | `runtime_service_install.rs:387-395` |
| `runtime service update/restart/status/verify/uninstall` 的选项表（Swift 注册表副本） | `rust/crates/arkdeck-cli/src/command_registry.json:953`、`:1020`、`:1073`、`:1188`、`:1241` |
| `flash bind-loader`（`--target`、`--expected-binding-revision` 均必填） | `command_registry.json:20059` |
| `job cancel`、`job reconcile`、`job wait`、`agent status`、`agent resume`、`human-action show`、`session cleanup preview/apply`、`runtime storage status`、`runtime tool select`、`runtime signing status` | `command_registry.json:7350`、`:7645`、`:6701`、`:10944`、`:11375`、`:11649`、`:8118`、`:8222`、`:3259`、`:2600`、`:1633` |
| `arkdeck-agentd --cutover-preflight [--hold-instance-lock]`：环境、退出码、输出字段、拒绝种类、快照 | `openspec/changes/chg-2026-074-shared-rust-runtime-core/evidence/runs/TASK-XPA-018/runtime-service-cutover-preflight-run.md:12-19`、`:35-77` |
| `loaderTransitionAwaitingBinding`、`retainedSessions`（#2255） | `rust/crates/arkdeck-agentd/src/cutover_preflight.rs:215-223`、`:247-253`；`rust/crates/arkdeck-cli/src/runtime_service_install.rs:673-695`、`:702-711`、`:727-733`；记录 `evidence/runs/TASK-XPA-017/cutover-preflight-legacy-refusals-run.md:18-35`、`:254-257` |
| Rust helper 发布构建与签名 | `Packages/ArkDeckKit/Distribution/macOS/build-helpers.sh:17-30`、`:88-121`；`package-rust-helpers.sh:83-136` |
| 发布包只读验收与维护者窗口命令 | `evidence/runs/TASK-XPA-017/rust-helper-packaging-run.md` §5、§6 |
| 结构检查（只适用于无签名产物） | `Packages/ArkDeckKit/Distribution/macOS/check-rust-helpers.py:35`、`:69-73`、`:305-345` |
| ArkForge 源码 pin | `rust/Cargo.toml:23-29`；`Packages/ArkDeckKit/Package.swift:46-48`；`rust/scripts/check-arkforge-pin.py` |
| ArkForge bundle manifest 校验 | `rust/crates/arkdeck-contract/src/arkforge_bundle.rs:295-296`、`:337` |
| GJ 跑法、固定事实、§6b、记录模板 | `docs/design/cli-golden-journey-headless-runbook.md` §0、§1–§6、§6b、§7 |
| XPA-AC-9 口径 | `openspec/changes/chg-2026-074-shared-rust-runtime-core/tasks.md:377`；`verification.md:43`、`:73`；design §G.4 |
| `runtime service` 各叶子的分派与选项白名单；`--control-request-id`/`--socket` 被拒 | `rust/crates/arkdeck-cli/src/lib.rs:865-870`、`:1358-1397`、`:949-956`；`runtime_service.rs:1715-1740` |
| `update` 的参数与保留规则、拒绝原文 | `runtime_service_install.rs:303-437`；`runtime_service.rs:967-987`、`:1664-1676` |
| `install()` 顺序：验签、探测、第一遍预检、目录、bootout、持锁一遍与快照、换 bundle、plist、回执、bootstrap | `runtime_service_install.rs:468-587`、`:593-670`、`:750-825`、`:992-1029`、`:1036-1066`、`:1071-1164`、`:1168-1196` |
| helper 签名要求（团队、identifier、钥匙串组、hardened runtime、embedded profile） | `rust/crates/arkdeck-platform/src/host_bundle_signature.rs:18-21`、`:336-414` |
| 预检块的 CLI 文案与 exit 75 | `runtime_service_install.rs:673-695`、`:697-736` |
| `status` 的判定、字段与退出码 | `runtime_service.rs:1011-1168`、`:459-493`、`:1424-1435` |
| `verify`：选项、重开校验、人工动作 exit 75 | `runtime_service.rs:1523-1612`、`:1645-1650`；`runtime_service_verify.rs:85-169`、`:1036-1089` |
| socket 对端只核 UID（macOS 不核可执行身份） | `rust/crates/arkdeck-platform/src/unix.rs:269` |
| bootstrap 的 EIO 重试与 `enable` | `runtime_service.rs:624-645`；`launchd.rs:60-62` |
| 预检模式：退出码、被拒组合输入、不写记录 | `rust/crates/arkdeck-agentd/src/cutover_preflight.rs:49-51`、`:53-56`、`:73-123`、`:176-197`、`:300-324`；`production.rs:78-116` |
| 共享状态表（阻断态、停放、终态、execution、capability use 词表） | `rust/crates/arkdeck-contract/src/job_state_preflight.rs:246-349`；`rust/tests/fixtures/job-state-preflight/table.json` |
| Rust daemon 启动时的 Loader 过渡（同一 target 两个及以上即启动失败） | `rust/crates/arkdeck-agentd/src/main.rs:716-724` |
| `flash bind-loader` 在 Rust CLI 上也已实现（`flash.bind-current-loader`） | `lib.rs:781`、`:1088`；`rust/crates/arkdeck-cli/src/flash_leaves.rs:79-102`；`rust/crates/arkdeck-control/src/lib.rs:1387-1400` |
| Rust CLI 签名叶子：`runtime signing status|remove` 及旧 `signing` 拼法；安装/迁移与更新时的凭据刷新仍未移植 | `rust/crates/arkdeck-cli/src/signing_leaves.rs`；`evidence/runs/TASK-XPA-018/signing-remove-run.md` |
| 窗口记录与 GJ 记录落点 | `openspec/changes/chg-2026-074-shared-rust-runtime-core/verification.md:76`；`docs/design/cross-platform/macos-chain-agent-prompt.md:516-522` |

## 附录 B. 需要维护者定的事项

窗口前必须裁决：

1. P2：#2255 已合入；判据之外、停在 Loader 过渡上的 parked Flash Job 仍会带进 Rust，同一 target 两个及以上会让 Rust
   daemon 启动失败。若 1a 读出这种情况，先处理还是接受，由维护者定。
2. P3/Q11：发布包是否公证；只签名不公证时 `build-local-helpers.sh` 还缺同样的 rust 开关（`rust-helper-packaging-run.md` §6 第 2 条）。
3. P4：20b Rust 基线是否为开窗条件。
4. P5：4h soak 是否要在窗口所用提交上重跑。
5. P6/S-1：签名写路径（S-1/S-2）；有签名预设的主机在 Rust 签名 owner 落地前 update 会被拒。
6. P7/F1/F2：ArkForge 摘要域修法、与 bundle 同步发布的方式；裁决前切换不换 ArkForge bundle、GJ-4 不开始。
7. P8：是否先发带 #2204/#2221/#2227 的 Swift 过渡版本；`$ROLLBACK` 用哪个构建。
8. P9：新 App 由谁安装、是否嵌入 helper / 发 DMG。
9. P10/Q6、P11/Q3：`REAL_DEVICE_PASS` 的环境口径；SPK-8 的执行环境。
10. 第 7 步：XPA-AC-9 回滚演练做不做、做到哪一层（tasks.md:377 与 verification.md:73 的口径差异）。

步骤中的 TBD（缺依据，维护者定或另派只读核实）：

11. 第 1 步 `pendingToolSelection`：已只读核实（`evidence/runs/TASK-XPA-017/cutover-runbook-appendix-b-run.md` 第 11 条）：没有「放弃」的已发布命令；待定选择由 Swift daemon
    下次启动自行结算，让它重启的已发布路径是 `runtime service restart`。待定：是否为此重启旧 Runtime。
12. 第 1 步 `retainedSessions`：已只读核实（同上，第 12 条）：`session cleanup apply` 不适用（有无法归属的内容时 cleanup
    整根拒绝），也没有移动它的已发布命令，只能手工移出 Session 根。待定：是否手工移出、移到哪里。
13. 第 2 步：「façade 保留一个周期」的截止日。
14. 第 4 步：SPK-8 正向的具体 UI 测试名与开关；负向用例与 harness；`FacadeRollbackUITests` 对 standalone Rust daemon 是否适用。
15. 第 7 步：`AgentXPCTransportContractTests` 黑盒子集对安装态 daemon 的运行方式。
16. 第 7 步与 P6：装有签名预设时 Rust CLI 的 update（含回滚、GJ-4 campaign staging）一律被拒；改用 Swift CLI 回滚是否可行、是否可接受。
17. 第 5 步 GJ-5：Rust CLI 没有装签名预设的叶子（S-1 前），预设由谁、用哪个 CLI 建立；若沿用切换前由 Swift 建的预设，
    又与 P6 的切换拒绝冲突。
18. 第 2 步在快照之后失败的中间态：已只读核实（`evidence/runs/TASK-XPA-017/cutover-runbook-appendix-b-run.md` 第 18 条）：快照写完之后确无自动恢复；本文给的处理（按 §4 第 3 行
    回到 `$ROLLBACK`）与源码一致，但没有测试覆盖从半途的安装态回退。待定：维护者是否认可这条回退路径。
19. 1a 手工预检：已只读核实（同上，第 19 条）：无锁那遍不取锁、不建目录或锁文件、不写任何 owner 数据；**会在 Job 索引旁
    创建或触碰 `-wal`/`-shm`，不改数据库内容**（有 `-shm` 时在其中记读标记；没有时新建空 `-wal` 与新 `-shm`）。待定：
    维护者是否接受这一点、是否认可在真实账户上这样跑；若要真正零写入（immutable 打开或先复制再读），是另一刀的设计取舍。
