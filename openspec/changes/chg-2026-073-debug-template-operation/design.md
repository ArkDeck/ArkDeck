# Design — CHG-2026-073

## Operation shape

`Catalog/operations/debug.template.v1.json` publishes `debug.template@1` on
the `hdc` provider: effect `readOnly` only, authorization `defaultReadOnly`,
binding `confirmedDevice`, concurrency `device-shared-readonly`. The only
input is `templateId`, an enum of the four closed templates. Steps are
`confirm-evidence-target` (binding identity confirmation against the live
device), one `runApprovedRemoteRead` step named `run-debug-template` without
an `actionRef`, and `finalize-session`. The operation is deliberately not
evidence-eligible: the execution kernel's per-operation evidence set may not
grow, and model/firmware facts remain the job of `target observe`. Two
required Artifacts are declared: `template-output.txt` (`raw`, `sensitive`)
and `template-report.json` (`derived`, `standard`).

## Single owner of the template table

`DebugRuntimeCommandTemplate` gains `remoteCommand`, `outputByteBudget` and
`title`. The legacy direct probe, the provider lowering and the CLI listing
read that table; the descriptor enum is compared against it by contract tests
and by `debug template list` at run time.

## Provider and engine

The HDC adapter maps `run-debug-template` to a new typed action
`runDebugTemplate(template)`, lowers it to `-t <connectKey>` plus the fixed
tokens with a 30-second timeout and the template's own stdout budget, and
verifies the receipt: truncation, a missing or non-zero exit status, or an
HDC transport/authorization marker fails the step; success records the
template identity, disclosed command, exit status, duration and byte counts.
The durable step parameters name the closed action `debugTemplate` and the
template identity. Re-observation is safe, so reconciliation answers
`confirmedNotExecuted`. The Artifact service maps the step to both products;
the raw stdout is published as `template-output.txt` and the summary as
`template-report.json`. Binding confirmation precedes the template step by
descriptor order and fails closed on identity drift.

## CLI

`debug template run` is a generic domain leaf bound to `debug.template@1`;
inputs come from `operation describe`. `debug template list` is a local,
non-connecting projection of the table cross-checked against the descriptor.

## Debug logs preset

`DiagnosticCapturePreset.logs(durationSeconds:filters:)` owns the HiLog-only
projection of `capture.diagnostics@1`: the exact dictionary the App's
`submitLogs` has always sent, with the App now calling the preset instead of
restating it. `arkdeck debug logs` is a generic domain leaf bound to
`capture.diagnostics@1`; its `--inputs-file` may carry only `durationSeconds`
and `hilogFilters`, and the client refuses any other diagnostics field, an
out-of-range window or a filter outside the typed component character set
before connecting.

## Failure classification

- identity outside the enum: refused at admission, zero dispatch;
- truncated, non-zero or transport-marked receipt: step failed, no output
  Artifact under the template's name;
- lost process result: unknown, reconciled as not executed.
