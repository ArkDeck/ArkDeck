# CLI workspace project lifecycle

Task: TASK-AIN-021

`arkdeck workspace project register|update|remove|list|show` exposes the
Runtime-owned project registration resource required by CLI-REQ-022. All five
leaves negotiate control protocol 2 before sending a target request.

```text
arkdeck workspace project register \
  --registration-request-id <id> --kind arkdeck|openharmony --root <absolute-path>
arkdeck workspace project update \
  --project <ref> --expected-generation <n> \
  --kind arkdeck|openharmony --root <absolute-path>
arkdeck workspace project remove \
  --project <ref> --expected-generation <n>
arkdeck workspace project list
arkdeck workspace project show --project <ref>
```

The registration owner accepts a root only on register or update. It requires
a lexical canonical absolute path, rejects every symbolic-link ancestor and
opens the leaf directory with `O_NOFOLLOW`. The durable private record pins the
opened directory's device and inode. List, show and mutation receipts publish
only `projectRef`, generation, kind, timestamps, configuration status and the
bounded availability projection; they have no field capable of carrying the
root, executable, fixed arguments or a secret.

Registration IDs are caller-stable. Retrying the same ID with the same kind
and pinned root returns the original resource; a different registration is an
`idempotencyConflict`. Update and remove require the exact current generation.
Remove deletes only the private grant and configuration record and never
removes the source directory.

Register and update return `configurationStatus: runtimeRestartRequired`.
Until the Runtime restarts and observes that exact generation, workspace Job
acquisition refuses it. At startup the daemon revalidates every root identity
and derives every usable registered built-in project profile into one typed
provider registry. An observed generation is `active`; its separate
availability remains `unavailable` when root facts drift or profile/toolchain
derivation fails. One failed project does not stop the daemon or disable a
different project's valid operation, and the failed registration remains
discoverable and repairable through update/remove. Removing a project
immediately prevents new acquisition even though an old in-memory profile
still exists until restart.

The project owner serializes acquisition and mutation. A workspace Job holds
an in-process use token from materialization through durable SQLite admission.
Update and remove first reject an in-flight token and then scan verified
durable Job records; active, nonterminal or outcome-unknown references block
the mutation. Once a Job is terminal with a known outcome, the registration
can be changed. Root identity is checked again on every acquisition, so a
directory replacement fails as `factsDrifted` before a Job is admitted.

The legacy `ARKDECK_WORKSPACE_PROJECTS` daemon flag is a compatibility reader.
Recognized built-in entries are migrated idempotently into the same private
store and subsequent target discovery reads that store. Preset and toolchain
registration remain a separate CLI-REQ-022 slice; an OpenHarmony project whose
typed toolchain/preset is not yet available is truthfully published as
unavailable rather than accepting a raw command escape.
