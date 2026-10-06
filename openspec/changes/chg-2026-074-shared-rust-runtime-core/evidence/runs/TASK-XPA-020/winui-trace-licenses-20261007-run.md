# TASK-XPA-020 — Windows Settings Trace licenses, 2026-10-07

Settings › Trace previously exposed its Runtime cache projection without the accepted local
license view. This increment lazily displays the running App's original
`ArkTrace/LICENSE` and `ArkTrace/THIRD_PARTY_NOTICES.md`, with separate loading/unavailable
states, selectable full text, and Reveal only for a safely revalidated `ArkTrace/Licenses`
directory. Cache navigation and Runtime cache behavior are retained. No Runtime RPC or CLI
substitute supplies legal content.

The fixed resource root is `AppContext.BaseDirectory`; it has no caller, environment or
Runtime override. The Windows reader follows the pinned macOS bounded-reader behavior:
UTF-8 regular files, 32 KiB for LICENSE and 128 KiB for notices, exact whole content, and
before/after handle metadata validation. Native no-follow directory handles retain one
source group across both reads and deny rename/replacement; files deny write/delete sharing.
Missing, nonregular, reparse, oversized, invalid-encoding or changing sources remain
unavailable. Reveal reopens that fixed local chain and holds it through the launch request.
No existing legal file is written or translated.

Compatibility: this is the existing accepted Windows Settings consumer, with six strings
already supplied by the Device lower layer. It adds no operation, authority or package legal
asset. Genuine Windows ArkTrace bundle content remains externally unavailable; no macOS
notice group is substituted. The isolated UI resources below are generated fixture text,
not a released license inventory. These software checks are not `REAL_DEVICE_PASS`.

## Local targeted checks

Checks ran on Diagnostics `2d5b8d969fd971a62f07e88464fa419fd6175612`, including its
Device/string dependency. Integration parent is the corrected Diagnostics head
`8aa0fa6f3e45986f9ed7e7418d29878398153972`. Its five-file fix has no overlap with the seven
License files; all six tested License product/test files remain byte-identical. The run-note
context is the only License source change during this fast-forward. Each dotnet command used the explicitly coordinated single native host window,
the existing dependency cache, `-m:2 -p:UseSharedCompilation=false`, and cleared inherited
`ARKDECK_*`/`OHOS_HDC_*` configuration. No legacy gate lock, installed RC, account Runtime,
Harmony SDK/signing, HDC or device was accessed. Only the just-built App was launched with
scripted transport and task-owned preferences/resource copies. Its official test harness
closed those processes; the native window was then released.

Logs are retained in local scratchpad `tools/logs/trace-licenses-20261007`.

| Command / observable check | Result | Log |
| --- | --- | --- |
| `dotnet test windows/App.Tests/ArkDeck.App.Tests.csproj --filter FullyQualifiedName~TraceLicenseTests -m:2 -p:UseSharedCompilation=false` | Exit 0; 11 passed, 0 skipped; 8.817 seconds | `core-directory-pin-fixed.log`, `license-core-directory-pin-fixed.trx` |
| `dotnet build windows/App/ArkDeck.App.csproj -m:2 -p:UseSharedCompilation=false` | Exit 0; 0 warnings, 0 errors; 30.672 seconds | `app-first.log` |
| `dotnet test windows/App.UITests/ArkDeck.App.UITests.csproj --filter FullyQualifiedName~TraceLicensesFlowTests -m:2 -p:UseSharedCompilation=false` with explicit newly built App and `ARKDECK_APP_UITESTS=1` | Exit 0; 2 passed, 0 skipped; 27.952 seconds | `ui-cache-peer-fixed.log`, `license-ui-cache-peer-fixed.trx` |
| `python -X utf8 windows/scripts/generate-ui-strings.py --check` | Exit 0 | `strings-final.log` |
| `PYTHONUTF8=1 ARKDECK_PYTHON=<verified Python/PyYAML6.0.3> 'C:/Program Files/Git/bin/sh.exe' scripts/check-sdd.sh` | Exit 0; 121 acceptance IDs, 0 errors, 0 warnings | `sdd-source-final.log` |
| `git diff --check` plus owned tracked/untracked UTF-8 and whitespace validation | Exit 0 | `diff-source-final.log`, `source-freeze.log` |

Reader cases cover lazy/concurrent once-only loading, no sibling-platform fallback, exact
raw UTF-8/CRLF content and unchanged files, nonregular/empty/UTF-16/invalid UTF-8 refusal,
exact byte bounds, root/path refusal, descriptor drift, concurrent write/rename denial,
one held source group, readonly files, native task-owned reparse points and stale Reveal.
UIA used two bounded ordinary copies of this checkout's built App, without overriding the
production resource root. One had no ArkTrace group; the other had generated readonly legal
documents. It measured full original CRLF/Unicode content and native TextPattern selection
for both documents, Reveal presence, cache/License return navigation and unchanged document
hashes, attributes and write times. Reveal was not invoked to open an external Explorer window.

Earlier failures are retained. `core-first.log`/`license-core-first.trx` returned 1 with
9 passing and 2 failing cases: Windows attribute-only directory handles did not deny rename.
The fix includes `FILE_LIST_DIRECTORY` in the retained read access without enumerating,
preserving the original no-follow/identity and sharing assertions. `ui-first.log`/
`license-ui-first.trx` returned 1 for both cases after reaching the legal states: the test
looked for a Border that has no UIA peer. The fixture now locates its existing cache heading
`settings.trace.cache.title`; content and native selection assertions are unchanged.
These results are not counted again in the final 13 distinct passing cases.

The first SDD attempt selected a PATH `python3` without PyYAML and returned 2 before SDD
executed (`sdd-final.log`). The explicit current Python was checked against the exact
`PyYAML==6.0.3` pin, and the documented `ARKDECK_PYTHON` override then passed
(`sdd-explicit-python.log`); the final note/source check used the same verified interpreter.

## CI

Not yet run for this License increment. Root owns its linear publication above Diagnostics,
maintainer review and protected-main delivery. No approval or hardware acceptance is claimed.
