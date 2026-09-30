# TASK-XPA-002 — Windows host W0 on the reference host, 2026-09-30

Host initialisation and a local reproduction of the hosted CI `workspace` lane on
the real Windows 11 target host. This is environment preparation, not SPK-3,
not Windows platform acceptance and not device acceptance: no board was touched,
no `hdc` was run, the daemon is unsigned and uninstalled.

Checkout: `main` at `fb6c808c` (fix(TASK-XPA-017): retry a busy hdiutil create in
the release build (#2323)), worktree clean apart from this uncommitted record.

## Host facts (measured 2026-09-30)

| Item | Value |
| --- | --- |
| OS | Windows 11 Pro 10.0.26200, 64-bit |
| CPU | Intel Core i7-10700 @ 2.90 GHz, 8 cores / 16 logical |
| Disk | one 1 TB NVMe SSD; C: and D: are partitions 3 and 5 of disk 0 |
| C: | NTFS, Fixed, 399 GiB, 143 GiB free after all installs (151 GiB before) |
| D: | NTFS, Fixed, 554 GiB, 494 GiB free after all installs |
| Account | a local account (redacted), member of `BUILTIN\Administrators` (deny-only in the filtered token), Medium integrity; UAC on |
| Profile dir | `%USERPROFILE%` (a truncated Microsoft-account name, not the account name); Git Bash `~` = `%USERPROFILE%` |
| Claude Code | native Windows, Git Bash `uname -s` = `MINGW64_NT-10.0-26200` |

Differences from the facts probed from the Mac:

- C: had ~151 GiB free, not ~18 GiB. The maintainer's D: placement was kept.
- Global `core.autocrlf` is **unset**; the effective value is `input` from the
  system scope (`C:/Program Files/Git/etc/gitconfig`), not `true`. Left unchanged.
- Global `core.longpaths` was already `true` (`~/.gitconfig`).
- The existing VS 2019 Build Tools instance is incomplete (`isComplete: 0`,
  `state: 5`), with no C++ tools. Left untouched.
- A `C:\Python313` interpreter was present (not mentioned before).
- `winget.exe` is an App Execution Alias in `%LOCALAPPDATA%\Microsoft\WindowsApps`,
  which is not on Git Bash's `PATH`; it was invoked by absolute path.
- In Git Bash `whoami.exe` resolves to Git's own `whoami`; the Windows one is
  `/c/Windows/System32/whoami.exe //groups` (GBK output, piped through `iconv`).

Chosen locations:

| Item | Location |
| --- | --- |
| Repository | `D:\src\ArkDeck` (`/d/src/ArkDeck`) |
| `RUSTUP_HOME` | `D:\rust\rustup` (user env var via `setx`) |
| `CARGO_HOME` | `D:\rust\cargo` (user env var via `setx`) |
| Cargo target | `D:\src\ArkDeck\rust\target` (3.7 GiB after the baseline) |
| Python venv | `D:\src\ArkDeck\.venv-sdd` |

## Tools

All from the official `winget` source (hash verified by winget) with
`--accept-package-agreements --accept-source-agreements`, maintainer-approved.

| Tool | Version | Package / location | Verification |
| --- | --- | --- | --- |
| Rustup | 1.29.1 | `Rustlang.Rustup`, installed into `D:\rust` | `rustup show home` = `D:\rust\rustup`; no `~/.cargo` / `~/.rustup` |
| Rust toolchain | rustc 1.98.1 (48a229cea 2026-09-01), cargo 1.98.1 (797e8a9bc 2026-08-05) | `stable-x86_64-pc-windows-msvc` via `rust/rust-toolchain.toml`; rustfmt, clippy | host `x86_64-pc-windows-msvc` |
| VS Build Tools 2022 | 17.14.37710.0, `isComplete: 1` | `Microsoft.VisualStudio.2022.BuildTools`, `--add Microsoft.VisualStudio.Workload.VCTools --includeRecommended`; Windows SDK 10.0.26100.0 | `vswhere -requires Microsoft.VisualStudio.Component.VC.Tools.x86.x64` → `C:\Program Files (x86)\Microsoft Visual Studio\2022\BuildTools` |
| Python | 3.14.7 | `Python.Python.3.14`, `--scope user` → `%LOCALAPPDATA%\Programs\Python\Python314\python.exe` | `py -0p` lists `-V:3.14 *` (now the `py` default); bare `python` in new processes is now 3.14 (see System settings) |
| PowerShell | 7.6.6 | `Microsoft.PowerShell` — winget installed the **MSIX** package: `C:\Program Files\WindowsApps\Microsoft.PowerShell_7.6.6.0_x64__8wekyb3d8bbwe\pwsh.exe`, reached through the `pwsh.exe` alias | `pwsh -v` |
| GitHub CLI | 2.101.0 (2026-09-15) | `GitHub.cli` → `C:\Program Files\GitHub CLI\gh.exe` | `gh --version`; `gh auth status`: not logged in |
| jq | 1.8.2 | `jqlang.jq` (user scope, WinGet Links) | `jq --version` |

Installation notes: the first two Python 3.14 attempts were ended by the
installer wrapper's own 900 s timeout (winget exit 143) while the installer
waited on a UAC prompt / setup window nobody was at the desk to answer; the third
attempt, with the maintainer present, succeeded. `pyenv update` failed on this
host (`pyenv-update.vbs(172, 13)` htmlfile error on the graalpython mirror), so
pyenv-win could not list 3.14.x.

## System settings

- Done by the agent (user scope): `setx RUSTUP_HOME D:\rust\rustup`,
  `setx CARGO_HOME D:\rust\cargo`; repository-level `core.autocrlf false`,
  `user.name Probe`, `user.email probe@example.invalid`.
- `LongPathsEnabled`: set to `1` by the maintainer (elevated PowerShell,
  `New-ItemProperty -Path HKLM:\SYSTEM\CurrentControlSet\Control\FileSystem -Name LongPathsEnabled -Value 1 -PropertyType DWORD -Force`);
  read back as `0x1` after the Claude Code restart.
- Side effect of the Python 3.14 install: `...\Python314\Scripts\` and
  `...\Python314\` were prepended to the **user** `Path`, ahead of pyenv-win, so a
  bare `python` in new processes resolves to 3.14.7 rather than pyenv's 3.10.11.
  Not reverted (maintainer's call).
- Defender exclusions: added by the maintainer in an elevated PowerShell,
  `Add-MpPreference -ExclusionPath 'D:\src\ArkDeck\rust\target','D:\rust\cargo'`
  (path exclusions only; no process exclusions, real-time protection unchanged).
  Reported done by the maintainer; not read back by the agent, because a
  non-elevated `Get-MpPreference` returns `N/A: Must be an administrator to view exclusions`.
  The baseline timings above were measured **before** these exclusions.
- `ARKDECK_PYTHON`: with the maintainer's approval, a new `~/.bashrc` exports
  `ARKDECK_PYTHON=/d/src/ArkDeck/.venv-sdd/Scripts/python.exe`, and
  `[ -f ~/.bashrc ] && . ~/.bashrc` was appended to `~/.bash_profile` (which did not
  source it before). Verified: `bash -lc '"$ARKDECK_PYTHON" --version'` → Python 3.14.7.
  Claude Code's Bash tool runs a non-login, non-interactive bash and reads neither
  file, so the maintainer chose a user environment variable as well:
  `setx ARKDECK_PYTHON D:\src\ArkDeck\.venv-sdd\Scripts\python.exe` (read back from
  `HKCU\Environment`). The Windows-form path works from Git Bash:
  `"$ARKDECK_PYTHON" --version` → 3.14.7 and `sh scripts/check-sdd.sh` passes with it.
- After the Claude Code restart the session still carried the pre-install
  environment (no `RUSTUP_HOME`/`CARGO_HOME`, none of the new `PATH` entries),
  although `HKCU\Environment` holds all of them: it was launched from a process
  that predates the `setx`/winget changes. After a restart from a fresh terminal
  window the agent session sees `RUSTUP_HOME=D:\rust\rustup`,
  `CARGO_HOME=D:\rust\cargo` and `ARKDECK_PYTHON`; `cargo`/`rustup`
  (`D:\rust\cargo\bin`), `gh`, `jq` and `python` (3.14.7) resolve from `PATH`;
  `sh scripts/check-sdd.sh` passes using the inherited `ARKDECK_PYTHON`, and
  `cargo fmt --all --check` passes.
- `pwsh` and `winget` are App Execution Aliases in
  `%LOCALAPPDATA%\Microsoft\WindowsApps`, which is not on this host's `PATH`
  (pre-existing). At the maintainer's request the agent appended
  `%LOCALAPPDATA%\Microsoft\WindowsApps` to the **end** of the user
  `Path` (winreg, type kept as `REG_SZ`, 1075 → 1126 chars; `setx` avoided because it
  truncates at 1024; previous value backed up; `WM_SETTINGCHANGE` broadcast). With it,
  `pwsh -v` → 7.6.6 and `winget --version` → v1.29.380. Being last, it does not
  shadow `python` (Python314) or `python3` (pyenv 3.10.11) with the Store stubs.
  Takes effect in processes started after the change.

## Line endings

Clone: `git clone -c core.autocrlf=false -c core.longpaths=true https://github.com/ArkDeck/ArkDeck.git`,
then `git config core.autocrlf false`.

- `git ls-files --eol` index/worktree mismatches: **0** (10,182 files).
- `i/crlf w/crlf` files: exactly the five expected — the three HDC Golden/Probe
  `*.bin` (`success-uninstall/stdout.bin`, `empty-marker.bin`, `rows-crlf.bin`) and
  the two TraceStreamer LICENSES (`hiperf-Apache-2.0.txt`, `sqlite-Public-Domain.txt`).
- `git status --short`: empty.

## Python and check-sdd

`py -3.14 -m venv .venv-sdd`; `pip install -r scripts/requirements-sdd.txt jsonschema==4.26.0`
→ PyYAML 6.0.3, jsonschema 4.26.0.
`ARKDECK_PYTHON=... sh scripts/check-sdd.sh` → exit 0, 12 s,
`check_sdd: 0 error(s), 0 warning(s), 121 acceptance IDs`.

## Baseline: CI workspace lane on this host

Single clean run from `cargo clean` (removed 3.7 GiB), 08:31–08:33 local time,
no other cargo process. `rustc -V`: `rustc 1.98.1 (48a229cea 2026-09-01)`.
Logs: `D:\src\ArkDeck\.claude\w0-baseline\*.log` (ignored, not committed).

| # | Command | Exit | Time | Result |
| --- | --- | --- | --- | --- |
| 1 | `cargo fmt --all --check` | 0 | 9 s | no diff |
| 2 | `CARGO_NET_GIT_FETCH_WITH_CLI=true cargo fetch --locked` | 0 | 0 s (warm `CARGO_HOME`; first anonymous fetch: 0, 7 s) | ArkForge fetched anonymously over HTTPS |
| 3 | `cargo clippy --workspace --all-targets -- -D warnings` | 0 | 16 s | no warnings |
| 4 | `"$ARKDECK_PYTHON" rust/scripts/workspace-tests.py` | 0 | 78 s (test build 38 s) | 258 test-binary/doctest result groups, **593 passed, 0 failed, 0 ignored** |
| 5 | `"$ARKDECK_PYTHON" rust/scripts/generate-contract.py --check` | 0 | <1 s | 105 methods, 1043 recorded shapes, contract identity `1d7d101e83fe` |
| 6 | `cargo run -p arkdeck-platform --example windows_spk3 -- process-selftest` | 0 | 5 s | `{"argvRoundtrip":true,"cleanChildEnvironment":true,"deviceDispatchCount":0,"executableSha256":"4aadabf9…4cc0","outputLimitRefused":true,"platform":"windows","probe":"process-selftest","timeoutRefused":true}` |

Build directory after the lane (plus the smoke build): 3.7 GiB.

A first, discarded attempt ran two copies of the baseline script concurrently (an
agent tooling mistake: stopping the watcher did not stop the script); its timings
and logs were thrown away. All results above are from the single clean run; that
earlier run was also all green.

### Differences from hosted CI

None observed: all six commands are green on this Windows 11 host, as on the
hosted `windows-latest` job. Compared against the hosted job for the **same
revision** `fb6c808c`: Swift CI run
[36595536890](https://github.com/ArkDeck/ArkDeck/actions/runs/36595536890), job
`rust-checks / Rust workspace (windows-latest)` (109499761894, success), same
`rustc 1.98.1 (48a229cea 2026-09-01)`. Both runs report 258 result groups and
593 passed / 0 failed / 0 ignored, and the multiset of per-group passed counts is
identical (hosted log read with `gh run view --job 109499761894 --log` after the
maintainer's `gh auth login`). The
note in `rust/README.md` that `cargo fetch --locked` needs read access to a
private ArkForge repository is outdated: the fetch succeeded anonymously.

## Host-path smoke

`target\debug\arkdeck-agentd.exe` started in the background (PID 8680, confirmed
running before and after the CLI call); then `target\debug\arkdeck.exe --output json doctor`:

```json
{"command":"doctor","error":{"attentionRequired":false,"code":"runtimeUnavailable","controlRequestRetryable":true,"details":{"method":"doctor"},"message":"pipe server lacks the installed package or trusted signing identity; zero frames sent"},"meta":{"cliVersion":"0.1.0","controlProtocolVersion":"1.0.0","controlRequestId":"ctl-96c9f3f7-e646-43e7-ba34-39c244d82953"},"ok":false,"schemaVersion":"arkdeck.cli.result/1"}
```

Exit 69. `operation list` and `device candidates` (via `cargo run`, previous
run) give the same refusal for `operation.list` / `device.observations`, exit 69.
The daemon wrote nothing to stdout/stderr. This is the expected XPA-AC-6
behaviour for an unsigned, uninstalled daemon — the CLI refuses the server
identity before sending a frame — and is byte-identical (apart from
`controlRequestId`) to `000-doctor.cli.jsonl` in `hosted-windows-2da3dfef.zip`.
The daemon was then stopped with `taskkill /F`; no `arkdeck*` process remained.

## Push credentials and hooks

At W0 the maintainer deferred push (暂不配置推送); it was configured on 2026-09-30 when the
Windows phase prompt (`docs/design/cross-platform/windows-phase-agent-prompt.md` §2.5) started:

- **Deploy key**: a host-only ed25519 key `~/.ssh/arkdeck-agent-deploy-windows` (comment
  `arkdeck-agent-windows`), added by the maintainer to `ArkDeck/ArkDeck` → Deploy keys with
  write access. The agent did not use gh or the API to add it.
- **SSH alias** `github-arkdeck-agent` (`HostName github.com`, `IdentitiesOnly yes`) appended to
  `~/.ssh/config`. `known_hosts` already held
  `github.com ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIOMqqnkVzrm0SdG6UOoqKLsabgH5C9okWi0dh2l9GKJl`,
  equal to the line pinned in `scripts/ci/arkforge-cargo-fetch.sh` and to the ed25519 entry of
  `https://api.github.com/meta` `ssh_keys`; port 22 is reachable.
- **Verification**: `ssh -T git@github-arkdeck-agent` → `Hi ArkDeck/ArkDeck! …`, exit 1;
  `git remote set-url --push origin git@github-arkdeck-agent:ArkDeck/ArkDeck.git` (fetch stays
  anonymous HTTPS); `git push --dry-run origin HEAD:refs/heads/agent/deploy-key-probe` → exit 0,
  nothing pushed.
- **gh** 2.101.0: the maintainer ran `gh auth login` (keyring, git protocol ssh; the token
  carries write scopes); `gh auth status` exit 0; no git credential helper or remote was changed.
- **Guard hook**: a PreToolUse hook in `%USERPROFILE%\.claude\settings.json`, matcher
  `Bash|PowerShell`, running `%USERPROFILE%\.claude\hooks\arkdeck-guard.py` with the Python 3.14
  interpreter by absolute path. On native Windows, command hooks run under Git Bash (Claude Code
  hooks reference, "Command hook fields"); the Mac bash+jq one-liner was not reused. It is active
  in repositories whose root has `.github/workflows/agent-pr.yml`, or for `gh -R/--repo` naming
  the ArkDeck organisation, and it follows `cd`/`Set-Location`/`git -C` inside a command,
  because the hook's `cwd` is the session's. It refuses `gh pr
  create|edit|reopen|merge|review|comment|close|ready`, `gh api` writes (a non-GET method, or
  fields/input), `gh run rerun|cancel`, `gh workflow run`, `git push` from a branch outside
  `agent/**` or to a destination outside it, `--all`/`--mirror`, a push whose repository cannot
  be resolved, and a push while `git cherry origin/main HEAD` has a `-` line. Refusal is exit 2;
  a guard failure on a command mentioning gh or push also refuses. A 33-case offline harness
  passed; live in the session: `gh pr create --help` refused, `git push --dry-run` on `main`
  (a temporary worktree, since removed) refused, `gh pr list --limit 1` allowed (exit 0).

## Not done, and why

- SPK-3, DAYU200, Windows code, CHG-2026-074 revision: out of scope for W0.
