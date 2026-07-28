# TASK-CM7-001 implementation run

- Executed at:2026-07-28T08:17:20Z
- Executor:agent
- Classification:host-only contract / repository corpus
- Implementation base:`eaa57f9281c6194e1bada0c740bde1d6e4f48fc6`
- Readiness ancestry:
  - r2 PR #712 merge `0c35f35e1afdb3ffe1e3602d7d1b87b2ed4e37f8`
  - scope remediation r3 PR #714 merge
    `eaa57f9281c6194e1bada0c740bde1d6e4f48fc6`
- Environment:macOS 26.5.2 build 25F84; Python 3.14.6; Git 2.55.0
- Device/HDC/E1/E2/destructive dispatch:0
- Network/credential/system mutation by verification commands:0

## Implemented

- `scripts/host_loop/__main__.py`
  - `_DEPENDS_RE` 与 `_ALLOWED_RE` 的字段分隔符由 ASCII-only `:` 收敛为
    封闭 `[:：]`；
  - 删除 C-M7 “已知但不在当前 scope”残留说明；
  - 其余 field/value/list/prose 读取逻辑未改。
- `scripts/host_loop/worker.py`
  - 将 `TASK-CM7-001` 加入 `NEVER_CLAIM_ROOTS`。
- Contract tests
  - Depends / Allowed 两条独立全角冒号 parity 哨兵；
  - inline / 合法缩进列表续行等价；
  - 空值、散文、`;` / `；` 非法分隔符继续 fail closed；
  - 同一个 `tasks.md` fixture 同时经过 host-loop discovery 与
    `check_pr_paths.extract_allowed_patterns`；
  - CM7 exact root、合法 suffix 与相邻 token；
  - r3 允许的 discovery live-census counter 使用独立、行锚定
    `Depends on[:：]`，不导入生产 `_DEPENDS_RE`。

未修改 invariant `scripts/check_pr_paths.py`、
`scripts/host_loop/instance.py`，未修改其他 change、workflow、spec、contract、
Packages 或 App 文件。

## Live corpus executable diff

命令读取 `host_loop.active_change_ids` 返回的全部 8 个 active change；after 使用
工作树真实实现，before 只在进程内把两条目标 regex 还原为 ASCII-only，未改仓库
文件：

```text
implementation_base=eaa57f9281c6194e1bada0c740bde1d6e4f48fc6
before_ascii_only=30
after_implementation=36
lost=[]
gained=[
  TASK-BRC-001,
  TASK-BRC-002,
  TASK-BRC-003,
  TASK-BRC-004,
  TASK-BRC-005,
  TASK-BRC-006
]
```

Gained candidates（六项 `base_pin=null`、`ready=false`）：

- `TASK-BRC-001`
  - status=`done`; grade=`unknown`; hardware=`false`; dependencies=`[]`
  - allowed paths:
    `docs/release/rockchip-component-distribution.md`,
    `openspec/changes/chg-2026-036-macos-bundled-rockchip-component/design.md`,
    `openspec/changes/chg-2026-036-macos-bundled-rockchip-component/tasks.md`,
    `openspec/changes/chg-2026-036-macos-bundled-rockchip-component/verification.md`,
    `openspec/changes/chg-2026-036-macos-bundled-rockchip-component/evidence/**`
- `TASK-BRC-002`
  - status=`done`; grade=`unknown`; hardware=`false`;
    dependencies=`[TASK-BRC-001]`
  - allowed paths:
    `vendor/rockchip/**`, `scripts/rockchip_component/**`,
    `.github/workflows/rockchip-component.yml`,
    `openspec/integrations/rockchip/bundled-component/**`,
    `docs/release/rockchip-component-distribution.md`,
    `openspec/changes/chg-2026-036-macos-bundled-rockchip-component/design.md`,
    `openspec/changes/chg-2026-036-macos-bundled-rockchip-component/tasks.md`,
    `openspec/changes/chg-2026-036-macos-bundled-rockchip-component/verification.md`,
    `openspec/changes/chg-2026-036-macos-bundled-rockchip-component/evidence/**`
- `TASK-BRC-003`
  - status=`blocked`; grade=`D2`; hardware=`false`;
    dependencies=`[TASK-BRC-002]`
  - allowed paths:
    `ArkDeck.xcodeproj/**`, `ArkDeckApp/**`, `scripts/release/**`,
    `scripts/rockchip_component/**`,
    `openspec/integrations/rockchip/bundled-component/**`, `docs/release/**`,
    `openspec/changes/chg-2026-036-macos-bundled-rockchip-component/design.md`,
    `openspec/changes/chg-2026-036-macos-bundled-rockchip-component/tasks.md`,
    `openspec/changes/chg-2026-036-macos-bundled-rockchip-component/verification.md`,
    `openspec/changes/chg-2026-036-macos-bundled-rockchip-component/evidence/**`
- `TASK-BRC-004`
  - status=`blocked`; grade=`D1`; hardware=`false`;
    dependencies=`[TASK-BRC-003]`
  - allowed paths:
    `Packages/ArkDeckKit/Package.swift`,
    `Packages/ArkDeckKit/Sources/ArkDeckWorkflows/**`,
    `Packages/ArkDeckKit/Sources/ArkDeckStorage/**`,
    `Packages/ArkDeckKit/Tests/ArkDeckContractTests/**`, `ArkDeckApp/**`,
    `ArkDeck.xcodeproj/**`,
    `openspec/integrations/rockchip/bundled-component/**`,
    `openspec/changes/chg-2026-036-macos-bundled-rockchip-component/design.md`,
    `openspec/changes/chg-2026-036-macos-bundled-rockchip-component/tasks.md`,
    `openspec/changes/chg-2026-036-macos-bundled-rockchip-component/verification.md`,
    `openspec/changes/chg-2026-036-macos-bundled-rockchip-component/evidence/**`
- `TASK-BRC-005`
  - status=`blocked`; grade=`D2`; hardware=`true`;
    dependencies=`[TASK-BRC-004]`
  - allowed paths:
    `ArkDeckApp/**`, `ArkDeckAppUITests/**`, `ArkDeck.xcodeproj/**`,
    `Packages/ArkDeckKit/**`, `scripts/rockchip_component/**`,
    `scripts/e0_readback/**`,
    `openspec/integrations/rockchip/bundled-component/**`,
    `openspec/changes/chg-2026-036-macos-bundled-rockchip-component/design.md`,
    `openspec/changes/chg-2026-036-macos-bundled-rockchip-component/tasks.md`,
    `openspec/changes/chg-2026-036-macos-bundled-rockchip-component/verification.md`,
    `openspec/changes/chg-2026-036-macos-bundled-rockchip-component/evidence/**`
- `TASK-BRC-006`
  - status=`blocked`; grade=`D2`; hardware=`false`;
    dependencies=`[TASK-BRC-005]`
  - allowed paths:
    `.github/workflows/**`, `ArkDeck.xcodeproj/**`, `ArkDeckApp/**`,
    `docs/release/**`, `scripts/release/**`,
    `scripts/rockchip_component/**`,
    `openspec/integrations/rockchip/bundled-component/**`,
    `openspec/changes/chg-2026-036-macos-bundled-rockchip-component/design.md`,
    `openspec/changes/chg-2026-036-macos-bundled-rockchip-component/tasks.md`,
    `openspec/changes/chg-2026-036-macos-bundled-rockchip-component/verification.md`,
    `openspec/changes/chg-2026-036-macos-bundled-rockchip-component/evidence/**`

`python3 -m host_loop --explain --repo-dir .. --change
chg-2026-042-tasks-field-colon-parity` 返回：

```text
TASK-CM7-001: rejected
  - never-claim: the readiness forbids claiming this task
  - decision grade 'unknown' is not dispatchable
claimable=none
```

直接 root 检查：exact=`true`、suffix `TASK-CM7-001R`=`true`、neighbour
`TASK-CM7-002`=`false`。

## Contract and suite results

| Command | Result |
| --- | --- |
| `python3 -m unittest host_loop.test_discovery_contract.DependenciesAreDeclaredNotAssumed.test_the_real_file_declares_dependencies_for_every_task host_loop.test_navigation_contract.TaskFieldColonParityTests host_loop.test_navigation_contract.NeverClaimRootsArePinnedByContent` | PASS, 13 tests |
| `python3 scripts/test_check_pr_paths.py` | PASS, 50 tests |
| `cd scripts && python3 -m unittest discover -s host_loop -t .` | PASS, 644 tests, 1 expected failure, 0 unexpected failures |
| `scripts/check-sdd.sh` | PASS, 0 errors / 0 warnings / 111 acceptance IDs |
| `git diff --check` | PASS |

全量 suite 仍输出既有 `ResourceWarning` 与
`test_discovery_contract.py:369` 的既有 `SyntaxWarning`；均未变成 test failure，
且不在本任务 scope。

## Mutation evidence

每项 mutation 均通过 `apply_patch` 单点引入，运行专属测试后再通过
`apply_patch` 原样恢复；没有 mutation 残留。

| Mutation | Command / observation | Verdict |
| --- | --- | --- |
| A：把 `_DEPENDS_RE` 从 `[:：]` 还原为 `:` | `TaskFieldColonParityTests.test_full_width_depends_colon_matches_ascii` 红，full-width fixture `0 != 1` | killed |
| B：把 `_ALLOWED_RE` 从 `[:：]` 还原为 `:` | `TaskFieldColonParityTests.test_full_width_allowed_paths_colon_matches_ascii` 红，full-width fixture `0 != 1` | killed |
| C：移除 `TASK-CM7-001` never-claim root | `NeverClaimRootsArePinnedByContent.test_cm7_root_and_suffix_are_excluded` 对 exact / `A` / `R` 三项全红 | killed |
| 负对照：只改 `_DEPENDS_RE` 上方注释 | 上述 13 项聚焦 contract 全绿 | survived |

## AC conclusions

- `CM7-PARITY-001`:PASS。两个 discovery 字段的 ASCII / 全角、inline / list
  输出相同；同 fixture 的 PR guard 路径相同；非法/空值/散文仍拒绝；A/B mutation
  各由独立测试击杀。
- `CM7-CORPUS-001`:PASS。`lost=[]`，gained 精确为六个 BRC task；全字段已记录，
  六项均非 ready / 不可 dispatch。
- `CM7-SELF-001`:PASS。exact 与合法 suffix 永不 claim，相邻 token 不受影响；
  C mutation 被专属测试击杀。

Residual risk：未来 active `tasks.md` 变化会改变诊断总数，仍须按语义集合而非固定
计数复验；本 run 只支持 implementation PR，不自行把 task 标为 done，也不把
change 标为 verified。

## r6 commit-time revalidation

- Revalidated at:`2026-07-28T08:50:53Z`
- Final submission base:
  `cd3f3e0a7b4c2055746a617110e94b2e1dc791c7`
- Additional readiness/corpus ancestry:
  - r5 PR #718 final head
    `85d1cb7f71250d4490cec1de8b3bcf26fb809123` merge
    `0185bf52b8e908560867bccaeb5f6a96d2cedf02`
  - OBS completion PR #719 exact head
    `7a3aed409a1d6471276c4aa8fe39e35d592d36f5` merge
    `570fe28c2d6edbad18050cfe873246fd45f0bc40`
  - r6 PR #720 exact head
    `645c138d34be5d88d692cd3bfdde9a50c43b330b` merge
    `cd3f3e0a7b4c2055746a617110e94b2e1dc791c7`
- r6 merge-tree corpus blobs:
  - CHG-022 `tasks.md` =
    `b2688926e2d691ae141e5b735f4b2066e33bc331`
  - C-M7 `tasks.md` =
    `481b3e8cf48472294242e44201d2b3c04f1ff38d`
- Restore receipt:completed implementation stash
  `02c82ee5d455054f48cdcf6725f9883d7e412251` restored without conflict after
  implementation branch fast-forwarded to the final submission base. Changed
  paths remained exactly within TASK-CM7-001 Allowed paths; invariant
  `scripts/check_pr_paths.py` and `scripts/host_loop/instance.py` remained
  byte-identical to the base.
- Concurrency receipt:fresh fetch before restore found no open PR.
- Live corpus rerun on the restored working tree:
  `before_ascii_only=30`、`after_implementation=36`、`lost=[]`、gained exactly
  `TASK-BRC-001`…`TASK-BRC-006`; all six candidate fields and rejection
  verdicts matched the original run, and none was ready or dispatchable.
- Claim rerun:`TASK-CM7-001` was rejected by exact never-claim and unknown-grade
  gates; `claimable=none`.
- Contract rerun:

  | Command | r6 result |
  | --- | --- |
  | 13 focused colon/census/never-claim tests | PASS, 13/13 |
  | `python3 scripts/test_check_pr_paths.py` | PASS, 50/50 |
  | `cd scripts && python3 -m unittest discover -s host_loop -t .` | PASS, 644 tests, 1 expected failure, 0 unexpected failures |
  | `scripts/check-sdd.sh` | PASS, 0 errors / 0 warnings / 111 acceptance IDs |
  | `git diff --check` | PASS |

  The first full-suite attempt inside the filesystem/network sandbox produced
  two `PermissionError` results only where redirect tests bind ephemeral
  localhost sockets. The required sandbox-exempt rerun passed all 644 tests;
  no source change was made between the two executions. Existing
  `ResourceWarning` / line-369 `SyntaxWarning` output remained non-failing and
  unchanged.

The r6 rerun preserves every original mutation result and AC conclusion. It
adds no device/HDC work, external network call, credential mutation, E1/E2
dispatch, task-status flip, or change-level verification claim.
