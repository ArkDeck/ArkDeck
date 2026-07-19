# CHG-2026-008 HiDumper Recipe capture runbook

> Status:plan-only; becomes executable only after the r3 governance PR is reviewed/merged.
>
> Real-device operator:human maintainer only. An Agent may implement and offline-test the closed
> harness, but SHALL NOT execute installed `hdc` or any device step.

## Purpose and authority boundary

This runbook fixes the candidate argv matrix **before** target capture and separates candidates by
their approved output/effect mode. It does not declare any candidate compatible or successful.
Capture completion proves only that the approved command was executed and recorded faithfully;
success/failure/unknown output families are fixed later by a separate approved decision revision.

The output-mode split is based on a pinned WindowManager routing input plus the same behavior in two
pinned OpenHarmony ArkUI source inputs:

- OpenHarmony `window_window_manager` master commit
  `b5df00fb15aa99734c2ec8f73cfd0219389314c6`, where `GetSessionDumpInfo` returns inventory/detail
  text through the dump response and forwards the Recipe tail to the session/ArkUI dump path;
- `OpenHarmony-v6.0-Release` commit
  `4b074c8d79421c948dd2ab2510c691371fd0f8ff`;
- ArkUI master commit `30c7d1ee12fbedf0fabece54291d75897e2ad44f`.

In both, `-default` routes to `DumpLog::OutPutDefault` while `-element` routes to
`DumpLog::OutPutBySize`; the latter creates `<application-data-dir>/arkui.dump` when the output is
large or the target is a UI extension. The `-element -lastpage ...` path can also enter ArkUI scroll
handling, and the reviewed parameter-count branch means the `-element -c` candidate cannot be
treated as state-neutral either. These source pins are integration design inputs, not proof that
the target firmware has the same behavior; an unexpected target result remains `outcomeUnknown`
and cannot broaden the allowlist.

The reviewed source locations are the official OpenHarmony repositories
[`window_window_manager`](https://gitee.com/openharmony/window_window_manager/blob/b5df00fb15aa99734c2ec8f73cfd0219389314c6/window_scene/session_manager/src/scene_session_manager.cpp),
[`pipeline_context.cpp`](https://gitee.com/openharmony/arkui_ace_engine/blob/30c7d1ee12fbedf0fabece54291d75897e2ad44f/frameworks/core/pipeline_ng/pipeline_context.cpp),
and
[`dump_log.cpp`](https://gitee.com/openharmony/arkui_ace_engine/blob/30c7d1ee12fbedf0fabece54291d75897e2ad44f/frameworks/base/log/dump_log.cpp).

## Fixed target/tool tuple

- Device:`DAYU200 (RK3568)`, OpenHarmony `7.0.0.34`, API `26.0.0`, USB; the human must physically
  confirm the same target and a fresh confirmed binding immediately before dispatch.
- HDC executable:
  `/Applications/DevEco-Studio.app/Contents/sdk/default/openharmony/toolchains/hdc`.
- Expected HDC SHA-256:
  `48395ba8d87115dffca47df2a640a6c868bc9a2bd4eb49611e4138ff88d8d260`.
- Expected HDC version:`Ver: 3.2.0d`, taken from the already merged M0B evidence. The capture task
  must re-hash the executable without running it; a mismatch stops the run and requires a new
  revision.
- Raw output root:a new operator-controlled `0o700` directory outside every git repository. Raw
  files are `0o600` and never enter ArkDeck git history.

`<CONNECT_KEY>` is populated only from the fresh confirmed binding. `<WINDOW_ID>` and
`<COMPONENT_ID>` are populated only from outputs captured in the same task run. Each is one ASCII
decimal token (`^[0-9]+$`), is range-checked by the harness, and is inserted only in its declared
slot. The operator cannot provide free-form text or add/remove arguments.

## Closed candidate argv matrix

Every row below is a process argv array. There is no host shell. In every Recipe row the payload
after the final `-a` is **one array element containing spaces**; quote characters are not part of
that element. Split-token or quoted-string fallbacks are not candidates and SHALL NOT be tried.

| ID | Logical operation | Exact host argv after substitution | Payload boundary | Approved mode / typed step | Owning task |
| --- | --- | --- | --- | --- | --- |
| `INV-1` | window inventory | `[HDC, "-t", CONNECT_KEY, "shell", "hidumper", "-s", "WindowManagerService", "-a", "-a"]` | final `-a` payload is one element | stdout-only / `captureRemoteStdout` / `readOnly` | `TASK-UD-CAP-001` |
| `R1` | `nodeSummary` | `[HDC, "-t", CONNECT_KEY, "shell", "hidumper", "-s", "WindowManagerService", "-a", "-w <WINDOW_ID> -default"]` | Recipe payload is one element | stdout-only / `captureRemoteStdout` / `readOnly` | `TASK-UD-CAP-001` |
| `R2` | `elementTree` | `[HDC, "-t", CONNECT_KEY, "shell", "hidumper", "-s", "WindowManagerService", "-a", "-w <WINDOW_ID> -element -c"]` | Recipe payload is one element | possible sidecar/UI-state change / `captureRemoteFile` / `deviceMutation` | `TASK-UD-CAP-MUT-001` |
| `R3` | `fullDefaultTree` | `[HDC, "-t", CONNECT_KEY, "shell", "hidumper", "-s", "WindowManagerService", "-a", "-w <WINDOW_ID> -default -all"]` | Recipe payload is one element | stdout-only / `captureRemoteStdout` / `readOnly` | `TASK-UD-CAP-001` |
| `R4` | `componentDetail` | `[HDC, "-t", CONNECT_KEY, "shell", "hidumper", "-s", "WindowManagerService", "-a", "-w <WINDOW_ID> -element -lastpage <COMPONENT_ID>"]` | Recipe payload is one element | possible sidecar/UI-state change / `captureRemoteFile` / `deviceMutation` | `TASK-UD-CAP-MUT-001` |

`TASK-UD-CAP-001` may implement and execute only `INV-1`, `R1`, and `R3`. `R2` and `R4` are
structurally absent from its executable allowlist. `TASK-UD-CAP-MUT-001` remains blocked and no
harness path may expose those rows until its dedicated readiness revision is merged.

## Result decision rules

For each attempted row, the harness records exact argv, stdout/stderr bytes separately, exit or
signal/timeout, duration, byte counts, truncation flags, and SHA-256. It never retries using another
boundary or a broader command.

- Exit code `0` alone is not success.
- Existing observed `option ... missed` output is explicit failure.
- Until a later approved revision registers a Recipe-specific success family, every other completed
  Recipe output is `unknownOutput`; the capture itself may still be valid evidence.
- Any unexpected sidecar/path marker or device-state difference during the read-only task yields
  `outcomeUnknown`, stops all remaining commands, and opens a Safety review. It is not silently
  reclassified after execution.
- Timeout, cancellation, target/binding drift, executable hash mismatch, invalid identifiers or
  truncation stop the affected run. No fallback argv is allowed.

## TASK-UD-CAP-001 execution protocol (ready on r3 merge)

The task has two PR-separated phases:

1. Harness implementation PR:implement `scripts/ui_dump_capture/**` from this immutable matrix.
   Offline tests must prove closed command IDs, exact array equality, one-element payload boundary,
   identifier validation, no shell API, external controlled output, per-stream hashing, bounded
   capture, privacy gates and structural absence of `R2`/`R4`. This PR contains no evidence/status
   change and is merged before any real-device execution.
2. Human evidence PR:the maintainer executes the merged harness against the fixed tuple. Run
   `INV-1`, select one window ID from that same raw capture, then run `R1` and `R3` once each. No
   command may start unless the physical target, binding, executable hash and fresh output directory
   match. The Agent never performs this phase. Evidence/status is a separate PR.

The task evidence location is:

- `evidence/runs/TASK-UD-CAP-001/run.md`;
- `evidence/runs/TASK-UD-CAP-001/redacted-manifest.json`;
- `evidence/runs/TASK-UD-CAP-001/capture-hashes.md`.

The repository records operator/time, physical target and binding revision, redacted argv,
effect/typed step, output sizes/hashes, outcome classification and deviations. It contains no raw
UI bytes or content excerpts.

## TASK-UD-CAP-MUT-001 gate (currently blocked)

Before a later revision may set this task ready, it must fix all of the following without
operator choice:

1. a dedicated disposable, non-sensitive fixture HAP tuple (artifact SHA-256, bundle, ability,
   declared static screen text, window selection rule) and the approved install/start/stop/cleanup
   steps that establish it;
2. a fresh confirmed device binding revision and durable human `deviceMutation` confirmation whose
   scope hash covers the exact candidate, fixture tuple, remote path, inventory and cleanup steps;
3. one exact expected remote sidecar path. A pre-inventory of that exact path must prove absence;
   global `/data` search, recursive deletion, wildcard paths and ownership inference are forbidden;
4. post-inventory proving that the exact new path belongs to the current task, separate stdout and
   sidecar raw origins/hashes, and `cleanupOwnedRemotePath` for that exact path only. Missing ownership
   leaves the file untouched; cleanup failure records `needsAttention` and never hides the primary
   result;
5. component ID selection from the same run's controlled `R2` output, strict validation and a second
   confirmation scope before `R4` if its UI-state effect is still possible.

Its future evidence location is `evidence/runs/TASK-UD-CAP-MUT-001/**`. Until the readiness revision
closes all five gates, `R2`/`R4` dispatch count is `0`.

## Sensitive raw → repository-derived chain

All UI Dump raw output is sensitive by default (page text, package/window/page names, tree values and
identifiers). Raw stdout, stderr and sidecar bytes remain only in the controlled directory; even a
successful capture contributes only whole-stream hashes and metadata to the repository.

Repository golden fixtures are later produced as `derived`, never mislabeled `raw`, by the following
replayable `uidump-derived-redaction-v1` chain:

1. verify the controlled raw SHA-256 against the merged capture manifest and decode UTF-8 strictly;
   non-UTF-8 input fails closed and produces no repository fixture;
2. normalize CRLF/CR to LF and tokenize using a versioned redactor plus a versioned safe-literal
   allowlist approved by the later output-family decision revision;
3. preserve only allowlisted, non-sensitive structural/semantic literals. Replace window/component/
   process IDs by stable first-seen typed placeholders; replace package, ability, page, window,
   path, text and every unrecognized field/line by deterministic typed ordinal placeholders. No raw
   value or content-derived digest is copied into the derived bytes;
4. write a transformation receipt containing algorithm version and source hash, safe-literal
   allowlist hash, raw whole-stream hash, derived fixture hash, replacement counts and human privacy
   review. The controlled operator replays the transform and attests hash equality;
5. commit only the derived fixture + receipt. `.gitattributes`, profile/lock and Bundle resource
   hashes pin the derived bytes. CI verifies the committed side of the chain; it never needs access
   to sensitive raw.

If the redactor cannot classify a token/line or a human review finds sensitive content, no derived
fixture is committed. Raw/derived byte equality is neither expected nor claimed.

## Prohibited actions

- Agent execution of installed HDC or any real-device command;
- operator-composed command strings, split `-a` payload fallback, command retries with broader argv;
- execution of `R2`/`R4` while `TASK-UD-CAP-MUT-001` is blocked;
- global sidecar search, overwrite of a pre-existing sidecar, unowned cleanup, recursive delete;
- raw UI bytes, excerpts, page text, package/window names, identifiers or user paths in git;
- compatibility/conformance/hardware-support/release claims from these captures.
