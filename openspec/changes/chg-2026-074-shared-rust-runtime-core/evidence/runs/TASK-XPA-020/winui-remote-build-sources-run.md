# TASK-XPA-020 — WinUI remote build sources, 2026-10-04

- Task: the remote build sources of the Debug workspace, TASK-XPA-020, WM5
  (`docs/design/cross-platform/windows-phase-agent-prompt.md`), after Diagnostics #2464. The lead's
  instruction: the App-side SSH browser on the built-in Windows OpenSSH client (`ssh.exe`) with the
  macOS host-key rules, credentials in Windows Credential Manager instead of the Keychain, the same
  trust rules; a macOS behaviour without a Windows counterpart is reported, not dropped.
- Note: ruling 53 (#2430) recorded "there is no Remote build source on Windows". The lead's
  instruction for this slice supersedes it; flagged for the next rulings batch.
- Base: branch `agent/xpa-020-winui-remote-build-sources-20261004`, one commit on `origin/main`
  `2d85d513`; nothing is force-pushed.
- Host: the Windows 11 x64 reference host, non-elevated; .NET SDK 10.0.401, Windows App SDK 2.5.1,
  MSTest 4.4.1, FlaUI.UIA3 5.0.0; OpenSSH_for_Windows_9.5p2 (the system's `ssh.exe`, `sshd.exe`,
  `sftp-server.exe`, `ssh-keygen.exe`). The tests run `sshd.exe` as this user on a loopback port
  with test keys in a temporary directory; no service was installed or changed, no system setting
  changed, no device, `hdc` or DAYU200. Nothing was left running.

## The macOS surface

`Packages/ArkDeckKit/Sources/ArkDeckClientKit/RemoteBuildSourceApplicationFacade.swift` (the whole
provider), `ArkDeckApp/Features/Settings/SettingsRootView.swift` and
`SettingsWorkspaceViewModel.swift` (Settings › Servers and the editor),
`ArkDeckApp/Features/Debug/DebugRemoteBuildBrowserViewModel.swift` and the browser and remote
branch of `DebugWorkspaceView.swift`, `DebugApplicationFacade.prepareRemoteNativeLibrary`, and
`RemoteBuildSourceContractTests.swift`, read in full.

## What was built

| Part | Content |
| --- | --- |
| `App.Core/RemoteSources/RemoteBuildSources.cs` | The model, the macOS error cases, and `RemoteBuildSourceBounds` (name, host, port, user name, absolute root, path components, relative paths, containment, credential bounds), as Swift's. |
| `RemoteBuildSourceStores.cs` | `sources-v1.json`, `target-bindings-v1.json`, `audit-v1.jsonl` under `%LOCALAPPDATA%\ArkDeck\App\RemoteBuildSources`: owner-only (a protected DACL of this user, the counterpart of 0600), written whole through a staging file, Swift's JSON (sorted keys, ISO 8601 seconds, upper-case UUIDs); the audit holds a path only as its SHA-256. The credential envelope is Swift's JSON. |
| `RemoteCredentialStore.cs` | The Keychain item (service `com.arkdeck.remote-build-source.v1`, account the lower-case id) as generic credentials `ArkDeck/app/<service>/<account>` in this user's Credential Manager, `CRED_PERSIST_LOCAL_MACHINE`, each call in ArkDeck's per-user turn (`Local\ArkDeck.CredentialManager.<SID>`, as the Runtime's owner), read back after writing. |
| `Sftp.cs` | A read-only SFTP v3 client (realpath, opendir/readdir, open for reading, fstat, read, close); it has no request that writes. |
| `SshConnector.cs` | The OpenSSH connector (below) and the App's askpass mode. |
| `RemoteBuildSourceProvider.cs` | Probe (normalize, credential, connect, realpath of the root, stage for 5 minutes under a single-use token), save (Credential Manager, then the records; the previous credential restored on failure), remove, list (root unchanged, canonical path contained, ≤ 500 entries, directories and lib*.so only, directories first, natural order), fetch (lib*.so, 64 B–64 MiB, 512 KiB reads, size and modification time unchanged), the bindings, the audit; and the staging of a fetched library for the local preparation. |
| `App/Program.cs` | The entry point: as `SSH_ASKPASS` the executable answers one prompt from its App over the pipe and exits; otherwise it starts WinUI. |
| `App/Pages/SettingsPage.RemoteSources.cs` | Settings › Servers: the rows, Add/Edit (the macOS editor: fields, Password or OpenSSH private key, Choose private key…, Use system default, passphrase, Test connection and inspect host key, the verified facts, trust on save, any edit discarding the probe), Remove with confirmation, the security boundary. |
| `App/Pages/DebugPage.RemoteBrowser.cs`, `DebugPage.Tabs.cs` | The remote browser (server, Up, Refresh, path, entries, Use selected library; stale answers dropped), binding the server to the Target, and the preparation: fetch, check, stage owner-only, prepare as a local file, remove the staging. |
| Strings | The 49 `settings.remoteSources.*` keys, `settings.tab.remoteSources` and 8 `overview.record.remoteServer.*` (values unchanged), and 37 Windows-only `windows.remoteSources.*` keys (below); `windows.debug.remote.unavailable` is gone. |

### The OpenSSH connector, and how it keeps macOS's boundary

macOS speaks SSH in-process (Citadel) and reads no SSH config, agent or known_hosts. On Windows the
built-in client is used, by its system path only (`%SystemRoot%\System32\OpenSSH\ssh.exe`), with:

- argv only, no shell: `-F none -T -x -a`, `BatchMode=no`, `ConnectTimeout=12` (macOS's 12 s),
  `IdentityAgent=none`, `IdentitiesOnly=yes`, no forwarding, `ControlMaster=no`/`ControlPath=none`,
  `PermitLocalCommand=no`, no GSSAPI/host-based/keyboard-interactive, `UpdateHostKeys=no`,
  `VerifyHostKeyDNS=no`, then `-p <port> -l <user> -s -- <host> sftp`;
- **host keys**: `HostKeyAlias=arkdeck-remote-build-source` and a per-connection
  `UserKnownHostsFile` (with an empty `GlobalKnownHostsFile`) in an owner-only temporary directory.
  A saved source's file holds only its pinned key, with `StrictHostKeyChecking=yes` and
  `HostKeyAlgorithms` of that key's type: any other key is `hostKeyChanged`. A first probe (or a
  changed host or port, as on macOS) uses `accept-new` on an empty file, and the key the client
  wrote there is the one shown (macOS's fingerprint: `SHA256:` + hex of the key blob) and trusted
  only when that probe is saved. The person's `~/.ssh/known_hosts` and config are never read or
  written;
- **secrets**: `SSH_ASKPASS` is the App's own executable with `SSH_ASKPASS_REQUIRE=force`; it gets
  the password or passphrase from the App through an owner-only, single-connection named pipe with
  a random name, at most once per offered key, and only for a password or passphrase prompt. No
  secret is on a command line, in the environment, or in a file other than an explicit or
  system-default key written for the connection into the owner-only directory, which is deleted
  when the session ends;
- **system default**: exactly `%USERPROFILE%\.ssh\id_rsa`, then `id_ed25519`, each only when a
  regular file (no reparse point) owned by this user and granting no one else (SYSTEM and
  Administrators allowed, as OpenSSH for Windows itself), 1 B–256 KiB, unchanged while read, and an
  ed25519 or RSA key.

## Delegated minor decisions (pending the next rulings batch)

1. **Credential Manager in parts.** A generic credential holds 2,560 bytes, macOS keeps a 256 KiB
   key in one Keychain item: the envelope is stored as `…/<account>#<n>` parts under a manifest
   (byte count, part count, SHA-256) written last; a mismatch reads as unavailable.
2. **The store namespace is `ArkDeck/app/…`**, beside the Runtime's `ArkDeck/<access group>/…`;
   tests and `--remote-sources-root` use `ArkDeck-fixture/app/…`.
3. **The App's files live in `%LOCALAPPDATA%\ArkDeck\App\RemoteBuildSources`**, apart from the
   Runtime's state (`--remote-sources-root` overrides it; the UI tests always pass one).
4. **Windows-only strings** where macOS names its platform: Keychain → Credential Manager (the
   badge, the security detail, the editor's optional password and stored-credential lines, the
   removal detail), `~/.ssh` → `%USERPROFILE%\.ssh`, "this Mac" → "this PC"; the localized error
   messages (macOS hard-codes Chinese ones), the client line, the editor's "test first" refusal,
   the probe facts' labels, saved/removed/loading statuses.
5. **No disabled Save**: Save before a test says why (XPA-AC-8) instead of being disabled.
6. **The Settings tab** is "Servers" between Toolchains and Storage, as on macOS.

## What macOS does that Windows does not, and why

1. **Overview's remote-server line** (`overview.record.remoteServer`: bound, stale, unbound for the
   selected device): the Windows Overview has no device record section to hold it. The bindings
   are written and read (`BindingAsync`) and its strings are in the catalogue; the line belongs
   with that section's port.
2. **The macOS sandbox entitlement** for the two identity files has no Windows counterpart; the
   owner, ACL and reparse-point checks stand in for `O_NOFOLLOW`, `st_uid` and `mode & 077`.
3. **In-process SSH**: Windows uses the system client as above; its version is whatever Windows
   ships (9.5p2 measured).

## Checks on the reference host

Local targeted checks (2026-10-04, built on `4f5d238c`; the rebase onto `2d85d513` adds only a
Rust USB census change, #2471; logs in the session scratchpad `x3/remote-full.log`):

| Check | Result |
| --- | --- |
| `cargo build -p arkdeck-agentd` (the daemon the UI tests drive; SHA-256 `651b6b9f4a49d938be4d7bf2b9960a779633033a337bbc4e802f447a035f6301`) | exit 0 |
| `dotnet build ArkDeck.Windows.slnx -c Release` | 0 warnings, 0 errors |
| App.Tests | 133 passed (`RemoteBuildSourceTests` 12; `RemoteBuildSourceSshTests` 1: probe, pin, list and read through `ssh.exe` against this user's loopback `sshd.exe`, and an impostor host key refused) |
| ClientKit.Tests | 42 passed, 1 skipped (`ARealArtifactSigningPublisherIsMatchedThroughWinVerifyTrust`, needs a signed release) |
| App.UITests (`ARKDECK_APP_UITESTS=1`, `ARKDECK_CLIENTKIT_DAEMON` = the daemon above) | 112 passed, 2 skipped (`TheInstalledAppConnectsToTheDaemonTheCliStarted`, needs an installed package; `KeyboardFocusIsVisible`, locked desktop); `RemoteSourcesFlowTests` adds a server through the UI with a key from the file dialog, tests and saves it, browses and chooses `arm64/libentry.so` in Debug, and removes it |
| `generate-clientkit`, `generate-ui-strings`, `generate-xaml-tokens`, `generate-app-icons` `--check` | exit 0 |
| `python -m unittest scripts/ci/test_plan.py scripts/test_agent_pr_workflow.py` | OK |
| `PYTHONUTF8=1 sh scripts/check-sdd.sh` | 0 errors, 0 warnings |
| `git diff --check` | clean |

After the rebase, with the daemon rebuilt from `2d85d513` (SHA-256
`93b18927f929a653df51339a7eee7a461daf1697bd5e453153ffd7be9c0044ff`): the Release build 0 warnings,
`RealDaemonTests` and `RemoteSourcesFlowTests` 11 passed.

The App's static-contract test (`TheAppHoldsNoRuntimeSemantics`) now names `SshConnector.cs` as
the one file with a named pipe: its per-connection `arkdeck-askpass-<random>` channel, which names
neither ClientKit nor the daemon's endpoint.

## Not done here, and why

1. Overview's remote-server line (above).
2. Deploying a fetched library on a device: it needs the Windows HDC tuple (CHG-2026-078); the
   preparation reaches the Runtime's Import and plan as a local file does.
3. The new Windows-only strings' Chinese values want the maintainer's review.

CI: to be recorded by the PR's hosted run; not verified here.
