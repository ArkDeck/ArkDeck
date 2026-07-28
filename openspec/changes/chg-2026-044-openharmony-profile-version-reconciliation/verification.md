# CHG-2026-044 Verification Plan

> Change:CHG-2026-044-openharmony-profile-version-reconciliation@r1
> Status:passed # 2026-07-28；三条 AC 与完整交付链见 proposal.md「Verification closure」；仅在维护者 review/merge 本 verification-only PR 后生效
> Core baseline:CORE-2.1.0（canonical Core AC 零认领）

## Environment

- protected-main checkout on macOS；Python/runtime 版本在 readiness 与 run evidence 中
  精确记录。
- 只读取 repository profile/lock/registry/history，tests 使用临时目录中的合成
  Markdown/YAML controls。
- 禁止执行 installed HDC、访问真实设备、network、server lifecycle 或任何
  device/binding/destructive operation。

## Acceptance matrix

| AC ID | Verification method | Expected result | Minimum evidence |
| --- | --- | --- | --- |
| `OPVR-HEADER-LOCK-001` | independent header parse, lock/profile/body/device-registry lineage audit | living header and current lock agree on existing `OPENHARMONY-TOOLS@0.5.0`; no new profile/lock version is created | contract |
| `OPVR-MUTATION-001` | focused unit suite plus explicit version/id/metadata/duplicate mutations | every mismatch or malformed form reports a deterministic SDD error; exact control is green | contract |
| `OPVR-NONINTERFERENCE-001` | forbidden-path blob/diff audit, full SDD suite and dispatch declaration | lock, registries, profile body, Core/platform/production sources remain unchanged; HDC/device/effect dispatch is zero | contract |

## `OPVR-HEADER-LOCK-001`

- profile leading metadata contains exactly one `ID: OPENHARMONY-TOOLS` and one
  `Version: 0.5.0` after normalizing only the accepted ASCII/full-width colon spelling；
- integration lock remains `INTEGRATION-PROFILES-0.6.0` and its single current
  `OPENHARMONY-TOOLS` entry remains version `0.5.0` at the exact profile path；
- device registry continues to bind `OPENHARMONY-TOOLS@0.5.0`；
- profile content outside the one header-version line is byte-identical to readiness pin。

## `OPVR-MUTATION-001`

- clean minimal lock/profile fixture reports no reconciliation error；
- changing only profile version from `0.5.0` to `0.4.0` reports version mismatch；
- changing only profile ID reports ID mismatch；
- missing/duplicate ID or Version metadata reports structural error；
- duplicate lock profile id/path reports duplicate error；
- non-mapping entry、missing/unreadable path or malformed metadata reports an error without
  aborting later checks；
- evidence records at least one red mutation and the restored green control。

## `OPVR-NONINTERFERENCE-001`

- `INTEGRATION-PROFILES.lock.yaml`、device/readonly/trace registries/resources、
  `core-conformance.yaml`、platform profiles、Core specs/contracts/baselines、
  production/test package sources and archived evidence match readiness pins；
- checker change is limited to integration lock/profile header consistency and does not
  reinterpret historical consumer pins or registry authority；
- installed HDC、真实设备、network、server lifecycle、device/binding mutation 与
  destructive dispatch 全部为 0。

## Negative and recovery tests

- mismatch/missing/duplicate/malformed inputs fail closed as SDD errors；
- a bad profile does not prevent the checker from reporting later independent errors；
- cancellation or checker process failure produces no repository/runtime state；
- reverting header without reverting guard makes baseline red，防止半回滚；
- full rollback re-establishes the pre-change blocked state and grants no HSO authority。

## Regression gates

- `python3 -m unittest scripts.test_check_sdd` passes；
- `scripts/check-sdd.sh` reports zero errors/warnings and the unchanged canonical AC count；
- PR allowed-path contract suite and `git diff --check` pass；
- forbidden-path blob comparison and secret/privacy scan pass。

## Deviations

任何需要修改 lock、registry、Core conformance、platform profile、production source 或
CHG-2026-043 的发现都使 `TASK-OPVR-001` 保持 blocked，并先修订本 change；不得在
implementation PR 中静默扩大范围。

## Result gate

- [x] 三条 change-local AC 均有 same-revision、可复查 host-only evidence。
- [x] proposal/approval/readiness/implementation/done/verified PR boundary 保持分离。
- [x] forbidden-path pins 与外部 dispatch 0 均有明确记录。
- [x] change `verified` 由独立状态 PR 引用具体 run；随后 HSO 仍走 fresh readiness。

Closure receipt:`proposal.md#verification-closure2026-07-28`；verification base =
protected main `38f0d4514ad16d9fe040fbd083d6e2f1a72e30f4`；revalidated
`2026-07-28T14:58:12Z`。本文件的 `passed` 与 proposal 的 `verified` 只在维护者
review/merge 本独立状态 PR 后生效；本 closure 不修改或执行 CHG-2026-043。
