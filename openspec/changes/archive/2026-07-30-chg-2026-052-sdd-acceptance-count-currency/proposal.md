---
id: CHG-2026-052-sdd-acceptance-count-currency
revision: 2
status: archived # 2026-07-30 archive PR；verification #820 merge cef348ceab6e82d817ece34d53cdcf03af8b94bf；Core/spec/contract/canonical Acceptance delta 均为空；目录外活路径引用 0；仅在维护者 review/merge 本 PR 后生效
class: implementation-only
core_change_level: none
owner: lvye
core_baseline: CORE-2.1.0
platforms: [macos, windows, linux]
---

# Keep the SDD real-baseline assertion current across Core AC-count changes

## r2 mechanical correction

PR #818 首个 implementation head 的 SDD Guard 已通过，但 Agent PR allowed-paths
正确拒绝 `tasks.md`：r1 写成“本 `tasks.md`”，而已批准的机械 grammar 只把
“本 change `tasks.md`”解析为 change-relative path。r2 仅修正这个载体语法，
并把 readiness audit base 前移到 #817 merge；实现文件、evidence path、Forbidden
paths、reader 行为、Acceptance 与风险边界全部不变。#818 必须在本 r2 由维护者
review/merge 后 rebase，不能从 head 自行扩权。

## Why

CHG-2026-051 的 archive candidate 将 canonical Core Acceptance 数从 111 增至
114。本地 `scripts/check-sdd.sh` 已对 current specs/index/cases 精确校验并报告
`114 acceptance IDs`，但 PR #816 的 SDD Guard 在
`ScopeCoverageTests.test_real_baseline_has_active_covered_scope_and_main_passes`
失败：`scripts/test_check_sdd.py` 把成功摘要的数量字面量写死为 111。

直接在 CHG-2026-051 archive PR 中把该字面量改成 114 不合法：
`scripts/test_check_sdd.py` 不在 `TASK-AHE-001` 已批准 Allowed paths 内，PR #816
exact head `ee33d996fd9adce4ef32d8527e49ae87da100143` 的 Agent PR
allowed-paths job 已按预期 fail closed。修改 archived task 追认扩权同样被
atomic-archive guard 禁止。

根因不是 CHG-2026-051 的 delta，而是 real-baseline contract test 把一个会随
批准后的 Core archive 正常变化的声明复制进 Python 字面量，制造了一个无法在
原 archive scope 内闭合的双写点。

## What changes

In scope:

- 仅修改 `scripts/test_check_sdd.py`：从 accepted
  `openspec/verification/core-conformance.yaml` 的
  `acceptance_index.count` 读取 real-baseline 期望数量，再断言
  `check_sdd.py` 的成功摘要精确匹配。
- reader 对缺失、布尔、字符串、零或负数 fail closed；合成 contract test 固定
  valid/invalid 矩阵。
- 保留真实仓库测试的全部既有门：subprocess exit 必须为 0，errors/warnings 必须
  精确为 0，reported count 必须与 accepted conformance manifest 一致。
- implementation/evidence PR 只交付上述 reader/test、同车 run evidence 和
  `TASK-GCC-001 ready → done`。

Out of scope:

- 不修改 `scripts/check_sdd.py`、SDD Guard workflow、allowed-path guard 或
  automation config；
- 不修改 current spec、canonical Acceptance index/cases、Core conformance
  manifest、baseline、CHG-2026-051 或 PR #816 内容；
- 不允许通过接受任意数量、正则忽略 count、删除真实仓库 subprocess 断言、
  `skip`、`xfail` 或 `|| true` 使 CI 变绿；
- 零 product/runtime/device/HDC/network 行为。

Observable behavior:

- Before：每次批准的 canonical AC-count 变化都要求额外修改一个未必属于该
  archive Allowed paths 的 Python 字面量。
- After：真实仓库 contract test 仍精确校验 count，但期望值来自 accepted
  conformance manifest；合法 baseline archive 不再需要越界修改测试源码。

## Scope（Requirement/AC）

- Change-local Acceptance:`GUARD-COUNT-CURRENCY-001`
- Core Requirement/AC/schema/index/cases:零修改
- Core baseline bump:不需要；保持 `CORE-2.1.0`

## Safety, privacy, and compatibility

- 这是 host-only/offline test-infrastructure change；零 device dispatch、零 authority
  或 evidence schema 影响。
- `core-conformance.yaml` 已由 `check_sdd.py` 校验 shape、三方集合与 declared
  count；本 change 只移除测试代码中的冗余副本，不改变 canonical source。
- 回退为 revert 单个 implementation PR；回退后下一次 AC-count 变化会重新命中同一
  CI blocker，但不影响产品运行时。
- macOS/Windows/Linux 产品 conformance 状态均不改变；GitHub CI runner 上的 host
  contract test 是唯一受影响执行面。

## Verification closure（2026-07-30）

`TASK-GCC-001` 的 implementation、tests、same-revision evidence 与 `done` 状态已由
PR #818 合入 protected main。本 verification PR 只翻转 change/verification 状态并
新增 latest-main 复验记录，零产品实现、零 scope、零 Acceptance、Core、authority
或 platform 状态变化。

### Protected-main delivery chain

| Stage | Exact reviewed head | Protected-main merge |
| --- | --- | --- |
| r1 proposal #817 | `237fb1e5b694606ee0ce161c724b0cecf54f8354` | `8a9bfef4d4794ff4289cc1e35d1b50e4c1d816b6` |
| r2 path correction #819 | `e70316b2f07deeb7760ca27405333c972734b7fe` | `04190f73f69d06ad2046997a7532b48eb3afb966` |
| implementation/evidence #818 | `a7bb8963c58970e89c440f224c38caef332cf253` | `55110476658df9b7955f4bd807f56b3071660c17` |

三个 exact heads 均由维护者 `lvye` review/approve；各 PR 的 Agent PR、SDD Guard、
allowed-path 与 Swift CI 所需 checks 均为 `SUCCESS`。批准/合入事实建立 authority；
`GUARD-COUNT-CURRENCY-001` 的真值源仍是
`evidence/runs/TASK-GCC-001/run.md` 与
`evidence/runs/TASK-GCC-001/verification-r1.md`，不是实现 PR 被 review 本身。

### Binary AC conclusion

- `GUARD-COUNT-CURRENCY-001` = PASS（contract）：strict reader 的 `114` 正例与
  11 个 malformed/type/range 反例通过；current main 的 111 manifest 通过完整
  SDD suite；从 #818 merge OID 叠加 #816 archive candidate 后，同一
  `scripts/test_check_sdd.py` blob 在 114 manifest 下仍通过完整 suite，未发生测试
  源码编辑。subprocess 非零、actual/declared count mismatch、errors 或 warnings
  非零继续 fail closed。

复验环境、输入 blob、命令与结果见
`evidence/runs/TASK-GCC-001/verification-r1.md`。复验只使用 host-only/offline
contract 路径，未运行 product Runtime、HDC、设备、capability 或网络操作，不产生
hardware/platform support 主张。

只有维护者 review/merge 本 PR 后，proposal `verified` 与 verification `passed`
才生效；archive 仍是后续独立 PR。若合并前 protected main 改变本 change 的 test、
guard、manifest、workflow 或对应 contract 输入，必须先重放受影响验证，不能从本
记录推断通过。
