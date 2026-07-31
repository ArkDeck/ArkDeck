# TASK-HTP-006 run r6 — fail 路径实跑:crash 真的发生了,而 harness 看不到它

- Date:2026-07-31(UTC 08:21–08:24)
- Executor:agent(维护者指示)
- Source baseline:`main@4e21d2eb`(#884 已合入)
- Device:DAYU200,`TGT-958780b2ffb7`,binding revision `1`
- Catalog digest:`6b2191e87a71eb8a5bc11d3801c74d2ecf921261b9e7a836b57fc24ec894b076`
- HAP:带 native crash 探针的构建,sha256 `003a4bff8292fdae…`
- E1 授权:`CAP-RT-AUTO-20260731T081359Z-147E4FF8B27E`(经 **PR#884** 合入签发)

## 1. 结论先说:期望 `humanRequired`,实得 `succeeded` —— 这是产品缺陷,不是运气

| 腿 | 结果 |
|---|---|
| L1/L2 | **succeeded**:装带探针的 HAP、启动、`process-readback verified [bundleName, running]`、采集、`skipped stop-ability`(应用留在运行态) |
| 应用自崩 | **发生了**(见 §2 的计数证据) |
| L4 一次 submit(`HTASK-23821B743072`) | **succeeded**,verdict `pass`,`matchingCrashCount=0`、`newFatalSignatureCount=0` |

**根因:cppcrash 的 fault block 根本不在 harness 采集的字节里。**
`capture.diagnostics@1` 的 HiLog 腿降为 `hilog -x`(dump 整个滚动缓冲),而 OpenHarmony 的
cppcrash 明细落在 **faultlogger**,不进 hilog 流。`capture.diagnostics@1` 里没有任何
faultlog 腿(实测:该 operation 文档中 `faultlog|Faultlogger` 出现 **0** 次)。

因此 `DebugCrashTaskHandler` 的三条 criteria 全部以 `hilog.txt` 为证据来源时,
**DC-1 / DC-3 在真机上不可能失败** —— fail 路径不只是「未覆盖」,而是**以当前证据源不可达**。
这比 r4 里那句「未覆盖」强得多,也正是设备窗口该产出的东西。

## 2. 计数证据(只取计数,不导出字节)

五次 harness 采集的 `hilog.txt`(870,154 / 873,662 / 881,082 / 886,480 / 889,954 字节,
逐份 digest 校验通过):

```text
"crash probe armed"                              1   ← ETS 探针武装
"crash probe firing"                             1   ← 定时器触发,调进了 native
"aborting inside WaterFlowCrashProbe_RecoverBack" 0   ← native 侧 FATAL 日志未进 hilog
"Cppcrash"                                       0
"Reason:Signal"                                  0   ← 没有 fault block
"Fault thread info"                              0
"SIGABRT"                                        0
"waterflowdemo"                                 69   ← 五次采集**完全相同**
```

两点推断,各有依据:

- **探针确实开火**:`crash probe firing` 在缓冲里(它是 abort 前最后一条 ETS 日志);
- **应用随后停止产出**:五次跨约 40 秒的采集里,应用行数**恒为 69** —— 活着的应用不会一行不增。
  (进程是否已消失需要一次设备读回才能断言,本轮没有为此再消耗授权,故只写到「停止产出」。)

`hilog -x` 拿到 887 KB 真日志、digest 校验通过、按 opt-in 读取 —— **不是采集失败,
是这个源里就没有崩溃明细**。

## 3. 这一轮同时证伪了一个被写进 fixture 的假设

TASK-HTP-002 的 observation builder 是按「hilog 里含 cppcrash fault block」的形态写的,
host 侧 fixture 也按该形态手写(当时如实标注了「按文档形态手写」)。**本轮在真机上证伪了
这个假设**:同一台设备、同一 digest、真实 abort 之后,`hilog -x` 里没有该块。
判定逻辑本身没问题(fail-closed、样本门、digest 校验都按设计工作),**错的是证据源**。

## 4. 下一个产品缺陷(GJ-5 的当前唯一阻塞)

harness 需要一个**faultlog 证据源**才能判 crash:

- chg-2026-049 的 D9 窗口已 pin 命令面:`hidumper -s 1201 -a "-p Faultlogger"`(空态输出已确认,
  当时设备无 fault log,故有崩溃时的格式未 pin);
- **现在这台设备刚好有了一条真 fault log**(本轮探针产生),正是把「有崩溃时的输出形态」pin
  下来的时机;
- 形态 pin 下来之后,要么给 `capture.diagnostics@1` 加一条 faultlog 腿(输入面 + 步骤 +
  artifact,digest 会变),要么新增一个只读 operation;随后 crash 扫描按**真实**格式重写,
  criteria 的 `evidenceRequirements` 指向该 artifact。

在此之前,GJ-5 的 fail → 交人路径在真机上无法取得证据 —— 不是缺窗口,是缺证据源。

## 5. 设备遗留与授权

- 授权:`…147E4FF8B27E` 已用尽(1/1),消耗发生在第一次 mutation 之前;
- 设备上 `com.example.waterflowdemo`(带探针的构建)**仍已安装**,进程已停止产出;
  应用每次启动会在 12 秒后自崩,直到把 `CrashProbe.ets` 的 `ENABLED` 改回 `false` 重新构建,
  或卸载该包(需一份 `cleanupPolicy: uninstall` 凭据或人工卸载);
- 本轮没有为「读回进程是否消失」再申请授权,相应断言按上文限缩为「停止产出」。
