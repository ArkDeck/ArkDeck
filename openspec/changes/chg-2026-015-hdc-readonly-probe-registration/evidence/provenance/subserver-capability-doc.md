# subserverCapability — documentation provenance record

- Family:`subserverCapability`(capture-plan.md 矩阵第 4 行,主源=权威 hdc 源码/文档)
- Evidence class:`documentReview`(先例:CHG-2026-011 flash-protocol 研究)
- Researched:2026-07-20,Agent 执行(纯文档检索,零 hdc/device/network dispatch);
  **provenance 认可 = 维护者 review/merge 本 evidence PR**(capture-plan.md 认可载体)。

## Inspected sources(pinned)

- Repository:`gitee.com/openharmony/developtools_hdc`,`master` head commit
  `fb114f4ee99136bc4c7587777b80973ef3972d6a`(gitee commits API,2026-07-20 查询;
  head 提交日期 2025-09-13)。
- Files(经 gitee raw 逐文件读取):
  - `src/host/translate.cpp`(host 命令表与 usage/help 文本)
  - `src/common/define.h`(CMDSTR 常量与版本宏)
  - `src/common/define_plus.h`(结构/类型定义,交叉确认)

## Findings

1. **host 命令面不存在任何 "sub" 动词。** `translate.cpp` 的命令表与 usage 文本中没有
   `spawn-sub`、`killall-sub`、`subserver` 或任何含 "sub" 的命令字串;`define.h`/
   `define_plus.h` 中也没有含 "sub" 的 CMDSTR 常量或字面量。
2. **server 生命周期命令面为封闭三元组(另加 uart 专用与监听配置):**
   `CMDSTR_SERVICE_START`=`"start"`(usage:`start [-r]`,-r 为 restart)、
   `CMDSTR_SERVICE_KILL`=`"kill"`(usage:`kill [-r]`)、
   `CMDSTR_CHECK_SERVER`=`"checkserver"`;另有 `checkdevice`(仅 uart)与
   `-s [ip:]port | uds`(listen 配置)。
3. **版本对应关系(含 residual uncertainty):** 被检 head 的
   `HDC_VERSION_NUMBER`=`0x30200100`,源码注释编码为 **3.2.0b**;目标环境 pinned 工具
   实测报告 `Ver: 3.2.0d`(M0B evidence,EVD-M0B-DAYU200-20260718-001)。两者同属
   3.2.0 家族;`d` 后缀修订的精确 tag/commit 未在本次检索中定位——该不确定性如实披露,
   由 TASK-I15-001 注册评审判断本记录是否充分(CHG-2026-011 已记录官方版本配套表
   3.2.0b→API 20 为软约束)。
4. **仓库内交叉印证:** `openspec/specs/toolchain-hdc-server/spec.md:152` 中的
   `spawn-sub`/`killall-sub` 是规格侧的**防御性禁令词汇**(SHALL NOT 自动调用),并非
   对工具命令面的存在性断言;CHG-2026-014 legacy import manifest(第 125 行)已记录
   M1-006 legacy subserver contract vector 中"`spawn-sub`/`killall-sub` are absent"——
   与上游源码检视结果一致。

## What this record supports(不在本记录内裁决)

- `subserverCapability` 的注册候选结论:对被检 3.2.0 家族,该 family 的命令面
  **absent/不存在**,capability 观察面即 host usage/help 表本身(其中无 sub 动词)。
  按 CHG-2026-015 design Decision 2,"registry 显式记录某 family 为 `unsupported`"
  是合法且更安全的注册结果;最终分类由 TASK-I15-001 实现与维护者 review 决定。
- 本记录不构成 capability/compatibility/support/release claim,不认领任何 AC PASS,
  不替代其余三类 family 的受控采集(见 capture-plan.md)。

## Source URLs

- https://gitee.com/openharmony/developtools_hdc (master,head `fb114f4e`)
- https://gitee.com/openharmony/developtools_hdc/raw/master/src/host/translate.cpp
- https://gitee.com/openharmony/developtools_hdc/raw/master/src/common/define.h
- https://gitee.com/openharmony/developtools_hdc/raw/master/src/common/define_plus.h
