# TASK-MECH-001 run — macOS Swift build+test CI job

- Date:2026-07-22;executor:agent(host-only;零设备/零 secret)。
- Base:main `42cc63123738313d253b25c9de78220e1e6814b5`(#327 合入后)。
- Readiness #323 pins 复核:`.github/workflows/swift-ci.yml` 于 base 不存在 ✓
  (纯新增,零既有文件触碰);runner 钉 `macos-15`;本地基线 = 346 tests /
  1 skip(worktree 口径另有 2 已知 `/private` 前缀环境性失败,具名见
  readiness;CI 正常 checkout 口径 = 346/1/0)。

## 交付

`.github/workflows/swift-ci.yml`,逐项对照 readiness 钉定:触发
`pull_request` + push `main`/`agent/**` ✓;`permissions: contents: read`、
零 secret ✓;`timeout-minutes: 30` ✓;concurrency 同 ref 后发取消先发 ✓;
v1 无 cache ✓;路径感知首步(PR 以 base sha、push 以 `event.before` 为 diff
基准;基准不可得 = fail closed 跑全量,宁多跑不漏跑)✓;job summary 恒输出
覆盖边界(ArkDeckKit only,App/XCUITest 不覆盖)与"CI 绿 ≠ 批准"注记 ✓。

## Run 证据(双向)

- 绿(真实全量):本实现分支创建 push(`event.before` 全零 → fail-closed
  全量路径)+ 实现 PR 的 pull_request run —— 链接与结果见下方补记。
- 红(canary 反证):丢弃分支 `agent/mech-001-canary`(基于本分支,注入
  必败测试)push → run 红 —— 链接见下方补记;该分支 auto-PR 立即 close
  (作废 PR 规则),分支删除,永不合入。canary 注入面(Packages/** 测试
  文件)在丢弃分支上,不进任何 merge,readiness 已钉此程序。

### Run 补记(推送后回填)

- PENDING:首绿 run / canary 红 run 链接与 CI 实际 Xcode/Swift 版本。

## 检查

- check-sdd:0/0/111;diff 范围 = allowed paths 内(workflow 新文件 + 本
  run);tasks.md 未动。
- 字节级 U+200B/U+FEFF 自检零命中。

## AC 结论(candidate)

`MECH-CI-001`:部分达成——workflow 形态与钉定逐项一致;done 前还需:
绿 run ≥3(随后续真实 PR 天然累积)+ canary 红 + 首 run 版本记录(上方
PENDING 回填)。required status 翻转 = 维护者 GitHub 设置动作,不属本 PR。

## 偏差与遗留

- `macos-15` label 可用性以首个 run 实证;不可用即停回 readiness 重钉。
- 交付形态:当前凭据可直接推 workflow 文件(SSH);BAP-003 收权后按
  design §5 复核。
