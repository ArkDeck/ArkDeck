# TASK-SVC-002 necessary scope supplement

The attached patch records three production paths missing from the original Task allowlist, before scope PR #1738:

- `Packages/ArkDeckKit/Sources/ArkDeckCLI/ArkDeckCLIMain.swift`: remove historical Flash/campaign inspection handlers together with the retired storage readers. Raw files remain in place; current Job/Session readers remain available.
- `Packages/ArkDeckKit/Sources/ArkDeckCLI/CLICommandRegistry.swift`: remove the four obsolete command spellings from help, completion and registry. Current Flash execution and reconciliation through Runtime Job resources remain unchanged.
- `Packages/ArkDeckKit/Sources/ArkDeckAgentDaemonMain/main.swift`: remove mounting the retired ledger, and wire the current mutation-state continuity validation before capability issuance/consumption. The guard also inspects the configured and default Session roots without rewriting their bytes. A test state-root override may still serve reads but cannot open a new mutation lane.

Regeneration also requires `openspec/contracts/cli-command-registry.yaml` and `openspec/contracts/cli-feature-coverage.json`; related CLI fixtures are already allowed by the Task. These are derived output changes, produced by the existing exporter after the source patch is accepted. No path-checker, policy, Catalog or safety acceptance change is proposed.

Status: user accepted this scope supplement on 2026-09-05. The production patch is applied, with the binding-function correction below; final unified verification passed. Scope PR #1738 subsequently merged as `ac8681dd72f0bcc48a8f6b1778aefcbc39a0e3e8`, adding the five reviewed paths to the implementation base.

The final implementation preserves the existing `runInstallBinding` function
unchanged. The review patch accidentally included that function between retired
helpers; the CLI build caught its live caller and the function was restored
before verification. The accepted removal covers the four archive spellings,
not the current binding command.

The follow-through after scope review removes the now-unreachable historical archive/reconciler/Agent-authority ledger models and their positive compatibility-only fixtures. Current capability-store lineage and crash tests remain. `RockchipFlashSessionRunLock` has no current producer outside that retired reconciler; the inventory includes its callers rather than inferring from its filename.
