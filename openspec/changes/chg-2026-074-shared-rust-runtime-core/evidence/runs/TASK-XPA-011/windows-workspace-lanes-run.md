# TASK-XPA-011 — Windows workspace profiles, reads and isolated copies (WM3 GJ-5, PR 4), 2026-10-04

- Task: TASK-XPA-011, WM3 slice GJ-5, fourth layer. Stacked on #2482 (the code-owned grep, sed
  and patch). A registered OpenHarmony project now resolves to its profile on Windows through
  the code-owned tools of the ruling of 2026-10-04. The daemon's own image runs grep, sed and
  patch; the trusted `System32\tar.exe` and Git for Windows come from #2481's `trusted_system`.
  The profile-served reads, the isolated copy and the sweep run end to end.
- Base: the head of #2482's branch (`agent/xpa-011-windows-code-owned-tools-20261004`).
- Host: the Windows 11 x64 reference host, non-elevated. It used Git for Windows
  (`C:\Program Files\Git\mingw64\bin\git.exe`) and `C:\Windows\System32\tar.exe` as installed.
  Nothing was installed or reconfigured, and no board, `hdc`, DevEco or credential was used.

## What changed

| Area | Change |
| --- | --- |
| `workspace_profile.rs` | `external_tools(root)` fills the table's `archive` slot with `trusted_system("sealed-source-archive", Tar, 120)`. Inside a git working copy it fills `source_control` with `trusted_system("git", Git, 120)`. A Windows `inside_git_working_copy` walks the root's ancestors to the drive's root. The "not composed yet" reason is gone |
| `workspace_composition.rs` | Git for Windows runs with `GIT_CONFIG_NOSYSTEM=1`. Git finds its system configuration relative to the image it was launched as, and a verified launch does not name that image, so without the variable every git read failed with `fatal: unknown error occurred while reading the configuration files`. `tool_environment(executable)` gives each read, patch and checkpoint dispatch its executable's overlay. On macOS that overlay is empty, so nothing changes there |
| `workspace_patch.rs` | `validate_path`, `snapshots`, the attempt store's record, patch and checkpoint paths and the lineage scan all join a relative path below a Windows `X:\` root with `support::join`. Before this change they joined with `/`, so every declared path was refused as escaping the root. A spawn's working directory is its canonical (verbatim) spelling, which the Windows tool runner checks it against. A staged file is closed before it is renamed over its destination (here and for the copy's manifest), because Windows renames no file a handle holds |
| `workspace_checkpoint.rs` | the source size check joins with `support::join` |

macOS behaviour and bytes are unchanged: every changed join spells `root/relative` there, the
environment overlay is empty, the canonical working directory is what macOS already used, and
closing a file before renaming it changes nothing on POSIX.

## Measurements

| Check | Result |
| --- | --- |
| `windows_workspace_provider_process` `the_profile_served_reads_and_the_isolated_copy_run_through_the_code_owned_tools` | The project is a git working copy initialized with the trusted git. After a restart it is `active`/`available`. Read-source-range, git status, diff, the isolated copy and the sweep are `available`. Apply-patch, revert-patch and create-checkpoint are `unavailable` with `runtime.mutationOwnerUnavailable`: a development root's mutation authority names the account's root, as on macOS. The isolated copy of the committed tree succeeds `verified` under `evolution-workspaces`. After an edit, the range, status and diff Jobs succeed `verified`: the range Artifact equals the reimplemented sed's answer, and the status and diff Artifacts equal the trusted git's answer run directly with the same argv in the clean environment. After a restart the copy is adopted with no "not adopted" line. A wet sweep with no quiescence or retention destroys the copy's tree and keeps its manifest |
| the same file's inspector test, on a project outside any git working copy | Inspect, read-source-range and the isolated copy are `available`. The git reads are `unavailable`, and a git-status plan is refused before admission with zero dispatch |
| `windows_signed_runtime` `workspace_profile_leaves_run_end_to_end_through_the_pipe` (dev signer) | `arkdeck workspace read`, `status`, `diff`, `isolate` and `sweep` run against the dev-signed daemon over a project registered through the CLI. Each ends `succeeded`, provider `workspace`, `hostOnly`, one step of its kind, no evidence blockers, and one derived Artifact with `bytesVerified`. After a restart each read is a new Job with the same SHA-256. Their five coverage entries are Windows `implemented` |
| `arkdeck maintainer contracts export` | Exactly five statuses moved, Windows `partial` → `implemented`: `workspace.read-source-range@1`, `inspect-git-status@1`, `inspect-diff@1`, `prepare-isolated-copy@1`, `sweep-isolated-copies@1`. `machine_contracts` passes; the oracle's pins do not cover this manifest's bytes |

## Gates

| Check | Result |
| --- | --- |
| `cargo fmt --all --check` | exit 0 |
| `cargo clippy --workspace --all-targets -- -D warnings` (Windows) | exit 0 |
| cross-check clippy `-D warnings` for `aarch64-apple-darwin` and `x86_64-unknown-linux-gnu` (stubbed toolchain) | exit 0, exit 0 |
| `cargo test --no-fail-fast -p arkdeck-platform -p arkdeck-hoststore -p arkdeck-agentd -p arkdeck-cli`, `ARKDECK_DEV_SIGNER_THUMBPRINT` set | 267 `test result: ok`, 0 failed. The only `SKIPPED` lines are the two known wildcard-listener skips |
| `PYTHONUTF8=1 sh scripts/check-sdd.sh`; `git diff --check` | `check_sdd: 0 error(s), 0 warning(s)`; clean |

These were run on the layer over #2482's `411f8721`. The layer was then rebased onto #2482's
`a0ac59b2`, whose change (the patch narration) touches no file of this layer.

## Delegated minor decisions, pending the next rulings batch

1. **Git runs with no system configuration** (`GIT_CONFIG_NOSYSTEM=1`). A verified launch does
   not name the image Git derives its system file from, and the Runtime's git reads no
   host-wide configuration, as the macOS oracles run git in a closed environment. No global
   configuration is read either, because the clean base environment names no home.
2. **A spawn's working directory is spelled verbatim** (`\\?\X:\…`), as the Windows tool runner
   requires it.

## Left out, and why

- **`workspace.apply-patch@1`, `revert-patch@1` and `create-checkpoint@1` end to end.** They are
  device mutations. A development root's mutation authority names the account's root, so they
  are refused there, as on macOS. Running them needs the installed composition and a standing
  (patch) or Runtime (checkpoint) capability. The next layer covers that, along with the hvigor
  build, tests and symbolization (and the build's landing path join).
- **Signing and the HAR console challenge** are another agent's layer, stacked on this one.
