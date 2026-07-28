# CHG-2026-024 Tasks

## TASK-I24-001 — register the parameterized device-observation snapshot family

- Status:ready（r2 corrective readiness；仅在维护者对本独立 readiness PR
  exact head review/merge 后生效。r1 的实现契约在实现预检中撞上一处**跨契约
  冲突**并按任务条款停手（见 Readiness（r2）Collision record）；r2 只做**最小
  scope 更正** = 多授权一个既有契约测试文件，其余条款原文有效、r1 实现成果
  可复用。只授权一个实现交付：按下方契约注册
  device-observation family（新 registry + profile/lock/macOS mapping + 受控
  provenance receipt + fake/adversarial 向量 + 契约测试 + evidence run），载体
  = 常规会话 agent/* PR。不授权：任何 `Packages/ArkDeckKit/Sources/**`、
  `Package.swift`、App/xcodeproj、Core/specs/contracts/baselines 变更；对既有
  `readonly-probes.yaml` 与 `Probes/1.0.0/**` 的任何**数据**字节改动；
  `HDCProbeRegistryContractTests.swift` 中除枚举作用域外的任何改动；新的设备/
  HDC 采集；CHG-2026-022 消费侧接线；`Decision-Grade` 代写。）
- Historical Status:blocked（change approval #273 已满足；r2 capture plan
  #275 已合；此后 authoritative capture 与 readiness 未完成。两项现已闭合，
  见下方 Unblock 逐条核验。）
- Readiness（r2；audit base = protected `main`
  `88465abd`… 即 r1 #662 合入后的 head；r1 全部 pin 于此 base 复核零漂移，
  下方 r1 段除被本段显式取代者外原文有效）：
  - **Collision record（实现预检实测，2026-07-27）。**按 r1 契约实现后，
    既有 `HDCProbeRegistryContractTests.testPackContainsExactPinnedResourceSet`
    `AndHashes` 变红。根因不是新 pack 有错，而是该测试**递归枚举整个
    `Fixtures/HDC/Probes/` 根**并断言其等于 1.0.0 清单的精确文件集
    （`HDCProbeRegistryContractTests.swift:373`）：它把「我这一包是精确的」
    写成了「`Probes/` 下不得存在第二包」。r1 把新 fixture 钉在
    `Probes/DeviceObservation/1.0.0/**`（design §2 亦如此指定），因此必然
    冲突，而该测试文件**不在 r1 的 allowed paths 内** → 按任务 Unblock 条款
    「如需任何超出 exact list 的文件，先修订 scope，不能静默扩展」停手，
    零推送、零绕过。
    **因果隔离已实测**：在 `/private/tmp` worktree 内该测试与 Golden 测试
    双双变红，但移走新 pack 后仍红——`/private/tmp` 的已知路径改写会掩盖
    信号；改在 `~/i24-verify`（非 `/private/tmp`）复测得出真相:
    **Golden 测试通过**（纯环境性），**ProbeRegistry 一条真红**且失败集合逐项
    列出 `DeviceObservation/1.0.0/**`。**教训:凡在 `/private/tmp` worktree
    判定契约测试红绿，必须换到非 `/private/tmp` 路径复测后才可下结论。**
  - **r2 的最小更正（唯一变化）。**allowed paths 增加
    `Packages/ArkDeckKit/Tests/ArkDeckContractTests/HDCProbeRegistryContractTests.swift`，
    且**只授权一处语义收窄**：把该测试的枚举作用域从「`Probes/` 全树」限定为
    「其自身的 `1.0.0/` 子树」，使其继续对自己那一包保持精确断言，同时不再对
    兄弟包主张权威。**不授权**该文件的任何其他改动（其余断言、hash pin、
    fail-closed 向量、隐私断言逐字不动），亦不授权放宽任何既有精确性。
  - **为何不换位置。**把新 pack 移出 `Probes/`（如 `Fixtures/HDC/
    DeviceObservation/`）需要在 `Package.swift` 增 `.copy(...)` 声明，而
    `Package.swift` 同样不在授权内且属更重的共享面；相较之下，收窄一处
    过宽断言是更小、更正确的改动。已实测确认 `Package.swift` 现有
    `.copy("Fixtures/HDC/Probes")` 会自动纳入新子目录，故保持 r1 的位置。
  - **验收增补（二值）。**实现后：`HDCProbeRegistryContractTests` 全部用例
    在**非 `/private/tmp`** 检出中绿；该文件 diff 仅含枚举作用域一处；
    `Probes/1.0.0/**` 与 `readonly-probes.yaml` 的 invariant blob pin 仍逐字节
    相等（r1 已钉，未变）。
  - **r1 其余条款全部保留**：版本候选（profile 0.5.0 / lock 0.6.0）、
    (D-2) 命名义务、三态语义、LF/CRLF 文法与 `[Empty]\r` 负向测试、
    fixtures 必须合成、DEV-1 受理裁定、privacy gate、Swift 基线
    400/1skip/0 与其 provenance 注、grade 注记，均原文有效。
- Readiness（r1；audit base = protected `main`
  `6e45a224cc7d5a758fe2f5661effe3c2ae726baf`）：
  - **Approval boundary:pending human merge。**本 carrier 只修改本文件的本任务
    段。只有 `lvye` 对 exact head APPROVED、required checks terminal success、
    `mergedBy=lvye`、`auto_merge=null` 的 merge OID 进入 protected main 后，
    本 readiness 才生效。
  - **Unblock prerequisites 六项逐条核验（对 audit base 实测）：**
    1. approval-only #273 已合 → **satisfied**；
    2. r2 capture plan #275 已合，其后 r3 #624 / r4 #651 / r5 #657 / r6 #659
       亦已合 → **satisfied**；
    3. 受控 capture 覆盖 zero/one/many/stable/appeared/disappeared：session #1
       （#656 merge `af6d64d67af98c94e1f03581de6f52ecdb8a6bb2`，S0+C0–C5）与
       V0 virgin-server 观察（#658 merge
       `6df25c25d0088238ce2700db07c4db6fbd92cc34`）已合，raw 全留仓外
       → **satisfied**（zero 一格的形态由 r6 重定义，见下）；
    4. 稳定 server 括号、精确 endpoint、exit/stdout/stderr 哈希与长度、
       effect counters 全 0 → **satisfied，但含一项待裁决偏差**（见下条）；
    5. 独立 readiness 钉全量 pin → **本 PR**；
    6. 既有 readonly registry/resource pin 保持 byte-identical → 见 Source
       pins 的 invariant 段。
  - **DEV-1 受理决定（open；本 PR merge 即裁定为「接受」）。**#656 evidence 的
    DEV-1 如实记录：r2/r4 要求**逐调用**前后括号，本窗口实际留存 **4 次**
    括号（19:51 / 20:19 / 20:21 / 20:29 本地）而非 8×2，evidence 明写
    「本记录不自行判定为满足」。本 readiness 提出接受，理由：括号防的是
    「采集期间 server 被替换而不自知」，而 PID `22677`、启动时刻、executable
    与 normalized endpoint 在跨越全窗口的四个观测点逐项一致——server 若被替换
    必然改变 PID 或启动时刻，四点一致已封死该威胁面；逐调用括号是更强形式，
    非该威胁的必要条件。**维护者 merge 本 PR = 接受 DEV-1 不降低
    `I24-HDC-DEVICE-PROVENANCE-001` 的受理等级**；若不接受，请勿 merge 并
    改为要求一次带完整逐调用括号的重采（实现相应推迟）。
  - **Version-candidate drift:corrected（audit base 实测）。**design §2 写
    「Candidate profile `OPENHARMONY-TOOLS@0.4.0`」「Candidate lock
    `INTEGRATION-PROFILES-0.5.0`」「existing … 0.3.0 adoption boundary」——三项
    **均已被消耗**：`INTEGRATION-PROFILES.lock.yaml` 现为
    `lock: INTEGRATION-PROFILES-0.5.0`、`OPENHARMONY-TOOLS` 现为 `0.4.0`
    （`updated_at: 2026-07-22`，由 CHG-2026-021 trace-probes 注册占用）。
    design 的措辞是 **Candidate**（暂定），故本 readiness 按其**意图**（取下一个
    未占用版本）改钉：**profile → `OPENHARMONY-TOOLS@0.5.0`**、
    **lock → `INTEGRATION-PROFILES-0.6.0`**；新 registry
    `OPENHARMONY-HDC-DEVICE-OBSERVATION-PROBES@1.0.0` 不受影响。**实现以本
    readiness 的版本为准，design §2 的候选数字不再有效**；design 正文更正不在
    本任务 allowed paths 内，留独立治理 PR（非阻塞）。
  - **Source pins:closed（audit base 实测 blob）。**
    - 只读输入（实现须逐项复核未漂移）：`integrations/openharmony/profile.md`
      `bba3bd5db722f73f71fff0de96623c6d1222e6f5`；
      `integrations/INTEGRATION-PROFILES.lock.yaml`
      `8a19f1aac86507e7988f494b31bf99ea9bc87aab`；
      `platforms/macos/profile.md`
      `d27264ab1ee1d0665062016a6d7e301f9ce924bd`（三者为**待改**文件，pin 为
      改前基线）。
    - **Invariant pins（实现前后必须逐字节相等，前置 6）**：
      `integrations/openharmony/readonly-probes.yaml`
      `99e8cc3d9929f9502a3e978a53cd56ad285d2aad`；
      `Packages/ArkDeckKit/Tests/ArkDeckContractTests/Fixtures/HDC/Probes/1.0.0/registry.yaml`
      **同 blob** `99e8cc3d…`（正本↔副本字节一致守卫，先例 #305）；
      同目录 `resources.json`
      `5796449dee4a7166746d9b0d7245d26bd2b21aae`。
    - **Absence pins（实现前必须不存在）**：
      `integrations/openharmony/device-observation-probes.yaml`、
      `Packages/ArkDeckKit/Tests/ArkDeckContractTests/HDCDeviceObservationRegistryContractTests.swift`、
      `Fixtures/HDC/Probes/DeviceObservation/`（audit base 实测三者均 absent）。
  - **Implementation contract:binary。**
    ① **新 registry** `openspec/integrations/openharmony/device-observation-probes.yaml`，
    `registryId: OPENHARMONY-HDC-DEVICE-OBSERVATION-PROBES`、
    `registryVersion: 1.0.0`、`integrationProfile: OPENHARMONY-TOOLS@0.5.0`、
    `registeredBy: CHG-2026-024-hdc-device-snapshot-registration/TASK-I24-001`；
    结构沿用 `readonly-probes.yaml` 的字段集（`schemaVersion`/
    `serializationFormat`/`unknownFamilyDisposition`/`toolContext`/`entries`）。
    `toolContext` 必须为 `{platform: macos, reportedVersion: "3.2.0f",
    executableSHA256: "05b2bf7ad30201c082da336db28f8856952a2b2f49ac3404b96fdb4bf1a68f83"}`。
    ② **(D-2) 命名义务**：family 条目 id **必须显式携带 `3.2.0f`**（同胞
    registry 的条目 id 内嵌 `3.2.0d`，两者不得混编）；registry 与 lock 亦须
    可辨识该工具版本。
    ③ **三态语义（r6 正文）**：`observedEmpty` = **零 `Connected` 行**，由两种
    已登记成功形态满足——`[Empty]` marker 行（virgin server）与 N 行全
    `Offline`；marker **充分不必要**，只认 marker 的实现必须在 EMPTY-001
    matrix 上失败。设备离场**不删行**，presence 由 state 字段判定，禁止以行的
    出现/消失作判据。
    ④ **grammar（实测导出，不得自行发明）**：设备行 = 制表分隔 **5 列** =
    `key` / `name`（可空）/ `transport`（`USB`）/ `state`
    （`Connected`|`Offline`）/ `hostTag`（`localhost`），**LF** 终止，
    `Offline` 行 56 B、`Connected` 行 58 B（key 32 字符时）；empty marker =
    `[Empty]`，**CRLF** 终止、9 B、**0 个制表字段**。解析器必须**同时接受
    LF 与 CRLF**，任何字段**不得残留 `CR`**，并须有一条
    `[Empty]\r` 不得被读作非空/unknown 的**负向测试**。
    ⑤ **profile/lock/mapping**：`integrations/openharmony/profile.md` 增记本
    family 与其观测来源（须写明「观测自 hdc `3.2.0f`，与 readonly-probes/
    trace-probes 登记的 `3.2.0d` 非同一工具」）；
    `INTEGRATION-PROFILES.lock.yaml` 升为 `INTEGRATION-PROFILES-0.6.0`、
    `OPENHARMONY-TOOLS` 升 `0.5.0` 并登记新 registry 与新 fixture pack；
    `platforms/macos/profile.md` 只加本 family 的 mapping/version adoption，
    **不改 Core/platform conformance**。
    ⑥ **fixtures 只可为合成向量**：`Fixtures/HDC/Probes/DeviceObservation/1.0.0/**`
    内的 stdout 向量必须为**人造**字节（结构同构、key 为显然的非真实占位），
    覆盖 empty-marker / one / many / all-offline / mixed / 重复 key /
    未知 state 字面量 / 列数错误 / 残留 `CR` / stderr 非空 / 非零 exit /
    截断 / 编码非法；**禁止**把任何一次真实采集的字节入仓（capture manifest
    的 boundary 明文：`no capture is registered as a repository golden fixture
    by this change`）。受控 provenance 只以**哈希/计数/结构字面量**形式登记。
    ⑦ **provenance 登记**：registry 每条 entry 的 `provenance` 指向
    `evidence/runs/TASK-I24-001/run.md`（session #1 与 V0 两节）并附其
    merge OID（`af6d64d6…` / `6df25c25…`），`acceptedBy` 记维护者 review/merge。
    ⑧ **契约测试** `HDCDeviceObservationRegistryContractTests.swift` 覆盖
    deliverables 矩阵：zero（两形态）/one/many、行序与重复、empty-vs-unknown、
    identity/endpoint drift、unsupported literal、stderr/非零/截断、
    timeout/cancellation、隐私（无原始标识符外泄）、**旧 registry 字节等同**、
    以及 ④ 的 CRLF 负向测试。
    ⑨ **测试基线**：audit base 上 Swift 全量 = **400 tests / 1 skipped /
    0 failures**（0 unexpected；2026-07-27 实测，见下 provenance 注）；实现后
    = 400 + 新增数 / 1 skipped / **0 failures**。`check-sdd` 保持
    **0 error / 0 warning / 111 acceptance IDs**（本 change 的 AC 为
    change-local，不进 canonical 计数）。
    ⑩ **diff 恰在 Allowed paths 内**，且 invariant pins 前后 blob 相等。
  - **Swift 基线 provenance 注（如实记录）**：该 400/1skip/0 于 2026-07-27
    在主工作副本实测，而彼时主副本被另一会话切至分支
    `agent/chg-2026-025-ain-004-readiness-r3`（`1dd20b90…`）。已机器核验该分支
    相对 audit base **仅改三个 chg-2026-025 的 openspec 文件**
    （`git diff --name-only` 全量列出），`Packages`/`ArkDeckApp`/
    `ArkDeck.xcodeproj` 差异为 **0**，故 Swift 构建输入与 audit base 逐字节
    相同、基线可迁移。实现开工时应在自己的干净 worktree 复测并记录。
  - **Privacy gate:closed。**原始 connect key/序列号一律不入仓；registry、
    fixture、evidence 只含哈希、计数、结构字面量与**长度**。展示形态按 design
    §4 的 per-session HMAC-SHA-256 假名（`redacted-device-<24 hex>`），
    跨会话相关性不承诺。
  - **Concurrency/absence:closed at drafting（2026-07-27）。**remote
    `agent/*i24*` 分支 = 0（推送前实测）。**注意共享工作副本**：主 checkout
    当前由另一会话占用于 `agent/chg-2026-025-ain-004-readiness-r3`，实现必须
    在独立 worktree 内进行，且 commit 前核对 `git branch --show-current`。
  - **Grade 注记**：本任务现携 `- Decision-Grade:D2。`（播种时其形态含设备
    窗口）。采集已完成，剩余实现为 **host-only**；是否重定级由维护者亲笔决定
    （#577 载体先例），本 readiness 不代写、亦不依赖其变更——实现载体为常规
    会话 PR，不经循环认领。
- Platform:macos
- Requirements/AC:change-local `I24-HDC-DEVICE-SNAPSHOT-001`/
  `I24-HDC-DEVICE-EMPTY-001`/`I24-HDC-DEVICE-PROVENANCE-001`/
  `I24-HDC-DEVICE-REGISTRY-001`/`I24-HDC-DEVICE-NODISPATCH-001`
- Depends on:CHG-2026-022 r2 merged（已满足）；本 change approval（PR #273，已满足）；
  r2 capture plan（#275，已满足）；受控 capture/provenance（#656 + #658，已满足）；
  独立 readiness（本 r1）
- Allowed paths after readiness:
  - `openspec/integrations/openharmony/profile.md`
  - `openspec/integrations/openharmony/device-observation-probes.yaml`
  - `openspec/integrations/INTEGRATION-PROFILES.lock.yaml`
  - `openspec/platforms/macos/profile.md`（仅新增本 family mapping/version adoption；
    不改变 Core/platform conformance）
  - `Packages/ArkDeckKit/Tests/ArkDeckContractTests/Fixtures/HDC/Probes/DeviceObservation/1.0.0/**`
  - `Packages/ArkDeckKit/Tests/ArkDeckContractTests/HDCDeviceObservationRegistryContractTests.swift`
  - `Packages/ArkDeckKit/Tests/ArkDeckContractTests/HDCProbeRegistryContractTests.swift`
    （r2 新增；**仅**授权把其 packaged-file 枚举作用域收窄到自身 `1.0.0/`
    子树，其余逐字不动）
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
- Decision-Grade:D2。
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
