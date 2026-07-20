# CHG-2026-008 HiDumper Recipe capture runbook

> Status:plan-only and non-executable. No real-device task in this change is `ready` at r3.
>
> Real-device operator:human maintainer only. An Agent SHALL NOT execute installed `hdc`, create a
> real binding or run any device step.

## Purpose and authority boundary

This runbook fixes the candidate Recipe payload boundary and the fail-closed prerequisites. It does
not create missing production authority. A later readiness revision may make a human task executable
only after it pins the registered server/device observations, durable binding loader, dedicated
fixture, exact-path inventory operation, journaled pre-dispatch authorization and semantic verifier
listed below. Phase A may capture only R1-R3. R4 is a separate Phase B task that cannot become ready
until approved R2 output-family and typed component-extractor decisions exist.

Journaled confirmation/append-chain dispatch authority is not defined by this runbook or CHG-008.
It changes accepted Core schema and Safety pass/fail, so it first requires a separately approved Core
MAJOR change with production task `TASK-JAUTH-CORE-001`, migration/recovery and cross-platform
conformance evidence, verified/archive closure and `CORE-3.0.0` ratification. CHG-008 must then retarget
that baseline. An offline receipt/verifier cannot substitute for production authority.

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
conservatively `deviceMutation`**. There is no stdout-only/readOnly Recipe capture in r3.

## Fixed target/tool tuple

- Device candidate:`DAYU200 (RK3568)`, OpenHarmony `7.0.0.34`, API `26.0.0`, USB. This is only the
  expected physical tuple; it is not a current binding.
- HDC executable:
  `/Applications/DevEco-Studio.app/Contents/sdk/default/openharmony/toolchains/hdc`.
- Expected HDC SHA-256:
  `48395ba8d87115dffca47df2a640a6c868bc9a2bd4eb49611e4138ff88d8d260`.
- Expected HDC version:`Ver: 3.2.0d`. These facts come only from merged M0B evidence and must be
  revalidated without invoking HDC before a later task can use them.
- Raw output root:a new operator-controlled `0o700` directory outside every git repository. Raw
  files are `0o600` and never enter ArkDeck git history.

The old M0B connect key is never reused. There is no operator-supplied `<CONNECT_KEY>` placeholder,
CLI flag, environment variable or editable config field in this runbook.

## Mandatory existing-server preflight

HDC client commands can implicitly start a host server. No HDC command, including `-v`,
`checkserver`, device discovery or a Recipe, may be used to learn whether the server precondition is
safe. The preflight is a closed typed sequence owned by `TASK-UD-PREFLIGHT-001`:

| ID | Typed operation | Required durable result | Dispatch gate |
| --- | --- | --- | --- |
| `SP-0` | commandless registered `serverIdentityGeneration` platform observation through the host-wide `HDCServerSupervisor` | exact endpoint, process/start identity, executable identity, client/server version, ownership and generation | absent server, `unknown` ownership, unknown generation/version/endpoint, unregistered receipt or identity ambiguity => all HDC dispatch `0` |
| `SP-1` | durable Job toolchain snapshot | HDC path/hash/version plus exactly the `SP-0` endpoint, ownership and generation | snapshot write/reopen mismatch => all HDC dispatch `0` |
| `SP-2` | same registered platform observation immediately before every HDC intent | byte/semantic equality with the pinned Job snapshot | absent/unknown/generation or ownership drift => intent/process dispatch `0` |
| `SP-3` | same registered platform observation immediately after every HDC outcome | same endpoint/process/start identity/ownership/generation | drift or observation failure => current outcome `outcomeUnknown`, remaining dispatch `0` |

`serverIdentityGeneration` is an approved family name in CHG-2026-015 design, but no completed
registration/adoption currently makes it executable. A future readiness revision must pin its
literal registry/profile version, entry hash, platform receipt schema and production adapter OID.
Until then `TASK-UD-PREFLIGHT-001` is blocked.

This change never starts, stops, restarts, adopts or reconfigures an HDC server. If `SP-0` observes
no existing server, the run stops. Establishing a server would require a separate approved
host-wide lifecycle task; chat confirmation or running a diagnostic command is not a substitute.
External ownership is permitted only as an observed stable value and automatic lifecycle/subserver
dispatch remains `0`.

## Mandatory durable CurrentDeviceBinding

After the server precondition is proven, `TASK-UD-PREFLIGHT-001` must create the initial binding
through the completed production device-targeting workflow, never through operator text input:

1. a registered no-server-start device discovery observation produces candidates while the `SP-0`
   server generation remains current. The family must be approved separately; the current
   `selectedDeviceAuthorizationBinding` family cannot mint an initial binding;
2. the human physically selects/confirms the exact DAYU200 identity. The M1-007 production
   `CurrentDeviceBinding` workflow appends `bindingCandidate` and `bindingConfirmed` to the
   repo-external locked Session journal before any device-scoped command. Revision starts at `1`,
   contains the selected connect key, identity snapshot/evidence, `confirmedBy:user` and channel
   protection, and survives close/reopen;
3. a registered `selectedDeviceAuthorizationBinding` observation is then materialized from that
   durable revision and must match its identity, authorization and revision. It cannot create or
   revise the binding;
4. a repo-safe binding receipt records `sessionId`, `jobId`, revision, candidate/confirmation event
   IDs, canonical binding-event hash, identity-snapshot hash, evidence IDs, toolchain snapshot hash,
   endpoint/ownership/generation and the external Session/journal locator ID. It contains neither
   connect key nor serial. A separately schema-validated physical-target confirmation receipt records
   canonical model/serial, claimed operator/attestation fields, `confirmedAt`/`validUntil`, binding
   revision and identitySnapshotHash; the serial also appears in the required hardware-evidence record.

The physical/binding confirmation applicable to any device intent must itself be a typed event written
by the trusted host entry point to that same locked Session/Job journal before the intent. The current
`journal-event.schema.json` has no task-applicable event kind linked to Manifest confirmation/execution
authority and no append-chain fields, so the external Core MAJOR's `TASK-JAUTH-CORE-001` must add the
approved delta, production store/entrypoint/gate and conformance evidence before this task can become
ready. A time string or imported receipt/manifest cannot mint authority.

The capture harness accepts only the receipt ID plus the **fixed expected binding revision**. It
opens the exact Session through the production durable store/loader, replays the locked journal,
verifies the binding-event hash and current revision, and materializes `-t <connectKey>` internally
from that revision. Before every device command it also appends a durable typed step intent whose
binding revision, target identity and arguments hash match the loaded binding. Missing Session,
stale/current-revision mismatch, candidate ambiguity, identity drift, loader substitution or
connect-key input from any other source yields intent/request/process dispatch `0`.

For every task-applicable confirmation, the production store emits a repo-safe confirmation-event
receipt and journal-authorization receipt. Together they bind journal/Session/Job identity,
confirmation/event IDs, canonical payload hash, strictly monotonic sequence, previous/append hashes,
the journal head, and the gap-free ordered slice through every related intent. Before each dispatch,
the harness uses the same serialized journal lane to validate the durable/current confirmation event,
append and fsync that planned intent, and prove its sequence is greater; the final journal receipt then
projects the complete confirmation-to-intents slice for offline verification. `decidedAt`/`confirmedAt`
is only an expiry input. Missing events, chain gaps, hash/head/session/job mismatch, sequence reuse/
non-monotonicity, or a confirmation event at/after an intent yields dispatch `0`. Later evidence cannot
repair or retroactively authorize that dispatch.

Before the first and every later device intent, the physical-target receipt must be current. Its
canonical model/serial must equal hardware evidence `physicalTargetConfirmation` and `device`, and
its identitySnapshotHash must equal the durable binding receipt plus every intent target identity.
A substituted device or expired confirmation stops before dispatch. These equalities are machine-
checkable; whether the claimed operator personally performed the confirmation is attested only by
maintainer review/merge, as required by `hardware-evidence.schema.json`.

M1-007 is currently not `done`, its real-device adapter is out of that task's scope, and the needed
registered discovery/selected-device adoption is not complete. Consequently the durable binding
cannot currently be produced and all capture tasks remain blocked.

## Candidate Recipe argv matrix (non-executable at r3)

Every row below is a process argv array materialized only from a durable binding revision. There is
no host shell. The payload after the final `-a` is one array element containing spaces; quote
characters are not part of it. Split-token/quoted-string fallbacks are forbidden.

`WINDOW_ID` is a strict ASCII-decimal typed value produced by an approved typed window-inventory
operation in the dedicated-fixture run, not operator text. The future readiness revision must
register that operation; the current ad-hoc `INV-1` command is not in `dump-recipes.yaml` and is not
executable.

### Phase A — TASK-UD-CAP-MUT-001 (R1-R3 only)

| ID | Recipe | Exact host argv after durable materialization | First-target typed mode/effect |
| --- | --- | --- | --- |
| `R1` | `nodeSummary` | `[HDC, "-t", BINDING[REVISION].connectKey, "shell", "hidumper", "-s", "WindowManagerService", "-a", "-w WINDOW_ID -default"]` | conservative conditional-sidecar `captureRemoteFile` / `deviceMutation` |
| `R2` | `elementTree` | `[HDC, "-t", BINDING[REVISION].connectKey, "shell", "hidumper", "-s", "WindowManagerService", "-a", "-w WINDOW_ID -element -c"]` | possible sidecar/UI-state change `captureRemoteFile` / `deviceMutation` |
| `R3` | `fullDefaultTree` | `[HDC, "-t", BINDING[REVISION].connectKey, "shell", "hidumper", "-s", "WindowManagerService", "-a", "-w WINDOW_ID -default -all"]` | conservative conditional-sidecar `captureRemoteFile` / `deviceMutation` |

### Phase B — TASK-UD-CAP-R4-001 (blocked after R2 decision)

| ID | Recipe | Exact host argv after durable materialization | First-target typed mode/effect |
| --- | --- | --- | --- |
| `R4` | `componentDetail` | `[HDC, "-t", BINDING[REVISION].connectKey, "shell", "hidumper", "-s", "WindowManagerService", "-a", "-w WINDOW_ID -element -lastpage COMPONENT_ID"]` | possible sidecar/UI-state change `captureRemoteFile` / `deviceMutation` |

Phase B cannot accept a manually supplied or merely decimal-looking `COMPONENT_ID`. After Phase A,
an approved decision revision must first register R2 success/failure/unknown output families and a
versioned typed component-tree extractor. The extractor registration pins source/resource path,
accepted input family, parser/adapter OID and SHA-256, typed output schema, deterministic fixture
selector and an exact zero/one/many rule. Its receipt binds the same R2 raw-origin hash, fixture/
window identity, parser hash and selection proof. Zero, multiple, unknown, truncated, stale or
foreign results stop before R4 request/process materialization. First/lowest-ID choice, regex-only
decimal validation, operator selection and `COMPONENT_ID` CLI/env/file inputs are forbidden.

For every row, the future task must pin a dedicated disposable non-sensitive fixture HAP and one
literal owned remote sidecar path. Before dispatch, an accepted, unexpired `actor=user`
`deviceMutation` confirmation manifest entry covers the Recipe, physical model/serial,
identitySnapshotHash, binding revision, server endpoint/ownership/generation, fixture hash/bundle/
ability/static screen, exact argv/arguments hashes, exact remote path, pre/post inventory, receive
and cleanup. The verifier recomputes its canonical scope hash and requires its related step/intent ID
set to be exact. Missing, extra, stale, substituted or scope-mismatched confirmation yields dispatch
`0`; a matching operator-name string is not treated as proof of a human actor.

The manifest entry is not authorization by itself. The trusted host entry point must first append the
matching typed accepted-confirmation event to the same production Session/Job journal. The pinned
confirmation-event and journal-authorization receipts must prove a gap-free append chain whose
confirmation sequence is strictly lower than every related intent. A backdated `decidedAt`, imported
manifest, run note, or evidence file cannot substitute for that pre-dispatch journal order.

The current `arkdeck-remote-operations` catalog has no exact-path sidecar inventory action, and
generic `verifyRemoteState(probeId, expectedState)` does not bind a remote path, exact argv, output
family or adapter. Therefore it is not an executable substitute. Before either phase can be ready,
an independent approved contract/integration change must register the closed operation across the
remote-operation catalog, workflow-step schema/registry and platform adapter/profile/lock. Its entry
must fix operation ID, typed arguments, minimum effect, exact argv array, output family/parser,
adapter OID/hash, literal path, existence/type/size/mtime/ownership receipt, timeout and cancellation;
shell/raw commands are forbidden. The readiness revision may only cite that merged entry OID/hash.

Before each Recipe the registered pre-receipt must prove the exact path absent. After it, the
registered post-receipt must distinguish a newly created regular file from pre-existing, stale,
unchanged, symlink or ambiguous identity, and stdout/stderr/optional sidecar remain separate raw
origins. Only a new exact owned path may be received and then removed by
`cleanupOwnedRemotePath(remotePath, ownershipEvidenceId)` using the ownership evidence produced by
the matching receipts. No global search, wildcard, symlink following, recursive removal, overwrite
or ownership inference is allowed. Phase B always has its own confirmation scope.

## Result decision rules

For each attempted row, the future harness records exact redacted argv, binding revision, server
generation, stdout/stderr separately, optional sidecar origin, exit/signal/timeout, duration, byte
counts, truncation flags and SHA-256. It never retries using another boundary.

- Exit code `0` alone is not success.
- Existing observed `option ... missed` output is explicit failure.
- Until an approved decision revision registers a Recipe-specific success family, every other
  completed Recipe output is `unknownOutput`; capture completion is not Recipe success.
- This change permits only text-marker or structural-parser families that have privacy-safe
  synthetic/derived positive conformance fixtures. A raw byte-fingerprint/digest family is
  unsupported and cannot be registered by the later decision revision. Enabling one requires a
  separate approved change that first pins a privacy-safe seam through the production stream-to-digest
  path.
- Server/binding drift, output truncation, unowned/pre-existing path, unexpected extra path or
  cleanup uncertainty stops the run and preserves `outcomeUnknown`/`needsAttention` as applicable.
- The conservative deviceMutation classification is never lowered after execution. Target evidence
  may support a later output-mode decision only through a separately approved revision.

## Required real-hardware evidence

Every human real-device task (`TASK-UD-PREFLIGHT-001`, `TASK-UD-CAP-MUT-001` and
`TASK-UD-CAP-R4-001`) must contain:

- `run.md`;
- `redacted-manifest.json` and whole-stream `capture-hashes.md` where applicable;
- a repo-safe binding/server receipt for the preflight task;
- schema-validated `physical-target-confirmation-receipt.json` and `confirmation-manifest.json`;
- schema-validated `confirmation-event-receipt.json` and `journal-authorization-receipt.json` proving
  the durable pre-intent append order;
- `hardware-evidence.json` conforming to
  `openspec/contracts/hardware-evidence.schema.json` version `2.0.0`.

The hardware record must state the claimed operator, physical target/serial, firmware, toolchain,
transport, execution time, exact task acceptance ID, artifact paths/hashes and actual step kinds.
`device.bindingRevision` is mandatory for these tasks despite being optional in the generic schema;
it must be a positive integer equal to the durable binding receipt and every device intent. Canonical
model/serial and identitySnapshotHash must also equal the physical-target receipt, binding receipt and
every intent. The server endpoint/ownership/generation and all receipt hashes are recorded under
`toolchain.other`. Claimed-operator/attestation fields must be internally consistent, while their
truth is established only by maintainer PR review—not by the schema or verifier.

The declared host validator is `/opt/homebrew/anaconda3/bin/jsonschema` version `4.17.3`, executable
SHA-256 `672885a523b0d538e4d734a9009d1678827facd27f2e634093e3bfc838392de7`.
The evidence PR must run:

```text
/opt/homebrew/anaconda3/bin/jsonschema -i <task-evidence>/hardware-evidence.json openspec/contracts/hardware-evidence.schema.json
```

Schema validation is necessary but never sufficient. Before a real-device task becomes ready,
`TASK-UD-HWE-SEM-001` must be done and the readiness revision must pin the verifier implementation
at `scripts/ui_dump_capture/verify_hardware_evidence.py`, its tests at
`scripts/ui_dump_capture/test_verify_hardware_evidence.py`, both file SHA-256 values, source commit
OID, fixed Python executable and the exact CLI declared in `tasks.md`, including physical-target,
confirmation-manifest, confirmation-event and journal-authorization inputs. It cross-checks canonical
model/serial/identity hash, positive exact binding revision, unexpired physical and task-applicable
confirmations, recomputed scope hash/related intent set, confirmation/event/payload hash equality, a
gap-free append chain and confirmation sequence strictly before every related intent, stable server
tuple, claimed-operator/attestation field equality, exact task/acceptance/step kinds,
resolvable artifact hashes and raw-outside-git privacy. It does not prove a person is human.
Missing/extra/unknown/mismatch/expired is nonzero. Schema-valid but semantically inconsistent negative
fixtures are mandatory. Any source/test/input-schema/CLI/interpreter hash drift blocks execution; no
network installation is allowed.

## Sensitive raw → repository-derived chain

All UI Dump raw output is sensitive by default. Raw stdout, stderr and sidecar bytes remain only in
the controlled directory. Before `TASK-UD-001` can become ready, `TASK-UD-REDACTOR-001` must be done
and pin `uidump-derived-redaction-v1` transform/finalizer sources, algorithm manifest, safe-literal
allowlist, transform/privacy-review receipt schemas, tests, commit OID, every file hash, fixed Python,
fixed Git and both exact CLIs. Repository golden fixtures are later produced as `derived`, never raw,
through a human-only two-stage task:

1. verify controlled raw SHA-256 against the merged capture manifest and decode UTF-8 strictly;
2. normalize line endings and tokenize through a versioned redactor and approved safe-literal list;
3. retain only allowlisted structural literals; replace IDs, package/ability/page/window/path/text
   and every unrecognized value with deterministic typed ordinal placeholders;
4. exclusive-create an immutable transform receipt recording algorithm/source/allowlist/raw/derived
   hashes, replacement counts, tool/path identities and transform completion time; it contains no
   reviewer/decision and is never edited;
5. a human reviews the exact derived bytes, then the pinned finalizer exclusive-creates a separate
   privacy-review receipt referencing the transform receipt hash, same derived hash, reviewer claim,
   approved/rejected decision, later review time and exact repository destination;
6. only `approvedForRepository` chains may be handed to TASK-UD-001, which copies the derived fixture
   and both repo-safe receipts under `.gitattributes`, profile/lock and Bundle resource hashes.

The exact CLIs are those declared in `tasks.md`; transform derived/receipt and review receipt first land
outside git. Before any bytes are read, both tools must validate `/usr/bin/git`, version
`git version 2.50.1 (Apple Git-155)`, SHA-256
`179301dcb41ea78accc3fa0048a7e6f6710d891945a751a34addd622020c1818`, then use only
`[/usr/bin/git, "-C", ARKDECK_ROOT, "worktree", "list", "--porcelain", "-z"]` without PATH, alias,
override or shell. They record raw/parsed inventory hashes, reject malformed/truncated/incomplete output,
reject any repository's `.git` worktree marker found by descriptor-based ancestor walk, and validate
an owner-only `0o700` controlled root outside every detected/registered git worktree, and walk every
path component with no-follow directory descriptors. All three data paths and their owner-only parents
remain beneath that root. Raw input is an owner-only `0o600` regular file with link count one, opened
read-only. Before creation their retained-parent identity plus basename, and after creation their file
descriptor identities, are pairwise distinct. Output and receipt must not exist and are created `0o600`
with exclusive-create/no-follow
semantics—never truncate or replace. Retained descriptors are revalidated after writing for root/
parent/file identity, mode, link count and worktree containment, while raw identity, size, mtime and
hash must remain unchanged. Alias, `..`, symlink/hardlink, existing target, parent swap, inventory
drift or any worktree breakout fails closed without overwriting raw or producing a committable fixture.
The transform receipt records those identities, pinned Git identity, open/create policy and inventory
hash in addition to content hashes. `TASK-UD-PRIVACY-REVIEW-001` owns real-raw transform and human
review; `TASK-UD-001` may only verify immutable transform + separate approved review receipts and copy
the approved derived bytes. It cannot read raw, run either tool, edit receipts, or change redactor/
manifest/allowlist. Unclassified content fails closed. Raw/derived equality is neither expected nor claimed.

## Prohibited actions at r3

- any implementation, installed-HDC invocation, device discovery, binding creation or device command
  under these blocked tasks;
- starting/stopping/restarting/adopting a server or using an HDC command to test server absence;
- operator-provided connect key, default HDC target, stale M0B endpoint or unfixed binding revision;
- execution of R1-R4 as readOnly, ad-hoc window/sidecar inventory, split `-a` payload or fallback argv;
- R4 before approved R2 family/extractor registration, decimal-only/manual component ID, or ambiguous
  extractor selection;
- schema-only hardware PASS, unpinned semantic verifier, missing/expired physical-target or mutation
  confirmation, missing/late/broken journal authorization chain, backdated confirmation used as
  authority, or identity/model/serial/scope/intent equality inferred rather than checked;
- treating journal authority as contract/integration-only, or proceeding before external Core MAJOR
  `TASK-JAUTH-CORE-001`, migration/recovery/conformance, archive and `CORE-3.0.0` ratification close;
- claiming that operator-string validation proves a human actor; authenticity comes only from
  maintainer PR review/merge;
- privacy-review raw access or TASK-UD-001 readiness before `TASK-UD-REDACTOR-001 done`, or changing its pinned source,
  manifest, allowlist, receipt schemas or transform/finalizer CLIs inside the golden implementation task; redactor
  input/output/receipt aliases, overwrite, symlink/hardlink, parent-race or git-worktree breakout;
- PATH/alias/unpinned Git inventory; writing reviewer/decision into transform receipt; missing,
  rejected, duplicate or mismatched separate privacy-review receipt; TASK-UD-001 raw access or
  transform/finalizer execution before `TASK-UD-PRIVACY-REVIEW-001 done`;
- registering a raw byte-fingerprint/digest output family without a separate approved privacy-safe
  production-stream conformance seam;
- sidecar search/overwrite, unowned cleanup, recursive delete or raw sensitive bytes in git;
- PASS/done, compatibility, conformance, hardware-support or release claims from plan/source/fake.
