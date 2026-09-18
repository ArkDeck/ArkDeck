# TASK-XPA-014 — the M2 oracles' answers published: job.submit's `admissionDenied` and five other methods' shapes (macOS, 2026-09-15)

TASK-XPA-014 remains in progress. Base: protected main `438434ef`; no stack. This slice changes no
Swift or Rust behaviour. It republishes six control-method schemas, their committed corpus and the
contract-input manifest. The Rust contract crate includes the schemas at compile time, so its
generated bindings do not change. Every frame here was recorded by Swift contract tests over the
shared fake HDC; nothing is device evidence (POL-VERIFY-001, POL-MODE-001).

## Already on main / this slice / still remaining

| Already on main | This slice | Still remaining for M2 |
| --- | --- | --- |
| The pointer-input and port-rule oracles (#1958), the debug HAP and app-owned native library oracles, and the Rust providers that replay their argv | The six re-derived schemas and their corpus; the generator's shape bound; the regenerated manifest | Runtime capability issuance, reservation and consumption in the Rust owner; the M2 operations' plans, admission and runs; their replay against these oracles |

## Why

The Rust control layer answers only what a method's published schema admits. It rewrites every
other answer to `internalError`. Validated against the published schemas, the frames the four M2
oracles record fall outside six of them:

| Method | Frames outside the published schema | What the schema lacked |
| --- | --- | --- |
| `job.submit` | 2 of 30 | `admissionDenied`: an automatic capability's lineage blocked by an earlier use's unknown outcome (the pointer and port-rule oracles) |
| `job.result` | 11 of 26 | `null` for `evidence.authority.artifactDigest`, which 11 of the 23 Runtime-capability authorities these oracles record carry |
| `capability.inspect` | 13 of 14 | integer values in `capability.exactInputs` (display sizes and IDs, ports, durations) and a string-array value (`additionalHapArtifactLeases`) |
| `job.plan` | 1 of 44 | an array value in the result's `inputs` (`additionalHapArtifactLeases`) |
| `cleanupDebt.list` | 1 of 4 | a string `bundleName` where only `null` was published |
| `cleanupDebt.continue` | 1 of 3 | a `bundleName` request parameter |

`job.run`, `job.evidence`, `artifact.list` and `capability.list` already admit every frame these
oracles record.

A Rust daemon that answered these oracles exactly as Swift does would still have answered
`internalError` in each of these places.

## What changes

- **The derivation.** `generate-control-contract.py --derive-method-schemas` rewrites only the
  methods its input frames name, so it was fed only these six. Its input was:
  - each method's committed corpus;
  - every frame of the four M2 oracles that the published schema refuses;
  - the JobPlanAnalyzer oracle's `job.plan` frames, which carry codes the committed corpus lacks;
  - for each published code that none of the above carries, the smallest frame of that code from a
    recording of the whole suite.
- **The shape bound.** The committed corpus keeps the first shapes of a method in sort order, up to
  a bound. `job.result` already held 23 committed shapes, and the oracles' new shapes would have
  pushed one committed frame out under the bound of 24. That frame is the `resultNotReady` refusal
  whose `nextAction` has no `retryAfter`, and a Rust corpus test reads it. The bound is now 32.
- **Regeneration.** `rust/scripts/generate-contract.py --write` regenerated
  `spec/baselines/swift-single-v1.json`: the six methods' corpus counts, the digests of the schema
  and corpus directories, and the blob and SHA-256 of the twelve changed files.
  `arkdeck-contract`'s `control_generated.rs` includes each schema with `include_str!` and does not
  change.
- **Sample counts.** A schema's `x-arkdeck-sampleCounts` now counts this derivation's input. For
  `job.submit`, `cleanupDebt.list` and `cleanupDebt.continue` that input is smaller than the
  recording the published schema was derived from, so their counts go down. Only the generator
  writes the field; nothing reads it.

## Checks

For each re-derived method, published → derived:

| Method | Corpus lines | Frames refused: M2 oracles (plus JobPlanAnalyzer for `job.plan`) | Frames refused: whole-suite recording | Error codes added |
| --- | --- | --- | --- | --- |
| `job.plan` | 9 → 10 | 1 → 0 of 115 | 1 → 0 of 137 | none |
| `job.submit` | 3 → 7 | 2 → 0 of 30 | 2 → 0 of 117 | `admissionDenied` |
| `job.result` | 23 → 29 | 11 → 0 of 26 | 11 → 0 of 82 | none |
| `capability.inspect` | 11 → 18 | 13 → 0 of 14 | 13 → 0 of 68 | none |
| `cleanupDebt.list` | 2 → 3 | 1 → 0 of 4 | 1 → 0 of 7 | none |
| `cleanupDebt.continue` | 2 → 3 | 1 → 0 of 3 | 1 → 0 of 5 | none |

| Check | Command | Result |
| --- | --- | --- |
| Nothing published is lost | A scratch comparison of each derived schema with the published one: enums, types, properties, required members and map values | Nothing lost; no error code removed; no committed corpus line dropped |
| Only the expected files | `git status --porcelain` | The six schemas and their six corpus files, the generator, the manifest and this record |
| The whole corpus | Every committed corpus line of every method against the derived schemas | 726 lines; none refused |
| Swift schema and reachability contracts | `sh Packages/ArkDeckKit/Scripts/run-swiftpm.sh test --filter 'ControlMethodSchemaContractTests\|ControlMethodReachabilityContractTests'` | 7 tests: 6 passed; `testFramesRecordedByThisRunValidate` skipped, since it needs `ARKDECK_CONTROL_FRAME_LOG` (the recordings above stand in for it) |
| Manifest and bindings | `python3 rust/scripts/generate-contract.py --check` | In sync |
| Rust contract tests | `cargo test --locked -p arkdeck-contract` | 46 passed in 7 suites |

### Recorded frames outside these six methods

The whole-suite recording (`run-swiftpm.sh test --parallel` with `ARKDECK_CONTROL_FRAME_LOG`) holds
2453 frames over 105 methods. Against the published schemas, 19 frames of 10 other methods fail.
Those schemas are unchanged from main, where the same frames fail:

- `artifact.export`: 3 errors whose codes, `sensitiveAccessDenied` (2) and `outcomeUnknown` (1),
  are missing from its error enum.
- `health`: 1 request carrying `padding`, from a frame-size test.
- `job.cancel` (1) and `job.list` (8): requests with non-string parameters, from negative tests.
- `runtime.bundle.inspect`, `runtime.bundle.register`, `runtime.bundle.remove`,
  `runtime.tool.inspect`, `runtime.tool.register` and `runtime.tool.remove`: 6 requests each
  missing a required parameter, from negative tests.

## Unified local gate

`python scripts/ci/plan.py --repo-root . --base-revision origin/main --head-revision HEAD
--merge-base --include-worktree --run-local`, with `ARKDECK_PYTHON` naming `.venv-sdd` and the
planner run from a virtual environment carrying PyYAML 6.0.3 and jsonschema 4.26.0:

| Run | Head | Result | Log |
| --- | --- | --- | --- |
| r1 | `cb18f112` | `gate exit=0`: the common checks and SDD, the Swift lane (full parallel, 2,678 tests, then the serialized lanes), the Rust lane on the development and candidate views (format, Clippy, the workspace tests — 2,241 passed in all over the workspace run and both views, none failed — and the contract checks), `cargo deny --locked check` and `cargo vet --locked --no-registry-suggestions` | `/private/tmp/xpa014-m2-oracle-frames-gate-20260915-a.log`, SHA-256 `2526f64ea1ab53d89cb22a98c821536cad65eee55eacf52ae1150704cc4c9623` |

The amend after r1 only fills in this row.

## Not run, and why

- **The Rust answers themselves.** The M2 slices that follow serve them.
- **`resourceConflict` and `resourceNotFound` on `job.submit`.** The Rust owner can answer both.
  No Swift oracle records either, so neither is published, and the control layer still rewrites
  them to `internalError`.
- No device, no real HDC.
