# CHG-2026-017 Verification Plan

> Status:passed;maintainer confirmation candidate 见文末;
> CHG-2026-017 `verified` 仅在本独立 verification closure PR 合入后生效
> Change:CHG-2026-017-guard-scope-coverage@r2
> Core baseline:CORE-2.0.0

本 change 是 guard 工具增强(class `implementation-only`):零 spec/contract/baseline/
product/设备变更。唯一交付=`scripts/check_sdd.py` 的 scope 覆盖校验 + `test_check_sdd.py`。
实现只能在显式 traceability remediation + 新 readiness PR 合入后开始,
并须证明四 scope.yaml change 全过、`0/0/111` 不变。

本文 acceptance matrix 的 Status 列保留起草期 `pending`,不追溯改写;
实际二值结论以 `evidence/runs/TASK-GUARD-001/run.md` 与文末合入版
`main` 复验为准。

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

## Maintainer confirmation candidate(2026-07-21)

- Governance chain:r1 approval PR #181
  (`d55b25fcfeff18f664fd8cf681a91c4591520c63`),r2 grammar PR #184
  (`d568800d49775482a5cc7ac8efc098c7587a7fb4`),traceability remediation
  PR #185 (`32ab471112f0cd7a998c709c45eaac8e439fc4d4`) 与 readiness PR #186
  (`f2edf9d69658e38d92080617ba62c9c91cd058e1`) 均已由维护者合入。
- Deliverable + evidence:TASK-GUARD-001 implementation/evidence PR #187 由
  `lvye` approve/review 并合入
  `5c2079c996aea74e3fbef6a510a68f99477263f0`;具体结论见
  `evidence/runs/TASK-GUARD-001/run.md`。
- Task completion:独立 `ready→done` PR #188 由 `lvye` approve/review 并
  合入 `e03b5c5cc533f04b5460205108b2a641d846cb9c`;合入版 `tasks.md` 中
  TASK-GUARD-001 为 `done`,且本 change 无其他任务。
- `TEST-GUARD-SCOPE-COVERAGE-001` / `GUARD-SCOPE-COVERAGE-001`:7 个
  offline test 全 PASS;覆盖 `AC-*`/`MAC-*`/`HW-*`/未来不透明 ID、反引号与
  各分隔符、续行、单向额外 token、具名断链、标识符粘连/大小写拒绝、
  干扰行、简写拒绝与无 scope 跳过。聚焦反例为 1 test/0 failures,
  内部断言未认领 `AC-X-003-01` 产生恰一条具名 error,恢复后消失。
- Real baseline:M0A/M1/CHG-005/M0B 分别 scope=28/68/1/5,全部
  missing=0;合入版增强 guard 为 0 errors/0 warnings/111 acceptance IDs。
- Scope/safety:implementation merge 只包含 guard、test 与 TASK-GUARD-001
  run evidence;completion merge 只包含本 change `tasks.md`;零设备/网络/
  destructive dispatch,零 spec/contract/baseline/product/platform/conformance 变更。
- Applicability:该 guard 为同步、只读、无持久化或外部副作用的 CI 检查;
  正常路径与具名错误路径已覆盖,cancellation、crash/restart 与 recovery
  场景对本 change 不适用。

维护者 review/merge 本 verification closure PR 后,上述 confirmation 满足
CHG-2026-017 `verified` gate。该结论只覆盖 r2 scope-coverage guard,不产生
产品能力、平台合规、硬件、support 或 release 声明,也不在本 PR 归档。
