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
  authentication and every read and write share one time budget.
- **Server authentication (design §F.2), before any byte is written.** The pipe is opened with
  `SECURITY_SQOS_PRESENT | SECURITY_IDENTIFICATION`. Layer 1: the pipe object's owner SID must equal
  this process token's owner SID. Layer 2: the connection's server PID is opened and held, its image
  must be the installed daemon (canonical path and file id), signed by the pinned Authenticode
  signer (SHA-256 of the certificate DER) or running in the installed MSIX package family, and the
  PID must not change; the image file and its ancestor directories are held for the connection.
- **Failures are typed.** `ControlFailureKind.DaemonUnavailable` (with a `DaemonUnavailableReason`)
  means nothing ran; the UI shows `ControlFailure.Banner`, the daemon-unavailable recovery banner,
  instead of any data. `OutcomeUnknown` means a business frame may have been processed; read the
  state back instead of retrying.

`ControlSession` is the entry point for UI code: one authenticated connection per call, `health`
first, `ControlResult` back.

## ArkDeck (the App)

- **Data only through ClientKit.** `App.Core` reads `health`, `doctor`, `device.observations`,
  `job.list`, `job.status` and `job.events` — one authenticated connection per call, health
  first — and keeps each answer as it came: the data, or `unavailable(reasonCode): detail` with
  the CLI command that reads the same thing (the daemon's wire code, e.g.
  `unavailable(rejected): hdc.notConfigured`, or `daemonUnavailable` when nothing answered). It
  writes nothing to the daemon.
- **Which daemon.** The installation inputs the CLI reads: `ARKDECK_DAEMON_PATH` (default
  `arkdeck-agentd.exe` beside the App), `ARKDECK_DAEMON_SIGNER_SHA256` or
  `ARKDECK_DAEMON_PACKAGE_FAMILY`, optional `ARKDECK_ENDPOINT`. Without a pin there is nothing
  to verify, so the App connects to nothing and shows the recovery banner. The App does not
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
  `foundation`, `recovers`, `outage`, `jobs`) so the UIA tests can show states the real daemon
  cannot be made to show on demand. ClientKit still decodes and schema-checks every reply; the
  window shows a "Test transport" banner.

## Build and test

.NET SDK 10.0.401 (`global.json`), MSTest 4.4.1 (`Directory.Packages.props`). On the reference
host the NuGet cache is `D:\nuget\packages` (`NUGET_PACKAGES`). From the repository root:

```sh
python windows/scripts/generate-clientkit.py --check   # --write after a contract input changed
python windows/scripts/generate-ui-strings.py --check  # --write after spec/ui-semantics/strings.json changed
python windows/scripts/generate-xaml-tokens.py --check # (no flag) rewrites after tokens.css changed
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

## CI

`scripts/ci/plan.py` selects the `windows` lane for `windows/**` and for the generator's and tests'
inputs (method schemas, registry, baseline, recorded corpus, pattern vocabulary, the development
identity script). The hosted job `windows-clientkit` in `.github/workflows/swift-ci.yml` runs the
commands above on `windows-latest` and is required through the `swift` aggregate.
`plan.py --run-local` runs them on a Windows host; on any other host it reports the lane as not
runnable and exits non-zero after the other selected lanes ran.
