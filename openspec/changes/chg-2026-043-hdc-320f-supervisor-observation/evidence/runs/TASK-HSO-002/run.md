# TASK-HSO-002 implementation/evidence run

## Classification and authority

- Executed at:`2026-07-28T23:38:19Z`
- Executor:`agent`
- Evidence class:`contract`（host-only production wiring、fake observer 与 static source
  verification）
- Implementation base:protected main
  `a6cd29318b8c86dcd02f13937b897aa64fa3a160`
- Readiness authority:TASK-HSO-002 D1 PR #757 exact head
  `1b838caa4ebda5e5c31a830165e0c0fab8d0df5a` 由维护者 `lvye`
  APPROVED，并以本 implementation base 合入。
- Implementation 结束前重新 fetch 后 `origin/main` 仍为上述 base；唯一 open PR #759
  exact head `323347590e615904c3e5ecd4251ab8ef9cfaa113` 仅修改
  `openspec/changes/chg-2026-025-ai-native-unattended-device-ops/tasks.md`，与本任务
  allowed paths、authority 和 production source 零交集。
- 本 run 未执行 installed HDC、未连接真实设备、未读取 raw device identifier、未访问
  network，也未把 contract/system-observer 代码审查记为真实 process/socket、HDC、
  device、hardware、conformance、support 或 release evidence。

## Delivered production route

- 新增 `HDCSupervisorObservationProbeRegistry.swift`，固定
  `OPENHARMONY-HDC-SUPERVISOR-OBSERVATION-PROBES@1.0.0` 的 exact macOS hdc
  `3.2.0f` / executable SHA-256
  `05b2bf7ad30201c082da336db28f8856952a2b2f49ac3404b96fdb4bf1a68f83` /
  endpoint `127.0.0.1:8710` / empty argv / invocation forbidden / 1,000 ms
  observation deadline。production factory 只接收 host-wide supervisor、已选择
  candidate 与 endpoint；receipt、generation、PID/start/path/hash、process/socket
  list、runner 和 registry 均无 production injection surface。
- `HDCApplicationDiagnosticsFacade` 的一次 bootstrap 仍只执行一次
  `HDCExternalFirstDiscovery.discover` 和一次 endpoint selection；同一 local
  `candidate` / `endpoint` 同时进入 exact 3.2.0f supervisor observation 与既有 device
  observation session。3.2.0f observation 失败直接返回，不 fall through 到
  3.2.0d；非 3.2.0f candidate 继续走未修改的
  `HDCServerProcessSupervisor.observeRegisteredExistingServer` 路径。
- supervisor 与 device 3.2.0f production route 共享一个
  `HDCExact320FSystemIdentityObserver` 实现，但各自从独立 catalog 构造 policy。
  observer 在 bounded pre/post scan 前后复核 selected executable bytes，并要求稳定的
  PID/start/path/hash/endpoint/listener receipt；listener 只接受 exact IPv4 loopback
  或 macOS IPv4-mapped IPv6 loopback，wildcard、port-only、wrong address、scan
  ambiguity 与多 listener 均 fail closed。
- successful stable receipt 只调用既有
  `HDCServerSupervisor.observeRegisteredServerIdentity` 四证据 classifier；
  health 与 client/server/daemon version 均保持 typed unknown。unsupported、
  unavailable、unknown、timeout、cancellation 和 receipt mismatch 全部调用既有
  `recordUnverifiedServerProbeFailure`，撤销 prior generation/external claim。
- commandless observer 未构造 `HDCProcessCommand` 或 `HDCProcessCommandRunner`；
  exact 3.2.0d lifecycle/read-only route 未修改。

## Implemented file identities

以下 Git blob/SHA-256 对应本 run 测试的 implementation 内容：

| Path | Git blob | SHA-256 |
| --- | --- | --- |
| `Packages/ArkDeckKit/Sources/ArkDeckOpenHarmony/HDCSupervisorObservationProbeRegistry.swift` | `589dfec329044b58f4fefec3a70d4af7f9cfd15e` | `8fd580ed96b35e49793de2a5b3f0ee97a213c87ccb04b25c91707346e1da0f6e` |
| `Packages/ArkDeckKit/Sources/ArkDeckOpenHarmony/HDCProduction.swift` | `c7f71e5af90bc3d468d5f0817734d297f0c339a2` | `9a303e5d7ef683d513e599e9ccd7d8d4402b100d823d405bc96af8e727515dcf` |
| `Packages/ArkDeckKit/Sources/ArkDeckWorkflows/HDCApplicationDiagnosticsFacade.swift` | `fa0bc651382c9b5d1a36a46c59a11af65bc84249` | `1d3e25c78f5d43bf357171967fc1b54310ef6be071109007c5a6e333d9b1fdff` |
| `Packages/ArkDeckKit/Tests/ArkDeckContractTests/HDCSupervisorObservabilityContractTests.swift` | `e6556e053680550325491a5deac5c7eac9a09d96` | `3254e17901fe7777f365c2179a7e489856e9bb64c0edc32c0271ad870d2c9ff5` |
| `Packages/ArkDeckKit/Tests/ArkDeckContractTests/HDCDeviceObservationPresentationContractTests.swift` | `a54b950a67af564260efe55fb159e63a1847b59d` | `8349bf218543be5b070eb5df7d49766f41f69ce2f2444155a2c59eb390373e20` |

## Contract and failure results

新增 6 个 HSO contract 与 DP19 production-root contract：

1. exact catalog、empty argv、invocation forbidden、production anti-injection surface、
   shared observer construction 与 pre/post byte verification；
2. stable receipt spy 证明 session 消费同一 selected candidate/endpoint，minted generation
   进入既有四证据 classifier，external basis 四项全真，health/version typed unknown；
3. wrong candidate hash 或 endpoint 在 observer 前 unsupported，并撤销 seeded stale
   external/generation claim；
4. unavailable、ambiguous/unknown、timeout、cancel、wrong path/hash/endpoint、generation
   overflow、invalid PID/start microseconds 共 10 个 failure vector 全部撤销 prior claim；
5. 实际 task timeout/cancellation 只终止 owned observation work，supervisor lifecycle、
   subserver、confirmed lifecycle 与 managed-start counters 均为 0，spawn audit 为空；
6. listener normalization 接受 exact IPv4 与 IPv4-mapped IPv6 loopback，拒绝 IPv4/
   IPv6 wildcard、wrong loopback、IPv6 loopback 与 non-IP family；
7. DP19 static production-root reachability 固定一次 discovery、一个 supervisor factory、
   一个 device factory、同名 local candidate/endpoint、无 contract seam/runner；
   3.2.0f 两个 consumer 使用同一个 observer implementation、独立 policy，3.2.0d arm
   仍存在且 3.2.0f 失败无 fallback。

既有 observability O1/O3/O4/O5/O6/O7/O8 继续逐项验证四证据 conjunction、每个缺项
保持 unknown、managed provenance 不可被 external 覆盖；device DP8-DP16 继续验证
wrong candidate/endpoint、identity unavailable/drift、显式 refresh 至多一个 registered
read-only child、cancel 只终止 owned observation，device/subserver mutation 为 0。
TASK-HSO-001 registry suite 继续验证 caller/persisted receipt/generation 不可 forge，
21 个 negative controls 和 10 个 effect counter 全为 0。

## Commands and results

```text
CI=true swift test --package-path Packages/ArkDeckKit \
  --filter 'HDCSupervisorObservabilityContractTests|\
HDCDeviceObservationPresentationContractTests|HDCSupervisorContractTests|\
HDCSupervisorObservationRegistryContractTests'
114 tests / 0 failures / 0 unexpected
  device presentation: 19
  supervisor: 55
  supervisor observability: 31
  supervisor registry: 9

CI=true swift test --package-path Packages/ArkDeckKit
506 tests / 1 expected manual sleep-wake skip / 0 failures / 0 unexpected

scripts/check-sdd.sh
0 errors / 0 warnings / 111 acceptance IDs

/Users/fuhanfeng/Dropbox/Code/Github/ArkDeck/.venv-sdd/bin/python \
  -m unittest discover -s scripts -p 'test_check_sdd.py'
56/56 PASS

/Users/fuhanfeng/Dropbox/Code/Github/ArkDeck/.venv-sdd/bin/python \
  scripts/test_check_pr_paths.py
50/50 PASS

git diff --check
PASS
```

Environment:macOS 26.6 (25G72)、Xcode 26.6 (17F113)、Swift 6.3.3。1 个
skip 是既有需人工 sleep/wake 的 suite，不属于本任务。

## Existing-authority noninterference

- supervisor canonical registry/profile/lock/macOS blobs 保持 readiness pins
  `b202b9d34680a0e7bbdba1d02637279ca4819d3f` /
  `2ae13490e075f327bb7448ccacf908be5ba7e3aa` /
  `836d4ccc8c34c5826b6c53dcf9004e678a506d25` /
  `b7471666b0bbfbfade3fbd510ad831e45b3cf9b8`；supervisor resource tree 保持
  `87421493b8d353a402e0f777ef684e55db1f2981`。
- readonly 与 device canonical registry blobs 保持
  `99e8cc3d9929f9502a3e978a53cd56ad285d2aad` /
  `399c5a102c7737bf6466e8a2c4c6a1d1b1bc0b6a`；其 resource trees 保持
  `f906403bc878a27dbef79736203da98c32a020eb` /
  `9ca93b91d18c554e4c137b7f3494550af072ebfc`。
- `Package.swift`、`HDCReadOnlyProbeRegistry.swift` 与
  `HDCSupervisorContractTests.swift` 保持 readiness blobs
  `292135a2c80c63ddf7182f58e2f81ff7c7d6104d` /
  `2dfe8e9d8290d6e939b4e3531ac81bb332a7cc29` /
  `c09f6255d50b9c7b008f82f7f696c47f352fcb9b`。
- App/xcodeproj、Core specs/contracts/baselines、integration/platform authority、旧
  registry/resource、其他 change tasks/evidence 全部未修改。

## AC conclusions

| AC | Result | Evidence |
| --- | --- | --- |
| `HSO-SINGLE-CANDIDATE-001` | **PASS (`contract`)** | one-discovery production-root contract；same candidate/endpoint observer spy；shared exact-3.2.0f observer；stable receipt + existing four-evidence matrix；typed unknown health/version |
| `HSO-NODISPATCH-001` | **PASS (`contract`)** | commandless static surface；success/mismatch/failure/timeout/cancel zero supervisor counters and empty spawn audit；existing device explicit-refresh and 10-counter registry controls |

`HSO-REGISTRY-001` 与 `HSO-SEPARATION-001` 的 TASK-HSO-001 evidence 继续通过
same-revision registry suite 与 immutable pins 回归，但本 run 不把前一 task 的
platform registration 重分类为新的真实 runtime evidence。

## Deviations and remaining risk

- Scope deviation:none。
- Test deviation:none。
- Remaining risk:本 run 只提供 host contract、static production wiring 与 fake observer
  evidence；未以 installed HDC 或真实 process/socket/device 验证平台运行结果。真实环境
  中 observation unavailable/unknown 必须继续 fail closed。
- TASK-HSO-002 在本 implementation/evidence PR 中保持 `ready`；`ready→done` 必须在
  本 PR 经维护者 review/merge 后使用独立状态 PR。change `verified` 仍需后续独立状态
  PR 引用两个 task 的具体 evidence，不在本 PR 翻转。
