# TASK-I5-001 run — HDC semantic golden fixture pack registration

## Run identity and classification

- Base revision:`3a4d45c`(`governance: approve CHG-2026-005 (HDC parser golden registration r2) (#40)`)
- Working branch:`worktree-task-i5-001`(独立 git worktree,与并行任务零共享)
- Date/timezone:2026-07-18,Asia/Shanghai
- Environment:macOS 26.5.2(25F84),arm64;Apple Swift 6.3.3
- Execution classification:registration-only。零 process dispatch、零 HDC 执行、零网络、
  零设备访问、零 destructive 操作;Agent 未执行任何已安装 `hdc`。
- 本 run 只得出"fixture prerequisite registered"结论;不将 `AC-HDC-005-01`、`TASK-M1-006`
  或任何 platform conformance 标记为 passed/done。

## Provenance inputs(维护者受控采集,Agent 只读)

维护者 `fuhanfeng` 于 2026-07-18 10:42:18 CST 在 macOS 26.5.2(25F84)以受控脚本
(`~/hdc-capture/hdc-capture.sh`,分 stream 原始字节采集 + 命令上下文 + exit code 记录)
对连接的 OpenHarmony 设备执行真实 hdc:

- hdc binary:`/Applications/DevEco-Studio.app/Contents/sdk/default/openharmony/toolchains/hdc`
  SHA-256 `48395ba8d87115dffca47df2a640a6c868bc9a2bd4eb49611e4138ff88d8d260`
- client/server version:`Ver: 3.2.0d`
- 采集命令与 exit:`hdc -v`(exit 0)、`hdc checkserver`(exit 0)、
  `hdc uninstall com.example.waterflowdemo`(exit 0)
- 敏感串自检:clean(无设备序列号、无用户路径、无密钥;uninstall 的 path 回显字段为空)
- 首轮 `hdc install -r <绝对路径>` 采集因输出回显用户路径被判不合格并弃用,未净化、未登记;
  改用 uninstall 重采,argv 仅含 bundle 名。

维护者对上述 provenance 的正式认可由本实现 PR 的 review/merge 构成(approve gate 见
`review.md`)。

## Registered fixture pack(Golden/1.0.0)

| Fixture ID | Family | Bytes | SHA-256 | Lineage |
| --- | --- | --- | --- | --- |
| `hdc-golden-failure-unauthorized` | failure | 46 | `5e73a89bfec57338a129ec0d22bbf805c9b633849db0571d70c6f2f24b5340d8` | `HDCFixtures.exitZeroFailure` M0A 候选逐字节提取 |
| `hdc-golden-failure-offline` | failure | 30 | `d06b9e806721c00ebe771cc4b29e89145937d7162211b66e44ca7d0e5bffa38f` | `HDCFixtures.largeOutputFailureTail` M0A 候选逐字节提取 |
| `hdc-golden-success-uninstall` | success | 78 | `c690501211bc9c7a6a3b37704dd2cd58bdcf03e49771ffee10adf205a589d353` | 受控人工 capture(uninstall,exit 0) |
| `hdc-golden-healthy-checkserver` | healthy | 55 | `50e8dfe03cb770dfade5b91198523b964fd3bd6fd8855b541ceb46201f0d014a` | 受控人工 capture(checkserver,exit 0) |
| `hdc-golden-version` | version | 12 | `906d35a917937ecbb33d8dc3bbb6b3e1783bd2996a6201ab7227fb406d474ed9` | 受控人工 capture(-v,exit 0) |

字节对应证明:`cmp` 逐字节比对 Golden 文件与维护者采集原件全部相同;failure 两个 fixture
由 `HDCGoldenResourceContractTests.testFailureFixturesAreByteExactM0ACandidateExtractions`
断言与 `HDCFixtures` 常量逐字节相等。

## Success-marker 实测发现(登记的关键披露)

真实 hdc 3.2.0d 的 install/uninstall 成功输出为
`[Info]App uninstall path: msg:uninstall bundle successfully.\r\nAppMod finish\r\n`,
**不含** M0A parser 假设的 `[success]` 标记。当前 `HDCSemanticOutputParser` 对该 fixture 判
`unknownOutput`,已由 `testRegisteredFixtureClassificationsUnderCurrentParserAreTruthful`
钉死并在 registry(`currentParserClassification`)与 profile 0.2.0 中显式披露。按登记形态
接线 parser 属于 TASK-M1-006;本 change 不修改任何 parser 行为(`ArkDeckOpenHarmony`
源码零改动)。

## Family coverage audit(静态)

M1-006 fake-hdc matrix 视为 supported 的 raw output family:success、
failure(unauthorized/offline)、healthy(checkserver)、version——五者均已有 profile 0.2.0
entry 与 pinned fixture。`failure.explicitFailureMarker` 与 `failure.nonZeroExit` 为行为
分类而非独立 raw family:通用 `[fail]`/`errorcode` 标记已包含于两个登记 failure fixture
字节;non-zero exit 不依赖输出字节。未登记 output family 依 profile 规则维持
unknown/unsupported。

## Registrations(三方一致)

- `Fixtures/HDC/Golden/1.0.0/registry.json`:五 fixture 全字段登记(ID/family/path/stream/
  exit/classification/lineage/evidence class/SHA-256)
- `openspec/integrations/openharmony/profile.md`:0.1.0 → 0.2.0,逐 family probe/semantic
  mapping + success-marker 披露
- `openspec/integrations/INTEGRATION-PROFILES.lock.yaml`:INTEGRATION-PROFILES-0.2.0 →
  0.3.0,fixtures 列表五项(id/version/path/sha256)
- `openspec/verification/core-conformance.yaml`:shared_inputs.integration_lock → 0.3.0、
  OPENHARMONY-TOOLS → 0.2.0、shared_inputs.fixtures 五项
- 独立重算每个 SHA-256 并 grep 对照:registry/lock/conformance 三方逐 fixture 1/1/1 命中
- `Package.swift`:仅为 `ArkDeckContractTests` 增加 `.copy("Fixtures/HDC/Golden")` resources
  声明(保留版本化目录树;其他 target/product/dependency 零改动)

## Verification commands and results

| Command | Result |
| --- | --- |
| `swift build --package-path Packages/ArkDeckKit --build-tests` | passed;0 errors,0 warnings,无 unhandled-file warning |
| `swift test --package-path Packages/ArkDeckKit --filter HDCGoldenResourceContractTests` | passed;3 tests,0 failures(Bundle.module 精确集枚举+hash 重算、M0A 字节血统、当前 parser 分类真实性) |
| `swift test --package-path Packages/ArkDeckKit` | passed;172 tests,0 failures,1 项既有 opt-in 手动 sleep/wake skip |
| `ARKDECK_PYTHON=<主仓 .venv-sdd> scripts/check-sdd.sh` | passed;0 errors,0 warnings,111 acceptance IDs(worktree 无 .venv-sdd,经 ARKDECK_PYTHON 显式指定) |
| `git diff --check` | passed |
| `shasum -a 256` 独立重算 + 三方 grep 对照 | 五 fixture 全部 1/1/1 一致 |
| `cmp` Golden 文件 vs 采集原件 | byte-identical |

## Binary conclusions

- fixture prerequisite for `AC-HDC-005-01`:**registered**(仅前置登记,不宣称 AC passed)
- M1-006 platform matrix 输入前置(success/healthy/version):**registered**
- `HDCGoldenResourceContractTests` Bundle.module 定位/hash/血统/分类:**passed**
- 零 dispatch 边界(process/HDC/网络/设备/destructive 均为 0):**held**

## Deviations and residual risk

- Byte-integrity incident(已修复):首次 commit 时全局 `core.autocrlf=input` 把含 CRLF 的
  success fixture blob 归一化为 LF(76 字节,hash 漂移),工作区原件未受影响。已在
  `Golden/1.0.0/.gitattributes` 以 `*.bin binary` 钉死并 renormalize 重存,复验 blob 与登记
  hash 逐字节一致;`.gitattributes` 随 `.copy` 进入 bundle,资源测试的精确集期望显式包含它。
- 首轮 install 采集字节含用户路径,按红线整批弃用重采;弃用字节未进入任何登记。
- 真实 3.2.0d 无 `[success]` 标记的发现意味着 M1-006 接线时必须按 profile 0.2.0 的登记
  形态扩展 parser marker;在此之前 fake-hdc 中自造的 `[success]` 字节不得再被当作真实
  语义证据(本 change 已提供真实替代)。
- 状态翻转与实现分离:本 PR 不将 `TASK-I5-001` 置 done;merge 即构成维护者对 provenance
  与登记的认可,done 翻转由独立状态 PR 执行。
