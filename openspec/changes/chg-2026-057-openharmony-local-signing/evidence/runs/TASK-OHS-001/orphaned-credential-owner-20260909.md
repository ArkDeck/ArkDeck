# A credential owner no preset record carries — 2026-09-09

Found on the reference host while clearing GJ-5's blocker for `TASK-SVC-005`.
This record covers the diagnosis, the repair and its verification on the
host; it does not mark `TASK-OHS-001` done and claims no journey result.

## What the host showed

Read on protected `main` `eadb46b8` (daemon `4153ec72…`, CLI built from
`8c6a376c`, `b34f888b…`), before anything was changed:

| Surface | Fact |
| --- | --- |
| `runtime signing status` | `credential:sha256-562430f169…`, `projectRef: "demo-app"`, **`referenceCount: 2`** |
| `workspace preset list --project project-fd677365f7bdefabda66a3c1` | signing `preset-23114ce6017f4fbdd8930bcc` `unresolved` (its credential is bound to `demo-app`, #1802/#1803); build, test and symbol presets `active` |
| `workspace project list` | exactly one project, `project-fd677365f7bdefabda66a3c1`; `workspace project show --project demo-app` → `workspaceReferenceNotFound` |
| `~/Library/Application Support/ArkDeck/Signing/OpenHarmony/credential-owner-v1.json` | `presetOwners: ["preset-3667528438767fb6b68fd0ad"]` after the live preset was removed |

The remedy the 2026-09-09 acceptance record names — reinstall the credential
against the registered project — was then tried through the product:

1. `workspace preset remove --mutation-request-id gj5-20260909-remove-stale-sign-preset --project project-fd677365f7bdefabda66a3c1 --preset preset-23114ce6017f4fbdd8930bcc --expected-generation 1` → exit 0, `configurationStatus: removed`, generation 2. `referenceCount` fell to **1**.
2. `runtime signing remove` → exit 1, `signing credential is referenced by an active workspace preset`.

The remaining owner, `preset-3667528438767fb6b68fd0ad`, is the signing preset
the 2026-09-02 window registered under the legacy `demo-app` root
(`docs/design/references/v1.6-goal/gj-headless-rerun-2026-09-02.json`,
`credentialSwap.newCredential.signingPreset`). That project and its presets
are not in the current store — the daemon state directory was retired since —
but the credential owner ledger lives beside the signing material, outside
the state directory, and kept the pin. `OpenHarmonySigningCredentialOwner.
ledgerForMutation` refuses `replace` and `remove` while any owner remains, and
the only release path is the preset store's own mutation of a preset it
carries. So the credential could be neither rebound nor removed: no product
path existed, and the reference host was stuck on it.

## The repair

`fix(signing): release credential owners no preset record carries
(TASK-OHS-001)`:

- `OpenHarmonySigningCredentialOwner.releaseOwners(absentFrom:)` drops every
  owner outside the set it is given and returns what it released.
- `ArkDeckAgentDaemonMain/main.swift` calls it at startup, after
  `presetCompositionRecords()` and before any preset resolves, with the
  preset references the store carries — only when the daemon owns the default
  state directory, because a daemon on a private `--state-dir` shares the
  ledger but not the store and must not judge the production pins. It prints
  what it released; an unreadable owner is reported to stderr and left to the
  per-preset resolution failure that already names it.
- Contract test `testCredentialOwnerReleasesOwnersTheStoreNoLongerCarries`:
  an absent owner is released, a carried owner still resolves and still
  blocks a rewrite, a second pass releases nothing, and once the store drops
  the last owner the credential can be replaced again.

`run-swiftpm.sh test --filter OpenHarmonyLocalSigningContractTests` → 34
tests, 0 failures.

## Verified on the host

Helper pair built from this branch with `build-local-helpers.sh` (CLI
`42c7b992…`, daemon `6e6c4df2…`), installed with `runtime service update
--daemon` at `2026-09-09T07:51:35Z`, exit 0; HDC, ArkForge lane and ArkTrace
descriptor preserved.

| Step | Result |
| --- | --- |
| daemon startup | `~/Library/Logs/ArkDeck/agentd.log`: `signing credential owner released presets no store record carries: preset-3667528438767fb6b68fd0ad` |
| `runtime signing status` | `referenceCount: 0` |
| `runtime signing install --build-profile … --project-ref project-fd677365f7bdefabda66a3c1 …` (same keystore, certificate, profile and `debugKey` as before) | exit 0, new `credential:sha256-2fa4fa4bcccf2d5867f960f18ab2a7c25691e43feba1607c949f950891096f7a`, `projectRef: project-fd677365f7bdefabda66a3c1` |
| `workspace preset register --registration-request-id gj5-20260909-sign-preset --kind signing --template openharmony.local-sign@1 --toolchain toolchain:sha256:9cee08f1… --toolchain-generation 1 --credential <new> --timeout-seconds 600` | exit 0, `preset-3cae17c26b7aca2c2bfba389`, `runtimeRestartRequired` |
| `runtime service restart` | exit 0 |
| `workspace preset list` | `preset-3cae17c26b7aca2c2bfba389` signing **`active`**; build/test/symbol `active` |
| `operation list` | **28 of 30 available**; `workspace.sign-openharmony-hap@1` `available`; only the two hardware-gated Flash entries remain `unavailable` |
| `runtime signing status` | `referenceCount: 1`, `projectRef: project-fd677365f7bdefabda66a3c1` |

Every step above is a published CLI leaf; no file under the signing root or
the state directory was edited by hand. Local captures:
`/private/tmp/arkdeck-gj-headless-20260909/gj5/10-*.json` … `20-*.json`.

## Residual

- The retirement of a state directory is what strands the owner; the startup
  reconciliation repairs it on the next start, so the stranded state no
  longer persists, but the retirement itself is not something this Task
  owns.
- `runtime signing status` still reports `ready: true` for a credential no
  registered project can use (its `projectRef` is the operator's diagnosis
  path); recorded under `TASK-SVC-005` as accepted for now.
