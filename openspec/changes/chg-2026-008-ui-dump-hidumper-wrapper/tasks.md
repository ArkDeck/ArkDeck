# Tasks — CHG-2026-008 ui-dump HiDumper wrapper integration

> V2 治理:本文件是任务的唯一事实源;任务状态变更仅在维护者 review/merge 后
> 生效。全部真机采集由人类维护者执行,Agent 不执行真实 `hdc`。

## TASK-UD-CAP-001 — 固定 stdout-only 候选的人工真机采集

- Status:ready（r3 candidate；仅在本治理 PR 由维护者 review/merge 后生效。该 merge 只批准
  runbook/任务包，不执行 harness 或真机步骤）
- Objective:按 `capture-runbook.md` 的封闭 argv 矩阵，先实现/离线验证 argv-native capture
  harness，再由人类维护者对同一 DAYU200 target 执行 `INV-1`、`R1 nodeSummary` 与
  `R3 fullDefaultTree`；忠实记录 target-build raw output，不据此自行定义 success marker。
- Requirements/AC:`INT-UD-CAPTURE-RO-001` / `TEST-INT-UD-CAPTURE-RO-001`。
- Depends on:CHG-008 r3 经维护者合入；`TASK-M0B-001 done` 的物理目标、firmware/toolchain
  provenance。无 TASK-M1-006 source AC 依赖。
- Readiness review（2026-07-19）：
  - exact matrix/output mode 已由 `capture-runbook.md` 固定；`-a` payload 只有 one-element
    candidate，无 split-token/quote fallback；
  - 本任务可执行 allowlist 只有 `INV-1`、`R1`、`R3`。两个 `-default` Recipe 依据固定官方
    source input 登记为 `captureRemoteStdout/readOnly`；`R2`/`R4` 结构性不可达；
  - 物理 target、HDC absolute path/hash/version 已由合入的 M0B evidence 固定；human phase
    每次仍须新鲜 physical confirmation + confirmed binding，mismatch 即停止；
  - raw/derived privacy chain 已固定：raw bytes 全部留在仓库外，repo evidence 只含 hash/
    metadata，golden 后续只能作为 `uidump-derived-redaction-v1` 的 derived output；
  - SDD interpreter 已在当前执行 host 验证：
    `/Users/fuhanfeng/Dropbox/Code/Github/ArkDeck/.venv-sdd/bin/python`，Python `3.14.6`，
    PyYAML `6.0.3`，executable SHA-256
    `b502cb4c5b46b8d4192ec6bcb600ce8922f1afc396fcf646e8765c6eba74a0bf`。任一值漂移须
    在执行前停止并修订，不得联网安装。
- Allowed paths:
  - `scripts/ui_dump_capture/**`（仅 argv-native harness + offline tests；不得包含 `R2`/`R4`）
  - `openspec/changes/chg-2026-008-ui-dump-hidumper-wrapper/evidence/runs/TASK-UD-CAP-001/**`
  - 本 `tasks.md`（仅独立 status/evidence PR 更新本任务）
- Read-only inputs:
  - 本 change `capture-runbook.md`、proposal/verification/acceptance-cases；
  - `openspec/contracts/catalogs/dump-recipes.yaml`、`workflow-step-registry.yaml`；
  - `openspec/specs/ui-dump/spec.md`；
  - `openspec/changes/chg-2026-006-dayu200-m0b-bringup/evidence/runs/TASK-M0B-001/**`。
- Forbidden paths:产品/App/Package source，`openspec/specs/**`、`openspec/contracts/**`、
  baselines、integration/platform profile/lock、其他 task evidence；任何 `R2`/`R4` command
  entry；raw UI bytes/excerpts 入仓。
- Risk:medium（真实设备 readOnly command；unexpected sidecar/state difference 仍可能发生，
  因此一旦观察到即 `outcomeUnknown`、停止余下矩阵并进入 Safety review，不得事后放宽 mode）
- Hardware required:yes；物理 DAYU200/USB，仅 human phase。Agent phase 只允许 offline harness
  implementation/tests，Agent 永不执行 installed HDC 或 real-device step。
- Required environment:
  - Phase A:锁屏 macOS headless、Python stdlib、临时目录、无网络/设备；mandatory SDD guard
    使用上面固定的 PyYAML interpreter；
  - Phase B:人类维护者、固定 HDC binary、物理 target、fresh confirmed binding、repo 外新建
    controlled output directory。不得需要 GUI 自动化、新授权、server lifecycle 或 mutation。
- Deliverables:closed harness + offline tests；human-operated `INV-1/R1/R3` per-stream raw capture；
  repo-safe redacted manifest/hash list；`run.md` 记录 operator/time、physical target、binding、exact
  argv、effect、exit/timeout/hash、binary AC、偏差及 deviceMutation/destructive count `0`。
- PR boundary:
  1. harness implementation PR 只含 `scripts/ui_dump_capture/**`，merge 前不得真机执行；
  2. merge 后由人类执行，evidence/status 使用独立 PR，不修改 harness/runbook/AC。
- Verification:offline test 必须证明 exact arrays、one-element payload、identifier validation、
  no-shell、closed IDs、外部 output/privacy gate 及 `R2/R4` 不可达；human run 三条 command 均逐项
  记录且 raw 未入仓；任一额外 argv、fallback、真实 mutation、敏感 byte 入仓或 Agent device
  dispatch 使 `TEST-INT-UD-CAPTURE-RO-001` FAIL。

## TASK-UD-CAP-MUT-001 — element/lastpage 人工 deviceMutation 采集

- Status:blocked（`R2 elementTree` 与 `R4 componentDetail` dispatch count 必须为 `0`）
- Requirements/AC:`INT-UD-CAPTURE-MUT-001` / `TEST-INT-UD-CAPTURE-MUT-001`。
- Depends on:本 r3 merge；后续独立 readiness revision 关闭下列全部 gate。
- Blocking gates:
  - 固定 dedicated disposable non-sensitive fixture HAP tuple：artifact hash、bundle、ability、
    静态页面内容、window rule，以及 install/start/stop/cleanup 的 typed effect/argv；
  - fresh confirmed binding revision；human `deviceMutation` confirmation 的 scope hash 覆盖
    candidate/fixture/remote path/pre-post inventory/cleanup；
  - 固定一个 exact remote sidecar path 且 pre-inventory 证明不存在；禁止全局 `/data` search、
    wildcard、递归删除或覆盖既有文件；
  - post-inventory 证明 exact new path 属于本 task，stdout/sidecar 分立 raw origin/hash，cleanup
    仅允许 `cleanupOwnedRemotePath` 作用于该 exact path；ownership 不明则保留，cleanup failure
    记录 `needsAttention`；
  - `R4` component ID 只来自同一 run 的受控 `R2` 输出并通过 strict validator；若 UI-state
    mutation 仍可能，须在 `R4` 前取得独立 confirmation scope。
- Future allowed paths（仅在 readiness revision 合入后生效）：
  - `scripts/ui_dump_capture/**`（新增 `R2/R4` mutation allowlist 与 offline fault tests）
  - `openspec/changes/chg-2026-008-ui-dump-hidumper-wrapper/evidence/runs/TASK-UD-CAP-MUT-001/**`
  - 本 `tasks.md`（仅独立 status/evidence PR）
- Forbidden now:任何 implementation、installed HDC、device dispatch、fixture install/start、
  remote inventory/receive/cleanup 或 evidence 起草；不得把 `TASK-UD-CAP-001` 结果推断为本任务
  evidence。
- Hardware required:yes, human only；当前未 ready。
- Deliverables/verification:见 `capture-runbook.md` mutation gate；未来必须用获批 exact matrix
  证明 confirmation、binding、pre/post inventory、separate raw origins、owned cleanup 与 raw/
  derived privacy chain，且 destructive count `0`。未关闭前不得起草 PASS/done。

## TASK-UD-001 — 固定 HiDumper 调用包装 + golden 登记 + 对抗测试

- Status:blocked（r3 review-remediation candidate；仅在本治理 PR 由维护者 review/merge 后
  生效。本 PR 不执行 TASK-UD-001，不产生 implementation/acceptance evidence，也不使
  CHG-008 verified）
- Blocking review（2026-07-19；只读审计，零真实 HDC/device dispatch）：
  - Capture/decision blocker：
    `EVD-M0B-DAYU200-20260718-001` 的 redacted manifest 只含 `hidumper --help` 与
    `hidumper -ls`。所谓四个文件是两条命令的 stdout/stderr，不是四个 Recipe；现有 evidence
    没有 Recipe success output family。r3 `capture-runbook.md` 已在采集前固定 one-element `-a`
    candidate matrix 与 output-mode/effect split；但 `TASK-UD-CAP-001` 尚未执行，mutation task
    仍 blocked，后续 decision revision 也尚未登记任何 target-build success/failure/unknown
    family。执行者不得选择 fallback argv、marker、fingerprint 或结构锚点，再用自造 fake/
    golden 自证通过。
  - Consumer-dependency blocker：r2 未按 CHG-2026-014 提供逐 deliverable dependency 表。
    本 r3 在下表完成审查，但由于 capture/decision 尚未满足，每一项结论仍是
    `remains blocked`；后续 readiness revision 必须重新确认表内结论。
  - Core-trace blocker：`REQ-DUMP-003` / `AC-DUMP-003-01` / `TEST-AC-DUMP-003-01` 必须由
    TASK-UD-001 自身闭环。缺失、空值、非法格式及参数/shell injection 形状的 component ID
    必须在 argv/`ProcessRequest` materialization 前失败，request 与 dispatch counter 均为 `0`。
  - SDD-environment gate:satisfied for the declared host。固定 interpreter、Python/PyYAML
    version 与 executable hash 见 `TASK-UD-CAP-001` readiness review；未来执行前任一漂移仍
    fail closed，不得回落到缺 `yaml` 的默认 `python3` 或联网安装。
  - Draft disposition：PR #126 的 argv/marker/fixture 与 PASS evidence 建立在未批准的假设上，
    不属于本 task acceptance evidence，只作为不可合并 draft 审计记录保留。

### CHG-2026-014 consumer dependency review

| Consumer deliverable | 使用的 consolidated interface | 是否需要 source AC | 结论 |
| --- | --- | --- | --- |
| typed Recipe、window/component token validator 与 argv materializer | 纯 ArkDeckOpenHarmony typed value；不调用 M1-006 probe/lifecycle/authorization | no | remains blocked：candidate matrix 已固定，但 target capture/decision 尚未完成 |
| success/failure/unknown semantic evaluator | `ArkDeckProcess.ProcessOutputChunk`、`ProcessExecutionResult`、`ProcessSemanticEvaluating`、`ProcessSemanticResult` | no | remains blocked：四 Recipe output family/marker 未登记 |
| Process/HDC preflight-to-request seam 与零 launch 证明 | `ArkDeckProcess.ProcessRequest` recording factory/dispatch counter；明确不使用 `HDCProduction`、`HDCProcessCommandRunner` 或真实 child | no | remains blocked：Core negative matrix 尚未在获批实现 revision 二值执行 |
| derived golden fixture 与 SwiftPM resource contract | `Bundle.module` resource seam；不消费 M1-006 source behavior/evidence | no | remains blocked：capture + `uidump-derived-redaction-v1` receipt 尚未闭环 |
| OpenHarmony profile / Integration lock 登记 | integration registry/schema；不消费 M1-006 source AC | no | remains blocked：argv 与 output family decision 尚不存在 |

所有 `no` 仅表示该 deliverable 不需要 M1-006 source AC，不等于当前可执行。TASK-UD-001
不绑定生产 HDC dispatch，不触发 device mutation，不产生 compatibility/conformance/hardware/
support/release claim；其 own verification 在 authoritative Recipe inputs/decision 缺失时不能二值
执行，所以依 CHG-2026-014 保持 `blocked`。SDD interpreter 已固定不解除 capture/decision
blocker；`TASK-M1-006` 也保持 `blocked`/非 `done`。

### Requirement → AC → Test trace

| Requirement/source | Acceptance | Canonical Test ID / method | TASK-UD-001 closure |
| --- | --- | --- | --- |
| `REQ-DUMP-003` | `AC-DUMP-003-01` | `TEST-AC-DUMP-003-01` / `recipeSchemaContract` | 缺失、空、非法、注入型 component ID；零 argv/request/dispatch |
| CHG-008 wrapper integration | `INT-UD-WRAPPER-001` | `TEST-INT-UD-WRAPPER-001` / adversarial contract | 获批 argv exact equality；仅登记 family 可成功；exit-0/unknown fail closed |
| CHG-008 golden registration | `INT-UD-GOLDEN-001` | `TEST-INT-UD-GOLDEN-001` / golden registration | controlled raw hash → deterministic derived receipt；privacy、profile/lock/resource 一致 |

- Objective:仅在 approved target-build Recipe capture 与后续 decision/readiness revision 固定
  精确 argv/output family 后，实现四个 canonical ArkUI Recipe wrapper、Core component ID
  preflight、golden 登记与 fake/adversarial contract tests。
- Requirements/AC:`REQ-DUMP-003` / `AC-DUMP-003-01`，以及 change-local
  `INT-UD-WRAPPER-001`、`INT-UD-GOLDEN-001`。
- Unblock prerequisites（全部满足后另起 governance revision，不能由实现 PR 顺带改写）：
  - `TASK-UD-CAP-001 done` 与 `TASK-UD-CAP-MUT-001 done`：人类维护者只按
    `capture-runbook.md` 的封闭候选矩阵/effect task 执行，逐条记录 host argv array、one-element
    `-a` payload、separate raw origins、exit/timeout/hash、binding/confirmation/inventory/cleanup；
    raw UI bytes 留在受控位置，不进入仓库；
  - 每个拟支持 Recipe 至少有一份真实成功输出；若目标 build 无法成功，平台结论必须如实为
    blocked/nonConformant，不得由 fake 补齐。后续 approved decision revision 逐 Recipe 固定精确
    argv 以及 success/failure/unknown family（文本 marker、结构锚点或 byte fingerprint 采用哪种
    必须显式声明），并说明 precedence/chunk boundary；
  - `TASK-RLC-001 done` + CHG-2026-014 verified 继续只作为 package bytes/interfaces provenance；
    不提供 M1-006 source AC，且上表经后续 revision 复核仍无 `yes`；
  - 固定 SDD Python executable 的 path/version/hash 重新 preflight 通过；r3 与后续 readiness
    revision 均经维护者 review/merge。
  - Agent 不得执行上述真实 `hdc`/device capture，也不得以公开文档、simulation 或 fake
    代替 human target-build evidence。
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
  - 本 change `capture-runbook.md` 与两个 capture task 的已合入 repo-safe evidence
  - `openspec/changes/chg-2026-006-dayu200-m0b-bringup/evidence/runs/TASK-M0B-001/**`
  - `openspec/changes/chg-2026-014-remote-lock-legacy-consolidation/**`
  - 两个 capture task manifest 记录、且由后续 readiness revision 固定的 exact repo-external raw
    paths（只允许读取/重算 hash/执行 approved deterministic transform；不得原地修改）
- Forbidden paths:
  - `openspec/constitution.md`、`openspec/specs/**`、`openspec/contracts/**`、
    `openspec/baselines/**`、`openspec/platforms/**`、hardware matrix
  - TASK-M1-006 源码/任务/evidence 与其他 change/task evidence
  - 上述 Allowed paths 以外的 App/Package source、tests、fixtures 或 integration inputs
  - 已安装真实 `hdc`、真实设备、capture/collector、非 loopback 网络、GUI/系统授权、
    device mutation/destructive dispatch
- Risk:medium（把人类受控 raw 经 deterministic redaction 登记为 derived fixture，并固定新的
  argv/output-family 语义；必须闭环 raw/derived receipt 与隐私审查，并以 fake 对抗测试覆盖
  exit-0 陷阱）
- Hardware required:no for TASK-UD-001；真机输入只来自两个具名 capture tasks 的已合入
  evidence。本实现/contract verification 必须 headless、无设备。
- Required environment:锁屏 macOS headless shell；Swift 6.3.3、`xcrun swift-format` 6.3.0、
  SwiftPM；固定 Python executable
  `/Users/fuhanfeng/Dropbox/Code/Github/ArkDeck/.venv-sdd/bin/python`，Python `3.14.6`、PyYAML
  `6.0.3`、SHA-256 `b502cb4c5b46b8d4192ec6bcb600ce8922f1afc396fcf646e8765c6eba74a0bf`。
  执行前先验证 version/hash 与 `import yaml`，再以该 path 设置 `ARKDECK_PYTHON` 调用 guard。
  任一 preflight 失败即 blocked；不得联网下载、启动 GUI/真实 HDC/真实设备或取得新系统授权。
- Deliverables:
  - 四个 Recipe 的 approved fixed typed argv composition；window/component ID 只作为已验证
    token 插入，不接受 shell/free-form text；componentDetail 的缺失/空/非法/注入输入在产生
    argv/`ProcessRequest` 前失败，recording request/dispatch count 均为 `0`；
  - 只依 approved decision revision 登记的 output family 做 success/failure/unknownOutput
    classification；exit code 0 不能单独成功，`option ... missed` 明确失败，未登记/marker 缺失
    fail closed；实现者不得新增自己的 success marker；
  - byte-exact **derived** HiDumper golden pack、registry/hash/provenance、`.gitattributes` 与
    Bundle.module resource contract；raw 永不入仓，`uidump-derived-redaction-v1` receipt 绑定
    raw hash、algorithm/source/allowlist hash、derived hash、replacement counts 与 human privacy
    review；不得把 derived 标为 raw；
  - OpenHarmony profile 与 Integration lock 版本化、一致登记；未登记 family 保持
    unknown/unsupported；
  - fake/adversarial tests 与 `evidence/runs/TASK-UD-001/run.md`，记录 base revision、
    输入/输出 hash、命令、二值 AC、偏差/风险及真实 HDC/device dispatch count `0`。
- Verification:
  - `TEST-AC-DUMP-003-01`：componentDetail 的 missing、empty、非法字符/格式、leading option、
    whitespace/newline、shell metacharacter 与 argument-injection cases 全部 preflight failure；
    argv/request materialization count `0`，recording dispatch count `0`；合法 token positive control
    只证明能 materialize，不启动真实 HDC；
  - `TEST-INT-UD-WRAPPER-001`：四 Recipe 对 approved decision 的 argv exact equality；每个已登记
    success/failure/unknown family、exit-0 trap、marker absence、chunk boundary、stdout/stderr
    precedence 与无 shell composition 的 fake/adversarial branches 全覆盖；
  - `TEST-INT-UD-GOLDEN-001`：受控 raw hash 与 capture manifest 一致；controlled replay 的
    deterministic transform 产生已登记 derived hash；repo 不含 raw/sensitive literals；receipt、
    registry/profile/lock/Bundle.module resource path/hash 一致；
  - Commands:`xcrun swift-format lint` 变更 Swift 文件；
    `swift test --package-path Packages/ArkDeckKit --filter HiDumperWrapperContractTests`；
    `swift test --package-path Packages/ArkDeckKit --filter HiDumperGoldenResourceContractTests`；
    `swift test --package-path Packages/ArkDeckKit`；固定 interpreter 的 hash/version/PyYAML
    preflight；以固定 path 设置 `ARKDECK_PYTHON` 运行 `scripts/check-sdd.sh`；
    `git diff --check`；fixture SHA-256 与禁止 dispatch 静态审计；
  - Core Test ID 与两个 change-local Test ID 均有同一 implementation revision 的可复查
    PASS evidence
    才能起草 `done`；不构成 M1-006、HDC compatibility、platform conformance、hardware、
    support 或 release claim。
