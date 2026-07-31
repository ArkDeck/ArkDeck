<!-- GENERATED FILE - DO NOT EDIT BY HAND. -->
<!-- Source of truth: Catalog/operations/*.json; regenerate via scripts/catalog_gen/generate.py --write -->

# Operation effect / authorization matrix

Catalog digest: `ad5d5a348af394ede7b6898008e6dff32b49f2e0cc8d569728066622e73876b4`

| Operation | Provider | Effect (min → max) | Authorization | Default issuance | Binding | Concurrency | Timeout (s) | Output budget (bytes) |
| --- | --- | --- | --- | --- | --- | --- | --- | --- |
| `capture.diagnostics@1` | hdc | readOnly → deviceMutation | readOnly: defaultReadOnly; deviceMutation: standingCapability | enabled | confirmedDevice | device-exclusive | 900 | 536870912 |
| `debug.hap@1` | hdc | deviceMutation | deviceMutation: standingCapability | enabled | confirmedDevice | device-exclusive | 600 | 67108864 |
| `deploy.native-library.app-owned@1` | hdc | deviceMutation | deviceMutation: standingCapability | enabled | confirmedDevice | device-exclusive | 600 | 134217728 |
| `deploy.native-library.system@1` | hdc | destructive | destructive: oneShotExactPlan | disabled | confirmedDevice | device-exclusive | 1800 | 134217728 |
| `flash.dayu200@1` | rockchip | destructive | destructive: oneShotExactPlan | enabled | confirmedDevice | device-exclusive | 1800 | 134217728 |
| `observe.device@1` | hdc | readOnly | readOnly: defaultReadOnly | enabled | confirmedDevice | device-shared-readonly | 60 | 1048576 |
| `workspace.inspect-source@1` | workspace | hostOnly | hostOnly: defaultReadOnly | enabled | none | host-exclusive | 120 | 1048576 |

## Profiles

| Profile | Provider | Supported operations |
| --- | --- | --- |
| `dayu200@1` | rockchip | `observe.device@1`, `capture.diagnostics@1`, `debug.hap@1`, `deploy.native-library.app-owned@1`, `deploy.native-library.system@1`, `flash.dayu200@1` |
| `openharmony-standard@1` | hdc | `observe.device@1`, `capture.diagnostics@1`, `debug.hap@1`, `deploy.native-library.app-owned@1`, `deploy.native-library.system@1` |
| `workspace-host@1` | workspace | `workspace.inspect-source@1` |
