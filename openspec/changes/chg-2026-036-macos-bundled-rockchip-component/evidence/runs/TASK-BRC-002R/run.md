# TASK-BRC-002R run log

## implementation（2026-07-27；实现 = #616 merge
`9ff769d`，本 evidence 为其后独立 PR）

### 变更（恰两类行，无第三类）

`.github/workflows/rockchip-component.yml` +6 −2：

1. `on:` 新增 `workflow_dispatch:`（无 inputs）+ 三行说明注释；`push:`
   段（branches/paths）逐字未动。
2. 两处 `retention-days: 1` → `30`。

**契约措辞更正（如实记录，不静默解释）**：r1 契约②写「三处
`retention-days`」，而其同句括号枚举的是两个 upload step。实测文件里
`retention-days` **恰 2 行**：`build` job 的 matrix upload（一步产出
`rockchip-builder-a` 与 `rockchip-builder-b` 两个 artifact）与 `compare`
job 的 reproducibility upload。故「三」指 artifact 数、「两」指声明处，
两者都对；改动覆盖全部三个 artifact，验收门（三 artifact 均报 ~30 天
expiry）不受影响且可独立复核。已按此实施并记录。

其余逐字不变（YAML 重解析实证）：jobs `[unit, build, compare]`、
action pins、`permissions: contents: read`、concurrency group、
timeout、matrix `[builder-a, builder-b]`、`DEVELOPER_DIR`、全部命令行。

### push-triggered 实证 run（本 PR 分支推送即触发，新 workflow 生效）

- run `30232760627`，head `4ed06d63`，结论 **success**（unit / build×2 /
  compare 全绿）。
- **保留期实证（三 artifact 全部 30 天）**，2026-07-27T02:42Z GET：

  | artifact | id | size | created | expires |
  | --- | --- | --- | --- | --- |
  | `rockchip-builder-a` | 8640625410 | 125,046 | 02:41:56Z | 2026-08-26T02:41:55Z |
  | `rockchip-builder-b` | 8640623802 | 125,047 | 02:41:48Z | 2026-08-26T02:41:47Z |
  | `rockchip-reproducibility` | 8640630569 | 647 | 02:42:24Z | 2026-08-26T02:42:23Z |

  对照：旧 run `30156181935` 的同名三 artifact 已于
  `2026-07-26T11:25:04Z`–`11:25:21Z` `expired=true`。

- **component identity 复现 = PASS（机器证明，非自报）**：`compare` job
  的 `Committed metadata audit` 步骤 `rockchip-component: PASS:
  verify-committed`。该步以 `verify_committed()` 对四个 OUTPUT_METADATA
  （`THIRD-PARTY-NOTICES.txt`、`source-distribution-manifest.json`、
  `sbom.spdx.json`、**`registry.yaml`**）做**逐字节**比对；`registry.yaml`
  是构建产物且携 component `sha256:
  3caee2136551b4b849daf7e9a906813354f354f8adb61e5f092de49ec7a2e56a`、
  `size: 247488`。任何 identity 漂移都会使生成的 registry.yaml 与仓内
  committed 版本不等而 `BuildError: committed metadata drift`。PASS 因此
  等价于「本次新构建产出的组件 SHA-256 == 已接受值」。
- `compare` job 的 byte-identical 比较（builder A vs B）通过，reproducibility
  receipt 已生成。
- 注：日志里 builder A/B 的 `SHA256 digest of uploaded artifact zip` 两值
  不同属预期——那是 upload-artifact 的 zip 容器摘要（含时间戳/顺序），
  不是组件二进制摘要；组件字节一致性由 `compare` 与 `verify-committed`
  两步判定。

### dispatch 可用性（实现已在默认分支）

实现 #616 已合入 protected `main`（merge `9ff769d`，`lvye` APPROVED），
`workflow_dispatch` 自此可被触发（GitHub 语义：dispatch 只认默认分支上
的 workflow 定义）。main 上现状复核：`workflow_dispatch:` 在第 11 行、
两处 `retention-days: 30` 在第 64/99 行。

### dispatch proof（2026-07-27；`BRC-HANDOFF-002` 最后一格 = PASS）

维护者于 `2026-07-27T02:53:23Z` 亲手执行
`gh workflow run rockchip-component.yml --ref main`（触发是写操作，
Agent 零执行、只读核验）。Agent 于 `02:54:52Z` authenticated GET 复核：

- run `30233237693`，**`event = workflow_dispatch`**、branch `main`、
  head `01e6f9a6`（= evidence #617 的 merge commit）、
  **conclusion `success`**；四个 job 全 success（`unit`、
  `build (builder-a)`、`build (builder-b)`、`compare`）。
- **保留期（dispatch 路径同样 30 天）**：

  | artifact | id | size | created | expires |
  | --- | --- | --- | --- | --- |
  | `rockchip-builder-a` | 8640763234 | 125,046 | 02:53:56Z | 2026-08-26T02:53:55Z |
  | `rockchip-builder-b` | 8640764283 | 125,047 | 02:54:02Z | 2026-08-26T02:54:01Z |
  | `rockchip-reproducibility` | 8640767666 | 647 | 02:54:21Z | 2026-08-26T02:54:20Z |

- **identity 复现 = PASS**：`rockchip-component: PASS: verify-committed`
  （逐字节比对含 component `sha256: 3caee213…56a` / `size: 247488` 的
  生成 `registry.yaml` 与仓内 committed 副本）；另有
  `PASS: build`×2 与 `PASS: compare`（builder A/B 字节一致）。

**结论**：按需 dispatch 可用、产出与已接受组件 identity 一致、保留 30 天。
`BRC-HANDOFF-002` 三格（dispatch 可触发 / identity 复现 / 30 天保留）
全部 PASS；BRC-003 的签名窗口自此与 artifact 过期解耦，可独立排期。

### 边界

零签名、零公证、零上传发布、零 install/launch、零设备/HDC/USB、零凭据
动作；credential/token/绝对用户路径不入本记录。本任务 done **不使
TASK-BRC-003 ready**（其 D2 尚缺 Developer ID identity 与 notary
credential）。
