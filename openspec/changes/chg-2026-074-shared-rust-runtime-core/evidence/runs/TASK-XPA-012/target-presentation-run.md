# TASK-XPA-012 Target presentation owner — isolated implementation

Date: 2026-09-12. All fixtures are synthetic host-test data, not hardware evidence.
The phase does not establish a binding, alias, fresh trusted fact, capability or
execution route. No installed state is selected.

## Scope and behavior

- A Rust owner reads the current Swift `targets.json` shape, validates bounded
  records and complete alias proof/hash chains, and preserves binding bytes.
  `target.list` selects active canonical records; `target.show` keeps the explicit
  absent warm/confirmed observation sources null.
- `target.display-name.set|clear` publishes only the existing separate name file,
  with exact generation CAS, private anchored locks, atomic publication and
  tombstones. Candidate writes require references from the Host's actual retained
  provider snapshot; caller fields cannot supply active references or facts.
  Snapshot refresh/restart expires candidate names, and publication uncertainty
  invalidates the retained snapshot. These names never select execution routes.
- Typed CLI leaves check identities, generation spelling, exact receipt identity,
  next generation and requested name/clear result. Lost/invalid write replies are
  outcomeUnknown and are never retried. Adoption remains unavailable because
  independent USB attachment proof and typed identity readback are absent.
- A DEBUG-only Swift construction seam acts immediately before the real save
  openat/renameat. Tests change fixture directory permissions/destination kind;
  the original syscall guards and catch path produce ioFailure/outcomeUnknown.
  Valid bounded input fixtures exercise count/byte quota errors. Production
  construction and release builds have no injection hook.

## Local checks completed

- Rust Target owner/alias tests: concurrent one-winner CAS, restart tombstone,
  current/unknown/adopted candidate rejection, global candidate generation,
  unsafe/duplicate document refusal, and alias hash/identity corruption refusal.
- CLI targeted tests: six command leaves, strict options, exact response binding,
  and lost response non-retryable classification.
- Host test: explicit simulated in-memory snapshot, stale/forged references and
  restart refusal with no reachable transport.
- Clippy for hoststore/agentd/CLI all targets, Rust formatting, Python harness
  compile, Swift frontend syntax parse and diff whitespace checks passed.
- `Fixtures/TargetNames/rust-display-names.json` was copied from the actual Rust
  owner test output; the Swift reader regression consumes these bytes directly.

## Coordinated integration checks pending

No Swift/App rebuild was started in this isolated worktree; the root agent owns
those serialized builds and the repository unified gate. Current producer capture
must include these AgentDaemonContractTests filters:

- testTargetDisplayNameIsADurableCASResourceSeparateFromIdentity
- testTargetDisplayNameRejectsUnknownTargetsInvalidNamesAndNonCanonicalGenerations
- testCandidateDisplayNameProducerCapturesExactTupleAndRefusals
- testTargetDisplayNameProducerRecordsCorruptDocumentRefusal
- testDisplayNameProducerRecordsRealSaveSyscallFailures
- testDisplayNameProducerRecordsCountAndByteQuotaRefusals
- testCurrentSwiftDisplayNameOwnerReadsActualRustTombstone

`ARKDECK_CONTROL_FRAME_LOG` records actual handler frames. Set
`ARKDECK_SWIFT_TARGET_COPY` for the first filter to export the actual synthetic
Swift Target/name documents. Set `ARKDECK_SWIFT_TARGET_ALIAS_COPY` when running
RockchipTargetAliasReconciliationContractTests/
testCompleteLaterFlashAppendsRelationWithoutRewritingUnknownJobOrTargets to export
actual alias-chain fixture bytes. The ignored Rust
`actual_swift_target_document_is_read_by_rust_without_rewriting_binding` test
requires `ARKDECK_SWIFT_TARGET_STORE` set to either actual export and `--ignored`.
The published contract pin is unchanged. Regenerate the candidate's four name
method schemas from the recorded existing Swift error paths before running
`check-target-resources.py` for both CLIs and the unified gate. The current
checked-in method schemas do not yet represent every existing Swift name-owner
failure and must not be treated as completed wire acceptance.
