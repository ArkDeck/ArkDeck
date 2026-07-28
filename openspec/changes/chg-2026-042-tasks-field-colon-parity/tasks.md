# CHG-2026-042 Tasks

本 change 只含一个实现任务。它修改 host-loop discovery 自身，按既有
HLR/NAV/DEC 先例由会话实现：`Decision-Grade` 在实现前保持缺失；实现须把
`TASK-CM7-001` 纳入 `NEVER_CLAIM_ROOTS`，不得让循环认领改写自身读取门的工作。

## TASK-CM7-001 — 对齐 `tasks.md` 字段冒号文法并锁定跨解析器契约

- Status:blocked（r1 approval 已由 PR #702 merge
  `3703a96ea334dc2ec2598008bd9c070190832127` 满足；本 r2 只更正计数门，
  r2 与其后的独立 D1 readiness 均合入前，本任务不 ready）
- Platform:macos（host-only）
- Requirements/AC:change-local `CM7-PARITY-001`、`CM7-CORPUS-001`、
  `CM7-SELF-001`
- Depends on:none（change approval 与 readiness 由状态/PR 门承载，不伪装为
  TASK 依赖）
- Readiness input pins:未实例化；独立 readiness 必须重钉实现/测试文件 blob、
  protected-main base、活跃 `tasks.md` 语料清单与 before/after 候选清点
- Applicable failure patterns:`AF-004`（同一契约多消费者语义分歧）、
  `AF-010`（必须用独立 fixture 与变异反证）、`AF-015`（全仓清点同模式）
- Production reachability:`python -m host_loop --once` →
  `discover_all` / `discover_candidates` → `Worker.select`；独立消费者
  `check_pr_paths.extract_allowed_patterns` 只用于 PR 路径守卫。两条链均为
  host governance automation，不到达产品/device effect。
- Trusted fact sources:protected-main Git bytes、活跃 change 的真实
  `tasks.md`、两个生产解析入口的可执行输出；测试不得从被测正则反推期望值，
  候选差分必须记录 task ID、status、grade、hardware 与 dependency。
- Allowed paths:
  - `scripts/host_loop/__main__.py`
  - `scripts/host_loop/worker.py`
  - `scripts/host_loop/test_navigation_contract.py`
  - `scripts/host_loop/test_token_parity.py`
  - `scripts/test_check_pr_paths.py`
  - `openspec/changes/chg-2026-042-tasks-field-colon-parity/evidence/**`
  - `openspec/changes/chg-2026-042-tasks-field-colon-parity/tasks.md`（仅本任务
    状态/evidence 引用）
- Forbidden paths:
  - `scripts/check_pr_paths.py`
  - `scripts/check_sdd.py`
  - `scripts/host_loop/instance.py`
  - `scripts/host_loop/backends.py`
  - `scripts/host_loop/cursor.py`
  - `scripts/host_loop/identity.py`
  - `scripts/host_loop/lease.py`
  - `scripts/host_loop/pr_envelope.py`
  - `scripts/host_loop/recovery.py`
  - `scripts/host_loop/reviewer.py`
  - `scripts/host_loop/transport.py`
  - `.github/**`
  - `openspec/changes/chg-2026-036-macos-bundled-rockchip-component/**`
  - `openspec/changes/archive/**`
  - `openspec/constitution.md`
  - `openspec/specs/**`
  - `openspec/contracts/**`
  - `openspec/baselines/**`
  - `Packages/**`
  - `ArkDeckApp/**`
- Risk:medium（候选集合会扩大；全部 claim/authority 门必须逐字保持，且当前
  新增候选必须全部为 done/blocked）
- Hardware required:no

### Deliverables

- `Depends on` 与 `Allowed paths` 仅接受 `:` / `：` 的 host-loop 实现，
  删除 C-M7 已知残留注记，不改变字段的其他解析语义；
- ASCII / 全角、inline / 合法缩进续行、空值 / 散文 / 非法分隔符的双向 fixture；
- host-loop 与 `check_pr_paths` 的 `Allowed paths` 跨解析器 parity test；
- protected-main 活体语料 before/after 清点：零 lost，gained 逐项归因且
  status/grade/hardware/dependency 全量记录；
- `TASK-CM7-001` never-claim 根及精确内容、suffix、撤销即红测试；
- `evidence/runs/TASK-CM7-001/run.md`，记录命令、计数、变异结果、AC 结论与
  residual risk。

### Verification

- `CM7-PARITY-001`：同一合法 task 用 `:` 与 `：` 时，host-loop 产生完全相同
  的 `TaskCandidate`；`check_pr_paths` 对两种 `Allowed paths` 写法产生相同路径；
  既有 ASCII、续行、空值与散文排除测试保持全绿；非法第三种分隔符仍 fail closed。
- `CM7-CORPUS-001`：readiness 钉定的全部活跃 `tasks.md` 做实现前后 executable
  diff，lost 为 0，gained 恰为 `TASK-BRC-001`…`TASK-BRC-006`，且六项均
  done/blocked、不得 ready / 可 dispatch。总数是绑定 exact tree 的诊断快照而非
  语义 pin：pre-proposal `e114d9d3ae668bff68d2cfb69c59fa6f4dff00ec` =
  26→32；approved-main `20aeee5653d7eece08911c0a84afc92c1fa09702` =
  27→33（新增本 TASK-CM7-001）；open PR #704 exact head
  `7a5da66fdf4e1cf09018a538312523899dacdeba` = 28→34（再新增 ASCII
  TASK-OBS-001R）；三者 lost/gained
  集合完全相同。后续无关 ASCII task 可使两侧对称增减；任何 lost、未登记
  gained、或六个 gained task 中出现 ready / 可 dispatch，仍须停止并走
  proposal revision。
- `CM7-SELF-001`：`is_never_claim("TASK-CM7-001")` 及合法 suffix 恒为 true，
  相邻非本任务 token 不受影响；撤销该 root 时专属测试必须红。
- 全量门：`scripts/check-sdd.sh` 保持 0 error / 0 warning / 111 acceptance IDs；
  `scripts/test_check_pr_paths.py` 与
  `python3 -m unittest discover -s host_loop -t .` 全绿；`git diff --check`
  全绿；零网络、零 GitHub 写入、零 device/destructive dispatch。

### Notes / handoff

- 独立 D1 readiness 须重做 open-PR/path overlap、源 blob 与活体语料清点；
  任一输入漂移或新增 ready/可 dispatch 候选都必须停下并修订 proposal。
- implementation PR 只交付代码、测试与本任务 evidence；任务状态翻转走独立 PR。
