# TASK-AIN-003 run — ArkDeckKit 执行门 standing-authorization 路径

- Date:2026-07-22
- Executor:agent(Claude,host-only,零设备零联网)
- Base:main `4621a73001e53277cfb5ca0d718c76145e8f4ac9`(#288 merge);readiness 五
  blob pin(RockchipFlashAuthorization/Provider/Profile/CLIMain/ContractTests)与只读
  契约 seam(v3 schema、flashing delta)于 base 逐一复核命中,无漂移。

## 做了什么(文件面)

- **新文件 `StandingAuthorization.swift`**(命名族符合 readiness 新文件面):
  - `RockchipStandingAuthorization`:JSON 载体严格解析(schemaVersion 1.0.0 封闭、
    身份字段非空、digest 64-hex 归一小写、负值拒绝),字段集与 design §2 一致;
  - `RockchipStandingAuthorizationContext` + `RockchipDeviceIdentityReadback`:时钟/
    run 计数/durable binding revision/身份读回全部注入,校验器自己不读时钟不碰设备;
  - `RockchipStandingAuthorizationValidator`:design §3 顺序(有效期/次数 → 8 字段
    逐项比对 → 身份读回),任何非全匹配返回阻断 verdict;
  - `RockchipUnattendedExecutionIntent`:durable intent(POL-WORKFLOW-001),
    auditRecord 走既有 SessionAuditRecord 通道,携带 authorizationRef。
- **`RockchipFlashAuthorization.swift`**(pinned 待改):authorize() 增
  `standingAuthorization`/`standingContext` 可选参(默认 nil,既有调用零改动);
  非 human authority 进入 `authorizeUnattended` 私有分支——无授权/缺 context/
  ordinaryCI → **policyBlocked(原行为保持,handoff 增补"缺授权载体"说明行)**;
  新阻断 outcome 三类(expiredOrExhausted / mismatch / readbackMismatch)+
  `authorizedForUnattendedAgentExecution(commandSurface:intent:)`;decision 增
  `authorizationRef`(仅门通过时非 nil)。
- **`ArkDeckCLIMain.swift`**(pinned 待改):`arkdeck flash execute` 增
  `--authorization <AUTH-*.json>` + `--unattended-context <context.json>`;授权通过
  时先原子写 durable intent 再写命令面文档;所有阻断分支非零退出、dispatch 0;
  usage 同步。
- **新测试文件 `StandingAuthorizationContractTests.swift`**:三条 AC 测试,
  real-fault 注入 = 逐字段篡改真实授权 JSON 字节走真实 parse+compare 路径,零 fake
  verdict 常量(TR-002R 先例)。既有
  `RockchipRockUSBFlashProviderContractTests.swift` 一行未动。

## 二值门结论(readiness 五门逐一)

1. 无授权 → policyBlocked + dispatch=0:PASS(含 context 缺失、ordinaryCI 持有效
   授权两个加强面);
2. 授权块逐项篡改(8 字段:targetModel/bindingRevision/firmware/transport/
   toolchain/provider/planDigest/stepSetDigest)→ mismatch 阻断 + dispatch=0:PASS;
   另 stale-plan(为他 plan 铸造的授权)阻断 PASS;
3. 过期/超次/validUntil 不可解析 → 阻断 + dispatch=0:PASS(fail closed);
4. 读回缺失/序列号摘要不符/USB 身份不符 → 阻断 + dispatch=0:PASS;
5. 门通过 → authorizationRef 非空、durable intent 字段完整并经 SessionAuditRecord
   往返、命令面 = 既有封闭 §0 序列:PASS(真机面归 TASK-AIN-004)。

解析边界另证:截断 JSON/未知 schemaVersion/63 位 digest 全部 typed error 拒绝;
大写 digest 归一后可用(比对不脆弱于大小写)。

## 命令与结果

```
swift build → Build complete
swift test --filter "StandingAuthorization|RockchipRockUSBFlashProvider"
→ 18/18 passed;既有 TEST-AC-FLASH-015-01/02 输出逐字与基线一致(不回退底线):
  TEST-AC-FLASH-015-01 PASS destructive_dispatch=0 job=policyBlocked handoff=controlled
  TEST-AC-FLASH-015-02 PASS mismatch_fields=8 stale_plan_blocked=1 real_dispatch=0 …
新增:
  TEST-AC-FLASH-015-01 PASS standing_authorization_absent=policyBlocked context_absent=…
  TEST-AC-FLASH-015-02 PASS sa_mismatch_fields=8 … parse_faults=3 dispatch=0
  TEST-AC-FLASH-015-03 PASS executor=agent authorization_ref=present intent_durable=…
swift test(全量)→ 323 tests / 1 skipped / 2 failures(0 unexpected)
  = readiness 基线 320/1/2 + 新增 3 全绿;2 失败为已知 HDCGolden /private/tmp
  环境性(#270/#278 复验同型),与本 PR 无关。
./scripts/check-sdd.sh → 0 error / 0 warning / 111 acceptance IDs
```

## AC 结论

- AC-FLASH-015-01(contract 面):PASS;AC-FLASH-015-02(contract 面):PASS;
  AC-FLASH-015-03(contract 面):PASS——三者 realHardware 面归 TASK-AIN-004,
  本任务不做任何硬件支持声明。

## 偏差与遗留

- **载体格式偏差(如实记录)**:design §2 示例为 YAML;实现载体定为 **JSON**——
  仓内无 Swift YAML 解析器(chg-2026-021 catalog parity 同一事实),引入解析依赖
  属首个第三方依赖供应链决策(CHG-2026-023 AU-001 未决),不在本任务越权引入。
  字段集与 §2 逐一对应,语义零变化;AIN-004 readiness 的授权块按 JSON 载体起草。
- 与 TR-001 同型的边界:本任务只交付执行门与授权决策;真实 dispatch 由 AIN-004
  的授权 run 按门产出的命令面执行并回填 outcome/evidence(门 → 执行 → 存证链)。
- destructive dispatch 计数:本 run 恒 0(host-only,监视器快照断言在案)。
