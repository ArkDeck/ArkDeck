# Ten methods Swift's App endpoint admits and the App never sends stay refused by the Rust App ingress (TASK-XPA-019, macOS, 2026-09-26)

TASK-XPA-019 / CHG-2026-074. Swift's App endpoint, the XPC Mach service the sandboxed App reaches,
admits ten methods that the Rust App ingress refuses:
- `artifact.inspect` and `job.status`;
- `session.list`, `.show`, `.pin`, `.unpin`;
- `session.cleanup.preview`, `.apply`;
- `session.export.preview`, `.apply`.

After cutover the App reaches the Rust ingress, so any App screen that sent one of them would
break. The hub asked on 2026-09-26, with the coordinator's agreement, for a read-only check first:
whether the App or ArkDeckClientKit sends any of them over XPC.
- **If a method is sent:** admit it exactly as Swift does.
- **If it is not:** keep it refused, recorded as a declared difference.

The App ingress is a security boundary, so nothing is admitted beyond what the App needs.

Base: protected `main` `d238bec7d` (#2246). Read-only; no code changes. Nothing here is device
evidence.

## What Swift admits, and on what terms

`ArkDeckCore/AgentXPCContract.swift` and `ArkDeckAgentDaemon/AgentXPCListener.swift`:

| Method | Admitted by | Parameters Swift closes |
| --- | --- | --- |
| `artifact.inspect` | `forwardableReadOnlyMethods` (`AgentXPCContract.swift:102–126`) | none at the boundary (`AgentXPCListener.swift:207–213`) |
| `job.status` | `forwardableReadOnlyMethods` (the same) | none at the boundary |
| `session.list` | `forwardableSessionMethods` (`AgentXPCContract.swift:168–177`) | `pageSize` 1–1000, `cursor` 1–2048 bytes (`AgentXPCListener.swift:330–342`) |
| `session.show` | the same | exactly `sessionId`, an identifier (`:343–344`) |
| `session.pin`, `session.unpin` | the same | exactly `sessionId` and a canonical `expectedGeneration` (`:345–347`) |
| `session.cleanup.preview` | the same | none (`:298–299`) |
| `session.cleanup.apply` | the same | exactly a lowercase UUID `previewId` and a lowercase SHA-256 `previewDigest` (`:300–308`) |
| `session.export.preview` | the same | exactly `sessionId`, an absolute bounded `destinationPath` without control characters, and `allowSensitive` (`:309–320`) |
| `session.export.apply` | the same | as `session.cleanup.apply` (`:321–329`) |

## What the App sends

Searched in full: `ArkDeckApp`, `Packages/ArkDeckKit/Sources/ArkDeckClientKit` and
`ArkDeckAgentClient`, for each method's name and for any spelling that builds one. The commands,
from the repository root:

```sh
for m in artifact.inspect job.status session.cleanup.apply session.cleanup.preview \
  session.export.apply session.export.preview session.list session.pin session.show session.unpin
do grep -rn "\"$m\"" ArkDeckApp Packages/ArkDeckKit/Sources/ArkDeckClientKit \
  Packages/ArkDeckKit/Sources/ArkDeckAgentClient; done
grep -rn 'request(method: "\|method: "\|send("\|request("' \
  Packages/ArkDeckKit/Sources/ArkDeckClientKit/*.swift ArkDeckApp --include=*.swift
grep -rn 'func listSessions\|func showSession\|func pinSession\|func previewSessionCleanup\|func inspectArtifact' \
  Packages/ArkDeckKit/Sources/ArkDeckAgentClient Packages/ArkDeckKit/Sources/ArkDeckClientKit ArkDeckApp
grep -rln HeadlessRuntimeVerifier Packages/ArkDeckKit/Sources ArkDeckApp
```

The coordinator repeated the search on `origin/main` and found the same.
- **No call site names any of the ten**, and no string, enum or format builds one.
- **Every method name the ClientKit sends literally:** `target.list`, `operation.list`,
  `job.submit`, `job.run`, `job.cancel`, `job.show`, `job.list`, `job.evidence`, `artifact.read`,
  `artifact.import.*`, `trace.probe`, `trace.cache.status`, `trace.cache.purge`,
  `runtime.hdc.status`, `history.filter.list`, `flash.device-access`, `flash.bootloader-status` and
  `device.observations`.
  - The facades also pass `artifact.list`, `job.timeline` and `runtime.storage.*` through shared
    helpers.
  - The App target itself names no method: it reaches the Runtime only through these facades.
- **A Job's status.** The App reads it with `job.show` and then `job.timeline`
  (`RuntimeAppReadResources.statusPresentation`, `RuntimeAppReadResources.swift:70`, `:83`). The
  Flash, Job control and workspace continuation facades use that; none uses `job.status`.
- **`job.status` appears once,** in `HeadlessRuntimeVerifier.swift:270`. Nothing in `Sources` or
  the App refers to that type.
- **Settings reads and changes Session storage only through `runtime.storage.*`**
  (`SettingsApplicationFacade.swift:285` on). Its "export" is the local support bundle
  (`:175`–`:191`), never `session.export`.
- **No App screen browses, pins, cleans up or exports Sessions** over the Runtime.

## Result

| Method | The App sends it | The Rust App ingress |
| --- | --- | --- |
| `artifact.inspect` | no | refuses, as before |
| `job.status` | no | refuses, as before |
| the eight `session.*` | no | refuses, as before |

- **A declared difference from Swift.** Swift's App endpoint admits these ten methods and the App
  sends none of them, so the Rust App ingress keeps refusing them. It answers them as any method
  outside its list, in the terms #2249 (X3) gives it.
- **Nothing is admitted.** The ingress stays exactly as narrow as the App's own requests.
- **If the App ever sends one of these methods,** reopen this in the same change, from Swift's
  admission (`AgentXPCListener.swift:184–195`, `:298–345`; `AgentXPCContract.swift:102–126`,
  `:168–177`). Admit the method on those terms, with Swift's parameter closure and the owner's own
  checks, and nothing wider. The search above tells whether a change sends one.

## Contract

No contract input changes, and no code changes.

## Local targeted checks

- `sh scripts/check-sdd.sh` (validation venv): exit 0.
- Not run: builds and tests, since there is no code change; `generate-contract.py --check` and
  `check-contracts.py`, since there is no contract input change.

## CI

#2250, head `a230e42ad`, run 36208949503: every selected lane passed. The Rust lanes were not
selected, since the change is a run record alone.
- `guard`; `swift` aggregate. `swift-tests` was not selected.

It merged as `fbdb9be17`. Recorded by a later slice (TASK-XPA-012, the Artifact list's own
snapshots), as AGENTS.md has it.
