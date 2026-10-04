# Windows phase — maintainer rulings, 2026-09-30

The agent put twelve open questions from the Windows phase slices to the maintainer, each with a
recommendation. On 2026-09-30 the maintainer answered "全部按推荐" (all as recommended). This
record lists them so the slices can cite them. None changes a Requirement, Acceptance Scenario,
Core baseline, safety invariant or hardware criterion. Where a ruling touches a platform decision
recorded elsewhere (the Windows profile, design §L.1), that document is updated in its own PR.

| # | Question (source) | Ruling |
| --- | --- | --- |
| 1 | Proof that an HDC server is the one the daemon manages, when Windows offers no supported way to read another process's argv (gate inventory §8 q2; `runs/TASK-XPA-005/windows-tool-dispatch-run.md`) | A server is **managed** only if this daemon instance launched it and it is still in that instance's Job object, with the verified tool's image path and SHA-256, the process creation time and the exact loopback listener bound; everything else is **external** — never adopted or stopped (fail closed; after a daemon restart the previous instance's server counts as external). No named Job surviving restarts, no undocumented command-line read. |
| 2 | Ending a tool's child tree (gate inventory §8 q4) | `TerminateJobObject` (immediate) is **T1-equal** to macOS's TERM-then-KILL of the process group: both leave no child and record the same outcome. The daemon itself stops through its stop event and drain. |
| 3 | Two differences of the Windows server lease from macOS | Accepted: a server whose image was renamed away reports `NotFound`; a listener owner that cannot be opened makes the proof `PermissionDenied`. Both fail closed. |
| 4 | Stop requests of the `Local\` single-instance guard (`runs/TASK-XPA-002/windows-daemon-lifecycle-run.md`) | Accepted: a stop request works only from the same logon session; cross-session exclusion stays with the owner lock. |
| 5 | An existing account state root whose DACL is not owner-only | **Refused**: the daemon does not start, and the start message / `runtime service verify` names the directory and what to fix. The daemon never rewrites an existing ACL. |
| 6 | `text_key`/`same_text` off macOS compared raw bytes (found by the NTFS host-store slice) | Portable canonical equivalence proven against the recorded corpora; a fail-closed refusal of non-ASCII comparisons only as an interim if needed. Delivered directly by #2336, so no interim was needed. |
| 7 | `document_metadata`/`remove_document` return `std::fs::Metadata`, which has no stable file id on Windows | They take a store-owned identity type (e.g. `HostFileIdentity`); the macOS callers change with it, behaviour T1-identical. |
| 8 | The daemon inside the MSIX (gate inventory §8 q3) | The package turns file-system and registry write virtualization off (`unvirtualizedResources`), so the App, the daemon and the xcopy CLI share one physical `%LOCALAPPDATA%\ArkDeck\Agentd`. |
| 9 | Windows CLI coverage status for "CLI serves it, the Windows daemon owner is absent or unmeasured" (`runs/TASK-XPA-018/windows-cli-leaves-run.md`) | `partial` (the existing vocabulary: a real surface implemented, target contract not closed). Only `implemented` counts for exit condition 4. |
| 10 | The 116 coverage entries with no Windows status (macOS-only families, App surfaces) | App surfaces are covered by the Windows client and become Windows-required; macOS-only families get their Windows counterpart (e.g. launchd → client-started daemon, Keychain → Credential Manager); entries with no counterpart become maintainer-accepted `deferred` platformService entries. The concrete list is reviewed at WM6. |
| 11 | Windows spelling of the USB topology (`runs/TASK-XPA-004/windows-usb-census-run.md`) | The decimal of the first eight bytes of the SHA-256 of the first `DEVPKEY_Device_LocationPaths` entry: stable per port, never equal to a macOS value. Revisit only if the DAYU200 sample shows it unstable. |
| 12 | Development MSIX publisher and client code location | `CN=ArkDeck Development`, host-trusted only; client code under `windows/`. |

Four further questions, raised later the same day by the portable text/calendar slice (#2336,
`runs/TASK-XPA-004/portable-text-calendar-run.md` §4) and SPK-4 (#2347,
`runs/TASK-XPA-007/spk-4-20260930-run.md`), were answered the same way ("全部按推荐"):

| # | Question | Ruling |
| --- | --- | --- |
| 13 | The portable Unicode tables reproduce the CoreFoundation of the CI image (macOS 27), while the design names macOS 26 as the reference | Follow the CI image: CI is the unified gate. When the reference host or the CI image moves, regenerate the tables (`rust/scripts/generate-host-text-tables.py`, whose `--check` stops silent drift). |
| 14 | The portable legacy ISO 8601 parser refuses spellings only ICU accepted (one-digit fields, `GMT`/`UTC`, trailing text, other digit scripts, leading spaces), on macOS too | Accepted (fail closed): no Swift or Rust writer produces them, so every recorded document still decodes. |
| 15 | NFC keeps CoreFoundation's dropping of one leading U+FEFF, which Swift `String` equality does not do | Keep the CoreFoundation behaviour, so keys stay byte-identical with existing macOS data (T0); the difference from Swift `String` equality is recorded as T1. |
| 16 | WinUI accent: the system accent (what the spike does) or the product accent of `tokens.css` | The product accent from `docs/design/arkdeck-ds/src/tokens.css`, for one brand on both platforms; light/dark still follow the system, and high-contrast themes use system colours only. |

Ruling 17, raised by the xcopy packaging slice (#2349, `runs/TASK-XPA-022/xcopy-package-run.md`)
and answered "按推荐" the same day:

| # | Question | Ruling |
| --- | --- | --- |
| 17 | The client pins the daemon's Authenticode signer by the certificate's SHA-256 (XPA-AC-6 layer 2), but Azure Artifact Signing issues short-lived leaf certificates, so that pin would change with every signing | Per form: the **MSIX** daemon is pinned by its package family (stable; decision 10); the **xcopy** daemon is pinned by publisher identity — `WinVerifyTrust` passes, the chain ends at the Microsoft root that Artifact Signing chains to, and the leaf's subject organisation and the Artifact Signing per-account identity EKU both equal the configured values — instead of one certificate's hash. The development signer keeps its certificate-hash pin. No form gets a switch that skips identity verification. Implemented in its own TASK-XPA-002 slice. |

Related rulings the same day: the WinUI alpha project templates are accepted, the client uses the
latest stable stack (.NET 10, Windows App SDK 2.5.1, WinUI 3) with a Fluent 2 style whose product
semantics come from `docs/design/arkdeck-ds/src/tokens.css`; the Windows support tuple is Windows
11 x64 only (CHG-2026-074 r13, #2342).

Rulings 18–28 were settled later the same day under the maintainer's delegation of 2026-09-30:
non-major choices follow the agent's recommendation. Ruling 18 was put to the lead and approved on
that delegation. Rulings 19–28 record the choices the slices made under it, so later slices can cite
them. None changes a Requirement, Acceptance Scenario, Core baseline, safety invariant or hardware
criterion.

| # | Question (source) | Ruling |
| --- | --- | --- |
| 18 | How a mutation refused because an owner is not composed is answered (#2350 `target.adopt`, #2370 `trace.cache.purge`) | `operationUnavailable` with `phase: preAdmission` and `newDispatchCount: 0`, on macOS and Windows alike, so a client reads a refusal rather than an unknown outcome. |
| 19 | Windows Credential Manager store (#2354) | A credential blob is limited to 2560 bytes. The presence check reads the secret. |
| 20 | Windows Artifact read and export, E1 (#2356) | NTFS reserved names and characters are refused. |
| 21 | NTFS import upload source, U1 (#2357) | The import source is opened shared read-only. |
| 22 | ConPTY prompt and secret exchange, G19 (#2358) | ConPTY's differences (CR line ends, VT-stripped rendering) are accepted as T1-equal. |
| 23 | Windows Job store, H2 (#2361) | `job.list` answers one page until the Windows pager lands. The NTFS replace retries for about 1 s on an access-denied or sharing violation. The Windows account root keeps the Job store in `jobs-state`. |
| 24 | Windows DevEco files and file identity, D2 (#2362) | SYSTEM, Administrators and TrustedInstaller count as root. "Private" means nobody else is granted anything, and the owner is checked. |
| 25 | Windows signing, G2 (#2369) | The signing `default_root` is `<LocalAppData>\ArkDeck\Signing\OpenHarmony`. Held file and ancestor handles replace `/.vol`, descriptors are set explicitly private, and stored paths use the host's spelling. |
| 26 | `observe.device` on Windows, S1 | The daemon has no fake-HDC bypass. On Windows, `observe.device` is refused before admission as without an HDC until the Windows HDC tuple's integration change lands. |
| 27 | CI speed-up options | The maintainer approved options B, C and E. Option A (#2364) is merged. |
| 28 | The account daemon's Trace cache on Windows, W1 (#2367) | The account daemon composes no Trace cache until the Windows App cache location is decided. |

Rulings 29–55 record the delegated minor decisions of 2026-09-30 and 2026-10-01, which the slices
took under the same delegation and marked "pending the next rulings batch" in their run records.
Each names its PR; the run record under `evidence/runs/` has the reasons. Two are from PRs still
open when this record was written (#2411, #2428), and read as their PRs merge. None changes a
Requirement, Acceptance Scenario, Core baseline, safety invariant or hardware criterion.

| # | Question (source) | Ruling |
| --- | --- | --- |
| 29 | Session provenance and the account's first Session location (#2385) | A Session published on Windows names `PLATFORM-WINDOWS@0.2.0` as its Manifest `platformProfile`; macOS keeps `PLATFORM-MACOS@0.2.0`. The account daemon's first Session location, below `Agentd`, is replaced by ruling 30. |
| 30 | The account daemon's Session and Trace locations (#2390) | Supersedes ruling 28. Session settings stay in `%LOCALAPPDATA%\ArkDeck\Agentd\session-state`, the default Sessions root is `%LOCALAPPDATA%\ArkDeck\Sessions` and the Trace cache `%LOCALAPPDATA%\ArkDeck\Trace\traces`, each created owner-only by the daemon (Windows has no App container to create the cache). |
| 31 | A device's name in the WinUI App (#2375) | On Windows the name is the Runtime's (`target.display-name.*`), so the CLI and the App show one name; the macOS input rule and message are kept. |
| 32 | The Windows release candidate's layout (#2380) | The CLI ships in `bin\` (NTFS cannot hold `arkdeck.exe` beside `ArkDeck.exe`) and is pointed at the root's daemon; the xcopy form carries the App unpackaged, and the MSIX carries the CLI in `bin\` with no App Execution Alias yet. |
| 33 | The phase A runbook (#2398) | It lives in `docs/design/cross-platform/`, in English, and points at the headless runbook for each Journey's steps and criteria. GJ runs install the RC xcopy zip and pin its daemon; Windows has no `runtime service install`/`update`. |
| 34 | The Windows GJ conformance rows (#2399) | The suite version stays `0.2.0`, as only `NOT_RUN` rows are added; one row per Journey, with GJ-1's HAR crash-resume inside `WIN-GJ1-001`. |
| 35 | The Windows USB relation census (#2402) | The census fails closed (`MappingUnconfirmed`, nothing read) while any CHG-2026-078 §4 field is `TBD(sample)`; the field mapping is one table, `CENSUS_MAPPING`. |
| 36 | The ArkForge lane on Windows (#2403) | A Windows bundle names `bin/arkforge.exe` and `bin/arkforged.exe`; the paired stop is end of input, half a second, then `TerminateJobObject`; the lane refuses before launching when either ArkForge pipe already answers. `arkforge-platform` is a Windows dev-dependency for the stand-in only. |
| 37 | The App Installer feed and uninstall (#2404) | The feed checks on every launch and prompts without blocking, never downgrades, and takes the MSIX's own version, which the maintainer raises per RC. Uninstall never removes the daemon's state or signing credentials. |
| 38 | Machine output equality across hosts (#2406) | The doctor report's `observedAt` (whole-second wall clock) is the one T2 member, labelled in the pinned macOS fixtures; every other byte of the five read-only leaves must be equal on every host. |
| 39 | The code-sign helper in the Windows packages (#2407) | The packages ship the checked-in, device-proved helper, pinned by SHA-256 and Build-ID; a Windows-built helper is reproducibility evidence only. |
| 40 | The Windows kill matrix (#2408) | The fake HDC answers in process. The daemon test reads its own clock's times and the ledger records' self-digests as labels, reads the Job index from a copy with no daemon running, and compares no POSIX modes. |
| 41 | The Flash archive reader on Windows (#2410) | A DEFLATE decoder of our own (about 400 lines of safe Rust) rather than a new crate, held to Swift's archive oracle and to zlib's streams; where it ends an output window may differ from Apple's, as no answer depends on it. |
| 42 | `runtime service` coverage on Windows (#2411, open) | As launchd's counterpart (ruling 10), `runtime service` status, verify, restart and uninstall join Windows coverage; `install` and `update` stay refused and read `notImplemented`. |
| 43 | The Windows DevEco toolchain record (#2412) | It keeps the macOS trust fields: `signingIdentifier` is the Authenticode signer's name and `codeDirectoryIdentitySHA256` the signer leaf's SHA-256, with no `teamIdentifier`. The signer must be exactly `Huawei Technologies Co., Ltd.`, and `"platform":"windows"` enters the content digest under the unchanged schema. |
| 44 | The production release candidate (#2413) | Supersedes #2404's decision 3: the MSIX publisher is set at build time on a copy of the manifest, whose tracked identity stays `CN=ArkDeck Development`. Both publisher pins come from the maintainer, and a production run signs the MSIX unless `-SkipMsix`. |
| 45 | HAR crash-resume on Windows (#2415) | The fake HDC is the oracle's table answered in process, and the crash children take their state root from the parent (`ARKDECK_HAR_ROOT`). |
| 46 | Pinning the MSIX daemon (#2416, #2417) | Option 3: the MSIX daemon is pinned by publisher identity like the xcopy one, since a CLI-started daemon has no package identity. The App reads the CLI's variable names, a partial publisher identity is refused at connect, and the production smoke configures the publisher only. |
| 47 | Ending a proved HDC server on Windows (#2419) | `end_proved_process` terminates at once, without the TERM grace Windows lacks, and reports `Killed`, never `Terminated`. |
| 48 | The debug.hap and native-library oracles on Windows (#2422) | The replays compare plan digests and the capability values derived from them through a one-to-one relabelling; the digests' T0 equality is proved separately over Swift's own paths. |
| 49 | The Flash owners on Windows (#2424) | Two refactors keep macOS's bytes (`swift_hex`, a per-platform `record_bytes`); directory synchronization is a no-op on NTFS; the journal snapshot compares size and times of the same open handle; a checkpoint seal naming a measured prewarm wait is read as Swift's. |
| 50 | `cleanupDebt.continue` on Windows (#2425) | It needs the planning root as well as the Job and Artifact owners, which the daemon always composes together. |
| 51 | The Windows HDC tuple gate (#2426) | The Windows development root runs no fixture HDC; the endpoint is per tuple, and an inherited `OHOS_HDC_SERVER_PORT` that differs is refused; the tuple table is a Rust constant that TASK-WHR-002 fills. |
| 52 | The Bootstrap and tool owners on Windows (#2428, open) | The account's Bootstrap registry is `%LOCALAPPDATA%\ArkDeck\Bootstrap\v1`, and a Windows DevEco child tool's `teamIdentifier` is null, published through the generator's shared-member rule. HDC registration is refused until a Windows HDC tuple is registered, and daemon Bundle registration until a Windows bundle form exists. |
| 53 | The WinUI Debug workspace (#2430) | The App submits the closed typed workspace Jobs as macOS does; no control is disabled (the action stays and its status line says why); there is no Remote build source on Windows, and the ELF check is the Runtime Import's. |
| 54 | A replace whose target is held (#2432) | A replace whose target a holder keeps for the whole 10 s patience is classified `BeforePublication`. |
| 55 | Windows CLI coverage measurement (#2409, #2420, #2429) | Leaves are measured in the owner process tests that hold recorded Swift state, each asserting that what it measured is `implemented` in the manifest the CLI renders; `health` counts through `runtime health`. Test setup that the CLI cannot express (an Import begun but not committed, the recorded capability store) is laid down over the pipe or on disk for the signed test only. |

On 2026-10-04 the maintainer ruled "按照建议执行所有未裁决的内容": every decision still pending is
accepted as recommended. Rulings 56–67 record, on that basis (maintainer ruling 2026-10-04, accept
as recommended), the delegated minor decisions of the PRs merged up to #2452 that rulings 29–55 did
not record, including #2439's `inodeLaunchPath` and #2446's lifecycle-only breakaway. Each names
its PR; the run record under `evidence/runs/` has the reasons. None changes a Requirement,
Acceptance Scenario, Core baseline, safety invariant or hardware criterion. The Windows HDC and
DAYU200 sample decisions are recorded in CHG-2026-078's revision, not here. The delegated decisions
of PRs still open on 2026-10-04 (#2450, #2451, #2453) are not numbered here; they are recorded once
their PRs merge.

| # | Question (source) | Ruling |
| --- | --- | --- |
| 56 | The HDC lifecycle audit and launch identity on Windows (#2439) | The lifecycle audit's `inodeLaunchPath` is the authorized executable path, and the record validator checks exactly that; macOS keeps its `/.vol` rule and bytes. The launch identity's device is the 64-bit `FileIdInfo` volume serial, its inode the 64-bit NTFS file id (a wider id refuses it) and its mode the file attributes; the status oracle's `chmod` disturbance is a last-write-time move. |
| 57 | A confirmed HDC restart's server on Windows (#2446) | Only the HDC lifecycle client runs in a Job that allows silent breakaway, so the server `kill -r` starts outlives it as on macOS; that server is adopted only through a fresh commandless proof and ended only by `end_proved_process` (ruling 47), and every other tool keeps the no-breakaway Job. A lifecycle client's capture ends 500 ms after it exits, and a listener holding the endpoint that cannot be bound to the tool is reported as `unproved_listener` (never set on macOS). |
| 58 | The Credential Manager turn (#2443) | The turn is named in the logon-session (`Local\`) namespace, following the daemon's guard, not `Global\`. The concurrent-writers test runs 10 rounds instead of 40, as its threads now take turns, and checks after each phase that every churned credential is still deleted. |
| 59 | A held Import checkpoint (#2448) | As ruling 54 reads the document replace, a held prior checkpoint that outlasts the 10 s patience is classified `BeforePublication`, not `OutcomeUnknown`. |
| 60 | The History filter document on Windows (#2423) | The Windows daemon keeps `history-filter.json` and its lock in the state root's private `history-filter` directory, as it keeps the Job store in `jobs-state`, because the host store cannot open a Windows state root itself; the bytes are unchanged. |
| 61 | The debug.hap and native-deployment lanes on Windows (#2449) | Swift's derived digests over content that differs only by host paths, the platform profile or relabelled values are read as labels; the content itself is always compared byte for byte, relabelled (as ruling 48). |
| 62 | Pinning a workspace preset's DevEco toolchain on Windows (#2447) | The pin writes the Bootstrap index in the encoding the Windows registration and retirement write, not canonical JSON, which cannot carry every NTFS file id exactly; macOS bytes are unchanged. The leaf's signed-CLI proof runs only with `ARKDECK_LIVE_DEVECO_ROOT` (a real, publisher-signed DevEco), and CI runs the refusal process test and the pin/release unit test over the signed fixture DevEco. |
| 63 | `uninstall-rc.ps1` stopping the daemon (#2440) | "Not ours, skip" is decided before the CLI runs, from the instance document's pid image, and after that check every non-zero exit fails closed; the pin is the installed image's own signer certificate, not the user's configured inputs. An unsigned image keeps the stop-event path. |
| 64 | The WinUI Flash workspace's reviews (#2442) | The App's host review of the archive is a C# port checked against every Swift oracle case, and the catalog review is embedded from the Swift-generated catalog with a drift test; `flash.bind-current-loader` is allowed beside `job.plan`/`submit`/`run`, as macOS binds the current loader from the workspace. The scripted `flash` scenario answers from the recorded Swift oracles. |
| 65 | The WinUI Flash workspace's wording and controls (#2442) | Three macOS strings that name the Mac say "the PC" on Windows, and two Windows-only lines stand where macOS uses an alert (`windows.flash.chooseImage.invalid`, `windows.flash.targetChanged`). Details is a plain toggle button, as macOS's, not an Expander, whose collapsed content is not in the UIA tree. |
| 66 | The WinUI Trace viewer's form (#2452) | The Trace viewer is a navigation page beside Trace (Alt+R), not a second window, with macOS's idle, error-banner and Inspector states, the "bundled parser is unavailable" banner and no timeline, search, zoom or annotation (nothing is shown disabled). Capture and Start never show disabled (XPA-AC-8) but say why when chosen, and the page re-reads when a capture ends instead of refreshing every 750 ms. |
| 67 | The WinUI Trace viewer's cache, strings and tree (#2452) | The App's cache is `%TEMP%\ArkDeck` (overridable with `--cache-root`), apart from the Runtime's `%LOCALAPPDATA%\ArkDeck`; the Windows-only strings are `windows.traceViewer.*` with the macOS values, plus "on this PC" and Ctrl+F. The component tree is a list with one Tab stop and macOS's arrow keys; its disclosures and the screenshot's outlines are named, invokable UIA elements but not Tab stops, the Tab-walk test's only exceptions. |
