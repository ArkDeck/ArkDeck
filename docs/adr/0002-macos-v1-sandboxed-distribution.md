# ADR-0002 — macOS v1 Sandboxed distribution(supersedes ADR-0001)

- Status: proposed; effective only when this PR is reviewed and merged by the
  maintainer(merge 即构成 DEC-004 决策与本 ADR 生效,V2 治理)
- Date: 2026-07-21
- Decision carrier: DEC-004 decision PR(open-questions.md 同 PR 翻转 decided)
- Decision owner: maintainer(`@lvye`)
- Core baseline: `CORE-2.1.0`
- Supersedes: ADR-0001(non-Sandbox zero-entitlement DMG 架构)

## Decision

ArkDeck v1 的 macOS 分发路径改定为:

> **Sandboxed**、Developer ID Application 签名、Hardened Runtime、单一公证 DMG,
> **公开直接分发**,面向既定支持格 `macOS 14 / arm64`;更新渠道 = **应用内自动
> 更新**(框架候选 Sparkle 2 或等价,最终选型/签名链/隐私披露由独立 change 评估
> 落地),自动更新 change verified 前以手动下载公证 DMG 为过渡通道。

MAS、ZIP、双 Sandbox/非 Sandbox 构建、未签名与 ad-hoc 构建仍不是 v1 分发路径。
外部优先工具模型不变:不捆绑 HDC(与 DEC-007 deferred 一致)。

## v1 entitlement 集(= 已验证的现行 `ArkDeckApp.entitlements`,精确六项)

```
com.apple.security.app-sandbox
com.apple.security.device.serial
com.apple.security.device.usb
com.apple.security.files.bookmarks.app-scope
com.apple.security.files.user-selected.read-write
com.apple.security.network.client
```

- 不含 `network.server`、`get-task-allow`(Release 构建关闭
  `CODE_SIGN_INJECT_BASE_ENTITLEMENTS`,M0A 先例)与任何 Hardened Runtime 例外
  (JIT/unsigned-exec-memory/禁用 library validation/DYLD env 等)。
- 自动更新框架若需要 XPC service 内嵌(Sparkle 2 sandbox 模式),其附加
  entitlement/签名面由该独立 change 显式声明并经维护者批准;不得静默扩集。

## Why(取代 ADR-0001 的依据)

ADR-0001 自身条款:"若实现证明需要任何 entitlement,须先 revisit 本决策"。该
触发条件已被实现事实实质满足(DEC-004 registered inputs,2026-07-21):

- 全部已验证面建立在 Sandboxed + 上述六 entitlement 形态上——M0B 真机 USB 受控
  采集、M1-006/CHG-2026-019 signed Sandbox XCUITest、PersistentFileAccess
  (security-scoped bookmark/PowerBox)文件访问模型、外部用户选定 hdc 的受控
  拉起;
- ADR-0001 选定的非 Sandbox 零 entitlement 形态从未被构建或测试;切换到它需要
  文件访问语义重验、XCUITest 全部重跑与全新形态验证,且不带来已识别的能力收益;
- Sandbox 对直接分发不是要求而是纵深防御加分:外部工具、镜像与输出目录的访问
  全部经用户显式授权(bookmark)且被内核边界约束,与本仓库 fail-closed 方向
  一致。

## Threat-surface 论证要点

- 外部 hdc 执行:仅用户经文件选择器显式选定 + security-scoped bookmark,子进程
  继承 sandbox;无 PATH 搜索、无捆绑、执行前 hash 记录(M1-006 pinned 模型)。
- 设备访问:`device.usb`/`device.serial` 为 HDC/RockUSB 工作流所必需,已被真机
  evidence 背书;不请求 `network.server`(ArkDeck 不做监听面;HDC server 为外部
  进程)。
- 文件面:只有用户选定的输出根目录 read-write;工具/镜像只读 scope(platform
  profile 既定)。
- 签名/公证:Developer ID + Hardened Runtime + notarized DMG 不变;自动更新引入
  的下载/验签面由独立 change 论证(必须验签到同一 Team identity,失败 fail
  closed)。

## Release gates(继承并扩展;本 ADR 不断言产物可发布)

1. Developer ID identity 就位(M0A 移交,未满足);
2. clean-VM/clean-host 矩阵(TRUST-001…004 与 M5 clean-host smoke)在 **Sandboxed
   分发形态**上执行;
3. 自动更新 change verified(评估框架/XPC/签名链/隐私披露/网络面;在此之前手动
   DMG 过渡);
4. macos platform profile distribution 节与本 ADR 同步(distribution-profile
   工作项)。

任一 gate 未满足,release 保持 blocked。本 ADR 不构成兼容性或支持声明。
