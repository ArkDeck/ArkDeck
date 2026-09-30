# TASK-XPA-021 — slice T4 run record: the offline Trace pieces on Windows (Windows 11 x64, 2026-09-30)

TASK-XPA-021 stays `blocked` in `tasks.md` (it depends on TASK-XPA-020; this slice does not change
its Status line). Base: protected main `ca880968` (#2350; written on `b20827ab`, rebased, and every
check below re-run after the rebase); no stack. Run on the maintainer's Windows
11 x64 reference host (native Windows, Git Bash). Nothing here is device evidence (POL-VERIFY-001,
POL-MODE-001): no HDC, board, elevation or system change, and no third-party binary downloaded or
added. No control schema, Catalog, command registry, CLI coverage or `openspec/platforms/**` change.

Scope per decision 5 (capture, inspect and export parity is the supported threshold, the viewer
later): the offline half — the ArkTrace distribution loader, `trace.inspect` and trace export —
without a device. Capture needs a registered Windows HDC tuple and is not touched.

## Finding: there is no Windows ArkTrace distribution

- The repository pins exactly one `trace_streamer`: `Packages/ArkDeckKit/ThirdParty/TraceStreamer/macx`,
  `"architecture": "arm64"`, built with Apple clang from smartperf_host `447a0a49` with an
  Apple-clang patch. There is no Windows artefact, recipe or provenance in the tree; design §L.2
  lists "`trace_streamer` Windows 构建可行性与许可证" as missing evidence, and design §C (the
  `AnalyzerProvider` row) already plans the trace analyzers on Windows as "defer（诚实 unavailable）".
  None is fabricated here.
- The loader's distribution contract is Apple-specific, not merely macOS-built:
  `ArkTraceDistributionTrustContract` pins a Developer ID team, signing identity, certificate SHA-1
  and the App's and helper's code directory hashes (`arktrace_trust.rs` → `static_code_holds`,
  `read_property_list`); the tree digest (`distribution_tree.rs`, Swift
  `ArkTraceDistributionTreeHasher`) hashes each file's POSIX mode in octal and requires owner/root
  ownership and no group/other write bits; the doctor probe runs the CLI at its canonical path inside
  the signed bundle. A Windows distribution therefore needs its own trust contract (e.g. Authenticode
  signer + file identity) and its own tree-digest spelling — a platform decision like ruling 11, and
  one that needs a Windows distribution to be measured against. Porting the loader's reads without
  that would load nothing real and could only be tested against invented distributions, which the
  task forbids. **The loader, trust checker and doctor probe stay macOS-only**, and Windows loads no
  distribution, pinned or not.

## What changes

- **The ArkTrace answer judges build on Windows** (`arkdeck-hoststore`). `arktrace_summary`
  (Swift `ArkTraceSummaryEnvelopeValidator`) and `arktrace_analysis` (Swift
  `ArkTraceAnalysisRequest` and `ArkTraceAnalysisEnvelopeValidator`) read nothing from the host;
  they were macOS-only only because they imported `ArkTraceContract` from the loader module and
  three JSON helpers (`integer_tokens`, `exact_keys`, `boolean`) from the doctor module, both
  macOS-only for their host primitives. Those five items move, unchanged, into a new portable
  `arktrace_envelope.rs` (with `integer`, which the doctor's envelope check uses, and the
  `integer_tokens` unit test). `arktrace_profile` re-exports `ArkTraceContract` under its old path,
  so `job_plan`, `job_run`, `analyzer_output` and the public `arkdeck_hoststore::ArkTraceContract`
  are unchanged on macOS. The three modules are `cfg(any(target_os = "macos", windows))` with the
  crate's usual `cfg_attr(not(target_os = "macos"), allow(dead_code))` (no Windows consumer yet:
  the Job owner that runs analyzers is still macOS-only). `session_json::parse_foundation` (Swift
  `JSONValue` decoding, used by the analysis judge) is widened the same way; it was gated only
  because every caller was.
- **A Windows process test of the offline Trace surface** (`arkdeck-agentd/tests/windows_trace_offline_process.rs`),
  against the real daemon over an isolated development root, raw pipe handle as in the lifecycle
  test (the client's identity check is not what this proves and is not relaxed).

No production code path of the Windows daemon changes: it already answers each method below with
the owner-absent default; this slice measures that answer end to end and records it.

## Parity

| Surface | Windows answer (measured) | macOS | Tier |
| --- | --- | --- | --- |
| `trace.inspect`, the 7 recorded requests of `rust/tests/fixtures/trace-inspect-unavailable` (Swift `TraceInspectOracleContractTests`) and 3 schema-invalid ones | `operationUnavailable`, "Trace inspection is unavailable", `{phase: traceInspectionOwner, newDispatchCount: 0, deviceEvidenceCreated: false}` for every one | Swift's daemon without a Trace inspector: the same bytes (the oracle). The Rust macOS daemon composes no inspector either and answers the same (`arkdeck-control` default, `tests/read_only.rs`) | T0 wire bytes |
| `trace.cache.status`, `trace.cache.purge` | `rejected`, no details, nothing removed | Rust macOS without the cache owner: `rejected`, no details; the status message there reads "Trace cache maintenance is not configured", the control default "Trace cache owner is not configured" | T1 (code, details); message T2 |
| `operation.list`: `analyzer.summarize-trace@1`, `analyzer.analyze-trace@1` | `unavailable`, `reasonCodes: [provider_not_registered]`, `reasonOrigins: [product_build]` | a daemon with the planning owner and no descriptor: `analyzer.arktraceNotFound`; without the planning owner: `provider_not_registered` | T1 with the macOS daemon without its planning owner (the Windows daemon composes no Job/planning owner yet) |
| a development root naming `ARKDECK_ARKTRACE_DESCRIPTOR` | start refused, "ARKDECK_ARKTRACE_DESCRIPTOR is not composed by the Windows development root yet; nothing was started", non-zero exit, nothing created in the root, the named file not read | macOS loads it and, if it does not load, names both analyzers unavailable for the loader's reason | fail closed (the refusal predates this slice, `windows_lifecycle::NOT_COMPOSED`; now also measured through the process) |
| ArkTrace summary judge: 95 envelopes (`arktrace-summary-validator`) | Swift's verdict for every one | same test on macOS | T1 (verdicts) |
| ArkTrace analysis judge: 176 edits of the reviewed envelopes, 49 requests (`arktrace-analysis-validator`) | Swift's verdict, arguments, deadline, recovery digest and range for every one | same tests on macOS | T1; the recovery digest is T0 |

The viewer is not built (decision 5); the CLI shows `trace inspect` as the daemon's
`operationUnavailable` refusal, which the CLI's recorded failure fixtures already cover on Windows
(`arkdeck-cli/tests/trace_inspect.rs`, host-independent part). The Windows client has no Trace
surface yet (TASK-XPA-020).

## Not in this slice, and why

- **Trace export.** `arkdeck trace export` is `artifact.export` over the Artifact read and export
  owners; their Windows port is PR #2356 (TASK-XPA-006), still open at this base. Left to a follow-up
  once it merges; nothing here depends on it.
- **Trace cache status/purge owners.** Not only a missing host-store primitive: the cache is the
  App's (`~/Library/Containers/com.arkdeck.desktop/.../Trace/traces` on macOS), and no Windows App
  or location for it exists yet; removal needs `host_trace_removal` (not ported, #2338 lists it as
  macOS-only); and purge asks the Job owner (`JobStore::with_active_sessions`) and the Artifact
  owner's Trace retention, both macOS-only. The honest owner-absent refusal stays.
- **`trace.inspect` with an inspector, and the ArkTrace analyzers.** Need a Windows distribution
  (above) and, for the analyzers, the Job/planning owner on Windows.
- **Capture** (`capture.diagnostics@1` trace steps): needs a registered Windows HDC tuple; untouched,
  its structured refusal unchanged.
- **The account daemon and a descriptor.** Only the development root refuses
  `ARKDECK_ARKTRACE_DESCRIPTOR`; the account daemon (decision 11's) composes no analyzer and does not
  read it, as the macOS standalone foundation does not. Its analyzers still answer
  `provider_not_registered`. Not changed here: refusing it would change every NOT_COMPOSED input for
  the client-started daemon, a TASK-XPA-002 lifecycle decision.

CLI coverage: unchanged. `trace.inspect`, `trace.cache.status|purge`, `trace.probe` and both
ArkTrace analyzers stay `partial` on Windows (ruling 9: the CLI serves them, the Windows daemon's
owner is absent); `cli-feature-coverage.json` and the maintainer-contracts oracle are not
regenerated.

## For the maintainer (a decision this task needs before its inspect/analyzer half can close)

Windows ArkTrace distribution: (a) the source of a Windows `trace_streamer` (upstream smartperf
Windows artefact, or an in-repo recipe with provenance and the licence inventory extended); (b) its
trust contract (proposal: Authenticode signer pinned as ruling 17 pins the development daemon, plus
the file identity of every pinned file through `VerifiedTool`); (c) the tree-digest spelling on NTFS,
which cannot carry POSIX modes (proposal: the same records with a fixed executable marker from the
manifest instead of a mode, never equal to a macOS digest). Until then the Windows answer is the
typed `unavailable` above.

## Local targeted checks (Windows 11 x64, rustc 1.98.1, `CARGO_TARGET_DIR=D:\cargo-target\t4-trace`, `CARGO_BUILD_JOBS=2`)

| Command | Exit |
| --- | --- |
| `cargo fmt --all --check` | 0 |
| `cargo clippy --workspace --all-targets -- -D warnings` | 0 |
| `cargo test -p arkdeck-hoststore -p arkdeck-agentd` (includes `arktrace_envelope`, `arktrace_summary`, `arktrace_analysis` unit tests: 4 passed; `windows_trace_offline_process`: 2 passed; `windows_lifecycle_process` 3, `windows_client_start_process` 3) | 0 |
| `sh scripts/check-sdd.sh` (`PYTHONUTF8=1`) | 0 |
| `git diff --check` | 0 |

No test sleeps for synchronisation: the daemon test waits on the daemon's own announcement lines,
its stop line and its exit, each bounded by a 60 s deadline.

macOS and ubuntu cannot be built on this host. cfg pairings re-read: the widened predicates are
`any(target_os = "macos", windows)`, so Linux compiles exactly what it compiled before; on macOS the
moved items keep their bodies and names, `arktrace_doctor` imports them from `arktrace_envelope`, and
`crate::arktrace_profile::ArkTraceContract` is a re-export, so every macOS path resolves as before;
the `cfg_attr` dead-code allowances are inert on macOS. `Cargo.lock` is unchanged. The CI macOS and
ubuntu lanes decide.

## CI

To be recorded by the next slice (the PR number and run are not known when this is written).
