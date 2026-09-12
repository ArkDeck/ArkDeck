# Import upload Target owner integration — 2026-09-12

The merged upload PR candidate includes published main `4e2a615e421e6174a4a50e2c8110196d77ce7007`, including the Target owner from #1870 and Artifact export from #1874. The former integration proposal has now been implemented through that existing owner. The Import diff retains the published Export implementation and excludes the HAP publication prototype at `708dab9a`.

`TargetStore::resolve_import_binding(&ImportIntent)` uses the owner's existing locked transaction and strict `TargetDocument` decoder. It finds the exact durable Target ID and requires the intent revision to match before returning a typed `ImportBinding`. It neither modifies Target binding/alias documents nor accepts wire-supplied binding, connect key, observation, capability, or validation facts. The daemon composes this method directly into the Import owner's new-request resolver; existing exact request identities remain rediscoverable without resolving a new binding.

| Kind | Snapshot from the actual existing owner |
| --- | --- |
| `workspace-patch` | Exact Target ID, omitted binding revision and identity digest, after verifying the intent's durable revision. |
| `flash-bundle` | Exact Target ID/revision and durable physical identity digest. |
| `hap`, `native-library`, without a canonical alias | Exact Target ID/revision and SHA-256 of the adopted connect key. This is the current Swift `hdcExecutionRoute` rule for a Target without a proven alias; its physical digest is not substituted. |
| `hap`, `native-library`, with a canonical alias | `operationUnavailable` until the live alias route owner is composed. The presentation digest and an unobserved fallback do not supply that owner. |

Missing or stale Target bindings return `resourceConflict`; malformed, duplicated or unsafe documents return `recordUnreadable`; absent required owners return `operationUnavailable`. The Import owner normalizes error provenance to `importOwner` with zero device dispatch. Wire parameters remain closed, including rejection of caller binding/App provenance injection.

Actual Swift Target fixture bytes are retained under `rust/tests/fixtures/import-target-current`, with original paths and SHA-256 values in `provenance.json`. The direct fixture intentionally has different physical and connect-key digests; the Rust test and daemon/CLI process test check that HAP stores the route digest. Alias fixtures test bounded unavailability and refusal of corrupted durable proof. The source files are host-only fixtures, not fresh hardware facts or device acceptance.

This API only opens an upload lifetime. It does not inspect or publish file contents. Commit, release and Job-reference inspection remain explicitly unavailable; the CLI's `artifact import inspect` continues to mean `artifact.import.inspection` and never falls through to ordinary Artifact inspection. HAP/native/patch/Flash validators, lease/reference census, active materialization holds, installed owner activation and GJ acceptance are outside this PR.
