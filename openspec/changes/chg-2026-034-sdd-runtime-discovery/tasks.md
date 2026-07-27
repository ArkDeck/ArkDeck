# Tasks

## TASK-SDR-001 — shared SDD runtime discovery and explicit bootstrap

- Status:ready（r1；仅在维护者按序 merge 前序 approval carrier 与本独立
  readiness PR 后生效；`Decision-Grade` 行由维护者亲笔（#577 先例），本文件
  不代写）
- Historical Status:blocked（前置：① 本 change approval-only PR merge；
  ② 独立 readiness PR。① = 堆叠前序 carrier 分支
  `agent/chg-2026-034-approval`（rebase 会改其 commit OID 故不钉；squash-merge
  OID 由维护者合并记录承载，本文件不回填）；② = 本 r1。原文：等待 CHG-2026-034 经维护者 approval-only
  PR 批准，并由独立 readiness PR 固定 source pins、测试矩阵和实现基线。）
- Readiness（r1；audit base = protected `main`
  `d5fac1e0d68e35c1ff0439848500de4a1b60d312`（#605））：
  - **Approval boundary:pending human merge。**本 carrier 只修改本文件；堆叠
    期 PR diff 含前序 approval 翻转（proposal.md），故标题走 governance 形态
    （#593 先例，#592 反例）。只有 `lvye` 对 exact head APPROVED、required
    checks terminal success、`mergedBy=lvye` 的 squash merge 进入 protected
    main 后，本 readiness 才生效；前序 approval carrier 必须先合
    （#589/#590 堆叠按序先例），其未合前本 PR 不得合并。
  - **Dependency gate:in-tree closed。**propose #523 merge
    `005e1ffc321b2dbc87409895ac28c290b93f7e24`（audit-base ancestor）；
    approval 翻转在本 PR 树内机器可验（proposal.md header
    `status: approved`）。
  - **Source pins:closed（全部于 audit base `git rev-parse` 实测）。**实现
    base 须逐项等于：`scripts/check-sdd.sh`
    `3ab25cfa5603a74a4ed8e99b54e55a1afaf4e256`、
    `scripts/requirements-sdd.txt`
    `f62ce0c56db2b5d134cff98f7fb1625023cd2874`（内容恰一行
    `PyYAML==6.0.3`）、`.python-version`
    `3f0a10fda703c327eb329f869a19cc5cc05af521`（`3.14.6`）、
    `openspec/README.md`
    `890f6f7a1abac7d81252b001d82ee7e8892a13f9`；本 change r1 全件：
    proposal.md `b81894b1861c87d50fe682b3e888ca99b3d29bce`（本链翻转前
    原文）、design.md `14db28fa791dc7f74dbe2bf7e4936bbce956d37e`、
    tasks.md `142d9286a52f52cad3ddd856cc224cdc91b80b2e`（本 carrier 前
    原文）、verification.md `940a7e85c065361f3a096430d2d3ddcbdd2c9a46`、
    acceptance-cases.yaml `2b598c5d2c46f86ee2fcabe2a636990e0313bf7c`、
    spec-impact.md `c526896afd3ffd2ccc7bf8b7a553746cfa5e4022`、
    evidence/README.md `fc5f8f721353a76478f4ac8d6a3d0bf46831a65d`。任一
    drift 停并重钉。**预期漂移注记**：`scripts/check_sdd.py`/
    `scripts/test_check_sdd.py` 属本任务 Forbidden 且是 CHG-2026-040
    TASK-DEC-003 的授权改动面，**不入 pin**；全套验证按实现时 protected
    main 现状运行（关系式而非字节钉，#597 先例），先落地者语义为准。
  - **Implementation contract:binary（2026-07-27 audit base 探针实测）。**
    ① resolver 四级优先级与 fail-closed 语义 = design.md §0-§2 原文（blob
    已钉）：`ARKDECK_PYTHON` → 当前 checkout `.venv-sdd/bin/python` → 经
    `git rev-parse --git-common-dir` 规范化推导的 primary-checkout venv →
    PATH `python3`；已选中候选 preflight 失败即 fail closed，禁止静默
    降级；token 不拆词、不 eval、外部调用全部独立引参。
    ② **红探针（audit base 实测）**：无 venv 的 linked worktree 裸跑
    `./scripts/check-sdd.sh` → `ModuleNotFoundError: No module named
    'yaml'` raw traceback，exit 1；实现后同输入必须自动只读复用 primary
    venv 并 PASS；且 design §4 的 shared-discovery removal red canary
    必须在案（全绿套件单独不作机制证据）。
    ③ **绿对照（audit base 实测）**：`ARKDECK_PYTHON=<primary>/
    .venv-sdd/bin/python ./scripts/check-sdd.sh` → `check_sdd: 0
    error(s), 0 warning(s), 111 acceptance IDs`，exit 0；primary venv =
    CPython 3.14.6 + PyYAML 6.0.3 == 两 pin 文件；linked worktree
    `git rev-parse --git-common-dir` = `<primary>/.git`（推导前提实测
    成立）；PATH `python3` import yaml 失败（PEP 668
    externally-managed host，全局 pip 非法路径）。
    ④ 诊断契约 = design §2：五类稳定失败各具名；输出选中来源
    （explicit/worktree/shared/PATH）与唯一显式 bootstrap 指引；零
    traceback、零 env dump；preflight 通过后同一解释器执行
    `check_sdd.py`，无二次解析。
    ⑤ bootstrap 契约 = design §3：仅人工直接调用 `scripts/
    bootstrap-sdd.sh`；目标唯一 = primary checkout 的 ignored
    `.venv-sdd`；argv 数组安装当前 checkout requirements；禁
    `--break-system-packages`/profile 写入/删除既有环境/自动运行；并发
    bootstrap 必须可见失败；checker 永不调用 bootstrap/pip/venv。
    ⑥ 测试矩阵 = design §4 全项（stdlib-only `scripts/
    test_sdd_runtime_entry.py`，临时仓库 + fake argv 目标，零下载），
    含 pip/venv/network canary 调用数恰 0 与当前仓库真实
    linked-worktree integration。
    ⑦ File partition：diff 恰在 Allowed paths 内（`check-sdd.sh`、新
    `bootstrap-sdd.sh`、新 `test_sdd_runtime_entry.py`、
    `openspec/README.md`、本 change `evidence/**` 与 tasks.md 注记）；
    Forbidden 面（含 DEC-003 全部改动面与 `.github/**`）零字节——与
    CHG-2026-040 八任务文件集互斥是两 change 的设计结果。
    ⑧ 套件门：audit base 基线 = guard `0/0/111`；实现后
    `test_sdd_runtime_entry.py` 全绿 + `test_check_sdd.py`（实现时
    main 现状）+ linked worktree plain `./scripts/check-sdd.sh` +
    `python3 scripts/test_check_pr_paths.py` + `git diff --check` 全部
    通过，精确计数入 HEAD commit message 与 evidence run。
  - **Deployment terms:closed。**host-only 入口脚本，合入即对任意
    checkout 生效；零 launchd/CI/workflow/设备动作；primary venv 属
    ignored machine state 不随 PR 交付；clean-host bootstrap 与既有
    venv 两路径分别取证（Notes 原则），不得以本机既有 venv 冒充
    clean-host 证据。
  - **Concurrency/absence:closed at drafting（2026-07-27T10:20+0800）。**
    remote `agent/*sdr*` 分支 = 0（实测）；双 carrier 已 rebase 到
    `75926f1`（#610）；audit base 后落入的 #601-#610（chg-039
    verify+archive、chg-027/028/030 archive）对本 change 关注面零触碰
    （`git diff --stat 005e1ff..75926f1 -- <四 pin + check_sdd.py + 本
    change 目录>` 实测为空），audit-base 探针与全部 pin 保持有效。
  - **Grade 注记**：`Decision-Grade` 行由维护者亲笔（#577 载体先例）；
    契约①-⑧机器可判；载体 = 常规会话 `agent/*` PR；`TASK-SDR` 根不在
    `NEVER_CLAIM_ROOTS`，grade 缺省 `unknown` 即不可被循环认领（grade
    与 claim 面解耦，NAV 先例），是否给 grade/是否扩根由维护者另行
    决定。
- Platform:macos / linux host tooling
- Requirements:无 canonical Requirement；只实现本 change 的 no-op spec impact。
- Acceptance:`SDR-DISCOVERY-001`、`SDR-DIAGNOSTIC-001`、
  `SDR-BOOTSTRAP-001`
- Depends on:none
- Readiness input pins:由批准后的独立 readiness PR 固定；至少覆盖
  `scripts/check-sdd.sh`、`scripts/requirements-sdd.txt`、`.python-version`、
  `openspec/README.md` 与本 change r1 的完整 Git blob OID。
- Applicable failure patterns:`AF-007`（消除每个 worktree 的隐式本机依赖）、
  `AF-008`（在 design 阶段封闭 resolver/bootstrap 负向矩阵）、
  `AF-017`（只做最小共享发现，不引入 daemon/package manager）、
  `AF-018`（多会话只读复用同一明确 machine state，不轻信会话自报）
- Production reachability:not applicable；host-only SDD tooling，不含产品
  composition、authority 或 effect dispatch。
- Trusted fact sources:Git executable 产生当前 checkout 的 common-dir；当前 checkout
  的 `scripts/requirements-sdd.txt` 产生 PyYAML pin；被选 Python 自报可导入模块和
  version。调用方可显式选择 interpreter，因此显式候选失败必须 fail closed，不能把
  调用方输入升级为“可信 pinned runtime”或静默改选。
- Allowed paths:
  - `scripts/check-sdd.sh`
  - `scripts/bootstrap-sdd.sh`
  - `scripts/test_sdd_runtime_entry.py`
  - `openspec/README.md`
  - 本 change `evidence/**`
  - 本 change `tasks.md`（仅本任务的独立 status/evidence 更新）
- Forbidden paths:
  - `.python-version`
  - `scripts/requirements-sdd.txt`
  - `scripts/check_sdd.py`
  - `scripts/test_check_sdd.py`
  - `.github/**`
  - `AGENTS.md`
  - `openspec/constitution.md`
  - `openspec/governance/**`
  - `openspec/verification/policy.md`
  - `openspec/specs/**`
  - `openspec/contracts/**`
  - `openspec/changes/archive/**`
  - `Packages/**`
  - `ArkDeckApp/**`
- Risk:low（host-only entrypoint；主要风险是错误解释器选择、路径拆词或 bootstrap
  隐式副作用，均由优先级/空格路径/零 pip canary 与 linked-worktree 正反测试收口）
- Hardware required:no；device/HDC/network/product/destructive dispatch 均为 0。

### Deliverables

- `check-sdd.sh` 的 primary-checkout shared venv resolver 与稳定 dependency
  preflight/diagnostic。
- 人工显式 `bootstrap-sdd.sh`；checker 与 bootstrap 保持单向提示、零自动调用。
- stdlib-only host contract suite，覆盖 design §4 的正反矩阵。
- `openspec/README.md` 最小入口说明。
- `evidence/runs/TASK-SDR-001/run.md`：source/base OID、逐文件 hash、解释器/PyYAML
  facts、测试清单与计数、linked-worktree red canary、plain checker 结果、零隐式
  pip/network/device dispatch、偏差和遗留风险。

### Verification

- `SDR-DISCOVERY-001`：临时 primary + linked worktree 以及当前真实 worktree
  integration；plain checker 自动选择同 repository primary venv并保持
  0 errors / 0 warnings / canonical acceptance count。
- `SDR-DIAGNOSTIC-001`：缺 module、错版本、坏 pin、不可执行候选、空格路径与
  高优先级坏候选全部稳定 fail closed；无 traceback、无下级静默 fallback、pip/venv
  canary 调用数为 0。
- `SDR-BOOTSTRAP-001`：fake base/venv Python 验证 exact primary target 与 pip argv；
  checker 不触发 bootstrap；人工 bootstrap 接口不使用全局 pip 或
  `--break-system-packages`。
- 全套：fixed shared Python 运行 `scripts/test_sdd_runtime_entry.py`、
  `scripts/test_check_sdd.py`、`scripts/check-sdd.sh`；另运行
  `python3 scripts/test_check_pr_paths.py` 与 `git diff --check`。

### Notes / handoff

- 本任务只有一个 resolver/bootstrap 信任边界，不拆为多个实现 task。
- readiness、implementation/evidence、`ready→done` 与 change verification 分离；
  implementation PR 不修改本 status 行。
- 不以本机已有 primary venv 证明 clean-host bootstrap；两条路径分别取证。
