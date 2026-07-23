# TASK-AFP-006 implementation/evidence run — 2026-07-23

- Evidence class: `documentReview`
- Core baseline: `CORE-2.1.0`（零 Core/product behavior 变更）
- Scope: change-local `AFP-HANDBOOK-001`、`AFP-CORRECT-001`
- Implementation base:
  `31865366f7bdb8e5ca33f0c8d41c15f6daba7933`（TASK-AFP-006 readiness #410
  合入后的 protected `main`）
- Branch: `agent/task-afp-006-implementation`
- Environment: macOS；仓内 Git/Markdown、`rg`、Python/PyYAML SDD 环境
- Dispatch: device/HDC/network/process/effect/destructive dispatch = **0**；真实硬件 = **无**

> 本 implementation/evidence PR 保持 TASK-AFP-006 `ready`。`ready→done` 与 change
> verification 分别使用后续独立 PR；本 run 不自行产生批准语义。

## Readiness and concurrency recheck

- readiness carrier 中 37 个 path blob 于 implementation base 逐项复取：
  **37/37 exact match**。
- carrier 中 8 个 commit OID 逐项执行 ancestry 检查：**8/8** 为 implementation
  base 的祖先。
- 本 change `tasks.md` 于 implementation base 的 blob 为
  `6a83270179915096373d1f3b4b4b11ff5724dbcd`；它是 `AF-018` dated observation
  F36 的 process-record source。
- 开工时 GitHub open PR = **0**；没有同路径 PR 或 active task 与本任务的 handbook
  allowed path 重叠。
- pre-edit handbook blob =
  `6fbb1a706bcf488aa39db672b51f0327a92cdf9b`；旧 TASK-AFP-004 run blob =
  `4eed9d2f5ab8d79ef681a6d1473ed31b71d5242b`。

## Work completed

### AF-014 correction

只改手册 `AF-014` 的四个允许语义位置：

1. `Signal`：删除“公开枚举 case 可直接构造能力值”，改为检查 reliable-total
   receipt/capability 是否只能由 current-adapter capability factory 的唯一 minting
   point 产生；
2. `Observed cases`：同时引用 CHG-2026-021 TASK-TR-002R `tasks.md` 与
   [`run.md`](../../../../chg-2026-021-trace-adapter-capture/evidence/runs/TASK-TR-002R/run.md)，
   登记 expected target + exact `revision + 1`、matching `PublishedArtifact` →
   cleanup authority、catalog membership alone 非 per-device capability，以及
   reliable-total receipt 只能由 current-adapter `capability=true` factory 产生；
3. `Preflight`：检查 capability/receipt 的唯一 minting point 是否绑定当前 adapter，
   以及 caller 能否绕开 factory；
4. `Negative verification`：以真实 fault injection 覆盖 wrong target、no publication
   receipt、missing/false/drifted/invalid capability 或 factory bypass，断言
   indeterminate/authority none/dispatch 0。

手册中的 `公开枚举` / `public enum case` 机制命中由 **4 → 0**。除这四个位置与
18 条 `Currency` 外，没有其他 handbook section 发生变化。

### Current Fact addendum

新增
[`TASK-AFP-004/addendum-r5.md`](../TASK-AFP-004/addendum-r5.md)，按当前手册顺序为
36 条 Fact 分配 `F01`…`F36`，每行包含 AF ID、Fact 定位/摘录、一个或多个一手相对
路径、各 source 的完整 40-hex blob OID、可检索 locator、verdict、disposition 与判定
依据。结果：

| Result | Rows |
| --- | ---: |
| `supported` + retained | 35 |
| `supported` + rewritten | 1（F27 / AF-014） |
| current `partially-supported` | 0 |
| current `unsupported` | 0 |

五条原先没有本行/本 block 直接 Markdown source link 的 Fact（F05/F24/F28/F29/F36）
均已在 addendum 显式回源。旧
[`TASK-AFP-004/run.md`](../TASK-AFP-004/run.md) bytes 保持不动；其
`AFP-CORRECT-001: passed` **仅在 AF-014 面被 addendum 明确标记 superseded**。

### Currency

18 项 `Currency` 从旧 current-review base
`e48673fbe8c8440d7e12dbfe6aea5e94f996a4e2` 统一更新为本次实际 implementation base
`31865366f7bdb8e5ca33f0c8d41c15f6daba7933` 与 `2026-07-23`
（Asia/Shanghai）；首批基线 `de6b79aafa95700297a94dc311e94b1283f8abdd` 的历史
记录仍保留，不追溯改写。

## Commands and binary results

| Check | Result |
| --- | --- |
| readiness path/commit pins | 37/37 exact blobs；8/8 commit ancestors **PASS** |
| Fact matrix | F01–F36 无遗漏；35 retained + F27 rewritten；36 supported **PASS** |
| 五条无直接 source link Fact | F05/F24/F28/F29/F36 均有相对路径 + blob + locator **PASS** |
| AF-014 before/after | Signal/Observed cases/Preflight/Negative 四处逐句映射；错误 enum 机制 4→0 **PASS** |
| 旧 PASS supersession | 旧 run bytes 不变；仅 AF-014 结论标记 superseded **PASS** |
| Handbook structure | H2 = 18 且恰 `AF-001`…`AF-018`；H3 = 144，18 组八字段同序 **PASS** |
| Fact/Inference/method | Fact 36；Inference 18 且误标 0；positive 18 + negative 18 **PASS** |
| Automation status | 18 项均在 `mechanized`/`partiallyMechanized`/`semanticReview` 域内 **PASS** |
| Semantic diff boundary | 仅 AF-014 四个允许位置 + 18 个 Currency section；其余 section 0 diff **PASS** |
| Currency | implementation base 完整 OID 18/18 **PASS** |
| Handbook relative links/anchors | 标准 Markdown links **98**；其中 anchors **56**；全部解析 **PASS** |
| Addendum links | 48 条相对链接全部解析 **PASS** |
| Handbook complete OIDs | 22 枚唯一完整 40-hex commit OID，存在且均在 implementation-base ancestry **PASS** |
| Fact named symbols | 16 个命名代码/AC symbol 在 handbook 与本 change 之外 16/16 可解析 **PASS** |
| Shadow-spec boundary | handbook 新增 normative `SHALL`/`MUST` = 0；自动 approval/ready/done、platform/hardware/support claim = 0 **PASS** |
| Privacy/evidence boundary | secret、用户绝对路径、真实 device identifier、raw dump/trace bytes、裸 64-hex digest 复制均为 0 **PASS** |
| Allowed/forbidden path audit | diff 仅 handbook、本任务 addendum/run 与 `tasks.md` evidence 引用；archive/template/CHG-021/spec/contracts/governance/product diff = 0 **PASS** |
| `scripts/check-sdd.sh` | `0 error(s), 0 warning(s), 111 acceptance IDs` **PASS** |
| `git diff --check` | clean **PASS** |

结构、链接、OID 与 symbol 检查均以仓内当前 bytes 重算；未沿用旧 TASK-AFP-004 run
的计数。symbol 集限于 Fact 行的命名代码/AC 标识，纯数值、运算符、文件显示名与完整
Git OID 不重复计入。

## AC conclusions

- `AFP-HANDBOOK-001`: **passed**（`documentReview` candidate）。AF-014 四个允许位置
  已按 CHG-2026-021 tasks + TASK-TR-002R run 一手事实修正，错误 public-enum bypass
  表述为 0；手册 shape、两轴、引用、Fact/Inference 与 non-normative 边界保持成立。
- `AFP-CORRECT-001`: **passed**（`documentReview` candidate）。r5 addendum 明确旧
  AF-014 PASS superseded；36 条 current Fact 均有完整 source/locator/verdict/
  disposition，当前 36/36 supported；AF-014 同时钉定两份要求的一手 source，符号、
  Currency、archive/template 边界全部通过。

本任务不重判 `AFP-TEMPLATE-001`、`AFP-DRILL-001` 或 `AFP-LINK-001`。

## Deviations and residual risk

- **Deviation: none。**交付物与语义改动均在 readiness 封闭面内；没有发现 AF-014
  之外的 `unsupported`/`partially-supported` current Fact。
- **Environment note（非 scope/product deviation）。**首次直接运行
  `scripts/check-sdd.sh` 与改用 bundled runtime 的尝试均因所选 Python 缺少 PyYAML
  在校验开始前退出；未联网安装依赖。按脚本既定 override 使用
  `ARKDECK_PYTHON=<ARKDECK_ROOT>/.venv-sdd/bin/python` 重跑，得到
  `0 error(s), 0 warning(s), 111 acceptance IDs`。
- **Residual risk 1 — source conclusion boundary。**本任务只判断 pinned bytes 是否
  支持手册表述，不重新验证被引用 change 的产品结论。
- **Residual risk 2 — prose review。**精确计数、链接、OID 与 symbol 可机械复查；
  prose 强度仍需维护者 review。本任务没有新增 parser/CI。
- **Residual risk 3 — future drift。**addendum 与 18 条 Currency 固定本 implementation
  base；后续 source 修订不会自动延续本次 supported verdict。
- destructive/device/HDC/network/process/effect dispatch = **0**；真实硬件 = **无**。
