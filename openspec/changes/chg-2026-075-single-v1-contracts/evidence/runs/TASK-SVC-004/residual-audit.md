# Single-format residual audit — CHG-2026-075 (TASK-SVC-004)

Scope: own-production schema/protocol/legacy/migration matches across the
repository, classified per the TASK-SVC-004 Deliverable 5 vocabulary. This is a
per-line disposition, not a "grep returns zero" claim: the greps below still
return matches, and every one of them is accounted for here.

Search modalities (run from the repository root on the delivered tree):

```bash
grep -rniE '\blegacy\b|\bmigrat|\bdeprecat|backward.?compat' --include=*.swift Packages ArkDeckApp
grep -rn 'schemaVersion' --include=*.swift --include=*.json Packages ArkDeckApp openspec/contracts Catalog
grep -rnE '"[0-9]+\.[0-9]+\.[0-9]+"' --include=*.swift Packages/ArkDeckKit/Sources
grep -rnE '\.v[0-9]+"' --include=*.swift --include=*.json Packages openspec/contracts Catalog
grep -rn 'UserDefaults\|@AppStorage\|@SceneStorage' --include=*.swift Packages ArkDeckApp
grep -rn 'ARKDECK_' --include=*.swift --include=*.plist --include=*.md --include=*.sh Packages ArkDeckApp scripts docs
```

No negative filter (`grep -v '/1"'` and friends) was applied. A reader that
accepts *both* an old and a current label is exactly what a single-v1 audit
exists to find, and such a line contains the current label too.

## (a) Own-production compatibility removed by this Task

| Match at the base tree | Disposition |
| --- | --- |
| `RuntimeHistoryView.swift` `legacySavedFilterKeys`, `legacySavedFilter(defaults:)`, `removeLegacySavedFilter(defaults:)` and the promotion inside `loadSavedFilter()` (8 `history.savedFilter.*` keys, `toolkit`→`device` remap) | Removed. The Runtime-owned filter owner is the only source; a record an earlier build left in this process's preferences is ignored and the pane shows the owner's own first-run state. |
| `SettingsApplicationFacade.swift` `SettingsLegacyStorageMigrationPlan`, `migrateLegacyStorageIfNeeded(_:)`, `legacyMigrationStore`, `legacyMigrationAssessed`, `migratesLegacyPreferences` | Removed. An ordinary launch no longer constructs a `SessionSettingsStore`, so no App-local preference can produce a `runtime.storage.root` / `runtime.storage.policy` write. |
| `SettingsApplicationFacade.swift` `legacyStorageRuntime` / `legacyRuntimeArtifactUsage`, their four in-process branches, `make(storageRuntime:runtimeArtifactUsage:)` and `makeStoragePresentation(settings:retention:runtimeArtifacts:)` | Removed. One presentation builder is left, fed by the exact-shape `runtime.storage.status` reader. The package seams are now the UI fixture owner and a reply-level `make(reply:)`, both of which drive the shipped reader. |
| `SettingsRootView.swift` `"ArkDeck.applicationIcon.v1"`, `DebugWorkspaceView.swift` `@SceneStorage("debug.workspace.tab.v2")` | Suffix dropped. Non-authoritative UI keys with sensible first-run defaults (`.waveform`, `DebugWorkspaceTab.artifacts`); an ignored old value costs the user one re-pick. |
| `LaunchAgentService.swift` `arkForgedPathEnvironmentKey` / `arkForgedSHA256EnvironmentKey` / `arkForgeProfileEnvironmentKey` / `legacyArkForgeEnvironmentKeys`, the three-key migration branch of `configuredArkForgeLane`, and `Refusal.mixedLegacyConfiguration` / `.partialLegacyConfiguration` / `.crossBundleLegacyConfiguration` / `.digestMismatch` | Removed. The three names survive only as `retiredArkForgeEnvironmentKeys`, a refusal vocabulary nothing reads values from. `digestMismatch` went with its only thrower. |
| `ArkForgeLaneComposition.swift` `EnvironmentKey.legacyDaemonPath` / `.legacyDaemonSHA256` / `.legacyDeviceProfilePath`, `Absence.legacyConfiguration` / `.mixedConfiguration` | Removed; replaced by `EnvironmentKey.retired` and one `Absence.retiredConfiguration(keys:)` naming `runtime service update --arkforge-bundle`. |
| `OpenHarmonyLocalSigning.swift` `legacyAccessSchemas` (`nil`, `trusted-applications-v2`, `trusted-applications-v3`) and the `allowLegacyAccessSchema` parameter | Removed. `data-protection-access-group-v1` is the only accepted marker; another marker is refused by name and nothing it points at is read, rewritten or deleted. |
| `OpenHarmonyLocalSigning.swift` `readLegacy(account:)` (protocol requirement, default and the non-Data-Protection query) and `legacySecretPair(for:)` | Removed. There is no read path outside the Data Protection Keychain access group. |
| `OpenHarmonyLocalSigning.swift` `removeLegacy(account:)` | Renamed `removeOutsideDataProtection(account:)` and called only by `remove()`. An explicit uninstall must finish; it is never a read path. |
| `OpenHarmonyLocalSigning.swift` the migration half of `refreshDaemonKeychainIdentity` (legacy envelope read, public-SDK substitution, fresh account, receipt rewrite at the current schema) | Removed. What remains is re-recording the verified daemon identity in the receipt — a receipt-file write that neither reads nor rewrites the envelope. |
| `OpenHarmonyLocalSigning.swift` `legacyPasswordAccounts`, its two-account bookkeeping in `install()`, `migrateToSecretEnvelope` and `remove()`, and the pre-envelope fallbacks in `secretPair` and `loadValidatedUnlocked` | Removed as compatibility. The current half is kept under a current name: `supersededEnvelopeAccounts` records envelope accounts this preset rotated away so uninstall clears them (see (b)). |
| `OpenHarmonyLocalSigning.swift` `normalizeDevEcoSecrets` + `OpenHarmonySigningSecretNormalization`; `ArkDeckRuntimeCommands.swift` `case "normalize"`; `CLICommandRegistry.swift` the `runtime.signing.normalize` leaf and its derived `signing normalize` alias | Removed. Its own doc comment named its purpose — repairing installs written by an older ArkDeck. Both current entries (`install --build-profile`, `migrate-deveco`) decode DevEco ciphertext at the boundary, so no install this build can create needs repairing. |
| `OpenHarmonySigningEnvelopeMigration` (`migrated`, `legacyAccountCount`) | Replaced by `OpenHarmonySigningEnvelopeReplacement` (`createdEnvelopeItem`); the `migrate-deveco` result document drops `legacyAccountCount`. |
| Comment text describing the retired per-executable `SecAccess` world (`OpenHarmonyLocalSigning.swift` header, `publicSDKReleasePassword`, `existingItemValueUpdate`, `contains`), the plist "all three or none" marker, the two `LaunchAgentInstallReceipt` "Optional keeps … decodable" justifications, the `agentdInstallOptions` and `AgentdOptionCoverageContractTests` "migration error" notes, `ArkForgeLaneComposition` "obsolete migration switch", `SettingsStorageUIFixture` "the facade's one-time legacy migration", `LaunchAgentService.install()` "Migrate any legacy file-based Keychain item" | Restated as the current rule. |
| `docs/design/cli-runtime-storage.md` "bounded migration candidate"; `docs/design/cli-history-filters.md` "can migrate the former `history.savedFilter.*` App preferences"; `LaunchAgents/README.md` "首次从旧版 file-based Keychain 升级" and the `signing normalize` sentence; `arkdeck-cli-product-spec.md` and `cli-workspace-preset-toolchain-lifecycle.md` `normalize` rows | Rewritten to the delivered behaviour. |

## (b) Current business semantics — retained

| Match | Why it stays |
| --- | --- |
| `supersededEnvelopeAccounts` (new) | Not a reader: nothing is ever read from these accounts. A reinstall reuses the installed envelope only while `contains` confirms it, and that probe answers `false` both for "gone" and for "this process may not look" — so a reinstall during an unreadable moment mints a new account beside a live item holding the user's passwords. Recording it keeps `remove` able to finish. Covered by `testUninstallClearsAnEnvelopeThatAReinstallRotatedAway`. |
| `runtime.storage.*` generation CAS, the `resourceConflict` read-back on all three storage mutations, and the History filter's `mutateSavedFilter` reconciliation | The Task requires both to survive. The storage read-back previously existed only inside the deleted migration; it now belongs to the three current mutation paths. |
| `OpenHarmonySigningSecretPresence` (`present`/`absent`/`unreadable`) and the new `OpenHarmonySigningReceiptState` (`absent`/`installed`/`unusable`) | Three-way on purpose. Collapsing "nothing installed" with "installed but unreadable" is the defect this Task names. |
| `LaunchAgentArkForgeLaneStatus.measuring`, `ArkForgeReleaseBundleReader.load`, `validateProductionDaemonBundle`, `trustedDaemonApplicationSHA256`, receipt-vs-live drift diagnostics | Bundle digest, bundle identity and helper identity verification. Untouched. |
| `Absence.notConfigured` / `.partiallyConfigured(missing:)`, the empty-value guard | A lane composed from part of its inputs is one nobody chose. Unrelated to the retired names. |
| `LaunchAgentService.swift` "Legacy harness gateway keys from a pre-CHG-2026-064 installation are deliberately ignored here" | The CHG-2026-064 mechanism: `runtime service update` regenerates the plist without them. It is a non-reader, not a compatibility branch. |
| `generation`, `bindingRevision`, row/state revision, HDC binding and recovery, budgets, JobState | Explicitly out of scope for this change; untouched. |

## (c) External versions — retained

`ArkForgeReleaseBundleReader` (`arkforge.release-bundle/v1`), ArkTrace descriptor
`formatVersion`, HDC / OpenHarmony SDK / Hvigor project layout (including the
`legacy Hvigor configuration is absent` refusal text), Apple's deprecated
`kSecUseAuthenticationUIFail` note, code-signing formats, `sqlite3_*_v2`, Swift
tools version, macOS availability, npm dependency versions. None is renumbered
or removed.

## (d) Historical documents and raw evidence — byte-identical

`openspec/changes/archive/**`; the non-archived historical change directories
(`chg-2026-070-arkforge-generic-integration/design.md` "Legacy three-key
LaunchAgent receipts", `chg-2026-031-macos-session-settings/**`,
`chg-2026-059/evidence/**`); `docs/design/references/v1.6-goal/**` run records;
and the planning documents of this change (`proposal.md`, `design.md`,
`spec-delta.md`, `tasks.md`) which quote the pre-cleanup state on purpose. CI
cache namespaces are untouched.

## (e) Negative fixtures and refusals by name — retained

`retiredArkForgeEnvironmentKeys` and `EnvironmentKey.retired` with their two
refusals; the `--arkforged` / `--arkforged-sha256` / `--arkforge-profile`
options, which stay in `agentdInstallOptions` and in the registry as
`stability: refusedByName` so the command can name `--arkforge-bundle` as their
replacement instead of answering "unsupported option"; the three retired-key
shapes asserted in `ArkForgeLaneInstallContractTests`,
`ArkForgeFlashSessionContractTests` and `LaunchAgentServiceContractTests`; the
`trusted-applications-v2` / `-v3` receipts and the `2.0.0` documents constructed
as refused vectors in `OpenHarmonyLocalSigningContractTests`. These are the
mechanism, so the greps above still find their strings by design.

## Outside the TASK-SVC-004 Allowed paths

These are own-production compatibility hits this Task may not touch. Per the
Task text they belong in follow-up PRs under their original Task IDs, submitted
against those Tasks' own Allowed paths; the last row has no owning Task at all
and needs a maintainer decision.

| Match | Owner |
| --- | --- |
| `Packages/ArkDeckKit/Sources/ArkDeckBootstrap/BootstrapToolRegistry.swift:623` — `["arkdeck.bootstrap-tools/1", "arkdeck.bootstrap-tools/2"].contains(index.schemaVersion)`, a two-generation acceptance reader in the HDC tool-binding index (the writer at :69 and :687 is `/2`) | TASK-SVC-001, whose Allowed paths list this exact file (tasks.md:71). Found only after re-running the label grep without a negative filter — a `grep -v '/1"'` hides precisely the lines that accept both. |
| `PublishedOperationBundleManifest.schemaVersion = "2.0.0"` and a stale `"2.0.0"` comment | TASK-SVC-001 (control plane / published surface). Reported from the baseline scan; not re-verified on the delivered tree by this Task. |
| `ArkDeckAgentDaemonMain/main.swift` `ARKDECK_WORKSPACE_PROJECTS` auto-import of a daemon environment profile, and the `allowsLegacySigningPresetFallback` flag it drives through `WorkspaceOperationsProvider` (a "compatibility source for legacy daemon environment profiles only") | TASK-SVC-002, whose Allowed paths list `ArkDeckAgentDaemonMain/main.swift` (tasks.md:202). This Task's `ArkDeckAgentDaemon/**` does not glob-match `ArkDeckAgentDaemonMain/`, and the flag cannot be retired from the consumer side alone. |
| `Packages/ArkDeckKit/Sources/ArkDeckWorkflows/WorkspaceProvider/RuntimeWorkspaceProjectStore.swift:1292-1302` accepts `arkdeck.workspace-project-store/1|/2|/3` and `:1425` migrates to `/3` | **No SVC Task's Allowed paths contain this file** — SVC-004 lists three sibling files in the same directory (tasks.md:371-373) and no other SVC Task names it. Needs an explicit maintainer decision rather than a follow-up PR. |
| `OpenHarmonyLocalSigning.swift` `supportedCertificateChainReadback` — recovers an early durable signing intent's `certificate-chain.pem` sibling into `.cer` | In an allowlisted file, but it is durable-intent payload compatibility, and refusing it instead would change pending-intent semantics under POL-RECOVERY-001. Left unchanged and raised here rather than decided inside a preferences Task. |
| `ArkDeckApp/Features/Trace/TraceViewerWorkspaceView.swift` `@AppStorage("inspectorDock")` / `inspectorVisible`; `HDCProduction.swift` `ArkDeck.HDC.devecoSDKPaths` / `ArkDeck.HDC.openHarmonySDKPaths` and its bookmark preference; `DeviceWorkspace.swift` `app.devices.customDisplayNames.v1` | Non-authoritative presentation preferences. The Trace and HDC files are outside this Task's Allowed paths. `app.devices.customDisplayNames.v1` **is** inside them and was deliberately left alone: it holds names the user typed, its Runtime-owned counterpart (`RuntimeTargetDisplayNameStore`) has no App-facing facade yet (`docs/design/cli-candidate-display-names.md`), and renaming the key would silently orphan the user's own data. |
