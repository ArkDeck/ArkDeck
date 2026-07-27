---
id: CHG-2026-034-sdd-runtime-discovery
revision: 1
status: archived # 2026-07-27 本 archive PR（先例 #235/#241/#605/#610）；verify 于前序堆叠 carrier；引用扫描：目录外精确路径引用 0（实测 git grep）；scripts/check-sdd.sh、bootstrap-sdd.sh 与 test_sdd_runtime_entry.py 为长驻交付物不随档移动；本 change 归档后 checker 行为不变
class: implementation-only
core_change_level: none
owner: lvye
core_baseline: CORE-2.1.0
platforms: [macos, linux]
---

# SDD checker 共享运行时发现与显式 bootstrap

## Why

`scripts/check-sdd.sh` 当前按“`ARKDECK_PYTHON` → 当前 checkout 的
`.venv-sdd` → PATH `python3`”选择解释器。Codex 与人工并行工作通常使用 linked
worktree；每个 worktree 都没有被忽略的本地 `.venv-sdd`，但同一 Git repository 的
primary checkout 已有机器级 pinned SDD venv。入口无法发现该共享环境，因而反复落到
PATH Python，并在 `import yaml` 时以 `ModuleNotFoundError` 退出。

2026-07-25 的只读复现确认：

- linked worktree 的 PATH Python 是 CPython 3.14.6，但没有 PyYAML；
- Homebrew Python 受 PEP 668 externally-managed environment 保护，不能把全局
  `pip install` 作为修复；
- 同一 repository 的 `<PRIMARY_CHECKOUT>/.venv-sdd/bin/python` 已是 CPython
  3.14.6 + PyYAML 6.0.3；
- 显式设置 `ARKDECK_PYTHON=<PRIMARY_CHECKOUT>/.venv-sdd/bin/python` 后，
  `scripts/check-sdd.sh` 通过，结果为 0 errors / 0 warnings / 111 acceptance IDs。

该问题已经在多个 task evidence 中重复出现；每个会话重新发现绝对路径或临时创建
venv，既浪费时间，也把机器路径和临时环境选择带入 run 记录。

## What changes

### In scope

- `check-sdd.sh` 在当前 worktree 没有 `.venv-sdd` 时，通过当前 repository 的 Git
  common directory 推导 primary checkout，并自动发现其中的共享
  `.venv-sdd/bin/python`。
- 固定解释器优先级为：显式 `ARKDECK_PYTHON` → 当前 checkout venv → 同一 Git
  repository 的 primary-checkout venv → PATH `python3`。
- 选中解释器后先做 PyYAML import/version preflight；失败时输出选中解释器、缺失或
  漂移原因，以及唯一的显式 bootstrap 入口，不再泄漏 Python traceback。
- 新增人工显式调用的 bootstrap 脚本，在同一 Git repository 的 primary checkout
  创建/更新一次 `.venv-sdd`，安装 `scripts/requirements-sdd.txt`。
- 增加纯 host contract tests，覆盖普通 checkout、linked worktree、优先级、路径含
  空格、Git 不可用、缺依赖、版本漂移、损坏的高优先级候选和零隐式安装。
- 在 `openspec/README.md` 的 Agent 入口旁登记首次机器 bootstrap 与 checker
  只读边界。

### Out of scope

- checker 自动创建 venv、自动执行 pip、自动联网或修改用户/系统 Python；
- 使用 `pip --break-system-packages`、修改 shell profile 或为每个 worktree 复制
  venv；
- 修改 `.python-version`、`scripts/requirements-sdd.txt`、PyYAML pin、
  `scripts/check_sdd.py` 的校验语义或任何 SDD pass/fail 规则；
- 修改 `.github/workflows/**`、required status、批准语义、Core/spec/contract、
  product source 或平台支持声明；
- 将 primary-checkout venv 解释为仓库内容、evidence、授权载体或可提交 artifact。

### Observable behavior before/after

- Before：linked worktree 的 plain `./scripts/check-sdd.sh` 忽略同 repository 已存在
  的 pinned venv，回落 PATH Python；缺 PyYAML 时直接 traceback。
- After：同一命令只读复用 primary-checkout venv；无可用 pinned dependency 时以
  稳定诊断失败，并要求人工显式运行 bootstrap。checker 本身始终零安装、零联网、
  零 repository mutation。

## Scope(涉及的 Requirement/AC)

- Canonical Requirements:无；本 change 只修改 host-side development/governance
  tooling。
- Canonical Acceptance:无。
- Change-local Acceptance:`SDR-DISCOVERY-001`、`SDR-DIAGNOSTIC-001`、
  `SDR-BOOTSTRAP-001`。
- Contracts/schemas:无。
- 是否需要 Core baseline bump:否；见 `spec-impact.md`。

## Safety, privacy, and compatibility

- Git common-dir 只用于定位同一 repository 的 primary checkout；结果必须规范化为
  绝对目录，并只拼接固定 `.venv-sdd/bin/python` 后缀。不得从 Git config、branch、
  PR 文本或调用方输入生成命令。
- 首个已声明候选被选中后若 preflight 失败，入口 fail closed，不静默降级到另一解释器；
  这避免 stale/被替换的高优先级环境被掩盖。
- `check-sdd.sh` 不调用 bootstrap、pip 或 venv，不写工作树、primary checkout、用户
  目录或 cache。bootstrap 的写入和依赖安装只在用户直接调用时发生。
- 诊断不得输出 home 目录、环境变量全集、pip 配置、token 或其他 secret；允许输出
  实际选中的 Python 路径，run evidence 仍按各 task 的 privacy 约束脱敏。
- 普通 checkout、linked worktree 和 Git 不可用的 source tree 均有封闭回退；路径含
  空格必须保持单 argv token。
- rollback 为单次 revert 本 task 的脚本、测试与入口文档；已创建的本地
  `.venv-sdd` 是 ignored machine state，不影响 repository tree。
- macOS/Linux host tooling 需要复验；产品 macOS/Windows/Linux 行为与 conformance
  状态均不变。

## Approval and flow

本 proposal PR 只登记 change package，不修改脚本、CI 或现有文档入口，不产生 task
evidence，也不构成 change approval/readiness。维护者批准 change 后，
`TASK-SDR-001` 仍须经独立 readiness PR 从 `blocked` 转为 `ready`；其后
implementation/evidence、`ready→done`、verification 状态分别按仓库规则独立提交。

## Verification closure（2026-07-27）

唯一任务 done 于 protected main 在案，三条 change-local AC 证据可复查；本 PR
仅状态翻转 + 引用，零实现夹带（先例 #224/#239/#570/#571/#601）。

- **任务链**：propose #523 merge
  `005e1ffc321b2dbc87409895ac28c290b93f7e24`；approval #611 merge
  `ecd5320b35308ddd44f67fb6a825a9c5f9e3fc1b`；readiness r1 #612 merge
  `982b679bf3fbc71b3422031a04e0e11b1e5592d2`（堆叠 governance carrier，
  #593 形态）；实现 = #618 merge
  `8a3482c7ae6aa1f525ca62507e6794d8acc20dea`（合入内容与实现分支五文件
  逐字节一致，done flip 复核在案）；done #620 merge
  `91d9c07d596ba7acecbc1af0e7feaf64f69adb9e`。evidence =
  `evidence/runs/TASK-SDR-001/run.md`（随 #618 在树）。
- **SDR-DISCOVERY-001 = PASS**：resolver 精确遵守 explicit → worktree →
  shared → PATH（`test_sdd_runtime_entry.py` 正/负 fixture，含真实 git
  linked-worktree 拓扑与 CI 形态裸名 `ARKDECK_PYTHON=python`）；本机
  audit-base 红探针（无 venv worktree 裸跑 = `ModuleNotFoundError`
  traceback、exit 1）实现后同命令转绿（`0 errors / 0 warnings / 111
  acceptance IDs`、exit 0，经 primary 共享 venv 只读复用）；Git 二进制
  不可用/无 Git metadata 封闭回退；含空格路径保持单 argv token。
- **SDR-DIAGNOSTIC-001 = PASS**：五类具名稳定失败（缺 executable、无法
  启动、缺 module、版本漂移、坏 pin 三态）全部 exit 2 且零 traceback、
  零 env dump；坏高优先级候选阻断健康低级候选（fake 解释器日志证零降级
  调用）；pip/venv/curl/wget canary 调用数恰 0；checker 运行前后工作树
  文件清单逐项一致（零写入）；shared-discovery removal red canary 在成品
  脚本上绿转红（全绿套件单独不作机制证据，design §4 要求履行）。
- **SDR-BOOTSTRAP-001 = PASS**：fake base/venv Python argv 契约证 bootstrap
  目标唯一 = primary checkout `.venv-sdd`（linked worktree 内调用亦然）、
  pip argv = `-m pip install --require-virtualenv -r
  scripts/requirements-sdd.txt`（无 `--break-system-packages`）、既有环境
  保留不重建、venv/pip/post-install 三类失败均可见非成功、并发锁可见
  失败；checker 拒收半成品 bootstrap 产物。**边界如实**：clean-host 真实
  bootstrap 未在本机执行（本机 venv 先于本任务存在，两路径分别取证原则），
  留作未来人工动作，已记 run.md Deviations。
- **suite 基线**：新增 `test_sdd_runtime_entry.py` 33 tests；
  `test_check_sdd` 19 OK 与 `test_check_pr_paths` 24 OK 于实现时现状复跑
  （r1 关系式条款，DEC-003 面零钉）；guard 维持 `0/0/111`；CI
  `sdd-guard.yml` 零改动（`ARKDECK_PYTHON=python` 显式路径由 preflight
  原样放行，#618 CI 实证）。
