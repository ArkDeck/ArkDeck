---
id: CHG-2026-023-macos-auto-update
revision: 1
status: proposed # 本 propose PR 合入仅登记提案;批准须独立 approval-only PR(先例 #55/#89/#171/#195/#226/#253/#254)
class: platform
core_change_level: none
owner: lvye
core_baseline: CORE-2.1.0
platforms: [macos]
---

# macOS v1 应用内自动更新(DEC-004/ADR-0002 载体)

## Why

DEC-004(#261,decided)与 ADR-0002 把自动更新纳入 v1 更新渠道,并明确"选型/
XPC/签名链/隐私披露/网络面由独立 change 评估落地,verified 前手动公证 DMG 过渡"
——本 change 即该载体。既有输入:

- macos platform profile "Auto-update backlog" 节已固定安全基线:HTTPS、
  Developer ID/公证、archive **EdDSA** 签名与**私钥隔离**;Sparkle 2.9+ signed
  feed 须同时启用 `SURequireSignedFeed` 与 `SUVerifyUpdateBeforeExtraction`;
- ADR-0002 分发形态 = Sandboxed + 六 entitlement(`network.client` 已在集内);
  自动更新框架若需 XPC service 内嵌,附加 entitlement/签名面须显式声明批准,
  不得静默扩集;
- **供应链事实:本仓库当前零第三方依赖**。引入 Sparkle 将是首个外部依赖决策
  (license/SBOM/版本与 hash pin/依赖审计),与最小自研路线(appcast 检查 +
  DMG 下载 + 验签 + 引导安装)之间的取舍是本 change 的核心评估项;
- 隐私边界:更新检查是产品第一个合法出站网络调用;DEC-008(remote crash/
  telemetry)保持独立,更新检查不得夹带遥测。

## What changes(两任务分期;本 change 首 PR 只 proposal + design,零实现)

- **TASK-AU-001 — 更新机制评估与选型(documentReview,host-only)**:在
  {Sparkle 2(sandbox/XPC 模式), 最小自研(appcast JSON over HTTPS + DMG 下载 +
  代码签名/Team identity 验证 + 引导安装)} 间做有据选型。评估维度(全部落
  facts):sandbox/XPC 兼容性与所需 entitlement/签名面 diff;供应链面(依赖
  license/SBOM/pin/hash/审计成本 vs 自研维护成本);签名链 fail-closed(EdDSA
  feed 签名、下载物必须验签到同一 Developer ID Team,任一失败零安装动作);
  失败/回滚诚实性;隐私(更新检查请求携带的确切字段,零设备/用户标识)。
  产出选型决策记录,owner review/merge = 选型认可。
- **TASK-AU-002 — 实现与发布管线面(blocked 于 AU-001 done + readiness)**:按
  选型集成;更新检查默认频率与用户开关、显式同意后才安装(零静默安装);
  contract 测试覆盖验签 fail-closed 矩阵与隐私字段断言;发布侧 = feed/appcast
  生成与 EdDSA 私钥处理规程(**私钥永不入仓**,与 V1 治理教训一致);若引入
  XPC/entitlement 变化,同 PR 显式更新 ADR-0002 entitlement 集声明。

## Out of scope / Non-goals

- 远程 crash/telemetry(DEC-008 独立)、delta 更新、多渠道(beta/stable)分轨、
  MAS(ADR-0002 排除);
- 不改 Core spec/contract/schema;不动 ADR-0002 已定的分发形态本体;
- 首 PR 不引入任何依赖、不写实现、不产生 evidence。

## Approval and flow

V2 治理:本 propose PR 合入仅登记提案;批准须独立 approval-only PR;两任务各自
独立 readiness/实现/done PR。change verified = ADR-0002 release gate #3 满足;
在此之前手动公证 DMG 过渡通道保持。
