# Tasks — CHG-2026-008 ui-dump HiDumper wrapper integration

> V2 治理:本文件是任务的唯一事实源;任务状态变更仅在维护者 review/merge 后
> 生效。全部真机采集由人类维护者执行,Agent 不执行真实 `hdc`。

## TASK-UD-001 — 固定 HiDumper 调用包装 + golden 登记 + 对抗测试

- Status:blocked（r3 review-remediation candidate；仅在本治理 PR 由维护者 review/merge 后
  生效。本 PR 不执行 TASK-UD-001，不产生 implementation/acceptance evidence，也不使
  CHG-008 verified）
- Blocking review（2026-07-19；只读审计，零真实 HDC/device dispatch）：
  - Capture/decision blocker：
    `EVD-M0B-DAYU200-20260718-001` 的 redacted manifest 只含 `hidumper --help` 与
    `hidumper -ls`。所谓四个文件是两条命令的 stdout/stderr，不是四个 Recipe；现有 evidence
    不能固定 `-s WindowManagerService -a` 的 token/单参数边界，也没有 Recipe success output
    family。公开示例不能替代目标 build capture。执行者不得自行选择 argv、marker、fingerprint
    或结构锚点，再用自造 fake/golden 自证通过。
  - Consumer-dependency blocker：r2 未按 CHG-2026-014 提供逐 deliverable dependency 表。
    本 r3 在下表完成审查，但由于 capture/decision 与 environment 尚未满足，每一项结论仍是
    `remains blocked`；后续 readiness revision 必须重新确认表内结论。
  - Core-trace blocker：`REQ-DUMP-003` / `AC-DUMP-003-01` / `TEST-AC-DUMP-003-01` 必须由
    TASK-UD-001 自身闭环。缺失、空值、非法格式及参数/shell injection 形状的 component ID
    必须在 argv/`ProcessRequest` materialization 前失败，request 与 dispatch counter 均为 `0`。
  - SDD-environment blocker：`scripts/check-sdd.sh` 会回落到 `python3`，当前默认解释器没有
    PyYAML。后续 readiness revision 必须登记一个已经存在、无需联网安装且通过
    `import yaml` / `yaml.__version__ == "6.0.3"` preflight 的精确解释器路径，并通过
    `ARKDECK_PYTHON` 使用它；在此之前任务不得执行。
  - Draft disposition：PR #126 的 argv/marker/fixture 与 PASS evidence 建立在未批准的假设上，
    不属于本 task acceptance evidence，只作为不可合并 draft 审计记录保留。

### CHG-2026-014 consumer dependency review

| Consumer deliverable | 使用的 consolidated interface | 是否需要 source AC | 结论 |
| --- | --- | --- | --- |
| typed Recipe、window/component token validator 与 argv materializer | 纯 ArkDeckOpenHarmony typed value；不调用 M1-006 probe/lifecycle/authorization | no | remains blocked：目标 build argv 边界未固定 |
| success/failure/unknown semantic evaluator | `ArkDeckProcess.ProcessOutputChunk`、`ProcessExecutionResult`、`ProcessSemanticEvaluating`、`ProcessSemanticResult` | no | remains blocked：四 Recipe output family/marker 未登记 |
| Process/HDC preflight-to-request seam 与零 launch 证明 | `ArkDeckProcess.ProcessRequest` recording factory/dispatch counter；明确不使用 `HDCProduction`、`HDCProcessCommandRunner` 或真实 child | no | remains blocked：Core negative matrix 尚未在获批实现 revision 二值执行 |
| byte-exact golden fixture 与 SwiftPM resource contract | `Bundle.module` resource seam；不消费 M1-006 source behavior/evidence | no | remains blocked：没有四 Recipe human capture 可登记 |
| OpenHarmony profile / Integration lock 登记 | integration registry/schema；不消费 M1-006 source AC | no | remains blocked：argv 与 output family decision 尚不存在 |

所有 `no` 仅表示该 deliverable 不需要 M1-006 source AC，不等于当前可执行。TASK-UD-001
不绑定生产 HDC dispatch，不触发 device mutation，不产生 compatibility/conformance/hardware/
support/release claim；其 own verification 在 authoritative Recipe inputs 与固定 SDD 解释器缺失时
不能二值执行，所以依 CHG-2026-014 保持 `blocked`。`TASK-M1-006` 也保持 `blocked`/非 `done`。

### Requirement → AC → Test trace

| Requirement/source | Acceptance | Canonical Test ID / method | TASK-UD-001 closure |
| --- | --- | --- | --- |
| `REQ-DUMP-003` | `AC-DUMP-003-01` | `TEST-AC-DUMP-003-01` / `recipeSchemaContract` | 缺失、空、非法、注入型 component ID；零 argv/request/dispatch |
| CHG-008 wrapper integration | `INT-UD-WRAPPER-001` | `TEST-INT-UD-WRAPPER-001` / adversarial contract | 获批 argv exact equality；仅登记 family 可成功；exit-0/unknown fail closed |
| CHG-008 golden registration | `INT-UD-GOLDEN-001` | `TEST-INT-UD-GOLDEN-001` / golden registration | human capture provenance、byte/hash、privacy、profile/lock/resource 一致 |

- Objective:仅在 approved target-build Recipe capture 与后续 decision/readiness revision 固定
  精确 argv/output family 后，实现四个 canonical ArkUI Recipe wrapper、Core component ID
  preflight、golden 登记与 fake/adversarial contract tests。
- Requirements/AC:`REQ-DUMP-003` / `AC-DUMP-003-01`，以及 change-local
  `INT-UD-WRAPPER-001`、`INT-UD-GOLDEN-001`。
- Unblock prerequisites（全部满足后另起 governance revision，不能由实现 PR 顺带改写）：
  - 人类维护者在声明的 DAYU200 build/toolchain/target 上实际执行四个 canonical Recipe；每条
    capture 必须记录 host HDC argv array、remote `hidumper` argv array，并能逐元素证明 `-a`
    payload 是否为单个参数；保存 stdout/stderr 原始 bytes、exit/timeout、输入 ID 的脱敏映射、
    toolchain hash、build/device identity、时间/操作者、privacy self-check 与 SHA-256；
  - 每个拟支持 Recipe 至少有一份真实成功输出；若目标 build 无法成功，平台结论必须如实为
    blocked/nonConformant，不得由 fake 补齐。后续 approved decision revision 逐 Recipe 固定精确
    argv 以及 success/failure/unknown family（文本 marker、结构锚点或 byte fingerprint 采用哪种
    必须显式声明），并说明 precedence/chunk boundary；
  - `TASK-RLC-001 done` + CHG-2026-014 verified 继续只作为 package bytes/interfaces provenance；
    不提供 M1-006 source AC，且上表经后续 revision 复核仍无 `yes`；
  - 精确 SDD Python executable 已存在并通过 PyYAML `6.0.3` preflight，无需联网下载；r3 与
    后续 readiness revision 均经维护者 review/merge。
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
- Hardware required:yes, but only as a human-produced readiness input；需要新的四 Recipe
  target-build read-only capture，Agent 不执行。capture/decision 合入后的实现与 contract
  verification 必须 headless、无设备。
- Required environment:锁屏 macOS headless shell；Swift 6.3.3、`xcrun swift-format` 6.3.0、
  SwiftPM；已存在且由后续 readiness revision 记录精确路径的 Python + PyYAML `6.0.3`。
  执行前必须先运行 `<recorded-python> -c 'import yaml; assert yaml.__version__ == "6.0.3"'`，
  再以 `env ARKDECK_PYTHON=<recorded-python> scripts/check-sdd.sh` 调用 mandatory SDD guard。
  任一 preflight 失败即 blocked；不得联网下载、启动 GUI/真实 HDC/真实设备或取得新系统授权。
- Deliverables:
  - 四个 Recipe 的 approved fixed typed argv composition；window/component ID 只作为已验证
    token 插入，不接受 shell/free-form text；componentDetail 的缺失/空/非法/注入输入在产生
    argv/`ProcessRequest` 前失败，recording request/dispatch count 均为 `0`；
  - 只依 approved decision revision 登记的 output family 做 success/failure/unknownOutput
    classification；exit code 0 不能单独成功，`option ... missed` 明确失败，未登记/marker 缺失
    fail closed；实现者不得新增自己的 success marker；
  - byte-exact HiDumper golden pack、registry/hash/provenance、`.gitattributes` 与
    Bundle.module resource contract；受控 raw 不原地修改，仓库只接收经 self-check 的流；
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
  - `TEST-INT-UD-GOLDEN-001`：受控输入与 fixture 逐 byte/hash 相等，registry/profile/lock/
    Bundle.module resource path 与 hash 一致，privacy self-check 保持通过；
  - Commands:`xcrun swift-format lint` 变更 Swift 文件；
    `swift test --package-path Packages/ArkDeckKit --filter HiDumperWrapperContractTests`；
    `swift test --package-path Packages/ArkDeckKit --filter HiDumperGoldenResourceContractTests`；
    `swift test --package-path Packages/ArkDeckKit`；PyYAML preflight；
    `env ARKDECK_PYTHON=<recorded-python> scripts/check-sdd.sh`；
    `git diff --check`；fixture SHA-256 与禁止 dispatch 静态审计；
  - Core Test ID 与两个 change-local Test ID 均有同一 implementation revision 的可复查
    PASS evidence
    才能起草 `done`；不构成 M1-006、HDC compatibility、platform conformance、hardware、
    support 或 release claim。
