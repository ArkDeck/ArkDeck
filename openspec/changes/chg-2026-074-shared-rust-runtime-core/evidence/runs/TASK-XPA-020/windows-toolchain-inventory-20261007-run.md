# Windows Toolchains inventory — 2026-10-07

The Toolchains Settings tab now reads the published `runtime.bundle.list` owner
and displays its retained Bundle inventory, full content digest, size, member
count, owner-reference count and unchanged Runtime trust assessment. Each tool
also shows the Runtime's actual `selected` Boolean. This is the existing
TASK-XPA-020 Settings projection scope in architecture §H.3, row 604.

Bundle discovery consumes one stable `bundleRef:asc` snapshot through opaque
continuation cursors. It permits at most 64 pages of 250 records and rejects a
changed revision, repeated cursor, duplicate or out-of-order reference,
incomplete continuation, malformed record or owner refusal without displaying
earlier pages as a complete inventory. The record parser retains the published
`sha256-jcs` content identity and exact `bundle:sha256:` reference correlation.
Tool selection is read as a Boolean rather than coerced from text.

The view keeps the existing signing-status CLI row and adds the Bundle-list CLI
row. It does not register, select, adopt, launch or remove a tool or Bundle.
Displayed trust fields are owner facts, not GUI authorization. The current macOS
HDC diagnostics facade also refuses direct selection and instructs callers to
change the registered tool through Runtime, then refresh its status.

## Local targeted checks

The integrated source is based on the adjacent License commit
`80a42c2d32c2cebabc0f30b100e8a8a6ff715d6b`, which includes corrected Diagnostics
`8aa0fa6f3e45986f9ed7e7418d29878398153972`. Commands ran sequentially in
`D:/src/ArkDeck-wt/trace-crlf` with two build jobs and shared compilation disabled.
The local command runner clears inherited `ARKDECK_` and `OHOS_HDC_` inputs and
creates each log exclusively. It uses no legacy gate or mutex.

Publication integration advances to License `02f4152a1409547fa8f6610d0c98f4aedc27873d`,
containing Diagnostics' test-only preparation correction `af43b5a6211fb26d7027438dd1331aba8d07b77b`.
The two inherited files overlap none of this layer's thirteen tested product/test/resource
files; all thirteen remain byte-identical. Only this run-note context changed. The
original 14-file source/log/TRX freeze remains retained and is not overwritten.

| Command / scope | Result | Log under `tools/logs/toolchain-inventory-20261007/` |
| --- | --- | --- |
| `dotnet test windows/App.Tests/ArkDeck.App.Tests.csproj --filter "FullyQualifiedName~ToolchainInventoryTests\|FullyQualifiedName~SettingsTests\|FullyQualifiedName~ShellContractTests" -m:2 -p:UseSharedCompilation=false` | exit 0; 20 passed, 0 failed/skipped; 12.678 s | `core-channel-import.log`, `toolchains-core-channel-import.trx` |
| `dotnet build windows/App/ArkDeck.App.csproj -m:2 -p:UseSharedCompilation=false` | exit 0; 0 warnings/errors; 30.406 s | `app-first.log` |
| `dotnet test windows/App.UITests/ArkDeck.App.UITests.csproj --filter "FullyQualifiedName~ToolchainInventoryFlowTests" -m:2 -p:UseSharedCompilation=false` | exit 0; 6 passed, 0 failed/skipped; 29.759 s | `ui-first.log`, `toolchains-ui-first.trx` |
| `python -X utf8 windows/scripts/generate-ui-strings.py --check` | exit 0; 1775 keys (1376 unchanged Mac-shared, 399 Windows-only); 0.231 s | `strings-final.log` |
| `C:/Program Files/Git/bin/sh.exe scripts/check-sdd.sh` | exit 0; 0 errors/warnings; 11.516 s; closed-note recheck exit 0, 2.915 s | `sdd-final.log`, `sdd-closed-note.log` |
| `git diff --check` | exit 0; 0.133 s | `diff-final.log` |

The Core result includes six new inventory cases, four continued Settings cases
and ten static App ownership/operation checks. It exercises a complete two-page
snapshot, the unchanged published macOS Bundle corpus, actual selected Booleans,
empty versus refused owner, snapshot/cursor/order/digest/count/trust/reference
drift and the page bound. All earlier Settings assertions remain. The exact six
UIA cases are three scenarios, each in `en-US` and `zh-Hans`: complete inventory,
empty registry and refused registry. They retain selected true/false facts,
available and removed records with retained content, complete digest/count/trust
readbacks, zero disabled placeholders and the maintenance CLI.

UIA was explicitly enabled and its App image was pinned to this worktree's freshly
built `windows/App/bin/x64/Debug/net10.0-windows10.0.26100.0/win-x64/ArkDeck.exe`.
Shared integration is seven designated-owner files: the two Settings call sites,
three scenario registration/dispatch references, nine Windows-only keys and
their generated outputs, and the one old semantic selected-name row. Parsed JSON
comparison proves the shared string entries and all other old semantic rows are
unchanged; its source/log manifest is retained separately at
`tools/logs/toolchain-shared-20261007/source-freeze.json`.

The first targeted compile failed with `CS9007` in the new scripted Bundle raw
string (`core-first.log`). Only its interpolation delimiter was corrected to
disambiguate nested object braces. The second compile reported `CS0246` because
the new reader lacked the `IControlChannel` namespace import
(`core-fixture-compiled.log`); the reader and new test gained that existing
namespace import. The final 20-case result follows these narrow fixes. The logs
are retained as source failures, not invalid load runs; no assertion, owner
validation or fixture meaning was weakened.

All UIA and Core fixtures are software-only and cannot establish hardware
acceptance or Narrator-by-ear acceptance. No installed Runtime, account state,
DevEco/Harmony SDK, HDC, private Raw data or device was accessed. The App build
uses the normal Windows/WinUI SDK. No Rust source, control contract, Catalog or
trust policy changed, so no Rust/contract generator or full workspace gate ran.

## CI

Not published yet. CI for this increment is pending; the local software results
above do not establish remote CI, hardware acceptance or maintainer approval.
