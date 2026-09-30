# TASK-XPA-007 — ArkDeck.ClientKit and the `windows` CI lane, 2026-09-30

- Task: TASK-XPA-007, client lane slice X1 (WM5 of `docs/design/cross-platform/windows-phase-agent-prompt.md`):
  the .NET ClientKit generated from `spec/control/methods/**`, its tests, and the planner's
  `windows` lane with its hosted job.
- Base: developed and measured on protected `main` at `f1df7913` (#2346), then rebased onto `main`
  at `84a44be1` (#2345), which brought SPK-4 (#2347, WinUI go, provisional), rulings 13–17 and the
  xcopy packaging slice (#2349); the checks below were rerun on the rebased head. This slice uses
  SPK-4's toolchain pins and its `windows/.gitignore` (it added the same bytes before the merge).
- Host: the Windows 11 x64 reference host (Windows 11 Pro 10.0.26200), non-elevated, .NET SDK
  10.0.401, MSTest 4.4.1, rustc/cargo 1.98.1 (for the daemon under test and the scratch oracles
  only). Nothing was installed beyond NuGet restores into `D:\nuget\packages`; no system setting
  was changed; the only processes started and stopped were the test daemon copies and the tools.

This is host evidence for the client library and its CI lane. It is not WinUI, platform or device
acceptance: no UI is part of this slice, and the daemon under test serves the read-only foundation.

## What was built

| Path | Content |
| --- | --- |
| `windows/scripts/generate-clientkit.py` | Generator with `--write`/`--check`. Inputs: `Packages/ArkDeckKit/Contracts/control-protocol.json`, `spec/control/methods/*.json`, `spec/baselines/swift-single-v1.json`, `rust/crates/arkdeck-contract/src/schema_patterns.json` — the inputs the Rust generator binds. Output `windows/ClientKit/Generated/ControlContract.g.cs`: protocol version, 4 MiB/8 MiB limits, contract identity (SHA-256 of the sorted compact registry, as `rust/scripts/generate-contract.py` computes it), the 105 methods in registry order, the SHA-256 of each method schema, the pattern vocabulary, and typed records for `health`, `doctor`, `operation.list`, `device.observations` with the Rust type names. It refuses schema vocabulary it cannot model (optional nullable members, unknown keywords) instead of guessing |
| `windows/ClientKit/` | `ArkDeck.ClientKit`, `net10.0-windows`, x64. `Json/`: a `serde_json::Value`-equivalent model, the strict parser (`strict_json`) and the canonical writer (`serde_json::to_vec`). `Contract/`: the Rust `framing.rs` functions (`encode_frame`, `decode_request`, `decode_response`, `validate_health`), the `schema.rs` validator port, the embedded schemas (verified against the generated digests, fail closed) and the typed-record helpers. `Transport/`: pipe endpoint rules and the default `\\.\pipe\arkdeck-agentd-<logon SID>`, the two-layer server authentication by P/Invoke, the pinned server process/image/namespace handles, the frame reader. `ControlClient` (the Rust `Client::connect_bounded` semantics), `ControlSession` (one connection per call, health first), `ControlFailure`/`RecoveryBanner` |
| `windows/ClientKit.Tests/` | MSTest, 32 tests (below) and `Fixtures/serde-json-vectors.json` |
| `windows/ArkDeck.Windows.slnx`, `Directory.Build.props`, `Directory.Packages.props`, `global.json`, `.gitignore`, `README.md` | Solution and pins (SDK 10.0.401 `latestPatch`, MSTest 4.4.1, central package management, warnings as errors, x64) |
| `scripts/ci/plan.py` | `windows` lane (below); `scripts/ci/test_plan.py` and `scripts/test_agent_pr_workflow.py` updated in the same change |
| `.github/workflows/swift-ci.yml` | Hosted job `windows-clientkit` on `windows-latest`, required through the `swift` aggregate |

### Server authentication (design §F.2, XPA-AC-6 client side)

Mirrors `arkdeck-platform/src/windows/{mod,identity}.rs` step for step: `CreateFileW` with
`GENERIC_READ | GENERIC_WRITE | READ_CONTROL`, no sharing, `FILE_FLAG_OVERLAPPED |
SECURITY_SQOS_PRESENT | SECURITY_IDENTIFICATION`; layer 1 `GetSecurityInfo(SE_KERNEL_OBJECT,
OWNER_SECURITY_INFORMATION)` owner SID equal to the process token's `TokenOwner`; layer 2
`GetNamedPipeServerProcessId`, `OpenProcess(PROCESS_QUERY_LIMITED_INFORMATION | SYNCHRONIZE)`,
`QueryFullProcessImageNameW`, canonicalization as Rust's `std::fs::canonicalize` does it, every
ancestor directory held without delete sharing, the image held with read-only sharing, same
canonical path and same `FILE_ID_INFO` as the installed daemon, then the MSIX package family or
`WinVerifyTrust` (generic verify v2, no UI, whole-chain revocation from cache, root excluded) with
the first signer's certificate DER hashing to the pin, liveness (not exited, same creation time),
and the server PID re-read unchanged. Every write re-checks liveness. Every refusal happens before
the first write and names "zero frames sent".

### Failure model the UI consumes

`ControlFailureKind.DaemonUnavailable` + `DaemonUnavailableReason` (`EndpointInvalid`,
`EndpointUnavailable`, `OwnerMismatch`, `InstanceMismatch`, `HealthExchangeFailed`,
`ContractMismatch`, `DeadlineExceeded`): no business frame was sent; `ControlFailure.Banner` is
the daemon-unavailable recovery banner (English source strings; the bilingual catalogue is a later
slice). `OutcomeUnknown`: a business frame was or may have been sent and no valid reply came; never
replayed. `Remote`: the daemon's wire error. `ConnectionUnusable`, `InvalidRequest` as in the Rust
client (`ConnectionUnusable`, and a local `Contract` refusal before any byte).

### `windows` lane

`classify_paths` selects `windows` for `windows/**`, `spec/control/methods/**`, the recorded
corpus `Packages/ArkDeckKit/Tests/ArkDeckContractTests/Fixtures/ControlFrames/**`, the registry,
the baseline, the pattern vocabulary and `rust/scripts/windows-dev-identity.ps1`, and in the
planner/workflow self-validation branch. `test_plan.py` loads the generator's `INPUTS` and asserts
each member (and a new file in each directory) selects the lane, as the rust lane's test does.
`--run-local` runs `generate-clientkit.py --check`, `dotnet build` and `dotnet test` of
`windows/ArkDeck.Windows.slnx` (Release); on a non-Windows host it prints that the lane is selected
but cannot run, runs the other lanes, then fails with "the windows lane is not runnable on this
host" (exit 1). The hosted job keeps repository bytes (`core.autocrlf false`), pins the SDK
through `actions/setup-dotnet@a98b5685…` (v6.0.0) with `windows/global.json`, then the same three
commands. The `swift` aggregate needs it with the same selected-or-skipped test as the other lanes;
`test_agent_pr_workflow.py` pins the new `needs` list, the job's tokens and their order, and eight
new mutation cases.

## T0 evidence: byte identity with the Rust client

1. **Request frames.** A scratch binary depending on `rust/crates/arkdeck-contract` at the base
   commit (serde_json 1.0.151 with `float_roundtrip`, the workspace pin) replayed the recorded
   corpus exactly as `corpus_parity.rs` does (`Request::new("corpus-<i>", method, params or {})`,
   `encode_frame`) plus the live preflight `Request::new("health", "health", None)`: 1,043 corpus
   frames + 1 health frame, 281,042 bytes, SHA-256
   `f78aebeb2240f5ced5aca0e5a5786a837c1f06d8b38f745ca5f30e2c00358281`. The same bytes were
   rebuilt independently by slicing each recorded row's raw `params` bytes: equal.
   `WireCorpusTests.EveryRecordedRequestEncodesToTheRecordedBytes` asserts ClientKit's
   `Wire.EncodeRequestFrame` equals the raw-slice frame for every row and pins the health frame;
   its logged total is the same 281,042 bytes and the same SHA-256.
2. **JSON parser and writer.** `Fixtures/serde-json-vectors.json`: 66 inputs (integer kinds and
   overflow, `-0`, float text in both notations with `e+`/`e-` exponents, escapes, surrogates,
   code-point member order, duplicate and escaped-duplicate keys, BOM, comments, trailing commas,
   invalid UTF-8, depth 127 accepted and 128 refused), each with the output recorded from the Rust
   crate (`strict_json` then `serde_json::to_vec`, or refused). ClientKit reproduces all 66. The
   oracle corrected one assumption before it could ship: serde_json writes `1e+16`, not `1e16`.

The scratch oracle is not committed (it would be Rust code outside the workspace's lock, deny and
vet policy); the fixture carries its provenance and a future corpus change is covered by the
raw-slice construction, which needs no oracle.

## Local targeted checks

| Check | Result |
| --- | --- |
| `python windows/scripts/generate-clientkit.py --check` | exit 0, "matches its inputs (105 methods)" |
| `dotnet build windows/ArkDeck.Windows.slnx -c Release` | exit 0, 0 warnings, 0 errors |
| `dotnet test windows/ArkDeck.Windows.slnx -c Release --no-build` | exit 0: 32 passed, 0 failed, 0 skipped (end-to-end included) |
| same, `ARKDECK_CLIENTKIT_DAEMON` pointing at a missing file | the end-to-end test reports skipped; exit 0 |
| `PYTHONUTF8=1 "$ARKDECK_PYTHON" -m unittest scripts/ci/test_plan.py scripts/test_agent_pr_workflow.py` | 66 tests, OK |
| `sh scripts/check-sdd.sh` | 0 errors, 0 warnings |
| `git diff --check` | clean |

The 32 tests: generator drift (`--check` from the test), registry identity recomputed with
ClientKit's own writer, embedded schema digests; frame limits (request 4 MiB and response limit
with the LF counted, missing delimiter, lost reply, bytes after a frame kept); response envelope
refusals (CR, wrong id, escaped duplicate `id`, extra member, non-boolean `ok`, `ok:true` with
`error`, `details:null`, empty or unknown code, unknown result member, invalid expected id,
over-limit); local request refusals (unknown/retired method, empty/control/long/unpaired-surrogate
id, empty method, wrong version, wrong identity); corpus request bytes (T0), corpus response replay
through the decoder and `validate_health`, typed-record round trip of every recorded value of the
four typed methods, closed records and required-null versus missing; the serde vectors; connection
semantics against a scripted peer (health first and once, health-only read, contract mismatch →
banner and zero business frames then unusable, failed health, lost reply never replayed, malformed
reply, wire error keeps the connection, malformed local request sends no byte, budget in the
preflight and in the business exchange); pipe authentication against in-process fake servers
(owner-SID mismatch, same-account impostor with another image, right image without signer or
package or with a wrong pin, no server, endpoint name rules and the default endpoint), each
asserting the fake server received 0 bytes; and the end-to-end test.

**End-to-end** (`EndToEndTests.HealthAndDoctorAgainstADevSignedDaemon`): `arkdeck-agentd.exe`
built with `cargo build -p arkdeck-agentd --locked` (the same bytes at both bases, SHA-256
`965bdcafe9ad512529b7205562e27015b63741e2b3cdd7293b5a06bd1638c0bd`), copied to a temporary
directory, signed there with the host-trusted development certificate named by
`ARKDECK_DEV_SIGNER_THUMBPRINT` via `rust/scripts/windows-dev-identity.ps1 sign` (as
`check-readonly.py`'s `signed_windows_matrix` does), started with only
`ARKDECK_ENDPOINT=\\.\pipe\arkdeck-clientkit-e2e-<guid>` (no inherited `ARKDECK_*`/`OHOS_HDC_*`).
ClientKit authenticated it through both layers with the copy's path and the returned pin, read
`health` (typed; status `ok`, this contract identity, all 105 methods) and `doctor {"deep":false}`
(typed; 10 findings, runtime protocol 1.0.0), then on one connection `doctor` and `operation.list`
after a single health. The same running daemon was refused (`InstanceMismatch`, no data) under a
wrong pin, and under the unsigned original's path. The daemon was killed and the directory removed. The test was run three times in a row on the rebased head (32/32 each).

## Limits and what is deferred

1. **Layer-1 test uses a substituted expected owner.** A non-elevated account cannot create a pipe
   owned by another SID, so `APipeOwnedByAnotherSidIsRefusedWithZeroFrames` passes a different
   expected owner to the internal connector overload against a pipe this account owns. The
   production path always uses the process token's owner; a foreign-account pipe on a real host
   needs a second account (maintainer).
2. **Client-started daemon (decision 11, #2344) is not in this slice.** ClientKit connects to a
   running daemon only; the start path (and the banner's "start" action) comes with the WinUI
   skeleton slice.
3. **Typed records** exist for the four methods the Rust contract types; the other 101 methods are
   `JsonValue` validated against their embedded schemas, as in the Rust client. The typed
   `job.submit` gate is a later slice.
4. **Only the bounded connection** (`Client::connect_bounded`, the one budget the CLI uses) is
   ported; the Rust per-IO-timeout `Client::connect` has no ClientKit twin.
5. **MSIX package-family identity** is implemented and exercised only negatively (an unpackaged
   server with a package family pin is refused); the packaged daemon is TASK-XPA-022.
6. **Banner strings** are the English source; the bilingual catalogue generator (`.resw` +
   `.xcstrings`) is a later TASK-XPA-007 deliverable.
7. **Hosted CI** skips the end-to-end test (no built daemon, no host-trusted signer on the runner).
8. **Ruling 17 (xcopy publisher-identity pin)** is not in ClientKit yet. ClientKit implements what
   the Rust client implements today — the package family and the signer certificate's SHA-256 (the
   development signer keeps that pin under ruling 17). The publisher-identity pin for the
   Artifact-Signing-signed xcopy daemon lands in its own TASK-XPA-002 slice on the Rust side;
   ClientKit follows it in the same form so the two stay T1-equal.

CI: to be recorded by the PR's hosted run (`windows-clientkit`, `swift` aggregate); not verified here.
