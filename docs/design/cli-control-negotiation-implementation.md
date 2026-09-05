# Single v1 control contract

Task: TASK-SVC-001

CLI, App/XPC and AgentRuntimeExecutor use one exact `1.0.0` control contract.
Each business request checks current `health` on the same socket or XPC
connection that will receive it. A reconnect checks again. The client verifies
the closed health fields, contract identity, Catalog digest and exact published
method set before sending business data. An old daemon that also reports
`1.0.0` cannot satisfy this identity check.

```sh
arkdeck runtime health --output json
```

Every request carries `protocolVersion`, `contractIdentity`, `id`, `method`
and optional object `params`. The registry fixes the exact version, method set,
4 MiB request and 8 MiB response limits. Its canonical SHA-256 identifies this
contract. UTF-8, duplicate keys, frame shape and response correlation are checked
strictly; a request has exactly one LF-terminated response.

The daemon rejects missing identity, other versions and unpublished methods
before dispatch. Clients do not select versions, fall back, or replay a business
request after a lost reply. Identity-check failure can prove zero business
dispatch; a failure after sending a mutation remains subject to the existing
unknown-outcome rules. Contract identity grants no Runtime authority.

The vocabulary is `Packages/ArkDeckKit/Contracts/control-protocol.json`.
Regenerate its Swift projection with
`python3 Packages/ArkDeckKit/Scripts/generate-control-contract.py`; `--check`
verifies drift. The CLI machine-contract exporter generates its matching schema,
registry, coverage and argv fixtures. `--version` reports local
`controlProtocolVersion` and `controlContractIdentity` without connecting.

Host tests cover real local sockets, current CLI/App serialization, exact
request decoding, bounded deadlines and retired-peer refusal. These are fixtures;
published device acceptance belongs to TASK-SVC-005.
