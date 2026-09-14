# Map-valued members in the control method schemas — macOS, 2026-09-14

TASK-XPA-014 remains in progress. The change was written on protected main `1b31a53f` (#1923) and
rebased four times as main moved while its PR was open. The gate section says which tree each
gate run covered:

- Onto `82dba0c3` and `cdfd18ad` (#1926, #1927): no contract input changed and nothing conflicted
  (gate r1).
- Onto `eedc0a0a` (#1924, #1920, #1928): no contract input changed. `tasks.md` conflicted where
  both sides had appended a TASK-XPA-014 entry, and both entries were kept (gate r2, stopped when
  main moved again).
- Onto `1c0d7273` (#1930): nothing conflicted (gate r3, stopped when #1925 merged).
- Onto `382c5a30` (#1925, the agent execution oracle): #1925 had changed the generator's corpus
  selection, re-derived `agent.run`, `agent.status`, `artifact.list`, `job.plan` and `job.result`,
  and regenerated the manifest. This change landed second, so it re-derived its schemas on top of
  #1925's (see "Re-derivation on 382c5a30") and ran gate r4.

The defect was found while porting `capability.list` and `capability.inspect` to the isolated Rust
composition: `capability-read-run.md` recorded that "a capability's input maps stay closed to the
recorded names, as a Job's inputs are". This change touches no installed state and no device.
Every frame it uses is either committed or recorded by a Swift contract test in a temporary
directory.

## Defect

`generate-control-contract.py` derived every JSON object in a method schema as
`additionalProperties: false`, with `properties` holding the union of the member names its frames
recorded (`infer`). For members that are maps keyed by caller data, this published only the
sampled names. The Rust control layer validates every answer against the published method schema
before writing it (`arkdeck-control/src/lib.rs`, the `conforms` check after the method routes).
It replaces a nonconforming answer with `internalError` "the result does not conform to the
current contract". `arkdeck-contract/src/schema.rs` accepted only a boolean `additionalProperties`.
The Swift daemon validates no answer, so a Job or capability read that Swift answered failed on
Rust whenever its keys differed from the samples.

Concrete case: capture.diagnostics@1 declares 22 inputs, and its runbook sends
`{"durationSeconds": 5}`. On `1b31a53f`, `durationSeconds` was missing from three sampled key
sets: `job.show`'s `request.inputs` (15 names), `job.result`'s `evidence.parameters` (12) and
`job.plan`'s `inputs` (9). The Rust daemon would therefore refuse to plan the Job that M1's next
Rust slice runs, and to show it or report its result. #1925 later added `durationSeconds` to the
`job.plan` and `job.result` samples as one more recorded name. The other inputs stayed refused
there, and `job.show` still refused `durationSeconds` itself. The same held for a capability
whose exact inputs, input constraints or exact Artifact facts named anything the capability-read
oracle had not stored.

## The reviewed list

`MAP_VALUED_MEMBERS` in the generator, each entry checked against the Swift type that encodes the
member:

| Method | Member (path from `$defs`) | Swift type |
| --- | --- | --- |
| `agent.run` | `request.inputs` | `RuntimeAgentExecutionRequest.inputs: [String: JSONValue]` |
| `capability.inspect` | `result.capability.inputConstraints` | `RuntimeCapability.inputConstraints: [String: RuntimeCapabilityInputConstraint]` |
| `capability.inspect` | `result.capability.exactInputs` | `RuntimeCapability.exactInputs: [String: JSONValue]?` |
| `capability.inspect` | `result.capability.exactArtifactFacts` | `RuntimeCapability.exactArtifactFacts: [String: String]?` |
| `job.evidence` | `result.parameters` | the evidence document's `parameters: [String: JSONValue]` (`RuntimeJobEngine`) |
| `job.plan` | `result.inputs` | `RuntimePlanOnlyPreview.inputs: [String: JSONValue]` |
| `job.result` | `result.evidence.parameters` | as `job.evidence` |
| `job.show` | `result.request.inputs` | `RuntimeOperationRequest.inputs: [String: JSONValue]` |
| `job.show` | `result.request.clientContext.provenance` | `RuntimeClientContext.provenance: [String: String]?` |

`job.status` and `job.list` carry none of these members: their projections hold no request,
evidence or capability.

Reviewed and kept closed:

- `operation.describe` `result.exampleRequest.inputs` is a `[String: JSONValue]`, but it is keyed
  by the Catalog's required input names, which the build fixes. `arkdeck-control`'s
  `operation_description` test validates the description of every Catalog operation against the
  published schema, so a new Catalog input fails a test rather than a read. Re-deriving it would
  also narrow its schema (see the first derivation).
- `operation.describe` `result.authorization` is keyed by effect class, a closed vocabulary of
  four names, all of them published.
- `artifact.import.*` `metadata` and `trace.inspect` `schema.provenance` are records with every
  member required.
- `humanAction.selectionSchema` (in `agent.*`, `human-action.*`, `runtime.hdc.restart` and
  `runtime.tool.select`) is published as `{"type": "null"}` because only null was recorded. That
  is a different gap, a schema document rather than a map, and is not addressed here.

## What changed

- Generator: `infer` threads the path of the samples it is given. An object at a listed path is
  derived as `{"type": "object", "additionalProperties": <infer of every sampled value>}`, with no
  `properties` and no `required`, or `additionalProperties: false` if only empty maps were
  recorded. Every other object is derived exactly as before. A list entry that names an
  unpublished method stops the derivation, and a listed member that no frame reaches is reported
  on stderr. On `382c5a30` the generator also carries #1925's retention of a corpus frame for every
  recorded refusal code, unchanged. The two changes sit in different functions and merged without a
  conflict.
- Rust `arkdeck-contract/src/schema.rs`: the schema self-check recurses into a schema-valued
  `additionalProperties`, so unknown vocabulary cannot hide there. The validator holds every
  undeclared member to that schema; `false` still refuses the member and `true` still admits it.
- `rust/scripts/generate-contract.py`: `check_vocabulary` does the same, so the Rust bindings
  accept the new schemas.
- Swift `JSONSchemaSubset` (`CLIMachineContractTests.swift`), which `ControlMethodSchemaContractTests`
  uses: validates each undeclared member against an object `additionalProperties`. The other
  tests that use it (CLI, diagnostics and durable-storage contracts) load no schema with a
  schema-valued `additionalProperties`. Only `openspec/contracts/workflow-step.schema.json` has
  one, and no test hands it to this validator.
- `spec/control/README.md` and `docs/design/cli-machine-contracts.md` name the exception to the
  closed-object rule.

## Re-derivation

### First derivation (on `cdfd18ad`)

A trial came first. The unchanged generator, run over the committed corpus alone, reproduced the
`$defs` of 87 of the 105 methods, including `capability.inspect`, `job.show`, `job.evidence`,
`job.result` and `agent.run`. It narrowed 18 others. Most of them lost refusal codes that no
corpus frame carried, because the corpus then kept one frame per shape. `job.plan` lost
`admissionDenied`, `inputTooLarge` and `operationUnavailable`. `operation.describe` gained a
request requirement and lost value types and three example-input names.

`job.plan` was therefore derived from the corpus together with the frames its Swift oracle
records. Every other listed method was derived from the committed corpus alone:

```bash
ARKDECK_CONTROL_FRAME_LOG=<frames> sh Packages/ArkDeckKit/Scripts/run-swiftpm.sh test --filter JobPlanAnalyzerOracleContractTests
# <source> = Fixtures/ControlFrames/*.jsonl + <frames>/control-frames-*.jsonl (71 job.plan frames)
python3 Packages/ArkDeckKit/Scripts/generate-control-contract.py --derive-method-schemas <source>
git checkout HEAD -- Packages/ArkDeckKit/Tests/ArkDeckContractTests/Fixtures/ControlFrames \
  Packages/ArkDeckKit/Sources/ArkDeckCore/ControlProtocolGenerated.swift <every other method schema>
python3 rust/scripts/generate-contract.py --write
python3 rust/scripts/generate-contract.py --check
```

- The oracle run passed 1 test in compare mode, so its fixture is unchanged. It recorded 71
  `job.plan` frames and no frame of any other method: 4 planned, 59 `invalidInput`, 5
  `operationUnavailable`, 2 `admissionDenied` and 1 `inputTooLarge`. Frames file SHA-256
  `b10768bb2a853718de4e63ea825c22756e6dfeed54374e6d0872bd73259916ab`.
- That derivation read 709 frames (638 committed and 71 recorded), and a second run reproduced it
  byte for byte. The structural check described below passed against `cdfd18ad` (output SHA-256
  `4a7101791f2b066053883882a51b5962282aa4ebbd965e7639c5470fd57d93b6`).

### Re-derivation on `382c5a30`

The rebase took `agent.run.json`, `job.plan.json`, `job.result.json` and
`spec/baselines/swift-single-v1.json` from `382c5a30`. The six schemas were then re-derived with
the procedure above:

- The source was the committed corpus at `382c5a30` together with the same 71 `job.plan` frames,
  733 frames in all. The corpus holds 662 frames, including #1925's oracle shapes and a frame for
  every refusal code its shape selection had dropped. The job.plan oracle and its fixture are
  unchanged since the recording. The corpus now carries a frame for `job.plan`'s `admissionDenied`
  and `operationUnavailable`. It still has none for `inputTooLarge`, whose only frame exceeds the
  generator's 64 KiB sample bound, so the recorded frames were still needed.
- Every corpus file and every other schema was restored. `generate-contract.py --write`, then
  `--check`, reported 105 methods and 662 recorded shapes.
- `capability.inspect`, `job.evidence` and `job.show` came out byte-identical to their first map
  versions, since #1925 did not change their corpus. `agent.run`, `job.plan` and `job.result`
  changed only at their listed members.

A structural check against `382c5a30` passes. It ran `verify-maps.py <checkout> origin/main`
(scratch; script SHA-256 `3b6c04d6e135f5addef119cf5ae85196d36a1f4ef8da7413de225ffbeb710959`,
output SHA-256 `d44027d19316ab2f97a44592afb8b3d6c6a04e4b0e11599c0496c40148761172`):

- The committed corpus equals `382c5a30`'s, and only the six listed methods' schemas differ from
  it.
- Their top-level fields are unchanged apart from `x-arkdeck-sampleCounts`.
- `$defs` is identical to `382c5a30`'s everywhere except at the nine listed members. Every
  refusal code and shape #1925 published therefore stays, among them `job.plan`'s
  `admissionDenied`, `inputTooLarge` and `operationUnavailable` and the five codes #1925 added to
  `agent.run`.
- Each listed member is exactly `{"type": "object", "additionalProperties": V}`, and every
  per-member schema `382c5a30` published there is admitted by `V`. That includes
  `durationSeconds`, an integer, which #1925 had added to `job.plan` and `job.result`.

The one reported exception is `traceCategories` in `job.show`'s request inputs. Only empty arrays
had been recorded for it, so main published `{"type": "array"}` with no item schema. The map holds
array items to strings, which are what the other inputs' recorded arrays hold. Every array input
the Catalog declares is a `stringArray` (7) or an `artifactLeaseArray` (1), so no value a
Catalog-conforming Job holds is refused.

| Schema | SHA-256 |
| --- | --- |
| `agent.run.json` | `f69cf055307f25a6953f4a9aed86796970edc7e7fb96c6bfd3b37cedf3d1ebae` |
| `capability.inspect.json` | `64889a0fe0505735a3f062c014d19df06006c8171c62bbdeef3a1648275f497e` |
| `job.evidence.json` | `035dabe849b9228ef805bcd58f0151d4eac4c47d1d81042434de990586e315f7` |
| `job.plan.json` | `c79ecae26044ee6c2926a25523edead74a0bdce41af6bbdfbd46ab80c1d8794a` |
| `job.result.json` | `78d90363f2d6d157d65af2637fcdf5dcb5473687bfd3c296c4fd1ce6956167c7` |
| `job.show.json` | `ab5328585c6459512b6fbc7ee8065cbbd06ec99f617efd2bd56f06569301bb3e` |

Each schema's `x-arkdeck-sampleCounts` now counts the frames of this derivation:

| Method | On `382c5a30` (request/result/error) | This change |
| --- | --- | --- |
| `agent.run` | 38 / 23 / 15 | 21 / 12 / 9 |
| `capability.inspect` | 13 / 11 / 2 | 11 / 9 / 2 |
| `job.evidence` | 32 / 30 / 2 | 21 / 19 / 2 |
| `job.plan` | 99 / 21 / 78 | 80 / 8 / 72 |
| `job.result` | 23 / 18 / 5 | 23 / 18 / 5 |
| `job.show` | 33 / 31 / 2 | 23 / 21 / 2 |

The published value schemas `V`:

| Member | `V` |
| --- | --- |
| `agent.run` `request.inputs`; `job.show` `request.inputs`; `job.result` `evidence.parameters`; `job.evidence` `parameters` (itself nullable) | array of strings, or boolean, integer or string |
| `job.plan` `inputs` | boolean, integer or string |
| `job.show` `request.clientContext.provenance` | string |
| `capability.inspect` `exactInputs` | the closed `{mode, partitions}` partition plan, or boolean or string |
| `capability.inspect` `exactArtifactFacts` | string |
| `capability.inspect` `inputConstraints` | the closed constraint record: `kind` required; `value`, `values`, `minimum` and `maximum` optional |

## Tests

- Rust: on the tree rebased onto `382c5a30`, `cargo fmt --all --check` and
  `cargo test -p arkdeck-contract -p arkdeck-control` all pass. That is `arkdeck-contract`'s
  library 15, `canonical_parity` 7, `catalog_parity` 1, `corpus_parity` 10, `framing_failures` 8
  and `imports` 5, and `arkdeck-control`'s library 1 and `read_only` 15. Warnings-denied Clippy on
  `arkdeck-contract` was clean on the first tree.
  - The new `a_schema_valued_additional_properties_types_every_undeclared_member` checks map
    values, declared members beside a map, closed records as values, `true` and `false`.
  - The self-check rejects unknown vocabulary and malformed values under `additionalProperties`.
  - `corpus_parity`'s two new tests take recorded results. On `capability.inspect`, an exact input
    name no capability recorded is accepted, a map value of an unrecorded type is refused, and an
    unknown member of the capability is refused. On `job.show`, `durationSeconds` is accepted and
    an unknown member of the request is refused. The published view of `check-contracts.py` runs
    these tests against the merge base's schemas, which predate the maps, so there, and only
    there, the acceptance may fail.
- Python: `rust/scripts/test_contract_checks.py`, 35 tests OK, with CI's pins PyYAML 6.0.3 and
  jsonschema 4.26.0 in a scratch venv. The vocabulary tests gained a map-values location and a
  schema-valued `additionalProperties` among the supported shapes. Every gate run repeats it.
- Swift, first tree: `run-swiftpm.sh test --filter 'ControlMethodSchemaContractTests|CLIMachineContractTests|DiagnosticsAndHAPContractTests|CurrentDurableStorageContractTests'`
  ran 149 tests with 0 failures (22, 5, 109 and 13). It ran with `ARKDECK_CONTROL_FRAME_LOG` on a
  directory holding the 71 recorded `job.plan` frames, so `testFramesRecordedByThisRunValidate`
  held them to the new `job.plan` schema. The new
  `testMapValuedMembersAcceptUnrecordedKeysWhileTheirRecordsStayClosed` proves the
  `capability.inspect` and `job.show` claims through the Swift validator. Log SHA-256
  `80da67ab56fe1a56c24e28e82bd33b287bf5f93a473535a1162b2411b9ab136d`.
- Swift, on `382c5a30`: the second run used
  `ARKDECK_CONTROL_FRAME_LOG=<a directory holding the 71 recorded job.plan frames> run-swiftpm.sh test --filter 'ArkDeckContractTests.(AgentExecutionOracleContractTests|CaptureDiagnosticsOracleContractTests|ControlMethodSchemaContractTests|JobPlanAnalyzerOracleContractTests|ObserveDeviceOracleContractTests|CLIMachineContractTests)'`.
  It ran 31 tests with 0 failures:
  - the agent execution, capture.diagnostics, job.plan and observe.device oracles in compare mode;
  - `ControlMethodSchemaContractTests` (5), whose `testFramesRecordedByThisRunValidate` checked
    the frames recorded before it ran;
  - `CLIMachineContractTests` (22).

  The run recorded 156 more frames. Together with the 71 `job.plan` frames, that is 227 frames:
  `agent.run` 11, `agent.status` 5, `artifact.list` 17, `job.evidence` 10, `job.plan` 156,
  `job.result` 10, `job.run` 10 and `job.submit` 8. Every one validates against the new schemas
  under the reference validator (jsonschema 4.26.0, Draft 2020-12): request, result, error code
  and error details. Log SHA-256
  `06496b1530530175ae0d982633c1b90cba6309f49a9400231fe90cab250c1045`.

## Unified local gate

The gate command was
`python3 scripts/ci/plan.py --repo-root . --base-revision origin/main --head-revision HEAD --merge-base --include-worktree --run-local`.
The planner ran from a scratch venv holding CI's pins (PyYAML 6.0.3, jsonschema 4.26.0), with
`ARKDECK_PYTHON` on the shared SDD venv. That venv lacks `jsonschema`, but the planner runs the
Rust lane's scripts with its own interpreter. `plan.py --run-local` runs every command with
`check=True`. It returns 1 and prints `ci-plan: ERROR` at the first failure, and this checkout's
planner prints no `gate exit=` line itself. Each log therefore ends with the wrapper's
`planner exit=<code>`.

- r1 ran on `2297967e` against merge base `cdfd18ad` (#1927), from 07:11:57Z to 07:23:46Z,
  starting at a load of 3.48 / 7.04 / 9.56. Scratch log
  `xpa014-map-valued-members-gate-20260914-r1.log`, SHA-256
  `e2feaf5f000677f35527aca49a5ea0aebdb34ab91a590f1631132a97c83a7121`. The planner classified 19
  changed files and selected the common, design-system, Swift and Rust lanes (no App build).
  - Common checks:
    - planner tests: 37 OK;
    - agent-PR workflow tests: 12 OK;
    - SDD: 0 errors, 0 warnings, 121 acceptance IDs;
    - Catalog generator tests: 49 OK, and `--check` passed;
    - design-system tests: 83 passed, 0 failed;
    - SwiftPM runner tests: 13 OK.
  - Swift full lane: `full-parallel` 2,666 tests exit 0 in 194 s, `full-process-identity-race`
    1 test exit 0 and `full-viewer-scale` 5 tests exit 0.
  - Rust lane:
    - `generate-contract.py --check`, `cargo fmt --all --check` and warnings-denied Clippy passed;
    - workspace tests passed;
    - `test_contract_checks.py`: 35 tests OK;
    - `check-contracts.py` passed both views. In the published view, the merge base's schemas
      still close the listed members; there the three new Rust tests pass, the two
      `corpus_parity` ones through their published-view allowance. In the candidate view they
      assert acceptance. The candidate process harnesses passed, as did `test-macos-facade.py`
      (7 tests OK);
    - `cargo deny`: advisories, bans, licenses and sources ok;
    - `cargo vet`: 36 fully audited.
  - Result: the planner exited 0, and the log has no `ci-plan: ERROR` line.
- r2 ran on `6c11649a` against merge base `eedc0a0a`. It was stopped in its Rust lane when #1930
  merged, after its Swift lane had passed. No verdict is claimed for it.
- r3 ran on `665e0852` against merge base `1c0d7273`. It was stopped in its Rust lane when #1925
  merged. No verdict is claimed for it.
- r4 ran on `66ecd691`, the re-derivation on `382c5a30` before this result was added here,
  against merge base `382c5a30`. It ran from 08:40:38Z to 08:56:06Z, starting at a load of
  125.25 / 63.24 / 41.64 from other sessions' work. It was run straight away, without waiting for
  the load to fall. Scratch log `xpa014-map-valued-members-gate-20260914-r4.log`, SHA-256
  `6322e2f8906967f25cf460653276791f898c9a716e6e94c77234b9985ed80821`. The planner classified 19
  changed files and selected the same four lanes.
  - Common checks:
    - planner tests: 37 OK;
    - agent-PR workflow tests: 12 OK;
    - SDD: 0 errors, 0 warnings, 121 acceptance IDs;
    - Catalog generator tests: 49 OK, and `--check` passed;
    - design-system tests: 83 passed, 0 failed;
    - SwiftPM runner tests: 13 OK.
  - Swift full lane: `full-parallel` 2,669 tests exit 0 in 155 s, `full-process-identity-race`
    1 test exit 0 and `full-viewer-scale` 5 tests exit 0.
  - Rust lane:
    - `generate-contract.py --check`, `cargo fmt --all --check` and warnings-denied Clippy passed;
    - workspace tests passed;
    - `test_contract_checks.py`: 35 tests OK;
    - `check-contracts.py` passed both views, with the three new Rust tests passing in the
      workspace run, the published view and the candidate view. The candidate process harnesses
      passed, as did `test-macos-facade.py` (7 tests OK);
    - `cargo deny`: advisories, bans, licenses and sources ok;
    - `cargo vet`: 36 fully audited.
  - Result: the planner exited 0; the log has no `ci-plan: ERROR`, no failed Rust test result and
    no panic.

  This result was then added here and amended onto the same commit. The amended tree differs
  from the gated one only in this file.

## Limits and overlaps

- A map value of a type no frame recorded is still refused. For example, an object-valued Job
  input such as a flash `partitionPlan` is refused in `job.show`'s inputs until a Job holding one
  is recorded; `exactInputs` holds the only recorded object shape.
- #1925 landed first, as `382c5a30`, and this change re-derived its three overlapping schemas on
  top of it (above).
- `operation.describe` and `selectionSchema` stay as described above.
