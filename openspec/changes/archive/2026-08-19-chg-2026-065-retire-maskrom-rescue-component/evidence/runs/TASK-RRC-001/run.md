# TASK-RRC-001 — 移除救援组件（2026-08-19）

## 删除/变更清单

| 面 | 动作 |
|---|---|
| `ArkDeck.xcodeproj/project.pbxproj` | 删除 `Embed Rockchip Component`/`… Metadata` 两个 CopyFiles 相位、6 个 PBXBuildFile、7 个 PBXFileReference（含 `RockchipComponent.entitlements`）、`Rockchip Component Package Inputs` group、`ROCKCHIP_COMPONENT_INPUT`（Debug）与 `ROCKCHIP_COMPONENT_METADATA_ROOT`（Debug+Release）构建设置；`plutil -convert xml1` 解析通过，`ROCKCHIP\|Rockchip Component\|rkdeveloptool` 命中 0 |
| `ArkDeckApp/RockchipComponent.entitlements` | 删除 |
| `.github/workflows/rockchip-component.yml` | 删除（整条组件构建/复核流水线退役） |
| `.github/workflows/swift-ci.yml`、`scripts/ci/plan.py`、`scripts/test_agent_pr_workflow.py` | 各删除 1 行 `ROCKCHIP_COMPONENT_INPUT=/usr/bin/false` 注入/断言 |
| `scripts/rockchip_component/**` | 删除；与组件无关的 `manual_ui_flash.swift` 与其候选夹具 `manual_ui_flash_candidate.json` 迁至 `scripts/manual_ui_flash/`，驱动器内 `origin/main:` 自校验路径与契约测试路径断言同步更新 |
| `openspec/integrations/rockchip/bundled-component/**` | 删除（1.0.0 注册表：registry/recipe/sbom/notices/source-manifest/package）；`profile.md` 保留并把「Maskrom rescue distribution」节改为退役记录 |
| `AuthorizationSurfaceGuardContractTests` | `testOnlyMaskromRescuePackagingRetainsTheStandaloneArtifact` 反转为 `testTheRescueComponentIsFullyRetiredFromTheProject`（断言相位/设置/文件**不存在**；全源码 `rkdeveloptool` tripwire 与 `SessionManifest.swift` 豁免保持原样） |
| `ManualUIFlashDriverContractTests` | 路径断言迁移；删除 `testRockchipSourceManifestPinsCurrentRepoBuildInputsBeforePush`（其主体 source-distribution-manifest 已随组件退役） |
| `docs/adr/0003`、`docs/release/rockchip-component-{packaging,distribution}.md` | 横幅由「救援保留」改「CHG-2026-065 整体退役；义务已随分发停止而卸除」 |
| `.gitignore` | vendor 日志 ignore 条目删除 |
| `scripts/README.md` 索引行 | **顺延至 TASK-RRC-002**（base 树的本 task Allowed paths 未列该文件；路径授权修正随 docs 治理 PR 先行） |

## 验证

- `swift test --package-path Packages/ArkDeckKit --parallel`：**1731/1731 通过，exit 0**（2026-08-19）。
- `xcodebuild -scheme ArkDeck … build-for-testing`：**TEST BUILD SUCCEEDED**；
  构建产物 `ArkDeck.app/Contents/MacOS/` 仅含 `ArkDeck`，
  `find -iname '*rockchip*' -o -iname '*rkdeveloptool*'` 命中 **0**（RRC-AC-2 构建半；
  Release 打包半待下一次 Release 复核）。
- `scripts/test_agent_pr_workflow.py`：8/8 OK；`scripts/ci/test_plan.py`：17/17 OK；
  `scripts/check_sdd.py`：0 error / 0 warning。
- 工程面残留 grep（RRC-AC-1）：pbxproj/workflows/scripts 命中 0；
  `rockchip-component.yml`、`scripts/rockchip_component/`、
  `openspec/integrations/rockchip/bundled-component/` 不存在。

## 边界

- 本 task 不触碰 `flash.dayu200` 行为；最近真机基线
  `EVD-NRU-DAYU200-20260819-001`（chg-2026-063 evidence）。
- 已发行 DMG 内的历史组件与其 notices 不受影响（义务跟随分发）。
