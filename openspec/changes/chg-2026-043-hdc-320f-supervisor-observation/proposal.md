---
id: CHG-2026-043-hdc-320f-supervisor-observation
revision: 1
status: verified # 2026-07-29 本 verification-only PR；closure 段见文末，仅在维护者 review/merge 后生效
class: integration
core_change_level: none
owner: lvye
core_baseline: CORE-2.1.0
platforms: [macos]
---

# Register and adopt exact HDC 3.2.0f commandless supervisor identity observation

## Why

CHG-2026-006 `TASK-M0B-002` 的 2026-07-28 fresh readiness 在 PR #736
（merge `193b19b2487952c7018e8bbcc77bc67b4197a92b`）继续保持 `blocked`：
production App 只选择一个 `HDCCandidate`，并把同一候选同时交给 server supervisor
观测与 device observation；但现有 server observation authority 只接受 hdc `3.2.0d`
（SHA-256 `48395ba8d87115dffca47df2a640a6c868bc9a2bd4eb49611e4138ff88d8d260`），
device observation registry 只接受 hdc `3.2.0f`
（SHA-256 `05b2bf7ad30201c082da336db28f8856952a2b2f49ac3404b96fdb4bf1a68f83`）。
当前主机只有后者，故单一候选无法同时建立 server generation/ownership 与设备事件。

CHG-2026-024 已受理 exact 3.2.0f 的工具身份、`127.0.0.1:8710` endpoint 和稳定
process/start/listener bracket，并在 production device source 中实现同一类 commandless
OS identity observer；但该 authority 仅登记为 device-observation precondition，不能被
server supervisor 暗中复用。把两个版本结果拼接、把 device registry 当 supervisor
registry、或从相似补丁版本推断兼容，都会越过 registry 与 provenance boundary。

本 change 建立一个独立、版本化的 3.2.0f commandless supervisor identity authority，
并让 production App 对同一候选显式采用它。它不改变 M0B 验收语义，不执行 HDC/设备，
也不宣称 `checkserver`、client/server/daemon version 或 health 已在 3.2.0f 上登记。

## What changes

### In scope

- 新增独立 registry
  `OPENHARMONY-HDC-SUPERVISOR-OBSERVATION-PROBES@1.0.0`，只登记 exact macOS /
  hdc `3.2.0f` / executable SHA-256
  `05b2bf7ad30201c082da336db28f8856952a2b2f49ac3404b96fdb4bf1a68f83` /
  endpoint `127.0.0.1:8710`；
- 登记 `serverIdentityGeneration` family 为
  `probeKind: platformProcessObservation`、`exactArgv: []`、
  `invocationAllowed: false`：通过 selected executable、exactly-one existing listener、
  PID/start/executable/listener 的稳定 pre/post equality 生成 identity receipt 与
  generation，全路径零 HDC child；
- provenance 只引用已由维护者 review/merge 受理的 CHG-2026-024 controlled capture
  （#656 `af6d64d67af98c94e1f03581de6f52ecdb8a6bb2`、#658
  `6df25c25d0088238ce2700db07c4db6fbd92cc34`）。readiness 必须重新判断这些
  inputs 是否足以支撑 supervisor family；不足则任务保持 `blocked`，不得用合成数据
  或 Agent/CI 实机调用补齐；
- bump OpenHarmony integration profile/lock，并在 macOS profile 添加本 family mapping；
  当前 3.2.0d readonly registry 与 3.2.0f device registry 保持各自独立、byte-identical；
- production composition 继续只选一个 `HDCCandidate`：exact 3.2.0f 候选同时进入新
  commandless supervisor identity route 与既有 device observation route；任何一侧
  都不得再次 discovery 或替换候选；
- 只有新 observer 自身铸造的稳定 receipt/generation 能进入既有 four-evidence ownership
  判断。3.2.0f route 不运行 `checkserver`，server health、client/server/daemon version
  无独立 registered source 时保持 typed unknown；既有 3.2.0d registered
  `checkserver` 行为保持不变；
- 添加 registry/resource hash closure、negative/fail-closed contract，以及同一候选
  production reachability contract。现有 diagnostics 字段足以表达 unknown 与 external，
  本 change 不增加 UI surface。

### Out of scope

- 修改 CHG-2026-006 的 task/readiness/evidence、执行 M0B hardware matrix、把本 change
  的 host-only 结果记作真实设备验收；
- 修改 Core Requirement/Acceptance Scenario、contracts/schema、hardware matrix 或
  Core baseline；
- Agent/CI 执行 installed HDC、访问真实设备、读取 raw device identifiers、启动/停止/
  restart/adopt server，或执行 subserver/device/binding/destructive mutation；
- 为 3.2.0f 登记或推断 `checkserver`、`hdc -v`、health、client/server/daemon version；
- 用两个候选、两个 endpoint、两个 session、caller-supplied receipt/generation、
  patch-version similarity 或 fallback 拼接 server 与 device 事实；
- 改写既有 `OPENHARMONY-HDC-READONLY-PROBES@1.0.0`、
  `OPENHARMONY-HDC-DEVICE-OBSERVATION-PROBES@1.0.0` 或其 resource pack；
- 改变 lifecycle、ownership、Job/journal/recovery、device binding 或 event
  disappearance 语义。

## Observable behavior before/after

- Before：exact 3.2.0f 候选可以执行已登记的显式 device refresh，但 server
  observation 返回 unsupported，generation/ownership 保持 unknown；App 不能用同一
  候选形成 CHG-2026-022 所需的完整诊断视图。
- After：在 exact tool/endpoint/existing-listener/stability 全部命中时，同一 3.2.0f
  候选可通过零 HDC child 的 OS observation 铸造 generation；既有 four-evidence
  判断可把真正 pre-existing 且无 managed provenance 的 server 分类为 external，
  同时 device refresh 仍只执行既有注册的单次 `list targets -v`。任一 mismatch/
  ambiguity/drift 都 fail closed，且不会触发 HDC child 或 lifecycle effect。

## Scope

- Canonical Core Requirements claimed:none（兼容实现既有 `REQ-HDC-002`、
  `REQ-HDC-003`、`REQ-HDC-004`、`REQ-UX-002`）
- Canonical Acceptance claimed:none
- Candidate integration profile:`OPENHARMONY-TOOLS@0.6.0`
- Candidate registry:`OPENHARMONY-HDC-SUPERVISOR-OBSERVATION-PROBES@1.0.0`
- Candidate lock:`INTEGRATION-PROFILES-0.7.0`
- Change-local acceptance:`HSO-REGISTRY-001`、`HSO-SEPARATION-001`、
  `HSO-SINGLE-CANDIDATE-001`、`HSO-NODISPATCH-001`
- Core baseline bump:no

Candidate version numbers are the next unused values at proposal base `193b19b…`; readiness
must re-audit main and re-pin them. A collision is a blocker, not permission to silently reuse
or overwrite a concurrent version.

## Platform impact

| Platform | Disposition | Reason |
| --- | --- | --- |
| macOS | integration mapping candidate; no conformance transition | 只增加 exact 3.2.0f commandless identity authority 与 consumer wiring |
| Windows | deferred / unchanged | port 未启动；无对应 process/listener observer 或 provenance |
| Linux | deferred / unchanged | port 未启动；无对应 process/listener observer 或 provenance |

## Safety, privacy, and compatibility

- 入口默认 unavailable/unknown；路径、hash、endpoint、listener count、PID/start 或
  pre/post equality 任一不匹配都不能产生 receipt/generation；
- receipt 必须由不可注入的 platform observer 从 OS process/socket state 生成；调用方不能
  同时构造事实和证明。caller-supplied PID/start/path/hash/endpoint 不具 authority；
- identity route 的 HDC child、server lifecycle/adoption、subserver、device/binding/
  destructive dispatch counter 必须全部为 0；显式 device refresh 仍至多执行既有
  registry 允许的一个 read-only child；
- process identity 只用于本机 session 内的 ownership/generation 判断，不引入 raw device
  identifier，也不新增持久敏感字段；
- rollback 先回退 production consumer，再回退新 registry/profile/lock；既有 3.2.0d
  supervisor 与 3.2.0f device observation authority 保持完整，3.2.0f server ownership
  安全退回 unknown。

## Approval and flow

本 proposal PR 只创建 change package，零 integration/production 实现、零 task 状态推进、
零 HDC/设备调用。批准须由后续独立 approval-only PR 完成；两个 task 初始均
`blocked`。批准合入后先对 `TASK-HSO-001` 走独立 readiness（D1），其
implementation/evidence 与 `ready→done` 各自独立；然后才能对依赖它的
`TASK-HSO-002` 走独立 readiness（D1）。本 change 全部 AC 通过后的 `verified`
翻转，以及 CHG-2026-006 `TASK-M0B-002` 的新一轮 readiness，也都必须使用独立 PR。

## Approval

- r1 proposal 经 PR #737 合入 protected main（squash
  `84728f1d16eb3dcd07fd869bee835b3d2397f118`，`status: proposed`）；维护者
  `lvye` 对 exact head `77efc7c078ae66c7465ae35f9feb1d6cfce0dbce` 的 review
  状态为 `APPROVED`。
- 正式批准：仅在维护者 review/merge 本 approval-only PR 后，本 change 的
  `status: approved` 才生效。该 D1 merge 表示维护者接受以下封闭范围：
  - **任务顺序**：`TASK-HSO-001` 先登记独立 exact 3.2.0f commandless supervisor
    identity authority；只有它经独立 implementation/evidence 与 `done` PR 合入后，
    `TASK-HSO-002` 才可进入自己的 readiness 并接 production；
  - **authority 与 composition 边界**：`serverIdentityGeneration` 仅允许
    `platformProcessObservation`、空 argv、不可调用；同一 production-selected
    candidate/endpoint 同时进入 supervisor 与既有 device route，不允许第二候选、
    fallback、跨版本事实拼接或 caller-supplied receipt/generation；
  - **语义与 effect 边界**：3.2.0f 不登记或推断 `checkserver`、`hdc -v`、health
    或 client/server/daemon version；既有 3.2.0d readonly 与 3.2.0f device
    registries/resources 保持独立且 byte-identical；identity bootstrap 的 HDC child
    与 lifecycle/adoption/subserver/device/binding/destructive dispatch 全部为 0；
  - **provenance 与验收边界**：CHG-2026-024 #656/#658 evidence 能否支撑新 family
    仍由 `TASK-HSO-001` readiness 独立判断，不足即保持 blocked；四条 `HSO-*`
    change-local AC、canonical Core AC 零认领、Core baseline 不升版，macOS mapping
    不产生 conformance transition。
- 本批准不执行 task、不接受 provenance 充分性、不固定 readiness pins，也不构成
  HDC/设备/hardware/support/release evidence。两个 task 继续保持 `blocked`；
  `TASK-HSO-001` 须下一独立 D1 readiness PR，`TASK-HSO-002` 仍受前者 `done` 门阻塞；
  CHG-2026-006 `TASK-M0B-002` 不因本批准自动 ready。

## Verification closure（2026-07-29）

TASK-HSO-001 与 TASK-HSO-002 已在 protected main 依序记为 done，四条 change-local
AC 均有同一 revision 的可复查 host-only evidence。本 PR 只翻 proposal /
verification 状态并引用已合入记录，零实现、零 scope、零 acceptance 定义变化。

Verification base = protected main
`205cfadcd296db7ec2fdc3f62d09e5047e5e5fa7`；该树的本文件、
`verification.md`、`tasks.md`、`acceptance-cases.yaml`、TASK-HSO-001 run 与
TASK-HSO-002 run 改前 blobs 分别为
`51c6304f7a080f01035580fc0593fe22460c1ba4`、
`831fc3b3a895fa6c2cc6966a7278ac58cb5828b4`、
`295e7a854764f35e81850c64b3a771caa2024c7b`、
`6b7becef9571c34a89e764240138879369e6653b`、
`db56cd004dd78295ab7129ee01f4f658cba71c9c` 与
`ba399ffb99dc3d67808c2500bcafb16ff3ff9047`。

### Protected-main delivery chain

| Stage | Exact reviewed head | Protected-main merge |
| --- | --- | --- |
| proposal #737 | `77efc7c078ae66c7465ae35f9feb1d6cfce0dbce` | `84728f1d16eb3dcd07fd869bee835b3d2397f118` |
| approval #738 | `a95ae3f229cf0f74bcc8681c92ce9239d1e1890e` | `07daee30ba99636b5dc7a334bdefc3a07611acef` |
| TASK-HSO-001 readiness #752 | `e49f9ba2161c72d4ef1e9c9bf5e25faf5c4b65d0` | `a2c275581ca6dce29414a47aafa59f6d7fa29f91` |
| TASK-HSO-001 implementation/evidence #755 | `38518eea9f487f76be2d065b882924376adbfdc3` | `4fc0cec76638cd299e6ccbaff7c5124a048a2106` |
| TASK-HSO-001 `ready→done` #756 | `30f816482a848f0943e58df5ff8bf5551257180e` | `248eb1e5348fb2bcc90c69af5d7b17c6954a99ca` |
| TASK-HSO-002 readiness #757 | `1b838caa4ebda5e5c31a830165e0c0fab8d0df5a` | `a6cd29318b8c86dcd02f13937b897aa64fa3a160` |
| TASK-HSO-002 implementation/evidence #760 | `e0f4b908eb6454e384b85a24fd598ed994126fb1` | `41e19225375ca65551d51251326169558c4e6980` |
| TASK-HSO-002 `ready→done` #761 | `93d2fdeafb87fcb9cf068a3fe68c5bc66309b979` | `205cfadcd296db7ec2fdc3f62d09e5047e5e5fa7` |

上述八个 exact head 均由维护者 `lvye` review/approve；各 PR 的 Agent PR /
SDD Guard / allowed-paths 与 Swift CI 均为 `SUCCESS`。Evidence 真值源为
`evidence/runs/TASK-HSO-001/run.md` 与
`evidence/runs/TASK-HSO-002/run.md`，不是“实现 PR 已 review”这一事实本身。

### Four binary AC conclusions

- **`HSO-REGISTRY-001` = PASS (`platform` + `contract`)**：TASK-HSO-001 run
  固定 exact commandless registry/resource/profile/lock/macOS/provenance closure；
  canonical registry、profile、lock、macOS mapping 与 dedicated contract test blobs
  分别为 `b202b9d34680a0e7bbdba1d02637279ca4819d3f`、
  `2ae13490e075f327bb7448ccacf908be5ba7e3aa`、
  `836d4ccc8c34c5826b6c53dcf9004e678a506d25`、
  `b7471666b0bbfbfade3fbd510ad831e45b3cf9b8`、
  `956a57fbe334248c4db3a13a7dab8d2561c02d63`，resource tree 为
  `87421493b8d353a402e0f777ef684e55db1f2981`。唯一 entry 固定 exact macOS
  hdc `3.2.0f` / executable SHA-256
  `05b2bf7ad30201c082da336db28f8856952a2b2f49ac3404b96fdb4bf1a68f83` /
  `127.0.0.1:8710` / empty argv / invocation forbidden，并保留 #656/#658 与
  `DEV-1` 窄边界。
- **`HSO-SEPARATION-001` = PASS (`contract`)**：3.2.0d readonly 与 3.2.0f
  device canonical registry blobs 保持
  `99e8cc3d9929f9502a3e978a53cd56ad285d2aad` /
  `399c5a102c7737bf6466e8a2c4c6a1d1b1bc0b6a`，resource trees 保持
  `f906403bc878a27dbef79736203da98c32a020eb` /
  `9ca93b91d18c554e4c137b7f3494550af072ebfc`；cross-version substitution、
  fallback、caller receipt/generation 与 semantic-authority mutation 全部 fail closed。
- **`HSO-SINGLE-CANDIDATE-001` = PASS (`contract`)**：TASK-HSO-002 run 与
  DP19/HSO contracts 固定一次 production discovery/endpoint selection、同一
  candidate/endpoint 进入 commandless supervisor 与既有 device session、共享
  exact-3.2.0f system observer implementation及独立 catalog policy；production
  source/test blobs 为 `589dfec329044b58f4fefec3a70d4af7f9cfd15e`、
  `c7f71e5af90bc3d468d5f0817734d297f0c339a2`、
  `fa0bc651382c9b5d1a36a46c59a11af65bc84249`、
  `e6556e053680550325491a5deac5c7eac9a09d96` 与
  `a54b950a67af564260efe55fb159e63a1847b59d`。stable receipt 只进入既有
  four-evidence classifier，任一证据缺失保持 unknown，health/version typed unknown。
- **`HSO-NODISPATCH-001` = PASS (`contract`)**：两个 run 共同覆盖 empty argv /
  invocation false、21 个 registry failure controls、10 个 effect counters、
  supervisor success/mismatch/failure/timeout/cancel 的零 dispatch 与 empty spawn
  audit；只有显式 device refresh 可产生至多一个既有 registered read-only child，
  且不授予 supervisor ownership。installed HDC、真实 process/socket/device、
  network、lifecycle/adoption、subserver、binding/device mutation 与 destructive
  dispatch 全部为 0。

### Closure-base replay and boundary

- macOS 26.6 (25G72)、Xcode 26.6 (17F113)、Swift 6.3.3 上四个 HDC 聚焦
  suites = 114 tests / 0 failures；ArkDeckKit 全量 = 506 tests / 1 个既有人工
  sleep/wake skip / 0 failures / 0 unexpected。
- `scripts/check-sdd.sh` = 0 errors / 0 warnings / 111 acceptance IDs；
  `scripts/test_check_sdd.py` = 56/56 PASS；
  `scripts/test_check_pr_paths.py` = 50/50 PASS；`git diff --check` = PASS。
- Core Requirement/AC、contracts/schema、baseline、platform conformance、
  hardware/support/release 与 production code 在本 closure PR 中零变化；host-only
  registration/fake/system-observer contract 不重分类为真实 HDC、设备或 hardware
  evidence。
- 本 closure 只确认 CHG-2026-043。它不自动推进或解除 CHG-2026-006
  `TASK-M0B-002`；后者仍须在本 verified PR 合入后另走 fresh readiness。
- 只有维护者 review/merge 本独立 verification-only PR 后，proposal 的
  `verified` 与 verification 的 `passed` 才生效。
