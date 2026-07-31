# TASK-HTP-006 run r3 — 第二趟第一次尝试:E1 被授权面按字节拒绝(如实记录)

- Date:2026-07-31(UTC 06:38–06:41)
- Executor:agent(维护者指示),E0 + hostOnly + **一次被拒的 E1 尝试**
- Source baseline:`main@32c0466f`(#875 已合入)
- Device:DAYU200,`TGT-958780b2ffb7`,binding revision `1`
- Catalog digest:`17bd5443d0a660a8d657b5ba9fb15017252f42f88714bc4bc3e4e22ff76bdaff`
- State dir:`/private/tmp/arkdeck-gj5-window-pass2`(0700,窗口内跨相位复用)

## 1. 结果

| 腿 | 状态 |
|---|---|
| L1 接管 + `observe.device@1` | **再次成功**(幂等重跑,新 artifact:`device-facts.json` → `ART-2b52fbee…`、`binding-snapshot.json` → `ART-9b3bac41…`) |
| L2 HAP 导入 | 成功,但**字节已变**(见下) |
| L2 capability install | 成功(`remainingUses: 1`) |
| L2 `debug.hap@1` | **被拒**:`authorizationRequired` / `inputConstraintViolated: input hapArtifactLease violates constraint` |
| L3 / L4 | 未执行 |

## 2. 为什么被拒:授权绑定的是**字节**,不是文件名

第一趟(06:19Z)导入的 HAP:

```text
sha256 9453a396e81d55abfb05b4d7f9a512dea139e5843462051a6e1cc3586849fac8  1,512,003 bytes
lease  lease-v1:input-hap-TGT-958780b2ffb7-r1-9453a396e81d55ab:ART-8d5b85963670977fa1def2734b77fe67
```

第二趟(06:40Z)同一路径导入的 HAP:

```text
sha256 e873aeb0a0da520e5d5eb8b648b9c60483af163a21ce59980dc241c4ba9607c9  1,512,211 bytes
lease  lease-v1:input-hap-TGT-958780b2ffb7-r1-e873aeb0a0da520e:ART-effd30d8d2da276a4a63a647f82c27ec
```

文件 mtime = **2026-07-31T06:29:22Z**,正好落在两趟之间:demo 应用在第一趟之后被重新构建
(与「装 demo 应用复现 WaterFlow crash」的窗口目标一致)。#875 里签发的
`CAP-RT-AUTO-20260731T061927Z-DAC082804598` 把 `hapArtifactLease` **逐字 pin** 在旧 lease
上,于是新字节的请求被拒。

**这是安全内核按设计工作的正例,应当如实记下**:

- 授权绑定到精确输入值,**没人注意到的一次重新构建也换不掉被授权的字节**;
- 拒绝发生在**消耗之前**:被拒后 `capability list` 仍为
  `consumptionCount: 0, remainingUses: 1` —— 一次失败的尝试没有烧掉授权额度;
- 拒绝理由是机器可读的 `inputConstraintViolated: input hapArtifactLease violates constraint`,
  直接点名违约的输入。

## 3. 本轮为此补的产品/工具面

crib 在提交 E1 之前先比对「capability 里 pin 的 lease」与「本次导入得到的 lease」,不一致就
带两行 lease 直接停下并说明该重新起草 —— 把一次绕圈后的内核拒绝变成开工前的一句话。
(内核的拒绝仍是权威;这只是把同一事实提前说出来。)

## 4. 新 draft(等签发)

```text
capabilityID           CAP-RT-AUTO-20260731T064048Z-F37B8AB1B99A
effectCeiling          deviceMutation | exactBindingRevision 1 | maximumUses 1
materializedPlanDigest cf7ce68ded58c2f2702af572be599fe69785b7618029da5fce82c1cecf957cf3
hapArtifactLease       lease-v1:input-hap-TGT-958780b2ffb7-r1-e873aeb0a0da520e:ART-effd30d8d2da276a4a63a647f82c27ec
cleanupPolicy          retain(逐项 pin:bundle / ability / installPolicy / 5s 同上)
expiresAtUTC           2026-07-31T10:40:48Z
```

旧凭据 `…T061927Z-DAC082804598` 保留在仓内作为历史(它证明的是那次被拒),不改写、不吊销。

## 5. 窗口纪律提醒

**窗口结束前不要再重新构建 demo 应用**:每次重建都会换掉 HAP 字节,从而使已签发的
capability 失效,需要重走一遍 draft → 合入。若必须重建,重建后告知,我重新起草。
