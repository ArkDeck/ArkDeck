# TASK-AIN-010P readiness audit r1 — blocked on production bootstrap and hardware facts

## Classification

- Date:`2026-07-29T00:25:25Z`.
- Audit base:`7a7f9db3de389b94c72e9a0d0a57fe4e0c488788`（PR #763 merge）。
- Method:host-only protected-main/dependency、production source、local product
  configuration、exact executable identity、existing-listener、durable storage、
  allowed-path 与 privacy audit。
- Result:**blocked**。TASK-AIN-010P 保持 blocked；本记录不批准 candidate argv，
  不创建 binding/capability/authorization/integration support，不运行 HDC/device。
- Installed-HDC child / HDC server lifecycle / device command / product-device network /
  deviceMutation / destructive dispatch:
  `0 / 0 / 0 / 0 / 0 / 0 / 0`。

## Approval, dependency, and collision audit

- r5 scope PR #763 exact head
  `8f3f791ba937e0b7fd88118e249dae4bea4bcdf4` 经维护者 `lvye`
  `APPROVED`（review timestamp `2026-07-29T00:15:44Z`），以 audit base
  `7a7f9db3de389b94c72e9a0d0a57fe4e0c488788` 合入。reviewed head 与
  merge 后 r5 tree 的语义由 squash merge 账本关联。
- TASK-AIN-010 已由 #758 implementation + #759 done 关闭；CHG-2026-043
  TASK-HSO-002 已由 #760 implementation + #761 done 关闭。两项 dependency 已满足，
  但都不自动建立本任务 readiness、device tuple 或 dispatch authority。
- audit 时 open PR 数为 0。allowed
  `AgentReadOnlyRegistration/**`、`AgentDeviceOperations/E0Registration/**`、
  `ArkDeckE0ProbeRegistrar/**`、task-local test 与本 run 目录在 base 均不存在，
  无 new-file collision。

## Pinned protected-main inputs

| Input | Git blob OID | Readiness observation |
| --- | --- | --- |
| r5 proposal | `64280cb4b37556e1b45187025591251419dee0b0` | 010P 只可做 closed Agent E0 registration；人工命令为 0 |
| base tasks | `8b19e14afe46cc082273c8cf789582adb69ea77b` | 必须固定 device/build/HDC、8 argv、budgets、storage、V3 instance、human/privacy boundary |
| r5 verification | `cd1f35c0d21e574bd70021a9bff329dba705ed91` | real-device V3 + raw local-only + zero E1/E2/lifecycle |
| change-local V3 evidence schema | `492aa3d5107c6790f56df1fff336280578494364` | Agent E0 record需要 ready-task `authorizationRef` 与 machine target confirmation |
| OpenHarmony profile | `2ae13490e075f327bb7448ccacf908be5ba7e3aa` | `OPENHARMONY-TOOLS@0.6.0`；HiLog/HiDumper/current Trace bytes 待 registration |
| integration lock | `836d4ccc8c34c5826b6c53dcf9004e678a506d25` | `INTEGRATION-PROFILES-0.7.0`；3.2.0f authorities 必须保持分离 |
| 3.2.0f device registry | `399c5a102c7737bf6466e8a2c4c6a1d1bc0b6a` | exact `list targets -v`，existing-server + stable brackets required |
| 3.2.0f supervisor registry | `b202b9d34680a0e7bbdba1d02637279ca4819d3f` | commandless observer；empty argv/invocation forbidden |
| `HDCProduction.swift` | `c7f71e5af90bc3d468d5f0817734d297f0c339a2` | discovery/identity-bound runner exists；registered command families remain closed |
| supervisor production source | `589dfec329044b58f4fefec3a70d4af7f9cfd15e` | exact 3.2.0f existing-listener observer；does not start server |
| App production composition | `fa0bc651382c9b5d1a36a46c59a11af65bc84249` | takes first production-discovered candidate; no selected-device binding bootstrap |
| durable binding adapter | `b07a8c7a8b5d45e335b2ec5dc04dd18cba48dde4` | reopen requires trusted Session/audit root and target ID |
| generic Agent host | `d5509f326d53296c70ad10c3c3719fea1c5f1857` | E0 admission seam available; facts/authority/storage/dispatcher remain composition ports |
| HostStorage / SessionLayout / Artifact | `4685eaa4fabe73df8e2ee4b5dea57a0db5f2b3e2` / `ed48f90a96ee239769e86727ae9272017fea72f7` / `635f4da53094305dc52dff6ebdb26e1ccb026ea1` | allowed new code can compose bounded local raw publication without Storage edits |
| Package manifest | `292135a2c80c63ddf7182f58e2f81ff7c7d6104d` | executable target may be added only after readiness |

## Host and tool audit

Environment = macOS `26.6 (25G72)` / arm64 / Xcode `26.6 (17F113)` /
Apple Swift `6.3.3`.

The registered system candidate exists at the DevEco SDK path:

| Fact | Observed |
| --- | --- |
| file type/mode | regular executable, `0755` |
| size | `6,016,944` bytes |
| SHA-256 | `05b2bf7ad30201c082da336db28f8856952a2b2f49ac3404b96fdb4bf1a68f83` |
| registered reported version | `3.2.0f`（protected-main integration tuple；本 audit 未运行 `-v`） |

The bytes therefore satisfy the exact executable pin, but the **production selection and
execution environment do not**:

1. `com.arkdeck.desktop` has one persisted `ArkDeck.HDC.userConfiguredPaths` entry.
   It names a now-missing old `ArkDeckFakeHDCFixture-M1-006`; the user absolute path is
   intentionally omitted here. `ArkDeck.HDC.devecoSDKPaths` and
   `ArkDeck.HDC.openHarmonySDKPaths` are absent.
2. `lsof -nP -iTCP:8710 -sTCP:LISTEN` returned no row, and the process inventory contained
   no server using the selected executable. This is an absent existing-server prerequisite,
   not authority to start one.
3. `~/Library/Application Support/ArkDeck/` contains no Session, selected HDC binding,
   device-binding journal or target-selection record. The audit enumerated names only and did
   not read host-loop token contents or historical `Characterization/**` stdout/stderr. Those
   characterization files are task-specific past probe output, not a durable target binding.

## Blocking findings

### B1 — production discovery cannot select the exact real candidate

`HDCApplicationDiagnosticsConfiguration.discoveryRequest()` prioritizes restored
user-configured paths and otherwise uses explicitly configured SDK path arrays; it never searches
PATH or invents a DevEco location. The only persisted path is a missing fake fixture and both SDK
arrays are absent. Although the exact real bytes exist, a caller-free registrar cannot claim that
the current product selected them.

OS picker/configuration is an allowlisted human boundary, but it has not occurred for this
candidate. Agent mutation of UserDefaults/bookmark bytes would be credential/configuration
forgery and was not attempted.

### B2 — commandless server identity prerequisite is unavailable

The device registry requires an existing server on exact `127.0.0.1:8710` and stable pre/post
server identity. TASK-HSO-002 intentionally observes only; it does not start/adopt/restart a
server. TASK-AIN-010P forbids every server lifecycle effect and does not allow a human to run an
HDC command.

With no listener present, even `list targets -v` was not run: an HDC child could implicitly start
a server and would cross the registered effect boundary. The registrar therefore cannot obtain
registered device facts or safely materialize any targeted argv.

### B3 — no durable target source is reachable from the closed request

The current binding implementation is per Session. `DeviceBindingJournalAdapter.reopen` needs a
trusted Session audit store plus target ID; `currentDurableBinding()` only works after the initial
binding event is durable. The registrar request is deliberately limited to request/task identity
and cannot supply a Session root, target ID, connect key, revision or receipt.

No product-local binding record currently supplies those facts. A historical redacted serial
digest or a row captured by a human harness is not a durable `CurrentDeviceBinding` and cannot be
promoted by the Agent.

### B4 — exact device/build and V3 instance cannot be fixed honestly

Because B2/B3 prevent a fresh registered observation, current device presence, physical identity,
binding revision and firmware/build are unknown. The hardware matrix's
DAYU200/OpenHarmony `7.0.0.34` record used HDC `3.2.0d`; it is historical evidence, not proof that
the present 3.2.0f target still has that firmware.

Consequently a V3 `realHardwareE0ReadOnly` instance cannot yet truthfully fill
`physicalTargetConfirmation`, `device.serial`, `device.firmware`,
`device.bindingRevision`, `executedAt` or Artifact receipts. Placeholder bytes would be
schema-shaped fiction and are forbidden.

## Candidate capture plan reviewed, not approved

The following arrays are a bounded **candidate for the next D1 review**, not command authority:

| Typed step | Candidate HDC arguments |
| --- | --- |
| `hilogHelp` | `["-t","<durableConnectKey>","shell","hilog","--help"]` |
| `hilogHostStream` | `["-t","<durableConnectKey>","hilog"]` |
| `hidumperHelp` | `["-t","<durableConnectKey>","shell","hidumper","--help"]` |
| `hidumperInventory` | `["-t","<durableConnectKey>","shell","hidumper","-ls"]` |
| `hitraceHelp` | `["-t","<durableConnectKey>","shell","hitrace","--help"]` |
| `hitraceTags` | `["-t","<durableConnectKey>","shell","hitrace","-l"]` |
| `bytraceHelp` | `["-t","<durableConnectKey>","shell","bytrace","--help"]` |
| `bytraceTags` | `["-t","<durableConnectKey>","shell","bytrace","-l"]` |

The shape is informed by upstream HDC HiLog documentation and historical M0B/Trace capture, but
the latter is 3.2.0d provenance. It does not establish 3.2.0f output family, semantic success,
support or cross-version compatibility. No array was dispatched during this audit.

A later readiness should separately approve per-step deadlines/retained-byte ceilings, a whole
plan deadline/claim, SIGTERM→bounded SIGKILL cancellation for the stream, incomplete-drain and
truncation semantics, raw-local-only retention, and zero E1/E2/lifecycle counters. Proposed
starting point only: non-stream stdout/stderr `4 MiB` each, bounded HiLog stdout `16 MiB`,
per-step `30 s` except HiLog active window `15 s`, whole-plan `180 s`, and a
`128 MiB` HostStorage soft claim with explicit metadata/finalization headroom.

## Remediation proposal for a separate r6 D1 PR

Do not turn this blocked audit into an implicit scope grant. A separate proposal/scope revision
should add a product-owned bootstrap before another 010P readiness:

1. resolve the exact real HDC from protected configuration; the only human action is the existing
   OS picker/permission flow, after which Agent discovery/hash/descriptor revalidation is automatic;
2. when the endpoint has no server, use a closed typed product lifecycle path rather than a human
   HDC command. Because current server lifecycle is destructive/host-wide, an Agent path must have
   its own ready task and D2 standing authorization/impact pins, or remain fail-closed;
3. turn the maintainer-approved target selection plus fresh registered USB observation into a
   durable revision-1 binding, or expose an existing product-created binding through a closed
   resolver. Ambiguous/mismatched identity returns structured `humanActionRequired`;
4. add a closed E0 build/firmware readback candidate (or another protected, fresh build fact) so
   readiness does not borrow the historical 3.2.0d hardware tuple.

The revision must decide exact allowed source/config paths and sequencing. It must not let the
Agent self-approve a target, synthesize a binding from chat, search PATH, start an unknown server,
or treat a registration result as integration support.

After the revision/bootstrap/configuration/hardware prerequisites are merged and available,
TASK-AIN-010P needs a new D1 readiness that fixes the final device/build/HDC tuple, all eight (or
revision-approved expanded) argv, budgets, HostStorage layout, V3 field mapping,
human-boundary registry, privacy allowlist and negative matrix.

## Verification

- `git status` before edits:clean.
- `gh pr view 763`:MERGED, exact-head APPROVED by `lvye`, merge OID matches audit base.
- `gh pr list --state open`:0.
- protected-main/file identity audit:PASS.
- real HDC file stat/hash:PASS for exact registered bytes; no HDC invocation.
- persisted product configuration audit:BLOCKED (missing real selection; stale fake path).
- exact endpoint/process audit:BLOCKED (no existing server/listener).
- product storage name-only audit:BLOCKED (no durable target/binding/session).
- `./scripts/check-sdd.sh`:0 errors / 0 warnings / 111 acceptance IDs.
- `python3 scripts/test_check_pr_paths.py`:50/50 PASS.
- shared pinned Python `scripts/test_check_sdd.py`:56/56 PASS.
- `git diff --check`:PASS.
- raw device/log/key/token content read:0; user absolute preference path omitted.

## AC conclusion and remaining risk

- `AIN-E0-CAPTURE-001`:**NOT RUN / blocked before readiness**.
- Scope deviation:none.
- Remaining risk:the candidate argv/budgets still require D1 judgment and live device provenance;
  server startup/adoption is host-wide and cannot be silently reclassified as E0; initial target
  selection/build evidence needs an explicit product authority path. Until those close, process,
  HDC and device dispatch remain 0.
