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

Rulings 18–29 were settled later the same day under the maintainer's delegation of 2026-09-30:
non-major choices follow the agent's recommendation. Ruling 18 was put to the lead and approved on
that delegation. Rulings 19–29 record the choices the slices made under it, so later slices can cite
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
| 29 | The account daemon's Sessions root and Trace cache locations on Windows (H3, W1; `runs/TASK-XPA-005/windows-account-locations-run.md`) | Beside the state directory in the product directory, mirroring macOS: the default Sessions root is `%LOCALAPPDATA%\ArkDeck\Sessions` (settings stay in `Agentd\session-state`), the Trace cache `%LOCALAPPDATA%\ArkDeck\Trace\traces` beside its `staging`, which the daemon creates owner-only (no App container on Windows; ruling 8). An earlier build's `Agentd\sessions` is moved once by one rename and its settings rebased; beside an existing `Sessions` an empty one is removed and one holding anything refuses the start. Supersedes ruling 28. |
