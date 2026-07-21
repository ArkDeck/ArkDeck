# CHG-2026-024 Tasks

## TASK-I24-001 — register the parameterized device-observation snapshot family

- Status:blocked(change approval 已满足；r2 capture plan 由维护者 review/merge 本 PR
  生效；authoritative capture/provenance 与独立 readiness 未完成)
- Platform:macos
- Requirements/AC:change-local `I24-HDC-DEVICE-SNAPSHOT-001`/
  `I24-HDC-DEVICE-EMPTY-001`/`I24-HDC-DEVICE-PROVENANCE-001`/
  `I24-HDC-DEVICE-REGISTRY-001`/`I24-HDC-DEVICE-NODISPATCH-001`
- Depends on:CHG-2026-022 r2 merged（已满足）；本 change approval（PR #273，已满足）；
  r2 capture plan（维护者 review/merge 本 PR 构成满足）、受控 capture/provenance、
  readiness（后两项未满足）
- Allowed paths after readiness:
  - `openspec/integrations/openharmony/profile.md`
  - `openspec/integrations/openharmony/device-observation-probes.yaml`
  - `openspec/integrations/INTEGRATION-PROFILES.lock.yaml`
  - `openspec/platforms/macos/profile.md`（仅新增本 family mapping/version adoption；
    不改变 Core/platform conformance）
  - `Packages/ArkDeckKit/Tests/ArkDeckContractTests/Fixtures/HDC/Probes/DeviceObservation/1.0.0/**`
  - `Packages/ArkDeckKit/Tests/ArkDeckContractTests/HDCDeviceObservationRegistryContractTests.swift`
  - `openspec/changes/chg-2026-024-hdc-device-snapshot-registration/evidence/**`
  - 本 change `tasks.md`（仅本任务状态/evidence 引用）
- Forbidden paths:
  - `Packages/ArkDeckKit/Sources/**`
  - `ArkDeckApp/**`、`ArkDeckAppUITests/**`、`ArkDeck.xcodeproj/**`
  - `openspec/specs/**`、`openspec/contracts/**`、`openspec/baselines/**`
  - `openspec/integrations/openharmony/readonly-probes.yaml`
  - `Packages/ArkDeckKit/Tests/ArkDeckContractTests/Fixtures/HDC/Probes/1.0.0/**`
  - CHG-2026-015/022 tasks/evidence 或其他 change evidence
- Risk:high（错误的 parameterized grammar/empty classification 会制造设备出现或消失）
- Hardware required:no for Agent/CI implementation；supported provenance 需要维护者按
  `capture-plan.md` 提供受控真实 HDC/device capture，Agent 不执行

### Unblock prerequisites

1. 本 change 经独立 approval-only PR #273 由维护者批准并合入 main
   `1eeb516875858031a6a6cc5a44d5e6199f7e2aa5`（已满足）。
2. r2 `capture-plan.md` 经独立治理 PR 由维护者 review/merge；review/merge 本 PR 即构成
   该门满足，在此之前不得执行计划。
3. 维护者控制的 exact 3.2.0d capture 覆盖 zero/one/many/stable/appeared/disappeared，
   raw 留仓库外；每个来源 receipt/hash/accepted-by 经独立 evidence PR review/merge。
4. capture 对每次 command 提供 stable pre/post server identity、exact endpoint、exit/
   stdout/stderr hash/length，以及 server lifecycle/adoption、subserver、device migration/
   mutation/destructive counter 全 0；缺一保持 blocked/unsupported。
5. 独立 readiness PR 钉完整 main commit OID、所有输入/目标文件 Git blob OID 或完整
   SHA-256、profile/registry/resource candidate version、allowed-path overlap、Swift/SDD
   环境和二值 test matrix。
6. readiness 证明现有 readonly registry/resource/Core conformance pins保持 byte-identical；
   如需任何 Sources/Package.swift/Core 文件，先修订本 task scope，不能静默扩展。

### Deliverables

- `OPENHARMONY-TOOLS@0.4.0` mapping、独立 device-observation registry、
  `INTEGRATION-PROFILES-0.5.0` lock 与 macOS mapping；
- versioned redacted provenance receipts、fake negative/control vectors、resource manifest 与
  complete hash closure；
- registry contract 覆盖 zero/one/many、row order/duplicate、empty-vs-unknown、identity/
  endpoint drift、unsupported literal、stderr/nonzero/truncation、timeout/cancellation、privacy
  和旧 registry byte identity；
- `evidence/runs/TASK-I24-001/run.md`，记录 base、input provenance/hash、全部命令、
  change-local AC 二值结论、Agent installed-HDC/device/network/mutation dispatch 0、偏差与
  遗留风险。

### Verification

- 逐项执行 `acceptance-cases.yaml` 的五个 Test ID；缺 capture/provenance/hash/negative
  vector/old-registry identity 任一项，任务整体不得 done；
- `swift build --package-path Packages/ArkDeckKit --build-tests`；
  `swift test --package-path Packages/ArkDeckKit --filter HDCDeviceObservationRegistryContractTests`；
  `swift test --package-path Packages/ArkDeckKit`；`scripts/check-sdd.sh`；
  `git diff --check`；profile/registry/lock/resource hash 独立重算；allowed-path 与
  secret/privacy scan；
- Agent/CI 不执行 installed HDC。完成只登记 integration inputs，不将 CHG-2026-022、
  M0B-002、macOS conformance、hardware/support/release 标记为 passed/ready/done。

### PR boundary

Proposal、approval、capture-plan review、capture/provenance、readiness、registration
implementation+evidence、`ready→done`、change `verified` 与 CHG-2026-022
adoption/readiness 分别使用独立 PR。
