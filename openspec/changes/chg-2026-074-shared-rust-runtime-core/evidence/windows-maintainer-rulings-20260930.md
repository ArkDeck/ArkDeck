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

Related rulings the same day: the WinUI alpha project templates are accepted, the client uses the
latest stable stack (.NET 10, Windows App SDK 2.5.1, WinUI 3) with a Fluent 2 style whose product
semantics come from `docs/design/arkdeck-ds/src/tokens.css`; the Windows support tuple is Windows
11 x64 only (CHG-2026-074 r13, #2342).
