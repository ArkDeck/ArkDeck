# Tasks

## TASK-SDR-001 — shared SDD runtime discovery and explicit bootstrap

- Status:blocked（等待 CHG-2026-034 经维护者 approval-only PR 批准，并由独立
  readiness PR 固定 source pins、测试矩阵和实现基线；本 proposal PR 不产生
  readiness 或实现授权）
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
