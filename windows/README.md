# ArkDeck for Windows

The Windows client of ArkDeck (CHG-2026-074, TASK-XPA-007). Windows 11 x64 only (r13). The client
holds no runtime semantics: everything it shows is a projection read from the local Rust daemon
(`arkdeck-agentd`) through **ArkDeck.ClientKit**.

| Path | What it is |
| --- | --- |
| `ClientKit/` | `ArkDeck.ClientKit` (.NET 10 class library): generated contract bindings, the embedded method schemas, the authenticated named-pipe transport and the connection semantics |
| `ClientKit.Tests/` | MSTest suite (`dotnet test`) |
| `scripts/generate-clientkit.py` | Generator of `ClientKit/Generated/ControlContract.g.cs`; `--check` fails on drift |
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

## Build and test

.NET SDK 10.0.401 (`global.json`), MSTest 4.4.1 (`Directory.Packages.props`). On the reference
host the NuGet cache is `D:\nuget\packages` (`NUGET_PACKAGES`). From the repository root:

```sh
python windows/scripts/generate-clientkit.py --check   # --write after a contract input changed
dotnet build windows/ArkDeck.Windows.slnx -c Release
dotnet test windows/ArkDeck.Windows.slnx -c Release --no-build
```

`EndToEndTests` runs `health` and `doctor` against a copy of the Rust daemon signed with the
host-trusted development certificate (`rust/scripts/windows-dev-identity.ps1`). It needs
`ARKDECK_DEV_SIGNER_THUMBPRINT` (environment or `HKCU\Environment`), PowerShell 7 and a daemon at
`ARKDECK_CLIENTKIT_DAEMON` or `rust/target/debug/arkdeck-agentd.exe`
(`cargo build -p arkdeck-agentd`); without them it reports itself skipped.

## CI

`scripts/ci/plan.py` selects the `windows` lane for `windows/**` and for the generator's and tests'
inputs (method schemas, registry, baseline, recorded corpus, pattern vocabulary, the development
identity script). The hosted job `windows-clientkit` in `.github/workflows/swift-ci.yml` runs the
three commands above on `windows-latest` and is required through the `swift` aggregate.
`plan.py --run-local` runs them on a Windows host; on any other host it reports the lane as not
runnable and exits non-zero after the other selected lanes ran.
