# TASK-HTP-006 run r5 — 给 demo 注入一条真 cppcrash(准备 GJ-5 的 fail 路径)

- Date:2026-07-31(UTC 08:05–08:14)
- Executor:agent(维护者 2026-07-31 指示「往 demo 注入一条 crash」)
- Effect:hostOnly(改 demo 工程 + 构建 HAP + 起草凭据)。**零设备命令、零 E1**
- Catalog digest:`6b2191e87a71eb8a5bc11d3801c74d2ecf921261b9e7a836b57fc24ec894b076`(未变)

## 1. 为什么必须是 native crash

harness 的 crash 扫描按 OpenHarmony **cppcrash** 的文档形态匹配 fault block
(`Reason:Signal:SIG...`、`Fault thread info:`、`#NN pc ... (symbol+off)`)。ArkTS 未捕获异常
走的是另一种日志形态,**不会**产生这样的块。所以要让 GJ-5 的 fail 路径在真机上成立,
demo 必须能产生一次**原生**故障。

原 demo(`WaterFlowLayoutDemo`)ETS 源码里没有任何 crash/abort/throw,**也完全没有 native
模块**,因此按原样不可能复现 —— 这一点在 r4 的边界登记里已写明。

## 2. 注入内容(全部在 demo 工程内,不在本仓)

工程位置:`~/Downloads/WaterFlowLayoutDemo`(维护者自有工程,**不进本仓**)。

| 文件 | 作用 |
|---|---|
| `entry/src/main/cpp/crashprobe.cpp` | napi 模块 `crashprobe`,导出 `triggerNativeCrash()`;实际中止发生在**具名且 `noinline`** 的 `WaterFlowCrashProbe_RecoverBack()` 里,`std::abort()` → SIGABRT |
| `entry/src/main/cpp/CMakeLists.txt` | 只构建这一个 `crashprobe` 共享库 |
| `entry/src/main/cpp/types/libcrashprobe/{Index.d.ts,oh-package.json5}` | ETS 侧类型面 |
| `entry/src/main/ets/crashprobe/CrashProbe.ets` | launch 探针:`ENABLED`(单一开关)、`DELAY_MS = 12000`、`SIGNATURE` |
| `entry/build-profile.json5` | `buildOption.externalNativeOptions` 指向上述 CMakeLists |
| `entry/oh-package.json5` | 声明 `libcrashprobe.so` 本地依赖 |
| `entry/src/main/ets/entryability/EntryAbility.ets` | 内容加载成功后 `armCrashProbe()` |

**为什么延迟 12 秒**:`debug.hap@1` 要依次完成 安装 → 启动 → `process-readback`
(必须读到进程在跑)→ 5 秒 bounded capture。启动即崩会让**部署 job 失败**,而我们要的是
部署成功、随后应用自己崩掉,把 fault block 留在 `hilog -x` 会 dump 到的缓冲里,供**下一个
观察者**(harness 的采集)发现。

**怎么关掉**:把 `CrashProbe.ets` 里的 `ENABLED` 改成 `false`(或删掉该文件与
`EntryAbility` 里那一行调用)。native 模块可连同 `src/main/cpp` 与
`externalNativeOptions` 一并删除。

## 3. 构建与验证(host)

```text
DEVECO_SDK_HOME=/Applications/DevEco-Studio.app/Contents/sdk \
  hvigorw --mode module -p module=entry@default -p product=default -p buildMode=debug assembleHap
BUILD SUCCESSFUL in 7 s 594 ms

HAP:    entry-default-signed.hap
sha256: 003a4bff8292fdaebfc03a0ef75b64996939cca98a2f6c0ebf5c462f2f715f84
内含:  libs/arm64-v8a/libcrashprobe.so   6,144 B
        libs/arm64-v8a/libc++_shared.so  1,262,248 B
符号:  strings libcrashprobe.so → WaterFlowCrashProbe_RecoverBack ✓
        (ELF 64-bit LSB shared object, ARM aarch64)
```

符号必须活到 fault frame 里 —— **frame 就是证据**,所以该函数是 `extern "C"` +
`__attribute__((noinline))`。预期的 fault block 形态:

```text
Reason:Signal:SIGABRT(SI_TKILL)@...
#NN pc ... libcrashprobe.so(WaterFlowCrashProbe_RecoverBack+NN)
```

crib 的 L4 因此默认声明 `--crash-signature SIGABRT+WaterFlowCrashProbe_RecoverBack`,
让**DC-1(声明的这次 crash 不复现)**成为决定 L4 的那条 criterion,而不是只让 DC-3
(「出现了某个新 fatal」)兜底。L4 也不再需要人工手势:应用启动 12 秒后自己中止。

## 4. 待签发的凭据

HAP 字节变了 → lease 变了 → 已签发的凭据(pin 旧 lease)按定义失效(r3 记录过同一机理)。
新 draft:

```text
capabilityID     CAP-RT-AUTO-20260731T081359Z-147E4FF8B27E
hapArtifactLease lease-v1:input-hap-TGT-958780b2ffb7-r1-003a4bff8292fdae:ART-7ce60a790ee66455…
cleanupPolicy    retain | postRunAbilityState running | maximumUses 1
expiresAtUTC     2026-07-31T12:13:59Z
issuer.reference PR#884(合入即签发)
```

## 5. 边界

- **本轮零设备动作**:没有装、没有跑、没有采集。fail 路径的真机证据仍未取得;
  HTP-AC-18 的结论(r4)不变;
- demo 工程的改动**不在本仓**,故不受本任务 Allowed paths 约束,也不会随 PR 提交;
  本文件是它的可复查记录(文件清单、构建命令、HAP digest、库内符号);
- 下一步:合入本 PR(签发凭据)→ `--phase l1l2`(装带探针的 HAP、保持运行)→ 等约 12 秒
  让应用自己崩 → `--phase l4`(一次 submit,期望 evaluator 判 `fail` → 任务转
  `humanRequired` + `criteriaFailedNoRepairCapability`)。
