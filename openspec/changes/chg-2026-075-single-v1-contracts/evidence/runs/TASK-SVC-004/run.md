# TASK-SVC-004 execution record

Status: local implementation and required unified verification complete.
TASK-SVC-004 is marked done in this delivery for maintainer review. No
protected-main approval, change verification or hardware acceptance is claimed.

Base: `e9a7dafce3a9ace7aab65921dbe42dff8773cb8d` (SVC-003 merged, #1741).
Branch: `agent/task-svc-004-single-v1-configuration-20260905`. The working tree
was clean at the start; every change travels in one vertical commit.

## Delivered behavior

- **History saved filter (SVC-AC-09).** The Runtime-owned filter owner is the
  only source. The eight `history.savedFilter.*` App preferences, their
  clamping, the historical `toolkit`→`device` remap and the key removal are
  gone, so a record an earlier build left in this process's preferences can no
  longer republish itself into the Runtime with no user action; the pane simply
  shows the owner's first-run state (generation 1, `query == nil`). The
  lost-response reconciliation is unchanged: a failed mutation reads the owner
  back, publishes what won and never re-sends itself, and every superseded
  reply is still rejected by request identity.
- **Settings storage (SVC-AC-09).** An ordinary launch no longer constructs a
  `SessionSettingsStore`, so no App-local preference can produce a
  `runtime.storage.root` / `runtime.storage.policy` write.
  `SettingsLegacyStorageMigrationPlan`, `migrateLegacyStorageIfNeeded` and the
  in-process `SessionStorageApplicationRuntime` seam with its four read/write
  branches are removed together with the second presentation builder they fed;
  one exact-shape reader is left. Generation-bound CAS is unchanged, and the
  `resourceConflict` read-back — which previously existed **only** inside the
  deleted migration — now belongs to all three current mutation paths, which is
  what the Task asks to preserve.
- **Non-authoritative UI keys.** `ArkDeck.applicationIcon.v1` and
  `@SceneStorage("debug.workspace.tab.v2")` lose their suffixes; both have
  sensible first-run defaults, so an ignored old value costs one re-pick.
  `app.devices.customDisplayNames.v1` is deliberately unchanged: it holds names
  the user typed and has no App-facing Runtime counterpart yet (recorded in
  [residual-audit.md](residual-audit.md)).
- **ArkForge single-bundle configuration (SVC-AC-09).** The three retired
  environment names (`ARKDECK_ARKFORGED_PATH`, `ARKDECK_ARKFORGED_SHA256`,
  `ARKDECK_ARKFORGE_PROFILE_PATH`) no longer configure anything: the
  LaunchAgent's structural upgrade (infer a bundle root from the daemon path,
  remeasure, cross-check profile and declared digest) is deleted, and both
  readers refuse by name with a message that states the current entry. Bundle
  manifest verification, daemon remeasurement, helper identity checks and the
  install / update / reconfigure / uninstall flows are untouched;
  `--arkforge-bundle none` still clears the lane and an update that restates
  nothing still preserves and remeasures the installed lane.
- **Signing storage (SVC-AC-09).** Only the current Data Protection Keychain
  access group and the secret envelope/receipt are supported. Deleted: the
  retired access-schema allowlist and its `allowLegacyAccessSchema` parameter,
  the non-Data-Protection read path (`readLegacy`, `legacySecretPair`), the
  legacy password-account roster and its bookkeeping, the pre-envelope
  fallbacks in `secretPair` and the validator, the migration half of
  `refreshDaemonKeychainIdentity`, and the `normalize` maintenance entry with
  its CLI leaf. Kept: custom signing material, `install-sdk-release` /
  `install` / `migrate-deveco` / `status` / `remove`, helper identity
  verification, and the explicit uninstall's ability to clear items an earlier
  build wrote (`removeOutsideDataProtection`, called only by `remove`). A
  receipt on an unsupported form is refused by name; nothing it points at is
  read, rewritten or deleted, and the user reconfigures explicitly.
- **CredentialOwner absent vs unusable (SVC-AC-09).** The store gained
  `receiptState()` (`absent` / `installed` / `unusable`), and the owner's five
  optional-collapse sites now use it. The two combinations the Task names are
  fixed: an unsupported receipt with **no ledger** no longer has an empty
  `state: stable` owner written beside it, and an unsupported receipt found
  **mid-`replace`** no longer settles into one. Both previously made `current()`
  answer "signing credential is not installed" while the receipt, envelope and
  material were all still on disk — after which `replace` and `remove` were
  free to run against them.
- **CLI, contracts and docs (SVC-AC-10).** `runtime signing normalize` and its
  §12 alias are gone from the registry, contracts, fixtures and coverage;
  `migrate-deveco` keeps its published spelling (the product spec and the
  toolchain-lifecycle doc both name it as the current re-keying path for an
  installed preset) and drops `legacyAccountCount` from its result. The
  generated bundle was regenerated, never hand-edited. `LaunchAgents/README.md`
  gains the ArkForge lane section it never had and loses the file-based
  Keychain upgrade story; `cli-runtime-storage.md`, `cli-history-filters.md`,
  `cli-workspace-preset-toolchain-lifecycle.md` and
  `arkdeck-cli-product-spec.md` are corrected to the delivered behaviour,
  including §13.1's leaf, lifecycle, fixture and coverage counts and the two
  rows documenting a `legacy flash` family the registry no longer contains.

## Defects found and fixed during implementation

Both were introduced by this Task's own first cut and caught by an adversarial
review pass before the gate:

1. **The named remedy was unreachable.** Refusing the retired ArkForge keys
   inside `configuredArkForgeLane` propagated through the shared plist reader,
   so `runtime service update --arkforge-bundle …` — the exact command both
   refusal messages tell the operator to run — failed on precisely the
   installations the refusal is about, and `status` lost its daemon/HDC facts
   with it. `configuredPaths()` now carries the lane as a `Result`: `status`
   degrades it to a diagnostic, the ArkTrace preserving read ignores it, and
   only `arkForgeLaneForPreservingUpdate()` still forces it, so a bare `update`
   on a retired plist still fails loud. Regression:
   `testARetiredKeyRefusesTheLaneWithoutBlockingReconfiguration`.
2. **The same shape in the credential owner.** Making `loadAndRecover` throw for
   an unusable receipt also blocked `replace`/`remove`, i.e. `runtime signing
   install` and `remove`, which are the only ways out of an unsupported
   receipt. Mutations now read the ledger without demanding a readable receipt
   (`ledgerForMutation`) and stay gated on ownership, which the ledger records
   by itself. Covered inside
   `testAnUnreadableReceiptIsNeverPublishedAsAnEmptyStableOwner`.
3. **A current path would have orphaned a live secret.** Deleting
   `legacyPasswordAccounts` outright removed the only record of an envelope
   account a reinstall rotated away. Reuse is proven with `contains`, which
   answers `false` both for "gone" and for "this process may not look", so a
   reinstall during an unreadable moment mints a new account beside a live item
   holding the user's passwords that uninstall would then never clear. The
   compatibility half (the pre-envelope two-account form) is deleted; the
   current half is kept under a current name, `supersededEnvelopeAccounts`,
   which nothing reads from. Regression:
   `testUninstallClearsAnEnvelopeThatAReinstallRotatedAway`.

## Scope

Every changed path is inside the TASK-SVC-004 Allowed paths; no scope
supplement was needed. Two cleanups were identified and deliberately not taken
— the now production-dead `SessionSettings/**` directory, and the two
unreachable "unavailable" arms in the storage presentation — each with its
reason and, where applicable, the exact diff, in
[scope-review.md](scope-review.md). Nothing under `openspec/specs/**`,
`Catalog/**`, `openspec/changes/archive/**` or `AGENTS.md` changed, and
`openspec/contracts/app-product-capability-registry.yaml` (an export product
outside this Task's Allowed paths) was verified unchanged after every
regeneration.

## Verification

Commands ran from the repository root on 2026-09-05. Logs under the session
scratch directory are development logs, not hardware evidence.

| Command / check | Result |
| --- | --- |
| `sh Packages/ArkDeckKit/Scripts/run-swiftpm.sh build --build-tests` | PASS. |
| Focused suites: `SettingsApplicationFacadeContractTests`, `SettingsStorageDomainContractTests`, `SettingsStorageUIFixtureContractTests`, `RuntimeHistoryApplicationContractTests`, `LaunchAgentServiceContractTests`, `ArkForgeLaneInstallContractTests`, `ArkForgeFlashSessionContractTests`, `AgentdOptionCoverageContractTests`, `OpenHarmonyLocalSigningContractTests`, `CLIArgumentParserContractTests`, `CLIMachineContractTests`, `CLICommandRegistryCoverageContractTests` | PASS after the fixes below. |
| `arkdeck maintainer contracts export --contracts-directory openspec/contracts --fixtures-directory …/Fixtures/CLI` then `… contracts check …` | `drifted: (none)`, `missing: (none)`, `unexpected: (none)`, exit 0. The export touched `cli-command-registry.yaml`, `cli-feature-coverage.json`, `Fixtures/CLI/index.json` and removed the two `normalize` argv fixtures; no other export product moved. |
| `sh Packages/ArkDeckKit/Scripts/run-swiftpm.sh test --parallel` | **PASS**, exit 0: 2,444 cases, zero failures. |
| `python3 scripts/ci/plan.py --repo-root . --base-revision origin/main --head-revision HEAD --merge-base --include-worktree --run-local` | **PASS**, exit 0, on the committed tree. Public checks (planner tests, Agent PR workflow tests, `check_sdd` 0 errors / 0 warnings / 121 acceptance IDs, guard suites): PASS. Design-system lane: `npm ci` + `npm test`, 83 passing, 0 failing. Swift lanes: full-parallel 2,438 cases (exit 0, 78 s), process-identity race 1 case, Viewer scale 5 cases, all exit 0. App lane: `TEST BUILD SUCCEEDED`. Log: session scratch `svc004-unified-gate-final2.log`. An earlier run of the same gate on the same tree failed one case — `AgentClientDeadlineContractTests.testBlockedWritesCannotOutliveTheSameDeadline`, "fixture did not receive the expected connection" after its 10 s wall-clock budget — while the machine's 1-minute load average was 31.6 on 8 cores (Spotlight was reindexing the build output). That suite passes 9/9 in isolation and no changed path in this diff is reachable from it; the gate was rerun once the load settled below 12 and is reported here from that run, not from the loaded one. |
| `python3 scripts/check_pr_paths.py --repo-root . --preflight --base-revision origin/main --head-revision HEAD` | **PASS**: resolves exactly `TASK-SVC-004`, exit 0, on the committed diff (33 changed paths, all inside this Task's base-tree Allowed paths). Run with `--expected-head-ref agent/task-svc-004-single-v1-configuration-20260905 --allow-bootstrap --infer-task`. |

Development failures resolved before the final run:

- `RuntimeHistoryApplicationContractTests` pinned the deleted migration by
  source scan: it required at least four superseded-reply guards (the fourth
  was the migration's reconciliation) and the literal `toolkit` remap. It now
  requires three, asserts the file contains no `UserDefaults` and no
  `history.savedFilter` literal, and pins the generation binding by the symbols
  the current code actually uses instead of a string only the migration wrote.
- `testSDKReleasePresetUpdatesDaemonReceiptWithoutReadingOrReplacingKeychainItem`
  asserted that an explicit reinstall over an unsupported receipt deletes the
  previous managed material. It no longer does, and must not: reclaiming it
  would mean deleting installed material on the strength of a document this
  build could not read. The assertion is inverted with that reason.
- The credential-owner reference is content-derived, so reinstalling the same
  material republishes the same `credential:sha256-*`; a first draft asserted
  the opposite.

No UI assertion or device operation was executed: this Task changes host
configuration surfaces and their readers. App presentation changes are limited
to two `UserDefaults`/`@SceneStorage` key names and the removal of the History
migration, which the contract tests above cover by source scan; the App build
lane runs inside the unified gate. Hardware acceptance of the published product
remains SVC-005; no `REAL_DEVICE_PASS` is claimed and no historical Catalog
result is relabelled.

## Acceptance results

| Acceptance | Result and evidence |
| --- | --- |
| SVC-AC-09 current configuration | PASS on host fixtures. Per required case: **first configuration** — `SettingsStorageUIFixtureContractTests.testFixtureLaunchAnswersTheOwnerContractThroughTheProductionFacade`, `LaunchAgentServiceContractTests.testInstallReceiptAndPlistPinOneArkForgeBundle`, `OpenHarmonyLocalSigningContractTests.testCredentialOwnerPublishesPathFreeReferenceAndPinsExactOwners`. **Repeat configuration** — `testUninstallClearsAnEnvelopeThatAReinstallRotatedAway`, `testSDKReleaseInstallRepublishesOverARetiredACLReceiptWithoutMigratingIt`, the second `updateStoragePolicy` leg of the fixture test. **Upgrading the current build** — `testDaemonIdentityRebindSurvivesAKeychainThisProcessCannotRead`, `testPreservingUpdateCarriesTheCurrentBundleLaneForward`. **Read failure** — `testUnreachableSwitchFailsEveryRequestUntilItIsCleared`, `testAnUnusableReplyIsRefusedRatherThanRendered`, the `keychainUnreadable` legs. **Cancel** — modelled as a configuration that does not complete: `testPresetUpdateRestoresExistingKeychainSecretsWhenReceiptReplacementFails`, `testSDKReleasePresetFailurePreservesPreviousReceiptAndMaterial` and `testCredentialOwnerBlocksReplacementAndRemovalWhilePinned` (the mutation body never runs). An interactive password-prompt cancellation is not exercised by a host contract test and is not claimed. **Defaults** — `SettingsStorageUIFixture.publishedPolicy` is asserted distinct from `RuntimeSessionStorageStore.defaultPolicy`; `ApplicationIconChoice.defaultChoice` and `DebugWorkspaceTab.artifacts` are the first-run values behind the two renamed keys. **Resource conflict** — `testAStorageMutationThatLosesItsGenerationPublishesTheWinnersState`, `testFixtureOwnerRefusesStaleGenerationsAndUnpublishedMethods`, `testCredentialOwnerBlocksReplacementAndRemovalWhilePinned`. Retired preferences, retired lane names and retired receipt forms are ignored or refused by name and never trigger an implicit Runtime write; custom signing material, the installed Keychain item and installed material survive every refusal; no secret or material is deleted except by the explicit `remove` entry. All signing tests run against `MemorySigningSecretStore` and per-test temporary roots — the developer machine's real Keychain and installation state are not touched. |
| SVC-AC-10 complete delivery | PASS for this Task's share: generated CLI products are regenerated with zero drift, the current entries remain usable, and the single-format residual audit in [residual-audit.md](residual-audit.md) gives a per-line disposition — including five own-production compatibility hits outside this Task's Allowed paths, one of which (`RuntimeWorkspaceProjectStore`'s three-generation reader) belongs to no SVC Task and needs a maintainer decision. The change-wide product verification remains SVC-005. |
