# TASK-HFA-009 run r3 — 让 workspace grant 可由维护者起草

- Date:2026-08-01
- Executor:agent(仅产品代码与 host 测试;未签发、安装或扩大 capability)
- Source baseline:`main@d62aad97`
- Catalog digest:`577a8ca1884ce79e0136bc236638fa142ebe963f1be23b2d756f8b0eb85919b8`
- Hardware:none(当前轮没有 DAYU200 dispatch)

## 1. 真实产品缺陷

r2 已让五个 workspace 变更 operation 要求维护者签发的 standing capability,但生产签发路径
仍只有 device subject:

1. `arkdeck capability draft` 无条件用 `--target` 查询 device binding store。workspace 的
   project target `demo-app` 不是 adopted device,所以 CLI 在请求 daemon 前就失败;
2. `RuntimeJobEngine.draftCapability` 无条件要求 materialized device stable identity + binding,
   workspace plan 天然没有这两个字段,所以 daemon 也会拒绝。

因此 r2 的闸可以 fail closed,却没有生产路径让维护者得到可 review 的 workspace grant 草稿。
这不是“缺凭据”,而是 GJ-5 当前 catalog digest 的真实产品缺陷。

## 2. 产品修复

- CLI 按 catalog descriptor 的 binding 解析 subject:device operation 才查询 current binding;
  workspace operation 直接携带 project target;未知 operation 留给 daemon 返回 authoritative error;
- draft 与 submit/dispatch 共用同一个 `authorizationQuery`,统一从 provider 取得 workspace
  identity、current revision 与 allowed scopes digest,避免签发面再次落后于准入面;
- workspace standing target 绑定 tree identity + scopes,不固定 revision;review payload 仍显示
  起草时观测到的 revision,请求声明的 `expectedWorkspaceRevision` 仍进入 exact input constraint;
- device draft 仍固定 stable identity + binding revision;新增 workspace review 字段仅在存在时编码,
  既有 device JSON 不增加 `null` 字段。

## 3. 安全边界

本轮只生成 `PENDING-MAINTAINER-PR` review envelope。测试断言 draft 后:

- capability store 条目 = 0;
- runtime Job = 0;
- workspace process dispatch = 0;
- workspace 文件字节不变。

Agent 没有创建、修改、安装或批准 standing capability。真实 grant 仍必须由维护者 merged PR
签发;grant 缺失时 submit 继续 `authorizationRequired`、零 dispatch。

## 4. 测试与本地闸

```text
CI=true swift test --package-path Packages/ArkDeckKit
  Executed 1079 tests, 1 skipped, 0 failures

swift test --package-path Packages/ArkDeckKit \
  --filter WorkspaceProviderContractTests.testRuntimeDraftsAReviewableWorkspaceCapabilityWithoutInstallingOrDispatching
  Executed 1 test, 0 failures

swift test --package-path Packages/ArkDeckKit \
  --filter HarnessConvergenceContractTests.testCapabilityDraft
  Executed 2 tests, 0 failures

sh scripts/check-sdd.sh
  0 error(s), 0 warning(s), 114 acceptance IDs

.venv-sdd/bin/python -m unittest discover -s scripts/catalog_gen -p "test_*.py"
  Ran 39 tests, OK

.venv-sdd/bin/python scripts/catalog_gen/generate.py --check
  exit 0, zero drift
```

## 5. GJ-5 结论

本轮修掉的是「安全闸合入后维护者无从起草钥匙」,减少了一处手写/猜测 subject 的人工旁路,
但**不构成当前 digest 的 `REAL_DEVICE_PASS`**。下一步只能是维护者 review/merge 本修复,
随后分别签发 patch/build/revert 所需的 workspace grants,再在 DAYU200 上如实执行
crash → patch → build → deploy → verify。grant 未签发前继续 fail closed。
