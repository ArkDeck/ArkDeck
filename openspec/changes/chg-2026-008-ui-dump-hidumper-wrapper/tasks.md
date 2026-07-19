# Tasks — CHG-2026-008 ui-dump HiDumper wrapper integration

> V2 治理:本文件是任务的唯一事实源;任务状态变更仅在维护者 review/merge 后
> 生效。全部真机采集由人类维护者执行,Agent 不执行真实 `hdc`。

## TASK-UD-001 — 固定 HiDumper 调用包装 + golden 登记 + 对抗测试

- Status:ready（r2 dependency/readiness revision candidate；仅在本治理 PR 由维护者
  review/merge 后生效。本 PR 不执行 TASK-UD-001、不产生 implementation/acceptance
  evidence，也不使 CHG-008 verified）
- Readiness review（2026-07-19；只读审计，零真实 HDC/device dispatch）：
  - Change/revision gate:satisfied on merge。CHG-008 r1 已经维护者批准；本 r2 只替换
    implementation scheduling dependency、补全 DoR 与起草 `blocked→ready`，不修改任何
    Requirement、AC、contract、schema、baseline 或产品安全默认值。
  - Consolidation gate:satisfied。TASK-RLC-001 implementation PR #110 已合入
    `main` `f7c334857ae5735077254ccbdf3dafac8c8ad83b`，done 状态 PR #113 已合入
    `e67568e56c53389090958c7aedb9b0681d6f2816`；CHG-2026-014 verification closure
    PR #114 已合入 `1c0420a18a8f77e4386ea77e8292ecf1217f09fe`。其 provenance manifest
    证明固定 M1-006 source tree/interfaces 已在 `main`，且允许 consumer 通过独立 revision
    使用这些实现 bytes。
  - Independence gate:satisfied。TASK-UD-001 不消费 TASK-M1-006 尚缺的 server
    identity/generation、selected-device authorization/binding、key-access、subserver
    probe family、signed Sandbox XCUITest、source-task AC 或 conformance/support evidence；
    本任务只新增独立 HiDumper wrapper、fixture/resource contract 与 integration 登记。
    TASK-M1-006 保持 `blocked`/非 `done`，其全部 blocker 与 evidence gate 不变。
  - Capture-input gate:satisfied。维护者受控目录
    `~/m0b-capture/2026-07-18/hidumper/` 的四个 stdout/stderr 文件存在且 byte size 分别为
    `34/0/3121/0`；2026-07-19 只读重算 SHA-256 分别为
    `a4904901becfb1a15517c14c51f6fa26524162008578bab3dc64f1c7baa006e5`、
    `e3b0c44298fc1c149afbf4c8996fb92427ae41e4649b934ca495991b7852b855`、
    `351fc59ea33de263a6123c6030624e1a1fcd17ae0eb5dab6d67ffba09ec07a4b`、
    `e3b0c44298fc1c149afbf4c8996fb92427ae41e4649b934ca495991b7852b855`，
    与 M0B capture hash 清单及 repo-safe redacted manifest 一致。manifest 标记
    `controlledHumanCapture`、`selfCheckPassed:true`，四个流均无序列号、key material 或
    用户路径；本复核未运行 capture/collector/真实 `hdc`，不重分类为 compatibility evidence。
  - Environment gate:satisfied。当前锁屏 macOS headless shell 可用 Swift 6.3.3 与
    `xcrun swift-format` 6.3.0；SwiftPM package、M0B 受控输入和 repo-safe manifest 在场。
    实现/验证只允许仓库 fixture、fake/adversarial output 与本地临时目录；真实 HDC、设备、
    非 loopback 网络、GUI/系统授权均 forbidden。
  - Review boundary:本治理 PR 只修改本 change 的 proposal/tasks/verification 与
    acceptance-cases revision metadata；不改 acceptance method/expected result，也不修改
    Swift、Package.swift、`.gitattributes`、fixture、integration profile/lock、M1-006 文件或
    acceptance evidence。实现与 run evidence 必须在后续独立 TASK-UD-001 PR 闭环。
- Objective:依批准的 M0B 观测固定四个 canonical ArkUI Recipe 的 HiDumper argv 包装与
  marker-based result classification，登记人类采集且脱敏/hash-pinned 的 golden inputs，
  并用 fake/adversarial contract tests 钉死 exit-0 trap 与 unknown-output fail-closed 边界。
- Requirements/AC:`INT-UD-WRAPPER-001`、`INT-UD-GOLDEN-001`(见
  acceptance-cases.yaml)
- Depends on:
  - `TASK-RLC-001` done + CHG-2026-014 verified（只证明固定 package bytes/interfaces 已
    合入且原会话排他占用解除，不提供 M1-006 AC evidence）；
  - M0B 事实 `EVD-M0B-DAYU200-20260718-001` 及其受控 HiDumper capture（已满足）；
  - 本 r2 dependency/readiness revision 经维护者合入。
  - `TASK-M1-006` completion 明确不是本任务依赖；其 implementation disposition 仅为只读
    provenance，不得消费其未关闭 evidence。
- Allowed paths:
  - `.gitattributes`（仅新增 HiDumper golden binary/byte-exact pattern；fixture 提交前固定）
  - `Packages/ArkDeckKit/Package.swift`（仅为 ArkDeckContractTests 登记 HiDumper Golden
    `.copy` resource tree，不改变 product/dependency）
  - `Packages/ArkDeckKit/Sources/ArkDeckOpenHarmony/HiDumperWrapper.swift`
  - `Packages/ArkDeckKit/Tests/ArkDeckContractTests/HiDumperWrapperContractTests.swift`
  - `Packages/ArkDeckKit/Tests/ArkDeckContractTests/HiDumperGoldenResourceContractTests.swift`
  - `Packages/ArkDeckKit/Tests/ArkDeckContractTests/Fixtures/HiDumper/Golden/1.0.0/**`
  - `openspec/integrations/openharmony/profile.md`
  - `openspec/integrations/INTEGRATION-PROFILES.lock.yaml`
  - `openspec/changes/chg-2026-008-ui-dump-hidumper-wrapper/evidence/**`
  - `openspec/changes/chg-2026-008-ui-dump-hidumper-wrapper/tasks.md`（仅 TASK-UD-001 状态与
    completion evidence）
- Read-only inputs:
  - `openspec/specs/ui-dump/spec.md`
  - `openspec/contracts/catalogs/dump-recipes.yaml`
  - `openspec/changes/chg-2026-006-dayu200-m0b-bringup/evidence/runs/TASK-M0B-001/**`
  - `openspec/changes/chg-2026-014-remote-lock-legacy-consolidation/**`
  - `~/m0b-capture/2026-07-18/hidumper/**`（只允许读取/重算 hash；不得原地修改）
- Forbidden paths:
  - `openspec/constitution.md`、`openspec/specs/**`、`openspec/contracts/**`、
    `openspec/baselines/**`、`openspec/platforms/**`、hardware matrix
  - TASK-M1-006 源码/任务/evidence 与其他 change/task evidence
  - 上述 Allowed paths 以外的 App/Package source、tests、fixtures 或 integration inputs
  - 已安装真实 `hdc`、真实设备、capture/collector、非 loopback 网络、GUI/系统授权、
    device mutation/destructive dispatch
- Risk:medium（把既有人类受控 capture 登记为版本化 fixture，并固定新的 argv/marker
  语义；必须逐 byte 保真、隐私自检通过，并以 fake 对抗测试覆盖 exit-0 陷阱）
- Hardware required:no new capture；golden provenance 来自已完成的人类受控只读 capture；
  代码、资源登记与测试均 headless，无设备。
- Required environment:锁屏 macOS headless shell；Swift 6.3.3、`xcrun swift-format` 6.3.0、
  SwiftPM；仓库 fake/adversarial fixture 与受控 M0B 输入。不得需要网络下载、GUI、真实 HDC、
  真实设备或新的系统授权。
- Deliverables:
  - 四个 Recipe 的 fixed typed argv composition；window/component ID 只作为已验证 token
    插入，不接受 shell/free-form text；
  - 只依声明 output markers 的 success/failure/unknownOutput classification；exit code 0
    不能单独成功，`option ... missed` 明确失败，缺 marker fail closed；
  - byte-exact HiDumper golden pack、registry/hash/provenance、`.gitattributes` 与
    Bundle.module resource contract；受控 raw 不原地修改，仓库只接收经 self-check 的流；
  - OpenHarmony profile 与 Integration lock 版本化、一致登记；未登记 family 保持
    unknown/unsupported；
  - fake/adversarial tests 与 `evidence/runs/TASK-UD-001/run.md`，记录 base revision、
    输入/输出 hash、命令、二值 AC、偏差/风险及真实 HDC/device dispatch count `0`。
- Verification:
  - `TEST-INT-UD-WRAPPER-001`：四 Recipe argv exact equality；exit-0 success/failure trap、
    marker absence、错误样输出、无 shell composition 的 fake/adversarial branches 全覆盖；
  - `TEST-INT-UD-GOLDEN-001`：受控输入与 fixture 逐 byte/hash 相等，registry/profile/lock/
    Bundle.module resource path 与 hash 一致，privacy self-check 保持通过；
  - Commands:`xcrun swift-format lint` 变更 Swift 文件；
    `swift test --package-path Packages/ArkDeckKit --filter HiDumperWrapperContractTests`；
    `swift test --package-path Packages/ArkDeckKit --filter HiDumperGoldenResourceContractTests`；
    `swift test --package-path Packages/ArkDeckKit`；`scripts/check-sdd.sh`；
    `git diff --check`；fixture SHA-256 与禁止 dispatch 静态审计；
  - 两个 change-local Test ID 均有同一 implementation revision 的可复查 PASS evidence
    才能起草 `done`；不构成 M1-006、HDC compatibility、platform conformance、hardware、
    support 或 release claim。
