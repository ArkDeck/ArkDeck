# CHG-2026-006 Spec Impact

> Change:CHG-2026-006-dayu200-m0b-bringup@r1

- Core Requirement/AC/contract/baseline:无修改(`core_change_level: none`)。
- Platform Profile / Integration Profile / locks:本 change 不修改。M0B evidence
  预期成为两个后续 change 的输入:
  1. DAYU200 Integration change:HiDumper 调用包装固定(`ui-dump` spec:47 的
     M0B 真机验证前置)、device-family golden fixture 登记与脱敏政策、
     DEC-002 四个 gap 的特征化;
  2. hardware matrix 后续升级(`observed` → `partial`/`verified`)所需的
     realHardware AC 定义(属未来 change,不在本 change)。
- `openspec/verification/hardware-matrix.md`:新增 `observed` 行(evidence 合入
  时,同 PR 经维护者 review;这是矩阵视图更新,不是 spec 修改)。
- 决策登记簿:本 change 不翻转任何 DEC;DEC-002 保持 open。
