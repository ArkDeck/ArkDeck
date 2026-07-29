# CHG-2026-052 Verification Plan

> Change:CHG-2026-052-sdd-acceptance-count-currency@r2
> Status:planned
> Core baseline:CORE-2.1.0

## Environment

- protected-main checkout
- pinned repository SDD Python / PyYAML environment
- host-only/offline; no device, HDC, network, capability or realHardware evidence

## Acceptance matrix

| AC ID | Verification method | Expected result | Minimum evidence |
| --- | --- | --- | --- |
| `GUARD-COUNT-CURRENCY-001` | strict reader synthetic matrix + full SDD contract suite + real current-main subprocess + #816 114-count downstream replay | accepted positive integer is the only expected count source; malformed values and actual/declared mismatch fail; both 111 and approved 114 baselines pass without another test-source edit | contract |

## Negative and recovery tests

- missing `acceptance_index` or `count`;
- null, bool, string, float, zero and negative count;
- subprocess nonzero or summary count different from manifest;
- source pin drift before implementation requires stop/review, not fallback parsing;
- no cancellation/recovery/device cases apply because the test has no external effect.

## Deviations

No deviation is accepted. A wildcard/range count, reading expected count from the
subprocess output, weakening the zero-error/zero-warning assertion, modifying the
manifest/guard in the same implementation PR, or skipping CI is failure.

## Result gate

- [ ] strict reader valid/invalid matrix PASS
- [ ] full `scripts/test_check_sdd.py` PASS on current 111 manifest
- [ ] `scripts/test_check_pr_paths.py` and `scripts/check-sdd.sh` PASS
- [ ] CHG-2026-051 archive candidate reports 114 and SDD Guard PASS without another
      `scripts/test_check_sdd.py` edit
- [ ] implementation run evidence is same-revision and reviewable
- [ ] zero product/device/network dispatch; no platform/hardware support claim
