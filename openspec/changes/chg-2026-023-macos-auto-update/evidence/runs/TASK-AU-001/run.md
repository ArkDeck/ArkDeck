# TASK-AU-001 run

- Date:2026-07-23
- Executor:agent
- Method:`documentReview`,host-only
- Branch:`agent/au-001-evaluation-r2`
- Actual base:`origin/main@ba67d59980a2e3f84efe142f607f092ee3f29c6d`
- Readiness provenance:PR #427 merge
  `2c04d0d3ad337a1bdaf074c132a50c4474fe99cb`；2.9.4 source-repin PR #428
  merge `ba67d59980a2e3f84efe142f607f092ee3f29c6d`

## Scope and outcome

在封闭候选
`{Sparkle 2.9.4 sandbox/XPC, 最小自研 check+download+verify}` 间完成五维
documentReview。推荐**最小自研**，由 ArkDeck 完成 signed feed、下载快照与
严格 `EdDSA AND same-Team` admission，成功后仍由用户显式挂载 DMG/手工替换。

决定性证据是 Sparkle 2.9.4 固定源码的
`passedDSACheck || passedCodeSigning`；这不能满足
`AU-CONTRACT-001` 对不同 Team identity 的零安装 negative，且公开 delegate
没有下载/解包后的可拒绝验证门。完整事实、后果、不确定性和排除理由见
`evaluation.md`，来源清单见 `sources.md`。

本 PR 只新增本目录下三份 evidence；TASK-AU-001 保持 `ready`，TASK-AU-002
保持 `blocked`。

## Read-only source procedure

执行的来源动作：

- `git fetch origin main` 与 GitHub PR metadata 只读核对 #428 merge OID；
- `git ls-remote --tags https://github.com/sparkle-project/Sparkle.git
  refs/tags/2.9.4 refs/tags/2.9.4^{}` 只读核对 stable tag；
- `curl` 只向 stdout 读取 Sparkle 官方 docs、GitHub tree API 与固定 raw
  Git blob；未保存 release/source archive；
- `rg`/`sed` 只读检查本仓库 pinned inputs 与本机 Apple SDK public
  headers/interfaces；
- 未 clone、install、build、link、load 或 run Sparkle；
- 未执行 Sparkle release tool，未创建 feed、EdDSA key 或外部服务。

## Input pin check

实际 base 上九个 readiness local inputs 的 Git blob OID：

```text
proposal.md                                      c7515254522f3f049fc7e89098eb3d522a91ded9
design.md                                        f25882d74e7d1a7ba7953ad33f255e414398271f
verification.md                                  e171304af3bf02a4641fc72dc25465e12d5ec8aa
acceptance-cases.yaml                            dd3264dea573bf04e776a47cc4344f15c7a46a03
docs/adr/0002-macos-v1-sandboxed-distribution.md
                                                  5111bb8c8657d0ed05e0184fbbaeb88af5fc5d8f
openspec/platforms/macos/profile.md               a9a5931ffedd304a7ce3a088f4397c26fd87e744
Packages/ArkDeckKit/Package.swift                 91a1032f8a5ff9285154ef6f48ef35470b294eb7
ArkDeck.xcodeproj/project.pbxproj                 e7943096688728a22f4b940e536a32f3b8eaaf98
ArkDeckApp/ArkDeckApp.entitlements                6435d00f8493ce4fbca24a806ca7f320db9fbfa6
```

Result:**PASS**，相对 readiness 无漂移；base 唯一预期变化是 PR #428 对
`tasks.md` 的 2.9.4 source repin。

## Evaluation boundary counts

| Counter | Value |
| --- | ---: |
| Third-party dependency introduced | 0 |
| Third-party release/source files downloaded into workspace | 0 |
| Third-party code/tool executions | 0 |
| Product implementation files changed | 0 |
| Package/project/entitlement/ADR/profile files changed | 0 |
| External feed/service/key created | 0 |
| Device/HDC dispatch | 0 |
| Destructive/deviceMutation actions | 0 |
| Evidence markdown files added | 3 |

未跟踪的 `ArkDeckFakeHDCFixture-M1-006`、`Packages/ArkDeckKit/log/`、`log/`
属于既有工作区内容；本任务未读取其内容、未修改、未暂存。

## Verification

以下命令在 evidence 内容完成后执行并记录最终结果：

| Check | Result |
| --- | --- |
| `PYTHONPATH=/private/tmp/arkdeck-sdd-python scripts/check-sdd.sh` | **PASS**:PyYAML 6.0.3；0 errors、0 warnings、111 acceptance IDs |
| fixed source/OID/link inventory review | **PASS**:`refs/tags/2.9.4` = `b6496a74a087257ef5e6da1c5b29a447a60f5bd7`；九个 local blob OID 全匹配 |
| source-boundary/privacy/secret scan | **PASS**:仅 Markdown；外链 domain 精确为 `developer.apple.com`、`github.com`、`sparkle-project.org`；secret pattern 0 matches |
| staged allowed-path diff | **PASS**:3/3 均在本 change `evidence/**`，`tasks.md` 未改 |
| `git diff --cached --check` + staged diff review | **PASS**:whitespace error 0；484 additions/3 evidence files |

## AU-EVAL-001

`TEST-AU-EVAL-001`:**PASS(candidate evidence)**。

- sandbox/XPC + exact entitlement/signing diff:有据；
- first third-party supply chain vs in-house maintenance:有据；
- fail-closed signing chain:有据，且识别 Sparkle 2.9.4 的硬不兼容；
- failure/rollback honesty:有据；
- privacy minimization:有据；
- 推荐与排除理由:明确；
- dependency/file download/third-party execution:0/0/0。

该二值结果不自行把 task 标为 `done`，不把 change 标为 `verified`。维护者
review/merge 本 evidence PR 才认可选型；随后才允许独立 D0 状态 PR。

## Deviations and residual risk

- Deviation:无。候选集合、五维度、source boundary 与 allowed paths 均未扩展。
- Residual risk:最小自研路线的 feed canonicalization、下载状态、DMG/App
  验证对象、same-Team requirement、TOCTOU、隐私请求字节与手工安装文案尚未
  实现或运行；已全部列入 `evaluation.md` 的 AU-002 readiness 前置合同。
- Sparkle 2.9.4 的成熟原子安装能力没有被验证执行，也没有被否认；排除原因只
  是固定源码语义与 ArkDeck hard invariant 不兼容。
