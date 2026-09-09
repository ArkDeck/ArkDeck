# Signing preset credential binding — 2026-09-09

An implementation record for `TASK-OHS-001`, Deliverable 2 (signing preset
install/status and availability diagnostics). It does not mark the Task done and
claims no device or real-signing result.

## What was wrong, found on the reference host

`workspace.sign-openharmony-hap@1` was the only non-Flash operation `unavailable`
on the host: 27 of 30 available, the other two being the hardware-gated Flash
pair. Its blocker had been carried as "the signing preset is stuck at
`runtimeRestartRequired` across a real restart", which was accurate and useless.

Read from the published surface, on protected `main` `c3a19631`:

| Command | Fact |
| --- | --- |
| `operation list` | `workspace.sign-openharmony-hap@1` unavailable, `workspace_preset_unavailable` |
| `workspace preset list --project project-fd677365f7bdefabda66a3c1` | signing preset `preset-23114ce6017f4fbdd8930bcc`, registered `2026-09-07T06:50:01Z`, `configurationStatus: runtimeRestartRequired`. The build and test presets on the same project and the **same** toolchain `toolchain:sha256:9cee08f1…` are `active`, so the toolchain resolves |
| `runtime signing status` | credential `credential:sha256-562430f169…` `state: available`, `ready: true`, `diagnostics: []`, and `projectRef: "demo-app"` |
| `workspace project list` | exactly one registered project, `project-fd677365f7bdefabda66a3c1`. There is no `demo-app` |

A `signing` preset resolves at start-up only if its credential's own
`projectRef` equals the preset's; otherwise the resolver throws `resourceConflict`,
"signing credential project binding changed", and records
`workspacePresetResolutionFailures[presetRef]`. A preset with an entry there is
never marked applied, and an unapplied preset was projected as
`runtimeRestartRequired`.

So the credential installed on 2026-09-02 is bound to a project reference that no
longer exists, and the product answered every enquiry with a remedy that could
not work. The reason existed in the daemon and reached no surface: `doctor`
returned nine findings and none concerned the preset, and
`~/Library/Logs/ArkDeck/agentd.log` recorded `workspace ProjectProfiles ready for
project-fd677365f7bdefabda66a3c1` with nothing about the preset that failed.

## What changed

Two halves of one defect: registration failed open, and the projection failed
silent.

- `RuntimeWorkspaceCredentialPinning.acquire` now carries the project the preset
  belongs to. The credential owner is the only party that can compare a
  credential's own binding with the preset's, and it was being asked to pin
  without being told the project. The daemon's owner closure now reads the
  credential's receipt — without `owner:`, because the preset does not own it
  yet, and with `requireSecrets: false`, because the binding is on the receipt
  and reading secrets would summon a Keychain prompt to answer a question that
  does not need one — and refuses a mismatch by naming both project references.
  Registration now fails where the operator is standing, with the same rule
  start-up applies, so the two cannot disagree.
- `RuntimeWorkspaceProjectStore` keeps the start-up resolution failures and
  projects an unapplied preset that has one as `unresolved` rather than
  `runtimeRestartRequired`. A preset merely registered since the last start is
  still `runtimeRestartRequired`, which is true for it.

`configurationStatus` is an unconstrained string in
`spec/control/methods/workspace.preset.list.json`, and the only production
consumers compare it against `"active"` and `"removed"`
(`AgentDaemon.swift:2604,2613`), so the new value needs no schema or consumer
change. The preset item is `additionalProperties: false`, so the failure text
itself has no published field to travel in; that is named below rather than
smuggled into the status string.

## Checks

- A preset registered and not yet applied reports `runtimeRestartRequired`;
  applied, `active`; unapplied with a recorded resolution failure, `unresolved`;
  and another preset's failure does not change it. Both the single-preset and
  list projections are asserted.
- Credential pinning receives `(credentialRef, presetRef, projectRef)`, which is
  what makes the registration refusal possible at all.
- Negative control: with the projection reverted, both new assertions fail with
  `("runtimeRestartRequired") is not equal to ("unresolved")`.
- 265 tests across the workspace store, daemon, workspace and signing suites
  pass, including the existing register/update assertions that
  `runtimeRestartRequired` is what a freshly registered preset reports.

These are host contract tests. No credential was installed, removed, migrated or
entered, no preset was registered on the host, and the reference host's broken
binding is untouched.

## Not fixed here

- The failure text still has no published field on the preset resource. Adding
  one means changing `workspace.preset.list`/`show` and re-deriving from a
  recorded frame; `unresolved` removes the false remedy but does not yet carry
  the reason.
- `runtime signing status` reports `ready: true` for this credential. That is not
  a lie in its own terms — it is a credential-local probe with no view of
  registered projects — but nothing in the product joins "installed and readable"
  to "no registered project can use it".
- `docs/design/cli-workspace-preset-toolchain-lifecycle.md:94` describes only the
  `runtimeRestartRequired` projection. `docs/design/**` is not in this Task's
  Allowed paths, so the sentence is left for whoever owns that file.

## The host's own preset

Unchanged by this work. It needs the credential rebound to the registered
project — `runtime signing install --project-ref project-fd677365f7bdefabda66a3c1`
with the same keystore, certificate, profile and key alias. That needs the
credential material and its passwords, so it is a maintainer action.
