# CHG-2026-036 Tasks

> r1 proposal PR 只登记 change package。六个任务全部保持 `blocked`；正式 approval、
> 每个 D1 readiness、implementation/evidence、D0 done、verification 与 archive
> 分别使用独立 PR。任一任务不得把后继任务的工作投机堆入同一 PR。

## TASK-BRC-001 — 闭合 source、license、dependency 与 distribution 决策

- Status:blocked
- Platform:macos
- Requirements：`REQ-FLASH-004`、`REQ-FLASH-013`、`REQ-UX-007`
- Acceptance：`BRC-SUPPLY-001`、`BRC-HANDOFF-001`、
  `AC-FLASH-013-01`、`AC-UX-007-01`
- Depends on：CHG-2026-036 formal approval；ADR-0003 accepted/archive ancestry
- Readiness input pins：未实例化；独立 readiness 必须固定 proposal/approval/ADR merge
  OID、upstream commit/source archive digest、license/dependency primary sources、
  retrieval date、review owner 与 exact allowed paths
- Applicable failure patterns：`AF-001`、`AF-002`、`AF-007`、`AF-009`、`AF-010`
- Production reachability：not applicable；host-only document/legal/distribution
  review，不 build/launch component，不产生 authority/effect
- Trusted fact sources：protected-main Git objects、exact maintainer review/merge、
  upstream repository/license/build files、dependency primary license/security
  records与 Apple distribution documentation；Agent 推断、二手文章、Homebrew
  installation state不能构成 license/distribution 接受
- Allowed paths:
  - `docs/release/rockchip-component-distribution.md`
  - `openspec/changes/chg-2026-036-macos-bundled-rockchip-component/design.md`
  - `openspec/changes/chg-2026-036-macos-bundled-rockchip-component/tasks.md`
  - `openspec/changes/chg-2026-036-macos-bundled-rockchip-component/verification.md`
  - `openspec/changes/chg-2026-036-macos-bundled-rockchip-component/evidence/**`
- Forbidden paths:
  - `openspec/constitution.md`
  - `openspec/specs/**`
  - `openspec/contracts/**`
  - `openspec/integrations/**`
  - `openspec/changes/chg-2026-026-macos-rockchip-flash-ui/**`
  - `ArkDeckApp/**`
  - `ArkDeck.xcodeproj/**`
  - `Packages/**`
  - `.github/**`
  - `scripts/**`
  - `vendor/**`
- Risk:medium（无 runtime effect，但错误接受会进入可执行代码发布供应链，必须 D1）
- Hardware required:no

### Deliverables

- 一份 maintainer-accepted distribution record，精确闭合：
  upstream/source acquisition、GPL-2.0 obligations、notices、corresponding source/
  source offer、modifications/build scripts、libusb/libiconv 与全部 transitive
  dependency、SBOM/CVE owner、update/rollback/retention；
- 对 architecture、minimum OS、builder/toolchain、hermetic input 与 reproducibility
  verdict 的可执行后继 gate；
- `evidence/runs/TASK-BRC-001/run.md`，结论只能是 accepted 或 blocked；proposal/
  approval merge 本身不算 legal acceptance。

### Verification

- `BRC-SUPPLY-001`：每个 source/license/dependency/distribution criterion 都有
  primary source、owner、明确 verdict 与后继 machine-checkable pin；
- `BRC-HANDOFF-001`：零 product/build/network artifact/process/USB/device effect，
  CHG-2026-026/Core/HDC 决策零变化；
- SDD、allowed/forbidden path、diff 与 secret/privacy scan 全绿。

### Notes / handoff

- 若维护者不接受 GPL-2.0 distribution 或任一 dependency/source-offer 义务，本任务
  记录 blocked 并停止整个 change；不得用下载预编译 binary 或外部工具 fallback。

## TASK-BRC-002 — 实现 hermetic/reproducible build、registry 与 SBOM

- Status:blocked
- Platform:macos
- Requirements：`REQ-FLASH-004`、`REQ-FLASH-013`、`REQ-JOB-005`
- Acceptance：`BRC-REPRO-001`、`AC-FLASH-013-01`、`AC-JOB-005-01`
- Depends on：`TASK-BRC-001` done；独立 D1 readiness
- Readiness input pins：未实例化；必须固定 001 accepted merge、source/dependency
  digests、recipe revision、builder/toolchain/minimum OS/architectures、expected
  output normalization 与 clean-builder procedure
- Applicable failure patterns：`AF-001`、`AF-002`、`AF-003`、`AF-007`、
  `AF-009`、`AF-010`、`AF-017`
- Production reachability：not applicable；host-side unsigned component build only，
  不进入 App bundle、不 launch、不产生 process/device authority
- Trusted fact sources：001 accepted record、pinned source/dependency archives、
  reviewed build recipe、two isolated clean-builder receipts 与 cryptographic
  digests；host PATH/Homebrew/cache 自报不能成为输入
- Allowed paths:
  - `vendor/rockchip/**`
  - `scripts/rockchip_component/**`
  - `.github/workflows/rockchip-component.yml`
  - `openspec/integrations/rockchip/bundled-component/**`
  - `docs/release/rockchip-component-distribution.md`
  - `openspec/changes/chg-2026-036-macos-bundled-rockchip-component/design.md`
  - `openspec/changes/chg-2026-036-macos-bundled-rockchip-component/tasks.md`
  - `openspec/changes/chg-2026-036-macos-bundled-rockchip-component/verification.md`
  - `openspec/changes/chg-2026-036-macos-bundled-rockchip-component/evidence/**`
- Forbidden paths:
  - `openspec/constitution.md`
  - `openspec/specs/**`
  - `openspec/contracts/**`
  - `openspec/changes/chg-2026-026-macos-rockchip-flash-ui/**`
  - `ArkDeckApp/**`
  - `ArkDeck.xcodeproj/**`
  - `Packages/**`
- Risk:medium（构建可执行供应链，但未进入 product/runtime）
- Hardware required:no

### Deliverables

- source-pinned、dependency-locked、无 ambient Homebrew/PATH input 的 build recipe；
- versioned bundled-component registry、license/notice/corresponding-source manifest、
  reviewable SBOM 与 vulnerability ownership metadata；
- 两个独立 clean build 的 unsigned artifact reproducibility/normalized-diff receipt，
  覆盖声明的 architecture 与 minimum macOS；
- negative tests：source/dependency/toolchain/hash/architecture drift、network/cache/
  ambient library 注入均 fail closed。

### Verification

- `BRC-REPRO-001`：同 pins 的两个 clean builders 产生相同 unsigned artifact
  identity（或 readiness 明确批准的可复查 normalization），registry/SBOM/manifest
  与 artifact dependency graph 一致；
- `AC-JOB-005-01`：build/runtime descriptor 没有 PATH/shell/caller environment；
- 不 launch artifact，不访问 USB/设备；SDD、build tests、diff、secret/privacy scan
  全绿。

### Notes / handoff

- task 完成不表示 binary 可签名、可打包或可分发；`TASK-BRC-003` 必须重新 pin exact
  artifact/registry/blob。

## TASK-BRC-003 — 闭合 nested component 打包、签名与公证

- Status:blocked
- Platform:macos
- Requirements：`REQ-FLASH-004`、`REQ-FLASH-013`、`REQ-JOB-005`、
  `REQ-UX-007`
- Acceptance：`BRC-PACKAGE-001`、`AC-FLASH-013-01`、
  `AC-JOB-005-01`、`AC-UX-007-01`
- Depends on：`TASK-BRC-002` done；独立 D1 readiness
- Readiness input pins：未实例化；必须固定 exact unsigned artifact/registry/SBOM、
  bundle location/identifier、App/child entitlement blobs、signing order、
  Developer ID/notary environment contract、DMG/release scripts 与 negative fixtures
- Applicable failure patterns：`AF-001`、`AF-002`、`AF-003`、`AF-007`、
  `AF-009`、`AF-010`、`AF-017`
- Production reachability：ArkDeck Xcode/archive root → fixed nested component copy →
  inside-out sign → App sign/notarize；本任务仍不从 App launch child，不产生 device
  authority/effect
- Trusted fact sources：BRC-002 accepted registry/artifact, Xcode build graph,
  codesign designated requirement/entitlement output, Gatekeeper/notary/stapler
  receipts；credential holder与artifact builder不能用自报字段替代独立 inspection
- Allowed paths:
  - `ArkDeck.xcodeproj/**`
  - `ArkDeckApp/**`
  - `scripts/release/**`
  - `scripts/rockchip_component/**`
  - `openspec/integrations/rockchip/bundled-component/**`
  - `docs/release/**`
  - `openspec/changes/chg-2026-036-macos-bundled-rockchip-component/design.md`
  - `openspec/changes/chg-2026-036-macos-bundled-rockchip-component/tasks.md`
  - `openspec/changes/chg-2026-036-macos-bundled-rockchip-component/verification.md`
  - `openspec/changes/chg-2026-036-macos-bundled-rockchip-component/evidence/**`
- Forbidden paths:
  - `openspec/constitution.md`
  - `openspec/specs/**`
  - `openspec/contracts/**`
  - `openspec/changes/chg-2026-026-macos-rockchip-flash-ui/**`
  - `Packages/**`
- Risk:medium（改变 App release/package shape，但零 runtime/device effect）
- Hardware required:no

### Deliverables

- fixed nested location/identifier、Code Sign On Copy/inside-out signing、minimum OS、
  architectures 与 exact child entitlements；
- Release App/DMG 的 Developer ID、Hardened Runtime、notarization、stapling 与 nested
  signature verification automation；
- negative package fixtures/tests：missing/wrong signature、location、identifier、
  arch、min OS、entitlement、registry/hash、notary/staple 全部 fail closed；
- sanitized package evidence；零 credential/private key 入仓。

### Verification

- `BRC-PACKAGE-001`：signed App/DMG inspection 对每个固定 field exact match，child
  只有 `app-sandbox=true` 与 `inherit=true`，App entitlement 仍为现行六项；
- binary/registry/SBOM/source-offer tuple 一致；任何 drift 阻止 release；
- 不 launch child、不访问 USB/设备；SDD/package tests/diff/secret scan 全绿。

### Notes / handoff

- ad-hoc/Debug evidence 不能替代 Developer ID/notary evidence；Developer ID secret
  只由批准的 release operator/environment 使用。

## TASK-BRC-004 — 迁移 product-owned composition 与 typed file leases

- Status:blocked
- Platform:macos
- Requirements：`REQ-FLASH-001`、`REQ-FLASH-004`、`REQ-FLASH-005`、
  `REQ-FLASH-008`、`REQ-FLASH-012`、`REQ-FLASH-015`、
  `REQ-JOB-002`、`REQ-JOB-003`、`REQ-JOB-005`、`REQ-JOB-006`
- Acceptance：`BRC-COMPOSITION-001`、`AC-FLASH-001-01`、
  `AC-FLASH-005-01`、`AC-FLASH-008-01`、`AC-FLASH-012-01`、
  `AC-FLASH-015-01`、`AC-JOB-002-01`、`AC-JOB-003-01`、
  `AC-JOB-005-01`、`AC-JOB-006-01`
- Depends on：`TASK-BRC-003` done；独立 D1 readiness
- Readiness input pins：未实例化；必须固定 signed package/registry identity、current
  host/facade/process/storage blobs、file-lease model、fault matrix、production
  reachability query 与 exact test commands
- Applicable failure patterns：`AF-001`、`AF-002`、`AF-003`、`AF-004`、
  `AF-006`、`AF-007`、`AF-009`、`AF-010`、`AF-012`、`AF-017`
- Production reachability：ArkDeckApp composition root →
  `RockchipFlashApplicationFacade`/`RockchipFlashExecutionHost` → typed
  plan/binding → existing authorization gate → product-owned bundled descriptor →
  process port/executor → future RockUSB effect → durable outcome；本任务保持 App UI
  execute disabled且无法取得 E2 authority
- Trusted fact sources：reviewed bundle registry + independently inspected bundle
  identity；device facts由 typed discovery/binding produced；intent/outcome由 durable
  store produced。调用方不能同时构造 executable/receipt/authority 或伪造 child result
- Allowed paths:
  - `Packages/ArkDeckKit/Package.swift`
  - `Packages/ArkDeckKit/Sources/ArkDeckWorkflows/**`
  - `Packages/ArkDeckKit/Sources/ArkDeckStorage/**`
  - `Packages/ArkDeckKit/Tests/ArkDeckContractTests/**`
  - `ArkDeckApp/**`
  - `ArkDeck.xcodeproj/**`
  - `openspec/integrations/rockchip/bundled-component/**`
  - `openspec/changes/chg-2026-036-macos-bundled-rockchip-component/design.md`
  - `openspec/changes/chg-2026-036-macos-bundled-rockchip-component/tasks.md`
  - `openspec/changes/chg-2026-036-macos-bundled-rockchip-component/verification.md`
  - `openspec/changes/chg-2026-036-macos-bundled-rockchip-component/evidence/**`
- Forbidden paths:
  - `openspec/constitution.md`
  - `openspec/specs/**`
  - `openspec/contracts/**`
  - `openspec/changes/chg-2026-026-macos-rockchip-flash-ui/**`
  - `Packages/ArkDeckKit/Sources/ArkDeckCLI/**`
- Risk:high（production composition/authority/effect 邻接代码；仅 contract/fake，零真实 effect）
- Hardware required:no

### Deliverables

- product-owned bundled descriptor/identity seam 与 App composition root；
- 删除 production route 对 user-selected executable URL/hash/bookmark、raw argv/
  environment/component receipt/authority bytes 的输入；
- typed image/key/output leases、cancel/timeout/partial/crash/restart/reconcile 与
  intent/outcome wiring；
- contract/fake/source-reachability tests，证明 external/PATH/shell/fallback/
  caller-forged identity 不可达，App UI execute 仍 disabled，真实 process/USB/device/
  E1/E2 dispatch 为 0。

### Verification

- `BRC-COMPOSITION-001` 与所列 canonical AC 通过 contract/fake/fault/source audit；
- crash-after-intent/unknown-outcome 必须 `waitingForRecovery`，零 automatic replay；
- build/test/SDD/allowed-path/diff/secret scan 全绿，硬件支持仍 `not proven`。

### Notes / handoff

- fake/contract 不能证明 signed Sandbox child、文件或 USB access；这些只由
  `TASK-BRC-005` 证明。

## TASK-BRC-005 — 取得 signed Sandbox E0、file-access 与 RockUSB 只读证据

- Status:blocked
- Platform:macos
- Requirements：`REQ-FLASH-001`、`REQ-FLASH-004`、`REQ-FLASH-008`、
  `REQ-FLASH-012`、`REQ-FLASH-013`、`REQ-FLASH-015`、
  `REQ-JOB-005`、`REQ-UX-007`
- Acceptance：`BRC-SANDBOX-E0-001`、`AC-FLASH-001-01`、
  `AC-FLASH-008-01`、`AC-FLASH-012-01`、`AC-FLASH-013-01`、
  `AC-FLASH-015-01`、`AC-JOB-005-01`、`AC-UX-007-01`
- Depends on：`TASK-BRC-004` done；独立 D1 readiness 与 exact E0 device window
- Readiness input pins：未实例化；必须固定 signed App/component tuple、test
  image/key/output fixtures、DAYU200 identity/USB topology、E0 commands、operator、
  privacy transform、effect counters、timeouts、disconnect/cancel cases 与 zero-E1/E2
  boundary
- Applicable failure patterns：`AF-001`、`AF-002`、`AF-003`、`AF-004`、
  `AF-005`、`AF-006`、`AF-007`、`AF-008`、`AF-009`、`AF-010`、`AF-012`
- Production reachability：signed ArkDeckApp E0 harness → product-owned descriptor →
  exact signed child → separately bounded version/`ld`, file-lease diagnostic and
  RockUSB read-only observation；该 E0 harness 没有 E2 authority 入口，mutation
  dispatch counter 必须保持 zero
- Trusted fact sources：signed/notarized component inspection、OS Sandbox/Gatekeeper
  result、typed app-owned receipts、independent USB/device identity observation；
  child/caller self-report cannot alone prove identity/access/effect
- Allowed paths:
  - `ArkDeckApp/**`
  - `ArkDeckAppUITests/**`
  - `ArkDeck.xcodeproj/**`
  - `Packages/ArkDeckKit/**`
  - `scripts/rockchip_component/**`
  - `scripts/e0_readback/**`
  - `openspec/integrations/rockchip/bundled-component/**`
  - `openspec/changes/chg-2026-036-macos-bundled-rockchip-component/design.md`
  - `openspec/changes/chg-2026-036-macos-bundled-rockchip-component/tasks.md`
  - `openspec/changes/chg-2026-036-macos-bundled-rockchip-component/verification.md`
  - `openspec/changes/chg-2026-036-macos-bundled-rockchip-component/evidence/**`
- Forbidden paths:
  - `openspec/constitution.md`
  - `openspec/specs/**`
  - `openspec/contracts/**`
  - `openspec/changes/chg-2026-026-macos-rockchip-flash-ui/**`
  - `openspec/verification/hardware-matrix.md`
- Risk:high（真实 signed process/USB E0；严格零 device mutation/E1/E2/destructive）
- Hardware required:yes

### Deliverables

- 三类分离 receipt：embedded component version/`ld`、child file-lease diagnostic、
  RockUSB read-only E0；各自记录 process/file/USB/mutation counters；
- no-device、permission denial、wrong identity/hash/version、malformed/multi-device、
  symlink/TOCTOU、file denial、cancel/timeout/disconnect/child crash negative evidence；
- raw device ID/path/log/credential/image/key 内容经 reviewable transform 移除；
- 明确声明 E0 PASS 不等于 Flash/hardware conformance。

### Verification

- `BRC-SANDBOX-E0-001`：exact signed component 在现行 App/child entitlement 下完成
  独立的 bounded E0/file stages，mutation/E1/E2/destructive/privilege/system change
  counters 全为 0；
- 任何 identity/access/USB/outcome unknown 都 fail closed，零 fallback；
- signed tests、SDD、allowed-path、diff、secret/privacy scan 全绿。

### Notes / handoff

- 本 task 不执行 `ppt/wlx/rd`、Loader transition 或真实 update；无 standing
  authorization需求，也不得接受 destructive authorization。

## TASK-BRC-006 — 验证 Developer ID/notarized DMG clean-host、update 与 rollback

- Status:blocked
- Platform:macos
- Requirements：`REQ-FLASH-004`、`REQ-FLASH-013`、`REQ-JOB-006`、
  `REQ-UX-007`
- Acceptance：`BRC-DISTRIBUTION-001`、`BRC-HANDOFF-001`,
  `AC-FLASH-013-01`、`AC-JOB-006-01`、`AC-UX-007-01`
- Depends on：`TASK-BRC-005` done；独立 D1 readiness；human-controlled release
  credentials/environment
- Readiness input pins：未实例化；必须固定 Developer ID/notary release artifact、
  source/SBOM/notices payload、clean host/VM snapshots、install/update/downgrade/
  rollback scenarios、credential owner、network endpoints 与 sanitized evidence
  transform
- Applicable failure patterns：`AF-001`、`AF-002`、`AF-003`、`AF-007`、
  `AF-009`、`AF-010`、`AF-014`、`AF-017`
- Production reachability：human-controlled release pipeline → signed/notarized DMG →
  clean-host install/launch/E0 → update/rollback；零 device mutation与零 E2 authority
- Trusted fact sources：release operator/environment、Developer ID/notary/Gatekeeper
  receipts、clean VM observation、artifact/source/SBOM digests；PR author不能用本地
  ad-hoc build或自报 notarization 结果替代
- Allowed paths:
  - `.github/workflows/**`
  - `ArkDeck.xcodeproj/**`
  - `ArkDeckApp/**`
  - `docs/release/**`
  - `scripts/release/**`
  - `scripts/rockchip_component/**`
  - `openspec/integrations/rockchip/bundled-component/**`
  - `openspec/changes/chg-2026-036-macos-bundled-rockchip-component/design.md`
  - `openspec/changes/chg-2026-036-macos-bundled-rockchip-component/tasks.md`
  - `openspec/changes/chg-2026-036-macos-bundled-rockchip-component/verification.md`
  - `openspec/changes/chg-2026-036-macos-bundled-rockchip-component/evidence/**`
- Forbidden paths:
  - `openspec/constitution.md`
  - `openspec/specs/**`
  - `openspec/contracts/**`
  - `openspec/changes/chg-2026-026-macos-rockchip-flash-ui/**`
  - `openspec/verification/hardware-matrix.md`
- Risk:high（外部 release/notary/update effect；零设备 mutation）
- Hardware required:no

### Deliverables

- clean-host/VM install and launch、nested signature/Gatekeeper/notary/staple、
  notices/SBOM/corresponding-source availability 的复验记录；
- supported update 与 rollback/downgrade 场景，证明 component/App tuple 原子更新、
  drift fail closed、旧 Job unknown 不被 replay；
- credential/network/privacy redaction 与 release retention 记录；
- final handoff 明确 CHG-2026-026 仍需独立 revision/readiness/真实 destructive
  acceptance。

### Verification

- `BRC-DISTRIBUTION-001`：全新 host 只用发布 DMG 即可验证完整 signature/notary/
  supply-chain tuple 与 bounded E0；update/rollback 不产生 mixed-version reachability；
- `BRC-HANDOFF-001`：Core/HDC/CHG-2026-026/hardware matrix 未静默变化，不形成真实
  Flash 支持声明；
- release/platform tests、SDD、allowed-path、diff、secret/privacy scan 全绿。

### Notes / handoff

- clean-host PASS 后仍需独立 D0 done 与 verification closure；不得在本任务直接修改
  CHG-2026-026 或启用 App Flash UI。
