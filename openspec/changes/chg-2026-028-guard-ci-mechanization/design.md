# CHG-2026-028 Design:guard/CI 机械化

> Status:candidate(r2 carrier namespace 修订;仅在维护者 review/merge 当前
> revision PR 后生效,且不构成 TASK-MECH-003 readiness)
> Core baseline:CORE-2.1.0(零 Core 变更)

## 0. 不变量

1. **授权语义零改动**:"CI 红 = 不能合并;CI 绿 ≠ 批准"逐字保持;所有新
   check 只读、零 secret、`permissions: contents: read`,不承担批准判断。
2. **每个新 check 必须证明会红**:canary 反证(故意注入违例的分支/fixture,
   证明 check 报红后丢弃,永不合入)是每个任务的 AC 组成部分;只有绿证据的
   check 整体 fail(exit0≠成功、套套逻辑 review 教训)。
3. **0/0/111 基线保持**:guard 每项增强合入前后
   `check-sdd = 0 error / 0 warning / 111 acceptance IDs` 不变;存量漂移先以
   所属 change 名义独立 PR 修复,不混入 guard 实现 PR。
4. **`archive/**` 全体豁免**:归档目录是冻结历史,新校验一律跳过,永不因新
   规则要求改写历史。
5. **fail closed**:校验器对格式解析失败报具名 err,不静默跳过(MECH-004
   的任务声明解析、MECH-003 的 block 解析同此)。
6. **与 CHG-2026-027 正交**:本 change 降低 D0 项的人工核验成本,不改变任何
   决策等级的定义与批准要求;两 change 无先后硬依赖。

## 1. TASK-MECH-001:macOS Swift build+test CI

- 新 `.github/workflows/swift-ci.yml`:`runs-on: macos-14`(或 readiness 钉定
  的当期 image),触发 = `pull_request` + push `main`/`agent/**`(与 sdd-guard
  对齐);`swift test` 于 `Packages/ArkDeckKit` 全量;`timeout-minutes` 与
  `concurrency`(同分支后发取消先发);SwiftPM 依赖零(仓库无第三方依赖),
  cache 面 = `.build` 编译产物。
- **路径感知而非 path filter**:workflow 恒运行,首步计算 diff 是否触碰
  Swift 面(`Packages/**`、`Package.*`;App 面见下),未触碰则直接 success
  (秒级)。这样未来翻 required check 不会在 docs-only PR 上因 path-filter
  永挂 pending(path-filter + required 的经典死锁)。
- 范围诚实性:只覆盖 ArkDeckKit swift test;`ArkDeckApp`/XCUITest 需签名与
  模拟器,不进本 change(PR 触碰 App 面时 CI 不给 Swift 结论,workflow 以
  中性名义快速 success 并在 log 注记——review 仍须人工跑,此边界写入 job
  summary,不伪装覆盖)。
- 已知环境性失败(HDCGolden 族在 `/private/tmp` worktree 的 #filePath 解析)
  预期不在 runner 出现(正常路径 checkout);若 runner 上复现,处置 =
  显式豁免清单 + 具名注记,禁止静默 skip 或 `|| true`(readiness 钉基线
  test 数与处置口径)。
- required status 翻转 = 维护者 GitHub 设置动作(D2,仓外),不属实现 PR;
  evidence gate:≥3 个真实 PR 绿 + 1 次 canary 红(注入必败测试的丢弃分支)
  后由维护者决定翻转时机。

## 2. TASK-MECH-002:三方 revision 同步校验

- 校验对象:`openspec/changes/<id>/`(active,`archive/**` 豁免)三元组:
  proposal front matter `revision`、acceptance-cases.yaml `change_revision`
  (文件存在时)、verification.md header `> Change:<ID>@rN`。
- 规则:三者数值一致,否则每 change 恰一条具名 err(列出三处实值);
  verification header 行缺失或不可解析 = err(fail closed);无
  acceptance-cases.yaml 的 change 只校验二元组。
- 测试(CHG-017 形态,进 `test_check_sdd.py`):合成 fixture 正例 + 三处各
  单独漂移的反例(恰一 err、err 文本含三实值)+ header 缺失反例 + archive
  跳过正例。
- 实现前扫描:readiness 钉当期 active changes 的三元组实测清单;存量漂移
  (如有)以所属 change 名义先行修复(#275 处置先例)。

## 3. TASK-MECH-003:pins 结构化全 hash 校验

- **前提诚实**:prose 中的缩写(`958780b2…`)是可读性惯例,机械区分
  "正当缩写"与"违规截断"不可行;可靠校验需要结构化载体。
- 约定:readiness/评估文档中的 pin 以 fenced block 表达——

  ~~~
  ```yaml pin-example
  - path: Packages/.../File.swift
    blob: <40-hex git OID>
  - artifact: registry.yaml
    sha256: <64-hex>
  ```
  ~~~

  上述 `yaml pin-example` 只展示 schema,不是 carrier。guard 只扫描
  `openspec/changes/**`(非 archive)中 opening info string 精确为
  `yaml pins` 的 fenced block:`blob`/`commit` 值必须恰 40 hex,`sha256`
  必须恰 64 hex,yaml 不可解析、未知 key、长度非法或字面占位符均具名 err;
  `yaml pins` 内不存在 placeholder 白名单。其他 info string(包括
  `yaml pin-example`)不激活校验。
- **opt-in 收紧**:无 `yaml pins` carrier 的文档不校验、既有文档不追溯
  改写;新 readiness 采用 carrier 后,截断在该载体内机械不可能。推广面 = 本 change 改
  `openspec/templates/change/` 相关模板加 `yaml pin-example` 示例 + 注记
  "新 readiness 应把 info string 改为 `yaml pins` 并填入完整真实值"
  (模板非 ratified 文档,implementation-only 可改;先例 = CHG-2026-025
  TASK-AIN-001 改 change 模板)。
- 测试:合法 `yaml pins` 正例;39/41 hex、sha256 63 hex、非 yaml、未知 key、
  carrier 内字面占位符反例;`yaml pin-example` 与无 block 文档跳过;archive 跳过。

## 4. TASK-MECH-004:PR allowed-paths diff 校验

- 载体:新 CI job(仅 `pull_request` event,需要 base..head diff;可并入
  sdd-guard workflow 为独立 job,复用 python 环境)。
- 任务声明解析(按序取首个命中,全不中 = 未声明):PR 标题/body 中
  `TASK-<AREA>-<NNN>` token;分支名 `agent/task-*` 惯例映射。声明的任务必须
  存在于某 active change 的 tasks.md,否则 err(fail closed)。
- 声明了任务:提取该任务 "- Allowed paths:" 行(含续行)中全部反引号 token
  为 glob(`本 change` 前缀解析为该 change 目录);校验
  `git diff --name-only base..head` 每一路径匹配某 glob,超出即红并列出
  越界路径。Allowed paths 行缺失或零 token = err(fail closed)。
- 未声明任务:diff 触碰敏感面(`Packages/**`、`ArkDeckApp/**`、
  `ArkDeckAppUITests/**`、`scripts/**`、`.github/**`)即红——产品/工具代码
  变更必须以任务名义;纯 docs/governance diff 通过(propose/approval/
  readiness/状态/decision PR 均此形态)。
- **边界诚实性**:这是 guard-rail 不是安全边界——声明可谎报其他任务;防线
  仍是维护者 review 与 enforcement"PR 载体与内容一致"。它机械关闭的事故
  形态:实现无意越出授权面(#301 remediation 类)、状态/readiness PR 夹带
  实现(#28 规则、#126 误合类)、未立项即改产品代码。
- 测试与 canary:解析器单元测试(声明命中/未命中/任务不存在/行缺失);
  canary draft PR 触碰 forbidden path 证明红(丢弃不合入);真实形态 PR
  (实现/状态/propose 各一)绿。

## 5. 凭据与交付形态注记

`.github/workflows/**` 变更可能受推送凭据 `workflow` scope 限制(BAP-003
凭据分离落实后预期收紧)。若 agent 凭据不可推 workflow 文件:交付形态 =
agent 起草 patch,维护者本地应用并推分支,PR review 语义不变。此注记进
MECH-001/004 readiness 的执行方式栏,不改变任务边界。

## 6. 任务间协调

- MECH-002 与 MECH-003 同改 `scripts/check_sdd.py` + `scripts/test_check_sdd.py`:
  串行交付(先 002 后 003)或同一会话连续两 PR;readiness 各自钉基 blob,
  后者如遇前者已合入须 rebase 重钉(workflow-conventions squash 规矩)。
- MECH-001 与 MECH-004 零文件交集(swift-ci.yml vs sdd-guard.yml/新脚本),
  可并行、可分会话(文件级分工先例 #255/#257)。
- 四任务对 CHG-2026-027 的 BAP-* 任务零文件交集(enforcement/AGENTS/模板
  batch-digest vs scripts/workflows;MECH-003 与 BAP-002 都碰
  `openspec/templates/` 但不同文件)。
