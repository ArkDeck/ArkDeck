# Windows gate inventory: the macOS and Unix gates between the Rust Runtime and Windows (2026-09-30)

- Task: TASK-XPA-004 (input to WM1: TASK-XPA-004 → TASK-XPA-005 → TASK-XPA-006)
- Base: protected `main` `2df7675d` (r12 of CHG-2026-074, #2327).
- Kind: analysis only. No Rust source, task status, proposal, design or verification text changes.
- Inputs: `docs/design/cross-platform/windows-phase-agent-prompt.md` §2.1 and WM1;
  `openspec/platforms/windows/profile.md` (Expected Port mapping, Forbidden Windows exceptions);
  design §D.2 and §E; `tasks.md` TASK-XPA-004/005/006; the headless runbook §2 (GJ-1);
  the SPK-5 NTFS facts measured on the Windows 11 x64 reference host today (their run
  record is filed separately; this note only uses them).

## Summary

**Scope.** Every `cfg(...)` / `cfg!(...)` predicate under `rust/crates/**/*.rs` (src, tests,
examples) that names `target_os = "macos"` or `unix`, including the `not(...)` fallback arms.
Reproduce with:

```sh
grep -rEn 'cfg!?[[:space:]]*\(' rust/crates --include=*.rs \
  | grep -E 'cfg!?[[:space:]]*\(.*(target_os *= *"macos"|\bunix\b)' | wc -l   # 1107
```

**Totals: 1107 gate lines in 261 files** (800 in production modules, 307 in test targets,
`#[cfg(test)]`/`all(test, …)` modules and examples).

| Class | Meaning | Gate lines | Share |
| --- | --- | ---: | ---: |
| (a) Apple API | CoreFoundation, Security (`SecStaticCode`, `SecItem`, LocalAuthentication), IOKit, libproc/`sysctl`, launchd, Mach/XPC, Foundation HTTP, Apple Compression, `/.vol`, `F_FULLFSYNC`, `renameatx_np`/`renamex_np`, `confstr(_CS_DARWIN_USER_TEMP_DIR)`, the system `libsqlite3`; also consumers of an Apple-only product surface that has no shared port (LaunchAgent service, runtime update feed, Keychain signing, Mach App ingress, `~/Library` layout) | 218 | 20 % |
| (b) POSIX semantics | `openat`/dirfd, `flock`, `O_NOFOLLOW`, uid/euid and mode bits, `getpwuid_r`, `posix_spawn` + process groups + signals, `openpty`, UDS `getpeereid`, `renameat` | 131 | 12 % |
| (c) no platform reason of its own | (c-inh) the module has no OS code but consumes a gated `arkdeck-platform` primitive, so it becomes buildable when that primitive gets a Windows implementation: 740; (c-pure) nothing platform-specific at all, only never built elsewhere: 18 | 758 | 68 % |

What the numbers say:

1. Two thirds of the gates (c) are Runtime semantics that have no platform code. They sit behind
   about a dozen primitive groups in `arkdeck-platform` (§3). WM1 should not remove them one by one.
   It should port the primitive, then drop the consumer gates of one GJ hop together with their
   test-file gates (`#![cfg(target_os = "macos")]` covers all 87 `arkdeck-hoststore` test files and
   all 22 `arkdeck-agentd` test targets).
2. The (a)/(b) gates that GJ-1 has to remove first, each with its Windows replacement:

   | # | Group | Windows primitive | In `arkdeck-platform` today |
   | --- | --- | --- | --- |
   | 1 | G01 durable host store (`HostDirectory`, `HostReadLock`, publish/replace, append, journal) + G09 account/state root | `LockFileEx` on the existing separate lock files; POSIX-semantics `SetFileInformationByHandle(FileRenameInfoEx)` replace; `FlushFileBuffers` on the file and on a `GENERIC_WRITE` directory handle; `FileIdInfo` identity; owner-SID/DACL checks in place of uid/mode; `SHGetKnownFolderPath(FOLDERID_LocalAppData)` | partly: `windows::file_identity` (FileIdInfo), `reject_reparse_file`, `lock_namespace` (`src/windows/identity.rs:26,43,58`) |
   | 2 | G03/G04 host text and calendar (CoreFoundation) | portable Rust tables pinned to the macOS Foundation behaviour and proved against recorded vectors, as `session_graphemes.rs` already does for Swift grapheme breaks; **not** Win32 NLS | no |
   | 3 | G02 SQLite (`#[link(name = "sqlite3")]`) | SQLite built from source with the crate (design §E.2 names `rusqlite` bundled), same pinned `user_version` layout | no |
   | 4 | G05 USB census (IOKit) | SetupAPI/CfgMgr32 read-only census of the DAYU200 HDC interface (serial, VID/PID, location path, device instance) feeding `UsbRegistryRelations::new` | no |
   | 5 | G06/G07 tool dispatch and managed HDC server proof (`posix_spawn` + process groups, libproc/`sysctl`) | `CreateProcessW` with an argv array inside a kill-on-close Job object, handle-held executable and namespace; server proof from `GetExtendedTcpTable` + process image + start time | partly: `windows::spawn` (Job object), `VerifiedTool` (FileIdInfo + held namespace), `LoopbackServerLease` (`src/windows/process.rs:215,265`, `src/windows/server.rs:14-53`); missing `ToolRequest`/`ToolExecution`, `ManagedServer`, `ServerIdentityReceipt` |

   G10 (serving loop, stop and drain) and G17a (HDC tool registry) come right after, because the
   GJ-1 restart hop and the registered Windows HDC tuple need them (§5).
3. **State directory and single instance (proposal, §6).** State root
   `%LOCALAPPDATA%\ArkDeck\Agentd`, resolved through the Known Folder API rather than the
   environment. It is held by the same `instance.lock` file (`LockFileEx`) plus a per-user named
   mutex `Global\ArkDeck.Agentd.<user SID>` held by the main thread. `WAIT_ABANDONED` is treated as
   a crashed predecessor and goes through the normal recovery start. The pipe keeps
   `FILE_FLAG_FIRST_PIPE_INSTANCE`.
4. Findings that change how WM1 is planned (details in §4–§7):
   - Without a USB census the Runtime composes `NoUsbRelations`. Then "no candidate is ever
     proved and no adoption can pass" (`arkdeck-provider-hdc/src/target_observation.rs:120-124`,
     `arkdeck-agentd/src/host.rs:1245`). G05 is on the critical path of hop 4. It is not optional.
   - The Bootstrap registry's timestamp check returns `false` off macOS
     (`arkdeck-bootstrap/src/registry.rs:20-29`). A registered Windows HDC tuple would decode as
     invalid until G04 is ported. That is safe (it fails closed) but blocking.
   - `job.submit` is refused unless `planning` holds `AnalyzerProfiles`
     (`arkdeck-agentd/src/host.rs:1802-1823`). Those profiles are built from ArkTrace
     trust (`static_code_holds`, `read_property_list`: Apple). On Windows they must compose as
     *honestly absent* (design §E.2 defers the trace analyzers), or observe/capture can never be admitted.
   - The CLI has non-macOS fallback arms that silently use Rust's own Unicode predicates
     (`arkdeck-cli/src/target_resources.rs:37-40`, `domain_leaves.rs:358`,
     `trace_inspect.rs:382`, `machine_contracts.rs:319-323`). That is a T1 divergence waiting to
     happen. They should switch to the same portable tables as G03, not survive WM1.
   - `runtime service restart` and `runtime service verify`, both GJ-1 steps, are LaunchAgent-only
     (`arkdeck-cli/src/main.rs:1036-1074`, `lib.rs:89-94`). Windows needs the decision-11
     equivalent (client autostart + single instance) named in WM1 before the restart-readback hop
     can be run.
   - The Windows serving loop cannot stop: `accept` has no latch and the loop ends in
     `unreachable!("only a stop request ends accepting")` (`arkdeck-agentd/src/lib.rs:95-105`).
     The XPA-005 kill matrix and the restart hop need a Windows stop source and drain (G10).
   - `HostReadLock::mark_catalog_initialized` writes a one-byte marker *into the lock file*
     (`arkdeck-platform/src/host_store.rs:143-165`, used by `job_repository.rs:498`). Under SPK-5's
     mandatory `LockFileEx`, lock a byte range beyond end-of-file so that the marker stays readable
     through other handles.

## 1. Classes and counting rules

- A gate is counted once per source line carrying the predicate. A `#[cfg(not(target_os = "macos"))]`
  fallback arm counts as its own line.
- (a) and (b) are about the code **in or directly behind** the gate. Example:
  `arkdeck-platform/src/host_journal.rs:294` calls `fcntl(F_FULLFSYNC)`, which is (a), even though the surrounding
  module is mostly (b). A group gets the class of its dominant reason, and mixed reasons are named in
  the group row.
- A consumer module whose only reason is a gated primitive is (c-inh). It is counted (a) instead
  when the consumer is itself an Apple-only product surface that Windows replaces with a different
  mechanism rather than a port (LaunchAgent service, update feed, Keychain signing, Mach ingress,
  the `~/Library` production layout).
- Group IDs: G01–G21 are primitive groups (the OS boundary, mostly `arkdeck-platform`),
  G30–G47 are consumer/owner groups.

## 2. Counts per crate and per file

| Crate | Production lines | Test-only lines | Largest files |
| --- | ---: | ---: | --- |
| `arkdeck-agentd` | 267 | 46 | `src/host.rs` 199, `src/main.rs` 67, `src/lib.rs` 19, `src/host_tests.rs` 4; 22 test targets gated whole-file |
| `arkdeck-hoststore` | 231 | 95 | `src/lib.rs` 205, `format_time.rs` 10, `session_json.rs` 5, `session_time.rs` 5; 87 of 87 test files gated whole-file |
| `arkdeck-platform` | 137 | 19 | `src/lib.rs` 75, `process.rs` 39, `tool_shim.rs` 8, `unix.rs` 6; 15 + 3 of 20 test files gated |
| `arkdeck-cli` | 104 | 118 | `runtime_update.rs` 30, `signing_leaves.rs` 16, `main.rs` 12, `import_resources.rs` 11, `support_bundle.rs` 9; 15 of 64 test files gated whole-file, plus `cfg!` option checks |
| `arkdeck-bootstrap` | 21 | 0 | `src/lib.rs` 19, `registry.rs` 2 |
| `arkdeck-provider-workspace` | 16 | 7 | `src/lib.rs` 11, `signing_preset.rs` 3 |
| `arkdeck-provider-hdc` | 14 | 13 | `src/lib.rs` 8, `capture_files.rs` 3, `dispatch.rs` 2; 13 of 15 test files gated |
| `arkdeck-provider-arkforge` | 4 | 6 | `src/lib.rs` 2, `authority_support.rs` 2 |
| `arkdeck-soak` | 3 | 1 | whole crate |
| `arkdeck-rockchip-binding` | 2 | 1 | `src/lib.rs` 2 |
| `arkdeck-contract` | 1 | 0 | `foundation_path.rs:79` (a test) |
| `arkdeck-client` | 0 | 1 | `tests/bounded.rs` (`#![cfg(unix)]`) |
| **Total** | **800** | **307** | 261 files |

`arkdeck-control` and the contract/client libraries carry no gates. They already build and pass
on the hosted `windows-latest` lane.

## 3. Primitive groups (the OS boundary)

"Has" = what `arkdeck-platform` already provides on Windows (`src/windows/`, `src/process.rs`).
GJ = the first Golden Journey that needs the group (§5).

| ID | Gated owner | Lines | Class | Why it is macOS-only (file:line in `rust/crates/arkdeck-platform/src` unless stated) | Windows primitive | Has | GJ |
| --- | --- | ---: | --- | --- | --- | --- | --- |
| G01 | Durable host store: `host_store` and its submodules `host_journal`, `host_session_publication`, `host_session_removal`, `host_import_upload`, `host_payload_verification`, `host_export`, `host_file_export`, `host_diagnostic_log`, `host_trace_removal`, `host_update_*` (`lib.rs:183-185`) | 5 | b (+a) | dirfd-relative `openat`/`unlinkat` with `O_NOFOLLOW` (`host_store.rs:422-425,474-484`); `flock` locks (`host_store.rs:492,1281,1320`, `host_journal.rs:53`); owner-euid and mode checks (`host_store.rs:208-215`); temp + `renameat` + directory `fsync` publish (`host_store.rs:608-720`); dev/ino link checks (`host_store.rs:169-176`); Apple spellings `F_FULLFSYNC` (`host_journal.rs:291-298`) and `renameatx_np(RENAME_EXCL)` (`host_journal.rs:174-181`) | Directory handle + `NtCreateFile`/`CreateFileW` relative opens with `FILE_FLAG_OPEN_REPARSE_POINT` and reparse refusal; `LockFileEx(LOCKFILE_EXCLUSIVE_LOCK \| FAIL_IMMEDIATELY)` on the **same separate lock files** (`.targets.lock`, `.manifest.lock`, `.rust-job-owner.lock`, `instance.lock` …; SPK-5: mandatory, refused for a second handle even in-process, released at once on kill); publish = temp file + `FlushFileBuffers` + `SetFileInformationByHandle(FileRenameInfoEx, POSIX_SEMANTICS \| REPLACE_IF_EXISTS)` + `FlushFileBuffers` on a `GENERIC_WRITE` directory handle (SPK-5: `MoveFileExW` fails with error 5 against any open holder; the POSIX rename succeeds when holders share delete, keeps their view, error 32 otherwise); `RENAME_EXCL` = the same call without `REPLACE_IF_EXISTS`; identity = `FileIdInfo` (stable across opens and in-place rewrite; a rename-replace carries the source id); uid/mode = owner SID equals token user + protected DACL; `F_FULLFSYNC` = `FlushFileBuffers` (append p95 ≈ 1 ms on NVMe; torn tails are byte prefixes, so the torn-tail matrix ports unchanged) | `file_identity`, `reject_reparse_file`, `lock_namespace` (`windows/identity.rs:26,43,58`) | GJ-1 hop 4 |
| G02 | `host_sqlite` (`lib.rs:196-198`) | 2 | a | links the OS `libsqlite3` (`host_sqlite.rs:9`), the library Swift used | SQLite compiled with the crate (`rusqlite` bundled or the amalgamation via `cc`); same `runtime_job` layout, exact `user_version` | no | GJ-1 hop 6 |
| G03 | Host text predicates and NFC (`host_text`, `lib.rs:201-203`); consumers `arkdeck-hoststore/src/lib.rs:470-503`, CLI `target_resources.rs:25-41`, `domain_leaves.rs:356-358`, `trace_inspect.rs:377-382` | 12 | a | `CFCharacterSet` / `CFStringNormalize` (`host_text.rs:1-11`); the hoststore comment forbids substituting another platform's tables (`arkdeck-hoststore/src/lib.rs:489-490`) | Portable Rust: generated tables for the Foundation character sets and NFC, pinned to the Unicode version of the recorded macOS owner, proved by corpora (precedent: `arkdeck-hoststore/src/session_graphemes.rs:1-8`). Not `IsCharAlphaNumericW`/`NormalizeString`, whose Unicode version follows the OS | no | GJ-1 hop 3 (display names) |
| G04 | Calendar and legacy date parsing (`host_calendar`, `host_date_formatter`, `lib.rs:218-227`); consumers `format_time.rs:142`, `session_time.rs`, `arkdeck-bootstrap/src/registry.rs:20-29` | 14 | a | `CFCalendar*`, `CFDateFormatter` (`host_calendar.rs:1-20`, `host_date_formatter.rs:5`) + objc autorelease pool | Pure Rust proleptic-Gregorian UTC arithmetic and the fixed legacy ISO-8601 grammar, proved against recorded Foundation vectors | no | GJ-1 hop 1 (registry decode) |
| G04p | `format_time.rs` pure helpers (`utc_precise_now`, `plain_utc_seconds`, …, `:232-309`) and `session_json.rs` Foundation-spelled JSON (`:229-287`, the `job-record.json` spelling) | 13 | c-pure | nothing: pure Rust over `arkdeck_contract::foundation_json`, gated only because its callers are | remove the gate | n/a | GJ-1 hop 6 |
| G05 | USB census (`usb_registry`, `lib.rs:343`); `UsbRegistryRelations::system` (`arkdeck-provider-hdc/src/target_observation.rs:177-182`) | 7 | a | IOKit `IOServiceGetMatchingServices` (`usb_registry.rs:128-146,167-170`) | SetupAPI/CfgMgr32 read-only enumeration (`CM_Get_Device_Interface_List`/`CM_Get_DevNode_PropertyW`: serial from the instance id, VID/PID, location path, a per-boot devnode identity as the attachment id). No open of the device, no driver install. Field choice waits for the WM0.5 DAYU200 USB-properties sample | no | GJ-1 hop 4 |
| G06 | Tool process and verified launch: `tool_process`, `verified_launch`, `macos_process`, `ToolLaunchIdentity`, `argument_zero`, shim check (`process.rs:50-117,707-775`); `ProcessDispatch` (`arkdeck-provider-hdc/src/lib.rs:13,49`, `dispatch.rs:54-77`) | 22 | b (+a) | `posix_spawn` in a new process group, TERM→KILL group termination (`tool_process.rs:1-9`, `macos_process.rs:461-476`); launch through the `/.vol/<dev>/<ino>` alias (`verified_launch.rs:175`, `macos_process.rs:746`: Apple) | `CreateProcessW` with the encoded argv array (never `cmd.exe`/PowerShell), `lpApplicationName` from the held file with the namespace held non-deletable, clean environment block + explicit overlay, `lpCurrentDirectory`, `NUL` stdin, kill-on-close Job object for group termination. There is no TERM on Windows, so the grace step becomes an immediate `TerminateJobObject` (record as T1 decision); launch identity = FileIdInfo + size + SHA-256 | `windows::spawn`, `VerifiedTool`, `run_read_only` (used by XPA-002 `device candidates`) | GJ-1 hop 6 |
| G07 | Managed server and server identity proof: `managed_server` (`process.rs:728,769`), `macos_server` (`lib.rs:92-94`), Unix placeholder `LoopbackServerLease` (`unix.rs:380-397`); consumers `arkdeck-provider-hdc` `lifecycle`, `managed_server`, `status` | 22 | a/b | `sysctl(KERN_PROCARGS2)` / `proc_pidinfo` socket ownership and argv reads (`macos_server.rs:247,493,631-670`), `verifies_managed_process` (`:526`) | Listener owner from `GetExtendedTcpTable(TCP_TABLE_OWNER_PID_LISTENER)`, image from `QueryFullProcessImageNameW`, birth from `GetProcessTimes`, stop = `TerminateProcess` on a handle whose identity was re-proved. **Open:** Windows offers no supported read of another process's argv, so `verifies_managed_process`'s argument check needs a Windows decision (e.g. prove only processes this daemon launched, by the Job object) | `LoopbackServerLease` (`windows/server.rs:14-53`), `process_started` (`windows/identity.rs:372`) | GJ-1 hop 1/6 (XPA-005 managed HDC) |
| G08 | Unix child termination inside the shared runner (`process.rs:363-704`) | 19 | b | `kill`/`waitpid`/EPERM proofs | already mirrored: `windows::process::RunningChild` (Job object) | yes | — (no action) |
| G09 | Account home and temp root: `account` (`lib.rs:27-32`), `temporary_directory` (`lib.rs:34-36`, `temporary_directory.rs:11-40`) | 8 | b/a | `getpwuid_r(getuid())`, `CFFIXED_USER_HOME`, `HOME` deliberately ignored (`account.rs:1-35`); `confstr(_CS_DARWIN_USER_TEMP_DIR)` (`temporary_directory.rs:3,24-40`: Apple) | `SHGetKnownFolderPath(FOLDERID_LocalAppData)` with the process token (not `%LOCALAPPDATA%` from the environment, mirroring the `HOME` rule); token user SID for "effective user"; `GetTempPath2W` for the receive root | no | GJ-1 hop 0 |
| G10 | Serving loop stop, drain and transport lock: `stop_signal`, `unix.rs` (`bind_facade`, `ListenerLock`, `accept_until`), `arkdeck-agentd/src/lib.rs:4-149`, `main.rs:274,745-829`, CLI `Interruption` (`arkdeck-cli/src/main.rs:690-718`), `arkdeck-client/tests/bounded.rs` | 42 | b | `sigaction` SIGTERM/SIGINT latch; directory `flock` of the transport directory (`unix.rs:151-182`); UDS peer uid (`unix.rs:69`) | Stop source: `SetConsoleCtrlHandler` + a per-instance named event; overlapped `ConnectNamedPipe` cancelled by the latch; drain keeps the single-instance guard until done (§6). Transport exclusivity is already `FILE_FLAG_FIRST_PIPE_INSTANCE` + logon-SID DACL | pipe `LocalListener`/`LocalConnection` (`windows/mod.rs:148-320`); no stop/drain | GJ-1 restart hop (XPA-005 kill matrix) |
| G11 | `random_bytes` unix arm (`lib.rs:147`) | 1 | b | `getentropy` | `BCryptGenRandom` | yes (`lib.rs:155-173`) | — |
| G12 | Code-signature inspection: `host_signature`, `static_code`, `host_bundle_signature` (`lib.rs:61-73,245-288`) | 6 | a | `SecStaticCodeCheckValidity` (`host_signature.rs:61`, `static_code.rs:46`) | `WinVerifyTrust` (Authenticode) + signer certificate SHA-256 pin; catalog signing for SDK tools (ToolTrustInspector) | partly: `verify_signature` for the pipe server (`windows/identity.rs:402`) | GJ-1 hop 1 (HDC registration, see G17a); bulk later |
| G13 | Credential storage and secret entry: `keychain`, `terminal_secret` (`lib.rs:39-56`); `arkdeck-provider-workspace` `credential_owner`, `keychain_secrets`, `signing_*`, `signer`; CLI `signing_leaves`, `signing_inputs` | 39 | a | `SecItemCopyMatching`, LocalAuthentication (`keychain.rs:120-177`); `openpty` echo-off entry (`terminal_secret.rs:128`) | Credential Manager (`CredWriteW`/`CredReadW`, DPAPI-protected, per design §E.2); presence via the HAR console challenge; console entry via `SetConsoleMode` without `ENABLE_ECHO_INPUT` | no | GJ-5 |
| G14 | Update feed and HTTP: `host_url`, `update_http`, `host_url_properties`; CLI `runtime_update`, `update_feed` | 44 | a | Foundation/AppKit/`NSURLSession` (`update_http.rs:32`, `host_url.rs:29,110`) | App Installer per decision 10; not a port | no | WM6 (not GJ) |
| G15 | Property lists and DevEco resources (`property_list`, `host_deveco_resources`, `host_deveco_files`) | 6 | a | `CFPropertyList*` | pure-Rust plist only if Windows DevEco ships plists; confirm with the WM3 install-shape crib | no | GJ-5 |
| G16 | Apple-only service and ingress: `launchd`, `macos_control` (`listen_mach`, `PeerOrigin`), CLI `runtime_service*` (`lib.rs:89-94`, `main.rs:1036-1190`), `--socket` (`lib.rs:714`), `foreground_console` (`arkdeck-agentd/src/lib.rs:151-157`); test `cfg!` checks of `macosCompatibilityOption` | 41 | a | launchctl, Mach service + code-signing requirement, audit-token peer origin | not ported. Windows: client autostart + single instance (decision 11); App on the same pipe; console origin from `GetNamedPipeClientProcessId` + `ProcessIdToSessionId` when the HAR console challenge reaches Windows | pipe transport yes | GJ-1 restart/verify hops need the Windows substitute (§5) |
| G17a | HDC tool registry: `host_bootstrap_tree`, `bootstrap_tool_capture` (`lib.rs:230-243`), `tool_shim`; `arkdeck-bootstrap` `tool_content`, `tool_macho`, `tool_registration`, `tool_registry_owner`, `tool_retirement`, `tool_selection_ledger`; hoststore `tool_selection`, `tool_list_owner`, `tool_retirement`; agentd `bootstrap_readers`, `tool_selection_startup` | 48 | c-inh (+a +b) | Mach-O dependency inspection (`arkdeck-bootstrap/src/tool_macho.rs:103,168`) and `SecStaticCode` content identity; Xcode shim detection (`tool_shim.rs:112,239`); capture via `openat`/`renameatx_np` | PE import inspection + Authenticode (G12) for the Windows HDC tuple; capture on G01 primitives; the shim check has no Windows counterpart (absent by construction). The tuple itself comes from the Windows HDC integration change | no | GJ-1 hop 1 |
| G17b | Bundle registry: `bootstrap_bundle_capture`, `distribution_tree`, `helper_replace`; `arkdeck-bootstrap` `bundle_*`, `store`; hoststore `bundle_list_owner` | 21 | c-inh (+a) | `CFBundleShortVersionString`, `F_FULLFSYNC`, `renamex_np(RENAME_SWAP)` (`helper_replace.rs:5,50`) | ArkForge bundle per AF-W1; swap = two POSIX renames under the registry lock (no atomic swap on NTFS; record as decision) | no | GJ-4 |
| G18 | `host_inflate` (`lib.rs:213-215`) | 2 | a | Apple Compression `COMPRESSION_ZLIB` (`host_inflate.rs:1-5,27`) | pure-Rust raw DEFLATE with the same 1 MiB output windows | no | GJ-4 |
| G19 | PTY exchange and persistent shell channel (`process.rs:712-720`) | 6 | b | `openpty`/`fork` (`macos_process.rs:770`) | ConPTY (`CreatePseudoConsole`), secrets never in argv/env (design §E.2) | no | GJ-2/3/5 |
| G20 | Analyzer runner and profile readers: `analyzer_process`, `owner_file`, `tree_snapshot`, `profile_file_reader`; hoststore `analyzer_composition`, `arktrace_*`, `crash_ledger`, `hilog_summary`; agentd analyzer modes | 38 | c-inh (+b) | ArkTrace trust needs `static_code_holds`/`read_property_list` (G12/G15); readers use `openat`/`O_NOFOLLOW` | Windows composes the trace analyzers as honestly unavailable (design §E.2); the pure hilog/crash computations move with GJ-2/GJ-5. **GJ-1 needs `AnalyzerProfiles` to compose "absent"** so that `job.submit` is reachable | no | GJ-1 hop 5 (composition only) |
| G21 | Soak and benchmark tooling: `self_resources`, `continuous_clock`, `autorelease_pool`, `arkdeck-soak` | 9 | b/a/c | `getrusage`, `CLOCK_MONOTONIC`, objc pools | ElapsedDeadlineClock = `QueryInterruptTime`/`GetTickCount64` when soak comes to Windows | no | — |

## 4. Consumer groups (Runtime owners behind the primitives)

All of these are (c-inh) unless noted. "Residue" lists direct POSIX use that still needs a small
Windows arm once the primitive exists.

| ID | Owner | Lines | Blocked by | Residue | GJ hop |
| --- | --- | ---: | --- | --- | --- |
| G30 | Targets and observation: hoststore `target_document`, `target_owner`, `target_observation` (`lib.rs:337-349`); agentd `observe`, `observing`, `target_adopt`, `target_resource`, `candidate_display_name`, USB relations (`host.rs:18,96,163-175,236,384-436,1369-1384,2987-3115`) | 43 | G01, G03, G05, G06 | — | 2–4 (candidates, adopt, show) |
| G31 | Jobs, admission, journal, capability, recovery: hoststore `job_*`, `recovery_epoch`, `mutation_execution`, `operation_availability`, `operation_request`, `capability_*`, `strict_json`, `swift_decoding`, `cutover_facts`, `device_lane`, `device_run`, `device_steps`, `device_facts`, `capture_documents` (`lib.rs:61-284,333`); agentd `RunSlot`, `job_*`, `recover_active_jobs`, doctor store facts (`host.rs:44-72,100-136,241-324,534,606,1278,1764-2150,2870-2930`, `main.rs:669`) | 131 | G01, G02, G04p, G06, G07, G20 (composition) | `job_repository.rs:453,504,519` (mode `0600`, dev/ino of the database → FileIdInfo); `capability_store.rs:238` (`0700`) | 5–6, 9 (submit, run, result, restart readback) |
| G32 | Artifacts: `artifact_publication`, `artifact_quota`, `artifact_usage`, `artifact_read_owner`, `artifact_projection`, `artifact_resources`, `artifact_export`; agentd artifact resources, `receive_root` (`host.rs:30,98,145,333,341,771,1227,1490,1967`) | 34 | G01, G09 (temp root) | `artifact_publication.rs:97,121` (`O_NOFOLLOW`, dev/ino), `artifact_quota.rs:253` | 7–8 (artifact list/read/export) |
| G33 | Agent executions and HAR: `agent_execution`, `human_action`; agentd `start_agent_run`, `agent_execution`, `human_action`, `interactive_human_action_resume` | 37 | G31, G30 | CLI `main.rs:882` console challenge is `cfg!(macos)`-gated but pure (c-pure) | 5 and §2.1 crash-resume |
| G41 | Managed and development HDC composition, isolated development root: agentd `managed_hdc`, `DevelopmentHdc`, `MeasuredHdc`, `development_admission`, `development_mutation`, `development_usb`, isolated root (`main.rs:33-46,74-160,249-330,660-662,792-815`; `host.rs:139-156,351-377,573-592,2851-2942`) | 35 | G06, G07, G01, G09, G05 | root lock is the directory `flock` of `bind_facade` (see §6) | 0 (dev composition), 1 (managed HDC) |
| G42 | Production composition, App ingress, cutover preflight: `production.rs` (`~/Library/Application Support/ArkDeck/Agentd`, `instance.lock` + `bind_facade`, `production.rs:64-68,211-251,326-360`), `app_ingress`, `cutover_preflight` (`main.rs:8-50,180-203,613-760`) | 19 | G16, G09, G10 | — | Windows layout replaces it (§6) |
| G17a/b | Bootstrap registries (see §3) | 69 | G01, G04, G12 | — | GJ-1 hop 1 (tools) / GJ-4 (bundles) |
| G34 | Control actions and HDC impact: `control_action*`, `hdc_control_action`, `hdc_impact_source` | 26 | G31, G07 | — | GJ-2/3 |
| G35 | Sessions, history, trace cache, storage claims: `session_*`, `history_owner`, `snapshot_pager`, `recovery_manifest`, `trace*`; agentd session/history/storage (`host.rs:86-151,273,783-883,2293-2625`, `main.rs:699`) | 57 | G01, G04, G03 | `session_publication.rs:1333-1334` (dev/ino) | later (UI parity, WM5); `recover_staged_sessions` at start can stay absent in WM1 |
| G36 | Workspace, crash symbolizer, toolchain pinning; `arkdeck-provider-workspace` `file_identity`, `canonical_json` (c-pure) | 59 | G01, G06, G12, G14 | `workspace_*` `O_NOFOLLOW`/mode/symlink use | GJ-5 |
| G37 | Flash, Rockchip, ArkForge lane, loader binding, post-flash alias; `arkdeck-rockchip-binding`, `arkdeck-provider-arkforge` lane; CLI `install_binding` | 126 | G01, G05, G07, G18, G17b | `rockchip_records.rs`, `rockchip_startup.rs`, `rockchip_reactivation.rs`, `flash_invocations.rs` (`O_NOFOLLOW`, modes) | GJ-4 |
| G38 | Debug read, trace probe, cleanup debt, device tests (hoststore/CLI tests) | 36 | G31, G06 | — | GJ-2/3 |
| G39 | DevEco registry, SDK release, DevEco password layout | 17 | G12, G15, G19 | `deveco_password.rs:216-297` (`material_layout` unix/not-unix arms) | GJ-5 |
| G40 | Import upload (hoststore `import_upload`, CLI `execute_import` `import_resources.rs:153-584`) | 31 | G01 | — | GJ-2 |
| G43 | Native code-sign helper (agentd `code_sign_helper`) | 6 | G12 | — | GJ-3 |
| G44 | Support bundle and diagnostic bundle | 12 | G01 (+`F_FULLFSYNC`) | — | WM6 |
| G45 | macOS path facts (`/private` standardisation: `arkdeck-contract/src/foundation_path.rs:79`, CLI `maintainer_contracts.rs:56`, `machine_contracts.rs:314-325` hidden flag) | 4 | — (a) | — | T2; Windows uses `GetFinalPathNameByHandleW` where a canonical path is needed |
| G46 | hoststore developer binary `main.rs` | 2 | G35 | — | — |
| G47 | Owner-only mode bits at creation (`arkdeck-provider-hdc/src/capture_files.rs:30,1849,3327`; CLI `domain_executor.rs:1062`, `update_feed.rs:378`) | 5 | — (b) | — | GJ-1 hop 7 (`capture_files` for capture.diagnostics) |

## 5. WM1 order: gates to remove per GJ-1 hop

The WM1 definition of done is that every runbook §2 step runs from the CLI on Windows against a
fake HDC; the real-device row stays for phase A. Hop numbers follow the runbook's command order.

| Hop | Runbook step | Groups to port or ungate (in this order) | Task |
| --- | --- | --- | --- |
| 0 | daemon start with the Windows development composition | G09, G01 (state root, `instance.lock`), single-instance guard (§6), G10, G41 (isolated root on Windows), G04p | XPA-004 (prerequisite) |
| 1 | `doctor` (deep facts), registered HDC selected | G17a + G04 (registry timestamps) + G12 (Authenticode of the tuple), G06 (`ToolLaunchIdentity`), G07 (managed server) | XPA-002 acceptance → XPA-004 |
| 2 | `device candidates` | G30 observation owner over G06 dispatch; XPA-002's provider path already works | XPA-004 |
| 3–4 | `target adopt`, `target show`, `target availability` | G30, G03 (display names), **G05 (trusted USB relation; without it adoption never passes)**, G01 (`.targets.lock`, `.target-display-names.lock`) | XPA-004 |
| 5 | `agent run --operation observe.device@1` | G33, G31 admission (G02 SQLite, G01 journal + atomic replace, G04p `job-record.json` bytes), G20 honest-absent `AnalyzerProfiles`, G06 `-t <connectKey>` dispatch, G07 server proof | XPA-005 |
| 6 | `agent status`, `job result`, `job evidence`, `artifact list` | G31, G32 | XPA-005 |
| 7 | `runtime service verify` | G16: LaunchAgent-only today; needs the Windows substitute (open question 1) | XPA-005 |
| 8 | `capture.diagnostics@1` + `artifact read`/`export` | G06, G32, G47, G09 receive root | XPA-006 |
| 9 | `runtime service restart`, `job show`/`job result` readback | G10 stop + drain, single-instance handover (§6), G31 `recover_active_jobs`, G16 substitute | XPA-005 |
| 10 | §2.1 HAR crash-resume (zero-candidate `physicalConnection`) | G33, G30 | XPA-006 |

Not needed for GJ-1:

| Later milestone | Groups |
| --- | --- |
| GJ-2/GJ-3 (WM2: XPA-008/009) | G34, G38, G40, G43, G19 (shell channel) |
| GJ-4 (WM4: XPA-010) | G37, G17b, G18 |
| GJ-5 (WM3: XPA-011) | G36, G39, G13, G15, G19 (PTY), G20 (hilog/crash analyzers) |
| WM5/WM6 | G35 (session/history UI surfaces), G14, G44, G21 |
| stays macOS-only | G16 (launchd, Mach ingress), G42 (Swift cutover and `~/Library` layout), G45, G08/G11 (already mirrored) |

## 6. Platform decision (proposal for review): state directory and single-instance guard

Checked against the profile's Expected Port mapping: **SingleInstanceGuard** ("Named Mutex or an
equivalent kernel object, isolated per user/product, must handle an abandoned owner"),
**VolumeIdentityResolver** (volume identity, never grouped by drive letter or path string) and
**ProcessExecutor**. The proposal leaves the design (§D.2) and the profile text alone.

| Concern | macOS today | Windows proposal |
| --- | --- | --- |
| State root | `~/Library/Application Support/ArkDeck/Agentd`, home from `CFFIXED_USER_HOME` or the password database, `HOME` ignored (`production.rs:211-251`, `account.rs:1-35`) | `%LOCALAPPDATA%\ArkDeck\Agentd` resolved by `SHGetKnownFolderPath(FOLDERID_LocalAppData)` for the process token; the environment variable is not read (same rule as `HOME`). Product parent `%LOCALAPPDATA%\ArkDeck` holds `Sessions`, `Bootstrap\v1`, `Signing\OpenHarmony` with the same relative names. Created owner-only: protected DACL = user SID + SYSTEM, no inheritance from the profile |
| Durable owner lock | `flock(instance.lock)` via `HostDirectory::lock_document` + `instance.json` (`production.rs:64-69,326-360`) | `LockFileEx` on the same `instance.lock` (file name and `instance.json` shape unchanged, T0), locking a range beyond end-of-file. SPK-5: released immediately when the holder is killed, like `flock` |
| Single-instance guard (Port) | the same `instance.lock`, plus the facade's transport-directory `flock` (`unix.rs:151-182`) | Named mutex `Global\ArkDeck.Agentd.<user SID>`: **per user and product across logon sessions**, because two sessions of one account share one `%LOCALAPPDATA%`. Created with an explicit DACL (user SID + SYSTEM). `ERROR_ACCESS_DENIED` or a foreign owner on an existing object refuses the start (fail closed, never serve). Acquired and held by the **main thread** for the life of the process: a mutex is thread-affine, and one taken on a worker thread would read as abandoned while the daemon still runs. A kernel private namespace bound to the user SID is an alternative that also stops name squatting; evaluate before coding |
| Abandoned owner | `flock` just disappears with the process | `WAIT_ABANDONED` = the predecessor died holding the guard. Take ownership, log one structured line, then go through the normal start, which already assumes a crash: `recoverActiveJobs` parks every unresolved intent, the torn-tail repair runs, zero dispatch. Never read it as a clean handover and never replay |
| Order at start | `instance.lock` → `bind_facade` → instance document → stores | mutex → `instance.lock` → pipe with `FILE_FLAG_FIRST_PIPE_INSTANCE` → `instance.json` → stores. Nothing is probed before all three are held; a second starter answers `already running` from `instance.json` as on macOS |
| Drain | `stop_listening` hands back the `ListenerLock`; it is released only after drain | stop accepting (close the pipe instance), keep the mutex and `instance.lock` until drain completes, then release both. A client-autostarted successor blocks on the mutex, never overlaps |
| Endpoint | `agentd.sock` inside the state directory, `getpeereid == euid` | `\\.\pipe\arkdeck-agentd-<logon SID>` as implemented (`windows/mod.rs:64-69`), DACL = logon SID, `PIPE_REJECT_REMOTE_CLIENTS`. Consequence to accept explicitly: a second logon session of the same account finds the daemon of the first session holding the user-scoped mutex and gets `already running in another session of this account` instead of a second daemon |
| Isolated development root | `ARKDECK_DEVELOPMENT_STATE_ROOT`, socket directly inside it, root owned by the facade's directory `flock`, refused under the installed state (`main.rs:307-330`) | Root anywhere outside `%LOCALAPPDATA%\ArkDeck`; containment is decided on opened handles (`FileIdInfo` + volume serial walk, `GetFinalPathNameByHandleW`), never by string prefix. Root ownership is `LockFileEx` on `<root>\.owner.lock` (NTFS cannot `LockFileEx` a directory); guard mutex `Global\ArkDeck.Agentd.Dev.<user SID>.<root FileId>`, never the production name; pipe `\\.\pipe\arkdeck-agentd-dev-<logon SID>-<root FileId hex>` (pipes cannot live inside a directory, so the endpoint-in-root rule becomes endpoint derived from the root identity). Daemon identity follows the r12 ruling 8 (a locally trusted development signer pinned with `ARKDECK_DAEMON_SIGNER_SHA256`); no bypass switch |
| Volume identity | `statfs f_fsid` / dev | `GetVolumeInformationByHandleW` serial + `FileIdInfo` (profile VolumeIdentityResolver) |

## 7. Fallback arms

Keep (they fail closed, and they disappear when the primitive is ported):
`arkdeck-hoststore/src/lib.rs:491,500` (`valid_host_text`/`canonical_host_text` → `false`/`Shape`),
`arkdeck-bootstrap/src/registry.rs:25` (timestamp → `false`), `session_time.rs:101`,
`arkdeck-agentd/src/main.rs:197,660` (composition refusals), `arkdeck-cli/src/import_resources.rs:574`,
`support_bundle.rs:250,317`, `runtime_update.rs:142`, and the candidate rows published without
adoption or presentation fields (`arkdeck-agentd/src/host.rs:3099-3115`, honest absence until G30).

Retire in WM1 (they answer with different predicates from macOS, a T1 risk):
`arkdeck-cli/src/target_resources.rs:37-40` (`trim()`/`char::is_control` for display names),
`domain_leaves.rs:358` (`char::is_alphanumeric`), `trace_inspect.rs:382`,
`machine_contracts.rs:319-323` (hidden = leading dot only).

## 8. Open questions for the maintainer

1. GJ-1 steps `runtime service verify` and `runtime service restart` exist only for the LaunchAgent.
   What is the Windows form under decision 11 (client autostart)? For example
   `runtime service restart` = pipe stop + autostart + readback, and `verify` = pinned signer and
   path of the running daemon over the pipe.
2. `verifies_managed_process` checks the managed HDC's argv on macOS. Windows has no supported
   foreign-argv read. Can the Windows proof be restricted to processes this daemon launched into
   its own Job object, with any other server reported as external and never stopped?
3. Decision 10 packages the App as MSIX and the daemon/CLI as xcopy. The daemon must stay
   unpackaged (or opt out of AppData write virtualization) so that the state root is one physical
   directory. Please confirm.
4. Group termination: macOS sends TERM, then KILL after 0.25 s. Windows `TerminateJobObject` is
   immediate. Record this as a T1-equal decision (the outcome and error code are the same)?

## 9. Local checks

- `sh scripts/check-sdd.sh`: see the commit message for the exit code.
- `git diff --check`: clean.
- No build was run; this slice changes documentation only.
