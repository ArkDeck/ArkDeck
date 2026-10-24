# `api/` — language-neutral contracts

The contracts a second implementation of the ArkDeck runtime consumes, in the
form design `docs/design/cross-platform/rust-core-cross-platform-architecture.md`
§F.1 asks for: derived from what the Swift implementation really does, checked
against it by contract tests, and read by generators rather than restated.

| Directory | Contract | Fact source and gate |
| --- | --- | --- |
| `control/methods/` | one typed schema per control-plane method of the single current protocol (`Packages/ArkDeckKit/Contracts/control-protocol.json`) | frames recorded from the Swift daemon; `ControlMethodSchemaContractTests` (see `control/README.md`) |
| `recovery/job-state-preflight.json` | which Job states, agent executions and capability uses block a daemon restart or the M5 cutover and which are carried over as they are (design §G.4; `runtime service restart`'s classifier) | `JobState`, `AgentExecutionState`, `RuntimeCapabilityUseOutcome` and `RuntimeCLI.classifyAgentdRestartCurrentJobs`; `JobStatePreflightTableContractTests`, which also records the Rust replay's oracle |

`api/` holds data only. Method schemas, baselines, recovery, and UI semantics
live beside `contracts/`, the machine-contract bundle (journal, manifest,
capability ledger, CLI schemas) formerly under `openspec/contracts/`. The
method set, the protocol version, the contract identity and the catalog remain
stated once in their registries
(`Packages/ArkDeckKit/Contracts/control-protocol.json`, `catalog/`), and the
Swift implementation stays the oracle for every contract here until another
implementation passes the same corpus. CHG-2026-075 has not yet folded the
durable-document schemas in `contracts/` onto one restated v1.
