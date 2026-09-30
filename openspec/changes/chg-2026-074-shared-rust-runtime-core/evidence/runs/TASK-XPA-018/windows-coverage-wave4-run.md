# TASK-XPA-018 — Windows CLI coverage, wave 4 (2026-09-30)

- **Kind:** host-only, on the Windows 11 x64 reference host. No hdc was run and the DAYU200 was
  not touched.
- **Base:** measured on protected `main` `b8699903` (#2425, coverage 62), after #2407, #2410 and
  #2422. Rebased onto `cf44fcc8` (#2419, #2426): the tests pass again, and the coverage and census
  are unchanged.

## What was measured

Each leaf runs through the real CLI against a copy of the daemon signed with the host-trusted
development signer (`ARKDECK_DEV_SIGNER_THUMBPRINT` set; the test was not skipped). Each test
asserts that what it measured is Windows `implemented` in the manifest the CLI renders.

| Leaves | Test | What it proves |
| --- | --- | --- |
| `workspace project update`, `remove`; `workspace preset update`, `remove` | `windows_workspace_projects_process.rs` | With no workspace Job naming the project, it moves to a second root and back (each update answers the next generation). A symbol preset is registered, updated (timeout 600 → 300) and removed (`removed`). The remove refused while a running Job names the project, and done once it has ended, now runs at the project's current generation. |
| `runtime storage root` | `windows_session_owner_process.rs` | The Sessions root moves to an existing owner-only directory inside the development root (`rootPath` is that directory, `rootKind` not `default`), then back with `--default` (the root's `sessions`). The kept Session stays in place. |
| `capability inspect` (and `list` again) | `windows_reconcile_agent_process.rs` | Swift's capability-read oracle store `base` sits beside the Job state (`jobs-state\capabilities`). The CLI's `capability list` and `inspect` of both capabilities equal the answers Swift's owner recorded. |

## Results

- **Coverage** (`maintainer contracts export`): Windows `implemented` 62 → 68, `partial`
  78 → 72.
- **Oracle.** The six coverage-digest pins in `rust/tests/fixtures/maintainer-contracts/oracle.json`
  were substituted.
- **Method census** over this tree: 73/105 answered by a composed owner (12 results, 61 owner
  refusals), 0 non-conforming, 32 with no owner. `evidence/windows-remaining.md` is refreshed.

## Looked at, left `partial`

- `workspace preset register`: a symbol preset registers, but a build, test or signing preset
  pins a DevEco toolchain or credential that the Windows daemon does not yet register.
- `artifact import flash-bundle`: #2410 put the Flash archive reader on Windows, but the Import
  owner's flash-bundle validator is still `#[cfg(target_os = "macos")]`
  (`arkdeck-hoststore/src/import_publication.rs`). Publication is refused as before. Wiring it is
  the Import or Flash owner's slice, not a coverage change.
- `trace cache purge` still answers that it needs the Job and Artifact retention owners.
- `target adopt|availability`, `device display-name`, `job plan|submit|run`,
  `agent run|resume|abandon` and `human-action resume` wait for the Windows HDC tuple (#2426).
- #2422 made no new leaf work (its replays are hoststore-level). #2407 composes the code-sign
  helper, but the native deploy still stops at the tuple gate.

## Delegated minor decisions (pending the next rulings batch)

1. The Sessions root is moved to a directory the test creates owner-only inside the development
   root. The owner refuses a missing directory (`Session storage is unavailable or unsafe`) and
   one outside isolated development storage (`Development Session root is outside isolated
   storage`), as its selection rule says.
2. `capability inspect` is measured over Swift's recorded store, placed in the capability store
   only for the signed-CLI test, so the pipe replay of the reconcile oracle is unchanged.

## Checks

- `ARKDECK_DEV_SIGNER_THUMBPRINT=AAC23CA4D38D100996C861D9E1A68DEECD69B149`,
  `CARGO_TARGET_DIR=D:/cargo-target/w1-coverage` (the one target directory reused). The #2396
  wildcard-listener gate is present in this tree.
- `cargo fmt --all --check`: clean.
- `cargo clippy --workspace --all-targets -- -D warnings`: clean.
- `cargo test -p arkdeck-agentd -p arkdeck-cli`: 113 result lines ok, 0 failed, no `SKIPPED` (114 after the rebase, with #2426's test).
- The same test run with an 8.3 short `TEMP`/`TMP` on C: (`…\SCRATC~1\SHORTP~1`): 113 ok.
- `PYTHONUTF8=1 sh scripts/check-sdd.sh`: 0 errors, 0 warnings.
- `git diff --check`: clean.
