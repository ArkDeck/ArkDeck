# ArkDeck Agent Contract

本文件是所有 AI Agent、自动化工具和人工贡献者进入 ArkDeck 仓库后的第一读取入口。

## 必读顺序

1. `openspec/constitution.md`
2. `openspec/project.md`
3. `openspec/governance/enforcement.md` 与 `openspec/verification/policy.md`
4. `openspec/config.yaml` 指定的 current Core baseline lock 与 file manifest
5. 当前任务引用的 `openspec/specs/**/spec.md`
6. accepted `openspec/integrations/INTEGRATION-PROFILES.lock.yaml` 与当前任务固定的 integration profile/catalog/fixture
7. `openspec/platforms/PLATFORM-PROFILES.lock.yaml` 与当前平台 profile
8. 当前任务固定且已接受的 Core conformance manifest
9. 已批准 change 的 proposal/delta/design/verification、`ready-review.md`、approval attestation 和 immutable Task packet

`docs/PLAN.md` 是 SDD 迁移输入和历史设计记录，不再是实现规则的事实源。发生冲突时不得用 `PLAN.md` 覆盖 living specs。

## 权威顺序

1. Constitution
2. Task 固定的 Core baseline 与 contracts
3. 该 baseline 的 current specs，叠加当前 Task 明确固定、经人类批准的 scoped delta
4. 与有效规格兼容且固定 hash 的 integration profile、platform profile 与 conformance manifest
5. 已批准 change 的 design/verification plan
6. Task packet
7. 代码和代码注释

Approved delta 只替换其中明确列出的 Requirement/AC；未涉及内容继续服从 pinned baseline。Core/Safety delta 必须具有有效人类批准记录。低层文件不得覆盖或放宽高层规则。发现冲突时停止受影响工作并创建 change proposal，不得自行选择更方便的解释。

## Agent 禁令

- 不得为让实现或测试通过而直接修改 accepted Core requirement、Safety invariant、Acceptance Scenario、release gate 或 baseline lock。
- 不得把平台限制写成 Core 豁免；平台不能满足 Core 时标记 `blocked`、`nonConformant` 或缩减该平台发布范围。
- 不得把模拟、fake、plan-only 结果记为真实设备或硬件验收。
- `standardAgent`/普通 CI Task 不得对真实设备执行 Flash、erase、format、unlock、真实 update 或其他 destructive Step；只能生成 plan、simulation/fake evidence 和人工 handoff。真实 destructive evidence 需要独立 `controlledHardwareLab` Task 与仓库外人类授权。
- 不得在设备身份、外部副作用结果或 destructive step 状态不确定时猜测继续。
- 不得使用 host shell 字符串拼接外部命令。
- 不得自行把 change 从 `proposed` 改为 `approved`，也不得自行接受 Core baseline 变更；这些动作需要明确的人类批准记录。
- 不得自行发布 archive staging：普通 Agent 不能把不可发布的 `result_revision` 合并到权威分支，也不能在 baseline/archive approval 前让其 specs、baseline 或目录移动生效。
- 在仓库尚未具备受保护 Git review/签名 approval 和自动 guard 前，任何 change/task 都不得进入 `approved`/`ready`；当前只能起草和审查。
- execution gate 打开后，任何 immutable identity 必须进入仓库外 append-only identity ledger；不得通过删除旧 archive/approval/sidecar 或重写 Git 历史复用 Task、claim、run、attestation、Change、approval subject 或 evidence ID。

## Windows / Linux platform port 规则

Windows/Linux 是同一产品和同一 Core baseline 的平台实现，不是新的产品规格；其 current delivery/not started 与 conformance 状态以 Task 固定的 accepted `PLATFORM-PROFILES` lock 为唯一事实源。处于 `not_started_platforms` 或未达到 release gate 的平台不得声称 supported。平台 Agent 只能替换 UI、进程、单实例、电源、文件授权、设备访问诊断、卷标识、日志、信任来源、签名/仓库、安装与平台测试细节。它不得改变：

- HDC server ownership 和 external server 保护规则；
- device binding、USB/TCP/UART 重绑定边界；
- Job 状态机、journal、取消、reconcile 和 recovery 语义；
- typed step、effect 等级、plan-only 和 simulation 隔离；
- Artifact、StorageBudget、隐私、安全提示和验收标准。

Linux 额外不得因缺少统一 OS executable trust verdict 而把工具标为 trusted，也不得自动 sudo/pkexec、写 udev rule 或降低全局 USB/UART 权限；这些只能是受控安装/运维动作。

## 执行规则

- 只领取状态为 `ready` 且未被 claim 的 immutable Task packet；原子 claim 成功后运行态才成为 `in_progress`。
- Task 必须选择一个具体执行平台并固定与之匹配的 Platform Profile，同时固定 Core baseline、approved change revision、accepted Integration lock 下的 profile version/hash、accepted Core conformance suite/hash、真实 base commit、Requirement/AC、允许路径、禁止路径、依赖和验证方式。Shared change 也必须拆为平台明确的执行 Task。
- 所有 Git base/result/source/implementation/repository revision 必须写 canonical full commit OID（当前仓库算法对应 40 或 64 个小写十六进制字符）；branch、tag、`HEAD`、缩写和其他可移动 revspec 不构成 immutable pin。
- 执行前必须通过受保护 claim 服务原子取得 task claim；`claim-owner-attestation.json` 必须绑定 claim 原始 bytes/hash、owner、attempt 和 lease。无法取得可验证 owner attestation 的环境不得执行或并行领取 Task。
- Ready Task packet 在批准后不可改写；V1 packet revision 固定为 1，claim、attempt、owner、运行状态、结果和 evidence 只写独立 append-only claim/run sidecar。范围变化必须让原 Task 产生 owner-attested `superseded` terminal run，明确 `supersededByTaskId`，取得绑定该 run 的 `taskSupersession` 人类批准，并生成同 change/base/platform、保持原 Requirement/AC/path/deliverable 覆盖的新 Ready Task；否则原 Task 仍属于 active scope。
- 开始后不得静默扩展范围。需要改变范围或 AC 时停止并走新 Task ID 的 Ready gate；同一 Task ID 不存在 r2 覆盖语义。
- Approved Change ID 同样不得原地升 r2；若 immutable `scope.yaml`、delta/design/verification plan 必须变化，创建带 `supersedes_change_id` 的新 Change ID 并重新批准。旧 Change 及其 Task/claim/run 不删除、不改写。
- `supersedes_change_id` 不是说明性链接：新 Change 的外部批准是旧 Change 执行授权的终止边界。批准前，受保护治理/claim 服务必须以同一串行化事务确认旧 Change 的全部 claim 已有同 owner 的终态 run；批准后旧 Change 的任何 Ready packet 均不可再领取，执行者也不得继续验证或归档旧 Change。批准 successor 只能形成单链且不得成环。
- Task 的 `runtimeCapabilities` 是运行时白名单；未列出的联网、外部工具、真机、主机安装、提权或仓库外写入一律不授权。工具调用平台仍要求的用户/系统 approval 不能被该字段替代。
- `exclusiveResources` 只能使用 `arkdeck-resource:<kind>:<canonical-id>`；ready Task 的 HDC server、device binding、host volume ID 必须是规范身份的 SHA-256，claim 还必须携带受保护 claim service 对 exact claim 签发的 `resourceIdentitySet` 证明。路径、IP、显示名等别名不得自行绕过冲突。
- `proposal.md` 的 `status: proposed`、`scope.yaml`、design/delta、`verification.md` 的 `Status: planned`、review 与 canonical acceptance registry 是 change-lock 固定且 approved 后不可变的 source input；`tasks.md` 只是 append-only 派生索引，Task packet 各自独立批准。change 的 approved/implementing/verified 状态分别由 change lock、有效 claim、外部批准的 `verification-result.json` 推导，禁止靠编辑 source input 转换状态。
- 每次 attempt 结束时追加唯一 immutable terminal run record，记录命令、结果、文件、证据、偏差、风险和安全恢复点；每个终态（包括 blocked/interrupted/superseded）都必须有受保护 claim 服务签发、绑定 run bytes/hash 且证明与 claim 同一 owner 的 `run-owner-attestation.json`。`modifiedFiles` 必须与 base/result Git diff 精确一致；`done` 还必须取得独立的仓库外人类 result approval。所有 active Task 完成后再生成 exact `verification-result.json`；Agent 不得自报 change verified。
- `controlledHardwareLab` 在任何真实设备 Step dispatch 前还必须取得仓库外人类批准的 `lab-execution-authorization.json`，绑定 exact plan、operator、target/binding、固件、transport、HDC、Provider、有效期和物理目标确认；自报 `humanOperator` 不构成授权。
- Archive staging 只能由受保护 workflow 在 verified + pre-archive proof 后构造；`archive-lock.yaml` 必须在其绑定的 `result_revision` 之后生成。Agent 不得把 staging 构造视为 sync/archive 完成，也不得在 exact baseline/archive approval 前发布它。
- 同一 claim 只允许一个 run，run 必须在 immutable lease 内结束；后一 attempt 只能在前一 attempt 已有终态 run 后 claim。

详细流程见 `openspec/verification/policy.md` 与 `openspec/changes/README.md`。
