# Governance recovery handoff

> Status: draft / human action required
>
> Authority: non-normative planning record
>
> Execution gate: closed / quarantined
>
> Last reviewed: 2026-07-14

This handoff records a fail-closed recovery path discovered while preparing
`CHG-2026-003-dayu200-image-characterization`. It is not a Change approval,
Task packet, trust decision, revocation, baseline or authorization to execute.
The current `arkdeck-platform` and `arkdeck-behavior` schemas cannot legally
express this governance-only bootstrap, so no fake Change or unrelated Core
Requirement/AC is created.

The detailed non-authorizing candidate authorized by
`APPROVE-RECOVERY-BOOTSTRAP` is in
`openspec/planning/recovery-bootstrap/README.md`. It remains outside the current
Change schemas and accepted protected set until a separate external recovery
authority approves an exact committed candidate.

## Confirmed incident

- Signed external ledger snapshots 4 through 10 contain 31 distinct
  `(kind, id, revision)` groups that map to more than one SHA-256.
- `acceptedBaseline/CORE-1.0.0@1` maps to three hashes. In particular, snapshot
  8 records `adc03fa950c2eb4758d14c63985ce0b318b00dbbcb91006e0d18b0400b73252a`,
  while snapshot 9 records
  `50b68917cb2aa011ab67d0a8a2469913b1f14b3c8c57f2ef53f7c0301a088a79`.
- `taskPacket/TASK-M0A-001@1` changes from
  `2a638a88038a3a279fa2792d745680009c45a2ce872aa22ac71eac3465434694`
  in snapshot 9 to
  `0124c98495070f262da7ba4372c0ff787b7d2177e95dd925107c72df16b0fc13`
  in snapshot 10. Approval identities also map to multiple record hashes.
- `scripts/ledger_snapshot.py` chains snapshot revision/hash but does not reject a
  prior identity being rebound to different bytes.
- `.github/workflows/sdd-guard.yml` creates ledger state on an ephemeral runner
  and exposes ledger-signing capability to an `agent/**` branch-triggered,
  branch-controlled workflow. A green run therefore proves the current inventory,
  not cross-run append-only identity history or Agent-independent signing.
- Constitution/enforcement candidate/closed statements conflict with accepted/open
  trust-policy, baseline and Ready Task statements. The external trust materials
  exist, so neither side may simply be declared historical without recovery proof.

The historical snapshots, packets, approvals and signatures are evidence and
must be preserved byte-for-byte. Generating one more snapshot, editing prose or
deleting the conflicting records cannot repair the incident.

## Immediate containment

1. Reject every new claim and execution attempt that depends on `CORE-1.0.0`,
   `CHG-2026-001-macos-m0a` or `TASK-M0A-*` authority.
2. Keep CHG-003 proposed/draft and record `APPROVE-STRUCTURE` only as its
   non-authorizing structural decision.
3. Preserve all ledger snapshots and conflicting repository subjects; do not
   reuse, rewrite, delete, archive or normally supersede polluted identities.
4. Do not expose approval, claim-service or ledger signing keys to Agent/PR jobs.

## Human-authorized recovery sequence

1. Establish a one-time governance recovery authority outside ordinary Task
   execution. It must bind the incident inventory, human approver, protected
   operator, exact repository revision and the allowed recovery outputs.
2. Move signing to an Agent-inaccessible, serialized external service. Agent/PR
   workflows run secret-free diagnostics only; CI consumes a read-only snapshot
   bound to the exact commit and never holds the ledger private key.
3. Make the ledger persistent across runs and reject every historical
   `(kind, id, revision) -> sha256` remap. Add replay tests for deletion, ID reuse,
   stale snapshots, chain reset, concurrent writers and signer substitution.
4. Rotate affected signing material as decided by the human security owner and
   publish a verifiable quarantine/recovery attestation for all polluted IDs.
5. Add a governance-specific schema and protected publication procedure. This
   bootstrap must not be disguised as an `arkdeck-platform` Change or a no-op
   product Requirement delta.
6. Publish mutually consistent Constitution/project/enforcement/trust statements,
   a fresh Core baseline ID and fresh conformance/approval subjects. Preserve
   `CORE-1.0.0` as quarantined history; never rewrite it in place.
7. Recreate M0A authorization with fresh Change, Task and approval IDs. Only then
   may CHG-003 pin the recovered baseline and enter formal Change/Task approval.

## Recovery acceptance boundary

Recovery is incomplete unless an independent verifier demonstrates all of the
following against preserved history:

- the signer and append-only state are inaccessible to standard Agents;
- one canonical hash exists for every new immutable identity for all time;
- snapshot revision and previous-hash continuity survive separate CI runs;
- collision, replay, deletion, reset and concurrent-write attempts fail closed;
- quarantine covers every previously collided identity and cannot be removed by
  rewriting Git history;
- all current governance declarations and external approvals agree on gate,
  baseline and Task eligibility;
- CHG-003 receives new exact pins and separate external approvals before claim.

Until those statements are externally evidenced, no ordinary Agent may mark the
recovery, CHG-003 or any affected M0A Task approved, ready, claimed or done.
