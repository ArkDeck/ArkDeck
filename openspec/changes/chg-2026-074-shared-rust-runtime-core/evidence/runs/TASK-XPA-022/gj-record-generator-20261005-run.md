# TASK-XPA-022: the Golden Journey record generator (phase A G9), 2026-10-05

## What changed

- **Generator.** `scripts/gj_record` (stdlib-only, Windows and macOS) builds the redacted
  `arkdeck.gj-headless-rerun/1` record from the Runtime's own outputs.
  - `capture` runs each published `arkdeck` command with an argument array. It keeps the stdout,
    exit code, order, UTC times and CLI image SHA-256 in a journal outside the repository.
  - `assemble` applies the headless runbook's §2–§6 criteria, derives each Journey's state and
    writes the record. Every criterion is listed with the captured files it was read from.
- **Refusals.** `assemble` writes no record from:
  - edited outputs, or outputs from more than one CLI image;
  - plan-only or simulated Jobs;
  - a development state root, or an unverified daemon image;
  - another HDC than the available configured one;
  - a revision off protected `main`, a Catalog that moved on `main` since that revision, or any
    answer on another digest;
  - an `operation list` that is not that Catalog's canonical set;
  - a record that would carry a connect key, serial, display name or path from the raw outputs,
    or anything path-shaped or `address:port`-shaped.
- **Expected digest.** It is read from `catalog_generated.rs` at the revision and recomputed from
  its canonical JSON, as `scripts/catalog_gen/generate.py` computes it.
- **Existing tooling reused.** There was nothing to reuse for the record itself:
  - `scripts/agent-guides/acceptance.md` names `agent run`/`resume` and the UI wrapper only;
  - no repository script produced `gj-headless-rerun` records; the 2026-09-02/09/10 records were
    hand-assembled;
  - `hardware-evidence.schema.json` is a different record (per-run lab evidence), not the
    Journey record.

  The generator therefore keeps the existing record shape and the headless runbook's criteria,
  and adds only `criteria`, `firstFailingCriterion` and `generator` fields.
- **Docs.**
  - The phase A runbook's §4.0.6 now runs every step through the generator, and §4.0.3 adds
    `runtime health`. The Rust `operation list` is a bare array; the digest is `runtime health`'s.
  - G9 is marked closed in §4.6.
  - `scripts/README.md` lists the new entry.
- **CI.** SDD Guard runs the suite on every PR.

## Where each criterion is read

| Criterion | Where the generator reads it |
| --- | --- |
| Job criteria | `job result` → `evidence` (`terminalState`, `outcomeUnknown`, `blockers`, `missingRequiredArtifacts`), `job.outstandingResidueCount`, `artifacts[].bytesVerified` |
| Artifact reads | every `artifact read` chunk to `eof`, rehashed against `artifactDigest` |
| Per-step verification | the `job show` timeline (`verified <step> [keys]`, `dispatched <step>; awaiting readback`), or every `job timeline` page |
| Capture completeness | `capture-summary.json` `completeness: complete`, `missingRequired: []` |
| HAR | `agent run` exit 75, `error.code humanActionRequired`, `error.details.execution.humanAction.newDispatchCount == 0`; then `agent status` (waiting, `nextAction.resumeReference`), `human-action show` (same reference), `agent resume` consuming it, the action `resolvedByFreshProbe`, the same Target and binding revision, and `target show` identity unchanged across the replug |
| GJ-3 | the timeline's `verify-elf-locally`/`hash-library` lines, the forward steps, and `verification-report.json` `loaderVerified: "true"`; the rollback leg's `verified rollback-native-library` and "restored previous library" |
| GJ-4 | `actualStepKinds` ⊇ the six kinds; `observation.firmware` by `machineReadback` and `post-flash-facts.json` `firmware` equal `OpenHarmony-7.0.0.37`; `flash-report.json` complete; no human action on the execution |
| GJ-5 | liveness and `crash-index.txt` (fault-log ledger entries between the `******` fences) from `capture.diagnostics@1`; `crash-signature.json` `answered`; `applied-patch.json` revisions against `isolated-workspace.json`; `install-readback.json` `deployedArtifactSha256` equal to the signed HAP's SHA-256; the negative case's `admissionDenied` / `preAdmission` / `newDispatchCount 0` / `workspace.revisionConflict`, with the complete `job list` before and after compared by count and ID set |

## Delegated minor decisions, pending the next rulings batch

1. **States for a failure.**
   - A failing Runtime value is `BLOCKED_BY_PRODUCT_DEFECT`.
   - A step that was not captured is `IMPLEMENTING`.
   - A Journey with no execution is `NOT_STARTED`.
2. **Composition where the Rust operation publishes less than the runbook's prose.**
   - `debug.hap@1` publishes no UI Dump, Trace, liveness or crash index. GJ-2 reads them from an
     app-scoped `capture.diagnostics@1` (`gj2-<d>-capture`), as the 2026-09-09 macOS round did.
   - GJ-5 reads them from `-repro-capture` and `-verify-capture`.
   - "Exactly one new crash-index entry" is counted against a `-baseline` capture.
3. **Artifact count.** "Artifact count of the same order as 08-28" is not mechanical and is not
   applied. The named Artifacts are required instead.
4. **Daemon digest on Windows.** `runtime service status` prints no image digest on Windows.
   `capture` hashes the image the status names at the moment the status is read.
5. **Test placement.** The tests run in SDD Guard. That is the one job that already runs stdlib
   Python suites on every PR.

## Findings, not changed here

- **GJ-2 "remote file readback".** The Rust `send-hap` is verified on exit status only
  (`["stagedAt"]`); there is no remote hash readback. The generator requires `send-hap` verified,
  which is what the Runtime publishes.
  - **This is Swift parity, not a port regression.** The last Swift Runtime (`57ba8e36f~1`,
    `ArkDeckWorkflows/DeviceProviders/DeviceProviderAdapters.swift`) did the same two things.
    - Lowering refused unless the lease resolved to the Artifact the Job admitted with the
      expected SHA-256 (around line 1209).
    - Its verifier returned `verified(["stagedAt"])` on `file send` exit 0 alone (around line
      2365).
  - **The deployed bytes are pinned after install instead.** `package-readback` binds its verdict
    to the resolved Artifact's SHA-256 (`deployedArtifactSha256`), in Rust as in Swift. The
    generator requires that readback.
  - A remote hash check before install would be a new behaviour on both platforms, not a parity
    fix. It is not added here.
- **GJ-2 "PID readback".** The Rust `process-readback` publishes `running`, not a PID.
- **Headless runbook §0.** It says `operation list` carries `result.catalogDigest`. On the Rust CLI
  it does not; `runtime health` does.

## Checks

- `cd scripts && python -m unittest discover -s gj_record -t .`: 31 tests OK. The tests use
  synthetic journals in a temporary git repository; no device, daemon or CLI is run.
- `python scripts/test_agent_pr_identity.py` (the boundary map): OK.
- `PYTHONUTF8=1 python scripts/test_agent_pr_workflow.py`: OK. Without `PYTHONUTF8` it fails on
  `main` too (`gbk` decoding on this host).
- `PYTHONUTF8=1 sh scripts/check-sdd.sh`, and `git diff --check`.

## Follow-up: the headless runbook's digest source

The headless runbook previously read the Catalog digest from `operation list` → `result.catalogDigest`. The
Rust CLI's `operation list` result is a bare array of operations, so §0's fixed-fact table and §1
now read the digest from `runtime health` → `result.catalogDigest` and the operation set from
`operation list`. §7's record template names `runtime health` as the digest's source.
