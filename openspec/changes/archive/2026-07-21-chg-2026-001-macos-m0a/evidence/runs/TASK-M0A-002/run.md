# TASK-M0A-002 run record — 2026-07-15

- Evidence class: `platform` (local macOS process and fixture tests; no hardware)
- Core baseline: `CORE-1.0.0`
- Integration profile: `OPENHARMONY-TOOLS@0.1.0`
- Scope: `MAC-M0A-PROC-001`, `MAC-M0A-HDC-001`

## Environment

- macOS 26.5.1 (25F80), arm64
- Xcode 26.6 (17F113)
- Swift 6.3.3 (`swiftlang-6.3.3.1.3`, target `arm64-apple-macosx26.0`)

## Work completed

- Added `FoundationProcessExecutor`, a shell-free `posix_spawn` implementation
  using an absolute executable and argv array. It keeps stdout/stderr separate,
  forwards every chunk to an output handler, bounds its in-memory capture,
  handles timeout/cancellation, and terminates the spawned process group.
- Added external-first HDC discovery that considers only explicitly supplied
  user, DevEco SDK, and OpenHarmony SDK paths in that order. It never searches
  `PATH`, streams SHA-256 calculation in 64 KiB reads, and records invalid or
  non-executable candidates as diagnostics.
- Added value-type per-Job HDC toolchain snapshots. Path, source, hash,
  endpoint, trust, client/server/daemon version, and server generation remain
  explicit values; unavailable probe fields are represented as `unknown`, not
  omitted or inferred.
- Added a bounded streaming HDC semantic parser. Exit status zero is not
  sufficient for success: `[Fail]`, Unauthorized/E000002/E000003, and Offline
  all produce failures; an unrecognised output family remains `unknownOutput`.

## Installed HDC diagnostic

| Field | Observed result |
| --- | --- |
| Source | DevEco SDK external tool |
| Path | `/Applications/DevEco-Studio.app/Contents/sdk/default/openharmony/toolchains/hdc` |
| SHA-256 | `48395ba8d87115dffca47df2a640a6c868bc9a2bd4eb49611e4138ff88d8d260` |
| Command attempted in the original run | `hdc version` |
| Original terminal output | `Connect server failed` |
| Client/server/daemon version, endpoint | `unknown/unverified`; the command result did not establish them |
| Platform signature/trust | `unknown/unverified`; ToolTrustInspector is explicitly deferred to TASK-M0A-005 |

No process-table observation was recorded for the original command. The former
claim that it did not manage a server has been withdrawn; see the review
correction below. It did not target a device.

## Commands and results

| Command | Result |
| --- | --- |
| `swift test --scratch-path /private/tmp/arkdeck-m0a-m002-build` in `Packages/ArkDeckKit` (after review fixes) | Passed: 16 XCTest cases, 0 failures. Covers argv with spaces/Chinese/shell metacharacters; stdout/stderr separation; bounded >1 MiB output; timeout; cancellation; parent/child process-group cancellation; external-first discovery and immutable snapshots; exit-0 semantic HDC failure; a failure in a large chunk followed by success; and marker splitting across chunks. |
| `xcodebuild -project ArkDeck.xcodeproj -scheme ArkDeck -configuration Debug -derivedDataPath /private/tmp/arkdeck-m0a-m002-derived clean build` | Passed: `** BUILD SUCCEEDED **`. |
| `scripts/check-sdd.sh` | Passed: `0 error(s), 0 warning(s), 110 acceptance IDs`. |
| `hdc version` at the path above | Original run output was `Connect server failed`. This command is no longer considered a safe read-only probe: its server lifecycle side effects were not observed in the original run and a reviewer later reproduced implicit server start. It is not accepted as installed-tool verification evidence. |
| `shasum -a 256` at the path above | Produced the SHA-256 recorded in the installed HDC diagnostic table. |

## AC conclusion

- `MAC-M0A-PROC-001`: **passed** for the prototype. Contract tests prove argv
  delivery without shell expansion, separated streams, bounded large-output
  handling, timeout, cancellation, and process-tree cancellation.
- `MAC-M0A-HDC-001`: **blocked**. The discovery/snapshot prototype and semantic
  fixture coverage are valid, but the required installed-tool observation is
  unsafe before host-wide HDC ownership/lifecycle protection exists. It must
  not be represented as passed.

This is platform/fake evidence only. It is not real-device, HDC server
ownership, USB/UART/TCP, Flash, erase, unlock, update, or hardware-support
evidence.

## Deviations and residual risk

- The installed HDC observation is blocked. The original run did not inspect
  host processes before or after `hdc version`; review subsequently established
  that this command can implicitly start a host-wide server. TASK-M0A-003 owns
  server ownership/lifecycle behavior; TASK-M0A-005 owns tool trust.
- The ProcessExecutor contract test proves bounded capture and streaming for
  more than 1 MiB of output with a 4 KiB in-memory limit. It is not a GB-scale
  or sparse-file hash/transfer-pipeline acceptance run; that scale evidence
  remains required before claiming full `AC-NFR-002-01` product conformance.
- No device was enumerated or targeted. No destructive command was dispatched;
  destructive dispatch count is `0`.
- Task state is drafted as `done` on this agent branch: every task deliverable
  is complete and verified, while the `MAC-M0A-HDC-001` installed-tool
  observation stays `blocked` in the verification matrix pending TASK-M0A-003
  ownership/lifecycle protection. State becomes effective only when the
  maintainer reviews and merges the PR; the change remains unverified until
  its full verification plan is complete.

## Review correction — 2026-07-15

The original evidence incorrectly asserted that the `hdc version` attempt did
not start, stop, restart, kill, or otherwise manage an HDC server. That outcome
was never observed through a process audit, so the assertion was unsupported
and is withdrawn.

The reviewer reproduced the same command from a clean host state and observed
`Ver: 3.2.0d` followed by implicit creation of a host-wide server
(`hdc -m -s ::ffff:127.0.0.1:8710`). The reviewer terminated that server and
confirmed cleanup. This is reviewer-reported lifecycle evidence, not a new
Agent-run probe. The Agent did not repeat the command during remediation.

The corresponding fixture/parser defect is fixed and covered by the 16-test
run above: complete incoming chunks are searched before the bounded carry is
trimmed, so an early `[Fail]`/Unauthorized marker cannot be hidden by a later
`[Success]`. ASCII marker matching also preserves markers split across UTF-8
chunks. The fixture newline sequences are now real LF bytes.
