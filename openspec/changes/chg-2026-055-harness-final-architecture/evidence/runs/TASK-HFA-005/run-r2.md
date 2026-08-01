# TASK-HFA-005 run r2 — DAYU200 一次 submit 完成 crash → repair → verify

- Date:2026-08-01
- Executor:agent(维护者明确允许模型出站与 DAYU200 E1 部署验证)
- Source baseline:`main@989b0018`
- Device:DAYU200,`TGT-958780b2ffb7`,binding revision `1`,stable identity suffix
  `23dc7a7e`,HDC `3.2.0f`
- Catalog digest:`44b6728d798dae80f2beaeef7b69b902140217847aa15814d213b04890af5ec6`
- Workspace:`WaterFlowLayoutDemo`,profile `waterflow-openharmony@1`
- Model gateway:`codex-cli-gateway@1`,model `gpt-5.6-sol`;project `demo-app` 由维护者
  opt in,敏感证据只放行 `hilog.txt,crash-index.txt`;未读取或持久化 vendor API key

## 1. 窗口前置与本 PR 修复的产品缺陷

第一次当前 digest 任务 `HTASK-888CE2031EEB` 已完成真实崩溃复现和精确补丁,但构建
`job-9609351bc30e8953e69fb0523608162c` 失败。`build.log`
(`ART-20607826d57a667b377ae5162eedaee7`,436 bytes,
SHA-256 `9e02865c494ac56354b433d5a1ad8b45d3f424cebde5dddf17cac090d96ed70e`)
给出 Hvigor `00303217 Configuration Error`:子进程没有有效的 `DEVECO_SDK_HOME`。
该任务如实停在 `humanRequired`,没有 resume,也没有把环境失败伪装成模型或设备结果。

窗口将补丁用 `workspace.revert-patch@1` 精确恢复到 crash 基线后,以有效 SDK 路径重启
daemon;随后 host-only 构建预检 `job-b01f326b9c1dff2969fb7227c3c40467`
成功。本 PR 把这项要求收回产品:

- WaterFlow profile 启动时解析并校验 `ARKDECK_DEVECO_SDK_HOME` →
  `DEVECO_SDK_HOME` → DevEco Studio 默认路径,缺 `default/openharmony` 即
  operation `UNAVAILABLE`,不再等到 Hvigor 才失败;
- `DescriptorBoundProcessDispatcher` 只给 workspace 子进程 overlay 已校验的
  `DEVECO_SDK_HOME`,不修改 daemon 或用户的全局环境。

## 2. 单次 submit 与零人工计数

一次 `arkdeck task submit` 创建 `HTASK-89586A62D3CD`;typed desired state 固定:

- target `TGT-958780b2ffb7@binding-1`,project `demo-app`;
- bundle `com.example.waterflowdemo`,ability `EntryAbility`;
- baseline HAP lease
  `lease-v1:input-hap-TGT-958780b2ffb7-r1-8abc989e25ced9ca:ART-4424fa7d60c1e102cf542020309b253b`;
- build/test preset `waterflow-debug` / `waterflow-tests`;
- touched-file base revision
  `8b98e5d5f316bc9b2c05e9e2462b48b912ba0b9a28d3c9896bdbf35ffe8ced0c`;
- budgets:`rounds=30`,`wallClock=3600s`,`artifactBytes=64 MiB`,`E1=3`,
  `noProgress=6`,`actionRetries=2`,`modelCalls=24`。

终态:

```text
HTASK-89586A62D3CD  succeeded / criteriaPassed
activeRound         20
wallClockSeconds    416
artifactBytes       6072891
modelCalls          20
e1Mutations         2
humanActions        []
```

从 submit 到终态没有 `task resume`,human action 数为 **0**。

## 3. HFA-AC-12:真实崩溃先判 FAIL

baseline fixture 的 E1 job `job-78e89fdbe18d0727b341e2dcd9896806` 成功,其授权证据为:

- capability `CAP-RT-POLICY-DAA6448E3C8EE1FF0800764BF3298393111B1915-G1`;
- issuer `runtimeDefaultPolicy`,reference
  `catalog:44b6728d…af5ec6:debug.hap@1`;
- exact binding revision `1`,exact bundle/ability/HAP lease/cleanup inputs;
- consumption outcome `confirmed`,effect `deviceMutation`。

round 6 的 `EVAL-202905F2F681` 为 **fail**,不是 pass:

```text
applicationLiveness    unhealthy
matchingCrashCount     1
latestCrashSignature   jscrash:com.example.waterflowdemo
latestCrashEntryName   jscrash-com.example.waterflowdemo-20010058-20260801102615
```

关键真机证据:

- `hilog.txt`: `ART-10bbe73f2845eae2e7e7a0aa3a3db27b`,SHA-256
  `4ab108a9f488eb9a49e840b50a53d9aac88fc9283798732fa5dc717966196f26`;
- `crash-index.txt`: `ART-05a57571f9cf01cfb7ed786c1440c0cb`,SHA-256
  `1d8cf9b8a3ef7a31df90610118423188335e69a4659cdfd8841066ea725fa36c`。

## 4. HFA-AC-11:精确修复、构建、测试、部署与五次 PASS

模型只提出一行 `ENABLED: true → false`;运行时读回:

- patch SHA-256 `6b45f926b558c6075aa78fe533ca422574d982cd71d3c4cf3974186e36571c98`;
- touched files 仅 `entry/src/main/ets/crashprobe/CrashProbe.ets`;
- patch/build source revision
  `cd4c272b17f6f96cdf554218c815fb8d577b3ea2c0c7a9d81ae38dace306f4ea`;
- apply job `job-420ff2d2a54e412574214d4b187844c5` succeeded;
- build job `job-2d4deda3fa71ecaa4fb407d70a086ab6` succeeded,
  `build.log`=`ART-a61d491ad12252d6a6e246cdec2a00a3`,SHA-256
  `1f36db5ec5feb2b35fead932090848cdae86f222deb40f5c4ece5a9781fe6971`;
- test job `job-5bcb688898d964e15c469d9608a5d2c8` succeeded,
  `test-output.log`=`ART-d1f2870c55ff5751f5e0c630331f3bbc`,SHA-256
  `f7f93c5deeee610f08c3ca428ac6fb36bf9a7fffa31ed6bfaf621b189b8d30b8`。

构建产物 lease:
`lease-v1:job-2d4deda3fa71ecaa4fb407d70a086ab6:ART-f1a661bd871b67d9e18c8920ea9bc8ca`。
构建读回与真机部署读回的 SHA-256 **逐字相等**:

```text
buildOutputDigest  6263bb8a25f9c5360f2e45f97b05000c6ff242a857a49c47f355c72af46287e8
deployedDigest     6263bb8a25f9c5360f2e45f97b05000c6ff242a857a49c47f355c72af46287e8
```

修复 HAP 的 E1 job `job-2f40dabe7916de33abd19a318476f23e` 成功;capability
`CAP-RT-POLICY-87969B268E1CBD84C580D60D103025EB99AF539F-G1` 精确绑定
binding `1` 与上述 build output lease,consumption outcome `confirmed`。

round 20 的 `EVAL-64B95811F714` 为 **pass**;连续五个复验样本均满足三条 mandatory
criterion:

```text
applicationLiveness       healthy  (5/5)
matchingCrashCount        0        (5/5)
newFatalSignatureCount    0        (5/5)
verificationRunCount      5
```

末轮 `hilog.txt`=`ART-9e1f206902469fe3509c82fa0bda19e9`,SHA-256
`bef3420f01ac88205ebb5de28530c725168ed74b42eee04ff44e67aef9614657`;
`crash-index.txt`=`ART-c71781984ac573b54e73f3aceb75429c`,SHA-256 与前述台账相同。

## 5. 窗口清理与结论

任务终态固定后,typed cleanup job `job-b0b7fddfedc8eec9e5d0eaf32f9375ec`
使用 capability `CAP-RT-POLICY-C2BA84E2DEC6A0B5BCC6DF69E3D9DE70ADEF0A9E-G1`
执行 `debug.hap@1` 的 `stop-ability`、`cleanup-uninstall` 与
`cleanup-remote-staging`;终态 `succeeded`,outcomeUnknown `false`,
outstanding residue `0`。

结论:HFA-AC-11 与 HFA-AC-12 在当前 catalog digest 上均为 **PASS**;
TASK-HFA-005 `done`,GJ-5 `REAL_DEVICE_PASS`。首次 SDK 环境失败、最终成功和清理结果均按
真实分类记录,没有把 simulation/fake 当作硬件证据。
