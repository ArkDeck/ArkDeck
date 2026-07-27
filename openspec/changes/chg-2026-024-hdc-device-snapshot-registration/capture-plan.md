# CHG-2026-024 controlled capture execution plan

> Status:plan-only (r3). Human maintainer execution only after the dedicated r3 governance PR
> is reviewed and merged, **and only after the r3 instrument-identity precondition below is
> resolved**. Agent/CI must not execute this plan, invoke installed HDC, inspect raw capture
> bytes or access a real device.

## r3 instrument drift and the decision it forces（2026-07-27；原 r2 正文如实保留）

**实测(Agent host 侧只读,零 HDC 调用)**:r2 钉定的 selected HDC
(`Ver: 3.2.0d` / SHA-256
`48395ba8d87115dffca47df2a640a6c868bc9a2bd4eb49611e4138ff88d8d260`)
**已不在本机**。当前唯一副本:

| 事实 | 值 |
| --- | --- |
| 路径 | `/Applications/DevEco-Studio.app/Contents/sdk/default/openharmony/toolchains/hdc` |
| 同字节副本 | `~/OpenHarmony/SDK/26.0.0/toolchains/hdc` |
| SHA-256 | `05b2bf7ad30201c082da336db28f8856952a2b2f49ac3404b96fdb4bf1a68f83` |
| size | 6,016,944 bytes；Mach-O 64-bit |
| 报告版本(**维护者 2026-07-27 实测 `hdc -v`**) | `Ver: 3.2.0f` |

搜索面:`/Applications`、`~/OpenHarmony`、`~/Library/OpenHarmony`、
`/usr/local/bin`、`/opt/homebrew/bin` 与 `~` 六层深度——全机仅此一个 hdc
二进制。成因推断(非断言):DevEco/SDK 升至 26.0.0(`~/OpenHarmony/SDK/26.0.0`
目录时间 2026-07-24,晚于 2026-07-22 AIN-004 E0 读回确认 `48395ba8…` 的时点)。
**版本来源与一处已更正的方法错误(如实记录)**:Agent 起草时用 `strings`
静态提取,得到 `Ver: 3.0.0b` 并据此误判为「降级」。维护者实测 `hdc -v`
输出 `Ver: 3.2.0f`,推翻该判断。事后定位根因:二进制里那条
`Ver: 3.0.0b` 位于 handshake/auth 字符串群中(邻接 `invalid auth type %d`、
`handshake info is : %s`、`daemonauthstatus`),是**协议握手常量**;真正的
客户端版本在运行时由格式串 `%x.%x.%x%c`(紧邻另一处空的 `Ver: `)拼出,
故 `3.2.0f` 在二进制中**不以文本形式存在**,`strings` 无论如何都找不到。
**通用规矩:`strings` 找到的版本字面量不能当作工具报告版本**——当版本由
printf 组装时,唯一权威来源是执行工具本身(本计划中该动作保留给人类),
或维护者的实测转录。本表 `3.2.0f` 即采后者;S0 步的 stdout 仍是窗口内的
最终判据。

### ⚠ 这不是一次单纯的重钉:两个后果必须由维护者显式接受

1. **是常规升级(d → f),但仍非同一工具**:`3.2.0f` > r2 钉定的 `3.2.0d`。
   同 minor 线的补丁级前进,grammar 大概率兼容,但**「大概率」不是证据**——
   本计划的存在意义正是对选定工具做可证伪判定,故 C0–C5 的输出结构仍须
   按新工具重新判定,不得以「只差一个字母」免测。
2. **跨 registry 版本不一致**:`3.2.0d`/`48395ba8…` 是**整个 openharmony
   integration profile 的注册工具身份**——`integrations/openharmony/
   readonly-probes.yaml` 的 `toolContext`(且其条目 ID 内嵌版本串,例:
   `openharmony-hdc-server-identity-generation-3.2.0d-macos`)、
   `integrations/openharmony/profile.md` 的观测来源、
   `integrations/openharmony/trace-probes/1.0.0/{registry.yaml,resources.json}`,
   以及 `verification/hardware-matrix.md` 两行 `observed`/`verified`
   (`EVD-M0B-DAYU200-20260718-001`、`EVD-RF002-DAYU200-20260721-001`)。
   在 3.2.0f 上采集并注册 device-observation family,会使该 family 的工具
   身份与全部同胞 family 相左,并进入 TASK-I24-001 必须产出的
   `INTEGRATION-PROFILES-0.5.0` 共享 lock。既有记录是历史观测,不因此变假;
   但**新数据与它们不是同一工具的产物**。注意方向:此处落后的是 profile
   (仍钉 3.2.0d)而非本次采集,故除下列三选项外另有第四条路(见 (D-4))。

### r3 precondition:instrument-identity decision（gate,未解不得开窗）

维护者必须在合入本 r3 时于 PR 中显式选定其一并记录理由:

- **(D-1) 恢复 3.2.0d**:取回 pin 命中的旧副本后按 r2 原文执行。**代价**=
  刻意固定在更旧的工具上,且需找回已不在机的二进制;仅在需要与既有
  registry 逐字同源时才合理。
- **(D-2) 接受双版本 profile(推荐的最小步)**:在 3.2.0f 上采集,接受
  device-observation family 的工具身份与同胞 family 不一致;此时
  TASK-I24-001 的 registry/lock/条目命名**必须显式携带 `3.2.0f`**,
  evidence 与 profile 必须写明「本 family 观测自 3.2.0f,与
  readonly-probes/trace-probes 登记的 3.2.0d 非同一工具」,不得静默混编。
- **(D-3) 暂缓**:TASK-I24-001 保持 `blocked`,等工具面统一后再开窗。
- **(D-4) 先统一 profile 再采集**:另立独立 change,把 openharmony
  integration profile 整体从 3.2.0d 迁到 3.2.0f(重观测 readonly-probes/
  trace-probes、更新 `toolContext` 与内嵌版本的条目 ID、hardware-matrix
  按既有 needsReverification 规则处置),其后本采集与全 profile 同源。
  **代价最高、结果最干净**;是否值得由维护者判断,不在本 r3 授权内。

选 (D-2) 时,下列 r2 pin 由本 r3 重钉;选 (D-1)/(D-3)/(D-4) 时本节不生效。



## Goal and result boundary

Determine whether the **selected exact HDC**(r2 = `3.2.0d`;r3 (D-2) = `3.2.0f`,见上方
instrument-identity decision)`list targets -v` on macOS can support a parameterized,
existing-server-only, zero-to-many device-observation family without server lifecycle, adoption,
subserver, device-mutation or destructive effects.

This capture produces candidate authoritative input only. It does not register the family, make
TASK-I24-001 ready/done, prove authorization/binding/channel protection, or establish hardware,
compatibility, conformance, support or release evidence. Provenance acceptance occurs only when
the maintainer reviews and merges the later evidence PR.

## Fixed instruments

### HDC capture harness

Use `scripts/m0b_capture/capture.py` **AS-IS** from the reviewed checkout. At the r2 planning
base `628653c69afdf5f1b3c69e0b9eda03ba111fa5bc`:

- `capture.py` Git blob OID:`47ee62f4486fdb9d2de71422ff69caf75a1ca7b5`;
- `capture.py` SHA-256:`be66c30e7db6839196f095724d9ee75a59d938a7e1e4ffa1f139e8f3df3760f8`;
- `test_capture.py` Git blob OID:`dd80592503d6dc29e17c51d13f9beee081af4655`;
- `test_capture.py` SHA-256:`466d9e81413a2d99a4d17c16ac6af626b12738c02bbb5babbbf572ff3fe79d97`.

The harness uses executable + argument arrays, a closed read-only allowlist, bounded separate
stdout/stderr capture, timeouts, per-stream hashes, repo-outside output enforcement and a
redacted-manifest gate. This plan selects only `hdc-version-flag` and
`hdc-list-targets-verbose`; it adds no argv or tool behavior. Any instrument hash/blob drift,
test failure or harness refusal stops the session; do not patch or work around it in the device
window.

The AS-IS manifest carries legacy constants `change: CHG-2026-006-dayu200-m0b-bringup`,
`task: TASK-M0B-001` and `transport: usb`. They identify the reused instrument, not this capture's
change/task or physical-state truth. The CHG-2026-024 evidence record must disclose and ignore
those three constants, and derive session/step facts only from the human attestation, raw hashes,
structural receipt and server brackets. Discovery runs have `serialPresent: null`; therefore all
raw discovery stdout is presumed identifier-bearing even when the self-check passes.

Before touching installed HDC, the human operator runs the fake-only harness test:

```text
python3 scripts/m0b_capture/test_capture.py
```

Expected result at the planning base:50 tests, `OK`, installed-HDC/device dispatch 0.

### Host observation bracket

The human operator records these commandless host observations to the same controlled session
directory. They are not HDC dispatches and must use literal arguments—no command substitution,
pipeline or free-form wrapper:

| ID | Fixed command shape | Required fact |
| --- | --- | --- |
| `OB-1` | `ps -axo pid,ppid,lstart,command` | exactly one pre-existing HDC server candidate; PID/start identity/executable |
| `OB-2` | `lsof -nP -a -p <literal-server-pid> -iTCP` | exact listener endpoint and connections |
| `OB-3` | `shasum -a 256 <absolute-hdc-path>` and `stat <absolute-hdc-path>` | selected client executable identity |

Raw `OB-*` output stays outside git. If `OB-1/OB-2` is absent, ambiguous, cannot identify the
exact executable/endpoint, or shows a changed server across a bracket, do not run/continue the
HDC family. Starting, stopping, restarting, adopting or reconfiguring a server to make the
precondition pass is prohibited.

## Fixed session context

Record before C0 and retain outside git:

- human operator and UTC start time;
- macOS build and architecture;
- absolute selected HDC executable path, `OB-3` identity and expected SHA-256:r2 =
  `48395ba8d87115dffca47df2a640a6c868bc9a2bd4eb49611e4138ff88d8d260`(`3.2.0d`);
  **r3 (D-2) = `05b2bf7ad30201c082da336db28f8856952a2b2f49ac3404b96fdb4bf1a68f83`**
  (`3.2.0f`,6,016,944 bytes,路径
  `/Applications/DevEco-Studio.app/Contents/sdk/default/openharmony/toolchains/hdc`);
  实测哈希与选定值不符即停;
- normalized exact endpoint `127.0.0.1:8710` and the fixed child environment below;
- stable pre-existing `serverIdentityGeneration` from `OB-1/OB-2`;
- controlled output root outside every git repository, directory mode `0700`, files `0600`;
- physical device state for each step, confirmed by the human operator.

The harness itself does not override ambient environment. To make the selected endpoint and child
environment reviewable, every harness invocation in this plan is launched through
`/usr/bin/env -i` with exactly these keys:`HOME` (literal operator home, raw-only),
`TMPDIR=/private/tmp`,
`PATH=/usr/bin:/bin:/usr/sbin:/sbin`, `LANG=C`, `LC_ALL=C` and
`OHOS_HDC_SERVER_PORT=8710`. Do not add inherited keys. `OB-2` must show the same normalized
`127.0.0.1:8710` listener before and after every invocation; any other host/port is a stop.

After the existing-server precondition is proven, capture the client version once through the
allowlisted harness into a fresh `S0-version` directory. Replace placeholders manually with
literal absolute paths; do not use variables or command substitution:

```text
/usr/bin/env -i \
  HOME=/absolute/operator/home \
  TMPDIR=/private/tmp \
  PATH=/usr/bin:/bin:/usr/sbin:/sbin \
  LANG=C \
  LC_ALL=C \
  OHOS_HDC_SERVER_PORT=8710 \
  /absolute/path/to/python3 /absolute/path/to/ArkDeck/scripts/m0b_capture/capture.py \
  --hdc /absolute/path/to/hdc \
  --out-dir /absolute/outside-repository/session/S0-version \
  --commands hdc-version-flag
```

The retained stdout must contain the pinned literal:r2 = `Ver: 3.2.0d`;**r3 (D-2) =
`Ver: 3.2.0f`**(源 = 维护者 2026-07-27 实测转录;本步是它在受控 harness 下的
复证——stdout 与之不符,无论更高或更低版本,一律停并如实记录实际值)。
nonzero exit, stderr, timeout, truncation, self-check failure or version/hash
drift stops the session.

## Observation procedure

For every observation below, the operator performs `OB-1/OB-2` immediately before and after the
harness invocation and records both outputs. Pre/post PID, start identity, executable and exact
listener endpoint must match. The exact argv selected by the harness is
`[<absolute-hdc-path>, "list", "targets", "-v"]`.

Use a fresh non-existing output directory for each step:

```text
/usr/bin/env -i \
  HOME=/absolute/operator/home \
  TMPDIR=/private/tmp \
  PATH=/usr/bin:/bin:/usr/sbin:/sbin \
  LANG=C \
  LC_ALL=C \
  OHOS_HDC_SERVER_PORT=8710 \
  /absolute/path/to/python3 /absolute/path/to/ArkDeck/scripts/m0b_capture/capture.py \
  --hdc /absolute/path/to/hdc \
  --out-dir /absolute/outside-repository/session/<STEP> \
  --commands hdc-list-targets-verbose
```

| Step | Human-controlled physical state | Required observation |
| --- | --- | --- |
| C0 | zero target devices attached | successful zero-row candidate; otherwise `observedEmpty` remains unsupported |
| C1 | attach first supported device | one complete connected row |
| C2 | no physical change | repeat yielding the same one-device semantic set |
| C3 | attach a second supported device | complete two-or-more-row output proving parameterization and row boundaries |
| C3R | no physical change | repeat multi-row snapshot; row order is recorded as presentation only, never identity authority |
| C4 | detach one device | successful remaining-device snapshot |
| C5 | detach final device | successful zero-row candidate matching C0 semantics |

Only the human operator performs the physical attach/detach actions. Do not run device-targeted
commands, trigger trust/authorization changes, create or modify durable binding, migrate devices,
or mutate device state. Do not run another HDC client concurrently in the capture window.

## Per-observation acceptance facts

For S0 and each C-step, retain and later summarize:

- exact UTC time, physical state and argv-array ID;
- exact six-key sanitized child environment and normalized endpoint;
- pre/post `OB-1/OB-2` hashes and the stable PID/start/executable/endpoint facts;
- exit code, elapsed time, cancellation disposition and timeout flag;
- stdout/stderr byte counts, complete SHA-256 and truncation flags;
- row count and redacted structural receipt:delimiter, column count/order, fixed non-sensitive
  state/transport/host literals and dynamic-field lengths only;
- harness manifest/redacted-manifest SHA-256 and `selfCheckPassed` result;
- effect counters:serverStart/serverStop/serverRestart/serverAdoption/subserverLifecycle/
  deviceMigration/deviceMutation/destructive all 0.

The zero effect counters are supported jointly by the closed selected command ID, the harness
argv/no-shell contract, stable pre/post server brackets and the human operator's physical-action
attestation. Missing any component leaves the candidate unsupported.

## Repository-safe handoff

Raw stdout/stderr, full manifests, `OB-*` output, absolute user paths and raw device identifiers
stay in the operator-controlled location outside git. Do not paste them into chat, issue, PR
comment, fixture or log.

The handoff to the Agent contains only:

1. the seven `redacted-manifest.json` files for C0/C1/C2/C3/C3R/C4/C5 plus S0 version;
2. the per-observation facts above, with raw identifiers replaced by stable session-scoped
   placeholders;
3. complete SHA-256/length/row-count tables for the outside-repo raw files;
4. human operator/time/physical-state attestation, stable bracket conclusion, effect-counter
   conclusion and every deviation/stop condition;
5. `accepted-by: pending maintainer evidence-PR review` until that later PR is merged.

The Agent may inspect only this repository-safe handoff, verify hashes/structure and draft the
evidence record. The Agent never receives or reads the raw streams.

## Stop conditions

- instrument/blob/hash/test drift or harness refusal;
- selected HDC hash/version drift(以 instrument-identity decision 选定值为基准);
- (D-2) 下 registry/lock/条目命名未显式携带所采集的工具版本(`3.2.0f`),
  或 evidence 未写明与同胞 family(`3.2.0d`)的工具版本差异;
- server absent, ambiguous, substituted, endpoint-drifted or generation-changed;
- any lifecycle/adoption/subserver/device-migration/device-mutation/destructive effect observed
  or uncertain;
- nonzero exit, stderr, timeout, cancellation, truncation, invalid encoding or self-check failure;
- zero devices cannot be distinguished from failure/unknown;
- multi-row boundaries or dynamic fields cannot be expressed as a closed bounded grammar;
- raw identifier/path/key leakage into any repo-facing artifact;
- concurrent HDC client or inability to preserve the physical-state sequence.

On any stop condition, stop without improvising, keep raw material outside git, and report a
blocked attempt. TASK-I24-001 remains `blocked`; no readiness or implementation PR may proceed.
