# CHG-2026-042 Tasks

本 change 只含一个实现任务。它修改 host-loop discovery 自身，按既有
HLR/NAV/DEC 先例由会话实现：`Decision-Grade` 在实现前保持缺失；实现须把
`TASK-CM7-001` 纳入 `NEVER_CLAIM_ROOTS`，不得让循环认领改写自身读取门的工作。

## TASK-CM7-001 — 对齐 `tasks.md` 字段冒号文法并锁定跨解析器契约

- Status:ready（r3 scope remediation 已由 PR #714 merge，implementation 与
  evidence 已完成且全绿；提交前 #715 改动 active corpus，命中 r3 stop condition。
  r4 exact head 虽已获 review，但 #716 在 r4 pin 后变更 head 才合入，故 r4
  未 merge、未授权恢复。r5 已由 #718 merge，但 19 秒后 #719 又改动 active
  corpus，故 r5 授权未被使用。仅在维护者对下方 r6 exact head
  review/merge 后，才授权恢复并提交同一个 implementation PR；不授权
  `done` / `verified` 翻转）
- Platform:macos（host-only）
- Requirements/AC:change-local `CM7-PARITY-001`、`CM7-CORPUS-001`、
  `CM7-SELF-001`
- Depends on:none（change approval 与 readiness 由状态/PR 门承载，不伪装为
  TASK 依赖）
- Readiness input pins:r1 / r2 / r3 / r4 / r5 为历史快照；现行提交前
  corpus 补救见下方 `Readiness pins(r6,2026-07-28)`。恢复实现前必须复核
  r3 merge、#715 / #716 / #718 / #719 merge 与完成态 stash
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
  - `scripts/host_loop/test_discovery_contract.py`
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

- 本 readiness 只授权一个实现 PR；任一 input pin、活跃语料、并发路径或候选集合
  漂移均须停止并重新 fresh readiness；出现 lost、未登记 gained，或六个 BRC
  candidate 中任何一项变为 ready / 可 dispatch 时必须修订 proposal。
- Implementation evidence:
  `evidence/runs/TASK-CM7-001/run.md`（实现、活体语料、三项 mutation 与 AC
  结论；本 implementation PR 内任务仍保持 `ready`，`done` 翻转另走独立 PR）。
- implementation PR 只交付代码、测试与本任务 evidence；任务状态翻转走独立 PR。

### Readiness pins(r1,2026-07-28)

- **Approval boundary。**Change r1 approval 已由 PR #702 exact head
  `88feb27dfd9ef425af3686ee883c2bdb39b8b822` 获维护者 review 并 merge 为
  `3703a96ea334dc2ec2598008bd9c070190832127`；r2 计数门更正已由 PR #705
  exact head `b04e367bb331f1bdf7fae13a54bd74febcaa52cd` 获维护者 review 并
  merge 为 `7c75dec6bb2f8f8a468a0c05001e35c43d998e22`。两者均为下列 audit
  base 的 ancestor。本 readiness PR 只改本任务段；只有维护者对其 exact head
  review/merge 后，上方 `Status:ready` 才生效。readiness merge 不宣称任一 AC
  passed，不授权实现 PR 夹带状态翻转，也不构成 change verified。
- **Audit base / environment。**Protected `main`
  `14b46e3066c52f54568e97545c59b3506ffc62a4`（2026-07-28T07:34:58Z
  fresh fetch 后的 `origin/main`）；macOS 26.5.2 build 25F84、Python 3.14.6、
  Git 2.55.0。#704 merge
  `02907b69b8fd7d1347ba26822e4a1961415fbc16` 与 #706 merge
  `14b46e3066c52f54568e97545c59b3506ffc62a4` 均已纳入本 base。
- **并发门。**同一 fresh fetch 后 `gh pr list --state open --limit 100` 返回空
  集合，故实现路径、change 路径与活跃语料均无 open-PR 占用。实现开工前必须
  重取 protected `main` 与 open PR files；任一 direct path overlap，或任何 PR
  改动下表活跃 `tasks.md`，均停止并重新 readiness，不以“看似无关”自行豁免。
- **实现/测试/只读输入 pins。**下列 OID 均由 audit base 的 `git ls-tree`
  实测。标为“待改”的文件只允许 Deliverables 所列最小变化；标为 invariant 的
  文件在实现前后必须 byte-identical。

  | File | Blob OID | 约束 |
  | --- | --- | --- |
  | `scripts/host_loop/__main__.py` | `ac3386457245c20507d6da3a16b63b39423b0387` | 待改：只收敛 `_DEPENDS_RE` / `_ALLOWED_RE` 的封闭冒号类并删除 C-M7 残留注记 |
  | `scripts/host_loop/worker.py` | `fd7aa86aede863fb5077fb703fab14f1fb17f8b0` | 待改：只把 `TASK-CM7-001` 加入 exact never-claim roots |
  | `scripts/host_loop/test_navigation_contract.py` | `63e2e0f6e3d634b9316f99b0810da9c71e1adb56` | 待改：discovery/never-claim 独立 fixture 与 mutation-sensitive assertions |
  | `scripts/host_loop/test_token_parity.py` | `efb937541d8da2049819267acc45bf94f3f3be64` | 待改：仅在 token/suffix 边界需要独立落点时修改 |
  | `scripts/test_check_pr_paths.py` | `4490daaf59bee14c4fe1d000606709fa9a355af4` | 待改：跨解析器 `Allowed paths` parity fixture |
  | `scripts/check_pr_paths.py` | `d3c3fe299487c7c8512569c75ba1827b7f3433b9` | invariant：生产 PR guard 真值侧，禁止修改 |
  | `scripts/host_loop/instance.py` | `0e7e16451e0e92a13d9cdfbfe18985e335bc8818` | invariant：claim/instance 门，禁止修改 |
  | `proposal.md` | `b1ee27ce0fc0eafdaefe2dff3822d76e28bb75a8` | invariant：approved r2 scope |
  | `verification.md` | `d641c76cb99d2f85f56c1cd46d2bd53c5257567b` | invariant：planned AC 门 |
  | `acceptance-cases.yaml` | `319b4ae4c9e0102e8c50c1a035d430529a1f3126` | invariant：r2 machine-readable AC |
  | `tasks.md`（本 PR 改前） | `89816243ac8cc7e9b320336ce5576f9e6a30fe36` | readiness 载体；实现须以本 PR merge 后版本为 authority，不要求仍等于改前 blob |

- **活跃语料 pins。**`host_loop.active_change_ids` 在 audit base 返回下列 8 个
  change；表内每个 `tasks.md` blob 都是 corpus 输入，不得漏扫。

  | Active change | `tasks.md` blob |
  | --- | --- |
  | `chg-2026-006-dayu200-m0b-bringup` | `5992c706d24249350bf385b464d58f172a6b7496` |
  | `chg-2026-008-ui-dump-hidumper-wrapper` | `43a6fc5f101deea07265cae33cdcbc6600d54c74` |
  | `chg-2026-022-hdc-supervisor-observability` | `ea4a5348b8a7fd5749703ea6e8ef0fc51c4acd3d` |
  | `chg-2026-025-ai-native-unattended-device-ops` | `3ff434156a8105196a156946cd684c81bbc8bb76` |
  | `chg-2026-026-macos-rockchip-flash-ui` | `5f758fe26dac2dd2f62d362345b560fb6a3523e0` |
  | `chg-2026-031-macos-session-settings` | `6b3656c3e637413b9bd9dfb65336ce4250a14d69` |
  | `chg-2026-036-macos-bundled-rockchip-component` | `de23d56688e713d90a2b12706e8d44651cffa164` |
  | `chg-2026-042-tasks-field-colon-parity` | `89816243ac8cc7e9b320336ce5576f9e6a30fe36` |

- **Executable corpus gate。**在未改工作树中先调用真实
  `discover_candidates` 得到 before，再只在进程内把 `_DEPENDS_RE` /
  `_ALLOWED_RE` 的字段分隔符替换为 `[:：]` 后调用同一入口得到 after：
  `before=28`、`after=34`、`lost=[]`、`gained=[TASK-BRC-001,
  TASK-BRC-002, TASK-BRC-003, TASK-BRC-004, TASK-BRC-005,
  TASK-BRC-006]`。#704 新增的 ASCII `TASK-OBS-001R` 已对称计入两侧；
  #706 改动的 CHG-025 corpus 也已纳入重算。总数仅是绑定本 exact tree 的诊断
  快照；pass/fail 仍只看 r2 集合不变量。
- **Gained candidate 全字段记录。**下列值来自 after 的真实
  `TaskCandidate` 序列；`base_pin` 六项均为 null。实现 run 必须重新生成同一
  结构，不得从本表反向硬编码期望。
  - `TASK-BRC-001`：status=`done`，grade=`unknown`，hardware=`no`，
    depends=`[]`，allowed paths =
    [`docs/release/rockchip-component-distribution.md`,
    `openspec/changes/chg-2026-036-macos-bundled-rockchip-component/design.md`,
    `openspec/changes/chg-2026-036-macos-bundled-rockchip-component/tasks.md`,
    `openspec/changes/chg-2026-036-macos-bundled-rockchip-component/verification.md`,
    `openspec/changes/chg-2026-036-macos-bundled-rockchip-component/evidence/**`]。
  - `TASK-BRC-002`：status=`done`，grade=`unknown`，hardware=`no`，
    depends=`[TASK-BRC-001]`，allowed paths =
    [`vendor/rockchip/**`, `scripts/rockchip_component/**`,
    `.github/workflows/rockchip-component.yml`,
    `openspec/integrations/rockchip/bundled-component/**`,
    `docs/release/rockchip-component-distribution.md`,
    `openspec/changes/chg-2026-036-macos-bundled-rockchip-component/design.md`,
    `openspec/changes/chg-2026-036-macos-bundled-rockchip-component/tasks.md`,
    `openspec/changes/chg-2026-036-macos-bundled-rockchip-component/verification.md`,
    `openspec/changes/chg-2026-036-macos-bundled-rockchip-component/evidence/**`]。
  - `TASK-BRC-003`：status=`blocked`，grade=`D2`，hardware=`no`，
    depends=`[TASK-BRC-002]`，allowed paths =
    [`ArkDeck.xcodeproj/**`, `ArkDeckApp/**`, `scripts/release/**`,
    `scripts/rockchip_component/**`,
    `openspec/integrations/rockchip/bundled-component/**`, `docs/release/**`,
    `openspec/changes/chg-2026-036-macos-bundled-rockchip-component/design.md`,
    `openspec/changes/chg-2026-036-macos-bundled-rockchip-component/tasks.md`,
    `openspec/changes/chg-2026-036-macos-bundled-rockchip-component/verification.md`,
    `openspec/changes/chg-2026-036-macos-bundled-rockchip-component/evidence/**`]。
  - `TASK-BRC-004`：status=`blocked`，grade=`D1`，hardware=`no`，
    depends=`[TASK-BRC-003]`，allowed paths =
    [`Packages/ArkDeckKit/Package.swift`,
    `Packages/ArkDeckKit/Sources/ArkDeckWorkflows/**`,
    `Packages/ArkDeckKit/Sources/ArkDeckStorage/**`,
    `Packages/ArkDeckKit/Tests/ArkDeckContractTests/**`, `ArkDeckApp/**`,
    `ArkDeck.xcodeproj/**`,
    `openspec/integrations/rockchip/bundled-component/**`,
    `openspec/changes/chg-2026-036-macos-bundled-rockchip-component/design.md`,
    `openspec/changes/chg-2026-036-macos-bundled-rockchip-component/tasks.md`,
    `openspec/changes/chg-2026-036-macos-bundled-rockchip-component/verification.md`,
    `openspec/changes/chg-2026-036-macos-bundled-rockchip-component/evidence/**`]。
  - `TASK-BRC-005`：status=`blocked`，grade=`D2`，hardware=`yes`，
    depends=`[TASK-BRC-004]`，allowed paths =
    [`ArkDeckApp/**`, `ArkDeckAppUITests/**`, `ArkDeck.xcodeproj/**`,
    `Packages/ArkDeckKit/**`, `scripts/rockchip_component/**`,
    `scripts/e0_readback/**`,
    `openspec/integrations/rockchip/bundled-component/**`,
    `openspec/changes/chg-2026-036-macos-bundled-rockchip-component/design.md`,
    `openspec/changes/chg-2026-036-macos-bundled-rockchip-component/tasks.md`,
    `openspec/changes/chg-2026-036-macos-bundled-rockchip-component/verification.md`,
    `openspec/changes/chg-2026-036-macos-bundled-rockchip-component/evidence/**`]。
  - `TASK-BRC-006`：status=`blocked`，grade=`D2`，hardware=`no`，
    depends=`[TASK-BRC-005]`，allowed paths =
    [`.github/workflows/**`, `ArkDeck.xcodeproj/**`, `ArkDeckApp/**`,
    `docs/release/**`, `scripts/release/**`,
    `scripts/rockchip_component/**`,
    `openspec/integrations/rockchip/bundled-component/**`,
    `openspec/changes/chg-2026-036-macos-bundled-rockchip-component/design.md`,
    `openspec/changes/chg-2026-036-macos-bundled-rockchip-component/tasks.md`,
    `openspec/changes/chg-2026-036-macos-bundled-rockchip-component/verification.md`,
    `openspec/changes/chg-2026-036-macos-bundled-rockchip-component/evidence/**`]。
  六项均不是 `ready`，且 dependency / grade / hardware 门下均不可 dispatch。
- **独立 parity 与现状门。**构造不复用 host-loop 正则的两个
  `check_pr_paths.TaskDefinition` fixture 后，
  `extract_allowed_patterns` 对 ASCII / 全角两种写法均返回 `('x/**',)`。
  未改实现的 `python -m host_loop --explain` 证明 change 已 approved，而本任务
  因 `blocked` 与 `Decision-Grade=unknown` 被拒绝、`claimable=none`；
  readiness 文本落地后再次执行，仅剩 unknown-grade 拒绝且仍
  `claimable=none`。这证明 D1 readiness 不会让循环认领修改自身的任务。
- **基线回归。**Audit base 实测：`scripts/check-sdd.sh` =
  0 error / 0 warning / 111 acceptance IDs；`scripts/test_check_pr_paths.py` =
  49 tests / 0 failures；`cd scripts && python3 -m unittest discover
  -s host_loop -t .` = 638 tests / 1 expected failure / 0 unexpected failures；
  `git diff --check` = PASS。测试过程仅使用临时目录与 localhost contract
  socket；network、GitHub write、device/HDC、E1/E2/destructive dispatch 均为 0。
- **实现与变异矩阵。**
  - 正向：ASCII / 全角分别覆盖 `Depends on` 与 `Allowed paths` 的 inline、
    合法缩进续行；两种写法产生 byte-equivalent candidate/path tuple。
  - 负向：空值无续行、散文 token、`；` / `;` / 其他分隔符继续 fail closed；
    现有 ASCII fixture 与全量 suite 零回退。
  - mutation A：只撤销 `_DEPENDS_RE` 的全角分支时 dependency/parity 专属测试红；
    mutation B：只撤销 `_ALLOWED_RE` 的全角分支时 discovery 与跨解析器专属测试红；
    mutation C：只移除 CM7 never-claim root 时 exact/suffix 专属测试红；相邻
    token 保持原 verdict；只改注释的负对照必须存活。
  - 实现 run 必须记录三项 mutation 的命令/失败用例与负对照，不得以代码检视、
    grep 或共享被测 helper 代替可证伪执行。
- **开工/停止条件。**实现只可从本 readiness merge 后的 protected `main`
  开始；首先复核本节所有 ancestor、blob、active-change 与 open-PR inputs。
  `tasks.md` 因本 readiness merge 产生的预期 blob 变化不算漂移，但必须确认变化
  仅为本任务的 readiness 段。除此之外任一 pin 漂移、活跃 change 增删、并发
  overlap、source defect 已被其他提交修复、candidate `lost` 非空、gained 集合
  不等于六个 BRC task，或六项中出现 ready / 可 dispatch，均 fail closed：
  不写实现、不补 evidence、不自行扩 scope，回到新的 readiness 或 proposal
  revision。实现、`ready→done` 与 change verified 继续各自独立 PR。

### Readiness pins(r2,2026-07-28)

- **为何 r1 失效。**PR #707 exact head
  `568bc596b89dc890b6a8c13d4597689fd110c896` 已获维护者 review 并 merge
  为 `c3ad721f1119d7cbf73022a89dd1b502bb92289a`，但 9 秒后 PR #708
  exact head `92d6edc6c20229166e7d3ece2c8d5afdff080d25` merge 为
  `d74c7af7179d89dc29c61e1e7b63d0ca4e7822ea`，修改了活跃 CHG-008 的
  `tasks.md`。这命中 r1“任一 active corpus blob 漂移即停手”的明文条件；
  r1 实现授权未被使用，本轮未写任何 production/test/evidence 文件。r2 只重钉
  readiness 输入，不改 proposal scope、AC、allowed paths 或实现方向。
- **Approval boundary。**Audit base 为 fresh fetch 后 protected `main`
  `c295d4a45a30ea08d7ab66440c5593d1208f222a`
  （2026-07-28T07:52:20Z）；#702 approval、#705 proposal r2、#707
  readiness r1、#708 与 #709 均为其 ancestor。本 r2 仍是独立 D1 readiness：
  只有维护者对本 PR exact head review/merge 后才生效，不宣称 AC passed、
  task done 或 change verified。
- **未漂移的实现面。**Audit base 的实现/测试/只读生产输入与 r1 逐 blob
  相同：`scripts/host_loop/__main__.py` =
  `ac3386457245c20507d6da3a16b63b39423b0387`；
  `worker.py` = `fd7aa86aede863fb5077fb703fab14f1fb17f8b0`；
  `test_navigation_contract.py` =
  `63e2e0f6e3d634b9316f99b0810da9c71e1adb56`；
  `test_token_parity.py` =
  `efb937541d8da2049819267acc45bf94f3f3be64`；
  `scripts/test_check_pr_paths.py` =
  `4490daaf59bee14c4fe1d000606709fa9a355af4`；
  invariant `scripts/check_pr_paths.py` =
  `d3c3fe299487c7c8512569c75ba1827b7f3433b9`；
  invariant `scripts/host_loop/instance.py` =
  `0e7e16451e0e92a13d9cdfbfe18985e335bc8818`。Proposal、verification 与
  acceptance blobs 也仍分别为
  `b1ee27ce0fc0eafdaefe2dff3822d76e28bb75a8`、
  `d641c76cb99d2f85f56c1cd46d2bd53c5257567b`、
  `319b4ae4c9e0102e8c50c1a035d430529a1f3126`。本 `tasks.md` 改前 blob
  为 `4ce0c016d32bee1eccad1c4926788c23aa397b7d`，只作为 r2 载体 pin。
- **现行 active corpus。**活跃 change 集合仍为 r1 的 8 项；audit-base
  `tasks.md` blobs 如下：

  | Active change | r2 audit-base blob |
  | --- | --- |
  | `chg-2026-006-dayu200-m0b-bringup` | `5992c706d24249350bf385b464d58f172a6b7496` |
  | `chg-2026-008-ui-dump-hidumper-wrapper` | `aefe113e3c24188651c062b337e33ddd99290691` |
  | `chg-2026-022-hdc-supervisor-observability` | `3e1022c0df5faa3bb8cb55512676a883a4775c08` |
  | `chg-2026-025-ai-native-unattended-device-ops` | `3ff434156a8105196a156946cd684c81bbc8bb76` |
  | `chg-2026-026-macos-rockchip-flash-ui` | `5f758fe26dac2dd2f62d362345b560fb6a3523e0` |
  | `chg-2026-031-macos-session-settings` | `6b3656c3e637413b9bd9dfb65336ce4250a14d69` |
  | `chg-2026-036-macos-bundled-rockchip-component` | `de23d56688e713d90a2b12706e8d44651cffa164` |
  | `chg-2026-042-tasks-field-colon-parity` | `4ce0c016d32bee1eccad1c4926788c23aa397b7d` |

  #708 只登记 ASCII 冒号的 `TASK-UD-R2-RECAPTURE-001` 与
  `TASK-UD-R2-REDIAG-001`，因此两侧各对称增加 2。真实 discovery before 与仅在
  进程内替换两条目标正则后的 after 为 `30→36`、`lost=[]`、`gained` 仍恰为
  `TASK-BRC-001`…`TASK-BRC-006`。CHG-036 blob 未漂移，故 r1 的六项完整
  status / grade / hardware / dependencies / allowed paths 记录逐字段仍成立：
  BRC-001/002 为 done，BRC-003…006 为 blocked，全部不 ready / 不可 dispatch。
- **#709 已闭合的并发输入。**PR #709 exact head
  `a629432b2f023c87afbdfb7318bc7e95329d621f` 已获维护者 exact-head review
  并 merge 为 audit base
  `c295d4a45a30ea08d7ab66440c5593d1208f222a`；它只改 CHG-022
  `tasks.md`，最终 blob 精确命中事前 prospective pin
  `3e1022c0df5faa3bb8cb55512676a883a4775c08`。合入树的 executable audit 为
  `30→36`、`lost=[]`、gained 恰为六个 BRC，六项字段/verdict 零变化。
  它与 C-M7 implementation/change paths 无直接 overlap。
- **开放并发 PR #710。**第一次提交前 fresh open-PR 清单含
  `readiness(TASK-AIN-BKMK-001)`；exact head
  `22b2d2985fbf19e296c0b6dab3fb5fa809c7297e` 是 audit base 的 descendant，
  只新增 CHG-025 readiness evidence 并把该 active `tasks.md` 从
  `3ff434156a8105196a156946cd684c81bbc8bb76` 改为
  `78c48f9e8ee15bf81db170c3dccbe4883f206d5f`，无 C-M7
  implementation/change-path直接 overlap。Exact-head executable audit 仍为
  `30→36`、`lost=[]`、gained 恰为六个 BRC，六项字段/verdict 零变化。
- **开放并发 PR #711。**#712 初始 head 推送后又出现
  `governance(CHG-2026-008): repin R2 recapture HDC (r13)`；exact head
  `b7d43ac9a46bf6479e7bb92a9dd9bdc2d68b6298` 同为 audit base descendant，
  只改 CHG-008 治理/evidence，并把该 active `tasks.md` 从
  `aefe113e3c24188651c062b337e33ddd99290691` 改为
  `834e0f2d064468bdf841458b466a4816acf06dc4`。它无 C-M7
  implementation/change-path直接 overlap；exact-head audit 以及 #710 + #711
  两 exact heads 的无冲突组合 audit 均为 `30→36`、`lost=[]`、gained 恰为六个
  BRC，六项字段/verdict 零变化。
- **#710 / #711 终态门。**实现开工前两者必须均终止；每项只接受
  closed-unmerged（对应 protected-main blob 保持上段改前值），或维护者对上述
  exact head review/merge（对应 blob 精确为上段改后值）。任一 PR 仍 open、
  head / merge tree 变化，或出现其他改 active corpus / implementation paths 的
  open PR，implementation 为 0 并重新 readiness。
- **新基线与安全门。**macOS 26.5.2 build 25F84、Python 3.14.6、Git
  2.55.0；`scripts/check-sdd.sh` = 0 error / 0 warning / 111 acceptance IDs；
  `scripts/test_check_pr_paths.py` = 49 tests / 0 failures；
  `cd scripts && python3 -m unittest discover -s host_loop -t .` =
  638 tests / 1 expected failure / 0 unexpected failures；独立 PR-guard parity
  fixture 对两种冒号均返回 `('x/**',)`；`git diff --check` = PASS。
  `python -m host_loop --explain` 仍因 `Decision-Grade=unknown` 拒绝本任务，
  `claimable=none`。上述验证命令的 network、GitHub write、device/HDC、
  E1/E2/destructive dispatch 均为 0；本轮外部写入仅限本治理 PR 的 Git push。
- **实现开工复核。**实现必须基于本 r2 merge 后的 protected `main`，先验证
  r2 merge ancestry、#709 exact merge、#710 / #711 限定终态、上列
  implementation/governance blobs 与 8 项 active change。`tasks.md` 因本 r2
  merge 产生的
  预期单任务段变化可接受；除此之外任一漂移、source defect 已消失、candidate
  lost、未登记 gained，或任一 BRC 变为 ready / 可 dispatch，均停止且不写实现。
  r1 的完整变异矩阵继续逐项有效；implementation、`ready→done` 与 verified
  PR 仍严格分离。

### Readiness pins(r3 scope remediation,2026-07-28)

- **触发事实。**r2 readiness PR #712 exact head
  `0352c0fbd2da678c9bec2eb6e0ae9d85f521bb12` 已获维护者 review 并 merge
  为 `0c35f35e1afdb3ffe1e3602d7d1b87b2ed4e37f8`；#710 / #711 也分别按
  r2 钉定 exact heads 合入为
  `70739c4c483232ff6a5d094d753811114e3b9702` /
  `f065ac90e69ff89c9ebb8817bfb4f9ebb1b0ed7d`。在最终 protected-main
  `f065ac90e69ff89c9ebb8817bfb4f9ebb1b0ed7d` 上，全部 implementation、
  governance 与 active-corpus blobs 精确命中 r2，open PR 为空，故实现合法开工。
- **可复现 blocker。**在 r2 已批准的四个文件中完成最小草稿
  （两条 parser regex、never-claim root、navigation / cross-parser tests）后，
  聚焦 colon/never-claim = 12 tests / 0 failures，
  `scripts/test_check_pr_paths.py` = 50 tests / 0 failures，活体语料 =
  `30→36`、`lost=[]`、gained 恰为六个 BRC 且六项均非 ready；但
  `cd scripts && python3 -m unittest discover -s host_loop -t .` 为
  644 tests / 1 expected failure / **1 unexpected failure**：
  `DependenciesAreDeclaredNotAssumed.
  test_the_real_file_declares_dependencies_for_every_task` 报 `7 != 1`。
- **根因与真值方向。**失败断言位于
  `scripts/host_loop/test_discovery_contract.py:461-466`；生产实现改前 blob
  `0d8ad4c98fb302b8fb9bb46cc9eef502553e36ff`。它用
  `.count("\n- Depends on:")` 独立统计活体 change 的依赖声明，仍是
  ASCII-only 文法；修复后 `live_sample_change` 选到 CHG-036，真实 discovery
  正确返回 7 个 candidate，但 counter 只看见其中 1 个 ASCII 字段并错误返回 1。
  让生产 parser 迁就该断言会重新隐藏六个 BRC task，直接违反
  `CM7-PARITY-001` / `CM7-CORPUS-001`，不可采用。
- **唯一 scope 补救。**TASK-CM7-001 Allowed paths 新增且只新增
  `scripts/host_loop/test_discovery_contract.py`。恢复实现时只允许把上述 census
  counter 收敛为独立、行锚定的封闭 `Depends on[:：]` 字段计数；不得导入生产
  `_DEPENDS_RE`、不得改 fixture/task 选择逻辑、不得修改其他 discovery contract
  tests。该断言必须在完整 suite 中从 `7 != 1` 变为通过，并保持“不漏真实
  dependency field”的原验证目的。
- **为何不是 proposal r3。**Proposal r2 已明确要求 ASCII / 全角字段等价、
  全部活跃 corpus executable diff 与相关 contract tests；本次不改行为 scope、
  AC、实现文件、候选集合或总数门，只补登记一个被全量 suite 证明直接消费同一
  文法的既有测试载体。按仓库“scope 变化显式修订 tasks.md”规则，由本独立 D1
  readiness 承载即可；proposal revision 保持 2。
- **隔离与批准边界。**触发 blocker 的实现草稿只保存在本地可恢复 stash
  `6fdae757beba184b86e3153d616ac751f49c4405`，未 commit、未 push、未形成 PR；
  本 r3 PR 只改本 `tasks.md`，不夹带 production/test/evidence。只有维护者对
  本 r3 exact head review/merge 后才允许恢复草稿并修改新增路径；此前
  implementation 为 0。
- **恢复开工门。**恢复时从 r3 merge 后 protected `main` 重建 implementation
  分支并复核：r2/r3 merge ancestry、原实现/测试 pins、新增 census-test blob、
  8 项 active corpus、open PR files。除本 r3 对 `tasks.md` 的预期变化外，任何
  漂移、并发 overlap、candidate-set 变化或新增失败都再次停止。r1/r2 的
  parity、negative、corpus、never-claim 与三项 mutation 门全部继续生效；
  implementation、`ready→done`、verified 仍为三个独立 PR。

### Readiness pins(r4 commit-time corpus refresh,2026-07-28)

- **触发事实。**r3 PR #714 exact head
  `f1b94a0a52204047cfd88132349d1c92e4eb5e86` 已获维护者 review 并 merge
  为 `eaa57f9281c6194e1bada0c740bde1d6e4f48fc6`。恢复后实现、run evidence、
  三项 mutation 与最终全量门均已完成；但提交前 fresh open-PR 检查发现 #715
  修改 active CHG-008 `tasks.md`，命中 r3“active corpus 漂移即停止”条件。
  完成态 implementation 未 commit / push / 开 PR，而是保存在本地可恢复 stash
  `02c82ee5d455054f48cdcf6725f9883d7e412251`；r4 只刷新提交时 corpus，
  不改代码、测试、evidence、AC 或行为 scope。
- **#715 exact merge。**PR #715 exact head
  `5487b9ff7d21c9ac2d71ac78d61e4e12b62b7856` 已获维护者 review 并 merge
  为最新 protected main
  `fe13de4d319bd4fdd07f2439daf9cce8bff34897`。它只改 CHG-008
  governance/evidence；该 active `tasks.md` 从 r3 base 的
  `834e0f2d064468bdf841458b466a4816acf06dc4` 变为
  `90a6e20fb0ebdd488b78289d5a4530e97a7a6036`，与 C-M7 implementation /
  change paths 无直接 overlap。Exact merge tree 的 executable audit 仍为
  `30→36`、`lost=[]`、gained 恰为六个 BRC，六项字段与非-ready verdict
  均不变。
- **唯一开放并发 PR #716。**r4 起草时 fresh open-PR 清单仅含
  `evidence(TASK-OBS-001R)`；exact head
  `d0ae24e98b472898dbef387ce539bc0fe5922826` 修改 Packages、CHG-022 evidence
  及 active `tasks.md`，但不触碰 C-M7 implementation/change paths。把该 exact
  head 与 #715 后 main 无冲突合成，CHG-022 `tasks.md` 为
  `bfe50de28892969ad79a22664a9e71c208a51fb9`；executable audit 仍为
  `30→36`、`lost=[]`、gained 恰为六个 BRC，六项字段/verdict 零变化。
- **#716 终态门。**恢复完成态 implementation 前 #716 必须终止，且只接受：
  closed-unmerged 时 protected-main CHG-022 blob 仍为
  `3e1022c0df5faa3bb8cb55512676a883a4775c08`；或维护者对上述 exact head
  review/merge 后 blob 精确为
  `bfe50de28892969ad79a22664a9e71c208a51fb9`。#716 仍 open、head /
  merge tree 变化，或出现其他改 active corpus / C-M7 paths 的 open PR 时，
  implementation commit/push 为 0 并重新 readiness。
- **未漂移面。**#715 与 #716 均未触碰
  `scripts/host_loop/__main__.py`、`worker.py`、
  `test_discovery_contract.py`、`test_navigation_contract.py`、
  `scripts/test_check_pr_paths.py`、C-M7 proposal/verification/acceptance 或
  evidence path。r3 所有 source/test pins、唯一新增 census-test scope、变异矩阵
  与 forbidden paths 逐字继续有效；本 r4 不新增 allowed path。
- **恢复/提交门。**本 r4 exact head 由维护者 review/merge 且 #716 达到上述
  终态后，从届时 protected main 重建 implementation 分支，恢复 stash
  `02c82ee5d455054f48cdcf6725f9883d7e412251`，确认 changed paths 只落本任务
  Allowed paths；重新执行 live corpus、13 项聚焦、50 项 PR guard、644 项
  host-loop、SDD `0/0/111` 与 `git diff --check`。任何集合、blob、并发或测试
  漂移再次停止；通过后才允许创建原定的一个 implementation PR。`ready→done`
  与 verified 继续分离。

### Readiness pins(r5 final #716 merge refresh,2026-07-28)

- **为何 r4 未生效。**r4 PR #718 exact head
  `2dcf669bf897b77edde1fe793ef305a94baf55b3` 已获维护者 `lvye` exact-head
  review，SDD Guard、allowed-paths 与 Swift CI 全绿，但未 merge。r4 钉定的
  #716 head 为 `d0ae24e98b472898dbef387ce539bc0fe5922826`；其后 #716 追加
  evidence/tasks 提交并以不同 head 合入，命中 r4 明文
  “head / merge tree 变化即重新 readiness”条件。因此 r4 review 未被当作
  implementation 授权；完成态 stash 未恢复、implementation 仍为零 commit /
  零 push / 零 PR。
- **最终 #716 exact merge。**PR #716 最终 exact head
  `6a98aa7315b09b556eb512651eca038704b8adf6` 已获维护者 exact-head review，
  merge 为最新 protected main
  `67978722a063f07adfee6c8b3fd8235076ea60c2`。相对 #715 后 main，它只改三个
  `Packages/ArkDeckKit/Sources/**`、新增一个 contract test，并更新 CHG-022
  tasks/evidence；未触碰 C-M7 implementation/change paths。最终 CHG-022
  `tasks.md` blob 为 `da3d5ecf3bed9992effeaa14b5911227b193f46b`，取代
  r4 对旧 head 的 prospective blob。
- **最终 active corpus。**在 protected main `67978722a063f07adfee6c8b3fd8235076ea60c2`
  上，`active_change_ids` 仍返回同一 8 项；对应 `tasks.md` blobs 为：

  | Active change | r5 audit-base blob |
  | --- | --- |
  | `chg-2026-006-dayu200-m0b-bringup` | `5992c706d24249350bf385b464d58f172a6b7496` |
  | `chg-2026-008-ui-dump-hidumper-wrapper` | `90a6e20fb0ebdd488b78289d5a4530e97a7a6036` |
  | `chg-2026-022-hdc-supervisor-observability` | `da3d5ecf3bed9992effeaa14b5911227b193f46b` |
  | `chg-2026-025-ai-native-unattended-device-ops` | `78c48f9e8ee15bf81db170c3dccbe4883f206d5f` |
  | `chg-2026-026-macos-rockchip-flash-ui` | `5f758fe26dac2dd2f62d362345b560fb6a3523e0` |
  | `chg-2026-031-macos-session-settings` | `6b3656c3e637413b9bd9dfb65336ce4250a14d69` |
  | `chg-2026-036-macos-bundled-rockchip-component` | `de23d56688e713d90a2b12706e8d44651cffa164` |
  | `chg-2026-042-tasks-field-colon-parity` | `ff83a4db13355e9a26427415ab0bfa04c0db9c95` |

  用未改 production parser 生成 before，再仅在进程内把两条目标正则替换为
  `[:：]` 后生成 after，结果仍为 `30→36`、`lost=[]`、gained 恰为
  `TASK-BRC-001`…`TASK-BRC-006`。六项完整字段与 r1/r4 记录相同：
  BRC-001/002 为 done + unknown grade，BRC-003…006 为 blocked + D1/D2，
  BRC-005 仍需 hardware；逐项真实 gate verdict 均非 dispatchable。
- **并发与实现面。**fresh fetch 后开放 PR 仅有本 #718 自身，且只改本
  `tasks.md`；没有其他 active-corpus 或 C-M7 implementation-path 占用。
  #715 / #716 merge 均未改
  `scripts/host_loop/__main__.py`、`worker.py`、
  `test_discovery_contract.py`、`test_navigation_contract.py`、
  `scripts/test_check_pr_paths.py`、C-M7 proposal/verification/acceptance 或
  evidence path。r3 scope、source/test pins、变异矩阵、allowed/forbidden
  paths 全部继续有效。
- **r5 批准与恢复门。**只有维护者对包含本节、基于
  `67978722a063f07adfee6c8b3fd8235076ea60c2` 的 r5 exact head 重新
  review/merge 后，才允许从届时 protected main 重建 implementation 分支并恢复
  stash `02c82ee5d455054f48cdcf6725f9883d7e412251`。恢复后必须确认 changed
  paths 只落本任务 Allowed paths，并重新执行 live corpus、13 项聚焦、50 项
  PR guard、644 项 host-loop、SDD `0/0/111` 与 `git diff --check`。恢复前或
  提交前若 main、active corpus、C-M7 路径、开放 PR 集合或测试结果再次漂移，
  implementation commit/push 为零并重新 readiness；`ready→done` 与 verified
  继续分离。

### Readiness pins(r6 post-#719 corpus refresh,2026-07-28)

- **为何 r5 未被使用。**r5 PR #718 final head
  `85d1cb7f71250d4490cec1de8b3bcf26fb809123` 已经 protected-main squash
  merge 为 `0185bf52b8e908560867bccaeb5f6a96d2cedf02`，其 fileset 仅为本
  `tasks.md`；按 V2 governance，合入 protected main 即构成人类批准。但
  19 秒后 PR #719 又合入 active CHG-022 `tasks.md`，发生在本会话恢复 stash
  之前，命中 r5 的 active-corpus 漂移停止条件。r5 一次性实现授权未被使用；
  stash `02c82ee5d455054f48cdcf6725f9883d7e412251` 仍未恢复，implementation
  仍为零 commit / 零 push / 零 PR。
- **#719 exact merge。**PR #719 exact head
  `7a3aed409a1d6471276c4aa8fe39e35d592d36f5` 已获维护者 `lvye`
  exact-head review，并 merge 为最新 protected main
  `570fe28c2d6edbad18050cfe873246fd45f0bc40`。它只把
  `TASK-OBS-001R` 从 ready 翻为 done 并追加同任务 completion 记录，fileset
  仅为 CHG-022 `tasks.md`；该 blob 从
  `da3d5ecf3bed9992effeaa14b5911227b193f46b` 变为
  `b2688926e2d691ae141e5b735f4b2066e33bc331`。它未触碰 C-M7
  implementation/change paths。
- **r6 corpus 与 pins。**protected main
  `570fe28c2d6edbad18050cfe873246fd45f0bc40` 的 active change 集合仍为
  r5 的 8 项。除两个预期变化外，r5 表内 blobs 均逐字不变：C-M7
  `tasks.md` 因 #718 从 `ff83a4db13355e9a26427415ab0bfa04c0db9c95`
  变为 `776140894aa258b95178f581180eaba6b55acdf9`；CHG-022 因 #719
  变为上述 `b2688926e2d691ae141e5b735f4b2066e33bc331`。在该 exact tree 上，
  未改 parser 的 before 与仅在进程内把 `_DEPENDS_RE` / `_ALLOWED_RE`
  分隔符替换为 `[:：]` 的 after 仍为 `30→36`、`lost=[]`、gained 恰为
  `TASK-BRC-001`…`TASK-BRC-006`。六项完整字段/verdict 逐字不变：
  BRC-001/002 done，BRC-003…006 blocked，全部非 ready / 不可 dispatch。
- **并发与未漂移面。**fresh fetch 后开放 PR 为空；#718 / #719 均未改
  `scripts/host_loop/__main__.py`、`worker.py`、
  `test_discovery_contract.py`、`test_navigation_contract.py`、
  `scripts/test_check_pr_paths.py`、C-M7 proposal/verification/acceptance 或
  evidence path。r3 唯一新增 census-test scope、source/test pins、变异矩阵、
  allowed/forbidden paths 全部继续有效。
- **r6 批准与恢复门。**只有维护者对基于
  `570fe28c2d6edbad18050cfe873246fd45f0bc40`、包含本节的 r6 exact head
  review/merge 后，才允许从届时 protected main 重建 implementation 分支并恢复
  stash `02c82ee5d455054f48cdcf6725f9883d7e412251`。恢复后须确认 changed
  paths 只落本任务 Allowed paths，并重跑 live corpus、13 项聚焦、50 项
  PR guard、644 项 host-loop、SDD `0/0/111` 与 `git diff --check`。恢复前或
  提交前若 main、active corpus、C-M7 路径、开放 PR 集合或测试结果再次漂移，
  implementation commit/push 为零并重新 readiness；`ready→done` 与 verified
  继续分离。
