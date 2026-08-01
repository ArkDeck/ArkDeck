<!-- GENERATED FILE - DO NOT EDIT BY HAND. -->
<!-- Source of truth: Catalog/operations/*.json; regenerate via scripts/catalog_gen/generate.py --write -->

# Operation effect / authorization matrix

Catalog digest: `7a4c0081f1ae653ce1201d779ae8465b2a3bd7cad2583b4cae3a7d7e7469c33f`

| Operation | Provider | Effect (min → max) | Authorization | Default issuance | Binding | Concurrency | Timeout (s) | Output budget (bytes) |
| --- | --- | --- | --- | --- | --- | --- | --- | --- |
| `analyzer.extract-crash-signature@1` | analyzer | hostOnly | hostOnly: defaultReadOnly | enabled | none | host-exclusive | 120 | 67108864 |
| `analyzer.summarize-hilog@1` | analyzer | hostOnly | hostOnly: defaultReadOnly | enabled | none | host-exclusive | 120 | 67108864 |
| `analyzer.summarize-trace@1` | analyzer | hostOnly | hostOnly: defaultReadOnly | enabled | none | host-exclusive | 120 | 67108864 |
| `capture.diagnostics@1` | hdc | readOnly → deviceMutation | readOnly: defaultReadOnly; deviceMutation: standingCapability | enabled | confirmedDevice | device-exclusive | 900 | 536870912 |
| `debug.hap@1` | hdc | deviceMutation | deviceMutation: standingCapability | enabled | confirmedDevice | device-exclusive | 600 | 67108864 |
| `deploy.native-library.app-owned@1` | hdc | deviceMutation | deviceMutation: standingCapability | enabled | confirmedDevice | device-exclusive | 600 | 134217728 |
| `deploy.native-library.system@1` | hdc | destructive | destructive: oneShotExactPlan | disabled | confirmedDevice | device-exclusive | 1800 | 134217728 |
| `flash.dayu200@1` | rockchip | destructive | destructive: oneShotExactPlan | enabled | confirmedDevice | device-exclusive | 1800 | 134217728 |
| `observe.device@1` | hdc | readOnly | readOnly: defaultReadOnly | enabled | confirmedDevice | device-shared-readonly | 60 | 1048576 |
| `workspace.apply-patch@1` | workspace | deviceMutation | deviceMutation: standingCapability | disabled | none | host-exclusive | 180 | 16777216 |
| `workspace.build-openharmony@1` | workspace | deviceMutation | deviceMutation: standingCapability | disabled | none | host-exclusive | 900 | 134217728 |
| `workspace.create-checkpoint@1` | workspace | deviceMutation | deviceMutation: standingCapability | disabled | none | host-exclusive | 120 | 1048576 |
| `workspace.inspect-diff@1` | workspace | hostOnly | hostOnly: defaultReadOnly | enabled | none | host-exclusive | 60 | 1048576 |
| `workspace.inspect-git-status@1` | workspace | hostOnly | hostOnly: defaultReadOnly | enabled | none | host-exclusive | 60 | 1048576 |
| `workspace.inspect-source@1` | workspace | hostOnly | hostOnly: defaultReadOnly | enabled | none | host-exclusive | 120 | 1048576 |
| `workspace.read-source-range@1` | workspace | hostOnly | hostOnly: defaultReadOnly | enabled | none | host-exclusive | 60 | 1048576 |
| `workspace.revert-patch@1` | workspace | deviceMutation | deviceMutation: standingCapability | disabled | none | host-exclusive | 180 | 16777216 |
| `workspace.run-tests@1` | workspace | deviceMutation | deviceMutation: standingCapability | disabled | none | host-exclusive | 900 | 134217728 |
| `workspace.symbolize-crash@1` | workspace | hostOnly | hostOnly: defaultReadOnly | enabled | none | host-exclusive | 300 | 67108864 |

## Profiles

| Profile | Provider | Supported operations |
| --- | --- | --- |
| `dayu200@1` | rockchip | `observe.device@1`, `capture.diagnostics@1`, `debug.hap@1`, `deploy.native-library.app-owned@1`, `deploy.native-library.system@1`, `flash.dayu200@1` |
| `openharmony-standard@1` | hdc | `observe.device@1`, `capture.diagnostics@1`, `debug.hap@1`, `deploy.native-library.app-owned@1`, `deploy.native-library.system@1` |
| `workspace-host@1` | workspace | `workspace.inspect-source@1`, `workspace.apply-patch@1`, `workspace.build-openharmony@1`, `workspace.run-tests@1`, `workspace.symbolize-crash@1`, `workspace.revert-patch@1` |
