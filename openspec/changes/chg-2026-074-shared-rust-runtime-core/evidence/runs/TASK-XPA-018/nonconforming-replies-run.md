# TASK-XPA-018: the two non-conforming replies the Windows method census found. Local run, 2026-09-30

The method census of #2378 (`rust/scripts/windows-method-census.py`) found two control methods
whose answer on the Windows development daemon did not conform to the published contract. In both,
the control layer replaced the answer with `internalError` "the result does not conform to the
current contract". This slice fixes both on the contract side, which is where Swift says the defect
is.

Checkout: branch `agent/xpa-018-nonconforming-replies-20260930` on `origin/main` `659f6474`. Host:
Windows 11 Pro 10.0.26200 x64, non-elevated. This is a host-only software change.

## 1. `target.display-name.clear` of a Target that does not exist

- **What the Rust owner answers:** `resourceNotFound` "Durable target does not exist",
  `{phase: targetDisplayNameOwner, newDispatchCount: 0}`. The code is in `target_owner.rs`, shared
  by macOS and Windows.
- **What Swift answered.** Checked in the Swift source before its removal (`32db20b1~1`):
  - `DeviceBootstrap.clearTargetDisplayName` throws `RuntimeTargetDisplayNameFailure(
    "resourceNotFound", "durable target does not exist or is an inactive alias")`, exactly as
    `setTargetDisplayName` does.
  - `AgentDaemon` answers it under phase `targetDisplayNameOwner`.
  - Swift's CLI mapper (`CLIControlMethodRegistry`) names `resourceNotFound` among that owner's
    refusals for both `set` and `clear`.
- **Why the published schema lacked it.** The committed corpus never recorded a clear of an absent
  Target; its only clear refusal is a generation conflict. So `clear`'s derived `errorCode` enum
  lacked `resourceNotFound` and `invalidInput`, while `set`'s has both.
- **Verdict: the schema is wrong, the owner is right.** The fix widens the schema.
- **macOS effect.** Before, a macOS `target display-name clear` of an absent Target also answered
  the replaced `internalError`. It now answers `resourceNotFound` with the owner's details, as Swift
  did. The CLI already maps it to `resourceNotFound` (`failure_mapping.rs`,
  `targetDisplayNameOwner`). Nothing else on macOS changes. The message text differs from Swift's,
  which is T2.

## 2. `artifact.import.list` without the Import owner

- **What is answered.**
  - The Windows host has no Import owner. The control layer's default `import_resource` answers
    Swift's `RuntimeImportControlHandler` refusal: `operationUnavailable` "Import owner services
    are unavailable", `{phase: importOwner, newDispatchCount: 0}`.
  - The macOS host answers the same when a composition lacks the Import, Artifact or Target owner.
    The macOS production daemon always composes them.
- **Why it did not conform.** `artifact.import.list`'s published enum lacked `operationUnavailable`.
  Every other `artifact.import.*` method has it, from recorded frames of the same refusal.
- **Fix.** Keep the existing no-owner answer; the published enum gains the code.
- **Why not the ruling-18 shape.** It would need `phase: preAdmission`, but every Import method
  answers this refusal with `phase: importOwner`. Changing only `list` would fork one owner's
  answers. The existing shape already fits the method's error details (`phase`,
  `newDispatchCount`).
- **macOS effect.** A macOS daemon without its Import owner (not the production composition) now
  answers `artifact.import.list` with the refusal instead of the replaced `internalError`.

## Generated, not hand-edited

1. `Packages/ArkDeckKit/Scripts/generate-control-contract.py` gains two owner vocabularies:
   - `TARGET_DISPLAY_NAME_OWNER_ERROR_CODES` for `target.display-name.set|clear`: Swift's CLI list
     for that owner;
   - `IMPORT_OWNER_ERROR_CODES` = `operationUnavailable` for `artifact.import.*`.
2. `--derive-method-schemas` was run over the committed corpora of `target.display-name.clear` and
   `artifact.import.list` only (15 frames).
   - `clear` gains `invalidInput` and `resourceNotFound`; `import.list` gains
     `operationUnavailable`. Nothing else in either schema changes except
     `x-arkdeck-sampleCounts`, which counts the committed corpus: clear 7/9/2 → 2/3/1, import.list
     request/result 16/13 → 12/9. This is the same drift as #2370, because the Swift recorder is
     gone.
   - `set` and the other import methods already publish their codes and were not re-derived.
3. `rust/scripts/generate-contract.py --write` refreshed `spec/baselines/swift-single-v1.json`.
4. `windows/scripts/generate-clientkit.py --write` refreshed the two schema digests in
   `windows/ClientKit/Generated/ControlContract.g.cs`.
5. The generator output was normalised to LF, and the files it rewrote with only line-ending
   changes (the Swift protocol file, the two corpus files) were restored. Both `--check`s pass.

## Test: every method answers in its contract

`crates/arkdeck-agentd/tests/windows_method_conformance_process.rs` (new, Windows) runs the census
as a test. Setup:

- the real daemon over a development root holding the Swift adoption oracle's Target;
- every one of the 105 published methods, sent the committed corpus's requests in order until one
  is not `invalidParams`, as the census script sends them.

It asserts that no reply is the non-conforming replacement, and asserts the two fixed answers
exactly:

- `clear` of `TGT-ffffffffffff` is `resourceNotFound`, `{phase: targetDisplayNameOwner,
  newDispatchCount: 0}`, and a clear of the oracle Target still answers its result;
- `artifact.import.list` is the exact Import-owner refusal.

In check-contracts' published view, whose merge-base schemas predate the widening, the two methods
may still be replaced; nothing else may be. This follows #2370's pattern.

Negative control: with the two schemas reverted to main's, the test fails with
`target.display-name.clear must publish resourceNotFound`. It takes about 0.5 s, so it runs in the
ordinary Windows test run.

The census script itself (#2378, not on main) gains a non-zero exit when any reply is
`nonConforming`, in that PR.

## Local targeted checks (Windows 11 x64)

| Command | Result |
| --- | --- |
| `cargo fmt --all --check` | pass |
| `cargo clippy --workspace --all-targets -- -D warnings` | exit 0 |
| `ARKDECK_DEV_SIGNER_THUMBPRINT=<host signer> cargo test -p arkdeck-contract -p arkdeck-control -p arkdeck-cli -p arkdeck-hoststore -p arkdeck-agentd` | exit 0 |
| `generate-contract.py --check`, `generate-clientkit.py --check` | pass |
| `dotnet build windows/ArkDeck.Windows.slnx -c Release` | 0 warnings, 0 errors |
| `dotnet test` | App.Tests 37 passed; ClientKit.Tests 31 passed, 1 skipped; App.UITests 19 skipped (their own skip, unrelated) |
| `PYTHONUTF8=1 sh scripts/check-sdd.sh` | 0 errors, 0 warnings |
| `git diff --check` | clean |

macOS and Linux were not built here. The macOS effect is the two answers above.

## CI

To be recorded, not verified.
