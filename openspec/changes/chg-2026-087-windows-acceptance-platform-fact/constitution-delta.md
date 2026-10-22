# Constitution Delta

> Change: CHG-2026-087-windows-acceptance-platform-fact@r1
> Target: `openspec/constitution.md`
> Semantics: complete replacement of `POL-PLATFORM-002`; constitution document
> version 2.0.0 → 2.0.1. All other `POL-*` text is unchanged.

## MODIFIED Policies

### POL-PLATFORM-002 Declared platforms have explicit revalidation debt

任何 Core MINOR/MAJOR change SHALL 在 proposal 中说明对每个 declared target platform 的影响。已处于 `verified` 的平台在新 Core baseline 下 SHALL 立即变为 `needsReverification`，直到同一新 Conformance suite 通过。尚未开始实现的平台（如当前的 Linux）记录 `deferred` 即可，不阻断批准；`deferred` SHALL 禁止该平台的新支持声明或 release，它不构成 AC 豁免。实现已经开始且验收进行中、conformance 仍为 `notStarted` 的平台（如当前的 Windows）不是“尚未开始实现”的例子；在同一 Conformance suite 通过并成为 `verified` 之前，它 SHALL NOT 作支持声明或 release，该限制同样不构成 AC 豁免。
