# CHG-2026-029 Tasks

> Change approval 状态以 `proposal.md` 为唯一事实源。本文件只登记任务及各自
> readiness/status，不执行任务或产生 completion evidence；change approval 本身不解除
> 独立 readiness 前置，只有对应 readiness PR 合入的任务才进入 ready，其余保持 blocked。

## TASK-AFP-001 — 建立非权威 Agent 失败模式手册

- Status:done（2026-07-23；仅在维护者 review/merge 本独立状态 PR 后生效。
  implementation + evidence PR #360 已由维护者 @lvye APPROVED 并合入 protected
  `main`，merge OID `95dc61cf6ed9223f5b5c1728aaf0d9a1ba6c9d5c`；交付物
  `openspec/planning/agent-failure-patterns.md` 于该 merge 的 blob 为
  `5b8c3b6b26b76893744aa11bdd7618318eab4674`。done 不等于 change `verified`：
  `AFP-HANDBOOK-001` 的最终结论仍需 change 级 verify PR 由维护者确认。）
- Done recheck（在**合入版** `95dc61cf6ed9223f5b5c1728aaf0d9a1ba6c9d5c` 上重跑，
  非沿用实现 PR 的结论）：
  - 结构：H2 = 18 且 `AF-001`…`AF-018` 唯一无缺号；H3 = 144，18 组均为 design §2
    八字段且同序；
  - 方法：positive 18 + negative 18 = 36；`Fact`/`Inference` 每项至少各一；
    `Automation status` 18 项全部落在三个合法取值内；`Currency` 18 项统一记
    audit base `de6b79aafa95700297a94dc311e94b1283f8abdd` 与 `2026-07-23`；
  - 引用：相对链接 99 条全解析（含 56 个 section anchor 命中目标文件真实标题）；
    完整 40-hex OID 20 枚全部在 ancestry；
  - 边界：新增 normative `SHALL`/`MUST` = 0；用户绝对路径 = 0；裸 64-hex 摘要 = 0；
  - readiness r2 pins 在合入版复核 35/35 无漂移；
  - `scripts/check-sdd.sh` 0 error / 0 warning / 111 acceptance IDs；
    `git diff --check` 干净。
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

### Evidence（candidate；不构成状态翻转）

- implementation + evidence run:
  [`evidence/runs/TASK-AFP-001/run.md`](evidence/runs/TASK-AFP-001/run.md)
  （2026-07-23，final run base `b2571fa6e30cf00594869c365c10d48946a8c9f6`；
  draft start `2f0c53e2924382bdf051c4975d1ed35b4ffd042d`；readiness r2 audit base
  `de6b79aafa95700297a94dc311e94b1283f8abdd`）。交付物
  `openspec/planning/agent-failure-patterns.md` blob
  `5b8c3b6b26b76893744aa11bdd7618318eab4674`。
- 二值门实测：H2 = 18 / H3 = 144（八字段同序）、positive 18 + negative 18 = 36、
  链接 99 全解析（含 56 个 anchor）、40-hex OID 20 枚全在 ancestry、shadow-spec 与
  隐私扫描均为 0、archive diff = 0、check-sdd 0/0/111、`git diff --check` 干净。
- #360 implementation/evidence PR 中任务状态保持 `ready`；随后独立状态 PR #362
  由维护者 `lvye` 合入 protected `main`，merge OID
  `4c8506a30afc5505230134903ccf03729a640c07`（GitHub `reviews=[]`，不臆造 review），
  当前任务状态为 `done`。该 task-level `AFP-HANDBOOK-001` 结论不构成 change
  `verified`，后者仍须独立 change 级 verify PR 由维护者确认。

### Notes / handoff

- 实现/evidence PR 不翻 task 状态；`ready→done` 使用独立 PR；
- 若某案例需要修改历史结论或 canonical rule，停止并把该问题交回所属 change，不在本
  手册任务中修复。

## TASK-AFP-002 — 将失败模式选择、生产可达性与 evidence freshness 接入模板

- Status:done（2026-07-23；仅在维护者 review/merge 本独立状态 PR 后生效。
  implementation + evidence PR #366 已由维护者 @lvye APPROVED 并合入 protected
  `main`，merge OID `3ed97323225b4614aa537bc707e1c79bb5fb9b36`。done 不等于
  change `verified`：`AFP-TEMPLATE-001` 的最终结论仍需 change 级 verify PR 由
  维护者确认。）
- Done recheck（在**合入版** `3ed97323225b4614aa537bc707e1c79bb5fb9b36` 上重跑，
  非沿用实现 PR 的结论）：
  - 相对 readiness base `9397e23d62434cc9b7cb747d721044442322763f`，三模板
    `+13 -0` / `+11 -0` / `+10 -0`——**零删除零修改行**；base 每一非空行在合入版
    逐文件缺失均为 0；
  - readiness 封闭的 8 处新增在合入版全部在场：tasks 三个 bullet、design 的
    `## Authority and production reachability`、evidence-run 的 `Base`/
    `Input pins`/`Producer → consumer`/`Evidence currency`；
  - polarity-aware boundary scan 六类在合入版全部为 0；
  - `scripts/check-sdd.sh` 0 error / 0 warning / 111 acceptance IDs。
- Pin lifecycle 说明（**预期行为，非漂移事故**）：本任务 readiness carrier 钉定的
  三个模板 blob 是**实现前**的值，其用途是"开工时确认未被他方改动"，该义务已在
  开工时满足（base `9397e23d…` 上 52/52 无漂移）。实现合入后这三枚 blob 必然改变，
  属任务自身交付物所致，与 TASK-AFP-001 r1 那次"实现开工前被他方 PR 打掉 pin"
  性质不同，不触发重新 readiness。其余 49 项 pin 在合入版仍逐项命中。
- Readiness（r1，base = protected `main`
  `9753b4bbc024b90454c7efc68f28d48a2760c545`）：
  - **Approval/dependency gate:satisfied。**approval-only #347 合入
    `813361830593f416eb845f0cceb9556ab51168be`；revision r2 #355 合入
    `de6b79aafa95700297a94dc311e94b1283f8abdd`（`status: approved` 与
    `revision: 2` 均已在 protected `main` 生效）。**前置 ② 已满足**：
    TASK-AFP-001 implementation #360 合入
    `95dc61cf6ed9223f5b5c1728aaf0d9a1ba6c9d5c`，`ready→done` 状态 PR #362 合入
    `4c8506a30afc5505230134903ccf03729a640c07`，该任务在 protected `main` 上为
    `done`。AFP-003 不构成本任务依赖并继续 `blocked`。
  - **Base/input pins。**以下是真实 `yaml pins` carrier；implementation 开工时必须
    基于本 readiness 合入后的最新 protected `main`，逐项确认路径仍解析到 exact blob、
    commit 仍在 ancestry 中。任一漂移、路径删除/重命名或字段定义被后续记录
    supersede，立即停止并重新 readiness；完整 hash 只证明固定引用，不自行证明内容
    正确或获得批准。

    ```yaml pins
    - artifact: TASK-AFP-002 readiness audit base
      commit: 9753b4bbc024b90454c7efc68f28d48a2760c545
    - artifact: CHG-2026-029 approval merge
      commit: 813361830593f416eb845f0cceb9556ab51168be
    - artifact: CHG-2026-029 revision r2 merge
      commit: de6b79aafa95700297a94dc311e94b1283f8abdd
    - artifact: TASK-AFP-001 implementation merge
      commit: 95dc61cf6ed9223f5b5c1728aaf0d9a1ba6c9d5c
    - artifact: TASK-AFP-001 done status merge
      commit: 4c8506a30afc5505230134903ccf03729a640c07
    - path: openspec/templates/change/tasks.md
      blob: 7fe7e00a9cf3ebc051abb4ced4147b8ca8d8d540
    - path: openspec/templates/change/design.md
      blob: b3f18410a2199975595b44a1cdd558ab890825d5
    - path: openspec/templates/change/evidence-run.md
      blob: a5fb98d9eada0d0664772756cfc8b2a2b1e78f3a
    - path: openspec/planning/agent-failure-patterns.md
      blob: 5b8c3b6b26b76893744aa11bdd7618318eab4674
    - path: openspec/changes/chg-2026-029-agent-failure-prevention/design.md
      blob: e559a6d45f15520b101280a20ed78591a924022a
    - path: openspec/changes/chg-2026-029-agent-failure-prevention/proposal.md
      blob: 91ee9a883439fb0d6b749c7d76a49968aa98417e
    - path: openspec/changes/chg-2026-029-agent-failure-prevention/verification.md
      blob: ba0a586442f9397e4c458165fb7972d334f19e2b
    - path: openspec/changes/chg-2026-029-agent-failure-prevention/acceptance-cases.yaml
      blob: 8137232534e498c329a85dece459887f8ef4b8a6
    - path: AGENTS.md
      blob: 3c2d3c6a01d3eaa31cd9e3ee333f3153552f4164
    - path: openspec/constitution.md
      blob: 137d09da7eaa535670a8bd3b0c9537681e6cb21b
    - path: openspec/governance/enforcement.md
      blob: e8ff3c130e1b8b15f8405d150ad567e774a0d82b
    - path: openspec/verification/policy.md
      blob: ef3b42085ff50b54f1bb70650510f27bdc020cf1
    ```

  - **Exact field set:closed。**只增不删；下列是允许写入的**全部**新增内容，
    实现不得超出，也不得少于任一项。字段措辞可在不改变语义的范围内润色，但
    "允许诚实 `not applicable` + 理由""不自动通过""不创造批准/状态语义"三条必须
    在模板文本中可见。

    1. `templates/change/tasks.md` — 在既有 `Readiness input pins` 块之后、
       `Allowed paths` 之前插入**恰三个** bullet（与 design §4 的字段名一致，
       并与本 change 自身 tasks.md 的既有相对顺序一致）：
       - `Applicable failure patterns:` — 取 `AF-NNN`… 或 `none`，`none` 须附
         可审查理由；写明 reviewer 可要求改为相关 AF ID，选 `none` 不是自动通过；
         引用手册相对路径 `../../planning/agent-failure-patterns.md`。
       - `Production reachability:` — `root → authority → effect`，或明确
         `not applicable` 加理由。
       - `Trusted fact sources:` — 事实生产者、freshness/binding 与 anti-forgery
         边界；写明调用方自报字段不因填写本行而升级为可信事实。
    2. `templates/change/design.md` — 在 `## Data and contract changes` 之后、
       `## Failure, cancellation, and recovery` 之前新增**恰一个**二级小节
       `## Authority and production reachability`，含 design §4 的五个要点：
       production composition root；authority/permit/capability 的唯一产生点；
       effect dispatch point 与 intent/outcome durable 边界；fake/simulation 与
       production 的结构差异；facts/provenance 能否由同一调用方同时控制。
       纯文档/host-only 无 effect 的任务可写 `not applicable`，但须给出理由。
    3. `templates/change/evidence-run.md` — 在既有 run identity bullet 列表
       （`Evidence class` / `Core baseline` / `Scope`）中增补**恰四个** bullet：
       完整 base OID；关键输入 hash/pin；producer→consumer 路径；
       evidence currency 三态 `current` / `superseded` / `invalidated` 及其含义。
       同时写明 currency 状态须在**事实原位**可见，不得只在文件尾部写模糊
       supersession 注记。

  - **Zero-deletion / zero-relaxation gate:binary。**实现 PR 必须给出 before/after
    字段矩阵，逐项证明三个模板的既有条目**零删除、零放宽**，具体包括但不限于：
    tasks 模板的 `Status`/`Platform`/`Requirements`/`Acceptance`/`Depends on`/
    `Readiness input pins`（含 MECH-003 引入的**非载体** `yaml pin-example` 块与
    "实例化时改用 `yaml pins`"注记，逐字保留）/`Allowed paths`/`Forbidden paths`/
    `Risk`（含 CHG-2026-025 引入的 destructive/standing authorization 注释）/
    `Hardware required`/`Deliverables`/`Verification`/`Notes / handoff`；
    design 模板的六个既有小节；evidence-run 模板的抬头禁令、`Evidence class`
    取值域、四个既有小节与"run record 不改任务状态""simulation/fake 永不计入
    realHardware"两条（含 CHG-2026-025 引入的人类执行例外措辞）。
  - **Boundary scan:binary。**实现后全模板搜索，下列各项计数必须为 0：自动
    approval / 自动 `ready`/`done` / auto-merge 表述；`fake`、`simulation` 或
    `plan` 升级为 `realHardware` 或平台支持的表述；把手册描述为 required gate 或
    可覆盖 canonical rule 的表述；新增 normative `SHALL`/`MUST`；secret、真实设备
    标识、用户绝对路径。
  - **Canonical-reference routing:closed。**新增字段只引用 canonical rule 与手册，
    不复制其 normative 文本：
    [`AGENTS.md` 权威顺序](../../../AGENTS.md#权威顺序)与
    [执行规则](../../../AGENTS.md#执行规则)、
    [`POL-SAFETY-001`](../../constitution.md#pol-safety-001-fail-closed-under-uncertainty)、
    [`POL-VERIFY-001`](../../constitution.md#pol-verify-001-evidence-not-task-completion)、
    [enforcement — 批准语义](../../governance/enforcement.md#批准语义)、
    [verification policy — Definition of Ready](../../verification/policy.md#definition-of-ready)
    与 [Evidence 与 run 记录](../../verification/policy.md#evidence-与-run-记录)。
    模板不得暗示填写某字段本身构成批准、就绪或完成。
  - **Environment/concurrency gate:satisfied。**纯 host-side document task，零硬件、
    零 HDC/device/network/effect dispatch。**模板面并发已核**（截至 base，凭
    `gh pr list` 与逐 change `tasks.md` 复核）：曾持 `openspec/templates/change/**`
    授权的 TASK-MECH-003（CHG-2026-028）与曾改动两个模板的 TASK-AIN-001
    （CHG-2026-025）均为 `done`；同期唯一 `ready` 的 TASK-MECH-004 其 Allowed
    paths 为 `.github/workflows/sdd-guard.yml`、`scripts/check_pr_paths.py`、
    `scripts/test_check_pr_paths.py` 及其 change 自有路径，**不含模板面**。因此本
    任务对三个模板持唯一 live 授权。若实现期间出现同路径 PR、canonical conflict、
    secret/privacy 风险或需要修改 forbidden path，任务立即回到 `blocked`。
  - **Verification/evidence gate:binary。**implementation/evidence PR 必须同时交付
    三个模板改动、本任务 run 与 `tasks.md` 本任务 evidence 引用，但不得翻
    `ready→done`；run 至少记录：三处新增与上述 Exact field set 逐项对应、
    before/after 字段矩阵零删除零放宽、boundary scan 各项为 0、新增字段的
    canonical 相对链接与 anchor 全部解析、`changes/archive/**` diff 为 0、
    allowed/forbidden path audit、`scripts/check-sdd.sh` 0 error/0 warning/
    111 acceptance IDs 与 `git diff --check` PASS。任何一项失败即不形成
    `AFP-TEMPLATE-001` PASS。
  - **Review boundary。**本 readiness PR 只修改本文件的 AFP-002 本节，将
    AFP-002 `blocked→ready` 并登记 pins/field-set/gate；零模板改动、零
    implementation、零 evidence、零 archive/历史改写。implementation/evidence 与后续
    `ready→done` 各自使用独立 PR；本 readiness merge 不构成 `AFP-TEMPLATE-001`
    PASS 或 change `verified`。
  - **Currency 复核（2026-07-23）。**上表全部 blob 与 commit 实测取值，非从
    AFP-001 readiness 转抄。起草起点为 `4c8506a30afc5505230134903ccf03729a640c07`
    （TASK-AFP-001 done 合入点）；起草期间 protected `main` 前进到
    `9753b4bbc024b90454c7efc68f28d48a2760c545`（#358 TASK-TR-003 实现，与本任务
    授权面零文件交集），audit base 已改钉该 commit 并在其上**重新复核全部 pin**：
    本 carrier 17/17、TASK-AFP-001 r2 carrier 35/35，合计 52/52 零漂移。其中
    `chg-2026-021-trace-adapter-capture/tasks.md` 未被 #358 改动，符合"实现 PR 不
    翻 task 状态"约定。开工前须再次对最新 protected `main` 复核，漂移即停止。
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

### Evidence（candidate；不构成状态翻转）

- implementation + evidence run:
  [`evidence/runs/TASK-AFP-002/run.md`](evidence/runs/TASK-AFP-002/run.md)
  （2026-07-23，base `9397e23d62434cc9b7cb747d721044442322763f`）。
- 二值门实测：开工前 pins 52/52 无漂移；三模板 diff 为 `+13 -0` / `+11 -0` /
  `+10 -0`（零删除零修改）；base 行缺失逐文件为 0；13 项点名既有条目全部在场；
  polarity-aware boundary scan 六类全 0 且 4 条 canary 全部变红；模板内新增相对
  路径解析通过；archive diff = 0；check-sdd 0/0/111；`git diff --check` 干净。
- 任务状态保持 `ready`；`AFP-TEMPLATE-001` 的 PASS 结论待维护者在独立
  `ready→done` PR 中确认。

### Notes / handoff

- 不在本任务引入 parser/CI；进一步机械化必须另立 change；
- 实现/evidence 与状态 PR 分离。

## TASK-AFP-003 — 历史案例检出演练与误报边界复核

- Status:done（2026-07-23；仅在维护者 review/merge 本独立状态 PR 后生效。
  implementation + evidence PR #383 已合入 protected `main`，squash merge OID
  `493153f65025f177550071b5c7ac5ea7cb0b90d0`；该 squash 只含本任务两个交付文件
  （`evidence/runs/TASK-AFP-003/run.md` 与 `tasks.md`），两者 blob 与实现分支 head
  `86fc669cd7b780c90eb8a450749a57d580f65385` **逐字一致**。done 不等于 change
  `verified`：`AFP-DRILL-001` 的最终结论仍需 change 级 verify PR 由维护者确认。）
- Done recheck（在**合入版** `493153f65025f177550071b5c7ac5ea7cb0b90d0` 上重跑，
  非沿用实现 PR 的结论）：
  - drill 覆盖：六案例 + 1 个环境反例节，逐行六列齐全；
  - 引用一致性：12 个 `AF-NNN` 全部存在于已合入手册（AFP-004 更正后版本）；
    6 个模板字段全部存在于已合入模板（AFP-002 交付版本）；
  - OID：9 枚中 commit 类全部在 protected `main` ancestry；
  - hindsight-bias 二值边界：列 ④ 全部标注 `Inference`（共 16 处 `Inference` 标注）；
    历史结论改写 = 0、产品/硬件重新验证声明 = 0、`fake`→`realHardware` 升级 = 0；
  - readiness r2 carrier 在合入版复核 **28/28** 无漂移；
  - `scripts/check-sdd.sh` 0 error / 0 warning / 111 acceptance IDs。
- Provenance 复核边界（**如实记录**）：TASK-BAP-003 凭据分离生效后 Agent 无维护者
  `gh` 凭据，无法读取 #383 的 reviews/mergedBy。本次以 `git` 验证：squash commit
  `493153f6…` 在 protected `main` 上、其 diff 恰为本任务两个交付文件、blob 与实现
  head 逐字一致。**"由维护者 APPROVED"未经 Agent 独立验证**，由维护者 review 本
  状态 PR 时确认。
- **r1 readiness 已失效（pin drift，如实记录不改写）**：r1 于 #369 合入
  `16325dbe40bad0fd445587e34ef4e99f93a76b9b`，其 pins carrier 钉定了本 change 四个
  文档与手册的当时 blob。此后两次**有意的更正**改动了这五个文件：
  CHG-2026-029 revision r3（#371 合入 `b53db548197486bd58d9236e183632c744f5276e`，
  更正 design §3.2 `AF-014`）与 TASK-AFP-004（实现 #374 合入
  `21d339b97d083f1e79c1851854737d5cf0a68d8e`、状态 #379 合入
  `605bff0…`），五枚 pin 全部漂移。按 r1 自身"任一漂移即立即停止并重新 readiness"
  条款，本 r2 重钉全部 pin。**r1 的 drill case set、环境反例、row shape 与
  hindsight-bias 边界结论未被推翻**，逐条保留于下方 r2；r1 文本保留在 `#369` 的
  Git 历史中，不追溯改写。该漂移是 r3 已预先登记的连带后果，不是意外。
- Readiness（**r2**，base = protected `main`
  `7d04c3dccb598a5e1a1d3b16846162353069dbf2`）：
  - **Approval/dependency gate:satisfied。**approval-only #347 合入
    `813361830593f416eb845f0cceb9556ab51168be`；revision r2 #355 合入
    `de6b79aafa95700297a94dc311e94b1283f8abdd`。**前置 ②**：TASK-AFP-001 实现 #360
    合入 `95dc61cf6ed9223f5b5c1728aaf0d9a1ba6c9d5c`、done #362 合入
    `4c8506a30afc5505230134903ccf03729a640c07`。**前置 ③**：TASK-AFP-002 实现 #366
    合入 `3ed97323225b4614aa537bc707e1c79bb5fb9b36`、done #368 合入
    `89f6c916e2724941b3cb9d949c3d925a92ade3db`。两任务在 protected `main` 上均为
    `done`，故本任务的手册与模板两项输入均已就位。
  - **Base/input pins。**以下是真实 `yaml pins` carrier；implementation 开工时必须
    基于本 readiness 合入后的最新 protected `main`，逐项确认路径仍解析到 exact blob、
    commit 仍在 ancestry 中。任一漂移、路径删除/重命名或案例结论被后续记录
    supersede，立即停止并重新 readiness；完整 hash 只证明固定引用，不自行证明内容
    正确或获得批准。

    ```yaml pins
    - artifact: TASK-AFP-003 readiness r2 audit base
      commit: 7d04c3dccb598a5e1a1d3b16846162353069dbf2
    - artifact: CHG-2026-029 revision r3 merge
      commit: b53db548197486bd58d9236e183632c744f5276e
    - artifact: TASK-AFP-004 implementation merge (handbook corrections)
      commit: 21d339b97d083f1e79c1851854737d5cf0a68d8e
    - artifact: TASK-AFP-003 readiness r1 merge (superseded by this r2)
      commit: 16325dbe40bad0fd445587e34ef4e99f93a76b9b
    - artifact: CHG-2026-029 approval merge
      commit: 813361830593f416eb845f0cceb9556ab51168be
    - artifact: CHG-2026-029 revision r2 merge
      commit: de6b79aafa95700297a94dc311e94b1283f8abdd
    - artifact: TASK-AFP-001 done status merge
      commit: 4c8506a30afc5505230134903ccf03729a640c07
    - artifact: TASK-AFP-002 done status merge
      commit: 89f6c916e2724941b3cb9d949c3d925a92ade3db
    - path: openspec/planning/agent-failure-patterns.md
      blob: 3aab3c3fd6c7cf9e80ab4831b60ac58588d5d431
    - path: openspec/templates/change/tasks.md
      blob: b5a73d0f2bd9a7529e751fdc46fe23b43df365b5
    - path: openspec/templates/change/design.md
      blob: c90c6d1033909b55c07e2054b7a5e59828b8d12c
    - path: openspec/templates/change/evidence-run.md
      blob: c46a0457d2ec921e1d45f1d3f5463d1b8cbd4095
    - path: openspec/changes/chg-2026-026-macos-rockchip-flash-ui/evidence/runs/TASK-RKFUI-001/run.md
      blob: 0f24bb2424e43edb34de0fffaa0eee3c4e5cbec3
    - path: openspec/changes/chg-2026-022-hdc-supervisor-observability/review.md
      blob: d03118ab83cbeb278910c08e55573094edbd5169
    - path: openspec/changes/chg-2026-025-ai-native-unattended-device-ops/review.md
      blob: 197e4adc47f75444a54eefadf00e58b4681e5202
    - path: openspec/changes/archive/2026-07-21-chg-2026-009-dayu200-partition-decode/evidence/runs/TASK-PD-002/platform-attempt-2026-07-20.md
      blob: e0f3b1b77f54b4b7cb1ff17c39316e8e70c29179
    - path: openspec/changes/archive/2026-07-21-chg-2026-002-macos-m1-infrastructure/evidence/runs/TASK-M1-009/review-remediation-2026-07-18.md
      blob: f615d3fabb42450621e05aa1daa5b837906f41d3
    - path: openspec/changes/archive/2026-07-21-chg-2026-002-macos-m1-infrastructure/evidence/runs/TASK-M1-009/review-remediation-round-4-2026-07-18.md
      blob: e336f498db72ba4c7a4abcd4303d595e152bcb2a
    - path: openspec/planning/postmortem-2026-07-governance.md
      blob: 308d260be9d545b8e27d20a6a30e0719cd76fd19
    - path: openspec/changes/chg-2026-026-macos-rockchip-flash-ui/evidence/runs/TASK-RKFUI-001/hermetic-contract-test-2026-07-22.md
      blob: 659f99f470cea5f03984de6ea28ce1395e391287
    - path: openspec/changes/chg-2026-029-agent-failure-prevention/design.md
      blob: fd3d21147fd75ecc9543222d567aefae351171f5
    - path: openspec/changes/chg-2026-029-agent-failure-prevention/proposal.md
      blob: c0ac4b1dbe331abcad38c6b05a1287cede8af9fe
    - path: openspec/changes/chg-2026-029-agent-failure-prevention/verification.md
      blob: 075f6177b5cdbd0207ef27e93b4d257fb3971d77
    - path: openspec/changes/chg-2026-029-agent-failure-prevention/acceptance-cases.yaml
      blob: 54963daaac8302ee5900024780c9dd7b3a9b3814
    - path: AGENTS.md
      blob: 3c2d3c6a01d3eaa31cd9e3ee333f3153552f4164
    - path: openspec/constitution.md
      blob: 137d09da7eaa535670a8bd3b0c9537681e6cb21b
    - path: openspec/governance/enforcement.md
      blob: e8ff3c130e1b8b15f8405d150ad567e774a0d82b
    - path: openspec/verification/policy.md
      blob: ef3b42085ff50b54f1bb70650510f27bdc020cf1
    ```

  - **Drill case set:closed（design §5 六案例，全部只读引用，不改历史结论）。**
    每例的事实范围以其 pinned bytes 为准；承载 PR 的 merge OID 经 `gh pr view`
    核对，不凭 git log 推断。
    1. **readiness/allowed-paths 漏项** → RKFUI-001 `run.md` 的 full-suite
       allowed-path blocker；实现 #301 merge
       `864df6fb29213e39338e72f4e35d7369d10ab961`，精确路径 remediation #303 merge
       `b81361bcbe19c136e96005513261a38252755c9c`。主 AF = `AF-001`。
    2. **production source / unforgeable origin 缺失** → CHG-2026-022 `review.md`；
       #269 merge `3147e33c0d4bf0f9f54e6160850a42f370c05cb6`。主 AF = `AF-002`，
       其"计数落在生产不可达入口"一面并触 `AF-010`。
    3. **caller-controlled authorization/facts/dispatch** → CHG-2026-025 `review.md`
       的 `P0-AUTH-001`/`P0-FACT-001`/`P0-DISPATCH-001`；#299 merge
       `a2dab4c3f4279cff0ef1a859cdb5297afe9aeb85`。主 AF = `AF-003`，
       gate 校验强度一面并触 `AF-014`。
    4. **producer→consumer 跨语言缝隙** → archived PD-002
       `platform-attempt-2026-07-20.md`；r5 revision #158 merge
       `b8902b199bfa834e8ea6022ea30f8e809c280eee`，producer 修复 #160 merge
       `33aff46b9a66370074af66b66ff2afb1ec164e48`。主 AF = `AF-004`。
    5. **adversarial 多轮 remediation** → archived M1-009 的初轮与 round-4 两份
       记录（其余两轮在同目录，drill 可引用但不必逐份 pin）；实现 #50 merge
       `15697e85444fdacab81779a588c0e290c2f47125`。主 AF = `AF-008`，
       "同类问题逐轮再现"一面并触 `AF-015`。
    6. **V1 治理信任边界错位** → `postmortem-2026-07-governance.md`；#2 merge
       `47b310d6ef4e06a3048b74c71420bfe411b53621`。主 AF = `AF-009`，
       机制规模一面并触 `AF-017`。
  - **Environment counterexample:closed（至少一例，本 readiness 钉两例）。**
    - **主反例** → RKFUI-001 `run.md` 记录的 E0 quarantine blocker：工具签名完整但
      带 `com.apple.quarantine` 且 Gatekeeper 拒绝，产品返回 typed
      `toolBlocked(quarantinePresent)`、零子进程启动，且未清除/改写 quarantine、
      未拷贝规避评估、未安装 helper 提权；该次尝试保持 **BLOCKED**，既未记为产品
      缺陷，也未记为通过。drill 必须证明手册不会把它误判为产品失败。
    - **备用反例** → RKFUI-001 `hermetic-contract-test-2026-07-22.md` 中
      `/private/tmp` 工作树口径的环境性差异（`AF-007` 的 flaky 判定纪律面）。
    - 二值边界：环境失败保持 environment blocked/deviation；`fake`/`simulation`/
      `plan` 不因 drill 而升级为 `realHardware` 或平台支持。
  - **Drill row shape:closed。**每个案例一行/一节，恰含六列语义：
    ① 最早触发阶段（proposal / design / readiness / implementation / review）；
    ② 命中的 `AF-NNN`（可多值，主 AF 置首）；
    ③ 会触发它的**具体模板字段**（取自 TASK-AFP-002 已合入的模板：
    `Applicable failure patterns` / `Production reachability` /
    `Trusted fact sources` / `## Authority and production reachability` /
    `Base` / `Input pins` / `Producer → consumer` / `Evidence currency`）；
    ④ 该字段会促成的**阻断/拆分/验证动作**；
    ⑤ 历史上**最终**发现该问题的证据（含完整 40-hex merge OID）；
    ⑥ 事实/推断标注——"若当时有该字段会更早发现"属 **inference**，必须显式标注，
    不得写成既成事实。
  - **Hindsight-bias 边界:binary。**drill 不得声称任何历史 change/task/AC 结论因本
    演练而改变；不得重新验证产品或硬件；不得把"更早发现"表述为"当时应当被发现"
    之外的更强主张；不得对未被 pin 的记录下结论。任一处违反即 `AFP-DRILL-001` fail。
  - **r1 登记的 upstream 缺陷:已闭环（r2 更新）。**r1 曾登记一条 fail-closed 指针：
    design §3.2 的 `AF-014` 把 TR-002R 第四条 gap 写作 "`TraceProgressTotal.reliable`
    作为 public case 绕过 capability 门"，而 `TraceProgressTotal` 在仓内不存在。
    该指针已由两个独立载体闭环，**不再是 drill 的开工障碍**：
    - **design 侧**：CHG-2026-029 revision r3（#371 合入
      `b53db548197486bd58d9236e183632c744f5276e`）在事实原位把四条 gap 逐条钉到一手
      出处（`chg-2026-021/tasks.md` 二值门 ①/④ 与 `TASK-TR-002R/run.md`），并保留
      r2 勘误记录；真实字段名为 `TraceCatalogContracts.swift` 的
      `reliableByteTotalAvailable`。
    - **手册侧**：TASK-AFP-004（实现 #374 合入
      `21d339b97d083f1e79c1851854737d5cf0a68d8e`）对全部 37 条 `Fact` 做一手复核，
      33 `supported` / 3 改写 / 1 删除；`AF-014` 的相关表述已对齐一手出处。
    **对 drill 的现行要求（保留 r1 的实质约束）**：仍以 pinned 一手记录为准；
    引用 `AF-014` 时以**本 r2 所钉的** design/手册 blob 为准，不得引用 r2/r1 时期的
    历史措辞。若 drill 期间再发现同类缺陷，仍按本任务 Notes 的 fail-closed 条款
    只记指针、不在本任务修复。
  - **可选覆盖（不构成新验收条件）。**design §5 r2 补充允许追加执行/验证轴案例
    （推荐 `AF-012` 的 CHG-2026-016 attempt-4 heredoc 窗口损耗、`AF-014` 的
    TR-002R 四 gap）。追加与否不影响"六案例 + 至少一个环境反例"这一二值门。
  - **Environment/concurrency gate:satisfied。**纯 host-side document review，零硬件、
    零 HDC/device/network/effect dispatch，零产品执行。本任务 allowed paths 仅本
    change `evidence/**` 与 `tasks.md`，与任何其他 change 的授权面零交集；audit 时
    GitHub open PR = 0。若实现期间出现同路径 PR、canonical conflict、secret/privacy
    风险或需要修改 forbidden path，任务立即回到 `blocked`。
  - **Verification/evidence gate:binary。**implementation/evidence PR 必须交付 drill
    run 与 `tasks.md` 本任务 evidence 引用，但不得翻 `ready→done`；run 至少记录：
    六案例 + 至少一个环境反例逐行六列齐全、每行的 AF ID 存在于已合入手册的
    `AF-001`…`AF-018`、每行引用的模板字段存在于已合入模板、全部 evidence 相对
    链接解析、完整 40-hex OID 复核、`Fact`/`Inference` 分离、hindsight-bias 边界
    扫描（历史结论改写 = 0、产品/硬件重新验证声明 = 0、fake→realHardware 升级 = 0）、
    `changes/archive/**` diff = 0、allowed/forbidden path audit、
    `scripts/check-sdd.sh` 0 error/0 warning/111 acceptance IDs 与 `git diff --check`
    PASS。任何一项失败即不形成 `AFP-DRILL-001` PASS。
  - **Review boundary。**本 readiness PR 只修改本文件的 AFP-003 本节，将 AFP-003
    `blocked→ready` 并登记 pins/case-set/counterexample/row-shape/gate；零 drill、零
    implementation、零 evidence、零手册/模板改动、零 archive/历史改写。
    implementation/evidence 与后续 `ready→done` 各自使用独立 PR；本 readiness merge
    不构成 `AFP-DRILL-001` PASS 或 change `verified`。
  - **Currency 复核（2026-07-23，r2）。**上表全部 blob 与 commit 于 audit base
    `7d04c3dccb598a5e1a1d3b16846162353069dbf2` **由脚本逐项重取**，非从 r1 转抄；
    r1 中未受 r3/AFP-004 影响的 pin 重取后与 r1 值一致，受影响的五枚（手册 +
    本 change 四文档）已更新。
    **provenance 复核方式变更（如实记录）**：r1 时六个案例的承载 merge OID 曾逐个
    经 `gh pr view` 复核；TASK-BAP-003 凭据分离（#375/#376）生效后 Agent 环境已无
    维护者 `gh` 凭据，本 r2 改用 `git merge-base --is-ancestor` 验证全部承载 OID 仍在
    protected `main` 的 ancestry 中，并逐项复核 blob。**"该 PR 由维护者 APPROVED"
    这一层本 r2 未独立验证**，由维护者 review 时确认。
    开工前须再次对最新 protected `main` 复核，漂移即停止。
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

### Evidence（candidate；不构成状态翻转）

- implementation + evidence run:
  [`evidence/runs/TASK-AFP-003/run.md`](evidence/runs/TASK-AFP-003/run.md)
  （2026-07-23，base `cfab930722afe60ed5e8759ea0c91d7a178971cc`）。
- 覆盖：readiness r2 钉定的六个历史案例逐行六列齐全（`AF-001`/`AF-002`+`AF-010`/
  `AF-003`+`AF-014`/`AF-004`/`AF-008`+`AF-015`/`AF-009`+`AF-017`），主环境反例 =
  RKFUI-001 E0 quarantine blocker（typed `toolBlocked(quarantinePresent)`、零子进程、
  未清除 quarantine、未提权，记为 BLOCKED），备用反例 = `/private/tmp` flaky 纪律面；
  另按可选覆盖追加 `AF-012` 一例作为方法示范。
- 二值门实测：开工前 carrier 28/28 无漂移；引用的 12 个 AF ID 全部存在于已合入手册、
  6 个模板字段全部存在于已合入模板；OID 全部在 ancestry；列 ④ 与"会更早发现"整体
  显式标注为 `Inference`；hindsight-bias 扫描（历史结论改写 / 产品硬件重新验证 /
  fake→realHardware）三项均为 0；archive、手册、模板 diff = 0；check-sdd 0/0/111。
- 任务状态保持 `ready`；`AFP-DRILL-001` 的 PASS 结论待维护者在独立 `ready→done` PR
  中确认。

### Notes / handoff

- 演练结果若发现当前 active task 的现实缺陷，只记录指针并 fail closed；不得在 AFP-003
  allowed paths 外顺手修复。

## TASK-AFP-004 — 手册 `Fact` 断言的一手核对与更正

- Status:done（2026-07-23；仅在维护者 review/merge 本独立状态 PR 后生效。
  implementation + evidence PR #374 已合入 protected `main`，merge OID
  `21d339b97d083f1e79c1851854737d5cf0a68d8e`；手册于该 merge 的 blob 为
  `3aab3c3fd6c7cf9e80ab4831b60ac58588d5d431`，与实现 PR head
  `2e52fdd3f681f428f180c881fc2b3bd778774a76` 的交付 blob **逐字一致**。
  done 不等于 change `verified`：`AFP-CORRECT-001` 的最终结论仍需 change 级
  verify PR 由维护者确认。）
- Done recheck（在**合入版** `21d339b97d083f1e79c1851854737d5cf0a68d8e` 上重跑，
  非沿用实现 PR 的结论）：
  - Invariants 零变化：`AF-001`…`AF-018` ID 集合完整；H3 = 144 且八字段同序；
    `Automation status` 18 项取值合法；positive 18 + negative 18；
  - 复核结果落地：`Fact` = 36、`Inference` = 18（与 run 的 37→36 处置一致）；
    四处已删/改表述（"分类不一致"、`rawValue`、"依次暴露"、"工作树占用"）残留 = 0；
  - `Currency` 18/18 记本次基线 `e48673fbe8c8440d7e12dbfe6aea5e94f996a4e2`；
  - 引用：链接 98 条全解析（含 56 anchor）；OID 21 枚全在 ancestry；
  - 符号级复扫：仅余 `partiallyMechanized`/`semanticReview`，即本 change 自定义的
    `Automation status` 取值域（r3 已确认该边界）；
  - `scripts/check-sdd.sh` 0 error / 0 warning / 111 acceptance IDs。
- Provenance 复核边界（**如实记录**）：本次复核在 TASK-BAP-003 凭据分离
  （#375/#376）生效后进行，Agent 环境已不具备维护者 `gh` 凭据，因此**无法**以
  `gh pr view` 读取 #374 的 reviews/mergedBy。可由 Agent 直接验证的是：merge commit
  `21d339b9…` 在 protected `main` 的 ancestry 中、其 committer 为 GitHub、author 为
  `github-actions[bot]`，且合入版交付物 blob 与实现 head 逐字一致。**"由维护者
  APPROVED"这一点本次未经 Agent 独立验证**，由维护者在 review 本状态 PR 时确认。
- Readiness（r1，base = protected `main`
  `b53db548197486bd58d9236e183632c744f5276e`）：
  - **Approval/dependency gate:satisfied。**approval-only #347 合入
    `813361830593f416eb845f0cceb9556ab51168be`；revision r3 #371 合入
    `b53db548197486bd58d9236e183632c744f5276e`（`revision: 3` 已在 protected `main`
    生效，本任务与 `AFP-CORRECT-001` 随之登记）。**前置 ②**：TASK-AFP-001 实现 #360
    合入 `95dc61cf6ed9223f5b5c1728aaf0d9a1ba6c9d5c`、done #362 合入
    `4c8506a30afc5505230134903ccf03729a640c07`，手册已在 protected `main` 上。
    AFP-002 `done`、AFP-003 `ready` 均不构成本任务依赖。
  - **Base/input pins。**以下是真实 `yaml pins` carrier，全部于本 base 由脚本枚举
    并实测取值（非手抄）。implementation 开工时必须基于本 readiness 合入后的最新
    protected `main`，逐项确认路径仍解析到 exact blob、commit 仍在 ancestry 中。
    任一漂移、路径删除/重命名或被引用结论被后续记录 supersede，立即停止并重新
    readiness；完整 hash 只证明固定引用，不自行证明内容正确或获得批准。

    ```yaml pins
    - artifact: TASK-AFP-004 readiness audit base
      commit: b53db548197486bd58d9236e183632c744f5276e
    - artifact: CHG-2026-029 revision r3 merge
      commit: b53db548197486bd58d9236e183632c744f5276e
    - artifact: CHG-2026-029 approval merge
      commit: 813361830593f416eb845f0cceb9556ab51168be
    - artifact: TASK-AFP-001 done status merge
      commit: 4c8506a30afc5505230134903ccf03729a640c07
    - path: openspec/planning/agent-failure-patterns.md
      blob: 5b8c3b6b26b76893744aa11bdd7618318eab4674
    - path: openspec/changes/archive/2026-07-21-chg-2026-001-macos-m0a/evidence/runs/TASK-M0A-003/run.md
      blob: 7fc3ab1d4fd3b2000b74ea04b0356d9a6c56fce6
    - path: openspec/changes/archive/2026-07-21-chg-2026-002-macos-m1-infrastructure/evidence/runs/TASK-M1-009/review-remediation-2026-07-18.md
      blob: f615d3fabb42450621e05aa1daa5b837906f41d3
    - path: openspec/changes/archive/2026-07-21-chg-2026-002-macos-m1-infrastructure/evidence/runs/TASK-M1-009/review-remediation-round-2-2026-07-18.md
      blob: 309a7f39f5befd20f3df93f95dcc42b3c02cf975
    - path: openspec/changes/archive/2026-07-21-chg-2026-002-macos-m1-infrastructure/evidence/runs/TASK-M1-009/review-remediation-round-3-2026-07-18.md
      blob: 8911811f11710ab1692b5ae834b21dfe020ea56e
    - path: openspec/changes/archive/2026-07-21-chg-2026-002-macos-m1-infrastructure/evidence/runs/TASK-M1-009/review-remediation-round-4-2026-07-18.md
      blob: e336f498db72ba4c7a4abcd4303d595e152bcb2a
    - path: openspec/changes/archive/2026-07-21-chg-2026-002-macos-m1-infrastructure/tasks.md
      blob: 2ea2ba6672b03f7ab6a86a6a7b136c5d531d9ac9
    - path: openspec/changes/archive/2026-07-21-chg-2026-009-dayu200-partition-decode/evidence/runs/TASK-PD-002/platform-attempt-2026-07-20.md
      blob: e0f3b1b77f54b4b7cb1ff17c39316e8e70c29179
    - path: openspec/changes/archive/2026-07-21-chg-2026-016-dayu200-recovery-rehearsal/evidence/runs/TASK-RH-001/rehearsal-attempt-4-2026-07-21.md
      blob: 6af1a69bea454251bac9a16ba26e58f2483702da
    - path: openspec/changes/archive/2026-07-21-chg-2026-020-dayu200-real-flash/evidence/runs/TASK-RF-002/run.md
      blob: 8869ad61b9ebf6e5397e7e6007318e11cb26429d
    - path: openspec/changes/archive/2026-07-22-chg-2026-015-hdc-readonly-probe-registration/proposal.md
      blob: b09301e257619d176c6adb0530847d499e97b6e6
    - path: openspec/changes/chg-2026-006-dayu200-m0b-bringup/tasks.md
      blob: 779ff6ac060ab7ba82ddaf955b65702ec52285db
    - path: openspec/changes/chg-2026-008-ui-dump-hidumper-wrapper/evidence/runs/TASK-UD-REDACTOR-001/run.md
      blob: 172ea48fba64819d0bf0743816323b8da68b6ec3
    - path: openspec/changes/chg-2026-008-ui-dump-hidumper-wrapper/tasks.md
      blob: abaee6a12290108f4daeac9f84a3ff6700971433
    - path: openspec/changes/chg-2026-021-trace-adapter-capture/design.md
      blob: 219c2812a321030bdd7a81517150ccc7fac755ab
    - path: openspec/changes/chg-2026-021-trace-adapter-capture/evidence/runs/TASK-TR-001/run.md
      blob: 6069642a7b3c13d741383fbbdd17a0f921c6b9f2
    - path: openspec/changes/chg-2026-021-trace-adapter-capture/tasks.md
      blob: 14703a488170143e02b15d3ae496d23cf390864e
    - path: openspec/changes/chg-2026-022-hdc-supervisor-observability/proposal.md
      blob: 63fa348e8f08276d17b1655532714d5da3a67482
    - path: openspec/changes/chg-2026-022-hdc-supervisor-observability/review.md
      blob: d03118ab83cbeb278910c08e55573094edbd5169
    - path: openspec/changes/chg-2026-025-ai-native-unattended-device-ops/review.md
      blob: 197e4adc47f75444a54eefadf00e58b4681e5202
    - path: openspec/changes/chg-2026-026-macos-rockchip-flash-ui/evidence/runs/TASK-RKFUI-001/hermetic-contract-test-2026-07-22.md
      blob: 659f99f470cea5f03984de6ea28ce1395e391287
    - path: openspec/changes/chg-2026-026-macos-rockchip-flash-ui/evidence/runs/TASK-RKFUI-001/run.md
      blob: 0f24bb2424e43edb34de0fffaa0eee3c4e5cbec3
    - path: openspec/changes/chg-2026-026-macos-rockchip-flash-ui/verification.md
      blob: f4aea707ded798680aacb7811a4786247a94dac8
    - path: openspec/changes/chg-2026-028-guard-ci-mechanization/evidence/runs/TASK-MECH-001/run.md
      blob: f5e51fad2f2a429748126eee27ab61df282c2f23
    - path: openspec/changes/chg-2026-028-guard-ci-mechanization/proposal.md
      blob: 2395c2b6f4624d806c2b88cb8769a9a0a5326253
    - path: openspec/planning/backlog.md
      blob: fc20c3de0187f3f4b4a7e60129163c33a6d1c6c3
    - path: openspec/planning/postmortem-2026-07-governance.md
      blob: 308d260be9d545b8e27d20a6a30e0719cd76fd19
    - path: openspec/changes/chg-2026-029-agent-failure-prevention/design.md
      blob: fd3d21147fd75ecc9543222d567aefae351171f5
    - path: openspec/changes/chg-2026-029-agent-failure-prevention/proposal.md
      blob: c0ac4b1dbe331abcad38c6b05a1287cede8af9fe
    - path: openspec/changes/chg-2026-029-agent-failure-prevention/verification.md
      blob: 075f6177b5cdbd0207ef27e93b4d257fb3971d77
    - path: openspec/changes/chg-2026-029-agent-failure-prevention/acceptance-cases.yaml
      blob: 54963daaac8302ee5900024780c9dd7b3a9b3814
    - path: AGENTS.md
      blob: 3c2d3c6a01d3eaa31cd9e3ee333f3153552f4164
    - path: openspec/constitution.md
      blob: 137d09da7eaa535670a8bd3b0c9537681e6cb21b
    - path: openspec/governance/enforcement.md
      blob: e8ff3c130e1b8b15f8405d150ad567e774a0d82b
    - path: openspec/verification/policy.md
      blob: ef3b42085ff50b54f1bb70650510f27bdc020cf1
    ```

  - **Audit inventory:closed。**待核对象 = 手册 `Observed cases` 中标注为
    `**Fact` 的**全部 37 行**，按项分布（脚本枚举，实现时须复现同一计数）：
    `AF-001` 2、`AF-002` 1、`AF-003` 2、`AF-004` 2、`AF-005` 2、`AF-006` 2、
    `AF-007` 2、`AF-008` 2、`AF-009` 1、`AF-010` 3、`AF-011` 3、`AF-012` 2、
    `AF-013` 2、`AF-014` 2、`AF-015` 2、`AF-016` 2、`AF-017` 2、`AF-018` 3。
    其中 **32 行含内联出处链接**，**5 行无内联链接**（依赖同项上文或共用 pinned
    bytes）——这 5 行必须在复核矩阵中显式补出其一手出处，不得以"上文已给"略过。
    一手出处文件共 **26 个**，全部在上表 pin 中。
  - **Audit method:binary。**每条 `Fact` 逐条执行，缺任一列即该行不通过：
    ① 定位其一手出处（相对路径 + 完整 40-hex blob OID，取自上表）；
    ② 在该出处的 bytes 中定位支持该表述的具体位置（行号或可检索片段）；
    ③ 判定 `supported` / `unsupported` / `partially-supported`；
    ④ 处置——`supported` 保留原文；`unsupported`/`partially-supported` 二选一：
    改写为该出处能支持的表述，或整行降级标注为 `**Inference.**`；
    ⑤ 记录判定依据（为何该片段支持/不支持该表述）。
    **禁止**以本 change 自身的 `design.md`/`proposal.md` 转述、会话记忆或跨会话
    摘要充当出处——该来源正是 r3 所修缺陷的成因（`AF-016`）。
  - **Inference 行处理:bounded。**`Inference` 行**只检查是否被误写成 `Fact`**；
    不因本任务扩写、删改或补证。发现 `Inference` 被误标为 `Fact` 时按上述 ④ 处置。
  - **Invariants:binary（零变化）。**`AF-NNN` ID 集合（恰 `AF-001`…`AF-018`，
    不新增不删除不复用）、taxonomy 归属与两轴划分、八字段契约与其顺序、
    `Automation status` 取值域（`mechanized`/`partiallyMechanized`/`semanticReview`）、
    首屏 non-normative/authority/conflict/privacy/archive 声明——**全部零变化**。
    本任务只改 `Observed cases` 内的表述与必要的 `Currency` 行。
  - **符号级复扫:binary。**实现后复跑 r3 起草期的符号级扫描：手册内出现的代码
    符号必须能在仓内（手册与本 change 之外）解析；不可解析即 fail。r3 已确认基线
    为"手册 `Fact` 行只引文件名、零代码符号"，本任务不得引入新的不可解析符号。
  - **Currency 更新。**手册 18 项的 `Currency` 行统一更新为本次复核的完整 base OID
    与日期；原 audit base `de6b79aafa95700297a94dc311e94b1283f8abdd` 的记录不追溯
    改写，按 `AF-005` 在事实原位更新当前值。
  - **Environment/concurrency gate:satisfied。**纯 host-side document review，零硬件、
    零 device/network/effect dispatch。手册面并发已核：TASK-AFP-001（唯一曾持
    该路径授权的任务）为 `done`；TASK-AFP-003（`ready`）的 allowed paths 仅本 change
    `evidence/**` 与 `tasks.md`，**不含手册**，故本任务对手册持唯一 live 授权。
    audit 时 GitHub open PR = 0。若实现期间出现同路径 PR、canonical conflict、
    secret/privacy 风险或需要修改 forbidden path，任务立即回到 `blocked`。
  - **Verification/evidence gate:binary。**implementation/evidence PR 必须交付手册更正、
    本任务 run 与 `tasks.md` 本任务 evidence 引用，但不得翻 `ready→done`；run 至少
    记录：37 行复核矩阵无遗漏（含 5 行无内联链接者）、每行五列齐全、invariants 全部
    零变化的实测证据、符号级复扫通过、`Inference` 未被误标统计、相对链接与 anchor
    全解析、`changes/archive/**` 与 `openspec/templates/**` diff 为 0、
    allowed/forbidden path audit、`scripts/check-sdd.sh` 0 error/0 warning/
    111 acceptance IDs 与 `git diff --check` PASS。任何一项失败即不形成
    `AFP-CORRECT-001` PASS。
  - **Review boundary。**本 readiness PR 只修改本文件的 AFP-004 本节，将 AFP-004
    `blocked→ready` 并登记 pins/inventory/method/invariants；零手册改动、零
    implementation、零 evidence、零 archive/历史改写。implementation/evidence 与后续
    `ready→done` 各自使用独立 PR；本 readiness merge 不构成 `AFP-CORRECT-001` PASS
    或 change `verified`。
  - **Currency 复核（2026-07-23）。**上表全部 blob 与 commit 于 audit base
    `b53db548197486bd58d9236e183632c744f5276e` **由脚本枚举并实测取值**，非从既往
    readiness 或起草期勘察转抄；`chg-2026-021/tasks.md` 的当前 blob 与 AFP-001 r2
    carrier 所钉值不同（TR-003 done PR `#367` 向该文件追加状态所致，无删除），
    本表采用**当前**值。开工前须再次对最新 protected `main` 复核，漂移即停止。
- Platform:macos（过程文档跨平台可复用，零平台产品行为）
- Requirements/AC:change-local `AFP-CORRECT-001`
- Depends on:revision r3、TASK-AFP-001 done、independent readiness
- Applicable failure patterns:`AF-016`（本任务修复的正是该模式的一次复发）、
  `AF-015`（要求全量复核而非只改发现点）、`AF-005`（在事实原位更正而非文末注记）
- Production reachability:not applicable；纯文档更正，零产品 effect、零 dispatch
- Trusted fact sources:每条 `Fact` 所引 pinned 一手记录的仓内 bytes；**会话记忆、
  跨会话摘要与本 change 自身的 design/proposal 转述均不作为事实源**（design 转述
  正是本次缺陷的来源）
- Allowed paths:`openspec/planning/agent-failure-patterns.md`、
  `openspec/changes/chg-2026-029-agent-failure-prevention/evidence/**`、
  `openspec/changes/chg-2026-029-agent-failure-prevention/tasks.md`（仅本任务状态/evidence 引用）
- Forbidden paths:`AGENTS.md`、`openspec/constitution.md`、
  `openspec/governance/**`、`openspec/specs/**`、`openspec/contracts/**`、
  `openspec/changes/archive/**`、`openspec/templates/**`、产品 source/tests/scripts/workflows
- Risk:low（风险是把可支持的表述误删、或把更正写成 taxonomy 变更）
- Hardware required:no

### Deliverables

- 对手册 `AF-001`…`AF-018` 的**全部** `Fact` 行逐条一手复核；
- 凡不能由其 pinned 一手出处支持的具体表述：改写为可支持的表述，或降级标注为
  `Inference`；两种处置都要在 evidence 中给出该行的一手出处与判定依据；
- `Inference` 行只检查是否被误写成 `Fact`，不因本任务扩写；
- `AF-014` 的第四条 gap 表述按 design §3.2（r3 更正版）对齐到一手出处；
- 手册的 `Currency` 行更新为本次复核的 base OID 与日期。

### Verification

- `AFP-CORRECT-001` document review；
- 复核矩阵：每条 `Fact` → 一手出处（相对路径 + 完整 40-hex OID）→ 支持/不支持
  → 处置（保留/改写/降级），无遗漏行；
- 不变量：`AF-NNN` ID 集合、taxonomy 归属、八字段契约、`Automation status` 取值域
  与两轴划分**零变化**；ID 不新增不删除；
- 符号级扫描复跑：手册内出现的代码符号必须能在仓内（手册与本 change 之外）解析；
- `scripts/check-sdd.sh` 与 `git diff --check`，archive 与模板 diff 为零。

### Evidence（candidate；不构成状态翻转）

- implementation + evidence run:
  [`evidence/runs/TASK-AFP-004/run.md`](evidence/runs/TASK-AFP-004/run.md)
  （2026-07-23，base `e48673fbe8c8440d7e12dbfe6aea5e94f996a4e2`）。
- 复核结果：37 条 `Fact` 全数核对 → 33 `supported` / 3 `partially-supported`
  （F07/F09/F14 改写）/ 1 `unsupported`（F36 删除，无任何一手出处）；`Fact` 37→36，
  `Inference` 18 行无误标。四行的共同来源均为跨会话记忆而非 pinned bytes，
  与 r3 所修 `AF-014` 缺陷同源（`AF-016`）。
- 二值门实测：开工前 carrier 39/39 无漂移；ID 集合/八字段契约/`Automation status`
  取值域/两轴划分零变化；positive 18 + negative 18；符号级复扫仅余本 change 自定义
  取值域；链接 98 条全解析（含 56 anchor）；OID 21 枚全在 ancestry；
  archive 与模板 diff = 0；check-sdd 0/0/111；`git diff --check` 干净。
- 任务状态保持 `ready`；`AFP-CORRECT-001` 的 PASS 结论待维护者在独立
  `ready→done` PR 中确认。

### Notes / handoff

- 本任务只更正表述，不重新验证被引用 change 的任何结论，也不改变其 task/AC 状态；
- 若某条 `Fact` 的一手出处显示被引用 change 本身有现实缺陷，只记录指针并 fail closed，
  交回该 change 处理，不在本任务修复；
- 实现/evidence PR 不翻 task 状态；`ready→done` 使用独立 PR。

## TASK-AFP-005 — 手册 archive 断链收口

- Status:ready（2026-07-23 D1 readiness r1；仅在维护者 review/merge 本独立 PR 后
  生效。三前置全部闭合：① revision r4 已生效；② TASK-AFP-001 done 与 TASK-AFP-004
  done；③ 本 readiness 钉定手册 blob、待改行与改法。merge 前不得开
  implementation/evidence PR）
- Readiness（r1，base = protected `main`
  `d53da289b7da80a4ee2282f5dea3122ebf97325a`）：
  - **Approval/dependency gate:satisfied。**revision r4 #387 合入
    `d53da289b7da80a4ee2282f5dea3122ebf97325a`（`revision: 4` 与本任务、
    `AFP-LINK-001` 均已在 protected `main` 生效）。TASK-AFP-001 done #362 合入
    `4c8506a30afc5505230134903ccf03729a640c07`；TASK-AFP-004 done #379 合入
    `605bff09fdc992478203109b1e5414b207d553b3`（手册最近一次授权改动者）。
    AFP-002/003 已 done，不构成本任务依赖。
  - **Base/input pins。**以下是真实 `yaml pins` carrier，于本 base 实测取值。
    implementation 开工时必须基于本 readiness 合入后的最新 protected `main`，逐项
    确认路径仍解析到 exact blob、commit 仍在 ancestry 中；任一漂移立即停止并重新
    readiness。

    ```yaml pins
    - artifact: TASK-AFP-005 readiness audit base
      commit: d53da289b7da80a4ee2282f5dea3122ebf97325a
    - artifact: CHG-2026-029 revision r4 merge
      commit: d53da289b7da80a4ee2282f5dea3122ebf97325a
    - artifact: TASK-AFP-001 done status merge
      commit: 4c8506a30afc5505230134903ccf03729a640c07
    - path: openspec/planning/agent-failure-patterns.md
      blob: 3aab3c3fd6c7cf9e80ab4831b60ac58588d5d431
    - path: openspec/changes/chg-2026-029-agent-failure-prevention/design.md
      blob: fd3d21147fd75ecc9543222d567aefae351171f5
    - path: openspec/changes/chg-2026-029-agent-failure-prevention/proposal.md
      blob: 821794ee769d4f406b78616358fcaaa58e9041c9
    - path: openspec/changes/chg-2026-029-agent-failure-prevention/verification.md
      blob: 84e8f4aed003244ebc48582429175ec468272958
    - path: openspec/changes/chg-2026-029-agent-failure-prevention/acceptance-cases.yaml
      blob: 7329d640e772b12e577c32e8d4dc00a3854b661d
    - path: AGENTS.md
      blob: 3c2d3c6a01d3eaa31cd9e3ee333f3153552f4164
    - path: openspec/constitution.md
      blob: 137d09da7eaa535670a8bd3b0c9537681e6cb21b
    - path: openspec/governance/enforcement.md
      blob: e8ff3c130e1b8b15f8405d150ad567e774a0d82b
    - path: openspec/verification/policy.md
      blob: ef3b42085ff50b54f1bb70650510f27bdc020cf1
    ```

  - **待改行:closed（恰一处）。**手册第 24 行：

    ```text
    [CHG-2026-029 design §3](../changes/chg-2026-029-agent-failure-prevention/design.md)：
    ```

    这是手册中**唯一**指向本 change 目录的相对路径引用（`git grep` 于
    `openspec/planning/**` 命中 1 处，实测）。
  - **改法:closed。**改为**不含相对链接**的纯文本指向，保留三项事实：
    ① change ID `CHG-2026-029`；② 章节 `design §3`；③ 一个不随目录移动而失效的
    定位锚——采用**完整 40-hex merge OID**（r4 merge
    `d53da289b7da80a4ee2282f5dea3122ebf97325a`，taxonomy 现行版本所在）。
    禁止改法：改指向 `changes/archive/<date>-<id>/`（每次归档都要再改手册，把一次
    性问题变成周期性负担）；删掉整句事实指向；把 §3 内容复制进手册（会制造第二
    份 taxonomy 正本，违反 design §1 的 non-normative 边界）。
  - **不动面:binary。**其余 **24 条**指向**其他活跃 change** 的相对链接与 **10 条**
    指向 `changes/archive/**` 的链接**逐字不动**（实测 35 条 = 10 archive + 25
    active，其中 1 条为本 change）；`AF-NNN` ID 集合、taxonomy 归属与两轴划分、
    八字段契约与顺序、`Automation status` 取值域、首屏五项声明、`Fact`/`Inference`
    标注与 positive/negative 各 18 的计数——**全部零变化**。
  - **Verification/evidence gate:binary。**implementation/evidence PR 必须交付手册
    改动、本任务 run 与 `tasks.md` evidence 引用，但不得翻 `ready→done`；run 至少
    记录：`git grep 'chg-2026-029-agent-failure-prevention'` 于
    `openspec/planning/**` 命中 **0**；三项事实指向仍在；上述不动面逐项零变化的
    实测；手册链接总数由 35 变 34 且减少的恰为本 change 那 1 条；
    `openspec/templates/**`、`changes/archive/**` 与
    `openspec/changes/chg-2026-027-decision-grading-batch-approval/**` diff 为 0；
    `scripts/check-sdd.sh` 0/0/111 与 `git diff --check` PASS。
  - **Dated 注记（2026-07-23）——r4 发现 2 的现状更新，不改写 r4 原文。**r4 登记
    CHG-2026-027 TASK-BAP-002 的 pin 漂移时，尚不知该 lane 已自行处理。经本 readiness
    起草期在 `origin/main` `d53da289…` 实测复核，准确现状为三点：
    ① 该 lane 已于 readiness **r3**（#386 合入
    `00bbc5a…`）识别漂移（其触发事实明确列出本 change 的 #383/#384）并在**散文**中
    重钉为 `dc8129773d18349b7e7d5123ce2fa8beefb80b7d`；
    ② 但其 **`yaml pins` carrier 未同步**，`tasks.md:157-158` 仍为
    `bbbda9b9f2ebefbe9b360fe2cade4e70712ed724`——同一份 readiness 内散文与机器可读
    载体两值并存（MECH-003 只校验 hash 形状不校验解析结果，故 guard 不报）；
    ③ 该散文值此后又被本 change 的 r4（#387）打漂，当前实际为
    `6211712d85bd719b7384769f8788a745d7249c21`。
    **处置不变（fail closed）**：该目录在本任务 forbidden paths 内，本 change 不修复
    不改写，已按 r4 决定通知 CHG-2026-027 lane；**chg-029 的 archive PR 仍须待该
    carrier 条目被重钉或解除后方可起草**。另据该 lane r3，`CHG-2026-029 verify` 已被
    指定为其批次演练**候选 2'**，且要求候选 PR 留在 open 队列按 digest 顺序合并——
    本 change 起草 verify PR 时须遵守该节奏，不催合。
- Platform:macos（过程文档跨平台可复用，零平台产品行为）
- Requirements/AC:change-local `AFP-LINK-001`
- Depends on:revision r4、TASK-AFP-001 done、TASK-AFP-004 done、independent readiness
- Applicable failure patterns:`AF-006`（archive 前引用扫描与断链即暂缓）、
  `AF-005`（在事实原位更正而非追加注记）
- Production reachability:not applicable；纯文档索引，零产品 effect、零 dispatch
- Trusted fact sources:`git grep` 对 protected `main` 的实测结果与被引用文件的仓内
  bytes；不以会话记忆或本 change 的 proposal 转述替代复扫
- Allowed paths:`openspec/planning/agent-failure-patterns.md`、
  `openspec/changes/chg-2026-029-agent-failure-prevention/evidence/**`、
  `openspec/changes/chg-2026-029-agent-failure-prevention/tasks.md`（仅本任务状态/evidence 引用）
- Forbidden paths:`AGENTS.md`、`openspec/constitution.md`、
  `openspec/governance/**`、`openspec/specs/**`、`openspec/contracts/**`、
  `openspec/changes/archive/**`、`openspec/changes/chg-2026-027-decision-grading-batch-approval/**`、
  `openspec/templates/**`、产品 source/tests/scripts/workflows
- Risk:low（风险是改法把事实指向一并删掉，或顺手动了其余 24 条活跃链接）
- Hardware required:no

### Deliverables

- 手册对**本 change 目录**的相对路径引用归零：第 24 行改为不依赖 change 目录位置
  的表述，保留"taxonomy 与其封闭范围登记在 CHG-2026-029 design §3"这一事实指向
  （可用 change ID + 完整 OID 或章节名，不用会随归档失效的相对路径）；
- 复扫证据：`git grep 'chg-2026-029-agent-failure-prevention'` 在
  `openspec/planning/**` 下命中数为 0；
- 其余 24 条指向**其他活跃 change** 的链接**逐字不动**，并在 run 中如实登记为
  已知限制与其归属（另立 change 处置）。

### Verification

- `AFP-LINK-001` document review；
- 不变量零变化：`AF-NNN` ID 集合、taxonomy 归属与两轴划分、八字段契约与顺序、
  `Automation status` 取值域、首屏 non-normative/authority/conflict/privacy/archive
  声明、`Fact`/`Inference` 标注与 positive/negative 方法数；
- 断链复核：模拟归档路径（`changes/archive/<date>-<id>/`）下手册对本 change 的引用
  不再存在可断项；
- 越界复核：手册对其他 change 的链接 diff 为 0；`openspec/templates/**`、
  `openspec/changes/archive/**` 与 chg-2026-027 目录 diff 为 0；
- `scripts/check-sdd.sh` 与 `git diff --check`。

### Notes / handoff

- 本任务**不**处理 r4 发现 2（CHG-2026-027 TASK-BAP-002 的 pin 漂移）：该 path 在
  本任务 forbidden paths 内，只由 r4 proposal 登记指针，交回 chg-027 lane；
- 本任务**不**处理其余 24 条活跃链接的结构性问题，另立 change；
- 实现/evidence PR 不翻 task 状态；`ready→done` 使用独立 PR；
- 本任务 done 后方可起草 change 级 verify；archive 仍须等发现 2 解除。
