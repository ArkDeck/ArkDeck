# CHG-2026-008 HiDumper Recipe capture runbook

> Status:Phase A (`TASK-UD-CAP-MUT-001`) becomes executable once the r4 readiness revision is
> merged and the maintainer confirms the device window; Phase B and all other tasks remain
> blocked.
>
> Real-device operator:human maintainer only. An Agent SHALL NOT execute installed `hdc`, create a
> real device session or run any device step.

## Purpose and authority boundary

This runbook fixes the candidate Recipe payload boundary and the fail-closed procedure for the two
human capture tasks (`TASK-UD-CAP-MUT-001` Phase A, `TASK-UD-CAP-R4-001` Phase B). The
authorization model is the M0B precedent (TASK-M0B-001): the human maintainer personally executes a
closed command list under this runbook, records byte-exact evidence, and the maintainer's
review/merge of the evidence PR is the attestation. No production supervisor, durable binding
workflow, journal authorization or offline receipt verifier is a prerequisite; those concepts stay
out of this change (see tasks.md 裁剪任务记录 and the JAUTH backlog entry).

Phase A may capture only R1-R3. Phase B (R4) cannot become ready until an approved R2
output-family decision exists and records the selected component token.

The reviewed OpenHarmony source is useful only for static routing analysis:

- [`window_window_manager`](https://gitee.com/openharmony/window_window_manager/blob/b5df00fb15aa99734c2ec8f73cfd0219389314c6/window_scene/session_manager/src/scene_session_manager.cpp)
  routes window detail tails into the session/ArkUI dump path;
- [`pipeline_context.cpp`](https://gitee.com/openharmony/arkui_ace_engine/blob/30c7d1ee12fbedf0fabece54291d75897e2ad44f/frameworks/core/pipeline_ng/pipeline_context.cpp)
  routes `-default` to default output and `-element` through size/scroll branches;
- [`dump_log.cpp`](https://gitee.com/openharmony/arkui_ace_engine/blob/30c7d1ee12fbedf0fabece54291d75897e2ad44f/frameworks/base/log/dump_log.cpp)
  can create `<application-data-dir>/arkui.dump` from its size-based path.

Those commits are not a byte-traceable source mapping for the DAYU200 target firmware. They cannot
prove target output mode or lower an effect. Under `dump-recipes.yaml`, unresolved output behavior
is `unsupported-fail-closed`. Therefore the **first target execution of every Recipe R1-R4 is
conservatively `deviceMutation`**. There is no stdout-only/readOnly Recipe capture in r3, and the
classification is never lowered after execution.

## Fixed target/tool tuple

- Device candidate:`DAYU200 (RK3568)`, OpenHarmony `7.0.0.34`, API `26.0.0`, USB. This is only the
  expected physical tuple.
- HDC executable:
  `/Applications/DevEco-Studio.app/Contents/sdk/default/openharmony/toolchains/hdc`.
- Expected HDC SHA-256:
  `48395ba8d87115dffca47df2a640a6c868bc9a2bd4eb49611e4138ff88d8d260`.
- Expected HDC version:`Ver: 3.2.0d`. These facts come from merged M0B evidence; the readiness PR
  and the run itself must re-verify hash/version and record the observed values in `run.md`.
- Raw output root:a new operator-controlled `0o700` directory outside every git repository. Raw
  files are `0o600` and never enter ArkDeck git history.

## Human preflight (per session and per Recipe batch)

The operator is a human maintainer. HDC client commands may implicitly start the host server (known
M0A/M0B fact); that is accepted for human capture exactly as in M0B. Explicit server lifecycle or
subserver commands (`kill`, `start`, `spawn-sub`, `killall-sub` and equivalents) are never used.

| ID | Step | Required recorded result | Stop condition |
| --- | --- | --- | --- |
| `HP-0` | verify HDC executable hash + `hdc version` | binary SHA-256 and reported version equal the pinned M0B values (drift recorded and run stops) | hash/version mismatch |
| `HP-1` | `hdc list targets` | exactly one expected DAYU200 target in `Connected` state; output recorded (redacted per capture conventions) | zero, multiple or ambiguous targets |
| `HP-2` | re-run `hdc list targets` immediately before each Recipe batch | same single target, same connect key | any drift |

The connect key is taken by the operator only from the same-session `HP-1`/`HP-2` output. Every
device command carries an explicit `-t <connectKey>`; the HDC default-target form is forbidden. The
connect key and serial bytes never enter the repository: redacted manifests use the constant
placeholder convention and the serial appears only in `hardware-evidence.json` device identity
fields (M0B precedent). The old M0B connect key value is never assumed still valid — it must be
re-observed in `HP-1`.

The operator physically confirms the device on the desk is the expected DAYU200 (model/serial as
recorded in hardware evidence) before `HP-1` and re-checks cabling before each batch.

## Candidate Recipe argv matrix (non-executable at r3)

Every row below is a process argv array. There is no host shell. The payload after the final `-a`
is one array element containing spaces; quote characters are not part of it. Split-token/
quoted-string fallbacks are forbidden, and a failed attempt is never retried with another boundary.

`WINDOW_ID` is a strict ASCII-decimal value read from the recorded output of the window-inventory
command `INV-1`, fixed at r4 as:

| ID | Purpose | Exact host argv | First-target typed mode/effect |
| --- | --- | --- | --- |
| `INV-1` | all-window inventory (WinId source) | `[HDC, "-t", CONNECT_KEY, "shell", "hidumper", "-s", "WindowManagerService", "-a", "-a"]` | conservative `deviceMutation` (first execution; output family unregistered) |

Official hidumper documentation confirms the `-a` payload prints full window information including
`WinId`. The window rule: select the unique foreground window whose entry corresponds to the
fixture bundle/ability (`com.example.waterflowdemo` / `EntryAbility`); zero or multiple candidates
stop the run. `INV-1` output is recorded as its own separate stream pair and remains
`unknownOutput` as a family until a decision revision registers it; only the `WinId` field is read
under the window rule.

### Phase A — TASK-UD-CAP-MUT-001 (R1-R3 only)

| ID | Recipe | Exact host argv | First-target typed mode/effect |
| --- | --- | --- | --- |
| `R1` | `nodeSummary` | `[HDC, "-t", CONNECT_KEY, "shell", "hidumper", "-s", "WindowManagerService", "-a", "-w WINDOW_ID -default"]` | conservative conditional-sidecar `captureRemoteFile` / `deviceMutation` |
| `R2` | `elementTree` | `[HDC, "-t", CONNECT_KEY, "shell", "hidumper", "-s", "WindowManagerService", "-a", "-w WINDOW_ID -element -c"]` | possible sidecar/UI-state change `captureRemoteFile` / `deviceMutation` |
| `R3` | `fullDefaultTree` | `[HDC, "-t", CONNECT_KEY, "shell", "hidumper", "-s", "WindowManagerService", "-a", "-w WINDOW_ID -default -all"]` | conservative conditional-sidecar `captureRemoteFile` / `deviceMutation` |

### Phase B — TASK-UD-CAP-R4-001 (blocked until the R2 decision)

| ID | Recipe | Exact host argv | First-target typed mode/effect |
| --- | --- | --- | --- |
| `R4` | `componentDetail` | `[HDC, "-t", CONNECT_KEY, "shell", "hidumper", "-s", "WindowManagerService", "-a", "-w WINDOW_ID -element -lastpage COMPONENT_ID"]` | possible sidecar/UI-state change `captureRemoteFile` / `deviceMutation` |

`COMPONENT_ID` is never typed ad hoc. After Phase A, an approved R2 output-family decision revision
must record the selected component token, the location/basis of that selection inside the R2
derived output, and the R2 raw-origin hash. Zero candidates, ambiguity, or an unknown/truncated/
failed R2 output keeps R4 blocked. CLI/env/file/manual component input is forbidden.

## Fixture HAP (pinned at r4)

- Artifact:`entry-default-signed.hap`, SHA-256
  `9453a396e81d55abfb05b4d7f9a512dea139e5843462051a6e1cc3586849fac8` (maintainer-built DevEco
  sample; the local path stays out of the repository and is recorded in `run.md` with a fresh hash
  recomputation before install).
- bundleName `com.example.waterflowdemo`; mainElement/ability `EntryAbility`; versionCode
  `1000000`; compileSdkVersion `26.0.0.25`; debug-signed (read from the artifact's `module.json`).
- Static screen content:WaterFlow layout sample with synthetic list data; no user or sensitive
  content.

Fixture lifecycle commands (human-executed, each recorded; first executions conservatively
`deviceMutation`):

| ID | Action | Exact host argv |
| --- | --- | --- |
| `FX-1` | install | `[HDC, "-t", CONNECT_KEY, "install", LOCAL_HAP_PATH]` (`LOCAL_HAP_PATH` = the pinned-hash artifact; path recorded in run.md) |
| `FX-2` | start | `[HDC, "-t", CONNECT_KEY, "shell", "aa", "start", "-b", "com.example.waterflowdemo", "-a", "EntryAbility"]` |
| `FX-3` | stop | `[HDC, "-t", CONNECT_KEY, "shell", "aa", "force-stop", "com.example.waterflowdemo"]` |
| `FX-4` | uninstall (cleanup) | `[HDC, "-t", CONNECT_KEY, "uninstall", "com.example.waterflowdemo"]` (M0B precedent) |

## Exact-path sidecar inventory

The single literal owned remote sidecar path, pinned at r4:

```text
/data/app/el2/100/base/com.example.waterflowdemo/haps/entry/files/arkui.dump
```

Basis:ArkUI `dump_log.cpp` creates `<application-data-dir>/arkui.dump`, and official
documentation retrieves the component tree via `hdc file recv` from exactly this
`/data/app/el2/100/base/<bundle>/haps/entry/files/arkui.dump` pattern. `userId=100` is the
device-default main user assumption; if the target build differs, the pre/post inventory will
honestly record absent/absent, the sidecar is simply not collected, stdout capture is unaffected,
and switching to a global search is still forbidden (residual risk disclosed in the readiness).

The inventory command, fixed at r4:

| ID | Purpose | Exact host argv |
| --- | --- | --- |
| `SC-1` | pre/post existence + identity check | `[HDC, "-t", CONNECT_KEY, "shell", "ls", "-l", "/data/app/el2/100/base/com.example.waterflowdemo/haps/entry/files/arkui.dump"]` |

Before each Recipe, the operator runs `SC-1` and records the output proving the path is absent
(error/nonzero exit). After the Recipe, the same command must distinguish a newly created regular
file (type/size/mtime recorded) from pre-existing, unchanged, symlink or ambiguous results. Only a
new file at the exact path proven to originate from this run may be received (`hdc file recv`) and
then removed; removal targets only that exact path. Global `/data` search, wildcards, symlink
following, recursive deletion and overwriting existing files are forbidden. If ownership is
unclear, the file is left in place and recorded as `needsAttention`. R1/R3 follow the same
conservative inventory even though a sidecar may not be expected.

## Result decision rules

For each attempted row, the operator records exact redacted argv, stdout/stderr separately,
optional sidecar origin, exit/signal/timeout, duration, byte counts, truncation flags and per-stream
SHA-256. A failed attempt is never retried with another boundary.

- Exit code `0` alone is not success.
- The observed `option ... missed` output family is explicit failure.
- Until an approved decision revision registers a Recipe-specific success family, every other
  completed Recipe output is `unknownOutput`; capture completion is not Recipe success.
- This change permits only text-marker or structural-parser families that have privacy-safe
  synthetic/derived positive conformance fixtures. A raw byte-fingerprint/digest family is
  unsupported and cannot be registered by the later decision revision; enabling one requires a
  separate approved change that first pins a privacy-safe seam through the production
  stream-to-digest path.
- Target drift (`HP-2`), output truncation, unowned/pre-existing path, unexpected extra path or
  cleanup uncertainty stops the run and preserves `outcomeUnknown`/`needsAttention` as applicable.

## Required real-hardware evidence

Each human capture task must contain in its evidence directory:

- `run.md` — commands, observed outputs (redacted), decisions, deviations, dispatch counts;
- `redacted-manifest.json` — per-stream metadata with connect-key placeholder and no user paths;
- `capture-hashes.md` — whole-stream SHA-256 per raw stream;
- `hardware-evidence.json` conforming to `openspec/contracts/hardware-evidence.schema.json`
  version `2.0.0` (provider `none`), stating claimed operator, physical target/serial, firmware,
  toolchain, transport, execution time, the task's exact acceptance ID, actual step kinds and
  artifact paths/hashes.

The evidence PR runs a JSON-schema validation of `hardware-evidence.json` and records the
validating tool's path and version in `run.md` at execution time (no pre-pinned tool hash).
Schema validation checks structure; the truth of the claimed operator and of the run narrative is
attested by maintainer review/merge of the evidence PR — the same trust root as every other
merge in this repository.

## Sensitive raw → repository-derived chain

All UI Dump raw output is sensitive by default. Raw stdout, stderr and sidecar bytes remain only in
the controlled directory. Repository golden fixtures are later produced as `derived`, never raw:

1. verify controlled raw SHA-256 against the merged capture manifest;
2. run the pinned `TASK-UD-REDACTOR-001` transform (`redact.py` with its versioned algorithm
   manifest and maintainer-approved safe-literal allowlist): strict UTF-8, deterministic typed
   ordinal placeholders, unknown/unclassified tokens fail closed, output-side sensitive-literal
   scan hard-fails before producing output;
3. the transform exclusive-creates the derived file and a `redaction-receipt` recording
   algorithm/manifest/allowlist hashes, raw hash/size, derived hash/size, replacement counts, the
   replay command line and `completedAt`; raw is opened read-only and never modified;
4. the derived bytes and receipt are committed by the `TASK-UD-001` golden PR. The maintainer reads
   the exact derived bytes in that PR; **merge is the privacy-review attestation** (M0B precedent).
   `TEST-INT-UD-GOLDEN-001` cross-checks the full hash chain (capture manifest raw hash →
   receipt → committed bytes) and runs a sensitive-literal scan over the committed fixtures.

`TASK-UD-001` never reads raw and never modifies the redaction toolchain. Raw/derived byte equality
is neither expected nor claimed.

## Prohibited actions at r3

- any implementation, installed-HDC invocation, device discovery or device command under these
  blocked tasks;
- explicit server lifecycle/subserver commands, or using drift/ambiguity as a reason to improvise;
- HDC default-target form, connect key from anywhere but the same-session `list targets` output,
  or committing connect-key/serial bytes;
- execution of R1-R4 as readOnly, ad-hoc window/sidecar inventory outside the fixed commands,
  split `-a` payload or fallback argv;
- R4 before the approved R2 decision, or a manually chosen component ID;
- global search, wildcard or recursive remote cleanup, or touching any path other than the fixed
  literal sidecar path;
- committing raw bytes, page text, package/ability/window/component identifiers or user paths;
- registering a raw byte-fingerprint/digest output family;
- PASS/done, compatibility, conformance, hardware-support or release claims from plan, source
  reading or fake output.
