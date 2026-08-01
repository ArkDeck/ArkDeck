# TASK-HFA-009 run r2 — 翻闸:workspace 变更第一次需要授权

- Date:2026-08-01
- Executor:agent(维护者当日决定:立即翻闸)
- Source baseline:`main@989b0018`
- Hardware:none(host-only)

## 1. 翻闸前的事实

`workspace.apply-patch@1` / `build-openharmony@1` / `run-tests@1` / `revert-patch@1` /
`create-checkpoint@1` 声明 `effect: hostOnly`,而引擎 `preauthorize` 对 `effect <= .readOnly`
**直接返回默认只读授权并忽略请求携带的 capability**。也就是说:**给这台机器打补丁、构建、
回滚源码,此前不需要任何授权**。

## 2. 交付面

- capability 主体 `.workspaceIdentity(sha256, expectedWorkspaceRevision, allowedFileScopesDigest)`;
- 引擎准入**第二条分支**:无设备绑定的计划改问 provider 要 workspace 事实,要不到就拒;
- **派发时二次确立主体**:不信任准入时的结论,重新读树 —— 准入与派发之间移动过的工作区
  在这里被抓住,而不是照改;
- 消费账本(`RuntimeCapabilityStore`)的主体校验从"必须有设备"改为"必须有设备**或**
  workspace 主体",两者都没有即拒绝;**复用同一账本,未建第二套**;
- harness 可**引用**已签发 grant(`HarnessCapabilityPort.standingCapabilityID`)。
  HTP-INV-6 禁的是铸造/起草/扩范围,不是使用。

## 3. 翻闸时堵掉的真漏洞

升 E1 后,workspace 变更被路由进了运行时的**自动 E1 签发**路径 —— 当时**只因设备身份为空
而偶然失败**。已在两层关闭:描述符 `defaultPolicyIssuance: disabled`,以及引擎 issuance 分支
的 `query.workspaceIdentitySHA256 == nil` 条件。**自己发钥匙的闸不是闸**,单层关闭则是单点故障。

## 4. 两个设计判断

**standing grant 不绑 revision**。patch→build→test→revert 四步各改变 revision,绑死等于
单次可用且无人能预知后三个值。留空 = "这棵树、这些范围";非空 = 精确匹配(一次性)。
r1 的每请求 `expectedWorkspaceRevision` 绑定在两种形态下都仍逐次 fail-closed。
§16.4 把该字段列在**自动**授权之下,而自动签发恰好已关。

**世系指纹含 identity 与 scopes,不含 revision**。第一版把 revision 也放了进去,结果
standing grant 在第一次变更后就被 `lineageBlocked` —— 正是上面要避免的失败模式,由测试抓到。
不同补丁已由 `inputs` 区分。

## 5. 既有不变量:重述,不是放宽

`testMutatingOperationsAreDeviceExclusiveWithConfirmedBinding` 编码的假设是"任何 E1 都是设备
E1"。workspace 变更是**没有设备的 E1**,天然违反它。

改成 `testMutatingOperationsCarryTheGuardsOfTheirOwnSubject`,按主体分两半:
- **设备半边逐条不变**(deviceExclusive + confirmedDevice);
- **workspace 半边**要求 host-exclusive + 无绑定 + standingCapability + 禁自签 + 零设备 step。

另加 `testOnlyWorkspaceMutationsMayBeUnbound`:只有 workspace 变更可以无绑定 ——
这条是防止"以后谁把某个设备 operation 的 binding 去掉"的那半,不加就等于把原保护删了。

## 6. 命令与结果

```text
swift test                                        Executed 1074 tests, 1 skipped, 0 failures
swift test --filter WorkspaceCapabilityGateContractTests    8 tests, 0 failures
.venv-sdd/bin/python3 scripts/catalog_gen/test_generate.py  Ran 39 tests, OK(零 drift)
./scripts/check-sdd.sh                            0 error(s), 0 warning(s), 114 acceptance IDs
```

## 7. 运行上的后果(维护者需要知道)

- **修复腿现在需要 grant**。没有已安装的 workspace capability 时,harness 会在 patch/build/
  revert 处停为人工阻塞 —— 这是设计,不是故障;
- **一张 grant 的世系绑定一个 operation + typed inputs**(仓内既有模型,设备侧同理)。
  所以 patch → build → revert 需要**分别**签发,不能一张覆盖三个。测试
  `testRuntimeConsumesHostBoundPatchLeaseAndRevertsExactAttempt` 就是按这个模型改的;
- **只读族没有被顺手升级**:inspect-source / git-status / diff / read-source-range /
  symbolize-crash 仍是 `hostOnly` + defaultReadOnly。把读也升上去会让闸看起来更安全,
  却让闭环什么都看不了。

## 8. 对 GJ-5 状态的影响(维护者 2026-08-01 已决定:先合,窗口另排)

TASK-HFA-005 r2(#915)在 catalog digest `44b6728d…af5ec6` 上取得了 GJ-5 的
`REAL_DEVICE_PASS`。本任务改了五个描述符,digest 移动到 `577a8ca1…19b8`。

按 `PRODUCT-LOOP.md` §6,`REAL_DEVICE_PASS` 必须在**当前** digest 上取得,旧 digest 的
真机记录只证明历史。所以本任务合入后:

- #915 的结论**作为历史记录保留**,不撤销、不追认;
- **GJ-5 需在新 digest 上重取**。

重跑不是走过场,它要验的是这次翻闸本身:#915 那次跑的 workspace 变更是**无授权**的。
新窗口必须证明「维护者签发 workspace grant → 修复腿用它跑通 patch / build / revert」。
注意 grant 的世系绑定**一个 operation + typed inputs**,三步需分别签发。
