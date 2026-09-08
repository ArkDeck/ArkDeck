# Publishing the method #1786 left unreachable — 2026-09-08

- Task: TASK-AFA-001
- Base: protected `main` `ae112a5b`.
- Scope: #1789 (`control-protocol.json`, the method's schema).

## What was wrong

`flash reconcile-alias` landed in #1786 with its handler, its CLI registry
entry, its effect classification, its coverage ruling, regenerated contract
products and 44 passing tests — and the daemon never published the method. It
was absent from the 96-entry table in
`Packages/ArkDeckKit/Contracts/control-protocol.json`, so the daemon refused it
before dispatch. Measured on the reference host with a helper rebuilt from
protected `main` `abc24e1d`:

```json
{"code":"controlMethodUnavailable",
 "details":{"method":"flash.reconcile-alias","wireCode":"unknownMethod"},
 "message":"method is not published by this Runtime"}
```

Nothing failed, because the reachability suite asks only whether every
*published* method dispatches. A handler `case` that the table does not list is
invisible to it.

## The gate

`CLIControlFailureMappingContractTests.testEveryDispatchedMethodIsPublishedByTheControlTable`
reuses the daemon-source method scrape that suite already has and asserts the
other direction: every method with a handler is in the control table. Negative
control — with `flash.reconcile-alias` removed from `control-protocol.json` and
the generated Swift, exactly reproducing #1786:

```text
XCTAssertEqual failed: (["flash.reconcile-alias"]) is not equal to ([]) —
these methods have a handler but are not in Contracts/control-protocol.json,
so the daemon refuses them before dispatch and nothing can call them
```

## Publishing it

The method is added to the table and the generator rewrites
`ControlProtocolGenerated.swift`. It is deliberately **not** added to
`AgentXPCContract`'s forwardable sets: this is an operator repair reached from
the CLI over the user's private socket, and the App has no reason to forward it.

`AgentDaemonContractTests.testReconcileAliasDispatchesAndRedactsItsReceipt`
drives the method through the real handler for both outcomes, asserts the
receipt's exact five keys and that the raw connect key, serial and USB topology
never appear, and is what records the frames the schema is derived from.

## The whole-contract cost, and why the churn is safe

Publishing a method changes the contract identity, and every per-method schema
carries that identity, so all 97 had to be re-derived. The derivation input is one
complete contract-suite recording: 2,410 tests, 2,747 usable frames, 97 methods.

Three inputs were tried before this one, and the two that failed are worth
recording because each fails differently:

- **The committed corpus alone.** It is a bounded, deduplicated selection, so
  the schemas it produces drop error codes the real schemas carry.
- **A recording that was cut short.** 27 corpus files lost distinct shapes.
- **The union of a complete recording and the committed corpus.** This looks
  safest and is wrong for `health`: its recorded result *embeds the published
  method table and the contract identity*, so the committed frames are not
  redundant, they are stale. The generator picked one, and the candidate view
  refused it — `validate_health` returned `ContractMismatch` inside
  `check-contracts.py`'s candidate run. A frame whose body quotes the contract
  cannot be carried across a contract change.

The churn was then measured rather than assumed:

- **No published shape changed.** Across all 97 schemas, every diff line is
  either `x-arkdeck-contractIdentity` or `x-arkdeck-sampleCounts`. Filtering
  those two out of `git diff spec/control/methods` leaves nothing: no `$defs`
  request, result, `errorCode` or `errorDetails` shape moved.
- **No corpus shape was lost.** 59 corpus files changed, and comparing distinct
  request/response key-shapes per method, none lost one.
- `rust/scripts/check-contracts.py` exits 0: the candidate view builds Rust
  against these inputs and passes `cargo test --workspace --locked`, including
  every `corpus_parity` case, under the new identity
  `8a662759721a2081e974306399997801246de4022047365c050107de5dce2912`, with
  `check-readonly.py` reporting `"result": "PASS"`.

`openspec/contracts/runtime-control-plane.schema.json` follows the identity and
was regenerated with `arkdeck maintainer contracts export`, not edited.

## Verification

`ControlMethodSchemaContractTests`, `ControlMethodReachabilityContractTests`,
`ControlProtocolContractTests`, `CLIMachineContractTests`,
`CLIControlFailureMappingContractTests`, `AgentXPCTransportContractTests`,
`RockchipRuntimeCompositionContractTests` and `AgentDaemonContractTests`:
203 tests, 1 skipped, 1 failure —
`AgentDaemonContractTests.testHilogAnalyzerRunsMultipleJobsInOneDaemonSession`
with `analyzer.toolIdentityDrift`. That is the ad-hoc-invocation artifact
already recorded in `session-publication-run-2026-09-08.md`: it fails the same
way under a bare `swift test --filter` with this branch's changes stashed, and
passes in the sanctioned `run-test-lane.sh` lane, which the unified gate below
uses.

## Not verified here

The leaf still has not been run against the reference host's real reissued
alias. That needs this merged and a helper rebuilt from protected `main`; the
run record belongs to TASK-SVC-005. GJ-4's second gate —
`flash.full-restore@1` is Catalog-`unavailable` without a named hardware
acceptance campaign — is untouched by this.
