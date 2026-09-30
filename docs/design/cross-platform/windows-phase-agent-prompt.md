# 任务指令：ArkDeck Windows 阶段——软件对等，交付可验收的 Windows 发布候选

- **版本**：2026-09-30
- **起点**：protected `main` ≥ `7c57345f2`，CHG-2026-074 r11
- **主机**：维护者的 Windows 11 x64 参考主机。初始化（W0）已完成；仓库、工具链和 Python 解释器的位置以 W0 记录为准。

本文不是规范：
- Task 定义以 `openspec/changes/chg-2026-074-shared-rust-runtime-core/tasks.md` 为准；
- 安全规则以 `openspec/constitution.md` 与 `PRODUCT-LOOP.md` 为准；
- 本文与它们冲突时，以它们为准，并在汇报里指出本文哪里写错了。

本文放在仓库里：`docs/design/cross-platform/windows-phase-agent-prompt.md`，以 `main` 上的最新版为准。会话重开或上下文被压缩后，先重读它。它与 macOS 链的 `macos-chain-agent-prompt.md` 并列。

你是 ArkDeck 的 Repo Agent：修改代码、测试和文档，不执行设备 job。你循环推进，直到达到下面的目标，或者剩下的工作全都在等维护者。

你不能合并 PR，不能自批，也不能把任何东西标成 approved 或 verified。维护者 review 后合入 protected `main` 才算批准。

和维护者对话用中文；代码、注释、commit message、PR 标题与正文用英文。

---

## 目标

**让 ArkDeck 在 Windows 11 上具备与 macOS 相同的产品能力，并交付一个可由维护者做真机验收的 Windows 发布候选。** 完成 GJ-1..5 的组合是：同一个 Rust Runtime（`arkdeck-agentd`）、Rust CLI（`arkdeck`），加上原生 Windows 客户端。

工作分两个阶段。这沿用维护者 2026-09-28 对 macOS 的裁决：「软件先做完，真机验收放最后」。Windows 是否同样适用，由 r12 提请维护者确认（§1.2）。

- **阶段 S（你负责）**：完成全部软件。出口条件见下。
- **阶段 A（维护者负责）**：在真实主机和板子上完成验收，包括：
  - SPK-3 的主机条件行；
  - Windows 11 x64 上的 GJ-1..5 headless `REAL_DEVICE_PASS`（r13：只支持 x64，ARM64 延后）；
  - 干净主机 smoke；
  - 翻转 conformance、traceability 与平台 lock。

  这些由维护者的窗口和合入来完成。你负责准备 crib、runbook 和记录。

### 阶段 S 的出口条件（全部满足才算完成）

1. **Windows 阶段已打开**：CHG-2026-074 r12 已合入，§1.2 列出的裁决已落地。
2. **GJ-1..5 在 Windows 上端到端可用**：runbook（`docs/design/cli-golden-journey-headless-runbook.md`）用到的每个 operation 和方法，都能在 Windows 上由 Rust CLI 经 named pipe 调用 Rust daemon 端到端跑通。具体要求：
   - 用主机测试覆盖，设备一侧用 fake HDC 或替身 lane；
   - durable 格式与 macOS 的 T0 字节一致，由回放已录的 oracle 证明；
   - daemon 重启后能读回，XPA-AC-7 的 kill 矩阵通过。
3. **Windows HDC tuple 已注册**：通过一个独立的 integration change 完成，输入来自本机的真实采样（§3 WM1）。
4. **CLI 覆盖完整**：`openspec/contracts/cli-feature-coverage.json` 里每个条目的 `implementationStatusByPlatform.windows` 都是 `implemented`。唯一例外是维护者接受 deferred 的 platformService 条目。
   - 这个文件由 `rust/crates/arkdeck-cli/src/feature_coverage.rs` 经 contracts export 生成，不手改。
   - 现在是 256 项里 140 项 `notImplemented`、116 项未填。
5. **Windows 客户端完成**：
   - SPK-4 已定案，选 WinUI 3 还是 WPF；
   - XPA-007 的骨架和 XPA-020 的各个页面接的是真实的 Windows daemon；
   - UIA 语义快照测试齐全；
   - `scripts/ci/plan.py` 里有 `windows` 车道，并已加入 `swift` 聚合。
6. **Trace 按决策 5 交付**（XPA-021）：至少做到 capture、inspect、export 与 macOS 对等。viewer 没做的话，如实显示 `unavailable`。
7. **打包就绪**（XPA-022 的软件部分）：MSIX（按决策 10）以及 daemon、CLI 的 xcopy 形态，都能由脚本从同一个修订构建出来；签名步骤已就绪，凭据由维护者提供并执行。
8. **全部落在 main 上**：
   - 以上内容都已进入 protected `main`；
   - CI 全绿，包括 `guard` 和 `swift` 聚合，后者含三平台的 Rust 车道和 `windows` 车道；
   - `evidence/windows-remaining.md` 仪表盘的数字与出口一致；
   - 阶段 A 的 crib 和 runbook 已写好。

### 不属于阶段 S（不做，也不宣称）

- 真机 `REAL_DEVICE_PASS`，以及平台 `supported` / `verified` 的声明；
- 翻转 traceability 的 Windows 列和 lock；
- 放宽任何 Core requirement、AC 或安全不变量；
- ArkForge 仓内的工作（AF-W1）：这是外部依赖，向 ArkForge 推送任何东西都要维护者当场确认。

---

## 0. 现状（2026-09-30 在 Mac 上核对；开工先用仓内文件和 `git log` 复核）

### macOS 侧

- 软件已全部合入：
  - Rust daemon 路由了 105/105 个方法；
  - Swift 的 daemon、引擎、存储和 CLI 都已删除，仓内只剩 Rust 这一份 Runtime 语义实现。
- RC 在 GitHub Actions 里构建（#2319，#2323–#2325）。
- 阶段 A 的真机验收还没做，所以 G5（= XPA-017 done）没有达成，XPA-017 仍是 `blocked`。
- 还没有人起草 r12。

### Windows 侧

- Hosted CI 在 `windows-latest` 上跑 Rust 的 `workspace` 和 `contracts` 两个 job，都是绿的。但那是一台以管理员身份运行、关闭了 UAC、没有板子的 Windows Server 虚拟机。
- 大部分 Runtime 在 Windows 上没有编译进来。`arkdeck-hoststore`、`arkdeck-agentd`、`arkdeck-bootstrap`、`arkdeck-provider-hdc` 等处有数百个 `cfg(target_os = "macos")`。
- Windows 上的 daemon 只有 XPA-002 的只读基础：
  - 用户私有的 named pipe（logon SID DACL、`FILE_FLAG_FIRST_PIPE_INSTANCE`、`PIPE_REJECT_REMOTE_CLIENTS`）；
  - 客户端的两层服务端认证：先比对 pipe owner SID，再核对本连接服务端 PID 的映像，以及 Authenticode signer SHA-256 或 MSIX family；
  - 三个叶子：`doctor`、`operation list`、`device candidates`。
- 由此带来的限制：
  - **未签名的开发构建会被 CLI 按身份拒绝，这是设计（XPA-AC-6）**；
  - 30 个 operation 全部 `unavailable`；
  - 没有注册 Windows HDC tuple，所以不派发 HDC；
  - 隔离开发根、production composition、managed HDC、ArkForge lane 都只在 macOS 上组合。
- Windows 专属代码：
  - `rust/crates/arkdeck-platform/src/windows/`、`src/process.rs`；
  - `tests/windows_transport.rs`、`examples/windows_spk3.rs`；
  - SPK-3 harness `rust/scripts/windows-spk3.ps1`；
  - 说明见 `rust/crates/arkdeck-platform/README.md`。
- Windows 任务与门槛的状态：
  - XPA-002 `in-progress`，只剩 Windows 验收；
  - XPA-004..011、020..022 都是 `blocked`；
  - SPK-3、SPK-4、SPK-5 都没跑过；
  - Windows profile 0.2.0，`notStarted`；`conformance-cases.yaml` 只是骨架；
  - traceability 与 lock 的 Windows 列全是 `notStarted`；
  - `plan.py` 还没有 `windows` 车道。
- ArkForge AF-W1 是 🟡：只剩在合格的 Windows x64 主机上把它的 self-hosted 验收 workflow 跑绿。

### 这台主机（W0 已完成）

- **W0 记录**：初始化会话把它留在工作区里，没有提交，路径是 `openspec/changes/chg-2026-074-shared-rust-runtime-core/evidence/runs/TASK-XPA-002/windows-host-w0-*.md`。开工先读它，确认以下几项：
  - 仓库、`RUSTUP_HOME`、`CARGO_HOME` 各自的位置；
  - `ARKDECK_PYTHON` 指向哪个解释器；
  - 工具版本和基线结果；
  - 推送凭据与 hook 的配置状态。推送还没配，就按 §2.5 先配好。
- **磁盘**：参考主机的系统盘空间紧张，仓库和工具链都放在另一块 NTFS 盘上。新产物（构建目录、worktree、缓存）也放那块盘，不放回系统盘。
- **权限**：账户在管理员组，但 Claude Code 以非提权方式运行。需要 UAC 的步骤交给维护者。
- **不要动的东西**：如果主机上为 Mac 开了 OpenSSH Server（只监听 `127.0.0.1`），不要改动它的配置和授权密钥。
- **Git Bash 的坑**：
  - 查 Windows 组用 `whoami.exe //groups`；
  - PowerShell 命令开头加 `[Console]::OutputEncoding=[Text.Encoding]::UTF8;`；
  - 调原生程序时 stdin 接 `</dev/null`，并用 `timeout` 包住。

---

## 1. 维护者门与要提请的裁决

### 1.1 你不能越过的门

- **合入**：包括 r12 和每一个 PR。
- **只能由维护者本人做的操作**：
  - UAC 提权；
  - 证书的创建与信任；
  - 建账户（跨账户用例要第二个账户）；
  - 装驱动和 HDC；
  - 接板；
  - 签名凭据（如 Azure Artifact Signing）；
  - destructive 的 go（GJ-4 按 HardwareCampaign 逐次放行）；
  - 向其他仓库推送。
- **需要 OpenSpec change + 维护者 PR review 的改动**（AGENTS.md 的表）：
  - 新 provider；
  - 新 integration 或 device profile，例如 Windows HDC tuple；
  - destructive 准入策略的变化。

  动手前读 `openspec/governance/enforcement.md` 与 `openspec/verification/policy.md`。
- **安全不变量冲突**：停下受影响的推进，写明条款和冲突在哪里，交维护者裁决。

### 1.2 r12 要提请的裁决（写成 proposed ruling，维护者合入即为认可，同 r11 对 §L.1 第 7 条的写法）

1. **§L.1 第 18 条（r8）改为：现在打开 Windows 阶段。**
   - 理由：Swift runtime 已删，Rust 是唯一的实现。r8 担心 Windows 建在一份会被 macOS differential 重塑的快照上，这个前提已经不成立。
   - G5 仍然是 macOS 的门（XPA-017），macOS 阶段 A 与 Windows 阶段并行。
   - 同一文件里，macOS 阶段 A 的修复优先于 Windows 的改动；Windows 的改动必须保持 macOS 和 ubuntu 两条 CI 车道为绿。
2. **Windows 同样「软件先做完、真机放最后」。**
   - 例外：会决定设计走向的主机事实要尽早采集，包括 HDC 输出、USB 设备属性，以及 SPK-3 中 CI 测不到的行（WM0.5）。
3. **Swift 解码器相关验证行的读法。** 以下几行以 Swift 为参照：
   - XPA-005「decoded by the Swift decoders unchanged」；
   - XPA-008「decoded by Swift」；
   - XPA-AC-2「`job.plan` digest equality with Swift」；
   - XPA-AC-4「ledger decodes in Swift」；
   - XPA-010「Swift and Rust compute the same plan digest」。

   Swift 的 runtime target 已删除（#2311/#2312/#2316），所以参照物改为：`rust/tests/fixtures/**` 与 `spec/**` 中录下的 Swift oracle 和语料，加上 macOS 上 Rust writer 写出的 T0 字节。这一条不改 AC 原文，只界定参照物，性质同 r11 的对等三级。
4. **决策 9（支持格）**：Windows 11 x64 与 ARM64，不支持 Windows 10。（r13 改为：只支持 Windows 11 x64，ARM64 延后，不支持 Windows 10 与 32 位 x86。）
5. **决策 10（打包）**：App 用 MSIX packaged + self-contained Windows App SDK，签名用 Azure Artifact Signing 并加时间戳，更新走 App Installer；daemon 和 CLI 另外提供 xcopy 形态，供 CI 和 headless 使用。
6. **决策 11（daemon 生命周期）**：由客户端自启动，daemon 单实例。
7. **决策 5（Trace 范围）**：选 (b)。capture、inspect、export 对等作为 supported 的门槛，viewer 放到后续。
8. **开发期 daemon 身份。**
   - 本机：维护者创建一张开发用代码签名证书，只在本机信任；用 `ARKDECK_DAEMON_SIGNER_SHA256` 钉住签名者，daemon 放在钉住的路径上。
   - CI：在 hosted runner 上用临时的自签证书测正向路径。
   - 任何情况下都不加跳过身份校验的开关。

第 4–7 条是设计 §H.4、§L.1 里已有的推荐。维护者要改任何一条，就在 PR review 里改。

---

## 2. 每一刀都适用的规则

### 2.1 实现原则

- **只有一份 Runtime 语义。** 做法是在 `arkdeck-platform` 里给平台原语补上 Windows 实现，从而拆掉 `cfg(target_os = "macos")` 的门。平台原语包括：路径、锁、原子替换、进程启动、USB 普查、工具身份、pipe 传输、凭据存储。不按操作系统分叉 Runtime 语义。
  - PRODUCT-LOOP §12 允许结构性改动，但必须和一个 GJ hop 同车交付。
- **拆门之前先弄清原因。** 先查清这个门为什么只在 macOS 上：用了 Apple API、依赖 POSIX 语义，还是只是没在别处测过。不借机扩大语义。
- **对等按 r11 的三级：**
  - T0 逐字节相等：线协议、digest 与引用身份、cutover 之后仍会被读取的 durable 格式；
  - T1 语义相等：状态迁移、错误码、拒绝条件、零派发证明、下一步动作；
  - T2 不比较：`message` 文本、时间精度、日志等。
- **Windows profile 明文禁止的做法**（`openspec/platforms/windows/profile.md`）：
  - 用 `cmd.exe /c` 或 PowerShell 拼接用户或设备输入；
  - 把 endpoint 当作身份；
  - 自动重绑定；
  - 自动 kill 外部 HDC server；
  - 静默提权、装驱动或改系统策略。
- **状态目录**：按设计 §D.2 放在 `%LOCALAPPDATA%\ArkDeck\Agentd`，用 named mutex 保证单实例。编码前先和 profile 的 Port mapping 核对，并把这个平台决定记录下来。

### 2.2 安全与设备边界（摘自 AGENTS.md，以原文为准）

- **设备操作只经 Runtime。** 对真板的操作只能经 Runtime 已发布的 typed operation。你不对板子执行 raw HDC、刷机命令或 raw shell。
  - 需要真机采样时，由你起草 crib，先在主机侧把能测的都测过，再由维护者亲手运行。你只处理产出的文件。
  - 入仓的记录要脱敏：不写序列号、机器名、账户名和用户目录（仓库是公开的）。
  - 本机上如果接着板子，测试一律用 fake HDC。
  - DevEco 或其他 hdc server 占着 USB 时，报告给维护者，不要 kill 它。
- **可信产物只由 Runtime 生成。** capability、trusted facts、reservation/outcome 记录、Provider coverage 声明和 hardware evidence，只由 protected-main 的 Runtime 生成。不要手工创建或修改它们，也不要加开发旁路。
- **不确定就 fail closed。** 身份或副作用结果不确定时一律 fail closed；未知的 intent 永不 replay；无法完整物化 plan 时，不消费 capability。
- **什么不算真机或平台验收。**
  - fake、fixture、simulation、plan-only 都不是真机；`REAL_DEVICE_PASS` 只用于当前 Catalog digest 上的真实设备结果。
  - 主机测试和 hosted CI 不能证明「Windows 已支持」。
- **不为通过而放宽。** 平台满足不了 Core 时，标 `blocked` 或 `nonConformant`。

### 2.3 分支、提交、推送

- **分支命名**：`agent/<slug>-<YYYYMMDD>`。auto-PR 只监听 `agent/**`（排除 `agent/host-loop/**`）。Claude Code 默认给的 `claude/...` 分支名，推之前必须改名。
- **commit subject** 用英文：`<type>(TASK-XPA-NNN): <what>`，只放一个 TASK token；治理 revision 不放 TASK token。
  - PR 正文是固定模板，标题取自 HEAD commit，squash 合入后 main 上只剩标题。所以完整说明必须写在 commit message 里：改了什么、为什么、Local targeted checks、CI、没验证到什么。
- **改动范围。** 路径护栏已由 CHG-2026-077 退役。Task 的 Allowed paths 只是规划声明，需要改表外的文件就直接改，在 commit message 里说明即可。
- **推送前**：
  - `git fetch origin && git rebase origin/main`；
  - `git cherry origin/main HEAD` 里不能有 `-` 行；
  - 跑完 §2.4 的针对性检查。
- **推送后**（push 成功不等于 PR 已经开出）：
  - 看 `gh run list --workflow "Agent PR" --branch <b> --limit 1` 是否成功，再看 `gh pr list --head <b>`；
  - 如果报 base 不是 head 的祖先，就 rebase 后用 `--force-with-lease` 重推。
- **gh 只读**：只用 `gh pr view/checks/list`、`gh run list/view`。
  - 不用 `gh pr create/edit/merge/review/comment`，不用 `gh api` 的写方法，不用 `gh run rerun`。
  - 偶发失败按 §2.4 的四条判据记录后，靠 amend 并重推来重跑。
- **不 amend 已经绿了的 head**（它可能正在被合入）。这次的 CI 结论写进下一刀的 run 记录。
- **git 卫生。**
  - 不用不带唯一标签的 `git stash`，不用 `git checkout <branch> -- .`。
  - squash 时基于 `git merge-base HEAD origin/main`，不要直接基于 `origin/main`。
- **union 合并的文件。** `tasks.md` 和 `rust/README.md` 标了 `merge=union`。rebase 后检查有没有重复的 bullet，`#[cfg(...)]` 属性是否仍然成对（`scripts/check_union_merge.py` 能查出重复）。
- **记录写在哪里。**
  - 每一刀：`evidence/runs/<TASK>/<slice>-run.md`；
  - `tasks.md`：只在 Task 的 Status 行变化时才改；
  - `rust/README.md`：按 crate 领域就地修改对应的那一节；
  - `evidence/windows-remaining.md`：每个里程碑结束时，用一个单独的 docs PR 刷新一次，不在每一刀里改，避免成为冲突热点。

### 2.4 本机针对性检查与 CI

**push 前在本机跑（目标 10 分钟以内）：**

- 所有改动：`cargo fmt --all --check --manifest-path rust/Cargo.toml`。
- 改动的 crate 及直接依赖它的 crate：`cargo clippy -p <crate> --all-targets -- -D warnings` 和 `cargo test -p <crate>`。
  - 多个 worktree 各用各的 `CARGO_TARGET_DIR`（放 D 盘）。
- 改了契约输入：`"$ARKDECK_PYTHON" rust/scripts/generate-contract.py --check`。
- 改了 `rust/scripts/check-contracts.py`：跑 `"$ARKDECK_PYTHON" rust/scripts/test_contract_checks.py`。
- 改了 `openspec/**`、`docs/**` 或 `AGENTS.md`：`sh scripts/check-sdd.sh`。
- Windows 客户端工程：跑受影响项目的 build 和 test。

**本机做不到、交给 CI 的：**

- macOS 和 Linux 这里编不了。改到 `cfg(unix)` 或 `cfg(target_os = "macos")` 下的代码时，自己把 cfg 配对重读一遍，结论以 CI 的 macOS 和 ubuntu 车道为准，并在交付说明里写明。
- CI 是统一门：required checks 是 `guard` 和 `swift` 聚合。本机不跑完整门。

**CI 红了怎么办：**

- 先看是哪一步失败的。代码红就修；不放宽断言，不加 sleep。
- 失败在本 PR 没改动的负载敏感测试里：按四条判据判定——失败不在改动范围、属于已知的负载或端口竞争、单独跑能稳定通过、与 diff 无关——记录后重推。

**交付说明分两段写：**

- 「Local targeted checks」：命令、退出码、日志路径；
- 「CI」：PR 号、run id、结论。

### 2.5 推送凭据与防护 hook（W0 没配时先配）

**1. 生成本机专用的 deploy key。** 维护者之前选的方案是：每台主机一把 deploy key，gh 只做只读查询。

```bash
ssh-keygen -t ed25519 -N "" -C "arkdeck-agent-windows" -f ~/.ssh/arkdeck-agent-deploy-windows
```

把公钥交给维护者，由维护者在 `ArkDeck/ArkDeck` → Settings → Deploy keys 里添加，并勾选 Allow write access。你不要用 gh 或 API 去添加。

**2. 配置 SSH 主机别名。** 在 `~/.ssh/config` 里追加：

```
Host github-arkdeck-agent
  HostName github.com
  User git
  IdentityFile ~/.ssh/arkdeck-agent-deploy-windows
  IdentitiesOnly yes
```

**3. 钉住 GitHub 的主机公钥。** 在 known_hosts 里写入 `scripts/ci/arkforge-cargo-fetch.sh` 里钉的那一行 `github.com ssh-ed25519 …`，并和 `https://api.github.com/meta` 交叉核对。

如果 22 端口不通，改成 `HostName ssh.github.com` 加 `Port 443`，known_hosts 那行的主机部分相应写成 `[ssh.github.com]:443`。

**4. 验证。**

- 运行 `ssh -T git@github-arkdeck-agent`，应该回 `Hi ArkDeck/ArkDeck! …`。
- fetch 仍然走匿名 HTTPS，只有 push 走 deploy key：

  ```bash
  git remote set-url --push origin git@github-arkdeck-agent:ArkDeck/ArkDeck.git
  git push --dry-run origin HEAD:refs/heads/agent/deploy-key-probe   # 只验证写权限
  ```

**5. gh 登录。** 由维护者本人运行 `gh auth login`，你只用 `gh auth status` 核验。

**6. 防护 hook。** 仓库的 `.gitignore` 忽略了 `.claude/`，Mac 上的 hook 不会随 clone 过来，要在这台机器上重建。

- **放在哪里**：用户级的 `%USERPROFILE%\.claude\settings.json`。写入前，先把完整的 JSON 给维护者看。
- **生效范围**：只在仓库根目录存在 `.github/workflows/agent-pr.yml` 的仓库里生效。
- **拒绝**：
  - `gh pr (create|edit|reopen|merge|review|comment|close|ready)`；
  - `gh api` 的写操作；
  - `gh run (rerun|cancel)`、`gh workflow run`；
  - 在非 `agent/**` 分支上执行的 `git push`；
  - `git cherry origin/main HEAD` 里有 `-` 行时的 `git push`。
- **怎么写**：原生 Windows 上 hook 命令由哪个 shell 执行，先查官方文档或实测。Mac 上那条 bash+jq 的单行命令不能照搬。
- **实测**：`gh pr create --help` 和在 `main` 上执行 `git push --dry-run …` 都必须被拒绝；`gh pr list --limit 1` 必须放行。

---

## 3. 里程碑

每个可运行的切片交一个 PR。CI 绿了不等合入，直接开始下一个不依赖这次合入的切片。每个 Task 开工前，重读它在 `tasks.md` 里的那一节。

### WM0：r12（第一个 PR）

- **先例**：`git show --stat 289328089`（r8，#1827，改了 5 个文件），以及 r9（#1836）、r11（#1910）。
- **分支**：`agent/chg-074-r12-windows-phase-<YYYYMMDD>`。
- **subject**：`proposal(CHG-2026-074): revise to r12 — open the Windows phase beside the macOS real-device acceptance`
- **要改的文件：**
  - `proposal.md`：`revision: 12`，`status` 保持 `proposed`，在开头加「Revision 12」一节；
  - `tasks.md`：
    - 加「Revision 12」一段；
    - 改 XPA-002 的排序文字；
    - XPA-004 的 `Depends on` 去掉 XPA-017 和 G5；
    - 把 XPA-004 状态行的括注改成它真正剩下的依赖。
  - 变更自己的 `design.md`，以及 `docs/design/cross-platform/rust-core-cross-platform-architecture.md`：§L.1 第 18 条和决策 5、9、10、11 加上裁决注记，§J.5 加上 r12 的进度入口；
  - `verification.md`：第 3 行必须严格写成 `> Change:CHG-2026-074-shared-rust-runtime-core@r12`，并补上 §1.2 第 3 条的读法；
  - 同车加入：W0 记录（按 §2.2 脱敏）；`evidence/windows-remaining.md`（一张表，见 §5）；本文如需随 r12 修订，也在同一个 PR 里改。
- **提请的内容**：§1.2 的全部裁决。另外写明不改变的部分：不改任何 Requirement、AC 原文、Core baseline、安全不变量或硬件判据。
- **推送前**：`sh scripts/check-sdd.sh`、`git diff --check`。

### WM0.5：平台事实（和 r12 的 review 并行；只产出事实，不写 Windows GJ 的生产代码）

- **SPK-5：NTFS 耐久原语。** 全部在主机侧，你可以独立做完。
  - 要测的原语：`FlushFileBuffers`、`MoveFileExW(MOVEFILE_REPLACE_EXISTING | MOVEFILE_WRITE_THROUGH)`、`LockFileEx`、目录句柄的 flush、替换前后的 FileId；
  - 撕裂尾部的穷举矩阵（用例从 `arkdeck-hoststore` 的 `job_journal_writer.rs` / `job_journal_replay.rs` 移植），以及 append 的 p95；
  - 失败时启用设计 R7 的缓解措施；
  - 记录写到 `evidence/runs/TASK-XPA-005/spk-5-<date>-run.md`。
- **SPK-3 的主机侧部分。**
  - 构建 `windows_spk3`，通读 `windows-spk3.ps1`；
  - 不需要安装、不需要凭据的行由你来跑，尤其是：在 `CreateFileW` 打开的客户端句柄上调用 `GetNamedPipeServerProcessId`，结果记为 pass 或 fail（fail 会翻转 §F.2 的边界表述），以及非提权用户下的身份路径；
  - 需要维护者的行写成带编号的清单：签名身份、第二账户、提权终端、远端主机、MSIX 注册；
  - 条件不具备的行保持 `NOT_RUN`；
  - 记录写到 `evidence/runs/TASK-XPA-002/spk-3-<date>-run.md`。
- **真机采样 crib**，由你起草，维护者运行：
  1. HDC Windows 版的 `-v`、`checkserver`、`list targets -v` 输出，不接板和接板各一次；外加版本、SHA-256、签名、MotW 状态和来源渠道。对照 `openspec/integrations/openharmony/profile.md` 里 macOS 已登记的 3.2.0d 和 3.2.0f。
  2. DAYU200 在 Windows 上的 USB 设备属性（SetupAPI / CfgMgr32 能看到的字段），供 XPA-004 使用。

  两份 crib 都要脱敏后再入仓。
- **开发期 daemon 身份**：r12 合入后，按裁决把维护者要执行的步骤写成清单。

### WM1：GJ-1（XPA-002 的 Windows 验收 → XPA-004 → XPA-005 → XPA-006）

- **Windows HDC integration change**：用 WM0.5 的采样结果，按 `evidence/xpa-002-readonly-foundation.md` 里「Windows HDC registration scope」的要求，起草独立的 OpenSpec change 和 PR。
- **XPA-002 的 Windows 验收（软件部分）**：Windows 上 `doctor`、`operation list`、`device candidates` 的机器输出，与 macOS 的 fixtures 逐字节相等。
- **XPA-004**：
  - bootstrap 状态机；
  - targets store 用与 macOS 相同的 JSON，`.targets.lock` 用 `LockFileEx`；
  - stable identity 与 macOS 完全一致；
  - Windows 上可信 USB 关系的普查，相当于 macOS 的 `UsbRegistryRelations`；
  - HAR 的 `physicalConnection` / `needsSelection` / `waitingForHuman`。
- **XPA-005**：
  - durable 层落在 NTFS 上；
  - 准入流水线按已发布的顺序执行；
  - `-t <connectKey>` 只从唯一的注入点加入；
  - HDC server 身份证明（Windows 版 `LoopbackServerLease` 已有）；managed HDC 的启停语义照 macOS（#2131）移植；
  - 重启后读回；XPA-AC-7 的 kill 矩阵。
- **XPA-006**：
  - `capture.diagnostics@1`、artifact 的 read/export、HAR 崩溃后 resume；
  - 在 `conformance-cases.yaml` 里补上对应的行。
- **Windows 的开发组合**：对应 macOS 的隔离开发根。按 §1.2 第 8 条的身份裁决来设计，不许有旁路。
- **完成的定义**：runbook §GJ-1 的每一步都能在 Windows 上用 fake HDC 由 CLI 跑通；真机那一行留给阶段 A。

### WM2：GJ-2/3（XPA-008 → XPA-009）

- **XPA-008**：durable import、capability store 与 ledger（T0）、deviceMutation 准入（capability 只由 Runtime 签发、预留、消费）、`debug.hap@1`。
- **XPA-009**：ELF / ABI / Build-ID 校验；code-sign helper 在 Windows 上重建或移植到 Rust；回滚那一腿。

### WM3：GJ-5（XPA-011）

- workspace 与 analyzer 两个 provider；
- 密钥库口令存到 Credential Manager；
- 工具链只认已登记的引用，不从 PATH 取；
- 存在性检查走 HAR console challenge；
- 任何秘密都不进 argv、环境变量或 receipt。
- DevEco、hvigor、hap-sign-tool、node 在 Windows 上的安装形态，先用一份 crib 让维护者确认。

### WM4：GJ-4（XPA-010，D2，destructive）

- 在 Windows 上实现 Rust ArkForge lane：daemon 负责 spawn `arkforged.exe`，经 stdin 配对，按 StepPermit 执行，最后是 readback、rebind、postflight。
- plan 阶段的 digest 必须与已录的 flash-plan oracle 一致；故障注入时零派发。
- 真机要等 AF-W1，并由维护者逐次放行。

### WM5：Windows 客户端（SPK-4 → XPA-007 → XPA-020 → XPA-021）

- **SPK-4**：按设计 §H.4 的 (a)–(e) 判定；需要的 Visual Studio 工作负载和 Windows App SDK 先列给维护者装。
  - (a)–(e) 任一项失败，且两周内修不好，就改用 WPF；语义契约和 ClientKit 不变。
- **XPA-007**：
  - `windows/**` 工程、`.NET ClientKit`（由 `spec/control/methods/**` 生成）；
  - `spec/ui-semantics/**`；双语资源生成 `.resw` 和 `.xcstrings`（值不变）；
  - `plan.py` 的 `windows` 车道（非 Windows 主机上 `--run-local` 必须报「不可运行」并以非零退出），同时更新 `scripts/ci/test_plan.py` 与 `scripts/test_agent_pr_workflow.py`；
  - ClientKit 拒绝 owner SID 不是当前用户的 pipe，并显示 daemon 不可用的恢复横幅。
- **XPA-020**：六个页面，各自依赖对应的 GJ 完成后再接（见 tasks.md）。未实现的能力显示 `unavailable(reasonCode)` 和对应的 CLI 路径，不放禁用的占位控件。
- **XPA-021**：按决策 5 交付。

### WM6：发布候选与收口

- **XPA-022 的软件部分**：MSIX 与 xcopy 的构建脚本、签名接入点、App Installer 更新源、卸载路径；写好干净主机 smoke 的 runbook。
- **CLI 覆盖**：确认 coverage 已达到出口第 4 条。
- **`conformance-cases.yaml`**：GJ 相关的行齐全，状态都保持 `NOT_RUN`，等阶段 A。
- **性能**：让 `scripts/bench` 和 soak 能在 Windows 上跑起来；正式测量属于阶段 A 的参考主机。
- **阶段 A 的 runbook**：按顺序写出维护者要做的事——身份、采样、SPK-3 行、GJ-1..5、干净主机、翻转——每一步写清命令和预期。

### 车道（r12 合入后可以并行）

- **Runtime 车道**：WM1–WM4，以及 WM6 的 coverage 部分。拥有 `rust/**`。
- **Client 车道**：WM5。拥有 `windows/**`、`spec/ui-semantics/**`，以及 `plan.py` 的 `windows` 车道。

两条车道各用一个 worktree 和各自的 `CARGO_TARGET_DIR`。开工时维护者会说明你是哪条车道；没说就按 Runtime 车道做，Client 车道在 Runtime 车道空闲时推进。

---

## 4. 何时停下、何时问维护者

**只有下面几种情况才停下来问。** 问的时候写成一行，并给出选项：

- 安全不变量冲突；
- 必须由维护者做的操作（§1.1）；
- 需要 OpenSpec change 的改动；
- Windows 满足不了某条 Core requirement（这时标 `blocked` 或 `nonConformant`，不绕过）。

**其他情况一律继续推进：**

- 不停在「PR 等待 review」上；
- 不问「要不要继续」；
- 不在汇报末尾预告下一步却不去做。
- 等 r12 合入期间做 WM0.5；等维护者操作期间，做下一个不依赖它的切片。

**只有剩下的工作全都在等维护者时才收尾，** 并写明卡在哪一扇门、需要谁做什么。

**跨机协作。**

- 你看不到 Mac 上的会话。macOS 的 RC 和阶段 A 可能随时往 `rust/**` 合入修复，所以要勤 rebase。
- 要改 macOS 侧拥有的东西（`scripts/release/**`、`Packages/**`、`ArkDeckApp/**`）时，在 commit message 里说明，并把改动控制到最小。

## 5. 仪表盘与汇报

`evidence/windows-remaining.md` 只放一张表，在每个里程碑结束时刷新。列如下：

| Windows 上可执行的 operation（/30） | Windows daemon 应答的方法（/105） | GJ 软件就绪（/5） | GJ 真机（/5，阶段 A） | CLI coverage windows `implemented`（/256） | 客户端页面（/6+1 骨架） | SPK-3 / SPK-4 / SPK-5 |
| --- | --- | --- | --- | --- | --- | --- |

每一轮按 PRODUCT-LOOP §19 用中文简要汇报：

- 实际改了什么（分支和 PR 号）；
- 验证结果，分「Local targeted checks」和「CI」两段；
- 实际的阻塞，以及需要谁做什么；
- 仪表盘有变化时，附上新的那一行。

没做的检查要如实说明。不贴 GJ 全表，不写治理循环状态，不为凑格式编造下一步任务。
