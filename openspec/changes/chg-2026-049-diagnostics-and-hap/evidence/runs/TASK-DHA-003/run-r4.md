# TASK-DHA-003 run — 多包 HAP 按目录安装(2026-07-31)

## 结论

- DHA-MULTI-001、002:**PASS**(contract 面)
- **DHA-MULTI-003:PASS** —— proposal r4 曾把它定为 pending(缺多模块签名 HAP)。
  素材当天构建出来了,故真机一次跑通并如实记 PASS

## 素材(本任务的前置条件,当天解决)

仓内与 samples 里**没有**现成的多模块集:15 个预构建 HAP 分属 15 个不同 bundleName、
全是 `type: entry`。可构建的候选有 150 个 feature 模块 / 24 个 HSP,但**签名 profile
绑 bundleName**(`~/.ohos/config/default_WaterFlowLayoutDemo_….p7b` 里写死
`com.example.waterflowdemo`),用它签 samples 的包装不上。

所以给 `WaterFlowLayoutDemo` 手加了一个 feature 模块(`feature1`,
`type: feature` + `deliveryWithInstall: true`),bundleName 与签名配置全不变:

```text
entry-default-signed.hap      bundle=com.example.waterflowdemo module=entry    type=entry    1,512,211 B
feature1-default-signed.hap   bundle=com.example.waterflowdemo module=feature1 type=feature    156,956 B
```

构建命令(已验证可用):

```bash
DEVECO_SDK_HOME=/Applications/DevEco-Studio.app/Contents/sdk \
JAVA_HOME=/Applications/DevEco-Studio.app/Contents/jbr/Contents/Home \
PATH=$JAVA_HOME/bin:$PATH \
/Applications/DevEco-Studio.app/Contents/tools/node/bin/node \
  /Applications/DevEco-Studio.app/Contents/tools/hvigor/bin/hvigorw.js \
  --mode module -p product=default assembleHap --no-daemon
```

`assembleHap` 出散装 HAP;`assembleApp` 出的是 `.app`,不是本任务要的形态。

## 真机执行

| 项 | 值 |
| --- | --- |
| 设备 | DAYU200,`TGT-958780b2ffb7`,hdc 3.2.0f |
| 入口 | `arkdeck agent run --operation debug.hap@1`(executor=agent) |
| Inputs | `hapArtifactLease`(entry)+ **`additionalHapArtifactLeases`**(feature1)|
| Job | `job-42c0ab9d8cceb99709cb8dfd26474510`,`succeeded`,`actualEffect: E1`,`outstandingResidueCount: 0` |

逐步判定:

```text
verified send-hap              ["packageCount", "stagedAt"]     ← 目录形,两个包
dispatched install-hap → verified package-readback ["bundleName", "installed"]
dispatched start-ability → verified process-readback ["bundleName", "running"]
verified stop-ability          ["stopped"]
verified cleanup-uninstall     ["uninstalled"]
verified cleanup-remote-staging ["cleaned"]
```

**装的确实是两个模块**(第二次跑用 `cleanupPolicy: retain` 保留后读设备):

```text
bm dump -n com.example.waterflowdemo  →  installed modules: ['entry', 'feature1']
```

窗口结束时设备已还原:应用已卸载、`/data/local/tmp` 无 `arkdeck-*` 残留。

## 本记录**不**证明的事

- 不声称任何 `DHA-HW-*` AC 通过(同前:hardware-evidence contract 编码不了 Agent executor);
- 只验证了 entry + 1 个 feature;HSP(`type: shared`)与 3 个以上包未测;
- 未验证包之间存在依赖关系时的安装顺序敏感性(本次两个模块相互独立)。
