# TASK-HFA-001 — 崩溃判定源改为崩溃台账

- Date:2026-07-31
- Executor:agent(维护者指示「GJ-5 直接当前会话接着实现」)
- Device:DAYU200(RK3568),`TGT-958780b2ffb7`;OpenHarmony 3.2 / Build 7.0.0.36
- Effect:**只读**(两条 `hidumper` 查询)。零设备状态改变、零 capability 消耗、
  零 job 派发
- Gate:HFA-001 的 Gate 写「TASK-DHA-005 的采集腿…当前在 PR #890,未合」——
  **该门已满足**:#890 于本日合入(`main@4eb14e2d`),`capture.diagnostics@1` 现有
  `crashLogs` / `crashLogName` 输入与 `crash-index.txt` / `crash-log.txt` artifact

## 1. 改了什么,以及为什么不是加法

判定逻辑没动,**换的是证据源**。r6 窗口在真机上证伪了 TASK-HTP-002 的假设:同机同
digest、真实崩溃之后,887 KB 的 `hilog -x` 里 fault block 数为 0。故:

- 三条默认 criteria 中 **DC-1 / DC-3 的 `evidenceRequirements` 由 `hilog.txt` 改为
  `crash-index.txt`**;DC-2(活性)留在 `hilog.txt`,并在注释里如实写明它断言的是
  「设备在产出日志」而不是「我的应用活着」;
- handler 的 capture 步骤增发 `crashLogs: true`(**只读腿**,不抬 effect,故 E0 任务
  `maxE1Mutations: 0` 可用);上一轮观测给出条目名时增发 `crashLogName`,取值只来自
  被 digest 校验过的台账字节;
- `HarnessObservationBuilder` 里 **hilog 不再贡献 `matchingCrashCount` /
  `newFatalSignatureCount`**,只贡献 `applicationLiveness` —— 一个问题一个源,
  同一次崩溃不可能被两个源各计一次;
- 新增 `HarnessFaultLogLedger`:索引读取、条目名分解、按 kind 分派的正文解析。

## 2. 一个 scope 里没点名、但不实现就跑不通的语义:水位线

台账是**设备级累积状态**,不是采集窗口。直接计数会把历史条目每轮重复计入 ——
`matchingCrashCount` 是 counter 类指标(逐轮求和),设备上只要存在一条该包的历史崩溃,
`== 0` 的判据就**永远不可能通过**,修好了也判不出来。故:

- 第一轮可读台账**只立水位、不产计数、不产样本**。那一轮还没有「自上次以来」可言,
  报 0 是没挣到的断言;
- 之后各轮只计**时间戳严格大于水位**的条目,水位随之前进。

水位用**设备时间戳对设备时间戳**比较,不与宿主时钟比:实测条目名里的时间戳是
**设备本地时**(`20260731162134`,而当时宿主 UTC 是 08:21),拿宿主时间当基线会
差一个未知时区偏移。条目名 `<kind>-<bundle>-<uid>-<yyyyMMddHHmmss>` 定宽,
故字典序即时间序,不需要日期解析。

副作用:DC-1 的 `minimumSamples: 5` 现在需要 **6 次采集**(1 次基线 + 5 次计数),
连同 `observe.device@1` 共 7 轮,仍在默认 `maxRounds: 8` 之内。

## 3. 样本来源逐条标注(这是本任务栽过的地方)

TASK-HTP-002 的 fixture 按文档形态手写并如实标注,随后被真机证伪。故本任务把来源
写进 fixture 注释:

| fixture | 来源 |
| --- | --- |
| `oneEntryIndex` / `emptyIndex` | **真机字节**,`hidumper -s 1201 -a "-p Faultlogger -l"` |
| `jsCrashBody` | **真机字节**,`-f <条目名>`;fingerprint 与 unique id 已 mask,尾部 `HiLog:` 段截断(与 `hilog.txt` 重复) |
| `twoEntryIndex` | 按真机索引形态构造(第二条为构造条目) |
| `cppCrashBody` / `appFreezeBody` | **文档形态手写,非真机** —— 设备上当前只有那一条 jscrash |

**仍缺真机字节的是 cppcrash 与 appfreeze 两类条目正文。** 取得它们需要在设备上真造一次
native abort 或一次冻屏,属设备状态改变;当前设备现场为 CHG-2026-054 GJ-5 窗口所留,
未经维护者点头不动。

## 4. 判定与门

```text
swift test --package-path Packages/ArkDeckKit
  → Executed 959 tests, with 1 test skipped and 0 failures
sh scripts/check-sdd.sh
  → check_sdd: 0 error(s), 0 warning(s), 114 acceptance IDs
.venv-sdd/bin/python -m unittest discover -s scripts/catalog_gen -p "test_*.py"
  → Ran 39 tests … OK
.venv-sdd/bin/python scripts/catalog_gen/generate.py --check
  → 零输出(零 drift;本任务未改 Catalog,digest 不变)
```

新增/改写用例(`HarnessEvaluationContractTests` +9,`HarnessConvergenceContractTests`
断言加固):

- `testRealJsCrashEntryYieldsItsReasonAndSourceLocation` —— 真机 jscrash 字节解出
  `jscrash:TypeError+entry/src/main/ets/crashprobe/CrashProbe.ets:36:16`;
- `testAMatchingLedgerEntryKeepsTheMandatoryCriterionFromPassing` —— 有匹配条目时
  mandatory criterion 判 `fail`;
- `testAbsentLedgerIsInconclusiveAndNeverPasses` —— 负例①,`artifactNotCollected`
  → `INCONCLUSIVE`;
- `testEmptyLedgerAndMissingLedgerAreDifferentAnswers` —— 负例②,空台账(设备答了、
  没有)可作正证据,缺席(没采到)不可;
- `testUnreadableLedgerIsAnIntegrityBlockerNotAnEmptyLedger` —— 负例③,非台账字节与
  不可解析条目名各产出 `crashLedgerUnreadable:…`(→ `ERROR` + 人工阻塞),
  **绝不退化成空台账**;
- `testHistoricEntriesAreNotCountedAndFreshOnesAreCountedOnce` —— 水位线:历史条目
  连跑 5 轮累计仍为 0(否则判据永不可达),新条目恰好计一次;
- `testHilogNeverContributesCrashCountsAnyMore` —— r6 回归:hilog 里就算带 fault
  block 也不再产出崩溃计数;
- `testAppFreezeYieldsNoFabricatedSignal` / `testEntryNameDecomposition` —— kind 分派
  与条目名分解(bundle 的点号不被切断)。

## 5. 边界与未覆盖

- **本任务不含真机端到端复验**(属 TASK-HFA-005);本轮的真机成分只有只读取样;
- cppcrash / appfreeze 正文仍缺真机字节(见 §3);
- DC-2 活性仍只能断言「设备在产出日志」。要断言「我的应用活着」需要 capture 带
  `hilogFilters` 指名 bundle,那是输入面变更,不在本任务范围;
- 设备上 `com.example.waterflowdemo` 仍已安装(CHG-2026-054 窗口所留),本轮未动。
