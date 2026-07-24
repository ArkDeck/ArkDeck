# CHG-2026-023 Verification Plan

> Status:passed # 2026-07-24；三条 change-local AC 与完整任务/merge/evidence 链见 proposal.md「Verification closure」；仅在维护者 review/merge 本 verification-closure PR 后生效
> Change:CHG-2026-023-macos-auto-update@r1
> Core baseline:CORE-2.1.0(零 Core 变更;canonical Core AC 零认领)

验收面全部为 change-local(见 acceptance-cases.yaml)。任何静默安装路径、任何
验签失败后仍触碰安装动作、任何更新检查夹带设备/用户标识或遥测、任何私钥入仓,
整体 fail。

## Change-local

| Evidence ID | Task | Method | Expected result |
| --- | --- | --- | --- |
| AU-EVAL-001 | AU-001 | documentReview | 五维度(sandbox/XPC+entitlement diff、供应链、验签链、失败诚实性、隐私)逐维有据可追溯;选型结论明确且未选路线排除理由成立;零依赖引入、零第三方代码执行 |
| AU-CONTRACT-001 | AU-002 | contract | 验签 fail-closed 矩阵全绿(feed EdDSA 坏/缺签、下载物 Team identity 不符/未签名、下载中断/截断 → 全部零安装动作 + 诚实错误);安装须显式同意(零静默);entitlement 集与 ADR-0002 声明一致的测试断言 |
| AU-PRIVACY-001 | AU-002 | contract | 更新检查请求字段 = 封闭白名单(App 版本/OS/arch),零设备标识/用户路径/遥测(DEC-008 边界);披露文案存在且与实际字段一致 |

## Gate

本 change `verified` 前提:两 task done(各有 merged 交付 + 独立 done PR +
evidence);三 change-local AC 有可复查证据;发布规程文档(feed 生成 + EdDSA
私钥隔离处理)在案;如引入依赖,版本+hash pin 与 license notice 在案。verified
= ADR-0002 release gate #3 满足;不构成 release(其余 gates 独立),不构成
兼容性/支持声明。
