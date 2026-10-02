# macOS Rust Runtime 切换窗口 runbook（G5 第 20c 刀）

> 状态：草案（2026-09-26 起草，未在真实主机上执行过）。Task：TASK-XPA-017（CHG-2026-074 M5）。
> 本文只写步骤，不代表任何一步已经执行、已被批准或已通过。源码位置以 `main` `5d42490da`（#2257，已含 #2255 = `8acfe6900`）
> 为准；
> 签名安装与身份刷新条目已按 `main` `8cdcb78c2`（#2272）复核；其余行号可能随后续合入移动，窗口前按附录 A 复核一遍。

维护者在一个切换窗口里照本文逐步执行：把安装态的 Swift Runtime（Swift daemon + Rust façade 对）换成
standalone Rust daemon，然后做正式验收。本文不另立验收规则，真机验收照
[验收指南](../../../scripts/agent-guides/acceptance.md) 与
[headless GJ runbook](../cli-golden-journey-headless-runbook.md) 执行；安全边界照 `AGENTS.md`
「Agent 禁令与设备执行边界」与 Constitution（`POL-AGENT-002`、`POL-RECOVERY-001`）。
两者与本文冲突时以它们为准，并把冲突写进窗口记录。

凡源码里找不到依据的命令或参数，本文一律写成「TBD（维护者定）」并说明缺什么，不作为确定命令。

## 维护者 2026-09-28 裁决（优先于下文各处的旧写法）

维护者 2026-09-28 裁决了附录 B 的开窗前事项；下文与本节冲突之处以本节为准。

| 事项 | 裁决 | 对本文的影响 |
|---|---|---|
| P3 / Q11：发布包是否公证 | 需要 | 取代 09-24 受托裁决 Q11。App、Rust helper 对、ArkForge.bundle 与 DMG 全部 Developer ID 签名、hardened runtime、timestamp，经 `notarytool` 公证并 staple；签名与公证由维护者用自己的凭据执行。P3 的 `stapler validate` 与 `spctl` 从「仅在要求公证时」改为必做。 |
| P4 / P5：Rust 性能基线、4h soak 是否为开窗条件 | 都不是 | 不因基线或 soak 推迟开窗；不在窗口所用提交上重跑 soak。 |
| P7：ArkForge 摘要域 F1/F2 | 交 Agent 决定（无发布版本） | 决定：跟随 pinned ArkForge（`c1dc0553b42627581583abfba3fec34d13343282`）的 `arkforge/v1/usb-topology\0` 与 `arkforge/v1/admission-device-facts\0`，退役的 `device-facts` 域不保留、不做兼容。切换时**改用发布包里由同一 pin 构建的 ArkForge.bundle**（先复制出 DMG 到稳定路径，再显式传 `--arkforge-bundle`），不再沿用 live plist 的旧 bundle；故障恢复时显式传入留存的旧 bundle 路径（§4），update 不保留旧 plist。 |
| P8：Swift 过渡版本与回滚包 | 都不需要 | 不发 Swift 过渡版，不另建 Swift 回滚构建。`$ROLLBACK` = 首次切换前由维护者 `ditto` 留存的安装态 helper（façade + Swift daemon）；`runtime service update` 另会把被替换的一代留在 `Helpers/.rollback`（`runtime_service_install.rs:1056-1091`，路径写进回执的 `cutover.rollbackBundlePath`，`:590-594`）。留存到 G5 报告为止（第 13 条）。 |
| P9：新 App 的交付方式 | 发 DMG | DMG 含 `ArkDeck.app`、`ArkDeckCLI.app`（内含 Rust daemon helper）与 ArkForge.bundle；App 与 helper 同一版本号。 |
| P10 / Q6、P11 / Q3：`REAL_DEVICE_PASS` 与 SPK-8 的环境 | 所有软件完成后，最后做真机验收 | 只有在阶段 S（全部软件，含删除 Swift runtime/CLI 与 façade，设计 r10 路线 C）完成、用公证发布候选版切换后的安装态纯 Rust daemon + Rust CLI 上的结果才算；SPK-8 在切换后的本机上做。开发根上的真机证据不计数。 |

据此，附录 B 其余各条按以下口径处理（维护者可随时改）：

- 第 1 条（P2）：同一 target 上两个及以上停在 Loader 过渡的 parked Flash Job 会让 Rust daemon 起不来；由切换预检提前拒绝（软件侧已由 #2302 补齐：`loaderTransitionsCoverTarget`），不在窗口里现场处理。
- 第 10 条：第 7 步回滚演练**不执行**。依据 `verification.md:73` 的 XPA-AC-9「no same-release Swift rollback」与 `:43-46` 的 r11 解释；临时 home 下的显式回滚已由 #2268 覆盖。`$ROLLBACK` 只在切换失败时按 §4 使用。
- 第 13 条：façade/Swift helper 保留到 G5 报告为止。
- 第 14、15 条：SPK-8 正向用 `FacadeRollbackUITests/testInstalledPureRustHistoryFilterRoundTrip`（开关见 `scripts/ci/installed-rust-ui.md:17-32`）；两个负向用例已由 TASK-XPA-019 补齐为 `scripts/ci/installed_spk8_negatives.py foreign-client|version-mismatch`（开关与判据见 `scripts/ci/installed-rust-ui.md`「SPK-8 negative cases」，命令见第 4 步）；`AgentXPCTransportContractTests` 是进程内测试，不能对安装态 daemon 黑盒运行，随 Swift target 删除，黑盒职责由 Rust 控制面黑盒测试与这两个负例承担。
- 第 19 条：接受手工预检在 Job 索引旁创建或触碰 `-wal`/`-shm`（数据库字节不变），不另做零写入打开。
- 删除 Swift target、Swift CLI 与 façade（原第 20d 刀）改在开窗**之前**完成；窗口里的 `$OLD_ARKDECK` 是当前安装态的 Swift CLI 二进制，不依赖源码。
- 历史记录提示（须由当前只读预检确认，不能据旧标签判断现状）：保留的 Session `2026/08/rockchip-session-42f8e86d-8cbf-4aa0-a411-5e1624e9f291` 无 Manifest、含未决的历史 Loader 过渡（`evidence/runs/TASK-XPA-017/historical-hap-step-digest-run.md:130-136`），预检会以 `retainedSessions` 拒绝；它涉及未知副作用，只能按 `POL-RECOVERY-001` 推进或由维护者裁决，窗口前先读一次 1a 预检确认。

## 0. 约定

### 0.1 执行者

| 标记 | 谁 | 允许做什么 |
|---|---|---|
| 【维护者】 | 维护者本人 | 一切改动安装态的动作：`runtime service update`（内部会 `launchctl bootout/bootstrap`）、手工 `launchctl`、Developer ID 签名与公证、安排最终验收窗口及尚未裁决的事项 |
| 【协调会话】 | Claude 协调会话 | 只读核实（git、源码、已提交记录）、比对输出、整理窗口记录；不改安装态、不跑 launchctl、不做设备 mutation |
| 【Agent】 | 被派的子代理 | 同协调会话；另可在窗口后按记录起草 evidence 文件的 PR |

Agent 与协调会话在窗口内**不执行**任何 `runtime service update|install|uninstall|restart`、`launchctl`，
本轮不执行设备 `agent run`；最终窗口按第 5 步与现行 Runtime authority 执行，不另设聊天确认。任何执行者都不改 trusted facts、capability、reservation、evidence
记录（`AGENTS.md`「Agent 禁令与设备执行边界」）。本文里凡是这些命令，执行者一律是【维护者】。

### 0.2 变量

下文命令用这些变量，窗口开始时由【维护者】在自己的 shell 里设好：

```sh
RUST_OUT=<从 RC DMG 装好的 ArkDeckCLI.app 所在目录（绝对路径）>  # 例如 /Applications；RC 由 scripts/release/build_macos_release.py 产出
ARKDECK="$RUST_OUT/ArkDeckCLI.app/Contents/MacOS/arkdeck"            # Rust CLI
HELPER="$RUST_OUT/ArkDeckCLI.app/Contents/Helpers/ArkDeckAgent.app"  # Rust daemon bundle
ROLLBACK=<首次切换前维护者 ditto 留存的安装态 helper>                 # Swift daemon + façade；见文首裁决节 P8
OLD_ARKDECK=<当前安装态配套的 Swift CLI>          # 例如 Toolchains/arkdeck-helpers-main-<sha>/ArkDeckCLI.app/Contents/MacOS/arkdeck
FORGE=<从最终 RC 复制到稳定版本目录的 ArkForge.bundle 绝对路径>
ROLLBACK_FORGE=<切换前 ArkForge.bundle 的稳定路径或 none>
ROLLBACK_TRACE=<切换前 ArkTrace descriptor 的绝对路径或 none>
HDC=<当前已验证 HDC 的绝对路径>                    # 从切换前的 runtime hdc status 的 executablePath 读
OUT=/private/tmp/arkdeck-cutover-<YYYYMMDD>        # 原始输出目录，不入仓
SUPPORT="$HOME/Library/Application Support/ArkDeck"
```

DMG 布局与安装步骤见 `docs/release/macos-install.md`；helper 对由 `build-helpers.sh` 的 Rust 模式经
`package-rust-helpers.sh` 布局，2026-09-28 起不再带 `rollback/ArkDeckAgent.app`（P8 裁决）。

### 0.3 输出与停止

- 每条命令的 stdout 原样存 `$OUT/<NN>-<step>.json`，stderr 存同名 `.err`，退出码写进窗口记录。
  这是输出目录，不是新的 Runtime state 目录。
- 「失败即停」：该步的停止判据命中时，不进入下一步，按该步「失败时」与 §4 处理，并在窗口记录里写明。
- 任何 `outcomeUnknown` / `reconcileRequired` / 真实设备不确定状态：只读回（`job show/evidence`、
  `job reconcile --job <id>` 的独立读回），**不重放、不为了消掉它而回滚或换 state 目录**（design §G.4、
  `AGENTS.md`）。

## 1. 目的与范围

软件收尾、相关 CI 和最终签名 RC 检查完成后，才由维护者进入本窗口；本轮软件准备不执行以下步骤：

1. §G.4 切换预检（两遍）并记录快照摘要；
2. LaunchAgent 改指向 standalone Rust daemon（`main.rs` 第三种模式，production 组合），被替换的
   Swift helper（Swift daemon + façade）保留一个周期作回滚；
3. `runtime service verify`；
4. 签名 App ↔ Rust Mach service 的正向与负向验收（SPK-8）；
5. 在当前 Catalog digest 上用 Rust CLI 跑完整 headless runbook，按真实结果记录 GJ-1…GJ-5；
   GJ-4 仅依现行 `POL-AGENT-002` / `POL-RECOVERY-001` Runtime authority 与安全规则执行，
   人工确认不能替代或扩大准入证明；
6. App 呈现检查（headless runbook §6b）；
7. 保存实际验收记录与必要发布状态；按文首裁决，不做同 release Swift 回滚演练。

不在本窗口内做：

- Swift target、Swift CLI、旧 façade 的删除与软件/打包验证：这些必须在窗口前完成，已合并的迁移不重做；
- Developer ID 签名与公证本身（第 20a 刀的发布动作，由维护者在窗口前完成，见 §2 P3）；
- Rust 性能基线或 soak 重跑：文首裁决已取消其开窗前置地位；
- Swift 过渡版本或新的 Swift 回滚构建：不发布，保留切换前真实安装包；
- 任何 capability、trusted facts、reservation、hardware evidence 的手工创建或修改；
- Windows。

## 2. 前置条件清单

每条都要在窗口开始前核实并把结果写进窗口记录。标「窗口前必须由维护者裁决」的，本文不替维护者下结论；
未裁决即不开窗口（或只开不依赖它的部分，并在记录里写明）。

| # | 条件 | 如何核实 | 状态 |
|---|---|---|---|
| P1 | 切换所需 PR 已合入 protected `main`：production 组合 #2136/#2137、`runtime service status/verify --job/restart` #2141、§G.4 预检 #2142、`update/install/uninstall` 与无 `--job` 的 `verify` #2143、Rust `--analyze-crash-ledger` #2144、Bootstrap 注册表 #2216/#2217、Rust helper 打包 #2218、entitlements 口径 #2219、App 脱离 `ArkDeckWorkflows` #2139；GJ-4 用到的 M4 Flash 链（含 `flash install-binding` #2245、执行授权 #2252 等） | 【协调会话】`git fetch origin main && git log --oneline origin/main \| grep -E '\(#(2136\|2137\|2139\|2141\|2142\|2143\|2144\|2216\|2217\|2218\|2219\|2245\|2252\|2255)\)'`，逐条命中；M4 其余 PR 以 `evidence/macos-remaining.md` 仪表盘 M4 行为准 | 起草时列出的 14 个 PR 均已在 `main`（#2136 `51f8009df`、#2137 `86ea4d839`、#2139 `1267e465d`、#2141 `5b1df34ee`、#2142 `d41cc1fb1`、#2143 `527459240`、#2144 `ae404cc5c`、#2216 `c3c120513`、#2217 `3315a9cba`、#2218 `1dbe5acd0`、#2219 `167783bb1`、#2245 `61d95b10d`、#2252 `f9d6cac06`、#2255 `8acfe6900`）；窗口前按此重核，并补上之后合入的 M4/CLI 车道 PR |
| P2 | #2255（S36：预检的 `loaderTransitionAwaitingBinding` 与 `retainedSessions` 两条拒绝）与 #2302（TASK-XPA-017 S3：`loaderTransitionsCoverTarget`）已合入 | 同上 grep `(#2255)`、`(#2302)` | #2255 已合入（`8acfe6900`），#2302 已合入（`092b45eb8`）。#2255 那条拒绝只拦 Swift 的 `bind-current-loader` 能结算的那一类（判据见其 run 记录 :79-86）；判据之外、停在 Loader 过渡上的 parked Flash Job 照旧原样带进 Rust，Rust daemon 启动时对单个这种过渡只打印一行「Loader transition … awaits settlement … its outcome stays unknown」并继续（`rust/crates/arkdeck-agentd/src/main.rs:385-395`，`rust/crates/arkdeck-hoststore/src/rockchip_startup.rs:86-90`）。**同一 target 上两个及以上会让 Rust daemon 起不来**（`rockchip_startup.rs:69-97`）的那一类，已由 #2302 的预检块 `loaderTransitionsCoverTarget` 按记录级谓词在切换前拒绝（exit 75，零改动，点名 Job；见第 1 步拒绝表与 `evidence/runs/TASK-XPA-017/preflight-loader-transitions-run.md`），不再需要窗口前逐个 `job show` 手工核对。被拒时照第 1 步表中该行处理 |
| P3 | RC：优先由版本变更合入 protected `main` 触发既有 `release-rc.yml`；从**窗口所用 `main` 提交**构建、Developer ID 签名、公证并 staple 的 DMG（App、Rust helper 对、ArkForge.bundle；`docs/release/macos-install.md`），附 `release-receipt.json` | 【维护者】构建命令与只读验收命令照 `evidence/runs/TASK-XPA-017/rust-helper-packaging-run.md` §5：`codesign --verify --strict --deep`、`codesign -dv`（Identifier `com.arkdeck.agentd`、Team `8AQTYW5FKR`、hardened runtime、有 Timestamp）、`-R` 要求、`codesign -d --entitlements`（恰为 `ArkDeckAgent.entitlements` 三键，#2219）、`stapler validate` 与 `spctl`（必做；脚本在挂载的 DMG 上已跑一遍，receipt 记公证 submission id）、以及临时 home + 记录型 launchctl 下的 `runtime service update` 自检。注意 `check-rust-helpers.py` **只检查无签名的结构产物**（要求 ad hoc 签名与 `UNSIGNED-STRUCTURE-CHECK-ONLY.txt`），对签名发布包必然失败，不能当发布验收 | 维护者执行；Q11 已由 2026-09-28 裁决取代：必须公证（文首裁决节） |
| P4 | Rust 性能基线 | 非开窗前置条件 | 2026-09-28 已决；不补跑已取消的前置门 |
| P5 | 4h soak | 既有 run `36130214960` 仅保留历史结果 | 2026-09-28 已决；不要求在窗口所用提交上重跑 |
| P6 | 签名 S-1/S-2 裁决与安装态签名预设 | 【维护者】只读检查 `test -e "$SUPPORT/Signing/OpenHarmony/preset-v1.json" && echo present`；`"$ARKDECK" runtime signing status --output json`。Rust CLI 已有凭据 owner；`install/update` 在任何安装改动前验证预设公开材料，在已安装 helper 验签后、bootstrap 前持锁刷新 daemon 指纹。缺失 envelope 或不能证明 helper 身份时刷新失败；不可读 envelope 不阻止仅写公开指纹，实际签名仍须读到 secret | 不再因存在预设而一律拒绝；无效材料仍 exit 69 且安装态不变，刷新失败则按 Swift 行为尝试启动已验证的新 helper 后 exit 1；恢复启动也失败时服务停着并报告两项错误，按下文失败阶段处理。`status|remove|install|migrate-deveco|install-sdk-release` 与身份刷新已有隔离测试；签名替换发布结果未知时保留 `replacingSecrets`/`removingSecrets` 与 pending account 跟踪，Rust/旧 Swift 均拒绝自动恢复；须通过 Rust 显式安装或移除恢复，不能删除 ledger 强制采用。SDK release 材料发布失败也保留有界目录跟踪并显式收尾；S-1/S-2 与真实 Keychain/GJ-5 验收仍待完成。见 `evidence/runs/TASK-XPA-017/signing-identity-refresh-run.md`；本项不构成安装窗口或设备操作批准 |
| P7 | F1/F2（ArkForge 摘要域）与随包 `arkforged` 版本一致 | 已由 #2303（`e2f96a29b`）修复：Rust 改用 pinned `arkforge_core` 的 `Domain::UsbTopology` 与 `Domain::AdmissionDeviceFacts`（`rust/crates/arkdeck-provider-arkforge/src/loader.rs:38`、`authority.rs:428`），固定向量测试 `rust/crates/arkdeck-provider-arkforge/tests/digest_domain_vectors.rs`；Swift 的 `ArkForgeObservationSelection.swift`、`ArkForgeExecutionAuthority.swift` 同车改成新域；退役的 `arkforge/v1/device-facts` 域不保留（`evidence/runs/TASK-XPA-017/arkforge-digest-domains-run.md`）。源码 pin 为 `c1dc0553…`（`rust/Cargo.toml` 的 `arkforge-*` 行；`Packages/ArkDeckKit/Package.swift:46-48`）。**仓内没有 `arkforged` 二进制或版本的 pin**：daemon 用的是 `--arkforge-bundle` 指向的 `ArkForge.bundle`（`Contents/MacOS/arkforged`，manifest `version` 非空，`rust/crates/arkdeck-contract/src/arkforge_bundle.rs:295-296`、`:337`）。【维护者】用 RC DMG 里由同一 pin 构建的 bundle（`release-receipt.json` 的 `arkforge.builtRevision` 等于 pin），先复制出 DMG 再传路径 | 2026-09-28 已决（文首裁决节）并已实现。旧 bundle（如 `3f5b48cd` 编出、仍是 device-facts 域）与新 ArkDeck 不一致，Flash 选择与准入会 fail closed，切换时不得沿用 |
| P8 | 保留切换前真实安装态 App、CLI、helper 与配套依赖 | 按 §4 离线核对来源、摘要、身份和旧版本的 state 兼容性 | 2026-09-28 已决：不发 Swift 过渡版、不另建回滚包。若旧 helper 不含 #2204 且已有相应墓碑，不能通过删记录让回滚通过 |
| P9 | 新 App：脱离 `ArkDeckWorkflows` 的签名 App 构建已安装，版本与 helper 同一 release | 【维护者】App 的 `MARKETING_VERSION`/`CURRENT_PROJECT_VERSION` 与 helper Info.plist 一致（`check-rust-helpers.py:157-162` 对结构产物比的就是这对值）；App 与 daemon 同 release 才配对 | 2026-09-28 已决：发公证 DMG，由维护者在最终窗口安装 |
| P10 | 当前 Catalog digest 上的安装态纯 Rust GJ-1～5 | 第 5 步与验收指南 | 2026-09-28 已决；软件和 RC 完成之后才执行，不把先前开发根或模拟结果计入 |
| P11 | SPK-8 正向、负向及 App 呈现 | 第 4 步的已签名 App 与安装态 Rust daemon | 2026-09-28 已决：在最终切换后的本机执行 |
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
  （`rust/crates/arkdeck-cli/src/runtime_service_install.rs:775-793`）；被拒的组合输入清单见
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
over as it is (<各块文案，以「; 」连接>); nothing was changed`（`runtime_service_install.rs:682-704`，各块文案
`:706-762`，例如 `Job <id> is <state>`、`Job <id> has an unresolved journal`、`agent execution <id> is <state>`、
`capability <id> use <n> of Job <id> is unsettled`、`HDC tool selection <id> is pending`、`<source> is unreadable: <reason>`）。

| `kind` | 含义 | 处理（执行者均为【维护者】，经已发布 CLI 面） |
|---|---|---|
| `jobState` {`jobId`,`state`} | Job 处于 13 个阻断态之一（`queued`、`preflight`、`running`、`waitingForDevice`、`awaitingRebindConfirmation`、`planning`、`cancelRequested`、`cancellingAtSafeBoundary`、`reconciling`、`recoveringByCompleteOverwrite`、`resumeAtConfirmedSafeBoundary`、`userAbandonRequested`、`finalizing`）或不在状态表里（含本读者自己的 `unreadableRecord`/`missingRecord`） | 在旧 Runtime 上让它走到终态或停放态：`"$OLD_ARKDECK" job wait --job <id> --output json`；等人工动作的走 `human-action show --human-action <id>` → `agent resume --resume-reference <ref>`；确需取消的用 `job cancel --job <id>`，是否取消由维护者判断（选项见 `rust/crates/arkdeck-cli/src/command_registry.json` 的 `job wait` :6701、`human-action show` :11649、`agent resume` :11375、`job cancel` :7350）。`unreadableRecord`/`missingRecord`：**停止**，不删不改，交协调会话只读排查 |
| `unresolvedJournal` {`jobId`} | 非停放 Job 的 journal 有未决 intent、unknown outcome、torn 尾或无法回放 | 让该 Job 在旧 Runtime 上结束（同上）；torn 尾或无法回放的：**停止**，不手改 journal，交协调会话排查，必要时维护者裁决 |
| `activeAgentExecution` {`executionId`,`state`} | 有活跃的 agent execution（被停放/终态 Job 名下的 `jobOwned` 除外） | `"$OLD_ARKDECK" agent status --execution-id <id> --output json`（`command_registry.json:10944`）读状态，按其 `nextAction` 走完（等待、`agent resume`）；不从外部改 execution 记录 |
| `unsettledCapabilityUse` {`capabilityId`,`useOrdinal`,`jobId`} | capability use 的 outcome 是 `pending` 或不在表里 | 让所属 Job 结算（同 `jobState`）；**不手工 settle、不删 ledger** |
| `pendingToolSelection` {`controlActionId`} | `Bootstrap/v1/tools.json` 有待定的 HDC 工具选择 | 没有「放弃待定选择」的已发布命令（核实见 `evidence/runs/TASK-XPA-017/cutover-runbook-appendix-b-run.md` 第 11 条）。待定选择只由 Swift daemon 自己结算：下一次启动时，所选 HDC 起得来就发布，起不来就判失败并回到原工具（`Packages/ArkDeckKit/Sources/ArkDeckAgentDaemonMain/main.swift:474-545`，只在配置了 HDC 时）。选择流程本身会让 daemon 重启，无锁那遍可能正好读到这个窗口，重启后即消失。持续存在时，让旧 daemon 再启动一次的已发布路径是 `"$OLD_ARKDECK" runtime service restart --output json`（`command_registry.json:1020`；有活动或未收尾的 Job 时 exit 75 拒绝）；之后 `"$OLD_ARKDECK" control-action reconcile --control-action <controlActionId> --output json`（`:12156`）结算该控制动作的记录（预检只读 `tools.json` 的待定项）。是否为此重启旧 Runtime，**维护者定** |
| `unreadable` {`source`,`reason`} | 某个来源读不了（`jobs`、`jobIndex`、`agentExecutions`、`capabilities`、`toolSelection`、`stateDirectory`、`instanceLock`、`snapshot`；#2255 起还有 `sessionStorage`） | **停止**。不删不改，交协调会话只读排查，维护者裁决 |
| `runtimeRunning` {`reason`} | 只在持锁那一遍出现：别的进程持有 `Agentd/instance.lock` | 第 2 步的 update 在「只因 runtimeRunning 被拒」时自己按 poll 间隔重问，最多 50 次，约 5 s（`runtime_service_install.rs:88`、`:635-657`）；仍拒则说明 bootout 后仍有进程持锁：**停止**，旧服务会被原样 bootstrap 回来（见第 2 步失败语义） |
| `loaderTransitionAwaitingBinding` {`jobId`,`targetId`,`expectedBindingRevision`}（#2255） | 一个从未被 ArkForge lane 驱动过的停放 DAYU200 Flash Job，其记录与 journal 恰好停在 Swift 的 `flash.bind-current-loader` 能结算的「进入 Loader」过渡上；Rust Runtime 不移植该结算（F7） | 板子接好并处于 **Loader** 时，在**旧 Swift Runtime** 上执行 `"$OLD_ARKDECK" flash bind-loader --target <targetId> --expected-binding-revision <expectedBindingRevision> --output json`（两个选项均必填，`command_registry.json:20059`；拒绝文案原文在 `rust/crates/arkdeck-cli/src/runtime_service_install.rs:711-720`），然后重跑 1a。bind-loader 被拒：**停止**，保留该 Job 与拒绝原文，交维护者裁决；不用 `--rebind` 覆盖缺失的身份/lineage 证明 |
| `loaderTransitionsCoverTarget` {`targetId`,`expectedBindingRevision`,`jobIds`}（TASK-XPA-017 S3） | 两个及以上 Job 的记录（索引行或 `job-record.json`）都把 DAYU200 Flash 停在同一 target、同一 binding revision 的「进入 Loader」过渡上（`waitingForRecovery`、`outcomeUnknown`、recovery step 为 `enter-loader-mode`），不看 journal、不论是否由 ArkForge lane 驱动。Rust daemon 启动时正按这个记录级谓词计数（`rust/crates/arkdeck-hoststore/src/job_owner.rs:110-122`、`:593-611`），Loader binding 把该 target 推过这个 revision 时两个及以上即拒绝启动（`jobNotRunnable("multiple unresolved Loader transitions cover target …")`，`rust/crates/arkdeck-hoststore/src/rockchip_startup.rs:69-97`），launchd 会让它崩溃循环；binding 可能在切换后才发布，所以预检只按记录判，不看当前 binding（判据 `rust/crates/arkdeck-hoststore/src/cutover_facts.rs` `record_candidate`；文案 `rust/crates/arkdeck-cli/src/runtime_service_install.rs:721-736`） | **停止**。这些 Job 的 outcome 未知，永不 replay；Swift 的 `flash bind-loader` 遇到同一 target 的多个过渡同样拒绝（`jobNotRunnable`），不能靠它结算。不手改记录或 journal、不删 Job 目录；保留 `jobIds` 与拒绝原文，交维护者裁决（只能按 `POL-RECOVERY-001` 推进或由维护者定处理方式），然后重跑 1a |
| `retainedSessions` {`sessionsRoot`,`code`,`message`}（#2255） | 保留的 Session（默认 `Sessions` 根，以及 `Agentd/session-storage.json` 选中的根）会被设备 mutation 的连续性证明拒绝，`code`/`message` 即该证明自己的码与原话（`recordUnreadable`；`rust/crates/arkdeck-hoststore/src/mutation_state_continuity.rs:196-201`、`:214-219`） | 被拒的 Session 由这一块的 `message` 点名（`retained Session <yyyy/mm/名称> …`）。`"$OLD_ARKDECK" runtime storage status --output json`（无其他选项，`command_registry.json:3259`）只给 `usage.unaccountedSessionCount` 计数、不点名（`message` 里说 status 会点名，实际只计数）；`session cleanup preview --output json`（`:8118`）遇到这种无法归属的内容会整根拒绝（`operationUnavailable`「Session catalog contains unaccounted content: …」），在拒绝原文里点名。所以 `session cleanup apply`（`:8222`，须先有 preview）移除不了它，也没有移动或删除它的已发布命令（核实见 `evidence/runs/TASK-XPA-017/cutover-runbook-appendix-b-run.md` 第 12 条）。审阅后是否手工移出 Session 根、移到哪里，**维护者定**。第一遍无锁，Swift 正在原地发布的 Session 可能被一时点名，重跑即消失 |

**1b update 内部的两遍（第 2 步自动执行，这里只说明）**：Rust CLI 的 `runtime service update` 在装 Rust daemon
时先跑一遍无锁预检（不 clear → exit 75，零改动），然后 bootout，再持 `Agentd/instance.lock` 跑一遍并在读事实之前
先拍快照（不 clear 或快照不是持锁拍的 → 原样 bootstrap 旧 plist）；持锁这一遍才是「state 已静止」的证明，
无锁那遍只是提示（run 记录 :12-19、:124-125）。快照摘要写到
`$SUPPORT/LaunchAgent/cutover-snapshots/cutover-<takenAtUtc 的字母数字>-<rootSha256 前 12 位>.json`（canonical JSON、0600、
只新建；同名但内容不同即拒 `another cutover snapshot already holds <path>`，`runtime_service_install.rs:1017-1054`）。
快照是逐文件的大小与 SHA-256 清单加根摘要 `rootSha256`，不是 state 的拷贝（`cutover_preflight.rs:300-324`）。
Swift 安装包（Rust→Swift 回滚）不走这两遍：新 helper 的 daemon 以 `unknown argument` exit 64 回答时即判为 Swift，
不再有任何预检门（`runtime_service_install.rs:837`、`:481-482`）。

### 第 2 步：LaunchAgent 改指向 Rust，façade 保留一个周期（约 5 分钟）

- 执行者：【维护者】本人。该命令内部会对 `gui/<uid>/com.arkdeck.agentd` 执行 `launchctl bootout` 与
  `bootstrap`（`/bin/launchctl`，参数数组见 `rust/crates/arkdeck-platform/src/launchd.rs:23-56`），属于安装态操作。
- 前提：第 1 步两遍 1a 都 `clear: true`；P6 已放行（无签名预设或 S-1 已落地）；按 2026-09-28 的 P7 决定，
  显式传 `--arkforge-bundle <发布包 ArkForge.bundle 的稳定路径>`，不再沿用 live plist 的旧 bundle。
  RC App 已装好时，先跑第 4 步的 SPK-8 负向 (b)（`version-mismatch`）：update 之后就没有自然的版本不匹配了。
- 命令（用 **Rust CLI**；Swift CLI 的 update 不做预检、不写快照、不留 `.rollback`，不得用于切换）：

  ```sh
  "$ARKDECK" runtime service update --daemon "$HELPER" --hdc "$HDC" \
    --arktrace-descriptor <现值的绝对路径或 none> --arkforge-bundle "$FORGE" --output json \
    > "$OUT/02-update.json" 2> "$OUT/02-update.err"; echo "exit=$?"
  ```

  选项的取值规则（`rust/crates/arkdeck-cli/src/runtime_service_install.rs:304-438`；没有 `--dry-run`、`--plist`）：
  - `--daemon`：显式给 `$HELPER`。省略时取 CLI 所在 `.app` 的 `Contents/Helpers/ArkDeckAgent.app`
    （`runtime_service.rs:1664-1676`），与 headless runbook「显式固定已发布 helper」的要求不符，不省略。
  - `--hdc`：显式给 `$HDC`；省略时沿用已安装的 `hdcPath`（`:321-329`）。
  - `--arktrace-descriptor`：省略时只有 live plist 与 descriptor 字节仍和 receipt 一致才沿用，否则 exit 1
    「ArkTrace distribution descriptor drifted since installation; pass --arktrace-descriptor explicitly …」
    （`:375-387`；`runtime_service.rs:967-987`）。从第 0 步 `status` 的 `launchAgent.arkTraceDescriptor` 读现值显式传入，
    没有就传 `none`。
  - `--arkforge-bundle` / `--arkforge-campaign`：都省略时沿用 live plist 的 ArkForge lane（`:399-427`）；按 P7 本次切换不省略，显式传 RC 的 bundle；
    `--arkforge-campaign` 必须同时显式给 `--arkforge-bundle`（`:418-422`）。
  - `--workspace-project` / `--deveco-sdk`：`runtime service` 拼写不沿用已安装的这一对（`:335-360`）；它们是旧版注入，
    按 headless runbook §1 省略。`--sensitive-evidence`、`--harness-*`、`--arkforged*`、`--arkforge-profile` 一律按名拒。
- 预期：exit 0；stdout 的回执带 `cutover` 成员：`snapshotPath`、`snapshotRootSha256`、`carriedOver`、`rollbackBundlePath`
  （`runtime_service_install.rs:590-594`、`:673-678`）。`cutover` **只出现在这次 stdout 里**，不写进磁盘上的
  `install-receipt.json`（`:561-572`），所以 `02-update.json` 必须保存；`$SUPPORT/Helpers/.rollback/ArkDeckAgent.app` 是被替换的 Swift helper；新 plist 的
  `ProgramArguments` 指向 `Helpers/ArkDeckAgent.app/Contents/MacOS/arkdeck-agentd`（无 façade 时选 daemon 本身，
  `runtime_service.rs:673-685`），环境里多了 `ARKDECK_RUNTIME_COMPOSITION=production`
  （`runtime_service_install.rs:1153-1155`），`MachServices` 仍是 `com.arkdeck.agentd`。
- 核对（【维护者】执行只读命令，【协调会话】比对）：

  ```sh
  plutil -p ~/Library/LaunchAgents/com.arkdeck.agentd.plist > "$OUT/02-plist-after.txt"
  shasum -a 256 "$HELPER/Contents/MacOS/arkdeck-agentd" "$SUPPORT/Helpers/ArkDeckAgent.app/Contents/MacOS/arkdeck-agentd"
  ls "$SUPPORT/Helpers/.rollback/ArkDeckAgent.app/Contents/MacOS/"      # 应见 arkdeck-agentd 与 arkdeck-facade
  ls -l "$SUPPORT/LaunchAgent/cutover-snapshots/"
  ```

- 停止判据：exit 非 0；或 exit 0 但回执没有 `cutover`（说明新 helper 被判成了 Swift）、`rollbackBundlePath` 为空、
  plist 仍指向 `arkdeck-facade`。
- 失败时，先按退出码与 stderr 判断安装态处在哪一段（`install()` 的顺序见 `runtime_service_install.rs:461-596`）：

  | 阶段 | 典型退出与原文 | 安装态 | 做什么 |
  |---|---|---|---|
  | 参数、签名预设、源 bundle 验签、分析器探测、façade 门、第一遍预检 | 64（参数）；69「… signing preset cannot be validated for identity refresh …」；1（验签，`host_bundle_signature.rs:19` 的要求）；69「… does not answer --analyze-crash-ledger …」（`:484-499`）；69「a Rust daemon bundle carries no facade」（`:500-508`）；69 预检探测错误（`:775-850`）；75「… nothing was changed」 | 未改动，旧服务照常运行 | 按原文处理后重跑第 1、2 步，或关窗口 |
  | bootout 之后的持锁一遍（`:602-679`） | 75「… the state was left as it is」或 69「the helper's daemon stopped answering the cutover preflight」「the held cutover preflight answered no snapshot taken under the instance lock」，并带后缀「; the previous service was started again from its unchanged plist」或「; starting the previous service again failed: …」（`:608-634`） | 前一种后缀：旧服务已从未改的 plist 重新 bootstrap；后一种：**旧服务停着** | 前者同上一行；后者由【维护者】`launchctl bootstrap gui/$(id -u) ~/Library/LaunchAgents/com.arkdeck.agentd.plist` 拉起旧服务（plist 未改），再用第 0 步的命令核对 |
  | 签名身份刷新失败 | exit 1，先尝试 bootstrap 已验证的新 helper 再报告刷新错误；启动也失败时包含 `credential refresh failed (…)` 和 `replacement daemon recovery failed (…)` | 恢复启动成功则只读 Runtime 已恢复，但签名仍按凭据校验拒绝；恢复启动失败则服务停着 | 核对服务状态和两项错误，修复签名材料或明确回滚；不能把启动成功当作签名验收 |
  | 快照写完之后的其他失败：换 bundle、写 plist/回执、bootstrap（`:537-589`；换 bundle 见 `:1056-1091`） | exit 1，原文即底层错误；**没有自动恢复**：快照写入及之前的失败会从未改的 plist 拉起旧服务（`:608-634`），之后的各步没有（核实见 `evidence/runs/TASK-XPA-017/cutover-runbook-appendix-b-run.md` 第 18 条） | 旧服务已 bootout、未运行。视失败的那一步：已装的 helper 未换（旧的）或已换成 Rust；被换下的 helper 在 `.rollback/ArkDeckAgent.app`，若失败发生在对换之后、移入 `.rollback` 之前，则留在 `Helpers/.arkdeck-agentd-<UUID>.app`；plist 与回执都未改、只改了 plist，或都已改 | **停止**。【维护者】只读核对 `Helpers/ArkDeckAgent.app`、`.rollback/` 与有无 `Helpers/.arkdeck-agentd-*.app` 里各是哪个 helper（有无 `arkdeck-facade`）、plist 的 `ProgramArguments`，【协调会话】比对；然后按 §4 第 3 行处理，不手改 state |
- façade 保留一个周期：`$SUPPORT/Helpers/.rollback/ArkDeckAgent.app` 与 `$ROLLBACK` 都不删。「一个周期」到哪天
  结束 **TBD（维护者定）**；在 20d 删除 Swift target 之前不得删除。注意 `.rollback` 只存一代：之后每次
  `--daemon` 指向别处的 `runtime service update` 都会先删掉 `.rollback` 里原有的那一代、再把当时被替换的 helper 放进去；
  只有 `--daemon` 恰为已安装 helper 本身（`$SUPPORT/Helpers/ArkDeckAgent.app`，路径文本完全相同）时不换 bundle、
  `.rollback` 不动（`runtime_service_install.rs:1061-1065`）。第 5 步 GJ-4 的 campaign staging 与第 7 步都要用到这一点。

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

### 第 4 步：签名 App ↔ Rust Mach service 的正向与负向验收（SPK-8，约 20 分钟）

- 执行者：【维护者】（App 与 UI 跑道是全机唯一的，窗口内不与其他 UI 跑道并行）。三条用例都只读或只写并恢复
  测试自己的 History filter，不改安装态、不派发设备操作；开关与判据的全文在 `scripts/ci/installed-rust-ui.md`。
- 变量：`$APP` 为从 RC 安装的签名 `ArkDeck.app`，`$CLI` 为 RC 的 `ArkDeckCLI.app/Contents/MacOS/arkdeck`，
  三个 SHA-256 分别对 `$APP/Contents/MacOS/ArkDeck`、`$CLI` 与 `$HELPER/Contents/MacOS/arkdeck-agentd` 用
  `shasum -a 256` 取得；证据目录都用 `$OUT` 下尚不存在的新目录。
- 正向（UI）：`FacadeRollbackUITests/testInstalledPureRustHistoryFilterRoundTrip`。UI 测试的变量要加 `TEST_RUNNER_` 前缀：

  ```sh
  TEST_RUNNER_ARKDECK_INSTALLED_RUST_UI=1 \
  TEST_RUNNER_ARKDECK_INSTALLED_RUST_APP="$APP" TEST_RUNNER_ARKDECK_INSTALLED_RUST_APP_SHA256=… \
  TEST_RUNNER_ARKDECK_INSTALLED_RUST_CLI="$CLI" TEST_RUNNER_ARKDECK_INSTALLED_RUST_CLI_SHA256=… \
  TEST_RUNNER_ARKDECK_INSTALLED_RUST_DAEMON_SHA256=… \
  TEST_RUNNER_ARKDECK_INSTALLED_RUST_EVIDENCE="$OUT/04-spk8-positive" \
    sh scripts/ci/run-ui-tests.sh \
    -only-testing:ArkDeckHDCUITests/FacadeRollbackUITests/testInstalledPureRustHistoryFilterRoundTrip
  ```

  预期：测试通过（不是 skip），`$OUT/04-spk8-positive/restoration.json` 存在。
- 负向 (a)，非本 team 签名的客户端被拒且零派发（切换后）：

  ```sh
  ARKDECK_SPK8_FOREIGN_CLIENT=1 \
  ARKDECK_INSTALLED_RUST_APP="$APP" ARKDECK_INSTALLED_RUST_APP_SHA256=… \
  ARKDECK_INSTALLED_RUST_CLI="$CLI" ARKDECK_INSTALLED_RUST_CLI_SHA256=… \
  ARKDECK_INSTALLED_RUST_DAEMON_SHA256=… \
    python3 scripts/ci/installed_spk8_negatives.py foreign-client "$OUT/04-spk8-foreign-client"
  ```

  预期：exit 0，`status: PASS`。ad-hoc 签名、无 team 的探针只发一帧只读 `health`；daemon 必须在不回任何帧的
  情况下切断连接（`connectionInterrupted`/`connectionInvalid`），前后 launchd PID 与已钉身份不变。
- 负向 (b)，App 面对另一 release 的 daemon 时报告不匹配与补救、不挂起：在**第 1–2 步之间**做——RC App 已装好、
  `runtime service update` 之前，此时安装态仍是旧 helper，版本号或 build 号与 RC 不同。先退出 ArkDeck：

  ```sh
  ARKDECK_SPK8_VERSION_MISMATCH=1 ARKDECK_SPK8_APP="$APP" ARKDECK_SPK8_APP_SHA256=… \
    python3 scripts/ci/installed_spk8_negatives.py version-mismatch "$OUT/02-spk8-version-mismatch"
  ```

  预期：exit 0，`status: PASS`。App 的 `--runtime-readonly-smoke` 入口两次刷新都在 20 秒内答
  「Runtime release does not match this App … run runtime service update」，然后正常退出，launchd owner 不变。
  若得到 `BLOCKED`（安装态 daemon 与 App 同版本），说明窗口里已没有自然的不匹配；切换后重跑需要一个带该入口、
  build 号不同的旧签名 App。
- 三条命令没有设开关时一律 `SKIPPED`（exit 77），skip 不是验收。`installed_spk8_negatives.py self-test` 只在
  进程内匿名 listener 上自检探针，可在窗口前跑，不计 SPK-8 证据。
- `AgentXPCTransportContractTests` 不在窗口内运行：它是对 Swift listener 的进程内测试，随 Swift target 删除；
  黑盒职责由 Rust 控制面黑盒测试与上面两个负例承担（附录 B 第 15 条）。
- 停止判据：正向任一项失败或被 skip；负向出现 `FAIL`（放行、挂起、服务被换）或 (a) 出现 `BLOCKED`。
- 失败时：记 `BLOCKED_BY_PRODUCT_DEFECT`，按原实现 Task（TASK-XPA-019）修；是否回滚见 §4。

### 第 5 步：GJ-1…GJ-5 `REAL_DEVICE_PASS`（约 70 分钟）

- 执行者：【维护者】安排最终验收窗口；操作通过已发布 typed Runtime 入口执行，【协调会话】核对判据与整理记录。GJ-4 不额外引入聊天确认或人工 grant，准入依现行 Runtime authority。
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
- GJ-4：runbook §5；须满足当前 Catalog policy、fresh trusted facts、完整 materialized plan 与 RuntimeCapability，缺证明时零新 dispatch。若需要命名 campaign，runbook §5 的
  `runtime service update … --arkforge-campaign` 在 Rust daemon 上也会重跑预检（每次装 Rust daemon 都跑，含 Rust→Rust）
  并重启 daemon，前提是没有在途 Job，且须通过 P6 的预设公开材料校验与 helper 身份刷新。这里的 `--daemon` 传已安装 helper 本身
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

### 第 7 步：历史回滚演练（不执行）

文首裁决已取消该演练；以下旧步骤仅供故障分析，不是验收窗口清单。故障恢复以 §4 的输入物料与显式配置为准。

> 2026-09-28 裁决后本步**不执行**（见文首裁决节，附录 B 第 10 条）。下文保留作切换失败时回到 `$ROLLBACK` 的参考。

**先读口径**：tasks.md 里 XPA-AC-9 的 r5 演练（TASK-XPA-003 行 :377）是「`runtime service update --daemon <swift>`，
再用**更新后的 App** 对同一 release 的已回滚 Swift daemon 跑 `AgentXPCTransportContractTests` 黑盒子集、
App 冒烟（Overview/History）与 headless CLI 演练；另一 release 的 daemon 应报不匹配与补救、不挂起」。
r10/r11 的 `verification.md:43`、`:73` 把 XPA-AC-9 解释为「在 M5 一次切换中满足（§G.4 预检、快照摘要、
façade bundle 保留一个周期）」，并写明「no same-release Swift rollback」；design §G.4「故障退出」也写明开发版本
修复后重启即可、不要求切回 Swift。早期文字的冲突已由 2026-09-28 裁决解决：本演练不执行。以下保留历史故障分析参考。

- 执行者：【维护者】本人（两次安装态切换）。
- 前提：第 5、6 步的记录已落盘；1a 手工预检（此时用 `$HELPER` 里的 Rust agentd）`clear: true`。Rust→Swift 的
  update 走 Swift 安装路径，**不会**自动跑预检（新 helper 的 daemon 以 `unknown argument` exit 64 回答即判为 Swift，
  `runtime_service_install.rs:837`、`:481-482`），所以这里的手工预检是唯一的门。P6 的签名校验与身份刷新对这次 update 同样生效：
  有效预设不再阻止 Rust CLI 回滚；无效公开材料在安装改动前拒绝。替换后的 helper 验签通过后、bootstrap 前
  持锁刷新身份，失败按 P6 的恢复启动与错误报告处理。真实 Keychain、所选 Swift 回滚包与安装态连续性仍须在
  维护者批准的窗口验收；不再要求仅为绕过预设拒绝而改用 Swift CLI。
- 回滚命令（源用 `$ROLLBACK`，不用 `$SUPPORT/Helpers/.rollback/…`：后者会在这次 update 里被当前 Rust helper 顶替）：

  ```sh
  "$ARKDECK" runtime service update --daemon "$ROLLBACK" --hdc "$HDC" \
    --arktrace-descriptor "$ROLLBACK_TRACE" --arkforge-bundle "$ROLLBACK_FORGE" --output json \
    > "$OUT/07-rollback.json" 2> "$OUT/07-rollback.err"; echo "exit=$?"
  ```

  按源码，这次 update 会：写不含 `ARKDECK_RUNTIME_COMPOSITION` 的 plist，`ProgramArguments` 重新选
  `arkdeck-facade` 并用 `ARKDECK_SWIFT_SHA256` 钉住同包的 Swift daemon（`runtime_service.rs:673-685`；
  `runtime_service_install.rs:1112-1117`）；把被替换的 Rust helper 放进 `Helpers/.rollback/`，放之前删掉原有的那一代
  （`:1084-1090`）。回执没有 `cutover`。源码没有「回滚」叶子，也没有保留旧 plist 或旧回执（二者都被原子覆盖，
  `:558-559`、`:571-572`）；「用 update 回滚」是按源码推出来的做法，Swift daemon 能否读 Rust 写下的 state 不在
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

切换前由维护者在离线可用的位置保留旧 App、CLI、独立的 `$ROLLBACK` helper 副本、旧 ArkForge bundle、
ArkTrace descriptor 及其引用的发行物、原 plist 和 install receipt，并保存其摘要、版本、Identifier 与 Team。
保存目录不能位于会被下一次 update 轮换的 `Helpers/.rollback` 内；只留快照摘要不构成备份。
新 RC 按安装说明的 `build_macos_release.py verify` 核对可信 run 的 revision/DMG 摘要，再在 Mac 上验签与
检查 staple。旧 helper 用 `codesign --verify --strict --deep` 及原先记录的身份要求离线复核；源文件、
摘要或身份不一致即停止，不下载或临时构建一个替代回滚包。

恢复命令必须显式传 `$ROLLBACK_TRACE`、`$ROLLBACK_FORGE`，不能省略后沿用已经切换过的 live plist。
如切换前配置含 ArkForge campaign，核对旧配置与现行 Runtime 安全条件后，同传
`--arkforge-campaign <原值>`；未知值不得猜测。App 也须恢复到与旧 helper 匹配的保留版本，不能期待新版
App 与旧版 daemon 通过版本绑定。先检查旧 helper 能否读取现有 durable 状态：已知不兼容或设备 outcome
不确定时停止新 dispatch，保持记录，不用 state 备份覆盖真实事实。临时 home 的 bootstrap 失败与显式
恢复测试只证明软件路径；真实安装态恢复尚未验收。

| 失败发生在 | 状态 | 做什么 |
|---|---|---|
| 第 0、1 步 | 什么都没改 | 按表处理后重来，或关窗口 |
| 第 2 步 update 非 0 退出 | 取决于失败阶段，见第 2 步「失败时」表 | 读 `02-update.err` 原文，按该表判断阶段；`"$ARKDECK" runtime service status` 看 `launchAgent.ready` 与 `ProgramArguments`；旧服务健康则按原文处理后重跑第 1、2 步或关窗口；旧服务停着且 plist 未改则由【维护者】bootstrap 旧 plist；中间态见下一行 |
| 第 2 步成功，但 Rust daemon 起不来（第 3 步 `socket_absent`、崩溃循环）；或第 2 步在快照之后失败（中间态） | 安装态已是 Rust，或处于中间态 | 【维护者】先 `launchctl bootout gui/$(id -u)/com.arkdeck.agentd` 止住循环；读 `agentd.error.log`；用 `"$ARKDECK" runtime service update --daemon "$ROLLBACK" --hdc "$HDC" --arktrace-descriptor "$ROLLBACK_TRACE" --arkforge-bundle "$ROLLBACK_FORGE" --output json` 回到 Swift（`$ROLLBACK` 的 Swift daemon 在解析参数时就以 exit 64 拒绝 `--cutover-preflight`，不碰 state，update 据此判为 Swift、不走预检门：`Packages/ArkDeckKit/Sources/ArkDeckAgentDaemonMain/main.swift:183-203`、`rust/crates/arkdeck-cli/src/runtime_service_install.rs:837`；第 7 步的前提、签名预设限制与核实同样适用；这条路径是按源码推出的，见附录 B 第 18 条）；不改 state |
| 第 3–6 步功能缺陷 | 安装态 Rust，daemon 健康 | 记 `BLOCKED_BY_PRODUCT_DEFECT`（原文、Runtime 引用、复现 argv）。两种走法由维护者当场定：(a) 停在 Rust，停止新执行、保留状态，修复后更新 Rust helper 再验（design §G.4「故障退出」）；(b) 回到 Swift（同上一行命令） |
| 任何一步出现真实设备不确定状态 | — | 只读回；只有 `POL-RECOVERY-001` 的完整机械证明成立时 Runtime 才能独立完整覆写恢复；缺证明时零新 dispatch。**不**为此回滚、不换 state 目录、不从备份恢复 |

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
  - 若实际触发故障恢复，记录每项核实结果；未执行的回滚演练不记为通过。
- 不写：secret、钥匙串条目、provisioning profile 内容、notarytool 凭据名以外的账户信息；设备序列号、connectKey、
  原始设备输出；个人路径。原始输出留在 `$OUT`，不入仓。

## 附录 A. 命令与源码位置对照

| 命令 / 事实 | 源码或记录位置 |
|---|---|
| LaunchAgent 标签 `com.arkdeck.agentd`、域 `gui/<uid>`、`/bin/launchctl` 与 `print`/`bootout`/`bootstrap` 参数数组 | `rust/crates/arkdeck-platform/src/launchd.rs:23`、`:25`、`:30`、`:40`、`:45`、`:50` |
| 安装态路径（plist、`Helpers/ArkDeckAgent.app`、`Helpers/.rollback/`、`LaunchAgent/cutover-snapshots`、`install-receipt.json`、`Signing/OpenHarmony/preset-v1.json`、`Agentd`、socket、日志） | `rust/crates/arkdeck-cli/src/runtime_service.rs:119-138` |
| plist 渲染（`Label`、`ProgramArguments`、`MachServices`）与切换时加 `ARKDECK_RUNTIME_COMPOSITION=production` | `rust/crates/arkdeck-cli/src/runtime_service_install.rs:1096`、`:1153-1155`、`:1156-1187` |
| `ProgramArguments` 选 daemon 还是 façade | `runtime_service.rs:673-685`；`runtime_service_install.rs:545-547` |
| 签名预设公开材料在安装改动前校验；无效材料拒绝（exit 69）；替换后持锁刷新身份，失败尝试恢复启动后报告 | `runtime_service_install.rs` 的 `validate_signing_refresh` 与 `install` 中 `refresh_signing_access` 分支；`signing_leaves.rs` 的 `validate_refresh` / `refresh_installed_identity` |
| 已退役的 `--arkforged`/`--arkforged-sha256`/`--arkforge-profile` | `runtime_service_install.rs:388-398` |
| `runtime service update/restart/status/verify/uninstall` 的选项表（Swift 注册表副本） | `rust/crates/arkdeck-cli/src/command_registry.json:953`、`:1020`、`:1073`、`:1188`、`:1241` |
| `flash bind-loader`（`--target`、`--expected-binding-revision` 均必填） | `command_registry.json:20059` |
| `job cancel`、`job reconcile`、`job wait`、`agent status`、`agent resume`、`human-action show`、`session cleanup preview/apply`、`runtime storage status`、`runtime tool select`、`runtime signing status` | `command_registry.json:7350`、`:7645`、`:6701`、`:10944`、`:11375`、`:11649`、`:8118`、`:8222`、`:3259`、`:2600`、`:1633` |
| `arkdeck-agentd --cutover-preflight [--hold-instance-lock]`：环境、退出码、输出字段、拒绝种类、快照 | `openspec/changes/chg-2026-074-shared-rust-runtime-core/evidence/runs/TASK-XPA-018/runtime-service-cutover-preflight-run.md:12-19`、`:35-77` |
| `loaderTransitionAwaitingBinding`、`retainedSessions`（#2255） | `rust/crates/arkdeck-agentd/src/cutover_preflight.rs:215-223`、`:247-253`；`rust/crates/arkdeck-cli/src/runtime_service_install.rs:682-704`、`:711-720`、`:752-758`；记录 `evidence/runs/TASK-XPA-017/cutover-preflight-legacy-refusals-run.md:18-35`、`:254-257` |
| Rust helper 发布构建与签名 | `Packages/ArkDeckKit/Distribution/macOS/build-helpers.sh:13-20`、`:77-101`；`package-rust-helpers.sh:80-104` |
| 发布包只读验收与维护者窗口命令 | `evidence/runs/TASK-XPA-017/rust-helper-packaging-run.md` §5、§6 |
| 结构检查（只适用于无签名产物） | `Packages/ArkDeckKit/Distribution/macOS/check-rust-helpers.py:36`、`:68-72`、`:305-345` |
| ArkForge 源码 pin | `rust/Cargo.toml:23-29`；`Packages/ArkDeckKit/Package.swift:46-48`；`rust/scripts/check-arkforge-pin.py` |
| ArkForge bundle manifest 校验 | `rust/crates/arkdeck-contract/src/arkforge_bundle.rs:295-296`、`:337` |
| GJ 跑法、固定事实、§6b、记录模板 | `docs/design/cli-golden-journey-headless-runbook.md` §0、§1–§6、§6b、§7 |
| XPA-AC-9 口径 | `openspec/changes/chg-2026-074-shared-rust-runtime-core/tasks.md:377`；`verification.md:43`、`:73`；design §G.4 |
| `runtime service` 各叶子的分派与选项白名单；`--control-request-id`/`--socket` 被拒 | `rust/crates/arkdeck-cli/src/lib.rs:865-870`、`:1358-1397`、`:949-956`；`runtime_service.rs:1715-1740` |
| `update` 的参数与保留规则、拒绝原文 | `runtime_service_install.rs:304-438`；`runtime_service.rs:967-987`、`:1664-1676` |
| `install()` 顺序：验签、探测、第一遍预检、目录、bootout、持锁一遍与快照、换 bundle、plist、回执、bootstrap | `runtime_service_install.rs:461-596`、`:602-679`、`:775-850`、`:1017-1054`、`:1056-1091`、`:1096-1189`、`:1193-1221` |
| helper 签名要求（团队、identifier、钥匙串组、hardened runtime、embedded profile） | `rust/crates/arkdeck-platform/src/host_bundle_signature.rs:18-21`、`:336-414` |
| 预检块的 CLI 文案与 exit 75 | `runtime_service_install.rs:682-704`、`:706-762` |
| `status` 的判定、字段与退出码 | `runtime_service.rs:1011-1168`、`:459-493`、`:1424-1435` |
| `verify`：选项、重开校验、人工动作 exit 75 | `runtime_service.rs:1523-1612`、`:1645-1650`；`runtime_service_verify.rs:85-169`、`:1036-1089` |
| socket 对端只核 UID（macOS 不核可执行身份） | `rust/crates/arkdeck-platform/src/unix.rs:269` |
| bootstrap 的 EIO 重试与 `enable` | `runtime_service.rs:624-645`；`launchd.rs:60-62` |
| 预检模式：退出码、被拒组合输入、不写记录 | `rust/crates/arkdeck-agentd/src/cutover_preflight.rs:49-51`、`:53-56`、`:73-123`、`:176-197`、`:300-324`；`production.rs:78-116` |
| 共享状态表（阻断态、停放、终态、execution、capability use 词表） | `rust/crates/arkdeck-contract/src/job_state_preflight.rs:246-349`；`rust/tests/fixtures/job-state-preflight/table.json` |
| Rust daemon 启动时的 Loader 过渡（同一 target 两个及以上即启动失败；切换前由预检 `loaderTransitionsCoverTarget` 拒绝，#2302） | `rust/crates/arkdeck-agentd/src/main.rs:385-395`；`rust/crates/arkdeck-hoststore/src/rockchip_startup.rs:69-97`；`rust/crates/arkdeck-agentd/src/cutover_preflight.rs:236-241` |
| `flash bind-loader` 在 Rust CLI 上也已实现（`flash.bind-current-loader`） | `lib.rs:781`、`:1088`；`rust/crates/arkdeck-cli/src/flash_leaves.rs:79-102`；`rust/crates/arkdeck-control/src/lib.rs:1387-1400` |
| Rust CLI 签名叶子：`runtime signing status|remove` 及旧 `signing` 拼法；服务安装/更新持锁刷新凭据身份，显式签名 `install` 已移植，DevEco 迁移与 SDK release 安装已移植，含发布未知时的材料/账号跟踪；真实 Keychain 验收仍待完成 | `rust/crates/arkdeck-cli/src/signing_leaves.rs`；`evidence/runs/TASK-XPA-018/signing-remove-run.md` |
| 窗口记录与 GJ 记录落点 | `openspec/changes/chg-2026-074-shared-rust-runtime-core/verification.md:76`；`docs/design/cross-platform/macos-chain-agent-prompt.md:516-522` |

## 附录 B. 需要维护者定的事项

> 2026-09-28：第 1–10 条已由文首裁决节处理，下列原文保留作记录。

窗口前必须裁决：

1. P2：已关闭。#2255 与 #2302 已合入；同一 target 两个及以上会让 Rust daemon 启动失败的那一类，由预检块
   `loaderTransitionsCoverTarget` 在切换前拒绝（零改动、点名 Job）。1a 读出它时照第 1 步表中该行停下交维护者；单个这种过渡照旧原样带进 Rust。
2. P3/Q11：发布包是否公证。`build-local-helpers.sh` 已提供 `ARKDECK_HELPER_RUNTIME=rust`，构建带本地开发标记的 provisioned Debug helper，保留经校验的 Swift 回滚包；它只用于当前 Mac，不替代正式发布所需的公证。见 `evidence/runs/TASK-XPA-017/local-rust-helper-build-run.md`。采用哪种产物开窗仍由维护者决定。
3. P4：20b Rust 基线是否为开窗条件。
4. P5：4h soak 是否要在窗口所用提交上重跑。
5. P6/S-1：Rust 签名写路径与 helper 身份刷新已在 #2272 合入，已有预设不再构成一律拒绝；真实 Keychain、安装态身份刷新与 GJ-5 验收仍需维护者安排。
6. P7/F1/F2：ArkForge 摘要域修法、与 bundle 同步发布的方式；裁决前切换不换 ArkForge bundle、GJ-4 不开始。（已由 #2303 按裁决修复；切换改用 RC 的 bundle，见 P7 行。）
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
    （2026-09-28 已收口：正向为 `testInstalledPureRustHistoryFilterRoundTrip`，负向为 `installed_spk8_negatives.py`，见第 4 步。）
15. 第 7 步：`AgentXPCTransportContractTests` 黑盒子集对安装态 daemon 的运行方式。
    （2026-09-28 已收口：不运行，随 Swift target 删除；黑盒职责由 Rust 控制面黑盒测试与 SPK-8 两个负例承担。）
16. 第 7 步与 P6：#2272 已移除“存在预设即拒绝”的实现限制。Rust CLI 的 update（含回滚、GJ-4 campaign staging）按 P6 校验公开材料并刷新身份；待定的是实际窗口与回滚包验收，不是另选 CLI 绕过旧拒绝。
17. 第 5 步 GJ-5：#2272 已提供 Rust `runtime signing install|migrate-deveco|install-sdk-release`（兼容旧 `signing` 拼法）。维护者仍须选择真实签名材料和凭据来源，确认在哪个安装窗口建立或沿用预设；沿用有效 Swift 预设不再与 P6 冲突。
18. 第 2 步在快照之后失败的中间态：已只读核实（`evidence/runs/TASK-XPA-017/cutover-runbook-appendix-b-run.md` 第 18 条）：快照写完之后确无自动恢复；本文给的处理（按 §4 第 3 行
    回到 `$ROLLBACK`）与源码一致。现有临时 home / 记录型 launchctl 测试覆盖了快照、helper、plist 与收据已写入但 bootstrap 失败后的显式回滚，验证 Swift bundle、plist、收据恢复且 Runtime 状态与快照不变（`evidence/runs/TASK-XPA-017/cutover-rollback-bootstrap-run.md`）；真实安装态、签名与设备连续性仍未验收。待定：维护者是否认可并执行真实回退路径。
19. 1a 手工预检：已只读核实（同上，第 19 条）：无锁那遍不取锁、不建目录或锁文件、不写任何 owner 数据；**会在 Job 索引旁
    创建或触碰 `-wal`/`-shm`，不改数据库内容**（有 `-shm` 时在其中记读标记；没有时新建空 `-wal` 与新 `-shm`）。待定：
    维护者是否接受这一点、是否认可在真实账户上这样跑；若要真正零写入（immutable 打开或先复制再读），是另一刀的设计取舍。
