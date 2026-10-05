# Windows workspace Session publication — 2026-10-06

Task: `TASK-XPA-011`, `CHG-2026-074`.
Base: protected main `258e6620e4f18968fb7884ebe2b036bec1f4d2ea` (PR #2596).
Catalog digest: `c6e92eb252fe7653ed303a9ce34d12635bbc5f71ffb2a54fb8eb1fa3a9b99036`.

The signed current-main RC published the retained failed HAP Session. A fresh,
serial capture Run contains 76 entries: the HAP receipt is published and
settled; the isolated-copy, build and test baseline products were read
completely; original patch import inspection still refused with
`recordUnreadable` and `newDispatchCount: 0`. Complete public Job and event
pages identify two confirmed successful workspace build/test Jobs whose
publication failed before their original Journals were finalized. Their
original consumed Runtime authority is complete and non-null. The Runtime
was stopped using typed `runtime.service.uninstall`; final typed status
confirmed its socket absent and state preserved. No new repair import,
patch, build, test or HAP execution was dispatched in this Run.

The earlier 28-entry Run has two sequence-27 rows caused by overlapping
read-only captures. It remains byte-for-byte retained and is invalid for
aggregate evidence. Fresh captures contain independent reads; old rows were
not moved, renumbered or spliced. The retained HAP reconciliation occurred
once in the original Run and was not repeated.

## Implemented behavior and scope

The accepted scope is the honest host/workspace target and original audit
projection in CHG-2026-075's `spec-delta.md` and
`evidence/runs/TASK-SVC-002/session-publication-scope-review.md`, approved in
[PR #1772](https://github.com/ArkDeck/ArkDeck/pull/1772). Existing workspace
Catalog writes use `deviceMutation` admission with `binding: none`; their
Provider effects remain local workspace changes. Requiring a physical HDC
observation for their Session was an implementation omission.

The composer now projects the five exact current Catalog workspace mutations
with an honest host target, empty device binding history, the actual pinned
host tool version and the complete original consumed Runtime audit. It proves
the original canonical materialization and step-set digests, host Journal
intent/outcome, request target/project and Artifact association. Its target
retains a physical-associated input's original request scope without inventing
device observations or bindings. Schema and strict Rust decoding close this
branch to the same five operations, exact steps, argument shapes and non-null
consumption; patch Artifact digests must be real matching lowercase SHA-256.

Windows external versions come from bounded embedded PE fixed FileVersion
resources read through the retained, revalidated executable handle. The
Runtime's compiled workspace package version applies only to the exact native
identity and SHA of its current executable. A copied executable cannot borrow
that version. No version child is launched.

Live execution retains its pre-write canonical materialization and compares
it with the original consumed plan at publication. A retained retry must
rematerialize the identical original plan; changes to facts bound into that
plan remain unpublishable. A historical patch with a changed expected revision
cannot acquire a replacement original plan. This increment does not invent
missing historical patch plans.

Publication retries serialize the fresh durable Job and its original Journal
through receipt persistence, reject source changes, proposals, torn or unknown
outcomes, and preserve already settled receipts. They dispatch no operation
and create or change no authority. Task-private regressions use real
planner/admitter/runner owners with a counted stand-in tool port; they are
development tests, not device acceptance evidence.

## Local targeted checks

All Rust checks use `CARGO_BUILD_JOBS=2`, the worktree's independent target
directory, and the host heavy-task limiter. Logs below remain outside the
repository under `tools/logs` in the local tools workspace.

| Check | Result | Log |
| --- | --- | --- |
| `cargo test --manifest-path rust/Cargo.toml -p arkdeck-platform --lib tool_version` | exit 0; 7 passed | `workspace-session-platform-version-fixed.log` |
| `cargo test --manifest-path rust/Cargo.toml -p arkdeck-hoststore --lib session_publication::workspace_publication::tests` | exit 0; 6 passed | `workspace-session-producer-fixed.log` |
| `cargo test --manifest-path rust/Cargo.toml -p arkdeck-hoststore --test terminal_publication_retry` including the actual patch runner | exit 0; 7 passed | `workspace-session-terminal-apply-fixed.log` |
| `python -X utf8 rust/scripts/test_contract_checks.py PreconsumeManifestSchemaTests WorkspaceManifestSchemaTests` | exit 0; 6 passed | `workspace-session-schema-repaired.log` |
| `cargo clippy --manifest-path rust/Cargo.toml` for platform, hoststore and the 9 directly affected consumer crates, `--all-targets -- -D warnings` | exit 0 | `workspace-session-clippy-final.log` |
| Exhaustive per-package `cargo fmt --manifest-path rust/Cargo.toml -p <package> --check` for all 13 packages | exit 0 | `workspace-session-fmt-check.log` |
| `sh scripts/check-sdd.sh` | exit 0 | `workspace-session-sdd-explicit.log` |
| `cargo build --manifest-path rust/Cargo.toml -p arkdeck-cli -p arkdeck-agentd` | exit 0 | `workspace-session-cli-daemon-build.log` |
| CLI `windows_signed_runtime` target after the required sibling build | exit 0; 7 manual cases passed | `workspace-session-cli-signed-runtime.log` |
| `cargo test --manifest-path rust/Cargo.toml -p arkdeck-hoststore` | exit 0; 559 passed, 7 existing ignored; includes all focused cases above | `workspace-session-hoststore.log` |
| Platform plus bootstrap/client/CLI/HDC/ArkForge/workspace/rockchip-binding test targets | 877 passed, 3 existing ignored; initial exit 101 solely for the missing-sibling CLI target, resolved by its exit-0 rerun above | `workspace-session-platform-consumers.log` |
| `cargo test --manifest-path rust/Cargo.toml -p arkdeck-agentd -p arkdeck-soak` | exit 0; 188 passed, 4 existing ignored | `workspace-session-daemon-soak.log` |

The completed crate suites contain 1,631 distinct passing Rust cases and 14
existing ignored cases, counting the summary-free signed CLI target's seven
manual cases and not adding focused reruns twice. The platform/consumer
run's other targets completed successfully; its initial signed Runtime failure
was the missing daemon sibling in this fresh target directory. Both siblings
were built and that exact target then passed without source/assertion changes.

Initial default-sandbox target creation refused access before compilation.
The controlled executor reached fixture-only compile errors, corrected
without changing acceptance requirements. Early producer fixtures used an
invalid capability-reference namespace, an external executable without an
authoritative embedded version, and a foreign Artifact binding key; corrected
fixtures now pass. A duplicated partial schema branch and mechanical clippy
warnings were fixed. The additional actual patch case reached succeeded and
published, then failed a fixture readback from the wrong isolation parent;
only that fixture path was corrected. All failed logs remain retained.

The exact `cargo fmt --all --check` command exceeds the native Windows command
length at this worktree path. The exhaustive 13-package checks cover the same
source tree. No formatter or lint requirement was relaxed.

Manifest schema is not a control generator input or a rendered owned-contract
bundle member. Catalog/control identity, generated vocabulary/pins and feature
coverage inputs are unchanged. The retired Swift Runtime validator is not
reintroduced. Coverage remains 149 implemented, 11 partial, 2 notImplemented
of 162 Windows-required features, plus 101 macOS-only features.

## CI

Not pushed at the time of this local record. The preceding PR #2596 passed
SDD Guard run 37341657944 and Swift aggregate run 37341657960 at head
`64370a4916f5d8c4bdc73e90b1c0f36ba26d18c4`; those runs do not validate this
increment. Main's required checks were independently read back as `guard`
and `swift`. This increment's exact PR/head/run conclusions will be recorded
in the subsequent delivery evidence after CI, without amending a green head.

GJ-1 is skipped at the user's request and remains incomplete. Independent
observations and host continuation checks are separate from formal GJ-2/3/5
passes while their prerequisites or paired assets are missing. No
`REAL_DEVICE_PASS` or hardware-evidence declaration is made here.
