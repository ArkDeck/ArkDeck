# TASK-XPA-018 — Windows CLI coverage measured against the composed owners, local run, 2026-09-30

This run measures, end to end on Windows, every CLI leaf that now works against a
development-signed daemon, and counts it in the CLI coverage manifest through the mechanism #2353
added (`WINDOWS_MEASURED_LEAVES` in `rust/crates/arkdeck-cli/src/feature_coverage.rs`). It also
measures, with a client over the named pipe, which control methods the Windows daemon answers. It is
a host-only software run: no board, no `hdc`, no elevation. It is not acceptance evidence.

- Checkout: branch `agent/xpa-018-windows-coverage-refresh-20260930` on `origin/main` `659f6474`
  (#2372).
- Host: Windows 11 Pro 10.0.26200 x64, non-elevated, NTFS.

## Rule applied (maintainer ruling 9)

A leaf is added only when both of these hold:

- the Windows daemon answers its complete target contract;
- a Windows process test runs it through the real CLI, over the named pipe, against the
  development-signed daemon.

A refusal because an owner is not composed does not count. That rules out `target adopt`,
`target availability` (presence stays `unresolved` without a registered HDC), the workspace project
and preset updates and removals (no Job owner), preset registration (only a symbol preset registers
without the DevEco owner), `trace cache purge` (refused before admission without the Job owner),
and every `artifact` leaf (no Job owner).

## Leaves added

`WINDOWS_MEASURED_LEAVES` gains ten leaves:

| Leaf | Composed by |
| --- | --- |
| `target.list`, `target.show`, `target.display-name.set`, `target.display-name.clear` | the Target store (TASK-XPA-004) |
| `workspace.project.register`, `workspace.project.list`, `workspace.project.show`, `workspace.preset.list`, `workspace.preset.show` | the workspace project owner (TASK-XPA-015, #2366) |
| `trace.cache.status` | the Trace cache owner, development root (TASK-XPA-021, #2367) |

The list still holds `doctor` and `operation.list`.

The measuring test is `crates/arkdeck-cli/tests/windows_signed_runtime.rs`
`measured_owner_leaves_answer_their_contract_through_the_pipe`. Its setup:

- a copy of `arkdeck-agentd` signed with the host-trusted development signer;
- an isolated development root, spelled as the disk names it, holding the Swift adoption oracle's
  `targets.json` and one project directory.

Every leaf goes through the real CLI:

1. `target list`, then `target show`, then `target display-name set` (generation 2).
2. `workspace project register`, then `workspace project list` and `workspace project show`, then
   `workspace preset list` (empty).
3. A symbol preset is registered (setup only; the leaf is not counted), then `trace cache status`.
4. The daemon is stopped by its stop request and restarted over the same root.
5. `target show` reads the name back. `target display-name clear` answers generation 3.
   `workspace project show` returns the registered project again. `workspace preset show` and
   `workspace preset list` return the preset.

The test then asserts that each of these leaves' coverage entries is Windows `implemented` in the
regenerated `cli-feature-coverage.json`. It passed three times in a row with
`ARKDECK_DEV_SIGNER_THUMBPRINT` set; without it, it skips like the rest of the file.

## Regenerated products

- `openspec/contracts/cli-feature-coverage.json`: `arkdeck maintainer contracts export
  --contracts-directory openspec/contracts --fixtures-directory
  Packages/ArkDeckKit/Tests/ArkDeckContractTests/Fixtures/CLI`. Only this file changed: ten
  entries go from `partial` to `implemented`.
- `rust/tests/fixtures/maintainer-contracts/oracle.json`: the six pins of that file's SHA-256
  (`3a2fe73a…` → `1f017c27…`). The Swift recorder of this oracle is gone, so the pins were rewritten
  as #2353 rewrote them: the old digest was replaced by the digest of the regenerated file, and
  nothing else changed. The replay (`tests/maintainer_contracts.rs` `swifts_recorded_answers_replay`)
  is `cfg(unix)`, so it runs in CI, not here.
- `refresh-contract-digests.py`, `copy-command-registry.py`, `copy-app-capability-registry.py` and
  `generate-contract.py` `--check`: pass. The contract bundle's `owned.json` does not pin the
  coverage file.
- `docs/design/cli-machine-contracts.md`: the Windows sentence names the measured leaves.

## Windows coverage (`cli-feature-coverage.json`, 256 entries)

| | implemented | partial | notImplemented | unset (macOS-only) |
| --- | ---: | ---: | ---: | ---: |
| Before (main `659f6474`) | 8 | 126 | 6 | 116 |
| After | 18 | 116 | 6 | 116 |

#2372 (the Windows signing leaves) changes no coverage entry: `signing` is a macOS-only runtime
group (`MACOS_ONLY_RUNTIME_GROUPS`), so its entries have no Windows status.

## Methods the Windows daemon answers (client over the pipe)

`rust/scripts/windows-method-census.py <arkdeck-agentd.exe>` (new) starts the daemon over a fresh
development root. It sends every published method (105) the parameters the committed control-frame
corpus records for it, trying each recorded request until one is not `invalidParams`, and
classifies the reply. The pipe is opened as a plain file: this measures the daemon, not the
client's identity check, which the signed CLI tests hold.

Owners reported: `targets, artifacts, workspaceProjects, traceCache`.

| Class | Count | Methods |
| --- | ---: | --- |
| `result` | 7 | `doctor`, `health`, `operation.describe`, `operation.list`, `target.list`, `trace.cache.status`, `workspace.project.list` |
| `ownerRefusal` | 21 | `artifact.export`, `artifact.inspect`, `artifact.list`, `artifact.read`, `device.display-name.clear`, `device.display-name.set`, `device.observations`, `target.adopt`, `target.availability`, `target.display-name.set`, `target.show`, `trace.cache.purge`, `workspace.preset.list`, `workspace.preset.register`, `workspace.preset.remove`, `workspace.preset.show`, `workspace.preset.update`, `workspace.project.register`, `workspace.project.remove`, `workspace.project.show`, `workspace.project.update` |
| `nonConforming` | 2 | `artifact.import.list`, `target.display-name.clear` |
| `noOwner` | 75 | every other method (Job, Session, agent, human-action, control-action, capability, debug, flash, runtime bootstrap/storage/HDC, history, trace inspect/probe, import leaves except `artifact.import.list`) |

About the `ownerRefusal` rows:

- Some are the owner's own validation of a recorded macOS request. For example
  `workspace.project.register` refuses a POSIX root, and `target.show` refuses a Target this fresh
  root does not hold.
- Others are an owner refusing because a dependency owner is not composed: the Artifact owner
  without the Job owner, or the workspace mutations without the Job census.

Either way the method reached an owner this daemon composes. That makes **28 of 105** methods
answered by a composed owner (7 with a result for the corpus request, 21 refused by the owner).

The script exits 1 when any reply is `nonConforming`. On this PR's base it does, for the two
findings below. Against the daemon of the follow-up that fixes them (#2382, branch
`agent/xpa-018-nonconforming-replies-20260930`) it exits 0, with 7 results, 22 owner refusals and
76 no owner: `artifact.import.list` becomes the Import owner's refusal, and
`target.display-name.clear` the Target owner's. #2382 also runs the same census as a Windows test
(`tests/windows_method_conformance_process.rs`).

### Findings (not fixed here)

1. **`target.display-name.clear` for a Target that does not exist.** The Target owner answers
   `resourceNotFound` ("Durable target does not exist"). That code is in `target.display-name.set`'s
   published error codes but not in `clear`'s, so the control layer replaces the answer with
   `internalError` "the result does not conform to the current contract". This is shared code, so
   macOS answers the same way. Either the clear schema needs the code, or the owner needs another
   refusal for clear.
2. **`artifact.import.list` with the recorded cursor on Windows.** Without the Import owner it
   answers a result that does not conform, rather than a structured "not configured" refusal.

## Local targeted checks (Windows 11 x64)

| Command | Result |
| --- | --- |
| `cargo fmt --all --check` | pass |
| `cargo clippy --workspace --all-targets -- -D warnings` | exit 0 |
| `ARKDECK_DEV_SIGNER_THUMBPRINT=<host signer> cargo test -p arkdeck-cli` | exit 0, including `windows_signed_runtime` (3 tests) and `feature_coverage`'s Windows status test |
| `cargo test -p arkdeck-cli --test windows_signed_runtime` with the signer | 3/3, three consecutive runs |
| the four `--check` scripts above | pass |
| `PYTHONUTF8=1 sh scripts/check-sdd.sh` | 0 errors, 0 warnings |
| `git diff --check` | clean |

macOS and Linux were not built here. The change there is the coverage status and the oracle pins,
which CI's replay holds.

## CI

To be recorded, not verified.
