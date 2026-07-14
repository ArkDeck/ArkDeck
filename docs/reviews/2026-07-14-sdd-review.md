# ArkDeck Plan / SDD 全面评审与修正报告

> 日期:2026-07-14
> 方法:11 个领域评审 agent 分域精读全部 plan/SDD 文档 + guard 脚本,108 条 findings 中 48 条经对抗性核实(要求核查员先为原设计辩护,再裁决);完整清单见 [附录](2026-07-14-sdd-appendix.md)。
> 核实结果:confirmed 14 · partial 30 · refuted 4。

## 一句话结论

产品规格层(constitution 的安全原则、9 个 capability spec、110 条 AC)质量高、跨文档一致性好,基本保留;**问题几乎全部集中在执行治理层**——一套为"多方互不信任、受监管"环境设计的密码学治理(ed25519 签名审批、仓库外身份账本、claim service、supersession barrier、三段式归档、约 12,900 行 guard),套在"单人维护者 + AI 执行 + 0 行产品代码"的现实上,不但是过度设计,而且**在自己声明的威胁模型下并不成立**,并已在上线 24 小时内自伤(治理事故)。已将其降级为 **git-native 模型**并修复了规格层的实质缺陷。

## 为什么原治理体系必须改(而非微调)

三条互相印证的证据,来自仓库自身:

1. **密码学对威胁模型零防护**(governance-trust-2/-5、guard-scripts-ci-1,均 confirmed)。三把审批私钥与运行 AI 的账户同机同 UID 可读,`ratify.py` 内置自动签名。核查员实测:用本机私钥可签发一份能通过 CI 验签的"人类 lvye 批准",内容任意。"Agent 无法自批准"这条整个体系的地基,在物理上不存在。

2. **身份账本的 append-only 属性是空的**(foundation-5、process-walkthrough-5,confirmed)。权威环境(CI)每次在临时 runner 上从空目录重建快照(revision 恒为 1、previous 恒为 null),签名 key 以 secret 注入 agent 分支可触发的 workflow。"跨 run 防历史改写"从未存在。

3. **它已经自伤**(planning-history-4/-7、governance-trust-3,confirmed)。ratify 当天为修 CI 两次原地重写了"已 accepted、永不重写"的 baseline,每次重写触发 ready packet 重钉,产生新的 identity→hash 映射——被账本记成 31 组"identity 碰撞",当作疑似密钥泄露级 P0,催生了一份 13 文件、约 5,500 行的恢复协议草案。而该恢复协议的验收边界(要求"独立 verifier 演示 append-only")单人几乎无法产出,等于把 execution gate 永久锁死。**事故完全由治理机制自身制造,0 行产品代码受影响。**

对抗核实的价值在这里体现:4 条被 refuted 的 finding(verification-policy-8/-10/-12、changes-8)证明,某些机制(如硬件证据必须由人产生、release gate 的逐能力覆盖等式)确有真实防线作用,不能一删了之;但核查员同时确认——它们的防伪核心(人执行、外部审查、计划字节绑定)用 git+PR 就能承载,昂贵的部分(签名服务、逐 cell hash、账本)是可去掉的包装。

## 已实施的修正

### 1. 治理:密码学链 → git-native(核心)

- 新信任模型([`governance/enforcement.md`](../../openspec/governance/enforcement.md) 重写):**受保护 main + 维护者 CODEOWNER PR review = 唯一信任根**;合并进 main 即人类批准;完整 git 历史即审计账本;CI 只做只读校验。真正补上的防线是**凭据分离**(Agent 用仅限 `agent/**` 的受限凭据)——这是 V1 忽略的唯一实质缺口。
- 删除:`openspec/approvals/`(15 个签名 JSON)、`governance/trust-policy.yaml`、`governance/verifiers/`(3 个)、`governance/trust-root-bundle.example.yaml`、13 文件的 `planning/recovery-bootstrap/` 与 `governance-recovery.md`、baseline 的逐文件 hash lock。字节级历史全部保留在 git 中。
- 事故与决策归档为一份 [postmortem](../../openspec/planning/postmortem-2026-07-governance.md)。

### 2. Contracts:删除 16 个运行时/治理 schema

删除为不存在的并发抢占/多方审计设计的执行期 schema:task-packet / task-claim / task-run / claim-owner-attestation / run-owner-attestation / resource-identity-attestation / approval / identity-ledger-snapshot / change-supersession-barrier / change-verification-result / lab-execution-plan / lab-execution-authorization / pre-archive-verification / pce-evidence-binding / platform-conformance-evidence / platform-release-subject。保留并重写 `hardware-evidence.schema.json` 为 V2 轻量版(人类操作者 + 物理确认 + 产物 hash)。产品契约(manifest / journal-event / workflow-step / provider-contracts / capability-registry / catalogs)全部保留——它们是真实的产品边界。

### 3. Guard:~12,900 行 → 一个 ~330 行只读检查器

`sdd_guard_*.py`(4 个巨型文件)、`ratify.py`、`relock_baseline.py`、`ledger_snapshot.py`、`guard_selftest.py`、`sdd_protected_set.py`、`check-json.py` 全部删除,换成 [`scripts/check_sdd.py`](../../scripts/check_sdd.py):校验 YAML/JSON 可解析且无重复 key、REQ/AC 唯一且每 Requirement 有 Scenario、三方 AC 集合精确一致、capability registry 与 specs 目录 1:1 且依赖闭包无环、change 必需 artifact 与状态合法、lock/conformance 引用的路径存在。**已通过(110 AC 三方一致),并经负向自测确认能对注入的违规报红。** CI([`sdd-guard.yml`](../../.github/workflows/sdd-guard.yml))简化为无 secret 的只读检查。

### 4. 规格层实质缺陷修复

- **REQ-JOB-001 状态机矛盾**(core-specs-1/process 双重 confirmed):`waitingForRecovery` 同时被"任意非终态失败即 finalizing→failed"和"只有两个出口"两条规则覆盖,自相矛盾。已把它加入排除名单,与散文一致。([spec](../../openspec/specs/workflow-journal-recovery/spec.md))
- **REQ-FLASH-015 / DUMP-003**:把 SDD 治理的实验室授权机制从产品规格里移除,改为"人类操作者亲自执行 + 物理确认"(core-specs-4);给 HiDumper 参数表加上"真机验证前不宣称兼容"的限定(core-specs-7)。
- **CHG-2026-003 立项前提造假**(changes-5、planning-history-3,confirmed):proposal 声称"DEC-001 selects DAYU200",而 DEC-001 实为 open。改为"DAYU200 是候选,本 change 产出决策输入",并同步 open-questions。
- **CHG-2026-002 自相矛盾**(changes-4,confirmed):声称排除全部 parserGolden 却包含 AC-HDC-005-01,已澄清范围。
- 全仓清除过期状态断言(gate closed/open、review candidate vs accepted 的冲突,foundation-1、verification-policy-1/2/4 等):constitution/README/enforcement/project/config/baseline/conformance/platform-lock 统一为 candidate + V2 表述。
- 三套并存的模板体系(templates/change + 两套 schemas/)合并为一套精简 change 模板(templates-schemas-3/4)。
- CHG-2026-001 保留为 approved(按维护者真实意图,不再依赖签名文件);M0A 七个任务重写为 tasks.md 单一事实源(替代 immutable packet)。

## 遗留人类动作项(我无法代做)

1. **删除/轮换** `/Users/Shared/arkdeck-trust/` 下三把私钥(曾与 Agent 同账户可读,视为已泄露);移除 GitHub secrets `ARKDECK_TRUST_BUNDLE`、`ARKDECK_LEDGER_KEY`。
2. **为 Agent 配置受限推送凭据**(仅 `agent/**` 分支的 fine-grained PAT / deploy key),使凭据分离落地——这是 V2 唯一依赖的新防线。
3. **`.claude/settings.json`** 的 allowlist 仍指向已删除的脚本(check-json/guard_selftest/python3.14);该文件受"agent 不得自改权限"保护,需你手动清理为只保留 `./scripts/check-sdd.sh` 与 `.venv-sdd/bin/python scripts/check_sdd.py`。
4. 待上述完成 + 规格评审修正合入后,**经一次 PR review 重新 ratify CORE-1.0.0**。

## 保留了什么(未过度删减)

constitution 的 12 条产品安全原则、9 个 capability spec 及 110 条 AC、传统 4 轴(Core/Integration/Platform/Conformance)版本分离的骨架、SDD 的 proposal→delta→tasks→verify→archive 生命周期、人类审批点——这些是健康的,只是把"用密码学证明"降级为"用 git + PR review 证明"。
