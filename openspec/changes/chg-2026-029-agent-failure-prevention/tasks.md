# CHG-2026-029 Tasks

> Change approval 状态以 `proposal.md` 为唯一事实源。本文件只登记任务及各自
> readiness/status，不执行任务或产生 completion evidence；change approval 本身不解除
> 独立 readiness 前置，只有对应 readiness PR 合入的任务才进入 ready，其余保持 blocked。

## TASK-AFP-001 — 建立非权威 Agent 失败模式手册

- Status:ready（2026-07-23 D1 readiness **r2**；仅在维护者 review/merge 本独立 PR 后
  生效。CHG-2026-029 approval 与本任务历史审计 base、**十八项** case routing、固定文档
  结构及验证矩阵已闭合；merge 前不得开 implementation/evidence PR）
- **r1 readiness 已失效（pin drift，如实记录不改写）**：r1 于 #356 合入
  `e73b025dab3c12162465040bd0829470b2409ae9`，其 pins carrier 钉定本 change 四个
  文件的 r1 blob。CHG-2026-029 revision r2（#355 合入
  `de6b79aafa95700297a94dc311e94b1283f8abdd`）把 taxonomy 由 `AF-001`…`AF-009`
  扩为 `AF-001`…`AF-018` 并改动了这四个文件，四枚 pin 全部漂移。按 r1 自身
  “任一漂移即立即停止并重新 readiness”条款，本 r2 重钉全部 pin 与 case routing。
  r1 的 nine-ID routing 结论未被推翻，逐条并入下方 r2 routing；r1 文本保留在
  `#356` 的 Git 历史中，不追溯改写。
- Readiness（**r2**，base = protected `main`
  `de6b79aafa95700297a94dc311e94b1283f8abdd`）：
  - **Approval/dependency gate:satisfied。**r1 proposal #345 合入
    `7083148b4ed6916f17ec87e05cc5970378839ba7`；approval-only #347 已由维护者
    @lvye 合入 `813361830593f416eb845f0cceb9556ab51168be`；revision r2 #355 已由
    维护者 @lvye 合入 `de6b79aafa95700297a94dc311e94b1283f8abdd`，因此
    `proposal.md status:approved` 与 `revision: 2` 均已在 protected `main` 生效。
    本任务无前序 task；AFP-002/003 不构成本任务依赖并继续 `blocked`。
  - **Base/input pins。**以下是真实 `yaml pins` carrier；implementation 开工时必须
    基于本 readiness 合入后的最新 protected `main`，逐项确认路径仍解析到 exact blob、
    两枚 commit 仍在 ancestry 中。任一漂移、路径删除/重命名或 case 结论被后续记录
    supersede，立即停止并重新 readiness；完整 hash 只证明固定引用，不自行证明内容
    正确或获得批准。

    ```yaml pins
    - artifact: TASK-AFP-001 readiness r2 audit base
      commit: de6b79aafa95700297a94dc311e94b1283f8abdd
    - artifact: CHG-2026-029 approval merge
      commit: 813361830593f416eb845f0cceb9556ab51168be
    - artifact: CHG-2026-029 revision r2 merge
      commit: de6b79aafa95700297a94dc311e94b1283f8abdd
    - artifact: TASK-AFP-001 readiness r1 merge (superseded by this r2)
      commit: e73b025dab3c12162465040bd0829470b2409ae9
    - path: AGENTS.md
      blob: 3c2d3c6a01d3eaa31cd9e3ee333f3153552f4164
    - path: openspec/constitution.md
      blob: 137d09da7eaa535670a8bd3b0c9537681e6cb21b
    - path: openspec/governance/enforcement.md
      blob: e8ff3c130e1b8b15f8405d150ad567e774a0d82b
    - path: openspec/verification/policy.md
      blob: ef3b42085ff50b54f1bb70650510f27bdc020cf1
    - path: openspec/changes/chg-2026-029-agent-failure-prevention/proposal.md
      blob: 91ee9a883439fb0d6b749c7d76a49968aa98417e
    - path: openspec/changes/chg-2026-029-agent-failure-prevention/design.md
      blob: e559a6d45f15520b101280a20ed78591a924022a
    - path: openspec/changes/chg-2026-029-agent-failure-prevention/verification.md
      blob: ba0a586442f9397e4c458165fb7972d334f19e2b
    - path: openspec/changes/chg-2026-029-agent-failure-prevention/acceptance-cases.yaml
      blob: 8137232534e498c329a85dece459887f8ef4b8a6
    - path: openspec/changes/chg-2026-026-macos-rockchip-flash-ui/evidence/runs/TASK-RKFUI-001/run.md
      blob: 0f24bb2424e43edb34de0fffaa0eee3c4e5cbec3
    - path: openspec/changes/chg-2026-022-hdc-supervisor-observability/review.md
      blob: d03118ab83cbeb278910c08e55573094edbd5169
    - path: openspec/changes/chg-2026-025-ai-native-unattended-device-ops/review.md
      blob: 197e4adc47f75444a54eefadf00e58b4681e5202
    - path: openspec/changes/archive/2026-07-21-chg-2026-009-dayu200-partition-decode/evidence/runs/TASK-PD-002/platform-attempt-2026-07-20.md
      blob: e0f3b1b77f54b4b7cb1ff17c39316e8e70c29179
    - path: openspec/changes/chg-2026-008-ui-dump-hidumper-wrapper/evidence/runs/TASK-UD-REDACTOR-001/run.md
      blob: 172ea48fba64819d0bf0743816323b8da68b6ec3
    - path: openspec/changes/chg-2026-028-guard-ci-mechanization/proposal.md
      blob: 2395c2b6f4624d806c2b88cb8769a9a0a5326253
    - path: openspec/changes/chg-2026-026-macos-rockchip-flash-ui/evidence/runs/TASK-RKFUI-001/hermetic-contract-test-2026-07-22.md
      blob: 659f99f470cea5f03984de6ea28ce1395e391287
    - path: openspec/changes/archive/2026-07-21-chg-2026-002-macos-m1-infrastructure/evidence/runs/TASK-M1-009/review-remediation-2026-07-18.md
      blob: f615d3fabb42450621e05aa1daa5b837906f41d3
    - path: openspec/changes/archive/2026-07-21-chg-2026-002-macos-m1-infrastructure/evidence/runs/TASK-M1-009/review-remediation-round-2-2026-07-18.md
      blob: 309a7f39f5befd20f3df93f95dcc42b3c02cf975
    - path: openspec/changes/archive/2026-07-21-chg-2026-002-macos-m1-infrastructure/evidence/runs/TASK-M1-009/review-remediation-round-3-2026-07-18.md
      blob: 8911811f11710ab1692b5ae834b21dfe020ea56e
    - path: openspec/changes/archive/2026-07-21-chg-2026-002-macos-m1-infrastructure/evidence/runs/TASK-M1-009/review-remediation-round-4-2026-07-18.md
      blob: e336f498db72ba4c7a4abcd4303d595e152bcb2a
    - path: openspec/planning/postmortem-2026-07-governance.md
      blob: 308d260be9d545b8e27d20a6a30e0719cd76fd19
    - path: openspec/changes/archive/2026-07-21-chg-2026-001-macos-m0a/evidence/runs/TASK-M0A-003/run.md
      blob: 7fc3ab1d4fd3b2000b74ea04b0356d9a6c56fce6
    - path: openspec/changes/archive/2026-07-21-chg-2026-002-macos-m1-infrastructure/tasks.md
      blob: 2ea2ba6672b03f7ab6a86a6a7b136c5d531d9ac9
    - path: openspec/changes/chg-2026-021-trace-adapter-capture/design.md
      blob: 219c2812a321030bdd7a81517150ccc7fac755ab
    - path: openspec/changes/chg-2026-021-trace-adapter-capture/tasks.md
      blob: aea6b410a31d06587679432407ec3119ac819997
    - path: openspec/changes/chg-2026-021-trace-adapter-capture/evidence/runs/TASK-TR-001/run.md
      blob: 6069642a7b3c13d741383fbbdd17a0f921c6b9f2
    - path: openspec/changes/chg-2026-026-macos-rockchip-flash-ui/verification.md
      blob: f4aea707ded798680aacb7811a4786247a94dac8
    - path: openspec/changes/archive/2026-07-21-chg-2026-020-dayu200-real-flash/evidence/runs/TASK-RF-002/run.md
      blob: 8869ad61b9ebf6e5397e7e6007318e11cb26429d
    - path: openspec/changes/archive/2026-07-21-chg-2026-016-dayu200-recovery-rehearsal/evidence/runs/TASK-RH-001/rehearsal-attempt-4-2026-07-21.md
      blob: 6af1a69bea454251bac9a16ba26e58f2483702da
    - path: openspec/changes/chg-2026-028-guard-ci-mechanization/evidence/runs/TASK-MECH-001/run.md
      blob: f5e51fad2f2a429748126eee27ab61df282c2f23
    - path: openspec/changes/chg-2026-008-ui-dump-hidumper-wrapper/tasks.md
      blob: abaee6a12290108f4daeac9f84a3ff6700971433
    - path: openspec/planning/backlog.md
      blob: fc20c3de0187f3f4b4a7e60129163c33a6d1c6c3
    ```

  - **Historical case routing（全部只读引用，不改历史结论）：**
    - `AF-001` → RKFUI-001 `run.md` 的 full-suite allowed-path blocker；实现 #301
      merge `864df6fb29213e39338e72f4e35d7369d10ab961`，精确路径 remediation
      #303 merge `b81361bcbe19c136e96005513261a38252755c9c`。手册只陈述依赖表文件未在
      初始 allowed paths、因而先阻断后修订这一事实。
    - `AF-002` → CHG-2026-022 `review.md`；#269 merge
      `3147e33c0d4bf0f9f54e6160850a42f370c05cb6`。事实范围是 production data
      source 与 unforgeable production origin 缺失，prototype/run 失效，不推断现状实现。
    - `AF-003` → CHG-2026-025 `review.md`；#299 merge
      `a2dab4c3f4279cff0ef1a859cdb5297afe9aeb85`。事实范围是 caller 可同时控制
      authorization carrier、execution facts 与 handoff，真实 destructive dispatch 为 0。
    - `AF-004` → archived CHG-2026-009 `platform-attempt-2026-07-20.md`；r5 诊断/
      revision #158 merge `b8902b199bfa834e8ea6022ea30f8e809c280eee`，producer 修复
      #160 merge `33aff46b9a66370074af66b66ff2afb1ec164e48`。事实范围是首次真实
      producer→consumer run 暴露 Objective-C `NSNumber(int)` JSON `1` 与 Python
      `is True` 的类型缝隙；该 blocked attempt 不升级为 passing evidence。
    - `AF-005` → CHG-2026-008 UD redactor `run.md`；#150 merge
      `4cf67754bf4dd2f5c81c6e8537f8d79c8b71c3c5`。使用“陈旧 hash/PASS 在事实
      原位标记 `SUPERSEDED`”作为正反边界示例，不复制 hash 表或 raw evidence。
    - `AF-006` → CHG-2026-028 `proposal.md` Why/诚实边界；proposal #316 merge
      `2382b47afb4a7ad2d0cb0f88e571b55b65593e61`。只引用其中已列出的 revision、
      pins、PR 载体漂移先例及机械化覆盖，不另建次数数据库。
    - `AF-007` → RKFUI-001 `hermetic-contract-test-2026-07-22.md`；#305 merge
      `c2342ca363e60bea8d159d6fe8b87e8fca31d8ca`。事实范围是 `#filePath`
      build-path 依赖在异地运行失败及 bundle-only 修复；不把已注明的同族 out-of-scope
      限制写成已解决。
    - `AF-008` → archived M1-009 四份 `review-remediation*.md`；实现 #50 merge
      `15697e85444fdacab81779a588c0e290c2f47125`。四轮依次暴露路径替换、typed
      write boundary、rename/unknown outcome、FIFO 与 writer-lock/identity 等 adversarial
      面；手册概括矩阵缺口与“任务跨边界过大”的推断时必须显式标记为 inference。
    - `AF-009` → `postmortem-2026-07-governance.md`；#2 merge
      `47b310d6ef4e06a3048b74c71420bfe411b53621`。事实范围是 V1 密钥同 UID、
      ledger 跨 run 不成立、机制自伤与 V2 决策，不复活废止机制或改写治理规则。
  - **Historical case routing — r2 执行/验证轴（同为只读引用，不改历史结论）：**
    - `AF-010` → archived M0A-003 `run.md` 的 tautological counter removal，与
      archived CHG-2026-002 `tasks.md` 两处套套逻辑清理（测试回显字面量被误写为
      运行期度量）；补充只读引用 CHG-2026-022 `review.md`（#269 merge
      `3147e33c0d4bf0f9f54e6160850a42f370c05cb6`）中“计数落在生产不可达入口”一面。
      事实范围是这些断言/计数曾被移除或判为无效，不推断当前测试套的整体质量。
    - `AF-011` → CHG-2026-021 `design.md`（空 trace `exit 0` 不判 succeeded）、
      CHG-2026-026 `verification.md`（`AC-FLASH-012-01` 的 exit0/marker/postflight
      叉乘）与 archived RF-002 `run.md`（`assessOutcome` 语义 postflight）。手册只
      陈述这些登记面要求按真实成功语义判定，不复制 argv、marker 字面量或工具输出。
    - `AF-012` → archived CHG-2026-016 `rehearsal-attempt-4-2026-07-21.md`；该 blocked
      attempt 记录的根因是 `python3 -` 的 stdin 被 heredoc 抢占、管道数据被丢弃。
      事实范围限于该 attempt 自身，同目录另有 attempt 2/3/5 记录；harness echo
      remediation done 见 #229 merge `3ac44f2d759bd8bec8f95405b85281d70f89cad0`。
      blocked attempt 不升级为 passing evidence，也不复制 transcript 或设备标识。
    - `AF-013` → CHG-2026-021 TR-001 `run.md`；hardening #274 merge
      `628653c69afdf5f1b3c69e0b9eda03ba111fa5bc`。事实范围是照搬既有 harness 形态
      导致 REQ-TRACE-006 的 Job-UUID 隔离与 verified-receive-before-cleanup 未被覆盖，
      经 hardening 修正；不推断其他 harness 是否存在同类漏项（如需断言必须标 inference）。
    - `AF-014` → CHG-2026-021 `tasks.md` 的 TASK-TR-002R 节；scoping #276 merge
      `6e85a784579809b0b79a95bb117d48033892fdf4`，real-fault 修复 #278 merge
      `4bdad2f037cd62c76dbc483f0cfb4a35ae3af539`。事实范围是四条 fail-closed 弱化
      （binding 未 target-bound、无条件 cleanup 无 publication receipt、
      membership 被当 capability、public enum case 绕门）由 post-merge 对抗审查
      发现并以真实 fault 注入堵住；不改写 #270 的历史 review 结论。
    - `AF-015` → archived M1-009 四份 `review-remediation*.md`（与 `AF-008` 共用
      pinned bytes，此处取“同类问题逐轮再现”一面），与 RKFUI-001
      `hermetic-contract-test-2026-07-22.md`；#305 merge
      `c2342ca363e60bea8d159d6fe8b87e8fca31d8ca`。事实范围是 `#filePath` 同族模式
      的部分收口与其余**如实记录为限制**；不得把已注明的 out-of-scope 写成已解决。
    - `AF-016` → CHG-2026-028 MECH-001 `run.md`：readiness r1 钉 `macos-15` 被 CI
      实测推翻，r2 #333 merge `e51dcd7a529d42d521efb9ec113a57716894a6b9` 重钉
      `macos-26`。事实范围是该假设未经探针实证即入 pin、随后被一手 run 证伪；
      三轮 attempt 均在案，手册不复述 run 编号之外的 CI 细节。
    - `AF-017` → CHG-2026-008 `tasks.md` 与 `planning/backlog.md` 记录的 r3 初稿
      过度架构与裁剪：#131 merge `d99ba58042b9cad64de39d6f4baa5994b2c351b2` 将 r3
      裁剪为 M0B-model gates、JAUTH 降级入 backlog；**#128 未合并（closed draft，
      其 head 保留于提交历史）**，手册不得把它写成 merged。次要引用
      `postmortem-2026-07-governance.md` 的 V1 机制规模一面（与 `AF-009` 共用
      pinned bytes，取“规模超配”而非“强度错位”）。
    - `AF-018` → CHG-2026-021 `tasks.md` 与 RKFUI-001 `run.md` 中已登记的并行事实：
      文件级分工作为并行前置、分支被他会话 worktree 占用的处置。**dated
      observation（2026-07-23）**：本任务 r1 readiness（#356 merge
      `e73b025dab3c12162465040bd0829470b2409ae9`）与 CHG-2026-029 revision r2
      （#355 merge `de6b79aafa95700297a94dc311e94b1283f8abdd`）由两个 lane 并行
      推进，导致本 r2 重钉——该实例可作为 `AF-018` 的仓内 case，但必须标注为
      本 change 自身的过程事实，不得表述为产品缺陷或他人过失。
  - **Handbook shape:closed。**唯一新增目标为
    `openspec/planning/agent-failure-patterns.md`，它在 audit base 不存在（零路径碰撞）。
    首屏依次声明 non-normative、权威顺序/冲突时忽略手册并按 canonical rule 处理、
    只链接不复制 evidence、隐私与 archive 只读边界；不得出现新的批准/授权/支持语义。
    随后恰有 `AF-001`…`AF-018` 十八个二级标题，标题名逐字采用 proposal r2 taxonomy
    （治理/交付轴九项 + 执行/验证轴九项，见 design §3、§3.2）；`AF-001`…`AF-009`
    的 `Observed cases` 须含 design §3.1 登记的子面；
    每项恰有 design §2 的八个三级标题：`Signal`、`Observed cases`、`Root cause`、
    `Preflight`、`Verification`、`Canonical references`、`Automation status`、
    `Currency`。Observed cases 以 `Fact`/`Inference` 显式分离；Verification 至少一个
    positive 与一个 negative/fault 方法；Automation status 只能取
    `mechanized`/`partiallyMechanized`/`semanticReview` 并诚实复用 design §3 边界；
    Currency 统一记录本 audit base 完整 OID 与 `2026-07-23`（Asia/Shanghai）。
  - **Canonical-reference routing:closed。**每项至少链接上述 pinned canonical bytes：
    `AGENTS.md` 的权威/批准/执行规则、Constitution 的 fail-closed/evidence/Agent
    边界、enforcement 的信任模型/批准语义/D0-D2/CI 边界、verification policy 的
    verification layers/Definition of Ready/Done/evidence/stop conditions；只用相对链接与
    section anchor，不复制或改写 normative 内容。`design.md`/`verification.md` 只约束本
    approved change，不冒充 canonical authority。
  - **Verification/evidence gate:binary。**implementation/evidence PR 必须同时交付手册、
    本任务 run 与 `tasks.md` 本任务 evidence 引用，但不得翻 `ready→done`；run 至少记录：
    十八 ID/八字段唯一性审读、三十六个 positive/negative 方法存在、全部 case/canonical
    relative link 解析、完整 40-hex OID 与上述 pin currency 复核、`Fact`/`Inference`
    分离、shadow-spec 扫描（新增 normative `SHALL`/`MUST`、自动 approval/ready/done、
    platform/hardware/support 声明均为 0）、secret/绝对用户路径/device identifier/raw
    dump/trace 扫描为 0、`changes/archive/**` diff 为 0、allowed/forbidden path audit、
    `scripts/check-sdd.sh` 0 error/0 warning/111 IDs 与 `git diff --check` PASS。任何一项
    失败即不形成 `AFP-HANDBOOK-001` PASS。
  - **Environment/concurrency gate:satisfied。**纯 host-side document task，零硬件、零
    HDC/device/network/effect dispatch；audit 时 GitHub open PR = 0。仓内 Git/Markdown、
    `rg` 与 Python/PyYAML SDD 环境可用；实现无需新权限、签名、联网依赖或产品/Safety
    判断。若实现期间出现同路径 PR、canonical conflict、secret/privacy 风险或需要修改
    forbidden path，任务立即回到 `blocked`。
  - **Review boundary。**本 readiness PR 只修改本文件的 AFP-001 本节，重钉
    pins/case/shape/verification 并把失效的 r1 替换为 r2；任务保持 `ready`
    （r1 已翻转，本 r2 不再产生状态跃迁，只恢复 readiness 有效性）。零手册、零
    implementation、零 evidence、零 archive/历史改写；`#356` 的 r1 文本保留在 Git
    历史中不追溯改写。implementation/evidence 与后续 `ready→done` 各自使用独立 PR；
    本 readiness merge 不构成 `AFP-HANDBOOK-001` PASS 或 change `verified`。
  - **Currency 复核（2026-07-23）。**上表全部 blob 与 commit 于 audit base
    `de6b79aafa95700297a94dc311e94b1283f8abdd` 实测取值，非从 r1 转抄；r1 中未受
    r2 影响的 pin 逐枚重取后与 r1 值一致，受影响的四枚已更新（见本节开头的
    pin drift 记录）。开工前须再次对最新 protected `main` 复核，漂移即停止。
- Platform:macos（过程文档跨平台可复用，零平台产品行为）
- Requirements/AC:change-local `AFP-HANDBOOK-001`
- Depends on:change approval、independent readiness
- Applicable failure patterns:`AF-009`（避免把手册本身做成新的重型治理机制）
- Production reachability:not applicable；纯文档索引，零产品 effect
- Trusted fact sources:protected-main Git 历史、仓内 review/postmortem/evidence；聊天记忆与
  仓库外 scratchpad 不作为事实源
- Allowed paths:`openspec/planning/agent-failure-patterns.md`、
  `openspec/changes/chg-2026-029-agent-failure-prevention/evidence/**`、
  `openspec/changes/chg-2026-029-agent-failure-prevention/tasks.md`（仅本任务状态/evidence 引用）
- Forbidden paths:`AGENTS.md`、`openspec/constitution.md`、
  `openspec/governance/**`、`openspec/specs/**`、`openspec/contracts/**`、
  `openspec/changes/archive/**`、产品 source/tests/scripts/workflows
- Risk:low（主要风险是 shadow spec、陈旧链接与复制敏感 evidence）
- Hardware required:no

### Deliverables

- `openspec/planning/agent-failure-patterns.md`，包含 design §2 固定字段与首批
  `AF-001`…`AF-018`（r1 治理/交付轴九项 + r2 执行/验证轴九项，见 design §3.2）；
- `AF-001`…`AF-009` 各自并入 design §3.1 登记的已观察子面；
- 每项至少一个可复查仓内案例与 canonical rule 引用，事实/推断分离；
- CHG-2026-028 已覆盖面与未覆盖语义面诚实标注（含 `AF-010`/`AF-016` 的
  “canary 红反证只覆盖新 check”“pins 校验只覆盖形状不覆盖来源”两处边界）；
- non-normative/authority/conflict/privacy/archive 边界在首屏明确。

### Verification

- `AFP-HANDBOOK-001` document review；
- 十八个 ID 唯一且字段齐全；link/OID/currency 审计；shadow-spec、secret/privacy、
  archive-zero-diff 检查；
- `scripts/check-sdd.sh` 与 `git diff --check`。

### Notes / handoff

- 实现/evidence PR 不翻 task 状态；`ready→done` 使用独立 PR；
- 若某案例需要修改历史结论或 canonical rule，停止并把该问题交回所属 change，不在本
  手册任务中修复。

## TASK-AFP-002 — 将失败模式选择、生产可达性与 evidence freshness 接入模板

- Status:blocked（三前置：① change approval；② TASK-AFP-001 done；③ 独立 readiness
  PR 钉定三个模板 blob 与精确新增字段）
- Platform:macos（模板跨平台可复用，零平台产品行为）
- Requirements/AC:change-local `AFP-TEMPLATE-001`
- Depends on:change approval、TASK-AFP-001 done、independent readiness
- Applicable failure patterns:`AF-001`、`AF-002`、`AF-003`、`AF-005`、`AF-008`
- Production reachability:not applicable；本任务只修改模板，模板内容要求未来任务显式
  记录 production root→authority→effect 或 `not applicable` 理由
- Trusted fact sources:TASK-AFP-001 已合入手册、当前三个模板完整 Git blob；模板不把
  调用者自报字段升级为可信事实
- Allowed paths:`openspec/templates/change/tasks.md`、
  `openspec/templates/change/design.md`、`openspec/templates/change/evidence-run.md`、
  `openspec/changes/chg-2026-029-agent-failure-prevention/evidence/**`、
  `openspec/changes/chg-2026-029-agent-failure-prevention/tasks.md`（仅本任务状态/evidence 引用）
- Forbidden paths:`AGENTS.md`、`openspec/constitution.md`、
  `openspec/governance/**`、`openspec/specs/**`、`openspec/contracts/**`、
  `openspec/changes/archive/**`、产品 source/tests/scripts/workflows
- Risk:low-medium（模板措辞可能被误解为新批准语义或强制性产品规则）
- Hardware required:no

### Deliverables

- tasks template：Applicable AF、production reachability、trusted fact sources 三个短字段；
- design template：authority/production reachability 分析段；
- evidence-run template：完整 base OID/input pins、producer→consumer、currency/
  superseded/invalidated 字段；
- 所有新增字段都允许诚实 `not applicable` + 理由，不改变既有状态、scope、AC、风险、
  hardware 与 evidence 分类规则。

### Verification

- `AFP-TEMPLATE-001` document review；
- before/after 字段矩阵证明既有模板条目零删除、零放宽；
- 搜索不存在自动批准、自动 ready/done、fake→hardware 或手册覆盖 canonical rule 的措辞；
- `scripts/check-sdd.sh` 与 `git diff --check`，archive diff 为零。

### Notes / handoff

- 不在本任务引入 parser/CI；进一步机械化必须另立 change；
- 实现/evidence 与状态 PR 分离。

## TASK-AFP-003 — 历史案例检出演练与误报边界复核

- Status:blocked（四前置：① change approval；② TASK-AFP-001 done；③ TASK-AFP-002 done；
  ④ 独立 readiness PR 钉定六个案例和一个环境反例的完整 base/link）
- Platform:macos（document review；零真实设备/产品执行）
- Requirements/AC:change-local `AFP-DRILL-001`
- Depends on:change approval、TASK-AFP-001 done、TASK-AFP-002 done、independent readiness
- Applicable failure patterns:`AF-001`…`AF-009`
- Production reachability:not applicable；只对历史记录做检出演练，不执行或重新验证产品路径
- Trusted fact sources:readiness 钉定的 protected-main OID、仓内历史 bytes 与 merge/review
  记录；不得用聊天摘要补足历史事实
- Allowed paths:`openspec/changes/chg-2026-029-agent-failure-prevention/evidence/**`、
  `openspec/changes/chg-2026-029-agent-failure-prevention/tasks.md`（仅本任务状态/evidence 引用）
- Forbidden paths:`AGENTS.md`、`openspec/constitution.md`、
  `openspec/governance/**`、`openspec/specs/**`、`openspec/contracts/**`、
  `openspec/changes/archive/**`、`openspec/planning/agent-failure-patterns.md`、
  `openspec/templates/**`、产品 source/tests/scripts/workflows
- Risk:low（风险是 hindsight bias、把环境失败误报为产品缺陷、或把演练当作重新验证）
- Hardware required:no

### Deliverables

- 一份 historical detection drill run，覆盖 design §5 六类固定案例与至少一个环境失败反例；
- 每例记录最早触发阶段、AF ID、模板字段、应采取动作、历史最终发现证据；
- false-positive 边界：环境失败保持环境失败，fake/simulation 不升级为真实支持，演练不改变
  任何历史 task/change/AC 结论。

### Verification

- `AFP-DRILL-001` document review；
- 六类案例全部有 evidence link 且能映射到具体 preflight/verification 动作；
- 至少一个环境反例被正确分类为 blocked/deviation 而非产品 failure；
- archive、历史 evidence、产品代码 diff 均为零；`scripts/check-sdd.sh` 与
  `git diff --check`。

### Notes / handoff

- 演练结果若发现当前 active task 的现实缺陷，只记录指针并 fail closed；不得在 AFP-003
  allowed paths 外顺手修复。
