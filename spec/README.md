# `spec/` — language-neutral contracts

The contracts a second implementation of the ArkDeck runtime consumes, in the
form design `docs/design/cross-platform/rust-core-cross-platform-architecture.md`
§F.1 asks for: derived from what the Swift implementation really does, checked
against it by contract tests, and read by generators rather than restated.

| Directory | Contract | Fact source and gate |
| --- | --- | --- |
| `control/methods/` | one typed schema per control-plane method of the single current protocol (`Packages/ArkDeckKit/Contracts/control-protocol.json`) | frames recorded from the Swift daemon; `ControlMethodSchemaContractTests` (see `control/README.md`) |

`spec/` holds data only. The method set, the protocol version, the contract
identity and the Catalog remain stated once in their registries
(`Packages/ArkDeckKit/Contracts/control-protocol.json`, `Catalog/`), and the
Swift implementation stays the oracle for every contract here until another
implementation passes the same corpus. The durable-document contracts (journal,
manifest, capability ledger) join this directory once CHG-2026-075 has
consolidated them on their single v1 (`TASK-SVC-002..004`); they are not
restated from the current `openspec/contracts/` files before that.
