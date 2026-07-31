# TASK-HFA-007 run r1 — 让结论有出处,以及两条我没有交付的 operation

- Date:2026-07-31
- Executor:agent(维护者指示:完成全部 HFA;§20 冻结门显式提前解冻)
- Source baseline:`main@57a6b140`(#899 已合入)
- Hardware:none(host-only)
- Catalog digest:随本 PR 更新(生成器写入,零 drift)

## 1. 为什么要做

TASK-HFA-001 让崩溃判定改看设备的 fault 台账,那个方向是对的,但**结论是匿名的**:
解析发生在 harness 进程内,没有任何记录说明是哪个解析器、哪个版本、从哪份字节得出的。
后来的人无法把"判对了"和"碰巧判对了"分开。

本任务把这步搬到每个外部效果都要走的那条路上:一次分析就是一个 runtime job ——
声明输入 artifact、经 descriptor-bound dispatcher 跑 pinned 可执行文件、发布一份
derived artifact,其 provenance 指名源 artifact、源摘要、analyzer 引用与版本。

## 2. 三条 fail-closed

| 情形 | 结果 | 理由 |
|---|---|---|
| 输入字节与 lease 不符 | 拒绝 materialize | lease 是**声称**,字节是**事实**;不符意味着分析描述的不是采到的东西 |
| 分析器零输出 | `analyzer.emptyResult` | 「分析器什么都没产出」不等于「没发现问题」 |
| 声明 `.json` 却不是 JSON | `analyzer.malformedResult` | 名字是**被检查的承诺**;把文本挂在 .json 名下会让每个下游解析器崩掉 |

第三条是我在 TASK-HFA-008 里拒绝把 git 文本命名成 `.json` 的同一条理由,只是这次
产物是我们自己的分析器产出,所以可以**承诺并校验**,而不是回退命名。

## 3. 交付面

- 新 provider `analyzer`:`CatalogProvider` 枚举 + 生成器与 operation schema 词表 +
  dispatcher **独立路由**(analyzer 计划不会被送进 workspace 路由 —— 那条路由拥有另一组
  可执行文件,混用等于让一个 provider 的计划在另一个的身份校验下运行)+ daemon 组合注册
  (无 profile 时报 `UNAVAILABLE` 带机器可读原因,而不是从 `operation.list` 里消失);
- 封闭 step kind `runDeterministicAnalyzer`:`analyzerRef` 是枚举,任意程序不可被命名;
- 三个 operation:`analyzer.extract-crash-signature@1` / `summarize-hilog@1` /
  `summarize-trace@1`;
- derived artifact provenance:sourceArtifactId、sourceSha256、sourceByteCount、
  analyzerRef、analyzerVersion、derivedSha256、derivedByteCount、truncated;
- journal 记 `analyzer.analyze`,只记 analyzer 与源 artifact 身份,**不记宿主路径**。

## 4. 两条没有交付的 operation,以及为什么

TASK-HFA-008 把 `workspace.parseBuildFailure@1` 与 `collectBuildOutputs@1` 移交给了本任务。
做到这一步实测后,结论变了,如实登记:

- **`collect-build-outputs@1` 不属于 analyzer 面**。它是构建产物收集,而
  `workspace.build-openharmony@1` **今天只发布 `build.log`**(实测其 descriptor),
  没有 output manifest。正确的修法是**补构建腿自己的产物声明**,不是在分析面另造一条
  收集路径。本 change **不为它新建任务**:TASK-HFA-005 的真机端到端要做
  「部署 digest == build output digest」的相等判定(HFA-AC-11/12),缺 output manifest
  时那条判定根本无法成立 —— 应在那条任务里同车补齐;
- **`parse-build-failure@1` 先不造壳**。它消费 `build.log`;等构建腿发布了结构化产物,
  它要么就是第四个 analyzer profile(零新机制),要么根本不需要。机制已经做实,
  加一个 profile 的成本接近零,所以现在造它没有收益。

## 5. 一条设计约束(写在代码注释里)

每台主机**一个** pinned analyzer 二进制,各 analyzer 用 `fixedArguments` 选行为。
dispatcher 按 provider 解析可执行文件,所以两个不同二进制会被对方的 digest 拒掉
(fail closed)。需要多工具的主机应注册一个带子命令的工具 —— 这正是 `fixedArguments`
的用途。

## 6. 命令与结果

```text
swift build                                          Build complete
swift test --filter AnalyzerProviderContractTests    Executed 9 tests, 0 failures
swift test                                           Executed 1010+ tests, 1 skipped, 0 failures
.venv-sdd/bin/python3 scripts/catalog_gen/test_generate.py   Ran 39 tests, OK
./scripts/check-sdd.sh                               0 error(s), 0 warning(s), 114 acceptance IDs
```

## 7. 未覆盖(如实登记)

- **harness 内的就地解析尚未改接 derived artifact**。TASK-HFA-001 的解析仍在原位;
  改接需要 handler 先派发 analyzer job 再消费其产物,属规划面变更,留给 TASK-HFA-005
  的真机链路一并验证。在那之前,analyzer 面是**可用但未被 harness 消费**的;
- **engine-internal 例外没有新增负例**:本任务没有引入该例外的实现,故没有可断言的对象。
  §17.5 的边界写在 `AnalyzerProvider` 的文件注释里(任何 spawn 子进程的分析都必须走本
  provider);
- **真机**:host-only,按定义不碰设备。
