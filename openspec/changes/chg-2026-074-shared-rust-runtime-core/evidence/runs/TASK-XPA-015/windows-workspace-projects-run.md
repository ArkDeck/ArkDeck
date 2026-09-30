# TASK-XPA-015 — workspace project owner on the Windows daemon, local run on the reference host, 2026-09-30

Windows slice W1: the workspace registration owner
(`arkdeck_hoststore::WorkspaceProjectStore`, on `main` for macOS) is built and
composed on the Windows Rust daemon, so `workspace.project.register|list|show`
and `workspace.preset.list|show` (and a symbol preset's registration) answer
there, measured end to end with the real daemon over an isolated development
root and the Rust CLI over the named pipe. This is a host-only software run: no
board, no `hdc`, no DevEco, no elevation, nothing under `%LOCALAPPDATA%\ArkDeck`
created (every daemon ran over a development root below the temporary
directory). It is not acceptance evidence.

Checkout: branch `agent/xpa-015-windows-workspace-projects-20260930` on
`origin/main` `ca880968` (#2350), rebased onto `f0d83f78` (#2358) and every check
below rerun there. Host: Windows 11 Pro 10.0.26200 x64,
non-elevated, NTFS.

## What is composed on Windows now

| Piece | Windows | Same as macOS |
| --- | --- | --- |
| `WorkspaceProjectStore` (+ `workspace_project_document`, `_presets`, `_mutations`, `workspace_preset_mutations`) | built (`cfg(any(macos, windows))`); composed by `windows_lifecycle::Authority::compose` in `workspace-projects`, a `StateRoot::private_child` of the development or account root | the directory name both macOS compositions use; `projects.json` under `.projects.lock` with the same keys, schema versions and digests |
| Start-up read | `startup_records()` at compose; an unreadable document ends the start (exit 69, "the workspace project store … nothing was started") | the macOS start reads it in `WorkspaceComposition::compose` and fails the same way |
| `Host::workspace_project`, `with_workspace_projects`, the `workspace_projects` field | `cfg(any(macos, windows))`; the owner census line is now `arkdeck-agentd owners: targets, workspaceProjects` | one code path; the clock is the host's whole-second UTC spelling (`utc_now`) where macOS calls `runtime_now` (same spelling) |
| Job census before a project/preset update or removal | no Job owner on Windows: every such mutation is refused `recordUnreadable` "workspace Job references cannot be verified", details `{phase, newDispatchCount: 0}` | the macOS answer without a Job owner, unchanged |

Not composed on Windows, with the reason:

| Left out | Reason |
| --- | --- |
| DevEco toolchain pinning (`toolchain_pinning` over the bootstrap DevEco registry) | the bootstrap DevEco registry store is macOS-only (D2 is porting the DevEco files); build/test/signing presets therefore stay refused as Swift refuses them without the owner |
| Signing credential pinning (Keychain `credential_owner`), hap-sign-tool / Hvigor signing | Keychain-only; the Windows Credential Manager store (#2354) is not merged and the provider-workspace signing path is being ported by D2. Not trivially portable here |
| `WorkspaceComposition` (`with_workspace_operations`: profiles, isolation, inspector, operations) | macOS-only modules (`workspace_composition`, `_isolation`, `_patch`, `_profile`, `_run` …) depend on the DevEco registry, the inspector and the macOS tool dispatch; `ARKDECK_WORKSPACE_INSPECTOR` still refuses the Windows development start. So every project stays `runtimeRestartRequired` with no operations |
| Job owner for the census | H2 (Job store on Windows) is in flight; once `Host::jobs` is composed on Windows the macOS census closure applies unchanged |
| CLI coverage flip for `workspace.project.*` | kept `partial`, as the Target leaves were kept (ruling 9): the owner answers and is measured end to end, but a registered project cannot become active on Windows until the workspace composition and its DevEco/credential/Job owners are composed there. Adding `workspace.project.register|list|show` to `WINDOWS_MEASURED_LEAVES` (#2353) is a one-line change the lead may prefer now |

## The Windows root rule

macOS pins a root as `(path, st_dev, st_ino)` after a canonical-path check, an
`lstat` walk refusing a symbolic ancestry, an `O_DIRECTORY|O_NOFOLLOW` open and
a second `lstat` of the name. Windows does the same checks, in the same order,
with the same codes and messages:

1. canonical text: `X:\a\b`, `\`-separated, not a drive root, no empty, `.` or
   `..` component, no trailing dot/space, no control character or
   `/ : * ? " < > |` (so no verbatim `\\?\`, stream or device syntax), at most
   4096 bytes → else `invalidInput` "workspace root must be a canonical absolute
   directory";
2. ancestry: `symlink_metadata` of every component below the drive root; a
   symlink or junction (the standard library reports a name-surrogate reparse
   point as a link) → `invalidInput` "…ancestry cannot contain a symbolic link"
   (a missing name also fails here, as on macOS);
3. open without following the last component
   (`arkdeck_platform::InspectedDirectory`: `FILE_FLAG_BACKUP_SEMANTICS |
   FILE_FLAG_OPEN_REPARSE_POINT`, attribute access only, reparse refused, must be
   a directory) → else `invalidInput` "…cannot be opened as a directory";
4. the system's name for the opened handle (`GetFinalPathNameByHandleW`) must be
   exactly the given spelling (another case of a component or the drive letter,
   or a short name, is refused as not canonical);
5. identity: volume serial and the 64-bit NTFS file reference (`FileIdInfo`) as
   device and inode; a ReFS id using the upper 64 bits is refused
   (`invalidInput`, cannot be opened) rather than folded;
6. the name opened again must be the same `(volume, id)` and the ancestry walk
   must still pass → else `factsDrifted`.

A replaced root (renamed away, a new directory at the same path) is an
unavailable project in `startup_records` (`factsDrifted`), not an unreadable
store, as on macOS.

## Observed on Windows

`crates/arkdeck-hoststore/tests/windows_workspace_project.rs` (in process, NTFS,
6 tests): registration pinned by identity (digest =
SHA-256(`kind\0path\0volume\0id`)), replay writes nothing, reopen lists and
shows; `idempotencyConflict` / `resourceConflict` / `workspaceReferenceNotFound`;
ten non-canonical spellings and two case variants refused `invalidInput`, a file
and a missing name refused, nothing written; a junction as the root or in its
ancestry refused (created with `mklink /J`, unelevated); a replaced root is
`factsDrifted` at start-up; a symbol preset registers and reads back, preset and
project update/remove refused while the census cannot verify and nothing
written, then carried out when it can (project moved to generation 2, read back
after reopen).

`crates/arkdeck-agentd/tests/windows_workspace_projects_process.rs` (the real
daemon over a fresh development root, every `ARKDECK_*`/`OHOS_HDC_*` removed):

1. start → `arkdeck-agentd owners: targets, workspaceProjects`; over the pipe
   `workspace.project.list` empty; register → `project-<sha256(request)[..24]>`,
   `runtimeRestartRequired`, no path in the answer; replay identical, no write;
   second project; `resourceConflict`, `idempotencyConflict`, forward-slash,
   upper-case and POSIX roots refused with `{phase: workspaceProjectOwner,
   newDispatchCount: 0}`; show; list of 2; `workspace.preset.list` empty; a
   symbol preset registers; an absent preset `workspaceReferenceNotFound`;
   `workspace.project.update|remove` and `workspace.preset.remove` →
   `recordUnreadable` (preset phase `workspacePresetOwner`, as Swift), no write;
2. stop (stop event) → restart: the list and the preset read back identically,
   `projects.json` unchanged;
3. a `workspace-projects` created as an ordinary directory (inherited grants)
   → exit 69, nothing served, no document; a `projects.json` cut to half its
   bytes → exit 69, the document left as it was;
4. **through the real CLI and named pipe against a dev-signed daemon** (a copy
   signed with `rust/scripts/windows-dev-identity.ps1 sign` and the host-trusted
   development signer, `ARKDECK_DEV_SIGNER_THUMBPRINT` from `HKCU\Environment`):
   `workspace project register --registration-request-id … --kind openharmony
   --root <dir>` (exit 0), the replay (same receipt), `workspace project list`,
   `workspace preset list --project …`, `workspace project remove …
   --expected-generation 1` (non-zero exit, `recordUnreadable`, no write); stop,
   restart: `workspace project show --project …` reads it back. Without the
   variable the test prints `SKIPPED: …` and checks nothing.

The process test file passed 3 consecutive runs with the signer. No test
sleeps: daemons are awaited on their own stdout lines with a 60 s deadline and
stopped by their stop request.

## Local targeted checks (Windows 11 x64)

| Command | Result |
| --- | --- |
| `cargo fmt --all --check` | pass |
| `cargo clippy --workspace --all-targets -- -D warnings` | pass (Windows build of every crate) |
| `ARKDECK_DEV_SIGNER_THUMBPRINT=<host signer> cargo test -p arkdeck-platform -p arkdeck-hoststore -p arkdeck-agentd -p arkdeck-cli` | pass (exit 0); new: hoststore `windows_workspace_project` 6, agentd `windows_workspace_projects_process` 3; `windows_target_owners_process` 3 with the new census line |
| `PYTHONUTF8=1 sh scripts/check-sdd.sh` | 0 errors, 0 warnings |
| `git diff --check` | clean |

macOS and Linux were not built here; the `cfg` pairings were re-read by hand.
macOS keeps its bytes and behaviour: `inspect_root` and `canonical` keep their
bodies under `cfg(target_os = "macos")`, the census closure is the same match
over `self.jobs` (its refusal factored into a local closure), and the
mutation module's unit tests are gated to macOS (Unix fixtures). On Linux the
hoststore module, the agentd dependency and the `Host` members stay out as
before. CI decides.

## CI

To be recorded, not verified.
