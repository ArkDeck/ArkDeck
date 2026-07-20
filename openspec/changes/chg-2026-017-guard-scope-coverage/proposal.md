---
id: CHG-2026-017-guard-scope-coverage
revision: 1
status: approved # r1 proposal 经 PR #180 合入;批准由本 approval-only PR 的维护者 review/merge 构成(先例 #55/#89)
class: implementation-only
core_change_level: none
owner: lvye
core_baseline: CORE-2.0.0
platforms: [macos]
---

# check_sdd guard:per-change scope 覆盖校验

## Why

2026-07-20 全任务面深度 review 的 CHG-2026-002 pre-verify 台账发现 **AC-JOB-003/004
归属断链**:两个 AC 在 `scope.yaml` 的 `acceptance:` 列表内,但**没有任何任务的
`Requirements/AC:` 行认领它们**,导致 `verification.md` 的"任务分配并集 == scope"
不变式为假。该缺口**静默存在**,只在人工 pre-verify 审计时才被发现(已由追溯修复
PR #138 补认领)。

根因是 guard 能力缺口:当前 `scripts/check_sdd.py` 只校验 change artifact 结构、
三方 AC 集合(specs/index/cases)一致与 capability registry 1:1,**不校验各 change
内部"scope.yaml acceptance 列表 ⊆ 各任务 Requirements/AC 认领并集"**。本 change 增强
guard 以自动拦截该类断链,把"人肉双开发现"变为机器侧 fail-closed——这是 backlog 已
登记的 guard 增强项(`openspec/planning/backlog.md`)。

## What changes

### In scope

- `TASK-GUARD-001`:在 `scripts/check_sdd.py` 增加 per-change scope 覆盖校验——对
  **含 `scope.yaml` 的 change**(当前 M0A/M1/CHG-005/M0B 四个),校验 `scope.yaml` 的
  `acceptance:` 列表中每个 AC 都被该 change 至少一个任务的 `Requirements/AC:` 行(含
  其缩进续行)认领;未认领即 `err`(fail-closed)。不含 `scope.yaml` 的 change 跳过
  (与现状一致,guard 不强制 scope.yaml)。
- 新增 `scripts/test_check_sdd.py`:合成 fixture 证明——完整覆盖通过、故意漏认领一个
  scope AC 即被具名 err;token 解析(反引号/`、`/`；`分隔、缩进续行)正反用例。
- 实现须先在当前 `main` 复跑证明**四个 scope.yaml change 现状全部通过**(AC-JOB-003/004
  已由 #138 补认领),即增强不引入 false positive。

### Out of scope

- 反向校验(任务认领 ⊆ scope):任务可引用 canonical Safety input 等 scope 外 AC
  (read-only,不认领 completion),故只做单向 `scope acceptance ⊆ claimed`;
- 为无 scope.yaml 的 change 补建 scope.yaml(属各 change 自身治理,不在本 change);
- `requirements:` 覆盖校验(本 change 只做 acceptance 覆盖,requirements 覆盖可后续
  revision 追加);
- 任何 spec/contract/baseline/product/设备变更。

## Approval

- r1 proposal 经 PR #180 合入 main(`status: proposed`)。
- 正式批准:2026-07-20 由本 approval-only PR(先例 #55/#89)将本 change 置为
  `approved`;批准由维护者 review/merge 本 PR 构成。本批准不产生任务执行:
  `TASK-GUARD-001` 保持 `blocked`,须再经独立 readiness PR 转 `ready`。

## Risk and boundary

- 风险=false positive(把合法未认领误报)或 false negative(漏报真断链):由实现前
  "current main 四 change 全过"基线 + 合成 fixture 正反用例覆盖;token 解析对
  反引号/分隔符/续行的边界由测试钉死。
- class `implementation-only`、`core_change_level: none`:仅改 guard 工具与新增测试,
  零 spec/contract/baseline/conformance/product 变更,无 ratification 成分。
- 不改变任何既有 change 的状态或 AC;增强生效后现状 guard 仍 `0/0/111`。
