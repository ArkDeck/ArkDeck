# CHG-2026-024 controlled capture execution plan

> Status:plan-only (r2). Human maintainer execution only after the dedicated r2 governance PR
> is reviewed and merged. Agent/CI must not execute this plan, invoke installed HDC, inspect raw
> capture bytes or access a real device.

## Goal and result boundary

Determine whether exact HDC 3.2.0d `list targets -v` on macOS can support a parameterized,
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
- absolute selected HDC executable path, `OB-3` identity and expected SHA-256
  `48395ba8d87115dffca47df2a640a6c868bc9a2bd4eb49611e4138ff88d8d260`;
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

The retained stdout must contain the pinned literal `Ver: 3.2.0d`; nonzero exit, stderr,
timeout, truncation, self-check failure or version/hash drift stops the session.

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
- selected HDC hash/version drift;
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
