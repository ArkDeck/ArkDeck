# CHG-2026-027 Design:决策分级与批次审批

> Status:candidate(随 proposal r1;approve 前不构成实现授权)
> Core baseline:CORE-2.1.0(零 Core 变更)

## 0. 不变量(本 change 的硬边界)

1. **唯一信任根零改动**:受保护 main + 维护者 CODEOWNER review;合并进 main =
   批准。批次内的每一次合并仍是**逐 PR 批准**——批次改变的是人类的节奏,
   不是权威。
2. **无 auto-merge**:任何决策等级(含 D0)都不引入自动合并;"CI 绿 ≠ 批准"
   保持不变。
3. **digest 无批准语义**:digest 是导航/汇总物,维护者 review 的对象永远是
   PR 本身;digest 与 PR 内容不一致时以 PR 为准,漂移按 enforcement
   "PR 载体与内容一致"条款处置。
4. **POL-AGENT-001/002 零改动**;D* 分级作用于 PR/决策维度,与 CHG-2026-025
   的 E0/E1/E2 设备执行分级正交。
5. **宽度并行,零投机堆叠**:判断门(D1/D2)之后的成 PR 工作,在该门合入前
   不开工(§3)。
6. **fail closed**:合并状态不确定 → 守望循环保持暂停;批次中某项被拒 →
   其依赖链停止合并;拿不准分级 → 按更高等级处理。

## 1. 决策分级(D0/D1/D2)

对 PR 链中每个待人类合并的决策点分级。分级决定它在批次中的组织方式,
**不决定它是否需要人类合并**(全部需要)。

### D0 — 机器可判定状态推进

同时满足三条件:

- (a) 结论由 **main 已合入状态 + 确定性检查**(guard、测试套件、merged OID
  复核、引用扫描、hash/pin 比对)完全决定,不依赖新的人类判断;
- (b) diff **零新 scope、零新风险接受、零新授权**;
- (c) 不改变任何权威文件(constitution/specs/contracts/enforcement/AGENTS.md)
  的语义。

三条件缺一即非 D0;拿不准按 D1。封闭示例(现行链中的 D0 面):

- 任务 done 翻转(实现 PR 已合,复核 merged OID + 全量测试基线);
- change verify 翻转(全部 AC 证据已在 main,verification closure 只引用);
- archive(引用扫描通过,git mv + status 翻转);
- evidence rerun/复验记录追加;
- readiness pins 的无漂移复核记录(注意:**首次锁定 pins 的 readiness 本体是
  D1**,见下)。

### D1 — 人类判断

封闭列举(新增门类须经治理 PR 扩列):change approval、readiness(首次风险
接受 + pins 锁定 + 窗口/边界确认)、DEC-* 产品决策、ADR、Core delta 与
baseline ratification、proposal revision(r2+)、机制冻结例外、postmortem 定性。

### D2 — 物理与授权

设备窗口执行安排、standing authorization 的创建/修改/吊销、E1 per-device
capability evidence 的接受、凭据与权限配置变更。D2 项除维护者合并外通常还需
维护者仓外动作(物理操作、GitHub 设置),digest 须写明该动作。

### 分级的落点

分级记录在 digest 的 grade 字段与 PR body 注记;**不引入仓内状态字段**
(不加 front matter、不加 guard 校验面)——分级是组织约定,错分的后果由
逐 PR review 兜底,治理面不为它膨胀。

## 2. 批次审批协议

- **队列载体 = GitHub issue**(命名 `batch-YYYYMMDD-N`)。不用仓内文件:入队
  本身若要 PR 就自反了。审计正本永远是批次合并产生的逐 PR merge 记录
  (`(#N)` subject 惯例),issue 只是导航,close 即归档。
- **digest 字段**(模板由 TASK-BAP-002 交付):PR 编号/标题;grade(D0/D1/D2);
  所属 change/task;一句话内容;风险与影响面;证据指针(evidence/测试/复验);
  独立 AI 合前 review 结论(APPROVE 或发现清单指针);依赖关系与建议合并顺序;
  合并前置(如需 update-branch、如 D2 需仓外动作)。
- **入队门(三条全过才入队)**:CI 绿;独立 AI 合前 review APPROVE(实现与
  review 必须是不同会话,现行惯例成文化;无 APPROVE 不入队);digest 字段
  完整。
- **合并语义**:维护者按 digest 声明顺序逐 PR review/merge;**遇拒即停该
  依赖链**(被拒项的依赖项本轮不合),被拒项回炉走正常修复;无依赖关系的
  其余项可继续。
- **批准检测与续跑**:守望循环以 `gh` poll 合并状态(以 merge OID 确认,不以
  分支消失/时间推断);检测失败保持暂停。

## 3. 宽度并行原则(零投机堆叠)

批次吞吐来自**多 lane 并行**——不同 change 各自推进到各自的人类门,而不是
单 lane 越过判断门投机堆叠:

- D0 序列可同 lane 连续推进(实现合入后 done→verify→archive 本来就是机械
  序列,可在一个批次内按序排列);
- **D1/D2 门之后的成 PR 工作一律等该门合入再开工**。判断门的意义 = 维护者
  批准的是提案,不是既成事实;投机堆叠使批准失真,与 enforcement"PR 载体与
  内容一致"同根。
- 门后唯一允许的预跑:不产生 PR 的采集/勘察(如 readiness 前的 pins 采集、
  测试基线预跑),其结果在门合入后成 PR。

## 4. 守望循环形态(runbook 摘要,正文由 TASK-BAP-002 交付)

状态机:推进各 lane → lane 到人类门则产 digest 入队并切换 lane → 全部 lane
阻塞时产出批次汇总(更新批次 issue)通知维护者 → poll 检测合并 → rebase
(squash 惯例下 `rebase --onto`)→ 续跑。

- 运行载体 = AI 会话(harness /loop 或 scheduled task),**不是产品代码、
  不是 CI**;runbook 是会话操作约定,改版走 PR。
- 不引入新服务、新 bot、新凭据面;通知 = 批次 issue 本身 + 既有沟通渠道。
- 与合前对抗 review 的关系:reviewer 会话独立于实现会话;review 结论落在 PR
  (comment/ReportFindings),digest 只引用不复制。
- 并行会话规矩(worktree 隔离、commit 前查分支、别人报绿自己复验)全部沿用。

## 5. 凭据分离前置(TASK-BAP-003)

enforcement.md 信任模型第 3 条自 V2 建立即写明:"在凭据分离落实前,'Agent
无法自批'只是软约束——这是 V1 失效的直接教训"。该项悬置至今。无人值守化
直接放大此风险:人在环外的时间变长,软约束的暴露窗口随之变大。因此:

- BAP-003 是 **BAP-002(扩大无人值守吞吐)的硬前置**;
- 精确机制(GitHub ruleset 限制可 push ref 的 actor、deploy key、GitHub App
  等)由 BAP-003 readiness 钉定;AC 只验行为:agent 凭据推 `agent/**` 成功、
  推其他 ref 被拒,双向证据在案,凭据值零入仓;
- 顺带面(V1 私钥删除/轮换、GitHub secrets 清理)可同窗口执行但不属本任务
  AC,避免 scope 混装。

## 6. 与 guard/CI 机械化的关系(out of scope,伴随 change)

D0 的"机器可判定"当前由 guard + 独立 AI review + 维护者逐 PR review 共同
承载;以下四项机械化会持续降低其中的人工核验成本,各自独立立项,与本 change
无先后硬依赖:

1. CI 增加 macOS Swift build+test job(消除"guard 绿 ≠ Swift 绿"的人工核验);
2. guard 三方 revision 同步校验(proposal revision / acceptance
   change_revision / verification @rN;#129/#152/#275 漂移类);
3. guard 全 OID 引用格式校验(截断前缀类,#257/#267);
4. allowed-paths diff 校验(tasks.md 授权面机器可读化,校验实现 PR diff 落在
   授权面内;"载体与内容一致"的机械近似)。

顺序论证:先把分级与批次语义成文(本 change),机械化随后逐项挂接;反向
顺序会让机械门没有分级语义可挂。
