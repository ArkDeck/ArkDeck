# CHG-2026-008 controlled UI Dump capture harness

`TASK-UD-CAPTURE-HARNESS-001`. **Human maintainer operated only.** Agents and CI
must not invoke an installed `hdc`, discover a real device, or execute any command
from this table. Tests use an injected fake runner (and the current Python
interpreter for runner mechanics) and never touch HDC, a device, or the network.

This harness is the mandatory capture instrument for the later human Phase A
run. It runs exactly one approved command per invocation so the maintainer can
perform the physical, target-drift, window-selection, sidecar-ownership, and
abort decisions between steps. Reuse one fresh session `--out-dir` for the full
run. The directory must be owner-only and outside every git repository.

## Closed command surface

The table mirrors `COMMAND_SPECS` in `capture.py`; tests pin the ids, token arrays,
and corresponding literal rows in `capture-runbook.md`. `HDC` is the resolved
`--hdc` executable. Values shown without quotes are typed placeholders; the R1–R3
payload after the final `-a` remains one argv element.

| id | exact argv array | purpose |
| --- | --- | --- |
| `HP-0` | `[HDC, "version"]` | HDC version preflight (the harness also hashes the executable) |
| `HP-1` | `[HDC, "list", "targets"]` | same-session target inventory |
| `HP-2` | `[HDC, "list", "targets"]` | immediate target recheck |
| `INV-1` | `[HDC, "-t", CONNECT_KEY, "shell", "hidumper", "-s", "WindowManagerService", "-a", "-a"]` | all-window inventory |
| `R1` | `[HDC, "-t", CONNECT_KEY, "shell", "hidumper", "-s", "WindowManagerService", "-a", "-w WINDOW_ID -default"]` | `nodeSummary` candidate |
| `R2` | `[HDC, "-t", CONNECT_KEY, "shell", "hidumper", "-s", "WindowManagerService", "-a", "-w WINDOW_ID -element -c"]` | `elementTree` candidate |
| `R3` | `[HDC, "-t", CONNECT_KEY, "shell", "hidumper", "-s", "WindowManagerService", "-a", "-w WINDOW_ID -default -all"]` | `fullDefaultTree` candidate |
| `SC-1` | `[HDC, "-t", CONNECT_KEY, "shell", "ls", "-l", "/data/app/el2/100/base/com.example.waterflowdemo/haps/entry/files/arkui.dump"]` | exact-path sidecar inventory |
| `SC-2` | `[HDC, "-t", CONNECT_KEY, "file", "recv", "/data/app/el2/100/base/com.example.waterflowdemo/haps/entry/files/arkui.dump", LOCAL_SIDECAR_DEST]` | receive an owned new sidecar |
| `SC-3` | `[HDC, "-t", CONNECT_KEY, "shell", "rm", "/data/app/el2/100/base/com.example.waterflowdemo/haps/entry/files/arkui.dump"]` | remove the owned exact-path sidecar |
| `FX-1` | `[HDC, "-t", CONNECT_KEY, "install", LOCAL_HAP_PATH]` | install pinned fixture |
| `FX-2` | `[HDC, "-t", CONNECT_KEY, "shell", "aa", "start", "-b", "com.example.waterflowdemo", "-a", "EntryAbility"]` | start pinned fixture |
| `FX-3` | `[HDC, "-t", CONNECT_KEY, "shell", "aa", "force-stop", "com.example.waterflowdemo"]` | stop pinned fixture |
| `FX-4` | `[HDC, "-t", CONNECT_KEY, "uninstall", "com.example.waterflowdemo"]` | uninstall pinned fixture |

R4 is not silently generalized into this allowlist. The approved harness task's
closed `COMMAND_SPECS` list omits R4, and `TASK-UD-CAP-R4-001` remains blocked on
an approved R2 output-family/component-provenance revision. That later revision
must explicitly update the pinned harness before Phase B can dispatch anything.

## Enforced inputs

- `CONNECT_KEY` is nonempty, bounded printable ASCII without whitespace or an
  option prefix. More importantly, it must occur as an exact token in the latest
  untruncated, self-check-passing `HP-1` or `HP-2` raw capture in the same session
  directory. A command-line value alone is never trusted.
- `WINDOW_ID` is ASCII decimal digits only. Provenance and unique foreground
  selection remain the human rule in `capture-runbook.md`.
- `LOCAL_HAP_PATH` must resolve to an existing regular file outside every git
  repository. Its fresh SHA-256 and byte count are recorded.
- `LOCAL_SIDECAR_DEST` must not exist, must be inside the controlled session
  directory with an owner-only existing parent, and must use the next controlled
  name `NN-SC-2.sidecar`. The harness exclusive-creates that file at `0o600`
  before dispatch, then verifies it remains a single regular file and hashes its
  post-command bytes; command failure remains a captured fact.
- Inputs not used by the selected command are rejected, as are unknown command
  ids, forged `CommandSpec` objects, nonpositive timeouts, unsafe output modes,
  pre-existing controlled artifacts, and output-side redaction leaks.

## Human invocation shape

First run the offline test suite with the repository-pinned interpreter:

```text
<ARKDECK_ROOT>/.venv-sdd/bin/python scripts/ud_capture/test_capture.py
```

For real capture, the human maintainer follows the canonical sequence in
`capture-runbook.md` and invokes one row at a time. Examples show argument shape
only; they are not authorization for an Agent to run HDC:

```text
<PYTHON> scripts/ud_capture/capture.py --hdc <PINNED_HDC> \
  --out-dir <CONTROLLED_SESSION> --command HP-1

<PYTHON> scripts/ud_capture/capture.py --hdc <PINNED_HDC> \
  --out-dir <CONTROLLED_SESSION> --command R1 \
  --connect-key <SAME_SESSION_KEY> --window-id <ASCII_DECIMAL_WINDOW_ID>
```

Never use shell redirection around these commands. The harness passes an argv
array directly to `subprocess.Popen`, owns stdout/stderr capture, and defaults to
a recorded 120-second per-command timeout that cannot be disabled.

## Controlled outputs

Each invocation exclusive-creates owner-only files named
`NN-<id>.stdout`, `NN-<id>.stderr`, `NN-<id>.manifest.json`, and
`NN-<id>.redacted-manifest.json`; SC-2 additionally owns
`NN-SC-2.sidecar`. Streams are drained independently; at most
4 MiB per stream is retained while the whole drained stream is counted and
SHA-256 hashed. Overflow sets `truncated: true`, fails the complete-stream
sensitive scan, and requires the run to stop. Timeout is recorded separately
from exit code (`exitCode: null`, `timedOut: true`). Exit code zero is never
interpreted as Recipe success.

The harness rebuilds `capture-hashes.md` from redacted manifests after every
successful redaction gate. Full manifests, raw streams, connect keys, window ids,
and local paths remain in the controlled directory only. Repository evidence may
copy only the per-command redacted manifests and the hash summary after the human
runbook checks; those bytes claim `controlledHumanCapture`, not Recipe success,
compatibility, hardware support, or canonical acceptance.
