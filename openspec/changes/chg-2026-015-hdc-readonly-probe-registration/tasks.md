# Tasks — CHG-2026-015 HDC read-only probe registration

> This change is `approved`（approval-only PR #123 已由维护者 review/merge 合入 `main`
> `9f08c9421a24beb5c670452ec42af7c0bbdef5b1`，2026-07-19）。No task may execute until an
> independent readiness PR confirms all four authoritative input families are available.

## TASK-I15-001 — register four closed production read-only probe families

- Status:blocked(authoritative input capture 与独立 readiness PR pending；change approval
  已由 PR #123 满足，2026-07-20 状态同步——#123 只更新了 proposal.md，本行与上方 banner
  据此对齐，不改变任务语义或解除任何 gate)
- Platform:macos integration input;Windows/Linux deferred
- Requirements:`REQ-HDC-001`、`REQ-HDC-002`、`REQ-HDC-003`、`REQ-HDC-006`、
  `REQ-HDC-007`、`REQ-HDC-009`、`REQ-HDC-010`
- Acceptance:`I15-HDC-SERVER-IDENTITY-001`、`I15-HDC-AUTH-BINDING-001`、
  `I15-HDC-KEY-ACCESS-001`、`I15-HDC-SUBSERVER-001`、`I15-HDC-PROVENANCE-001`、
  `I15-HDC-REGISTRY-001`、`I15-HDC-NODISPATCH-001`
- Depends on:CHG-2026-015 approved（已满足:PR #123）；四类 authoritative/controlled-human
  raw or platform receipt inputs 可读取且 provenance 已由维护者认可（未满足）；独立
  readiness PR merged（未满足）
- Allowed paths:
  - `openspec/integrations/openharmony/profile.md`
  - `openspec/integrations/openharmony/readonly-probes.yaml`（可新建）
  - `openspec/integrations/INTEGRATION-PROFILES.lock.yaml`
  - `Packages/ArkDeckKit/Tests/ArkDeckContractTests/Fixtures/HDC/Probes/1.0.0/**`
  - `Packages/ArkDeckKit/Tests/ArkDeckContractTests/HDCProbeRegistryContractTests.swift`
  - `Packages/ArkDeckKit/Package.swift`（仅为 ArkDeckContractTests 增加精确
    `.copy("Fixtures/HDC/Probes")` resource；不得改变 product/dependency/其他 resource）
  - `openspec/changes/chg-2026-015-hdc-readonly-probe-registration/evidence/**`
  - 本 change `tasks.md`（仅本任务状态与 completion evidence）
- Read-only inputs:
  - `openspec/changes/chg-2026-002-macos-m1-infrastructure/evidence/runs/TASK-M1-006/run.md`
  - `openspec/changes/chg-2026-005-hdc-parser-golden-registration/**`
  - `Packages/ArkDeckKit/Tests/ArkDeckContractTests/Fixtures/HDC/Golden/1.0.0/**`
  - 维护者认可的受控 capture/receipt（只读取；敏感 raw 不入仓）
- Forbidden paths:
  - `Packages/ArkDeckKit/Sources/**`
  - `ArkDeckApp/**`、`ArkDeckAppUITests/**`、`ArkDeck.xcodeproj/**`
  - `openspec/specs/**`、`openspec/contracts/**`、`openspec/baselines/**`
  - `openspec/platforms/**`、`openspec/verification/**`
  - CHG-2026-002 tasks/evidence 修改、既有 Golden fixture/registry 改写、其他 task/change evidence
- Risk:high(effect misclassification could authorize host-wide or device observation as read-only)
- Hardware required:no。Agent/CI 禁止运行真实 HDC/device；authoritative capture 由维护者在
  task 外提供。实现/验证本身只用 pinned inputs、fake/adversarial vectors 和本地文件。

### Deliverables

- `OPENHARMONY-TOOLS` 新版本和 structured `readonly-probes.yaml`，四类 family 全部有
  supported/unsupported 的二值、版本化结论；
- exact argv/receipt/effect/precondition/authority/timeout/cancellation/provenance entries；
- versioned raw/receipt resources 与 registry contract tests；
- Integration lock version bump，profile/registry/resource/hash closure；
- `evidence/runs/TASK-I15-001/run.md`，记录 base OID、input provenance/hash、全部命令、
  family matrix、真实 HDC/device/network/server mutation dispatch 0、偏差和遗留风险。

### Verification

- 每个 family 按 `acceptance-cases.yaml` 的 Test ID 二值验证；缺任一 provenance、entry、
  negative vector 或 hash closure，任务整体不得 done；
- exact argv 仅做静态/fixture contract，Agent/CI 不执行 installed HDC；server absent/start、
  lifecycle/subserver/device migration effects 只消费维护者提供的受控 receipt；
- contract tests 必须证明 unknown family、identity/binding mismatch、missing/denied key、
  unproven subserver 与 cancellation 全部 fail closed；
- `swift build --package-path Packages/ArkDeckKit --build-tests`；
  `swift test --package-path Packages/ArkDeckKit --filter HDCProbeRegistryContractTests`；
  `swift test --package-path Packages/ArkDeckKit`；`scripts/check-sdd.sh`；
  `git diff --check`；fixture/profile/lock SHA-256 独立重算；allowed-path 与 secret/privacy scan；
- 完成只证明 integration inputs 已登记，不将任何 `AC-HDC-*`、TASK-M1-006、macOS
  conformance、hardware/support/release 标记为 passed/done。

### PR boundary

一个独立 TASK-I15-001 registration implementation + evidence PR；`blocked→ready`、
`ready→done`、change `verified` 与 M1-006 adoption/readiness 分别使用独立 PR。
