# Tasks — CHG-2026-015 HDC read-only probe registration

> This change is `approved`（approval-only PR #123 已由维护者 review/merge 合入 `main`
> `9f08c9421a24beb5c670452ec42af7c0bbdef5b1`，2026-07-19）。No task may execute until an
> independent readiness PR confirms all four authoritative input families are available.

## TASK-I15-001 — register four closed production read-only probe families

- Status:ready(readiness candidate;仅在维护者 review/merge 本 readiness PR 后生效。
  本 PR 不含实现、不产生 evidence、不执行任何 hdc/device 命令)
- Readiness review(2026-07-20;host-only,零 HDC/device/network dispatch):
  - Change gate:satisfied。CHG-2026-015 approved(PR #123,main `9f08c942`);r2
    capture plan(PR #140)固定采集面;revision 标记三方一致 2/@r2(#152 同步)。
    本 readiness 不修改任务契约、七项 `I15-HDC-*` AC/method、acceptance-cases 或
    verification 定义(acceptance_id 计数 7,与 tasks/verification 锚点逐项对应)。
  - Input/provenance gate:satisfied——四类 authoritative input 全部经维护者
    review/merge 认可,逐文件 pin(全部于 `main` `2c3f6d8` 实测重算):
    - `subserverCapability`:`evidence/provenance/subserver-capability-doc.md`
      (PR #141,documentReview;SHA-256
      `6bb63426ecee6e0e86f4027bd7d9b6034db56e116663494885fd69aa89618013`);
    - `serverIdentityGeneration`+`keyAccessDiagnostics`:
      `evidence/provenance/host-only-capture-2026-07-20.md`(PR #155;SHA-256
      `7949d8a2f813b7f2f6b7d8ba45d37cca84d57167f0e319e4761b5f50e53493d8`)与
      `harness-checkserver.redacted-manifest.json`
      (`8d6d63177f59d784ccd071fd054a27873db8a8779481ac83a3110a5cda4787b4`);
    - `selectedDeviceAuthorizationBinding`:
      `evidence/provenance/device-window-capture-2026-07-20.md`(PR #156;SHA-256
      `a06cc98999adb1067448ab879870c77e88740988cbc3905dff933a98fb7ae887`)与
      `harness-list-targets.redacted-manifest.json`
      (`80b3c9d62f7aa5262bc647c7097067e0428d0f1c4975851480285b6c6365d417`);
    - 关键流锚点(raw 留仓库外,hash 在各 record 内钉定):`checkserver` stdout
      `50e8dfe0…`(client/server 双 `Ver: 3.2.0d`)、plain 33B `2035c078…`、
      verbose 58B `d8816e41…`(与 merged M0B evidence 跨日逐字节相同);instrument
      `scripts/m0b_capture/capture.py` `be66c30e…`。
  - Scope/base gate:satisfied on merge。实现范围严格等于 Allowed paths;
    `Fixtures/HDC/Probes/**` 与 `HDCProbeRegistryContractTests.swift` 在当前 `main`
    不存在(零碰撞实测);`Package.swift` 仅加 `.copy("Fixtures/HDC/Probes")` 单行
    resource(I5-001 先例:版本化子目录须 `.copy` 保留目录树,勿用 `.process`;
    二进制 fixture 先钉 `.gitattributes` 再 commit);实现 base = 本 readiness 合入后
    `main` HEAD,source OID/逐文件 SHA-256 由实现 run.md 执行时记录(不预钉)。
  - Environment gate:satisfied。`<ARKDECK_ROOT>/.venv-sdd/bin/python` 实测 Python
    `3.14.6`+PyYAML `6.0.3`;Swift 全量基线 261 tests/1 known opt-in skip/0 failures
    (2026-07-20 于 `main` `2c3f6d8` 实测);实现/验证只用 pinned inputs、
    fake/adversarial vectors 与本地文件,Agent/CI 零 installed-HDC/device 执行。
  - Path/concurrency gate:satisfied。open PR 数 0(实测);CHG-008 侧 `ready` 的
    TASK-UD-CAP-MUT-001 为人工设备任务,与本任务 Allowed paths 零交集;
    `Fixtures/HDC/Golden/1.0.0/**` 与既有 registry/lock 对本任务只读(不得改写)。
  - Review boundary:本 readiness PR 只翻转本任务状态并记录 readiness review;
    probe entries、fixture 内容、`OPENHARMONY-TOOLS` 新版本号与 lock bump 均在
    implementation PR 由维护者逐项 review;`blocked→ready` 生效即授权起草
    implementation PR,不解除 Verification 节任何 gate、不改变 M1-006 状态。
- Platform:macos integration input;Windows/Linux deferred
- Requirements:`REQ-HDC-001`、`REQ-HDC-002`、`REQ-HDC-003`、`REQ-HDC-006`、
  `REQ-HDC-007`、`REQ-HDC-009`、`REQ-HDC-010`
- Acceptance:`I15-HDC-SERVER-IDENTITY-001`、`I15-HDC-AUTH-BINDING-001`、
  `I15-HDC-KEY-ACCESS-001`、`I15-HDC-SUBSERVER-001`、`I15-HDC-PROVENANCE-001`、
  `I15-HDC-REGISTRY-001`、`I15-HDC-NODISPATCH-001`
- Depends on:CHG-2026-015 approved（已满足:PR #123）；四类 authoritative/controlled-human
  raw or platform receipt inputs 可读取且 provenance 已由维护者认可（未满足——采集面已由
  r2 `capture-plan.md` 固定:三类 host-only 可随时采集、`selectedDeviceAuthorizationBinding`
  需独立设备窗口;维护者按计划采集后,capture record 经 evidence PR 合入
  `evidence/provenance/**` 即构成认可；其中 `subserverCapability` 的 documentation
  provenance 已由 PR #141 合入 `evidence/provenance/subserver-capability-doc.md`,
  1/4 family 已满足——2026-07-20 账本对齐补记;同日 `serverIdentityGeneration` 与
  `keyAccessDiagnostics` 的 host-only capture record 随 evidence PR 合入
  `evidence/provenance/host-only-capture-2026-07-20.md`(merge 即认可),3/4 已满足;
  同日 `selectedDeviceAuthorizationBinding` 经独立设备窗口采集,capture record 随
  evidence PR 合入 `evidence/provenance/device-window-capture-2026-07-20.md`
  (merge 即认可),**4/4 全部满足**——剩余前置仅为独立 readiness PR）；独立 readiness PR merged（未满足）
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
