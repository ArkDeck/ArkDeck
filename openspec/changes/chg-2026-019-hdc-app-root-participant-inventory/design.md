# CHG-2026-019 Design:App-root participant registry

> Status:candidate(随 proposal r1;approve 前不构成实现授权)
> Core baseline:CORE-2.0.0(零 Core 变更)

## 备选与裁决

- **A. 教 Supervisor 把「无 participant 信息」当可靠**:否决——这正是 M1-006 review 链
  (addendum 18/22)修掉的 fail-open;两类显式 reliability receipt 是合入版的安全不变量。
- **B. App 直接硬编码喂 `.complete([])`**:否决——「空」不等于「完备」;没有创建权独占,
  空列表只是当下巧合,任何未来功能加 Job 后即静默失真,恰是 addendum 23 批评的
  「treating empty affected/critical arrays as truth」。
- **C. App-root 单一 registry,完备性由构造保证(本设计)**:采纳。App 内所有
  lifecycle-相关 recipient 的注册路径收敛到一个 root registry;registry 的枚举因此
  构造性完备;facade 只转发 registry 状态,健康=complete、异常=unavailable fail-closed。

## 目标形态(实现 PR 落地)

- `ArkDeckWorkflows` 新增 `HDCApplicationParticipantRegistry`(actor):
  - `register(recipient:criticalState:)` / `updateCriticalState` / `participants` 枚举;
  - 与 `HDCApplicationDiagnosticsHost` 组合:compose 时由 registry 产出
    `HDCApplicationHostImpactInventory`;registry 与 host 同 endpoint 校验沿用既有
    `apply(impactInventory:)` 的 duplicate/exact-endpoint fail-closed 分支;
  - production 可见性:App 只经 Workflows facade 触达;`HDCApplicationDiagnosticsHost`
    的 inventory 参数在 production 组合里只接受 registry 产物(封闭构造,直接构造
    `.complete` 的入口不对 App 公开——以类型/可见性而非约定保证)。
- `HDCApplicationDiagnosticsFacade`:`.unavailable(固定文案)` → registry 驱动;registry
  初始化失败/不一致时保留 fail-closed unavailable(理由如实)。
- UI 文案:`hdc.lifecycle.recoveryUnavailable` 在 production 空-完备态下由
  inventory-unavailable 理由变为 server-identity/endpoint 前置理由(fixture 路径不变)。

## 证据面

- contract(HDCSupervisorContractTests 专段):构造性完备(App 可达 API 面无 registry 外
  注册路径,静态 import/可见性断言)、空-完备 → participant reliability true、注入
  critical Flash Job → preview 含全部 affected/critical 且 dispatch 计数 0、duplicate/
  跨 endpoint → fail-closed;全部计数为仪表化实测(M1-010/004 准则)。
- signed Sandbox XCUITest(M1-006 既有 harness 复用):production 启动断言
  inventory-unavailable 文案缺席 + 新 unavailable 理由;fixture 场景回归不变。
- 完成后 `MAC-M1-HDC-001` 的 production critical-gate 演示面补齐;其行状态由 TASK-M1-006
  的后续 closeout 修订处置,本 change 不代办。

## 风险

小而集中:纯 Workflows/App 组合层;不触 Supervisor 安全不变量(只满足它);最坏错误方向
是「假完备」——由构造性封闭 + contract 静态断言 + 维护者 review 拦截。
