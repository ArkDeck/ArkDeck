# TASK-HSO-001 implementation/evidence run

## Classification and authority

- Executed at:`2026-07-28T15:47:00Z`
- Executor:`agent`
- Evidence class:`contract` + `platform`（host-only repository registration）
- Implementation base:protected main
  `06fad4cad68aeaca28a5714c2e2ecbdd3cc56a9d`
- Readiness authority:TASK-HSO-001 D1 PR #752 exact head
  `e49f9ba2161c72d4ef1e9c9bf5e25faf5c4b65d0` 由维护者 `lvye`
  APPROVED，并以 `a2c275581ca6dce29414a47aafa59f6d7fa29f91` 合入。
- Base 中其后的 #753 只修改 CHG-2026-025 tasks/evidence，与本任务 allowed paths、
  profile/lock/registry/fixture inputs 零交集；implementation 开始时 open PR = 0。
- 本 run 未执行 installed HDC、未扫描真实 host HDC process/socket、未访问真实设备、
  未读取 raw device identifier、未访问 non-loopback network，也未触发 server
  lifecycle/adoption、subserver、device/binding mutation 或 destructive effect。

## Delivered registry/profile closure

| Artifact | Git blob | SHA-256 / conclusion |
| --- | --- | --- |
| canonical supervisor registry | `b202b9d34680a0e7bbdba1d02637279ca4819d3f` | `f1691f748da10f1bb7753167d71ff3b764a347676f97d5ec70a1e97ac35c9763` |
| bundled registry copy | `b202b9d34680a0e7bbdba1d02637279ca4819d3f` | byte-identical to canonical |
| resource manifest | `405591c84b2cd0f5a4a8c73229ccafd17789992b` | `6bf09cabfc762b1e632d6dba2528b04b33173f6e53f2f1669d26ef8d72a4ab3d` |
| redacted receipt | `9e7b6ce4772bed5f1ef7ae4ad7863fc37932de0c` | `2edb677d25849eef8c0dede8c639a9ca21649578c7184b343870c5b79ecf1350` |
| fail-closed controls | `798646e66d969421752a45c4d46826cadbf37518` | `13470fbd7485dd328703476da4b4626fbce21ba5bce2bbfc4aef6f9020e65bbc` |
| pack attributes | `0d34dd828b3e3d4cb8f78b16dff59da7c4282b24` | `6f4d10e6d9a40109d02dfde8373df60ad01eabc5cca17be26fee4ca961621c9a` |
| OpenHarmony profile | `2ae13490e075f327bb7448ccacf908be5ba7e3aa` | `OPENHARMONY-TOOLS@0.6.0`; SHA-256 `8f70c070c9657f224ed019cddcc207d97f63424e9a032fef0473f58edededde0` |
| integration lock | `836d4ccc8c34c5826b6c53dcf9004e678a506d25` | `INTEGRATION-PROFILES-0.7.0`; SHA-256 `1ec25dc1afe9b57ae237afda9e454a53e9b6e3ee2231892af75969a2baa4644c` |
| macOS mapping | `b7471666b0bbfbfade3fbd510ad831e45b3cf9b8` | SHA-256 `b91154c03d96cdf138c3e3be75bbb92f3690a4bec68dfe0712d87c575afb4b5e` |
| dedicated contract test | `956a57fbe334248c4db3a13a7dab8d2561c02d63` | SHA-256 `2b5cedabe32e06b7bbcbb09374e1c2ce3a4af6674cb9b3192f74eccbd38d1c73` |

registry 只含一个 `serverIdentityGeneration` entry：exact macOS / hdc `3.2.0f` /
executable SHA-256
`05b2bf7ad30201c082da336db28f8856952a2b2f49ac3404b96fdb4bf1a68f83` /
endpoint `127.0.0.1:8710`、`platformProcessObservation`、`exactArgv: []`、
`invocationAllowed: false`。selected executable bytes 前后复核、exactly-one
process-owned listener 与 PID/start/path/hash/endpoint/listener bounded pre/post
equality 是 generation 的全部登记输入。

provenance 使用 archive-stable change id + relative evidence path，固定 #656/#658
exact heads/merge OID 与 source run SHA-256，并显式保留 `DEV-1`。它只支撑
commandless OS observation field shape/normalization/exact tuple/stability；不复用
command output，不证明 capture server 的 pre-existing/external origin，不登记
`checkserver`、health 或 client/server/daemon version。

## Contract and mutation results

新增 `HDCSupervisorObservationRegistryContractTests` 9/9 PASS：

1. canonical registry、bundled copy、manifest 与每个资源的 bytes/hash/exact file set
   闭合；
2. exact tool/profile/endpoint、空 argv、invocation forbidden、one-listener 与 pre/post
   field set 闭合；
3. caller/persisted receipt、caller generation、device snapshot 与 failed observation
   都不能 mint/retain generation/external claim；
4. #656/#658 provenance、archive-stable reference 与 `DEV-1` 窄边界精确；
5. redacted receipt pre/post tuple 稳定，真实 PID/path/device identifier 缺席，
   10 个 effect counter 全为 0；
6. 21 个 synthetic negative controls 覆盖 tuple/endpoint/provenance/argv、zero/multiple
   listener、wrong owner、PID/start/path/hash/endpoint drift、timeout/cancel/scan error、
   caller authority 与 3.2.0d fallback；全部禁止 generation/fallback；
7. `testIndependentMutationMatrixRejectsAuthorityDrift` 的 clean control 为 green，
   并逐一杀死 13 个 mutation：profile、registry ID、tool version/hash、endpoint、
   argv、invocation、effect、fallback、receipt hash、accepted merges、DEV-1 与
   forbidden-effect set；
8. profile/header/lock/registry/resource/macOS mapping exact hash closure；
9. 两个既有 registry/resource manifest pins 不变；其原有 suites 继续验证 manifest
   对整棵资源树的 exact file/hash closure。

## Commands and results

```text
cmp canonical-registry bundled-registry
PASS (byte-identical)

jq empty <registry/resources/receipt/controls>
PASS (4/4)

CI=true swift test --package-path Packages/ArkDeckKit \
  --filter HDCSupervisorObservationRegistryContractTests
9 tests / 0 failures / 0 unexpected

CI=true swift test --package-path Packages/ArkDeckKit
485 tests / 1 expected manual sleep-wake skip / 0 failures / 0 unexpected

scripts/check-sdd.sh
0 errors / 0 warnings / 111 canonical acceptance IDs

(cd scripts && /Users/fuhanfeng/Dropbox/Code/Github/ArkDeck/.venv-sdd/bin/python \
  -m unittest test_check_sdd)
56/56 PASS

python3 scripts/test_check_pr_paths.py
50/50 PASS

git diff --check
PASS
```

编译仅出现既有 `ArkDeckContractTests.swift` 的 “no async operations occur within await”
warnings；本任务新增文件无 warning/error。

## Existing-authority noninterference

- readonly canonical registry blob/SHA-256 保持
  `99e8cc3d9929f9502a3e978a53cd56ad285d2aad` /
  `b0ac1564109b8138c7a73cbb83684400967633f6e6b04701175a22d314d88da6`；
  resource manifest SHA-256 保持
  `e91e38dfa9a01132062865837844cf77494644488fba9527ce52c5a68c593bf6`；
  readiness-pinned resource tree OID 保持
  `f906403bc878a27dbef79736203da98c32a020eb`。
- device-observation canonical registry blob/SHA-256 保持
  `399c5a102c7737bf6466e8a2c4c6a1d1b1bc0b6a` /
  `79814e45901ab7e4d9f9a271645cad62b0053a50534cba884cdff0c2e50b9d49`；
  resource manifest SHA-256 保持
  `5192f30d9e38d869ab5f87ae1f0c53b68b66205f6421b9a0b613e5863e33f4d2`；
  readiness-pinned resource tree OID 保持
  `9ca93b91d18c554e4c137b7f3494550af072ebfc`。
- `Package.swift` 与两个既有 registry test blobs 保持 readiness pins
  `292135a2c80c63ddf7182f58e2f81ff7c7d6104d`、
  `6f83b54e4d01148005a7348786c886cf4b7c7ade`、
  `ff7dab950caa390c0b982c0c765c39606190e80f`。
- `Packages/ArkDeckKit/Sources/**`、App/xcodeproj、Core specs/contracts/baselines、旧
  registry/resource、其他 change tasks/evidence 全部未修改。

## AC conclusions

| AC | Result | Evidence |
| --- | --- | --- |
| `HSO-REGISTRY-001` | **PASS (`platform` + `contract`)** | exact commandless registry/resource/profile/lock/macOS/provenance closure；9 项专用 contract |
| `HSO-SEPARATION-001` | **PASS (`contract`)** | readonly/device registry/resource pins；3.2.0d substitution/fallback mutation red；既有 pack suites + 全量回归 |
| `HSO-NODISPATCH-001` | **PASS (`contract`)** | empty argv/invocation false；receipt/control 的 10 counters 恒 0；21 failure vectors 均不 mint/fallback |

`HSO-SINGLE-CANDIDATE-001` 属依赖本任务 `done` 后才可 readiness 的 TASK-HSO-002，
本 run 不认领、不接 production composition root。host-only/fake/contract 结果不记为真实
HDC、设备、hardware、conformance、support 或 release evidence。

## Deviations and remaining risk

- Scope deviation:none。
- Test deviation:none（1 个 skip 是既有需人工 sleep/wake 的 suite，非本任务）。
- Remaining risk:本任务只登记 authority；production observer construction、
  one-candidate reachability、four-evidence ownership 与 runtime zero-dispatch 仍由
  TASK-HSO-002 独立 readiness/implementation 验证。
- TASK-HSO-001 在本 implementation/evidence PR 中保持 `ready`；`ready→done`
  必须在本 PR 经维护者 review/merge 后使用独立状态 PR。
