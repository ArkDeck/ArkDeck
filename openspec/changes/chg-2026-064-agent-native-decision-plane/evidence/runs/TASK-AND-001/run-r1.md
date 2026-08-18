# TASK-AND-001 run r1 — product capabilities leave the Harness plane

- Date: 2026-08-18
- Base: `origin/main@70ecb304`
- Branch: `agent/task-and-001`
- Platform: macOS arm64
- Hardware: not required; no device command or mutation was executed
- Catalog digest before/after:
  `d76ad7750eeb39423de804fffca2ff262edec39fac41638b487571f2cd9bad9e`

## Implementation decision

The executable crash-ledger analyzer now lives beside
`ArkDeckWorkflows/AnalyzerProvider`. The parser and crash-signature value it
shares with the still-live legacy observation reader moved below both
consumers into `ArkDeckRuntime`; this avoids a forbidden Harness → Workflows
dependency while leaving no analyzer implementation in `ArkDeckHarness`.
Canonical encoding moved to the existing runtime wire contract, so both the
producer and provenance verifier recompute the same bytes.

The native chat loop and its OpenAI-compatible streaming gateway moved intact
to `ArkDeckAgentComposition`. Chat now owns equivalent model identity,
credential and task-wire projection types; the accepted
`ARKDECK_HARNESS_MODEL_*` environment spelling remains unchanged. Target
pseudonyms keep the exact historical domain separator and hash algorithm.

The evolution campaign retains its repair lane, but owns its environment-key
mapping and consumes the plane-neutral `LocalAgentCLIProfile`. This is the
"self-contained equivalent types" branch of the TASK-AND-001 design choice;
the lane itself remains for TASK-AND-003 to adjudicate and remove.

## AND-AC-1 — analyzer bytes and production reachability

The checked-in sample is the measured Faultlogger listing shape already used
by the contract suite:

`evidence/runs/TASK-AND-001/faultlog-sample.txt`

The base executable was built from a clean `git archive origin/main` under a
temporary directory. Both executables then ran their real one-shot production
entry point:

```text
origin/main arkdeck-agentd --analyze-crash-ledger faultlog-sample.txt
sha256 = 29918b313e4f180f617eed0b4ac0766f4bd02d6bc763267d05030798b2e1d94c
exit = 0

TASK-AND-001 arkdeck-agentd --analyze-crash-ledger faultlog-sample.txt
sha256 = 29918b313e4f180f617eed0b4ac0766f4bd02d6bc763267d05030798b2e1d94c
exit = 0
```

The output is byte-for-byte identical. `git diff --exit-code origin/main --
Catalog` returned 0, and the generated catalog digest remains the value above.

`swift test --package-path Packages/ArkDeckKit --filter
AnalyzerProviderContractTests`:

```text
Executed 16 tests, with 0 failures (0 unexpected)
exit = 0
```

This includes the actual runtime/provider path through analyzer plan,
dispatch, structured stdout verification and derived-artifact provenance.

## AND-AC-2 — native chat equivalence

`swift test --package-path Packages/ArkDeckKit --filter
NativeAgentChatContractTests`:

```text
Executed 15 tests, with 0 failures (0 unexpected)
exit = 0
```

The suite covers streaming/tool-call pairing, per-turn budgets, context
compaction, target pseudonymization, environment validation, closed typed
operations and Runtime stop conditions. The chat/loop/gateway/runtime-tools
source files contain no `import ArkDeckHarness`.

## AND-AC-3 — evolution campaign equivalence

`swift test --package-path Packages/ArkDeckKit --filter
EvolutionCampaignContractTests`:

```text
Executed 50 tests, with 1 test skipped and 0 failures (0 unexpected)
exit = 0
```

The skipped case is the pre-existing optional real-input gate requiring
`ARKDECK_DAYU200_70035_IMAGE`; it is unrelated to this host-only refactor.
`EvolutionCampaignHost.swift` contains no `import ArkDeckHarness`,
`HarnessVendorConfiguration`, or `HarnessLocalAgentCLIProfile`. The five
Workflows-side campaign authority/ledger/admission/engine/candidate files were
not modified.

## Decoupling search

Both searches returned no matches (`rg` exit 1):

```text
rg 'HarnessCrashLedgerDerivedAnalyzer|HarnessAgentSession|OpenAIHarnessAgentGateway' \
  Packages/ArkDeckKit/Sources/ArkDeckHarness

rg 'import ArkDeckHarness|HarnessVendorConfiguration|HarnessLocalAgentCLIProfile' \
  EvolutionCampaignHost.swift AgentChatApplication.swift \
  NativeAgentChatRuntimeTools.swift HarnessAgentLoop.swift \
  HarnessAgentOpenAIGateway.swift
```

## Unified local gate

The repository's shared CI planner selected both production lanes because the
change touches `Packages/ArkDeckKit/Sources/**`:

```text
python3 scripts/ci/plan.py \
  --repo-root . \
  --base-revision origin/main \
  --head-revision HEAD \
  --merge-base \
  --include-worktree \
  --run-local

SDD guard: passed (121 acceptance IDs, 0 errors, 0 warnings)
CI planner tests: 17 passed
agent-pr workflow tests: 8 passed
catalog generator tests: 45 passed
catalog zero-drift check: passed
SwiftPM runner tests: 10 passed
full ArkDeckKit Swift test lane: passed
ArkDeck App/UI-test build-for-testing lane: ** TEST BUILD SUCCEEDED **
exit = 0
```

The first sandboxed invocation could not write the repository-configured
stable SwiftPM cache under the user Library. The same command was rerun with
that cache writable; no command, lane or test selection was weakened.

## Golden Journey conclusion

TASK-AND-001 is a host-only structural prerequisite. It preserves GJ-1's
crash-signature chain and GJ-4's campaign lane, while moving GJ-5 product
capabilities out of the retiring Harness plane. It does not claim a real-device
run; GJ-5 remains `IMPLEMENTING` under the CHG-2026-064 external-agent
criterion until TASK-AND-002 passes on the current catalog digest.
