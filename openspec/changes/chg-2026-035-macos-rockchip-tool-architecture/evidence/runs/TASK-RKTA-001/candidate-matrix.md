# TASK-RKTA-001 source-pinned candidate matrix

- Date: 2026-07-25
- Retrieval UTC: `2026-07-25T06:48:27Z`
- Evidence class: `documentReview`
- Outcome: `selected:bundledRockchipComponent`
- Matrix vocabulary: `pass | fail | unknown | requires-new-change`

Every result below starts with the controlled vocabulary and labels its basis
as `fact`, `inference`, or both. `requires-new-change` is not a present-tense
pass: the referenced gate must be approved and closed before implementation.
No `unknown` is promoted to pass.

## Source registry

| ID | Primary source and pinned fact |
| --- | --- |
| `CORE` | Protected-main Constitution; flashing, workflow/journal/recovery and desktop UX specs; Provider/typed-step contracts at readiness pins. Typed steps, fixed argv, durable intent/outcome, mode separation, least privilege, and honest recovery remain mandatory. |
| `001G` | PR #525 merge `2b15a53986054f0984a71a0f113a5a2b807c3914`; sanitized receipt SHA-256 `240503c81b9f5a7f9d3e7e4fbb6be806f1417992d7fa52bcc3dd47af1b6d5d8e`. Stage A stopped at `selectedEntryNotRegularFile`; bookmark, Process, real tool, USB and device were not reached. |
| `ADR2` | `docs/adr/0002-macos-v1-sandboxed-distribution.md` at blob `5111bb8c8657d0ed05e0184fbbaeb88af5fc5d8f`: Sandboxed, exact six App entitlements, Developer ID, Hardened Runtime, single notarized DMG; HDC external-first. |
| `A1` | Apple, “Accessing files from the macOS App Sandbox”, retrieved `2026-07-25T06:48:27Z`, <https://developer.apple.com/documentation/security/accessing-files-from-the-macos-app-sandbox>. User-selected access, persistent security-scoped bookmarks, cross-process bookmark sharing and executable location are separate. The user-selected file entitlements do not let an App run programs outside its bundle, container or App Group containers. |
| `A2` | Apple, “Embedding a command-line tool in a sandboxed app”, retrieved `2026-07-25T06:48:27Z`, <https://developer.apple.com/documentation/xcode/embedding-a-helper-tool-in-a-sandboxed-app>. Xcode-built and externally built embedded tools are supported; the documented shape includes App Sandbox + inherit, Hardened Runtime, architecture handling, Skip Install, Code Sign On Copy, and Developer ID distribution applicability. |
| `A3` | Apple, “Protecting user data with App Sandbox”, retrieved `2026-07-25T06:48:27Z`, <https://developer.apple.com/documentation/security/protecting-user-data-with-app-sandbox>. App Sandbox limits resource access through entitlements; an embedded command-line tool inherits the containing App's Sandbox configuration. |
| `A4` | Apple, “Configuring the macOS App Sandbox”, retrieved `2026-07-25T06:48:27Z`, <https://developer.apple.com/documentation/xcode/configuring-the-macos-app-sandbox>. Sandbox capabilities are explicit least-privilege inputs, not generic authority. |
| `A5` | Apple, “Service Management”, retrieved `2026-07-25T06:48:27Z`, <https://developer.apple.com/documentation/servicemanagement/>. Login items, LaunchAgents and LaunchDaemons have different lifecycle and privilege surfaces. |
| `A6` | Apple, “SMAppService” and `register()`, retrieved `2026-07-25T06:48:27Z`, <https://developer.apple.com/documentation/servicemanagement/smappservice>. Registration is approval/lifecycle-sensitive; login items and agents can start/relaunch, while a LaunchDaemon needs administrator approval before bootstrap. |
| `A7` | Apple, “xpc_listener_set_peer_requirement”, retrieved `2026-07-25T06:48:27Z`, <https://developer.apple.com/documentation/xpc/xpc_listener_set_peer_requirement>. Listener messages can be restricted by peer code-signing requirement; peer sessions do not inherit that requirement. |
| `A8` | Apple, “Constraining a tool’s launch environment”, retrieved `2026-07-25T06:48:27Z`, <https://developer.apple.com/documentation/security/constraining-a-tool%27s-launch-environment>. Parent identifier and Team ID launch constraints can restrict an embedded tool's launch context. |
| `A9` | Apple, “Creating distribution-signed code for macOS”, retrieved `2026-07-25T06:48:27Z`, <https://developer.apple.com/documentation/xcode/creating-distribution-signed-code-for-the-mac/>. Nested code is identified and signed inside-out; Developer ID main executables use secure timestamp and Hardened Runtime; deep signing is not a substitute for per-component entitlements. |
| `A10` | Apple, “Customizing the notarization workflow”, retrieved `2026-07-25T06:48:27Z`, <https://developer.apple.com/documentation/security/customizing-the-notarization-workflow>. The distribution is submitted, logs are checked, and tickets are stapled/validated; nested payloads remain part of the notarization surface. |
| `R1` | Upstream `rockchip-linux/rkdeveloptool` commit `304f073752fd25c854e1bcf05d8e7f925b1f4e14`, tree `9908d5bd43d32659500e6f0d0734755ee557122e`, authored/committed `2025-03-07T07:34:30Z`, retrieved through the GitHub API at `2026-07-25T06:48:27Z`. |
| `R2` | Exact upstream `license.txt` blob `25e216a7063f10f19bf5b77b3a351f5bbd62e268` contains GNU GPL version 2. It describes notice/source obligations for object-code distribution. This review is not legal approval. |
| `R3` | Exact upstream `CMakeLists.txt` blob `90faa72f90bf6111d26559d278685cdb5c39811a` hard-codes libusb 1.0.22 and libiconv Homebrew paths and links their dylibs. It is not a hermetic build or dependency manifest. |
| `R4` | Exact upstream `Readme.txt` blob `2561f1e2e153488efd1ad0628ef00a9dfaac1f5d` documents libusb/libudev build prerequisites and generic RockUSB read/write commands; it does not define ArkDeck macOS packaging, signing or support. |

## `selectedExternal`

| Criterion | Result, basis and source |
| --- | --- |
| product/Core compatibility | `fail` — fact (`A1`,`ADR2`): the current Sandboxed six-entitlement shape cannot use user-selected file authority as authority to run an out-of-bundle program. |
| component/executable location | `fail` — fact (`A1`): the executable is outside the App bundle/container/App Group, the location class Apple says user-selected file entitlements cannot run. |
| sandbox/entitlements | `fail` — fact (`ADR2`,`A1`): the approved exact App entitlement set does not create external-executable authority; adding a file-writing executable entitlement would not establish launch authority. |
| tool access | `fail` — fact (`001G`,`A1`): 001G did not reach tool access, and the platform rule independently blocks treating selection as launch authority. |
| image/key/output access | `requires-new-change` — inference (`A1`,`CORE`): cross-process file authority would require separately designed and tested leases; App access cannot be extrapolated to the child. |
| USB/device access | `unknown` — fact (`001G`): the real external tool and USB were never reached in the exact product shape. |
| production composition root | `fail` — inference (`CORE`,`001G`): no reviewed App root can construct a permitted external executable route. |
| authority minting | `fail` — inference (`CORE`,`A1`): a picker/bookmark cannot mint process/device execution authority. |
| IPC peer authentication | `pass` — fact: this candidate has no IPC peer, so it adds no IPC authentication boundary; that does not repair its launch failure. |
| fixed argv/no shell/PATH | `pass` — fact (`CORE`): the existing adapter can fix absolute URL + argv, but a safe request shape cannot make a forbidden location executable. |
| tool provenance | `requires-new-change` — inference (`R1`,`001G`): user installation ownership and a reproducible relationship to the pinned source would still need closure. |
| license/notice | `requires-new-change` — fact/inference (`R2`): external use avoids ArkDeck redistribution only if ArkDeck never distributes/copies the binary; user-facing license/provenance policy still needs closure. |
| corresponding source/source offer | `requires-new-change` — fact/inference (`R2`): the support model must prove ArkDeck performs no object-code distribution or define the applicable corresponding-source duty without guessing. |
| dependency provenance/licenses | `unknown` — fact (`R3`): the selected external artifact's libusb/libiconv closure is not established. |
| reproducible build/architecture | `unknown` — fact (`R1`,`R3`): no reproducible artifact maps the observed binary to the pinned source or architecture inputs. |
| SBOM | `unknown` — fact (`R3`): no SBOM identifies the external artifact and its dependency closure. |
| sign/notarize | `fail` — inference (`A9`,`A10`): ArkDeck cannot sign/notarize user-owned external code as part of its App distribution. |
| update/CVE | `fail` — inference: ArkDeck cannot atomically update, recall or assign CVE response for an independently installed/user-selected executable. |
| cancel/crash/reconcile | `requires-new-change` — inference (`CORE`): the workflow can model process outcomes, but the external lifecycle and version drift require a new closure. |
| diagnostics/privacy | `requires-new-change` — inference (`CORE`,`A1`): external path/trust/permission diagnostics need redacted, bounded product evidence. |
| clean-host verification | `unknown` — fact (`001G`,`ADR2`): no Developer ID/notarized clean-host external-tool matrix exists. |
| Windows/Linux portability | `requires-new-change` — inference: every platform would need a different external executable, permission and provenance model. |
| rollback | `fail` — inference: ArkDeck cannot atomically roll back an independently installed/user-selected executable. |
| source refs | `pass` — fact: `A1`,`001G`,`ADR2`,`CORE`,`R1`–`R3` support the recorded cells. |
| fact-vs-inference | `pass` — fact: platform/run observations are labelled fact; architecture consequences are labelled inference. |
| verdict | `fail` — inference: contains `fail` and `unknown`; not selectable and no 001G retry is permitted. |

## `bundledRockchipComponent`

| Criterion | Result, basis and source |
| --- | --- |
| product/Core compatibility | `pass` — inference (`CORE`,`A2`): a product-owned exact component can remain behind the existing typed Provider/effect/authority semantics. |
| component/executable location | `pass` — fact (`A1`,`A2`): an embedded executable is inside the App bundle, a documented executable location for a sandboxed App. |
| sandbox/entitlements | `requires-new-change` — fact/inference (`A2`,`A3`,`ADR2`): the documented component shape is App Sandbox + inherit; the exact signed ArkDeck nested entitlement closure must be approved and tested without changing the six App entitlements. |
| tool access | `requires-new-change` — inference (`A2`,`R1`): the bundle-relative descriptor, artifact identity and prepared-launch path must be implemented and tested. |
| image/key/output access | `requires-new-change` — fact/inference (`A1`,`CORE`): parent file access cannot be assumed to reach the child; exact read/write leases need signed-product tests. |
| USB/device access | `requires-new-change` — fact/inference (`A3`,`001G`): Sandbox inheritance is documented, but exact bundled `rkdeveloptool` RockUSB access requires a fresh signed E0 test. |
| production composition root | `requires-new-change` — inference (`CORE`): `ArkDeckApp -> RockchipFlashApplicationFacade/RockchipFlashExecutionHost -> bundled descriptor` must be the only production construction path. |
| authority minting | `pass` — inference (`CORE`): the existing trusted host authorization gate remains the single mint; the component receives a prepared closed command and never mints authority. |
| IPC peer authentication | `pass` — fact/inference: direct child execution adds no IPC service; parent/team launch constraints may harden the child (`A8`) without becoming authority. |
| fixed argv/no shell/PATH | `pass` — fact/inference (`CORE`): existing `RockchipClosedCommand` lowering and identity-bound Process request meet the shape; the follow-on change binds only a bundle URL. |
| tool provenance | `requires-new-change` — fact (`R1`): exact upstream is pinned, but a hermetic source-to-artifact receipt and product registry do not yet exist. |
| license/notice | `requires-new-change` — fact (`R2`): maintainer/legal acceptance, license/warranty notices and modification notices must precede distribution. |
| corresponding source/source offer | `requires-new-change` — fact (`R2`): corresponding-source delivery or a compliant source-offer mechanism, including build scripts, must precede object-code distribution. |
| dependency provenance/licenses | `requires-new-change` — fact (`R3`): libusb 1.0.22/libiconv paths are known inputs, but source/hash/license/system-vs-bundled closure is absent. |
| reproducible build/architecture | `requires-new-change` — fact/inference (`A2`,`R3`): architecture handling is documented; a hermetic arm64/universal decision and reproducible source-to-artifact build must be proven. |
| SBOM | `requires-new-change` — fact (`R3`): a reviewable component/dependency SBOM does not yet exist. |
| sign/notarize | `requires-new-change` — fact (`A2`,`A9`,`A10`): Code Sign On Copy, inside-out Developer ID/Hardened Runtime signing, notarization and ticket verification must be implemented on release bytes. |
| update/CVE | `requires-new-change` — inference: component identity must be atomic with App update/rollback and have an assigned vulnerability-response owner. |
| cancel/crash/reconcile | `pass` — inference (`CORE`): the direct child remains behind current durable intent/outcome, critical cancellation and `waitingForRecovery`; fault tests remain a follow-on deliverable. |
| diagnostics/privacy | `requires-new-change` — inference (`CORE`): component/source/dependency/signing diagnostics and raw-output redaction/limits need product evidence. |
| clean-host verification | `requires-new-change` — fact (`ADR2`,`A10`): Developer ID/notarized DMG clean-host and clean-VM evidence is still a release gate. |
| Windows/Linux portability | `pass` — inference: the Core Provider/process ports remain shared while each future platform supplies its own reviewed component packaging; macOS bundle rules are not exported as Core. |
| rollback | `requires-new-change` — inference (`A9`,`A10`): component version must be atomic with the App release, with rollback disabling execute rather than selecting an external fallback. |
| source refs | `pass` — fact: `CORE`,`ADR2`,`A1`–`A3`,`A8`–`A10`,`R1`–`R3`,`001G` support the recorded cells. |
| fact-vs-inference | `pass` — fact: Apple/upstream/repository statements are facts; future topology and adequacy judgments are labelled inference. |
| verdict | `pass` — inference: there is no `fail` or `unknown`; every `requires-new-change` maps to an ADR-0003 pre-implementation gate. Outcome is `selected:bundledRockchipComponent`. |

## `brokerOrHelper` (aggregate)

| Criterion | Result, basis and source |
| --- | --- |
| product/Core compatibility | `fail` — inference (`CORE`): at least one required subrow adds persistence/privilege or lacks a complete executable supply-chain end state; the umbrella cannot inherit a subrow's local advantage. |
| component/executable location | `fail` — fact/inference (`A1`,`A2`): a broker alone does not make an external executable runnable; bundling the exact tool is the separately selected candidate. |
| sandbox/entitlements | `requires-new-change` — fact (`A2`,`A3`,`A5`,`A6`): each subrow has a distinct entitlement/lifecycle surface and would need its own approval. |
| tool access | `fail` — inference: no single umbrella access model covers XPC, intermediary helper, agent and daemon. |
| image/key/output access | `requires-new-change` — fact (`A1`): cross-process bookmarks/leases must be carried and verified per receiver. |
| USB/device access | `unknown` — fact (`001G`): none of the broker/helper subrows has RockUSB evidence. |
| production composition root | `fail` — inference (`CORE`): the aggregate has no single component/effect dispatch point. |
| authority minting | `fail` — inference (`CORE`): an umbrella cannot establish one minting point across four different lifecycles. |
| IPC peer authentication | `requires-new-change` — fact (`A7`): every IPC listener/session requires explicit code-signing requirements and session-level treatment. |
| fixed argv/no shell/PATH | `requires-new-change` — inference (`CORE`): each subrow needs a closed protocol that cannot forward caller command/environment. |
| tool provenance | `requires-new-change` — fact (`R1`): a broker does not close source-to-artifact provenance. |
| license/notice | `requires-new-change` — fact (`R2`): any redistributed component needs explicit license/warranty/modification notices. |
| corresponding source/source offer | `requires-new-change` — fact (`R2`): any object-code redistribution needs an accepted corresponding-source/source-offer mechanism. |
| dependency provenance/licenses | `unknown` — fact (`R3`): component dependency closure is absent. |
| reproducible build/architecture | `unknown` — fact (`R3`): no broker/helper build or architecture closure exists. |
| SBOM | `unknown` — fact (`R3`): no broker/helper/tool SBOM exists. |
| sign/notarize | `requires-new-change` — fact (`A5`,`A6`,`A9`,`A10`): nested/service code must be signed and notarized coherently. |
| update/CVE | `requires-new-change` — inference (`A5`,`A6`): service install/update/remove, compatibility, CVE response and orphan handling need one lifecycle. |
| cancel/crash/reconcile | `requires-new-change` — inference (`CORE`,`A6`): relaunch/persistence can conflict with unknown-outcome recovery and requires a dedicated protocol. |
| diagnostics/privacy | `requires-new-change` — inference (`CORE`): IPC identity, lifecycle and helper logs need bounded redacted evidence. |
| clean-host verification | `unknown` — fact: no subrow has a Developer ID/notarized clean-host result. |
| Windows/Linux portability | `fail` — inference: ServiceManagement/XPC lifecycle is macOS-specific and cannot become the shared Core seam. |
| rollback | `fail` — inference (`A5`,`A6`): aggregate rollback cannot atomically remove four possible service forms. |
| source refs | `pass` — fact: `A1`,`A2`,`A5`–`A10`,`CORE`,`R1`–`R3` support the recorded cells. |
| fact-vs-inference | `pass` — fact: API/lifecycle statements are facts; adequacy and attack-surface judgments are labelled inference. |
| verdict | `fail` — inference: the aggregate contains `fail`/`unknown`; each mandatory subrow is evaluated below. |

## `brokerOrHelper/sandboxedXPC`

| Criterion | Result, basis and source |
| --- | --- |
| product/Core compatibility | `requires-new-change` — inference (`CORE`): a new IPC contract could preserve typed semantics only after schema, authority and recovery review. |
| component/executable location | `fail` — fact/inference (`A1`,`A2`): XPC transport alone neither relocates nor supplies `rkdeveloptool`; adding a bundled tool would be a distinct combined candidate. |
| sandbox/entitlements | `requires-new-change` — fact (`A3`): service sandbox/inheritance and file/device capabilities require explicit nested-code configuration. |
| tool access | `fail` — inference: no complete tool location/provenance path exists without importing another candidate. |
| image/key/output access | `requires-new-change` — fact (`A1`): cross-process bookmarks can transfer access, but exact leases and revocation require implementation evidence. |
| USB/device access | `unknown` — fact (`001G`): no XPC RockUSB evidence exists. |
| production composition root | `requires-new-change` — inference (`CORE`): App-to-service construction and the single process/device dispatch point need a new approved contract. |
| authority minting | `requires-new-change` — inference (`CORE`): the App must mint an opaque permit; the XPC service cannot trust request claims. |
| IPC peer authentication | `requires-new-change` — fact (`A7`): listener and every peer session need code-signing requirement enforcement. |
| fixed argv/no shell/PATH | `requires-new-change` — inference (`CORE`): protocol must carry typed operation IDs, never argv/executable/environment. |
| tool provenance | `requires-new-change` — fact (`R1`): XPC adds no provenance closure. |
| license/notice | `requires-new-change` — fact (`R2`): redistributed service/tool code needs explicit notices. |
| corresponding source/source offer | `requires-new-change` — fact (`R2`): redistributed object code needs an accepted corresponding-source/source-offer path. |
| dependency provenance/licenses | `unknown` — fact (`R3`): dependency closure remains absent. |
| reproducible build/architecture | `unknown` — fact: neither service nor tool has a reproducible architecture-bound build. |
| SBOM | `unknown` — fact: neither service nor tool has an SBOM. |
| sign/notarize | `requires-new-change` — fact (`A9`,`A10`): service and nested code need inside-out signing/notarization closure. |
| update/CVE | `requires-new-change` — inference: App/service/tool compatibility, update, rollback and vulnerability response need a single owner. |
| cancel/crash/reconcile | `requires-new-change` — inference (`CORE`): connection loss cannot prove external outcome; durable service-side correlation would be required. |
| diagnostics/privacy | `requires-new-change` — inference: IPC identity and request/result logs need redaction and bounds. |
| clean-host verification | `unknown` — fact: no packaged XPC result exists. |
| Windows/Linux portability | `fail` — inference: XPC is a macOS implementation detail and the added protocol has no cross-platform need. |
| rollback | `requires-new-change` — inference: App/service/tool versions must roll back atomically. |
| source refs | `pass` — fact: `A1`,`A3`,`A7`,`A9`,`A10`,`CORE`,`R1`–`R3` support the recorded cells. |
| fact-vs-inference | `pass` — fact: documented API properties and missing evidence are facts; topology judgments are labelled inference. |
| verdict | `fail` — inference: contains `fail`/`unknown`; not selectable. |

## `brokerOrHelper/embeddedInheritedHelper`

This subrow means a custom intermediary helper. If the embedded executable is
the exact Rockchip tool itself, it is `bundledRockchipComponent`, not this
subrow.

| Criterion | Result, basis and source |
| --- | --- |
| product/Core compatibility | `fail` — inference (`CORE`): a separate intermediary adds authority/IPC surface without closing a Core requirement beyond direct bundled execution. |
| component/executable location | `fail` — inference (`A2`): the intermediary still must bundle or reach the real tool; direct bundling already supplies the documented location. |
| sandbox/entitlements | `requires-new-change` — fact (`A2`,`A3`): helper needs App Sandbox + inherit and explicit nested signing. |
| tool access | `fail` — inference: helper indirection alone does not select a complete real-tool location. |
| image/key/output access | `requires-new-change` — fact (`A1`): child access still needs exact file-lease proof. |
| USB/device access | `unknown` — fact (`001G`): no intermediary-helper RockUSB evidence exists. |
| production composition root | `requires-new-change` — inference: App/helper/tool ownership and dispatch point require a new composition contract. |
| authority minting | `fail` — inference (`CORE`): the extra helper creates a second tempting authority point and has no necessity justifying it. |
| IPC peer authentication | `requires-new-change` — fact/inference (`A7`,`A8`): any control channel needs peer verification; parent/team launch constraints are hardening, not authority. |
| fixed argv/no shell/PATH | `requires-new-change` — inference (`CORE`): helper protocol must not forward generic commands. |
| tool provenance | `requires-new-change` — fact (`R1`): helper does not remove source/artifact closure. |
| license/notice | `requires-new-change` — fact (`R2`): bundled helper/tool license and modification notices remain. |
| corresponding source/source offer | `requires-new-change` — fact (`R2`): bundled object code needs an accepted corresponding-source/source-offer path. |
| dependency provenance/licenses | `unknown` — fact (`R3`): dependency closure remains absent. |
| reproducible build/architecture | `unknown` — fact: helper plus tool has a larger unclosed build and architecture graph. |
| SBOM | `unknown` — fact: helper plus tool has no complete SBOM. |
| sign/notarize | `requires-new-change` — fact (`A2`,`A9`,`A10`): both nested code items need coherent signing/notarization. |
| update/CVE | `requires-new-change` — inference: App/helper/tool compatibility, update and vulnerability response need one lifecycle. |
| cancel/crash/reconcile | `requires-new-change` — inference (`CORE`): helper/tool crash boundaries and outcome correlation are new. |
| diagnostics/privacy | `requires-new-change` — inference: two process boundaries expand bounded logging and redaction. |
| clean-host verification | `unknown` — fact: no packaged intermediary result exists. |
| Windows/Linux portability | `fail` — inference: the extra helper boundary adds no shared Core value. |
| rollback | `requires-new-change` — inference: App/helper/tool identities must roll back atomically. |
| source refs | `pass` — fact: `A1`–`A3`,`A7`–`A10`,`CORE`,`R1`–`R3` support the recorded cells. |
| fact-vs-inference | `pass` — fact: platform/build gaps are facts; necessity and attack-surface judgments are labelled inference. |
| verdict | `fail` — inference: contains `fail`/`unknown`; not selectable. |

## `brokerOrHelper/loginItemOrLaunchAgent`

| Criterion | Result, basis and source |
| --- | --- |
| product/Core compatibility | `fail` — inference (`CORE`,`A5`,`A6`): persistent login lifecycle is not required for a user-triggered flash Job and expands effect ownership. |
| component/executable location | `requires-new-change` — fact (`A5`,`A6`): service code must live in an App-managed registered location; the real tool supply remains separate. |
| sandbox/entitlements | `requires-new-change` — fact (`A1`,`A5`): service sandbox and cross-process file access require explicit configuration. |
| tool access | `fail` — inference: registration does not close the real tool's location/provenance. |
| image/key/output access | `requires-new-change` — fact (`A1`): bookmarks/leases must be transferred to and resolved by the service. |
| USB/device access | `unknown` — fact: no registered-agent RockUSB evidence exists. |
| production composition root | `fail` — inference (`CORE`): launchd persistence creates an independent lifetime outside the Job composition root. |
| authority minting | `fail` — inference (`CORE`): a long-lived agent cannot retain or recreate stale Job authority. |
| IPC peer authentication | `requires-new-change` — fact (`A7`): every connection/session needs a peer requirement. |
| fixed argv/no shell/PATH | `requires-new-change` — inference (`CORE`): protocol must expose closed operations only. |
| tool provenance | `requires-new-change` — fact (`R1`): registration supplies no tool provenance. |
| license/notice | `requires-new-change` — fact (`R2`): redistributed service/tool code needs explicit notices. |
| corresponding source/source offer | `requires-new-change` — fact (`R2`): redistributed object code needs an accepted corresponding-source/source-offer path. |
| dependency provenance/licenses | `unknown` — fact (`R3`): dependency closure is absent. |
| reproducible build/architecture | `unknown` — fact: no service/tool reproducible architecture-bound build exists. |
| SBOM | `unknown` — fact: no complete service/tool SBOM exists. |
| sign/notarize | `requires-new-change` — fact (`A5`,`A6`,`A9`,`A10`): registered service/tool code needs coherent signing/notarization. |
| update/CVE | `requires-new-change` — fact/inference (`A5`,`A6`): registration, update, removal, compatibility and vulnerability response form a new lifecycle. |
| cancel/crash/reconcile | `fail` — fact/inference (`A6`,`CORE`): automatic relaunch after crash must not replay an unknown destructive outcome; no durable protocol exists to prove otherwise. |
| diagnostics/privacy | `requires-new-change` — inference: persistent logs and IPC identifiers need independent retention/redaction policy. |
| clean-host verification | `unknown` — fact: no user-approval/register/unregister/update clean-host matrix exists. |
| Windows/Linux portability | `fail` — inference: login item/LaunchAgent lifecycle is macOS-specific. |
| rollback | `fail` — inference (`A5`,`A6`): orphaned registration/removal is a separate rollback hazard. |
| source refs | `pass` — fact: `A1`,`A5`–`A7`,`A9`,`A10`,`CORE`,`R1`–`R3` support the recorded cells. |
| fact-vs-inference | `pass` — fact: lifecycle/relaunch properties are facts; product necessity and recovery conclusions are labelled inference. |
| verdict | `fail` — inference: contains `fail`/`unknown`; not selectable. |

## `brokerOrHelper/privilegedLaunchDaemon`

| Criterion | Result, basis and source |
| --- | --- |
| product/Core compatibility | `fail` — fact/inference (`CORE`,`A6`): no accepted requirement needs root, while current UX forbids silent privilege/helper installation. |
| component/executable location | `requires-new-change` — fact (`A5`,`A6`): daemon packaging/installation is a separate service-management product. |
| sandbox/entitlements | `fail` — inference (`ADR2`): a privileged daemon is not the selected inherited Sandbox child shape and reopens the distribution/privilege boundary. |
| tool access | `requires-new-change` — inference: daemon still needs a pinned tool/component supply chain. |
| image/key/output access | `requires-new-change` — fact (`A1`): privileged service file access cannot bypass user consent or become broad filesystem authority. |
| USB/device access | `unknown` — fact: no evidence shows privilege is required or that this daemon shape can access the exact RockUSB target. |
| production composition root | `fail` — inference (`CORE`): a system daemon outlives the App/Job and creates a second privileged effect root. |
| authority minting | `fail` — inference (`CORE`): root status cannot mint ArkDeck workflow/device authority. |
| IPC peer authentication | `requires-new-change` — fact (`A7`): privileged IPC requires strict peer requirements and session handling. |
| fixed argv/no shell/PATH | `requires-new-change` — inference (`CORE`): daemon protocol must not expose generic root command execution. |
| tool provenance | `requires-new-change` — fact (`R1`): privilege does not establish provenance. |
| license/notice | `requires-new-change` — fact (`R2`): redistributed daemon/tool code needs explicit notices. |
| corresponding source/source offer | `requires-new-change` — fact (`R2`): redistributed object code needs an accepted corresponding-source/source-offer path. |
| dependency provenance/licenses | `unknown` — fact (`R3`): dependency closure is absent. |
| reproducible build/architecture | `unknown` — fact: daemon/tool/installer reproducible architecture-bound build is absent. |
| SBOM | `unknown` — fact: daemon/tool/installer SBOM is absent. |
| sign/notarize | `requires-new-change` — fact (`A5`,`A6`,`A9`,`A10`): daemon/tool/installer signing and notarization need a new distribution design. |
| update/CVE | `requires-new-change` — inference (`A5`,`A6`): approval, install, update, removal, compatibility and vulnerability response need a new lifecycle. |
| cancel/crash/reconcile | `fail` — inference (`CORE`): privileged persistent effects enlarge unknown-outcome and orphan recovery without demonstrated need. |
| diagnostics/privacy | `requires-new-change` — inference: privileged logs and IPC require a new privacy/audit boundary. |
| clean-host verification | `unknown` — fact: no administrator approval/install/remove clean-host matrix exists. |
| Windows/Linux portability | `fail` — inference: LaunchDaemon is macOS-specific and root service models differ per platform. |
| rollback | `fail` — inference (`A6`): removal/orphan/old-daemon compatibility cannot be atomic with a DMG-only App rollback today. |
| source refs | `pass` — fact: `A1`,`A5`–`A7`,`A9`,`A10`,`CORE`,`ADR2`,`R1`–`R3` support the recorded cells. |
| fact-vs-inference | `pass` — fact: service approval and missing evidence are facts; least-privilege and topology conclusions are labelled inference. |
| verdict | `fail` — inference: contains `fail`/`unknown`; not selectable. |

## `planOnlyHandoff`

| Criterion | Result, basis and source |
| --- | --- |
| product/Core compatibility | `fail` — fact (`CORE`): plan-only is valid but cannot satisfy the current Rockchip execute capability or produce `succeeded`. |
| component/executable location | `pass` — fact: ArkDeck launches no tool, so it adds no executable-location boundary. |
| sandbox/entitlements | `pass` — fact (`ADR2`): current App shape can produce a host-only plan without new process authority. |
| tool access | `pass` — fact: ArkDeck does not access or launch the execution tool. |
| image/key/output access | `requires-new-change` — inference (`CORE`): plan Artifact and any human transport/import would need a privacy/provenance design. |
| USB/device access | `pass` — fact (`CORE`): process/device dispatch is zero. |
| production composition root | `pass` — inference (`CORE`): App owns only validation/plan finalization; no execution root exists. |
| authority minting | `pass` — fact: no ArkDeck process/device authority is minted. |
| IPC peer authentication | `pass` — fact: no IPC service is added. |
| fixed argv/no shell/PATH | `pass` — fact/inference (`CORE`): the Artifact may display a typed plan but ArkDeck executes no command or shell. |
| tool provenance | `requires-new-change` — inference: human handoff still needs to state which external tool the plan expects without claiming it was used. |
| license/notice | `pass` — inference (`R2`): ArkDeck does not redistribute the tool in this end state. |
| corresponding source/source offer | `pass` — inference (`R2`): no ArkDeck object-code distribution creates a corresponding-source delivery path. |
| dependency provenance/licenses | `pass` — fact: ArkDeck distributes no tool dependency. |
| reproducible build/architecture | `pass` — fact: ArkDeck builds no Rockchip executable in this end state. |
| SBOM | `pass` — fact: no Rockchip executable/dependency is added to the App SBOM. |
| sign/notarize | `pass` — fact (`ADR2`): no Rockchip nested code is added to the signed/notarized App release. |
| update/CVE | `pass` — fact/inference: ArkDeck owns no Rockchip binary update or CVE surface in this end state. |
| cancel/crash/reconcile | `pass` — fact (`CORE`): plan finalization follows plan-only states; external human execution is outside ArkDeck and cannot be reconciled as an ArkDeck Job. |
| diagnostics/privacy | `requires-new-change` — inference: human command/result artifacts need explicit redaction and import provenance if introduced. |
| clean-host verification | `requires-new-change` — inference (`ADR2`): plan-only UI/export still needs normal release clean-host evidence. |
| Windows/Linux portability | `pass` — inference: typed plan semantics are cross-platform. |
| rollback | `pass` — inference: disable/remove handoff UI without external service cleanup. |
| source refs | `pass` — fact: `CORE`,`ADR2`,`R2` support the recorded cells. |
| fact-vs-inference | `pass` — fact: zero-dispatch/mode rules are facts; product sufficiency is explicitly evaluated. |
| verdict | `fail` — fact/inference: it fails the current execute capability and cannot be selected as the Rockchip execution end state. |

## `distributionRevisit`

This row means reopening DEC-004/ADR-0002 before adopting a non-Sandbox or
other distribution. It does not choose a specific replacement distribution.

| Criterion | Result, basis and source |
| --- | --- |
| product/Core compatibility | `requires-new-change` — inference (`CORE`,`ADR2`): Core can remain unchanged only after a replacement platform profile proves equal or stricter behavior. |
| component/executable location | `pass` — inference (`A1`): a non-Sandbox App would not have the same Sandbox executable-location restriction, subject to normal DAC/Gatekeeper. |
| sandbox/entitlements | `requires-new-change` — fact (`ADR2`): abandoning/changing Sandbox requires an explicit DEC-004/ADR-0002 reopen and entitlement/distribution redesign. |
| tool access | `requires-new-change` — inference: exact external-tool selection, trust and launch need a new product path and evidence. |
| image/key/output access | `requires-new-change` — fact/inference (`A1`,`ADR2`): file semantics and least-privilege access must be redesigned/revalidated outside the current bookmark model. |
| USB/device access | `requires-new-change` — fact (`001G`): exact replacement shape has no RockUSB evidence. |
| production composition root | `requires-new-change` — inference (`CORE`): a new root must still own the sole process/device dispatch path. |
| authority minting | `pass` — inference (`CORE`): trusted-host authority semantics can be retained, but must be revalidated in the replacement composition. |
| IPC peer authentication | `pass` — fact: a direct non-Sandbox process route need not add IPC; any added service would be a separate combined candidate. |
| fixed argv/no shell/PATH | `pass` — fact/inference (`CORE`): existing closed lowering can remain mandatory. |
| tool provenance | `requires-new-change` — inference (`R1`): external installation/source/artifact ownership still needs closure. |
| license/notice | `requires-new-change` — inference (`R2`): obligations depend on whether ArkDeck distributes the tool; the replacement choice must state notices and modifications. |
| corresponding source/source offer | `requires-new-change` — fact/inference (`R2`): any replacement that distributes object code must define the corresponding-source/source-offer path. |
| dependency provenance/licenses | `requires-new-change` — fact (`R3`): exact external artifact dependency closure is absent. |
| reproducible build/architecture | `requires-new-change` — fact (`R1`,`R3`): replacement distribution/tool artifact build and architecture closure is absent. |
| SBOM | `requires-new-change` — fact (`R3`): the replacement App/tool dependency SBOM is absent. |
| sign/notarize | `requires-new-change` — fact (`A9`,`A10`,`ADR2`): the replacement App/tool distribution must be re-signed, notarized and tested. |
| update/CVE | `requires-new-change` — inference (`ADR2`): replacement update compatibility, vulnerability response and rollback need a new owner and evidence. |
| cancel/crash/reconcile | `pass` — inference (`CORE`): existing workflow semantics can remain, subject to replacement-path tests. |
| diagnostics/privacy | `requires-new-change` — inference: broader filesystem/process reach needs a revised threat and redaction review. |
| clean-host verification | `requires-new-change` — fact (`ADR2`): all Sandbox/current release evidence becomes inapplicable to the new shape. |
| Windows/Linux portability | `pass` — inference: Core can remain portable, but every platform keeps its own permission/distribution profile. |
| rollback | `requires-new-change` — inference: rollback/supersession between distribution identities and file-access models must be designed before release. |
| source refs | `pass` — fact: `CORE`,`ADR2`,`A1`,`A9`,`A10`,`001G`,`R1`–`R3` support the recorded cells. |
| fact-vs-inference | `pass` — fact: the required reopen/current evidence gap is factual; potential non-Sandbox feasibility is labelled inference. |
| verdict | `pass` — inference: no `fail`/`unknown` remains if every listed D1/revalidation gate precedes implementation, but it is rejected because `bundledRockchipComponent` preserves the approved distribution with a smaller authority/change surface. |

## Decision rule result

`bundledRockchipComponent` and, conditionally, `distributionRevisit` contain no
`fail` or `unknown`. The latter requires replacing the approved distribution
before implementation; the former has an Apple-documented route inside the
current distribution and turns each unresolved supply-chain/runtime fact into
a precise pre-implementation change gate. The selected complete end state is
therefore:

> `selected:bundledRockchipComponent`

No combined sixth candidate was inferred. In particular, the selected direct
bundled component is not combined with XPC, a login item, an agent, a daemon,
an external-tool fallback, or a distribution revisit.
