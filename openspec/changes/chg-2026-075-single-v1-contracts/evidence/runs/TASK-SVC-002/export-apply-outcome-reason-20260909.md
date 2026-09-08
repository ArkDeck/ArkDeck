# `session export apply` erased the reason it refused — 2026-09-09

- Task: TASK-SVC-002
- Base: protected `main` `2b16e2fc` (#1795).
- Found on the reference host, running the published Runtime built from that
  commit against the Session the producer had actually published.

## What happened

#1795 made exact export succeed while the global accounting is incomplete, and
on this host `session export preview` does exactly that:

```json
"catalogStatus": {"blocker":"unaccountedSessionContent","complete":false,
                  "measurementIncomplete":true,"unaccountedSessionCount":"1",
                  "usedBytes":"5395"}
"source": {"jobId":"job-71f00adafcce67d0de4eed11ebb4b5c3",
           "manifestSha256":"270bd40d97701cf462c28e473cfa7406ccdfea5872214a560f0fcafd50eabef5", …}
```

`manifestSha256` is the same digest the Job's own publication receipt carries,
and `usedBytes` is measured known content rather than the root's 4 GB total.

`session export apply` then answered:

```text
exit 75  outcomeUnknown  phase sessionOwner  newDispatchCount 0
"Session export outcome requires destination inspection"
```

and the destination did not exist. Reproduced with a destination under `$HOME`
as well as under `/private/tmp`, so it is not path visibility.

## The defect this record fixes

`RuntimeSessionStorageStore.applySessionExport` wrapped the whole publication
block in one `catch` that rewrote **every** error into `outcomeUnknown` with
that fixed sentence. Two consequences:

- The catalog-drift case inside the same block raises its own
  `outcomeUnknown("Session changed while its export was published")`, and the
  blanket catch replaced that message too.
- A refusal that wrote nothing was reported as `outcomeUnknown`, which on this
  surface means "may be half-published" — the most expensive classification
  there is. An operator is told to inspect the destination and given nothing to
  inspect it for.

A failure the owner already classified now keeps its own code and message. An
unclassified one still becomes `outcomeUnknown` — the exporter may already have
created the destination, so that is honest — but it now names the cause.

## Verification

`SessionExportContractTests` 10/10, including two new cases:
`testApplyKeepsAClassifiedFailuresOwnCode` (a classified refusal keeps
`resourceConflict` and its own text) and
`testApplyNamesAnUnclassifiedCauseInsteadOfTheBareSentence` (an unclassified
one stays `outcomeUnknown` and must not equal the bare sentence). Both assert
the destination was not created.

## What this does not fix

**Why the host's apply fails is still unknown**, and deliberately so: this
change is what will reveal it. The candidates visible in
`SessionDiagnosticExporter.export` are the heavy-writer `StorageClaim`
requirement and the claim/destination volume check; the host's Session has zero
Manifest artifacts and its storage domain reports `measurementIncomplete: true`
against a 4 GB used / 20 GB quota root, so a refused heavy claim is plausible
and unproven. After this merges, a helper rebuilt from protected `main` will
print the actual cause, and that belongs in the TASK-SVC-005 run record.

So the export half of SVC-AC-05 is **not** met on the reference host: preview
succeeds with correct disclosure, apply does not publish.
