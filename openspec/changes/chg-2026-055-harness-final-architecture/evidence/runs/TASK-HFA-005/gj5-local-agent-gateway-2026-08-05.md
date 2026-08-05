# GJ-5 — the decision producer stops being a Codex dependency (2026-08-05, later)

Follow-up to `gj5-current-digest-2026-08-05.md`, which recorded GJ-5 stopping at
`patchProposalRequired` because this host had no decision producer: the Codex
CLI is not installed here, and the HTTPS vendor gateways need a separately
provisioned API key. That was a product limitation, not a host one — the local
CLI lane existed but was written around one vendor.

With the lane turned into a closed set of `HarnessLocalAgentCLIProfile`s, the
Claude Code CLI that *is* signed in on this host becomes a producer, and the
loop runs model-driven end to end.

## Scope and target

- Catalog digest: `e2f8eb6592aaeeec37c63a01708db2325b38c798b0f8272228ba0fccc2cfd0aa`
- Target: `TGT-958780b2ffb7`, binding revision `2`, DAYU200 / OpenHarmony `7.0.0.36`
- Decision producer: `claude-code-cli-gateway@1`, model `sonnet`, provider
  `anthropic-claude-code-cli`
- Egress: opt-in for `demo-app` only (`ARKDECK_HARNESS_EGRESS_PROJECTS`)

Daemon startup, with no API key configured anywhere:

```text
harness decision egress enabled for demo-app
harness decision gateway ready: claude-code-cli-gateway@1 model=sonnet
```

The child is identity-bound and gets the bounded context and nothing else —
observed directly in the process table while a round was in flight:

```text
arkdeck-agentd(75039)
 └─ /Users/…/claude/versions/2.1.221 --print --model sonnet --output-format text
      --strict-mcp-config --permission-mode plan  "<decision context>"
```

Two host facts worth recording:

- The configured path must be the **canonical** one. Pointing at the symlinked
  launcher is refused at startup as `malformedExecutable` — the existing
  identity binding doing its job, since a symlink is not a thing whose bytes
  can be pinned.
- The child needs `USER` inherited: the CLI resolves its stored credential
  through it, and without it the child reports "Not logged in" while PATH,
  HOME, TMPDIR and LANG all look healthy. The `claude-code` profile declares
  that one variable by name; no credential value is ever named.

## What the model-driven loop did — `HTASK-6F6393BA459E`

One submit, no `task resume`, human actions `0`:

```text
1  admitted        taskAdmitted
2  jobDispatched   retryAllowedSameStrategy
3  jobObserved     operationSucceeded:observe.device@1
4  evaluation      inconclusive:collectMoreEvidence
5  jobDispatched   collectDeclaredEvidence
6  jobObserved     crashLedgerAwaitingDerivedAnalysis
7  jobDispatched   analyzeCapturedCrashLedger
8  jobObserved     operationSucceeded:analyzer.extract-crash-signature@1
9  evaluation      inconclusive:collectMoreEvidence
10 jobDispatched   deployBaselineCrashFixture
11 jobObserved     baselineCrashFixtureDeployed
12 jobDispatched   collectDeclaredEvidence
13 jobObserved     crashLedgerAwaitingDerivedAnalysis
14 jobDispatched   analyzeCapturedCrashLedger
15 jobObserved     operationSucceeded:analyzer.extract-crash-signature@1
16 evaluation      criteriaFailed
17 humanBlocked    unauthorizedScopeMissingDiagnostics
```

Consumed: `rounds 6/20`, `modelCalls 7/24`, `e1Mutations 1/8`,
`artifactBytes 1,742,017/67,108,864`. The E1 mutation is a real
`debug.hap@1` deployment of the crash fixture to the device.

Every round consulted the model — `modelCalls` tracks `rounds` — which is the
difference this change makes. The producer is a model, and the runtime still
owns every typed input: the strict validator refused several proposals in
flight (`proposalRejected:operationNotExpected:capture.diagnostics@1`,
`proposalRejected:oversizedField:expectedObservation`) and the deterministic
step ran in their place, so a loose proposal costs a model call and changes
nothing else. That behaviour predates this change and is working as designed.

## Where it now stops, and what is left

`unauthorizedScopeMissingDiagnostics` at round 6, immediately after the FAIL
verdict: this task was submitted without a workspace scope, so its decision
context carried `allowedFileScopes: []` and the repair route has nothing it is
allowed to touch. Declaring one at submit requires both
`--workspace-allowed-paths` and `--base-workspace-revision`
(`malformedEvolutionPolicy("baseRevision")` otherwise) — the revision has to be
read from the workspace, not guessed, which is why this run does not simply
re-submit with a value.

Beyond that gate the repair legs still need the maintainer-issued workspace
capability: `workspace.apply-patch@1` and its siblings carry
`defaultPolicyIssuance: disabled`, and the two grants installed on this host are
scoped to other evolution workspaces and have expired.

So the honest statement is unchanged in shape but smaller in size: GJ-5 remains
`IMPLEMENTING`, and what is missing is no longer "a decision producer" — it is
a workspace scope on the submitted task plus the maintainer's workspace grant.
