# TASK-AHE-001 implementation run — 2026-07-29

## Scope and provenance

- Change:`CHG-2026-051-agent-hardware-evidence@r6`
- Task:`TASK-AHE-001`
- Executor:`agent`（Repo Agent Plane）
- Final implementation base:`1836ab149e1520665cfcbc087552baba1ad212d9`
  （r6 proposal merge；r5 proposal merge =
  `963be5374cfd10dedc06b81473d02fb4606ec135`）
- Declared readiness base:`40712017d248f4d0ae36a3d660e17d6f22f5ac54`
- Readiness result:43 项 exact source pins 逐项复核，零漂移。
- Evidence class:`contract/fake`。本 run 未连接真实设备，未执行 HDC、device runtime
  job、E1/E2 effect 或网络操作，real-hardware evidence publication count = 0。
  `DHA-HW-001` attempt#2 未复用、未修改、未追认。

## Implemented

- 将 current hardware-evidence contract 提升至 V3，明确
  `executor(human|agent)`、按实际 effect 匹配的 authority、同 job/binding 的
  target confirmation、model/firmware、实际 step kinds 与经重新散列的 Artifact
  references。
- 增加纯 `HardwareEvidenceProjector`；caller 只能提供 evidence ID、Acceptance IDs、
  validity 与 notes。缺失、空值、stale/mismatch、outcome unknown、simulation、
  authority/effect 漂移或 Artifact bytes/hash 不一致均返回
  `evidenceIncomplete`，publication count = 0。
- Runtime/daemon 新增只读 `job.evidence` 投影输入：admission decision、实际 effect、
  durable step/outcome、同 operation preflight、provider/tool 与 Artifact store facts。
  读取/投影路径不持有 capability mint 或 device dispatch 能力。
- 三个 production operations 在任何 evidence-bearing capture/E1 step 前执行
  descriptor-bound exact target、model、firmware typed preflight；property lowering
  使用精确 `-t <connect-key>`，unknown/ambiguous target 与事实漂移 fail closed。
- Operation Catalog schema/generator、generated Swift/matrix、remote-operation registry、
  durable WorkflowStep Swift/JSON registries同步；unknown、missing、cross-kind action
  reference 拒绝。
- process-level engine crash fixture 补齐 production-shaped target facts，原有两个 WAL
  crash windows、outcome-unknown 与 zero-redispatch 断言保持不变。
- V2 evidence bytes 只读识别、不迁移；legacy target-store record 仍可读，但不能缓存或
  合成 same-operation evidence facts。

## Verification commands and results

1. `CI=true swift test --package-path Packages/ArkDeckKit --filter
   'HardwareEvidenceWorkflowStepContractTests|RuntimeJobEngineContractTests/testCrashWindowsPreserveUnknownOutcomeAndNeverRedispatch'`
   — PASS，3 tests / 0 failures；两个 WAL crash windows 均到达并保持 zero redispatch。
2. `CI=true swift test --package-path Packages/ArkDeckKit --filter
   HardwareEvidenceProjectionContractTests`
   — PASS，7 tests / 0 failures；包含 required-fact/correlation、E0/E1/E2 authority、
   caller surface/JSON Schema Acceptance ID parity、V2 compatibility 正反矩阵。
3. `CI=true swift test --package-path Packages/ArkDeckKit`
   — PASS，666 tests / 0 failures / 1 个既有条件性 skip；TASK-AHE-001 的定向 tests
   均实际执行。
4. `python3
   openspec/changes/chg-2026-051-agent-hardware-evidence/evidence/runs/TASK-AHE-001/validate_v3.py`
   — `AHE-SCHEMA-V3:PASS (10 vectors)`。
5. `/Users/fuhanfeng/Dropbox/Code/Github/ArkDeck/.venv-sdd/bin/python
   scripts/catalog_gen/test_generate.py`
   — PASS，38 tests / 0 failures；包含 required/exact-kind remote action reference、
   generated Swift/matrix determinism 与 byte-for-byte drift checks。
6. `./scripts/check-sdd.sh`
   — `0 error(s), 0 warning(s), 111 acceptance IDs`。
7. readiness pin、allowed-path 与 evidence-record privacy audits
   — PASS；43/43 pins 相对 declared readiness base 零漂移，所有 staged/unstaged/
   untracked 文件均在 r6 Allowed paths，run records 中无已知 fake raw serial/connectKey
   （validator 的 rejected raw-serial 负例源码不计作 published evidence record）。
8. `git diff --check` 与 `git diff --cached --check`
   — PASS。

## Acceptance conclusions

- `AC-WF-004-01`:PASS（contract/fake）。Agent E0 integrated runner →
  daemon/runtime job → `job.evidence` → V3 projector 产生 schema/Swift
  round-trip record；target/binding、firmware/confirmation、actual steps 与 Artifact
  hashes 由同一 operation 的 product-owned facts 闭合。
- `AC-WF-004-02`:PASS（contract/fake）。required fact、freshness、target/binding、
  raw-serial privacy、caller injection、unknown/simulation 与 Artifact tamper vectors
  均 fail closed，publication count = 0。
- `AC-WF-004-03`:PASS（contract/fake）。E0/default read-only policy、
  E1/RuntimeCapability、E2/standing authorization 的结构匹配正例通过；cross-kind、
  missing、expired/drifted authority 以及 schema/projector dispatch separation 反例通过。

## Deviations and residual risk

- Deviation:none。
- 本 run 不是 hardware acceptance，也不把 fake/simulation 记作 realHardware。
- change 级 `verified` 尚未翻转；须由维护者基于本 run 与实现 PR 在独立 PR 中确认。
- archive 后消费方 `CHG-2026-049` 仍需 fresh readiness 与新的 E0 real-device run；
  不能复用 attempt#2。
