# CHG-2026-017 Verification Plan

> Status:planned
> Change:CHG-2026-017-guard-scope-coverage@r2
> Core baseline:CORE-2.0.0

本 change 是 guard 工具增强(class `implementation-only`):零 spec/contract/baseline/
product/设备变更。唯一交付=`scripts/check_sdd.py` 的 scope 覆盖校验 + `test_check_sdd.py`。
实现只能在显式 traceability remediation + 新 readiness PR 合入后开始,
并须证明四 scope.yaml change 全过、`0/0/111` 不变。

## Acceptance matrix

| Evidence ID | Method | Expected result | Status |
| --- | --- | --- | --- |
| GUARD-SCOPE-COVERAGE-001 | 合成 fixture + 真实基线 offline 测试 | 对含 scope.yaml 的 change 校验每个不透明 acceptance ID 均在某个 Requirements/AC 认领面以完整、大小写敏感字符串出现,未认领即具名 err;单向(任务可引 scope 外只读 input);无 scope.yaml 跳过;正例覆盖 `AC-*`/`MAC-*`/`HW-*`、反引号/分隔/续行变体;反例覆盖漏认领 1 个即恰一具名 err、标识符粘连不误匹配、`…`/`*`/`01/02`/`等` 不展开;追溯补齐后真实基线四 change 零 scope-coverage err 且 check-sdd 0/0/111;仅改 guard+测试,零 spec/contract/product/设备变更 | pending |

## Gate

- guard 增强不引入 false positive:显式 traceability remediation 合入后,
  实现前后 `scripts/check-sdd.sh` 均为 `0 errors / 0 warnings /
  111 acceptance IDs`,current-main 四个 scope.yaml change 精确覆盖成立。
- 精确匹配:scope ID 为不透明字符串;标识符边界内大小写敏感匹配;
  `…`/`*`/`01/02`/`等` 不构成隐式认领。
- 单向校验:只 `scope acceptance ⊆ claimed`,不反向;任务引用 scope 外 canonical
  Safety input 不报错。
- class `implementation-only`:归档/verify 无 ratification 成分;不改变任何既有
  change 状态或 AC。
