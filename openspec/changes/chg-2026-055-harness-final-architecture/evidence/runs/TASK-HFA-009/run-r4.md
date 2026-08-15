# TASK-HFA-009 run r4 — Runtime 只为 source-preserving checkpoint 签发 exact capability

- Date:2026-08-15
- Executor:agent(产品代码与 host contract;未在设备上 dispatch)
- Source baseline:`origin/main@4e478b46`
- Hardware:none

## 1. 阻塞不是“仓库里少一张 JSON grant”

ArkTrace Phase 6 提交的 exact `workspace.create-checkpoint@1` 请求在 ArkDeck Runtime
准入处得到 `authorizationRequired`。r2 把全部 workspace E1 operation 统一成 standing
capability,但产品当前故意不向 Agent 开放 capability draft/install/revoke 管理面。因此:

- Agent 不能、也不应自行安装一张 workspace standing grant;
- 把 capability JSON 当成代码提交不会让运行中的 Runtime 信任或加载它;
- 为 checkpoint 临时扩大 apply/build/revert 的 standing authority 会把安全边界做反。

真正的最小产品缺陷是:**source-preserving checkpoint 与 source-changing mutation 被放进了
同一授权桶。** checkpoint 只创建 Git object 或 provider-owned archive,不会更新 ref、index、
worktree 或声明源码字节;它是后续安全 mutation 的回滚前置,却被要求先取得只能由人安装的
源码 mutation grant。

## 2. 正式治理路径

Catalog 只把 `workspace.create-checkpoint@1` 改为 `runtimeCapability` 并开启
`defaultPolicyIssuance`;四条 source-changing/consuming operation 保持 standing-only。
Runtime 仅在 plan 与 workspace facts 全部 materialize 后签发能力,并固定:

- operation = `workspace.create-checkpoint@1`;
- exact typed inputs;
- exact materialized plan digest;
- workspace identity + request `expectedWorkspaceRevision` + ProjectProfile source scopes digest;
- maximumUses = 1,沿用同一个 consumption/outcome lineage ledger。

caller 仍不能给 Runtime-owned policy 注入自己的 capability。窄文件列表 digest 也不能冒充
workspace revision。这个 policy 不授予 apply/build/test/revert,不碰 device binding,不放宽
destructive E2。

## 3. 证据范围

本 PR 的证据仅是可复核的 host contract、Catalog generation 与 repository gates。它不声称
DAYU200 上已执行 checkpoint,也不提交任何 raw Trace。维护者 merge 后需要部署新 agentd,
再原样重放 Phase 6 request;只有那次生产结果才可写入 ArkTrace Phase 6 的设备证据。

## 4. 命令

最终 PR 门禁由同一冻结树生成:

```text
swift test --package-path Packages/ArkDeckKit --filter WorkspaceProviderContractTests.testCatalogToRuntimeArchiveCheckpointPublishesReceiptAndConfirmsCapabilityLineage
swift test --package-path Packages/ArkDeckKit --filter WorkspaceCapabilityGateContractTests
swift test --package-path Packages/ArkDeckKit --filter WorkspaceReadOnlyOperationsContractTests
swift test --package-path Packages/ArkDeckKit --filter RuntimeOperationCatalogTests
.venv-sdd/bin/python -m unittest discover -s scripts/catalog_gen -p 'test_*.py'
.venv-sdd/bin/python scripts/catalog_gen/generate.py --check
sh scripts/check-sdd.sh
python3 scripts/ci/plan.py --repo-root . --base-revision origin/main --head-revision HEAD --merge-base --include-worktree --run-local
```

结果:

- checkpoint Catalog→Runtime→artifact→capability lineage 定向:1 test,0 failure;
- Catalog / workspace authorization / checkpoint lowering 定向:36 tests,0 failure;
- Harness human-patch checkpoint/apply boundary:16 tests,0 failure;
- evolution journey:7 tests,0 failure;
- Catalog generator:43 tests,OK;generated Swift/matrix zero drift;
- `check-sdd`:0 error,0 warning,121 acceptance IDs;
- path-aware full lane:SwiftPM 1649 tests,0 failure;Xcode `build-for-testing` succeeded;
- raw hardware evidence:none;raw Trace upload/commit:none。
