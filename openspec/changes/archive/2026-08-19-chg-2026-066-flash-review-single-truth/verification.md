# Verification — CHG-2026-066

> Change:CHG-2026-066-flash-review-single-truth@r1
> Status:planned；proposal merge 只批准 scope，不代表实现或验收通过

## Environment

- macOS 26 / Xcode 26.6 / Swift 6.3；`swift test --package-path
  Packages/ArkDeckKit --parallel` 全量 + `build-for-testing`。
- 不需要设备：本 change 不触碰 submit/execute 行为与 lane 契约。
  stepSetDigest 的对拍基准用台架既有 job record
  （`job-b00e006a…` 的 `stepSetDigestSHA256 = c1ab01f8…`）作离线常量。

## Acceptance matrix

| AC ID | Verification method | Expected result |
| --- | --- | --- |
| SPT-AC-1 设备地址退出 | grep + 编译 | `RockchipFlashProfile`/mapped 类型无 `offsetSectors`（介入声明面仅存归档 introspection 的 `RockchipDeclaredPartition`——那是 `parameter.txt` 的归档事实）；FA-001 钉值与升序自检删除 |
| SPT-AC-2 覆写范围语义保持 | 契约测试 | `partitionPlan` admission 校验行为逐字不变（钉定名单比对）；分区名单/写序/成员绑定断言全绿 |
| SPT-AC-3 伪造计划清除 | grep + 编译 | Sources 零命中：`RockchipFlashPlan`、`rk-` 步骤 nonce 模板、`wlx`、`rockusb.wl-write`、`assessOutcome`、`RockchipFlashPlanDocument`、`makePlan(` |
| SPT-AC-4 摘要同源 | 契约测试 | presentation 的 `stepSetDigestSHA256` 与 `RuntimeJobEngine.stepSetDigest(descriptor:inputs:)` 对 `flash.dayu200` 默认输入逐字相等，且等于台架 job record 常量 `c1ab01f8c7c24649080d109c481f9c034ffb73edcc62033684ac8a59875e0b12`；plan digest 在评审面如实缺席（可选并标注提交时物化） |
| SPT-AC-5 步骤列表同源 | 契约测试 | 评审步骤列表 = descriptor 经 `stepIsRequested` 对默认请求输入筛选的序列（id/kind/effect/cancellation 逐项相等），无第二份筛选实现 |
| SPT-AC-6 UI 身份与行为不变 | `swift test` + build-for-testing + UI 契约 | 全量绿；`flash.execute.submit`/`flash.impact.userdata` 等 accessibility 身份零改；submit 请求体（含 `partitionPlan`）逐字节形状不变 |

## 不在本次验收内

- 真机回归（零行为改动；最近基线 `EVD-NRU-DAYU200-20260819-001`）。
- lane 侧 `arkforged` 计划摘要在评审前的预物化展示（需要 daemon 常驻 +
  预导入，另立 change 评估）。
- Catalog/请求 schema 演进。
