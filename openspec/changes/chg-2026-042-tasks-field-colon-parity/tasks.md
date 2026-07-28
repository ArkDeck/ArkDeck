# CHG-2026-042 Tasks

本 change 只含一个实现任务。它修改 host-loop discovery 自身，按既有
HLR/NAV/DEC 先例由会话实现：`Decision-Grade` 在实现前保持缺失；实现须把
`TASK-CM7-001` 纳入 `NEVER_CLAIM_ROOTS`，不得让循环认领改写自身读取门的工作。

## TASK-CM7-001 — 对齐 `tasks.md` 字段冒号文法并锁定跨解析器契约

- Status:ready（仅在维护者对本独立 readiness PR exact head review/merge 后生效；
  一次性授权严格受下方 `Readiness pins(r1,2026-07-28)` 约束的实现 PR，不授权
  `done` / `verified` 翻转）
- Platform:macos（host-only）
- Requirements/AC:change-local `CM7-PARITY-001`、`CM7-CORPUS-001`、
  `CM7-SELF-001`
- Depends on:none（change approval 与 readiness 由状态/PR 门承载，不伪装为
  TASK 依赖）
- Readiness input pins:见下方 `Readiness pins(r1,2026-07-28)`；实现开工必须逐项
  复核 exact base ancestry、实现/测试 blob、活跃 `tasks.md` 语料与并发 PR
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

- 本 readiness 只授权一个实现 PR；任一 input pin、活跃语料、并发路径或候选集合
  漂移均须停止并重新 fresh readiness；出现 lost、未登记 gained，或六个 BRC
  candidate 中任何一项变为 ready / 可 dispatch 时必须修订 proposal。
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
