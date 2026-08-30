# UI 一致性台账 · 2026-08-31 批次十（preview 纳入构建守护）

> 任务：[UI 稿与实现一致性核对任务](../../ui-consistency-audit-task.md)（TASK-AIN-021）
> 基线：`99b244f6`
> **批次范围**：F52 第 8 条。纯设计侧工具链，**不触碰任何 App 代码或设计稿内容**。
> 差异登记见[审计记录 F61](../../implementation-audit-2026-08-27.md)。
>
> **验证边界**：无原生 UI 跑动、无浏览器走查、无设备操作——本批不改变任何被渲染的东西。

## 1. 被修的是「审计自己的证据链」

| 事实 | 影响 |
| --- | --- |
| `tsconfig.json` 的 `include` 只有 `src/**/*.ts` / `src/**/*.tsx` | 32 个 preview 从未被类型检查 |
| `build:review` 只打包 `scripts/session-review.tsx` | 32 个 preview 从未被任何 npm 脚本打包 |

因此审计记录里「32 个 preview 逐个独立打包通过」是**手工循环的结论**，换人换机器都无法复现。
本批把它变成 `npm run build` 的一部分。

## 2. 三步测量，排除了两层假象

| 尝试 | 结果 | 真实含义 |
| --- | --- | --- |
| 直接把 previews 加进 `include` | 38 × `Cannot find module 'react'` | preview 位于仓库根 `.design-sync/`，模块解析走不到本包 `node_modules` |
| `paths` 映射 `react` → `./node_modules/react` | 71 × `Could not find a declaration file` | 映射指到了实现文件（`jsx-runtime.js`）而非类型声明 |
| 映射到 `./node_modules/@types/react` 并设 `typeRoots` | **0 错误** | **preview 代码本身一直是干净的，缺的只是配置** |

若在第一步收手，会得出「32 个 preview 有 38 处类型问题」这种完全错误的结论。

## 3. 落地内容

| 文件 | 作用 | verdict |
| --- | --- | --- |
| `arkdeck-ds/tsconfig.previews.json` | 把 previews 纳入类型检查；两条 `paths` 映射与 `typeRoots` 承重，配置内写明原因 | `fixed` |
| `arkdeck-ds/scripts/build-previews.mjs` | **逐个** preview 一个 entry point 打包，任一失败即 `exit 1` | `fixed` |
| `arkdeck-ds/package.json` | 新增 `check:previews` / `build:previews`，接进 `npm run build` | `fixed` |

**为什么必须逐个入口**：合并成单一入口时，「某个 preview 只因兄弟文件替它引入了依赖才编译得过」
会蒙混过关。逐个打包才对应「每个 preview 可独立打包」这句断言。

## 4. 守护的负向验证（不是套套逻辑）

往 `.design-sync/previews/Chip.tsx` 注入一个不存在的 prop：

```
Chip.tsx(5,11): error TS2322: Type '{ children: string; nonexistentProp: number; … }'
  is not assignable to type 'IntrinsicAttributes & ChipProps'.
```

`check:previews` **退出码 2**；还原后退出码 **0**。守护确实会失败。

## 5. 回归

新增 `every design preview is type-checked and bundled by a script`，钉住：两个脚本的定义、
它们必须出现在 `build` 链中、tsconfig 必须伸到 `.design-sync/previews` 且经 `@types` 解析
React、打包器必须逐个入口且失败即非零退出、它走的集合等于覆盖表 `previewFiles`（32）。

## 6. 本批验证

| 检查 | 结果 |
| --- | --- |
| `npm --prefix docs/design/arkdeck-ds test` | **79 项通过，0 失败**（新增 1 项；含顺车修复 2 项，见第 7 节） |
| `npm run build` 全链（含新增两步） | **通过**；`build-previews: 32 previews bundled independently` |
| 守护负向验证 | 注入类型错误 → 退出码 2；还原 → 0 |
| 统一本地闸 `scripts/ci/plan.py --run-local` | 退出 0 |
| 原生 XCUITest / 浏览器走查 / 真实设备 | **均未执行**（本批不改变任何被渲染的东西） |

## 7. 顺车修复：rebase 后发现 `main` 上交互测试已红

rebase 到含 `bec43c53`（#1606 *modernize SwiftUI surfaces*）的 `main` 之后，本地
`npm test` 变成 **77 通过 / 2 失败**。在**干净 `main`** 上复跑确认：**`main` 自身就是
76/2**，与本批改动无关。

| 失败 | 原因 | 产品行为 |
| --- | --- | --- |
| `History compact activity picker mirrors every native category and the workspace-width boundary` | 测试用 `/workspace\.size\.width >= (\d+)/` 取阈值；#1606 改为 `onGeometryChange` + `workspaceWidth >= 890` | **未变**，890 仍在 |
| `all actual navigation items and subtabs are audited` | 测试用 `/Label\(settingsText\("settings\.tab\.(\w+)"\)/` 枚举面板；#1606 换成 SwiftUI 新的 `Tab(settingsText(...))` | **未变**，七个 tab 与顺序都在 |

两处都是**测试正则锚在 SwiftUI 的写法上**，写法一现代化就断，而被审计的事实（阈值、tab 集合）
根本没动。已改为锚定事实本身：阈值正则同时接受两种拼写，tab 正则只认
`settingsText("settings.tab.X")` 这个本地化调用，不再关心外层容器是 `Label` 还是 `Tab`。

**这条同时暴露一个覆盖缺口**：CI 不跑 `npm test`（PR 检查里只有 `ds-tokens`），所以 #1606
把交互测试改红也能合入。本审计的核心守护因此可以在无人察觉的情况下失效——**已登记，
本批不改 CI 配置**（`.github/**` 不在本 Task 的 Allowed paths 内）。
