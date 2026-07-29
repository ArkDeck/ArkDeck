# CHG-2026-052 Spec Impact

> Change:CHG-2026-052-sdd-acceptance-count-currency@r1
> Core baseline:CORE-2.1.0

## No-op Core delta

- `openspec/specs/**`:零修改。
- `openspec/contracts/**`:零修改。
- canonical Acceptance index/cases:零 ID 或语义变化；
  `GUARD-COUNT-CURRENCY-001` 仅为 change-local contract AC。
- `openspec/verification/core-conformance.yaml`:零修改。
- Core baseline:保持 `CORE-2.1.0`。

## Guard-test impact

本 change 只改变 real-baseline contract test 的 expected-value sourcing：从
Python 字面量改为 accepted conformance manifest 的正整数 count。生产
`check_sdd.py`、SDD Guard workflow、allowed-path guard 与 protected-main approval
语义均不变。CI 绿仍只表示一致性检查通过，不构成批准。

## Platform impact

macOS/Windows/Linux 产品与 conformance 状态均不改变。实现仅在 host Python
contract suite 执行，零设备、零 HDC、零网络、零 runtime effect。
