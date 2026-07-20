# CHG-2026-017 Verification Plan

> Status:planned
> Change:CHG-2026-017-guard-scope-coverage@r1
> Core baseline:CORE-2.0.0

本 change 是 guard 工具增强(class `implementation-only`):零 spec/contract/baseline/
product/设备变更。唯一交付=`scripts/check_sdd.py` 的 scope 覆盖校验 + `test_check_sdd.py`。
实现须证明现状 guard 不回归(四 scope.yaml change 全过、`0/0/111` 不变)。

## Acceptance matrix

| Evidence ID | Method | Expected result | Status |
| --- | --- | --- | --- |
| GUARD-SCOPE-COVERAGE-001 | 合成 fixture + 真实基线 offline 测试 | 对含 scope.yaml 的 change 校验 acceptance ⊆ 各任务 Requirements/AC 认领并集,未认领即具名 err;单向(任务可引 scope 外只读 AC);无 scope.yaml 跳过;正例(全覆盖零 err,反引号/分隔/续行变体)+反例(漏认领 1 个即恰一具名 err)+解析边界+跳过+真实基线(四 change 零 scope-coverage err,check-sdd 0/0/111)全 PASS;仅改 guard+测试,零 spec/contract/product/设备变更 | pending |

## Gate

- guard 增强不引入 false positive:实现前后 `scripts/check-sdd.sh` 均
  `0 errors / 0 warnings / 111 acceptance IDs`;current-main 四个 scope.yaml change
  的 scope 覆盖现状成立(AC-JOB-003/004 已由 #138 补认领)。
- 单向校验:只 `scope acceptance ⊆ claimed`,不反向;任务引用 scope 外 canonical
  Safety input 不报错。
- class `implementation-only`:归档/verify 无 ratification 成分;不改变任何既有
  change 状态或 AC。
