# TASK-XPA-005 — `human-action.resume` admits an unsigned control-action preview tool

Change: CHG-2026-074-shared-rust-runtime-core. A contract-only slice found while running the confirmed
HDC restart on Windows with the registered DevEco Studio `hdc.exe` (CHG-2026-078 c2).

Branch `agent/xpa-005-resume-signature-schema-20261004`, one commit on `origin/main`.

Host: the Windows 11 x64 reference host. No device, HDC or installed state was touched by this slice;
the finding came from the restart slice's live run (below).

## Why

A control action's preview names its tool's native signature, one projection
(`HDCControlActionRecord`; Swift's `HDCControlActionContract` validates it with `identifier` and
`teamIdentifier` each optional text and `state` one of `unsigned`, `adHoc`, `verified`).
`runtime.hdc.impact-preview`, `runtime.hdc.restart` and `control-action.*` publish it with an
identifier and a team each a string or null (#2037, #2052, #2101). `human-action.resume` carries
the same projection twice — the console challenge's `controlAction.preview.tool.signature` and the
consumed action's `preview.tool.signature` — but its schema admitted only a string identifier and
a null team, the values Swift's fixture tool happened to record.

DevEco's Windows `hdc.exe` is Authenticode NotSigned (`Get-AuthenticodeSignature`), so the Runtime
reports `{state: unsigned, identifier: null, teamIdentifier: null, …}`. In the restart slice's live
run (2026-10-04 09:08Z, real c2 `hdc.exe`, no board) the impact preview and the restart's approval
passed, and the console challenge was replaced by `internalError: the result does not conform to
the current contract`: no Windows restart could be approved.

## What

- `generate-control-contract.py` `SHARED_MEMBERS`: `runtime.hdc.impact-preview`'s recorded
  `result.preview.tool.signature.identifier` and `.teamIdentifier` are samples of the same members
  in `human-action.resume` (`result.controlAction.preview.tool.signature.*` and
  `result.preview.tool.signature.*`).
- `--derive-method-schemas` over the committed corpora of `human-action.resume`,
  `runtime.hdc.impact-preview` and `agent.run` (the generator needs `agent.run`'s frames for the
  existing shared members of `human-action.resume`). The only schema change is four lines in
  `spec/control/methods/human-action.resume.json`: `identifier` `string` → `["null","string"]` and
  `teamIdentifier` `null` → `["null","string"]`, at both copies — exactly the sibling definition,
  no broader. The corpus selection the run rewrote was restored, so no corpus line changes; the
  line-ending-only rewrite of the Swift protocol file was restored too.
- `generate-contract.py --write` (the baseline's method-schema digests and input digest) and
  `generate-clientkit.py --write` (the one schema digest in `ControlContract.g.cs`), LF.

## Proof

- `rust/crates/arkdeck-contract/tests/control_action_preview_signature.rs`:
  - `every_copy_of_the_preview_tool_signature_is_the_sibling_definition`: every preview `tool`
    signature schema in `runtime.hdc.restart`, `control-action.show|list|reconcile` and
    `human-action.resume` equals `runtime.hdc.impact-preview`'s, so the copies cannot drift again;
  - `an_unsigned_tool_s_challenge_and_consumed_action_conform`: the recorded challenge and
    consumed-action answers with the unsigned signature grafted in validate.
  - Negative control: with main's `human-action.resume.json` both fail.
- `windows/ClientKit.Tests` `ControlActionSignatureTests.AnUnsignedToolsChallengeAndConsumedActionDecode`:
  the C# client decodes both answers with the unsigned signature through `Wire.DecodeResponse`.
- Swift: not run (no macOS host here). The committed corpus is unchanged and the schema only widens,
  so `ControlMethodSchemaContractTests` sees the same frames against a wider schema; Swift's own
  `HDCControlActionContract` already admits a null identifier and an `unsigned` state.

## Delegated minor decision, pending the next rulings batch

1. **Sibling consistency.** `human-action.resume`'s two copies of a control action's preview tool
   signature admit what `runtime.hdc.impact-preview`, `runtime.hdc.restart` and `control-action.*`
   admit for the same projection. No Swift oracle records an unsigned tool; the lead approved the
   widening on 2026-10-04 on sibling-consistency grounds.

## Gates

The PR description gives this commit's gate output.
