# The migration that turned off four operations — 2026-09-08

- Task: TASK-AFA-001 (the only Task that declares
  `Packages/ArkDeckKit/LaunchAgents/LaunchAgentService.swift`).
- Base: protected `main` `abc24e1d` (#1786).
- Found while installing helpers repeatedly through `runtime service update
  --daemon` for the AFA-001 and SVC-005 real-host work.

## Measured on the reference host

`operation list` on the installed Runtime, digest `508783ac…`:

| Operation | Availability | Reason |
| --- | --- | --- |
| `analyzer.summarize-hilog@1` | unavailable | `analyzer.profileUnavailable` |
| `analyzer.extract-crash-signature@1` | unavailable | `analyzer.profileUnavailable` |
| `workspace.symbolize-crash@1` | unavailable | `workspace.symbolPresetUnavailable` |
| `workspace.inspect-source@1` | unavailable | `no_workspace_inspector_configured` |

Every reason blames configuration the operator is supposed to supply. The
operator had supplied it. `workspace preset list --project
project-fd677365f7bdefabda66a3c1` shows the symbol preset
`preset-cbeb3954de5b7119e638ddbc` as `configurationStatus: active`, carrying
`constraints.relativeSourceMap =
entry/build/default/outputs/default/mapping/sourceMaps.map`, and the project
itself is `available` with build, patch, checkpoint and diff operations all
`available`.

What is actually missing is in the LaunchAgent:

```text
EnvironmentVariables => {
  ARKDECK_ARKFORGE_BUNDLE_PATH => …
  ARKDECK_ARKTRACE_DESCRIPTOR  => …
  ARKDECK_HDC_PATH             => …
}
```

No `ARKDECK_ANALYZER_PATH`, no `ARKDECK_WORKSPACE_INSPECTOR` — after several
`runtime service update --daemon` runs today.

## Why

`LaunchAgentService` writes both keys **inside `if let workspace`**, alongside
the retired `ARKDECK_WORKSPACE_PROJECTS` / `ARKDECK_WORKSPACE_ACTIVE_PROJECT` /
`ARKDECK_DEVECO_SDK_HOME` trio. Neither belongs to that trio: the analyzer path
is this installation's own daemon in one-shot mode, and the inspector is a fixed
system tool.

Once the product moved to Runtime-owned workspace registration, the headless
runbook began telling operators to run `runtime service update` **omitting**
those legacy path parameters. Doing exactly that drops the analyzer and the
inspector too, and four published operations go dark.

The reader had the same coupling: it treated all five keys as one closed
bundle, so a plist carrying the analyzer without the trio was refused as
"workspace environment must be the closed demo-app ProjectProfile
configuration".

`testTargetUpdateMigratesOutOfTheLegacyWorkspaceConfiguration` asserted that all
five keys disappear, so the behaviour was pinned rather than caught. The only
test that ever asserted `ARKDECK_ANALYZER_PATH` was written
(`testInstallPersistsValidatedWaterFlowWorkspaceForHeadlessGJ5AndUpdateKeepsIt`)
supplies the retired pair — the configuration the runbook now tells operators
not to use.

## Repair

The writer sets both keys unconditionally, from `daemonPath` and the fixed tool
path. The reader validates each independently: present-and-equal or absent,
never "present implies a workspace". Every real invariant survives — a workspace
trio must still be complete and closed, the analyzer must still be exactly this
daemon, and the inspector must still be exactly the registered host tool — and
two new named refusals cover an analyzer or inspector that is present but wrong.

## One existing assertion changed, deliberately

`testTargetUpdateMigratesOutOfTheLegacyWorkspaceConfiguration` now asserts that
the three retired keys are gone **and** that the analyzer and inspector survive,
still pinned. Its subject — migrating out of the legacy workspace injection —
is unchanged; what changed is that it no longer requires two unrelated host
facts to be destroyed along with it. That requirement is the defect.

## Verification

`LaunchAgentServiceContractTests` 25/25. New
`testInstallAndUpdateWriteTheAnalyzerAndInspectorWithoutTheRetiredWorkspacePair`
installs and then updates with no workspace argument and asserts both keys are
written both times, and that the three retired keys stay absent so this is not a
way to reintroduce them.

Not verified here: the four operations have not been observed flipping to
`available` on the reference host. That needs this merged, a helper rebuilt from
protected `main`, and a `runtime service update`; it belongs to the TASK-SVC-005
run record. GJ-5 has other prerequisites besides these four — the signing preset
on this host reads `configurationStatus: runtimeRestartRequired` and does not
clear across a real `runtime service restart` — and this change does not address
that.
