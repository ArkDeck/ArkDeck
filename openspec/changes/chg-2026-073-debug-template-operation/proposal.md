---
id: CHG-2026-073-debug-template-operation
revision: 1
status: proposed
class: capability
core_change_level: none
owner: fuhanfeng
core_baseline: CORE-3.0.0
platforms: [macos]
---

# CHG-2026-073 — Debug command templates as a published Catalog operation, and the Debug namespace closure

> **This file does not approve itself.** The new operation becomes approved
> only if a human maintainer reviews and merges the delivery PR into
> protected `main`.

> Four-category declaration: this change publishes one new Catalog operation,
> `debug.template@1`, on the existing `hdc` provider using only registered
> workflow step kinds. It adds no provider, device profile, control method,
> capability administration or destructive admission rule.

## Governance loop

1. **Concrete safety risk.** The daemon method `debug.template.run` executes a
   user-selected device command template directly, without Runtime admission,
   Job/WAL, durable intent or Artifact publication. The CLI product spec
   forbids a CLI leaf on that path, and the App path carries no evidence.
2. **Why this is not only a defect fix.** Publishing a Catalog operation is a
   reviewed vocabulary change even when every member is read-only.
3. **Golden Journey advanced.** GJ-1, GJ-2 and GJ-5 all read device state
   between steps; a template that runs as a Job gives an external agent an
   admitted, evidenced way to do that instead of a bespoke RPC.
4. **Why the scope is finite.** One task delivers the descriptor, provider
   lowering, engine artifact mapping, the `debug template list/run` and
   `debug logs` CLI leaves, tests, documentation and host evidence.
   `debug logs` adds no operation: it is the HiLog-only typed preset of
   `capture.diagnostics@1` that the App's Debug workspace already submits,
   moved into the shared preset owner so the App and CLI cannot drift.
   Migrating the App's direct template method, new template members and
   real-device acceptance stay outside this change.

## Observable behavior

Before this change, the four closed templates were reachable only through the
App's `debug.template.run` XPC method. After it, `arkdeck debug template list`
publishes the closed set with its remote command disclosure and budgets, and
`arkdeck debug template run --inputs-file <json>` submits `debug.template@1`
like any other operation: binding identity confirmation, one typed process
plan whose argv is the template's fixed tokens behind the bound connect key, a sensitive
raw output Artifact and a standard report Artifact, and a Job record that
recovery and `job result` can read. The template identity is validated
against the descriptor enum at admission; no caller text reaches argv.
`arkdeck debug logs --inputs-file <json>` submits the same bounded HiLog
window the App's Debug workspace submits (`durationSeconds` 1...600, at most
16 typed component filters, every other diagnostics leg off), through
`capture.diagnostics@1` and the same preset owner.

## Non-goals

- no raw command, argv, shell, HDC, remote path, or capability input;
- no new step kind, remote action registration or provider;
- no change to the App's direct method or its capability matrix;
- no claim that host fixtures constitute real-device acceptance.
