# ArkDeck for Windows

The Windows client of ArkDeck (CHG-2026-074, TASK-XPA-007). Windows 11 x64 only (r13). The client
holds no runtime semantics: everything it shows is a projection read from the local Rust daemon
(`arkdeck-agentd`) through **ArkDeck.ClientKit**.

| Path | What it is |
| --- | --- |
| `ClientKit/` | `ArkDeck.ClientKit` (.NET 10 class library): generated contract bindings, the embedded method schemas, the authenticated named-pipe transport and the connection semantics |
| `ClientKit.Tests/` | MSTest suite (`dotnet test`) |
| `App/` | **ArkDeck** (`ArkDeck.exe`), the WinUI 3 App on Windows App SDK 2.5.1, self-contained, x64: NavigationView shell (Overview, Device, History), the global Job Inspector, the daemon-unavailable recovery banner |
| `App.Core/` | `ArkDeck.App.Core`: the UI-free half of the App — which daemon to reach, one ClientKit read per surface, the page states, the catalogue lookup, the scripted test transport |
| `App.Tests/` | MSTest suite of App.Core, the catalogue and the App's static contracts |
| `App.UITests/` | MSTest + FlaUI (UIA3): UIA semantic snapshots of the running App; needs a desktop session (`ARKDECK_APP_UITESTS=1`), otherwise reported skipped |
| `scripts/generate-clientkit.py` | Generator of `ClientKit/Generated/ControlContract.g.cs`; `--check` fails on drift |
| `scripts/generate-ui-strings.py` | Generator of the App's `.resw` from `spec/ui-semantics/strings.json` (values equal to the macOS `.xcstrings`); `--check` fails on drift |
| `scripts/generate-app-icons.py` | Generator of `App/Assets/AppIcon.ico` (16–256 px) and the MSIX visual assets (scale-100/200, the taskbar target sizes) from the macOS AppIcon (`ArkDeckApp/Resources/Assets.xcassets/AppIcon.appiconset`), resampled, never drawn; `--check` compares decoded pixels |
| `scripts/generate-xaml-tokens.py` | Generator of `App/Themes/ArkDeckTokens.xaml` from `docs/design/arkdeck-ds/src/tokens.css` (product accent on controls, ruling 16); `--check` fails on drift |
| `ArkDeck.Windows.slnx` | The solution the `windows` CI lane builds and tests |
| `spikes/spk4/` | The SPK-4 WinUI 3 spike (its own solution and pins; not part of the lane) |

## ArkDeck.ClientKit

- **Contract, generated.** `generate-clientkit.py` reads the same inputs as the Rust contract
  generator: `Packages/ArkDeckKit/Contracts/control-protocol.json` (version, 4 MiB / 8 MiB frame
  limits, method list; the contract identity is the SHA-256 of its sorted compact JSON),
  `spec/control/methods/*.json`, `spec/baselines/swift-single-v1.json` (cross-check) and the shared
  pattern vocabulary `rust/crates/arkdeck-contract/src/schema_patterns.json`. It writes constants,
  the SHA-256 of every method schema, and typed records for the four methods the Rust side types
  (`health`, `doctor`, `operation.list`, `device.observations`). The schemas are embedded in the
  assembly; `ContractSchemas` refuses to validate anything if one differs from its recorded digest.
- **Wire (T0 with the Rust client).** Single-v1 LF frames `{protocolVersion,contractIdentity,id,
  method,params?}`; the LF counts toward the 4 MiB request / 8 MiB response limits; JSON written as
  `serde_json::to_vec` writes it (members in code-point order, serde's escapes and float text) and
  parsed as `strict_json` parses it (duplicate keys refused, depth 127, serde's number kinds).
- **Connection (T1 with `arkdeck-client`).** `health` first on the same connection, validated
  against this contract; a failed preflight sends zero business frames; a failed exchange leaves the
  connection unusable and is never replayed; a malformed local request sends no byte; connection,
  authentication and every read and write share one time budget. While every instance of the pipe
  is busy (`ERROR_PIPE_BUSY`), the open waits for a free one within that budget, as the Rust
  client's `connect_verified` does (the App reads a page and the Job Inspector at once).
- **Server authentication (design §F.2), before any byte is written.** The pipe is opened with
  `SECURITY_SQOS_PRESENT | SECURITY_IDENTIFICATION`. Layer 1: the pipe object's owner SID must equal
  this process token's owner SID. Layer 2: the connection's server PID is opened and held, its image
  must be the installed daemon (canonical path and file id), signed by the pinned Authenticode
  signer (SHA-256 of the certificate DER) or by the pinned publisher (ruling 17), or running in
  the installed MSIX package family, and the
  PID must not change; the image file and its ancestor directories are held for the connection.
- **Failures are typed.** `ControlFailureKind.DaemonUnavailable` (with a `DaemonUnavailableReason`)
  means nothing ran; the UI shows `ControlFailure.Banner`, the daemon-unavailable recovery banner,
  instead of any data. `OutcomeUnknown` means a business frame may have been processed; read the
  state back instead of retrying.

`ControlSession` is the entry point for UI code: one authenticated connection per call, `health`
first, `ControlResult` back.

## ArkDeck (the App)

- **Data only through ClientKit.** `App.Core` reads `health`, `doctor`, `device.observations`,
  `target.list|show|availability`, `job.list`, `job.status`, `job.events`, `artifact.list`,
  `artifact.read` and `trace.inspect` — one authenticated connection per call, health first —
  and keeps each answer as it came: the data, or `unavailable(reasonCode): detail` with the CLI
  command that reads the same thing (the daemon's wire code, e.g.
  `unavailable(rejected): hdc.notConfigured`, or `daemonUnavailable` when nothing answered). Its
  one write is an adopted Target's Runtime display name (`target.display-name.set|clear`,
  guarded by the generation the App read; TASK-XPA-020).
- **Surfaces (TASK-XPA-020).** Device lists the adopted Targets (the Target store answers
  without an HDC), shows a Target's `target.show` and `target.availability`, and renames or
  clears its display name in a Fluent dialog (the macOS rename rule: whitespace collapsed,
  1–64 characters). History shows the selected Job's detail and Artifacts; a published
  Artifact is exported as on macOS (preview, a save location the person picks, bounded
  `artifact.read` chunks each checked against the metadata, SHA-256 verified before a staging
  file replaces the destination; a sensitive one needs its own confirmation), and a Job's raw
  Trace can be inspected by the Runtime (`trace.inspect`; without a Windows Trace inspector the
  refusal is shown as it came, and the viewer is deferred, decision 5).
- **Which daemon.** The installation inputs the CLI reads: `ARKDECK_DAEMON_PATH` (default
  `arkdeck-agentd.exe` beside the App), `ARKDECK_DAEMON_SIGNER_SHA256` (the development
  signer), `ARKDECK_DAEMON_PUBLISHER_ORGANIZATION` with `ARKDECK_DAEMON_PUBLISHER_EKU` (a
  production daemon, maintainer ruling 17: the chain `WinVerifyTrust` accepted ends at the
  Microsoft Identity Verification Root 2020, and the leaf has exactly that one `O=` and the
  Artifact Signing profile EKU; both or neither), or `ARKDECK_DAEMON_PACKAGE_FAMILY`, optional
  `ARKDECK_ENDPOINT`. Without a pin there is nothing to verify, so the App connects to nothing
  and shows the recovery banner. The App does not
  start the daemon (the client-started daemon lives in the CLI); the banner names
  `arkdeck doctor`, which starts it and says what is wrong.
- **Recovery banner.** A daemon-unavailable failure (ClientKit refused or reached nothing)
  opens an `InfoBar` (assertive live region) with what happened, what to do, ClientKit's
  reason, the CLI command, Retry and Copy CLI command; the pages show their macOS unavailable
  states, never data.
- **Strings.** Every visible string comes from the shared catalogue (`spec/ui-semantics`),
  generated into `App/Strings/*/Resources.resw`; the App's language is set explicitly at start
  (`--language en-US|zh-Hans`, else the first supported Windows language, else English).
- **Semantics.** Stable AutomationIds (the macOS accessibility identifiers where one exists),
  UIA names on every meaningful element, no disabled control (XPA-AC-8), live regions for the
  Job Inspector status, the selected Job's state and the recovery banner.
- **Test transport.** `--test-transport <scenario>` replaces the pipe with an in-process
  scripted daemon (`App.Core/Testing/ScriptedDaemon.cs`: `unavailable`, `contract-mismatch`,
  `foundation`, `recovers`, `outage`, `jobs`, `targets`, `inspector`, `flash`, `viewer`, `diagnostics`) so the UIA tests can show states the real daemon
  cannot be made to show on demand. ClientKit still decodes and schema-checks every reply; the
  window shows a "Test transport" banner. Only beside it, three accessibility test hooks:
  `--text-scale <1..2.25>` (the App's own text at up to 225 %), `--high-contrast-tokens` (the
  tokens take their high-contrast system colours) and `--focus-walk <file>` (on the window
  message `ArkDeck.FocusWalk`, WinUI's own Tab navigation walks the window and writes each stop).
- **Settings (TASK-XPA-020).** A footer item with the macOS Settings tabs the Windows daemon can
  speak to — General, Toolchains (`runtime.hdc.status`, `runtime.tool.list`), Storage
  (`runtime.storage.status`), Trace (`trace.cache.status`) — and two Windows tabs: Runtime
  (`health` and every `doctor` check; service status/verify/restart and signing status as their
  CLI commands, since the App never controls the Runtime) and Workspace
  (`workspace.project.list|show`, `workspace.preset.list`). All read-only.
- **Sessions and Job actions (TASK-XPA-020).** A Sessions page lists the Session catalog
  (`session.list|show`), pins and unpins by generation, and exports and cleans up through the
  Runtime's preview-then-apply (`session.export.preview|apply`, `session.cleanup.preview|apply`):
  the person confirms the preview, and the apply names its id and digest. The export goes to a
  new folder inside the one the person picks; the Runtime proves it absent and writes it. The Job
  Inspector requests `job.cancel` for a queued or active Job after a confirmation (a request, not
  an outcome: the state is read back), shows a terminal Job's `job.result`, and opens the record
  in History, whose detail now carries the macOS evidence section (`job.evidence`).
- **Agents and Imports (TASK-XPA-020).** An Agents page lists the agent executions
  (`agent.list|status`) and the human actions waiting on a person (`human-action.list|show`).
  A waiting action is resumed after the person did what it asks (`agent.resume` for an
  execution's action, `human-action.resume` otherwise); a pick-a-device action offers exactly the
  values of its `selectionSchema` enum as a radio group, and Resume without a choice says so. An
  execution that is not terminal is abandoned after a confirmation, guarded by its generation
  (`agent.abandon`); starting one stays in the CLI. An Imports page uploads a file chosen in the
  system file dialog as an Import of one kind for an adopted Target (`artifact.import.begin`,
  bounded `append` chunks each with its SHA-256, `commit`), with its progress and a Cancel that
  aborts the partial Import; it lists and inspects the Imports (`artifact.import.list|inspect`)
  and releases a committed one after a confirmation (`artifact.import.release`). A flash bundle
  that is not a DAYU200 images archive is refused by the Runtime's format validator.
- **Debug (TASK-XPA-020).** The macOS Debug workspace: the Target the page submits against and
  five tabs — Artifacts (an app-owned native library imported, planned with `job.plan`, reviewed
  in the plan sheet, then submitted exactly as reviewed), Logs (a bounded HiLog capture and its
  shards, with export), Apps (one HAP lifecycle, its packages imported for their leases), Network
  (typed port rules, and the active ones `debug.probe` reads) and Commands (four read-only
  templates) — each with its operation's availability (`operation.list|describe`) and recent
  Jobs. Every action is one closed typed Runtime Job (`RuntimeRequest`: fixed operation, typed
  inputs, the Target and binding revision read, the workspace's client name) submitted with
  `job.submit`, run with `job.run` and read back with `job.show`; an action that cannot run says
  why instead of being disabled.
- **Flash (TASK-XPA-020).** The macOS Flash workspace for the DAYU200 full restore
  (`flash.full-restore@1`): the current device and its readiness, one primary surface (choose an
  image, then the one fully named Flash button with its user-data impact; the running progress;
  the result with its postflight build and binding checks) and a details toggle with the
  operation's availability, device access (`flash.device-access`), the bootloader
  (`flash.bootloader-status`), the profile and Target, the prerequisites (`flash.prerequisites`),
  the exact plan (catalog stages, plan and step-set digests, lane plan preview, partitions) and
  the Runtime activity. The chosen archive is reviewed on the host exactly as macOS reviews it
  (`FlashArchive`, verified against the Swift oracle cases), imported as a flash bundle, planned
  with `job.plan` against the embedded catalog review, bound to the current loader when the plan
  asks, then submitted as reviewed and followed to its terminal Job and evidence. Wherever the
  Runtime refuses (no lane, no validator), the page shows its reason and offers no Flash button.
- **Trace (TASK-XPA-021).** The macOS Trace workspace: an adopted device (named from the device
  observation), a capture profile (the five presets and their tags) and a duration (seconds or
  minutes within the Catalog's range, with quick values), checked against the Runtime's probe of
  that device (`trace.probe`: the adapter, the nine debug parameters, the tags) and captured as
  one typed `capture.diagnostics@1` Job (`job.submit`, `job.run`, `job.cancel`). Start never
  shows disabled: while a capture cannot start, the first reason is the status line. The
  capture's one raw `trace.htrace` is read and verified (`artifact.read`, SHA-256) into the App's
  cache (`--cache-root`, by default `%TEMP%\ArkDeck`) and opened in the Trace viewer.
- **Trace viewer.** The macOS Trace Viewer window as a page: capture or open a Trace, the recent
  Traces (eight, a missing file shown inert), the timeline pane and the Inspector. Windows has
  no ArkTrace parser, so the timeline pane shows the macOS "bundled parser is unavailable" state
  and its diagnostics instead of a timeline; the Inspector shows the file's size and SHA-256 and,
  for a captured Trace, the Runtime's Trace inspector's answer (`trace.inspect`, refused on
  Windows today).
- **Viewer (TASK-XPA-020).** The macOS UI dump Viewer: capture the view of a Connected adopted
  device (`capture.diagnostics@1` with the UI dump preset), read and verify its same-Job
  screenshot, component tree and dump, and inspect them on the host (`UIDumpCapture`, checked
  against the Swift CLI's 19 oracle cases): the screenshot with the components' bounds and
  hit-testing, the complete tree (a list: arrows move, Left and Right collapse and expand), the
  search, the selected component's properties, layout, accessibility, raw fields and Advanced
  Dump (`componentDetail`), and the capture's timings.
- **Diagnostics (TASK-XPA-020).** The macOS Diagnostics session reader, opened on a History
  record (its Open Diagnostics, or Open Diagnostics beside another workspace's Open for a
  `capture.diagnostics@1` Job): a saved session read from its verified Artifacts and inspected on the host
  (`DiagnosticSession`, checked against the Swift CLI's 15 diagnostics-inspect oracle cases) —
  the alignment state, the marks and why a mark has no picture, what was never looked for, the
  missing products, the Artifacts with a bounded local text preview and the sensitive Trace
  opened in the Trace viewer — or a HiLog summary verified as macOS verifies it. No Diagnostic
  Session capture provider is composed, so Arm and Mark (Ctrl+M) say so with the macOS reason
  code `diagnostic_session_capture_not_connected`.
- **Remote build sources (TASK-XPA-020).** The macOS App-side SSH servers: Settings › Servers
  saves an SSH endpoint after a probe verifies the connection, the credential, the SFTP build root
  and the host key (its fingerprint shown, trusted only by saving that probe); Debug › Artifacts ›
  Remote server browses the folders below the verified root and chooses a lib*.so, which is
  fetched, checked and prepared like a local file. SSH runs through Windows' built-in OpenSSH
  client (`%SystemRoot%\System32\OpenSSH\ssh.exe`, argv only, `-F none`, the `sftp` subsystem)
  with a per-connection known-hosts file holding only the pinned key; secrets stay in Credential
  Manager (`ArkDeck/app/com.arkdeck.remote-build-source.v1/<id>`, in parts beyond 2,560 bytes) and
  reach the client only through the App's own askpass mode over an owner-only pipe. The files
  (`sources-v1.json`, `target-bindings-v1.json`, `audit-v1.jsonl`) are owner-only under
  `%LOCALAPPDATA%\ArkDeck\App\RemoteBuildSources`; no Runtime call is made.
- **History hand-off (TASK-XPA-020).** A History record's detail has the macOS Open button of the
  workspace that produced it (the Runtime's `workspaceKind`, else the operation or the capture's
  typed inputs): Trace (the record's Target pinned; a capture's raw Trace read, verified and opened
  in the Trace viewer), Viewer (the record's own screenshot, tree and dump read), Debug (its Target
  and the tab that ran it), Flash (its exact Target, any plan invalidated; a Target no longer
  adopted is said to be missing), Device (its Target selected) and Diagnostics. The workspace shows
  the record's read-only context (Job, Target, operation, state, Artifacts) until dismissed;
  nothing is submitted or replayed.
- **Overview scope (TASK-XPA-020).** The macOS Overview device bar: the adopted device online now
  (an authorized, current observation with an adopted Target) that the page describes — its name,
  Target, binding, system and transport, a picker when several are online, "No online device"
  otherwise — and the remote build server bound to that Target from the App's own bindings
  (unbound, bound with its endpoint, or stale when the server was removed).
- **Keyboard and assistive technology.** Every action is a Tab stop in reading order (lists of
  rows with their own buttons are `SemanticList`s, which Tab walks row by row); navigation items
  have access keys (Alt+O, D, H, N, A, I, B, F, T, R, V, G, S); rows of facts and actions wrap (`FlowPanel`, a grid for
  label and value) instead of running past the page at large text sizes; no host control is an
  empty Tab stop.

## Build and test

.NET SDK 10.0.401 (`global.json`), MSTest 4.4.1 (`Directory.Packages.props`). On the reference
host the NuGet cache is `D:\nuget\packages` (`NUGET_PACKAGES`). From the repository root:

```sh
python windows/scripts/generate-clientkit.py --check   # --write after a contract input changed
python windows/scripts/generate-ui-strings.py --check  # --write after spec/ui-semantics/strings.json changed
python windows/scripts/generate-xaml-tokens.py --check # (no flag) rewrites after tokens.css changed
python windows/scripts/generate-app-icons.py --check   # (no flag) rewrites after the macOS AppIcon changed
dotnet build windows/ArkDeck.Windows.slnx -c Release
dotnet test windows/ArkDeck.Windows.slnx -c Release --no-build
```

The App's UIA tests drive the built App (`App/bin/Release/.../ArkDeck.exe`, or
`ARKDECK_APP_EXE`) and need a desktop session: `ARKDECK_APP_UITESTS=1 dotnet test
windows/App.UITests -c Release --no-build`. Their real-daemon test also needs what the ClientKit
end-to-end test needs (below); `ARKDECK_UI_SNAPSHOT_DIR` keeps each language's observed
snapshot as JSON.

`EndToEndTests` runs `health` and `doctor` against a copy of the Rust daemon signed with the
host-trusted development certificate (`rust/scripts/windows-dev-identity.ps1`). It needs
`ARKDECK_DEV_SIGNER_THUMBPRINT` (environment or `HKCU\Environment`), PowerShell 7 and a daemon at
`ARKDECK_CLIENTKIT_DAEMON` or `rust/target/debug/arkdeck-agentd.exe`
(`cargo build -p arkdeck-agentd`); without them it reports itself skipped.

## Release candidate package (TASK-XPA-022)

`windows/scripts/package-rc.ps1` (PowerShell 7) builds the Windows x64 release candidate of the
whole product from one recorded checkout (r12 decision 10, rulings 8, 12 and 17):

- the daemon and the CLI through `rust/scripts/windows-package-xcopy.ps1` (release build,
  signing, its own manifest) into `<out>\runtime`;
- the App published unpackaged (`WindowsPackageType=None`; self-contained Windows App SDK and
  .NET, ReadyToRun and trimmed), `ArkDeck.exe` signed like the runtime;
- the **xcopy form**: `arkdeck-rc-<version>-windows-x64-<revision>\` with the App, `arkdeck.exe`
  and `arkdeck-agentd.exe` side by side (the layout both clients default to), the runtime's
  code-sign helper bundle (`ArkDeckKit_ArkDeckWorkflows.bundle\`) beside the daemon, and
  `rc-manifest.json` (`arkdeck.windows-rc-package/1`: every file's size and SHA-256, the
  toolchains, the signer pin), zipped, with the manifest beside the zip carrying its SHA-256;
- the **MSIX form**: the same App with the signed daemon and CLI and the helper bundle at the
  package root
  (`ArkDeckRuntimeDirectory`), identity `CN=ArkDeck Development` (ruling 12) unless
  `-MsixPublisher` names the signing certificate's subject (the package is then built from a
  copy of `Package.appxmanifest` under `<out>\msix-manifest`, passed as `ArkDeckPackageManifest`;
  the tracked manifest is never rewritten), write virtualization off (ruling 8), unsigned unless
  `-MsixSignCommand` is given; its SHA-256 and the daemon's and CLI's inside it are in the
  manifest, and the helper inside it must be the runtime package's.

`-SigningMode none` (CI) signs nothing; `development` signs with the host-trusted development
certificate (`ARKDECK_DEV_SIGNER_THUMBPRINT`); `production` calls the maintainer's command
(`-ProductionSignCommand` / `ARKDECK_PRODUCTION_SIGN_COMMAND`, one call per file) for the daemon,
the CLI and `ArkDeck.exe`, and requires timestamps, one publisher identity (ruling 17) and a
clean checkout. That identity must be the one the clients pin, given by the maintainer:
`-ExpectedPublisherOrganization` and `-ExpectedPublisherEku` (else
`ARKDECK_DAEMON_PUBLISHER_ORGANIZATION` / `ARKDECK_DAEMON_PUBLISHER_EKU`, the CLI's own inputs;
the EKU is an Artifact Signing certificate profile `1.3.6.1.4.1.311.97.<profile>`, never the
Public Trust marker). Unless `-SkipMsix`, a production run also signs the MSIX:
`-MsixSignCommand` and `-MsixPublisher` are required and the publisher's `O=` must be the
expected organisation. Anything missing is refused before anything is built.
`-MsixSignCommand` / `ARKDECK_MSIX_SIGN_COMMAND` signs the MSIX, whose signer's subject must be
the manifest's `Publisher`. The scripts hold no credential; the commands obtain them from the
maintainer at run time. `-FeedBaseUri
https://…/` writes the App Installer feed `ArkDeck.appinstaller` from the MSIX this run built
(name, publisher, version and architecture read from its `AppxManifest.xml`). The package
version must rise with each published RC.

```powershell
pwsh windows/scripts/package-rc.ps1 -OutputDirectory D:\out\rc -SigningMode development -Smoke
```

`-Smoke` installs the zip into a new owner-only directory under the account's local application
data with a private development state root, checks every file against the manifest and every
executable's signer against the pin (a production RC: its timestamped signature against the
manifest's publisher identity, which then configures the CLI and the App), lets `arkdeck doctor` start the installed daemon (decision
11), runs the App's UIA smoke (`App.UITests` `InstalledRcTests`: the installed `ArkDeck.exe`
connects to that daemon and shows its doctor report, no recovery banner), runs doctor again,
and uninstalls with `uninstall-rc.ps1`: no process may run from the directory, no new entry
may appear in the local application data and `%LOCALAPPDATA%\ArkDeck` must be as it was. The
record is `smoke.json` beside the zip.

`windows/scripts/uninstall-rc.ps1 -InstallDirectory <dir>` uninstalls the xcopy form. It refuses
a directory without an RC manifest. It stops a daemon running from the directory with the
installation's own `bin\arkdeck.exe runtime service uninstall`, pinned to the installed image and
its signer (an active or unclosed Runtime Job, or any other refusal of the CLI, refuses the
uninstall; an unsigned image, which no CLI can prove, is asked through its own stop event), leaves
a daemon of another installation alone, refuses while the App or a CLI still runs from it, and
removes the directory.
`-PackageName <identity>` does the same for the MSIX with `Remove-AppxPackage` for this user.
The daemon's state (`%LOCALAPPDATA%\ArkDeck`: its state directory `Agentd`, the default Sessions
root `Sessions` and the Trace cache `Trace`; or a development root) and the signing credentials
stay, and are listed in the answer. The clean-host smoke is a maintainer runbook
(`openspec/changes/chg-2026-074-shared-rust-runtime-core/evidence/runs/TASK-XPA-022/windows-clean-host-smoke-runbook.md`). The workflow `.github/workflows/windows-rc.yml` builds the
unsigned RC on `main` and keeps it as the artifact `arkdeck-windows-rc-<revision>`; it uses no
secret.

## CI

`scripts/ci/plan.py` selects the `windows` lane for `windows/**` and for the generator's and tests'
inputs (method schemas, registry, baseline, recorded corpus, pattern vocabulary, the development
identity script). The hosted job `windows-clientkit` in `.github/workflows/swift-ci.yml` runs the
commands above on `windows-latest` and is required through the `swift` aggregate.
`plan.py --run-local` runs them on a Windows host; on any other host it reports the lane as not
runnable and exits non-zero after the other selected lanes ran.
