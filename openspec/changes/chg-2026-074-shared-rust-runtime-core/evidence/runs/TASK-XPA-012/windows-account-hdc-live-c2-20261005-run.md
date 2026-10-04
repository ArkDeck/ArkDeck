# TASK-XPA-012 — the Windows account daemon's selected HDC, live with the registered c2 `hdc.exe`, 2026-10-05

Change: CHG-2026-074-shared-rust-runtime-core. This is the live run of the account-daemon HDC
composition: PR #2524 (the composition) and stacked PR #2526 (the signed-CLI layer). Read-only
`hdc` use, as AGENTS.md (#2454) allows.

The coordinator granted port 8710 for this run. No device mutation was requested. This is not
device acceptance and not a `REAL_DEVICE_PASS`.

## Set-up

- **Host.** The Windows 11 x64 reference host, non-elevated.
- **Build.** The debug build of #2526's head `815dddd2`, which contains #2524.
- **How the daemon was run.** The signed test build of the account daemon from #2526
  (`tests/spawning/account_tool_selection.rs`), run unchanged except for one local switch:
  - The child kept the registered tuple table (`WINDOWS_HDC_TUPLES`, c2 only). No fixture tuple
    was injected, so the composition was production's.
  - The copy was signed with the host-trusted development signer.
  - It ran over a fake profile (`USERPROFILE` below `%TEMP%`), holding the account's daemon
    starters' turn.
  - The local switch and the driver test were not committed.
- **Inputs.**
  - `ARKDECK_HDC_PATH` named DevEco Studio's bundled `sdk\default\openharmony\toolchains\hdc.exe`.
    That is the registered c2: SHA-256 `c79518498aaf4e719733961216444e70c3eb53c8ba7006b933e6d7f2e1c6101e`,
    `Ver: 3.2.0g`.
  - `OHOS_HDC_SERVER_PORT` was `8710`.
- **Before each run.** Nothing listened on 8710 and no `hdc.exe` or `arkdeck-agentd` process
  existed.
- **After each run.** The same. The daemon stopped its managed server on its drain.
- **Board.** A DAYU200 happened to be attached; nothing depended on it.
- **Runs.** Two runs, each about 11 s:
  - the first built the impact preview's arguments wrongly (a CLI-side refusal, not recorded);
  - the second is the one recorded here.

## Observed (second run)

| Step | Result |
| --- | --- |
| Start | 4.1 s to listening. Start line: `arkdeck-agentd composes the selected registered Windows HDC c2 (tool:sha256:f84ff986…53bc, SHA-256 c7951849…101e) as its managed server on 127.0.0.1:8710`. Owner census includes `hdc`, `managedHdc`, `controlActions`, `usbRegistryRelations` |
| Adoption | The configured `hdc.exe` was captured with its imported sibling `libusb_shared.dll` (relocatable) and adopted as the account registry's first selection, active generation 1. The managed server ran the retained copy below `…\ArkDeck\Bootstrap\v1`, not the DevEco file |
| `runtime hdc status` | `availability: available`, `ownership: arkDeckManaged`, `reasonCode: hdc.identityObserved`, startup versions client/server `3.2.0g`, endpoint `127.0.0.1:8710` (`inheritedEnvironment`). **`serverHealth: unknown`**, `healthReasonCode: hdc.commandlessIdentityDoesNotProveHealth` |
| `runtime tool list` | one row: `platform: windows`, `selected: true`, `activeSelectionGeneration: 1`, dependency `libusb_shared.dll`. **`trust.registeredIdentity: false`, `toolVersion: null`** (finding 3) |
| `runtime tool select` (the active tool, generation 1) | The tool-selection owner recorded action `runtimeToolSelection`, state `previewDrifted`, `blockerReasonCode: tool.selectionFactsUnavailable`, dispatch count 0 (`control-action list`). The CLI answered exit 75, `outcomeUnknown`, wire code `internalError`: "the result does not conform to the current contract" (finding 2) |
| `runtime hdc impact-preview --action restart` (the status's endpoint reference and generation) | exit 0, `ok: true`. The HDC control action `hdcLifecycle`, state **`blocked`**, `blockerReasonCode: hdc.serverIdentityUnproven`, `humanAction: null`, dispatch count 0. Preview: `serverHealth: unknown`, `serverOwnership: unknown`, critical Job gate clear |
| `device candidates` | answered, `health: current`. The attached board: `Connected`, `relationProven` (its connect key is not recorded here) |
| Stop | drained; the managed server stopped; 8710 free, no `hdc.exe` left |

## Findings

1. **No awaiting-approval answer is reachable on Windows today, and the limit is not only the
   single tuple.**
   - With one registered tuple there is no second tool to select: the active tool is no candidate,
     so `runtime tool select` can only record that its facts are unavailable.
   - Even with a second tuple, every approval request needs `serverHealth: healthy` (the
     tool-selection preview, and the HDC restart's). On Windows the commandless identity proves
     the server's identity, not its health (`hdc.commandlessIdentityDoesNotProveHealth`).
   - The restart preview here is therefore `blocked` (`hdc.serverIdentityUnproven`), not
     awaiting approval.
   - The health proof is the open PR #2501 ("prove the registered Windows HDC server's health in a
     restart's impact preview"). The awaiting-approval answers can be measured live once it lands
     and, for a tool selection, once a second Windows tuple is registered.
   - Nothing was faked to reach them.
2. **Follow-up: the `runtime.tool.select` result contract does not hold a blocked or drifted
   action.**
   - The published result schema (`spec/control/methods/runtime.tool.select.json`) was sampled
     from Swift's awaiting-approval answer: `blockerReasonCode` null, `preview` and `humanAction`
     objects.
   - A blocked or drifted action the owner legitimately records is answered by the control layer
     as `internalError`, and by the CLI as `outcomeUnknown`. The macOS daemon answers the same way.
   - The `hdcLifecycle` impact preview's contract does hold its blocked answer.
   - Taken as a follow-up after this change (coordinator, 2026-10-05).
3. **`runtime tool list` on Windows never shows a registered identity.**
   - The tool list page decodes rows with the macOS static identity table
     (`arkdeck_bootstrap::decode_tools`, `registry::published_identity`). It does not use the
     store's composed Windows identities.
   - So the c2 row reads `registeredIdentity: false`, `toolVersion: null`. Admission and selection
     are not affected, because they use the store's identities.
   - Display only. Not changed here; a follow-up.
4. **The composition worked end to end.** Adoption with the sibling DLL, the retained copy
   started as the managed server on the tuple's endpoint, the status, the owners composed, and
   the relation proof over the managed server all held as designed.

## Not covered

- A selection that restarts into another tool: there is no second Windows tuple.
- Any device mutation.
- Whether the start settled past the startup listing: `StartupListing` is not surfaced on a status, so it was not observed.
