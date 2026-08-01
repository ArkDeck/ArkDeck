# TASK-HFA-009 run r1 — 先绑住"对着哪棵树做的决定",授权闸留给维护者

- Date:2026-08-01
- Executor:agent(维护者指示:完成全部 HFA)
- Source baseline:`main@bbaa50e7`
- Hardware:none(host-only)

## 1. 开工后第一件事:发现这个任务不能整体交付

任务写的是「capability subject 扩展 **与** exact base revision 绑定」。实测引擎准入路径后,
这两半必须拆开:

`RuntimeJobEngine.preauthorize` 在 `effect <= .readOnly` 时**直接返回默认只读授权**,
并且**忽略请求携带的 capability**。而全部 `workspace.*` operation 都声明 `hostOnly`。

所以:**在 effect 重分类之前,capability 的 workspace 主体没有任何路径可达**。把它落进
仓库就是一段够不着的枚举 —— TASK-HFA-002 已经立过这条规矩:不写够不着的空校验。
我把已写好的主体扩展**撤回**了,而不是留着凑数。

主体扩展与「workspace 变更必须授权」是同一件事:要让主体有意义,就得把四个 workspace
变更 operation 的 effect 从 `hostOnly` 提到 E1。那是**对已发布 operation 的破坏性修改**,
且后果具体:GJ-5 的修复腿会在维护者签发 workspace capability 之前停下 —— 按 HTP-INV-6,
harness 不得自签。**这个决定权在维护者,r1 不代为行使。**

## 2. r1 交付:exact base revision 绑定

不需要碰授权就能生效、且挡的是真实风险的那一半:**补丁打在与决策所见不同的树上**。

- `WorkspaceProviderSupport.workspaceRevision(root:profileVersion:globs:)`:
  HEAD OID + index 文件摘要 + 作用域内文件内容摘要(排序)+ profileVersion;
- `workspaceIdentity(root:profileID:)`:这是**哪棵树**,与它当前**是什么**分开;
- 四个变更 operation(applyPatch / buildOpenHarmony / revertPatch / createCheckpoint)
  新增**可选**输入 `expectedWorkspaceRevision`。声明了就强制:不符即
  `workspace.revisionConflict` fail closed;不声明则维持既有行为(非破坏性)。

### §18.2 的两处替换,写在代码注释里而不是藏着

1. **index 贡献的是 index 文件摘要,不是 tree OID**。读 tree OID 要解析 git 的二进制索引;
   文件摘要随索引变动 —— 那正是这里要用的性质;
2. **submodule OID 未纳入**。本 provider 目前没有 submodule 面,而一个什么都不能改变的
   成分不是证据。

全部为**文件读取**,不 spawn git:准入需要在任何进程启动之前拿到答案。HEAD 的解析覆盖
detached、symbolic ref 与 packed-refs 三种形态。

## 3. 命令与结果

```text
swift build                                          Build complete
swift test --filter WorkspaceRevisionBindingContractTests
                                                     Executed 9 tests, 0 failures
swift test                                           Executed 1058 tests, 1 skipped, 0 failures
.venv-sdd/bin/python3 scripts/catalog_gen/generate.py --write   零 drift
./scripts/check-sdd.sh                               0 error(s), 0 warning(s), 114 acceptance IDs
```

## 3.5 CI 抓到的一个仓内词表冲突(本任务不修)

第一次推 PR 时 `guard` 红了,原因不在交付面:任务状态我最初写了 `in_progress`,而

- `scripts/check_sdd.py` 的词表是 `ready|in_progress|done|blocked`(**下划线**);
- `scripts/host_loop/test_discovery_contract.py` 断言 `ready|done|blocked|in-progress`
  (**连字符**),且其解析器把 `in_progress` 截断成 `in`。

**两种拼法都不可能同时过两道门**,所以实际可用的状态只有 `ready`/`done`/`blocked`。
本任务改用 `blocked` —— 它也确实是操作上准确的:r2 不该被任何人接手,直到翻闸决定落地。
修词表要动 `scripts/**`,超出本任务 allowed paths,如实记在这里不顺手改。

## 4. r2 的两个前置(不由本 PR 决定)

1. **维护者对翻闸时机的决定**:workspace 变更是否、何时开始要求 capability;
2. **TASK-HFA-005 的真机证据补齐**。当前仓内**没有任何真机 run 记录**能支撑 GJ-5 的
   `REAL_DEVICE_PASS`:#902 的 commit 标题写了 "close GJ-5 bounded repair loop",
   但该 PR 零 `openspec/` 改动 —— 任务仍 `ready`、HFA-AC-11/12 仍 `pending`、无 run 记录。
   在闭环状态不明时再改授权语义,出问题会分不清是新门的问题还是原本就没通。

同样的台账缺口也适用于 TASK-HFA-003/004/006/010:代码已合入 `main`,五个任务的状态、
AC 结论与 evidence 都还没写。这是证据缺口,不是能力缺口 —— 但 GJ-5 的状态只能由跑过
窗口的人如实落定,我没在场,不代写。
