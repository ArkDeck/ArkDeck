# TASK-XPA-022 — RC smoke physical file identity

Run: 2026-10-05, Windows 11 x64 development host. Source base:
`e957da597d23c001157a05c7ba0a8ce1b3d38d3d`, protected `main`.

The packaged Windows executor virtualizes LocalAppData. A freshly installed
daemon's physical process path can therefore differ from the logical install
path while naming the same owned file. The former string comparison rejected
the signed RC. Setting only child `LOCALAPPDATA` does not redirect .NET's Windows
known-folder lookup and is not a workaround.

The smoke now resolves its fresh private work directory through a native file
handle before deriving install, state, UIA, uninstall and cleanup paths. The
started daemon must match the installed image's physical canonical path, volume
serial and file index. Manifest file hashes, Authenticode checks and signer or
publisher pins are unchanged. Forced cleanup is allowed only after this identity
proof; an unproven process is not stopped, and a private directory containing a
remaining process is retained. Existing ACLs are not rewritten.

The smoke used the original signed protected-main RC ZIP without modifying any
package byte or rebuilding Runtime. Its daemon used a fresh private development
root with every inherited `ARKDECK_*` and `OHOS_HDC_*` input cleared. No HDC or
device operation ran. This is packaging/UIA smoke, not `REAL_DEVICE_PASS`.

## Local targeted checks

Logs and raw smoke records remain local under the task tools and RC output
directories; no raw account paths or Runtime outputs are committed here.

| Check | Exit | Log / record |
| --- | --- | --- |
| `pwsh -NoProfile -NonInteractive -File windows/scripts/test-package-rc-path.ps1` | 0 | `rc-smoke-path-unit.log` |
| `package-rc.ps1 -SmokeZip <original e957 RC ZIP> -SmokeRecord <fresh physical-path record>` | 1 | `rc-smoke-path-smoke.log`; `smoke-physical-path.json` |
| Same smoke during a quiet account-Runtime window, with another fresh record | 0 | `rc-smoke-path-smoke-quiet.log`; `smoke-physical-path-quiet.json` |
| `sh scripts/check-sdd.sh` | 0 | `rc-smoke-path-sdd.log` |

`git diff --check` also passed (exit zero).

The native regression proves that logical and physical handles name the same
file, refuses a different file with identical bytes, an unrelated process and
missing/unreadable images, and verifies the cleanup ownership guard. The initial
sandboxed attempt was denied before creating its private directory; the approved
controlled executor ran the test successfully.

Both smoke runs passed first doctor, the single installed App UIA test, doctor
with the daemon running, and normal uninstall. The first aggregate failed only
`productRootUnchanged` while parallel account-Runtime work was active. The quiet
repeat passed that unchanged criterion, removed its private work directory,
left no new LocalAppData entry and no process, and needed no forced daemon kill.
Its private before/after account-tree diagnostic found zero changed paths. All
four captured executable steps exited zero, and the RC ZIP hash was unchanged.
The 364-file ZIP SHA-256 is
`a47e96b9cf9dada0684c0cb1f6b57b6eb1296649da849baef4056d99f34b2a6a`.

## CI

Not run in this subtask: no push or PR created. The integration owner records
the actual PR and CI result. Local smoke does not grant maintainer approval.
