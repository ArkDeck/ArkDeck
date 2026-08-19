# Verification — CHG-2026-065

> Change:CHG-2026-065-retire-maskrom-rescue-component@r1
> Status:planned；proposal merge 只批准 scope，不代表实现或验收通过

## Environment

- macOS 26 / Xcode 26.6 / Swift 6.3；`swift test --package-path
  Packages/ArkDeckKit --parallel` 全量；`scripts/ci/plan.py --run-local`
  与 python 脚本自测。
- 不需要设备：本 change 不触碰 `flash.dayu200` 行为（产品路径对组件
  本就零引用，NRU-004 边界）。Release bundle 清点在下一次 Release 打包时
  复核（RRC-AC-2 的 bundle 半）。

## Acceptance matrix

| AC ID | Verification method | Expected result |
| --- | --- | --- |
| RRC-AC-1 工程面零残留 | `grep -ri rkdeveloptool` 于 pbxproj/workflows/scripts + 契约测试 | pbxproj 无 Embed 相位与 `ROCKCHIP_COMPONENT_*` 设置；workflows/scripts 无该 env；`rockchip-component.yml`、`scripts/rockchip_component/`、`openspec/integrations/rockchip/bundled-component/` 不存在 |
| RRC-AC-2 产物面零携带 | build-for-testing 产物检查；下一次 Release 打包清点 | app bundle 无 `Contents/MacOS/rkdeveloptool`、无 `Resources/RockchipComponent/**`；DMG tuple 单 App |
| RRC-AC-3 守卫反转且 tripwire 保持 | 契约测试评审 + 运行 | 「必须含相位」断言改「必须不含」；全源码 `rkdeveloptool` tripwire 与 `SessionManifest.swift` 豁免原样；`ManualUIFlashDriverContractTests` 指向新路径 |
| RRC-AC-4 文档对齐 | 文档评审 | ADR-0003 / `docs/release/rockchip-component-*` 顶部声明组件已随本 change 退役、义务随分发停止卸除；DEC-011 注记（governance PR 已落）指向本 change |
| RRC-AC-5 staging 死代码清除 | grep + `swift test` | `RockchipFlashExecutionStaging.swift` 与 fault 契约测试删除；`RockchipFlashStagingCapacity` 容量门移除；生产零引用 |
| RRC-AC-6 改名落地 | grep + `swift test` | `RockchipFlashExecutionHost`/`RockchipFlashSessionReconcile` 旧名零残留（历史 journal/manifest 字符串除外——那是数据不是代码）；新名逐引用编译通过 |
| RRC-AC-7 无调用方端口清除 | grep + `swift test` | `RockchipProductExecutePlanFactPort` 及其 test-only 引用删除 |

## 不在本次验收内

- `flash.dayu200` 真机回归（本 change 零行为改动；最近基线
  `EVD-NRU-DAYU200-20260819-001`）。
- 分区表/计划模型双份归一（另立 change）。
- Release 打包/公证全流程（沿用既有 packaging 验收，tuple 缩小后首次
  Release 时执行）。
