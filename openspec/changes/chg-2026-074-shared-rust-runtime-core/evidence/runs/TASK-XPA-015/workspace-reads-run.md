# Workspace reads on the Rust daemon (TASK-XPA-015, M3)

The Rust daemon now plans, admits, runs, reconciles and publishes the four
read-only workspace operations as Swift does:

- `workspace.inspect-source@1`: the inspector a host configured
  (`ARKDECK_WORKSPACE_INSPECTOR`) searches a registered project's root for a
  symbol;
- `workspace.read-source-range@1`: the profile's pinned source reader
  (`/usr/bin/sed`) reads a bounded line range of a declared file;
- `workspace.inspect-git-status@1` and `workspace.inspect-diff@1`: the
  profile's pinned source-control tool (`/usr/bin/git`) reads the working
  copy's status and a bounded diff.

A new Swift oracle of 49 frames replays byte for byte, with the published
products and the durable records of the two reads whose receipt was lost.

Base: protected `main` `24fb6c692` (#2187); written on `fa193b758` (#2184) and
rebased without conflict.

| Already on `main` | This change | Still remaining (M3) |
|---|---|---|
| The workspace project and preset owner, the DevEco pins and the credential owner (#1989, #2056, #2073, #2076, #2153); `prepare-isolated-copy`, `apply-patch`, `revert-patch`, `build-openharmony`, `sign-openharmony-hap` (#2145, #2146, #2153) | The Swift read oracle; plan, admission, run, reconcile and result of the four reads; the configured inspector read by both compositions; an empty product published as Swift publishes it | `create-checkpoint`, `sweep-isolated-copies`, `run-tests`, `symbolize-crash`; the `operation.list`, project and preset availability projections; GJ-5 |

## The oracle

`WorkspaceReadOracleContractTests` composes Swift's daemon composition over
two fabricated projects under `/private/tmp/arkdeck-workspace-read-oracle` —
`ReadOracleProject`, a committed git working copy with a source reader, and
`PlainOracleProject`, with neither — and drives every read through the
production control plane: `RuntimeControlPlaneHandler` over a
`RuntimeJobEngine` whose provider is `WorkspaceProvider` (the registered
roots and the configured inspector) delegating to `WorkspaceOperationsProvider`
over both profiles, `EvolutionWorkspaceManager` as its isolation manager, and
`DescriptorBoundProcessDispatcher` over `CombinedWorkspaceExecutableResolver`.
It records, in `rust/tests/fixtures/workspace-read-oracle/`:

- 49 frames in order. The inspection: a symbol found; a symbol absent (exit
  1, an honest empty answer, published as an empty product); an unknown
  project (`unknownProject("…")`), a scope with a separator and a symbol with
  a line feed (`malformedScope("…")`) refused before admission; a receipt lost
  after the child ran (parked, reconciled as not executed, failed, never run
  again). The range: a range read; an inverted range, a path outside the
  profile's scope, a traversal, and the plain project that has no reader,
  refused by name; a missing file (sed exits 1: the Job fails and publishes
  nothing). The status: clean, then after an edit and a new file; the plain
  project refused; a receipt lost after the child ran. The diff: against
  `HEAD`; an option as the revision and an absolute pathspec refused; a
  revision git does not know (exit 128: the Job fails).
- The six published products, and the durable records of the two parked
  Jobs as they stood when parked — the inspection's persisted action
  (`workspace.inspectSource`: project, symbol and scope, never the root) and
  the status's (`workspace.action`, the canonical typed action).

`grep.sh`, `sed.sh` and `git.sh` stand in for `/usr/bin/grep`, `/usr/bin/sed`
and `/usr/bin/git` with fixed bytes, so the plan digests repeat on every host;
each runs the host's own tool with the lowered argv in a closed environment
that reads no locale or git configuration. The working copy is committed
with a fixed author and date. Two recordings were identical and the checked-in
fixture was then verified; every frame validates against the published
method schemas, so no contract input changes.

## Swift, as ported

**The inspection** is `WorkspaceProvider`'s, not the profile's. It is
available when an inspector is configured
(`provider_tool_unavailable`/`no_workspace_inspector_configured` otherwise)
and some registered root exists
(`workspace_preset_unavailable`/`no_workspace_project_registered`); its roots
are every registered project's pinned root, whether or not the project's
profile resolved. The action takes the root the project registered, then
screens the scope (1…120 ASCII letters, digits or `*?.-_[]`, no `..`, no
leading dash) and the symbol (1…200 characters, no NUL, no line feed of its
own — a carriage return and its line feed are one character). The plan is one
process: the inspector's digest, `-r -n --include <scope> -- <symbol> <root>`,
120 s, and no working directory. Exit 0 or 1 verifies (`matches` `1+` or `0`,
the `truncated` flag carried, never refused); any other exit fails the step
`inspectorExit<status>`.

**The other three** go through `WorkspaceOperationsProvider`'s preamble (the
profile the request names, the operation available in it, a stated revision
enforced) and the tool the profile offers: source control for the status and
the diff, the source reader for the range. The argv, in the profile's root:
`-C <root> status --porcelain=v1 --untracked-files=all -- .`;
`-C <root> diff --stat <revision> -- <pathspec>` after the revision
(`[A-Za-z0-9._\-^~@{}]`, no `..`, no `/`, no leading dash) and the pathspec
(`[A-Za-z0-9*?.\-_\[\]/]`, no `..`, no leading `/` or dash) are screened;
`-n <start>,<end>p <path>` after the range (`start ≥ 1`, `end ≥ start`, fewer
than 2,000 lines) and the path (1…240 characters, no leading `-` or `/`, no
`..`, no NUL, matched by a profile scope, joined to the root as
`URL.appending(path:)` joins it) are. A truncated output fails
`workspace.outputTruncated`; a non-zero exit fails `workspace.gitStatusFailed`,
`workspace.diffFailed` or `workspace.sourceRangeFailed`; otherwise the output
summary and `dirty`, `changed` or `empty`.

**Run.** Swift runs a workspace step in its safe-boundary cancellation mode
whatever the catalog declares: the typed action is materialized and lowered
again, persisted before its write-ahead intent, the child started only then
and never cancelled mid-run; a request that arrived meanwhile is honoured at
the next boundary. The product is the tool's own standard output
(`source-inspection.txt`, `source-range.txt`, `git-status.txt`,
`diff-summary.txt`), published after the correlated outcome through the
redacting text path. A failed read publishes nothing.

**Reconcile.** A read writes nothing: the persisted action is materialized
and, as the providers answer, confirmed not executed; the Job fails with
`executionConfirmedNotPerformed` and is never run again.

**Admission.** `hostOnly` under the default read-only policy: no capability
is issued, reserved or consumed, and no mutation lane is taken.

## The tools

- The inspector is the one `ARKDECK_WORKSPACE_INSPECTOR` names, read now by
  both compositions (the production one no longer reports it as an input it
  leaves unread). As Swift's `FixedExecutableResolver`, it must be an explicit
  absolute path naming a regular executable file, resolved as Foundation
  resolves it and pinned by the digest of its bytes when the daemon starts;
  one that is not fails the start. Its dispatch opens it by that digest and
  runs the retained inode, so bytes that changed later are refused, never
  run.
- `/usr/bin/sed` and `/usr/bin/git` follow the `/usr/bin/patch` precedent the
  coordinator ruled on (2026-09-25, C3): absolute paths, hashed when the
  profile is composed (first use), re-measured at every plan and run (a
  changed file makes the operation unavailable, `workspace.toolIdentityDrift`,
  before any intent), opened by the pinned digest at dispatch; argv only, no
  shell, `/dev/null` as stdin, each stream bounded to 8 MiB (Swift's
  dispatcher default).
- Child environment, as for the patch and build children: the Rust runner's
  clean base (`PATH=/usr/bin:/bin LANG=C LC_ALL=C`), where Swift's children
  inherit the daemon's `PATH`, `HOME`, `TMPDIR` and `LANG`. For git this means
  no user configuration is read (no `HOME`); the porcelain status and the
  diff stat are the forms git keeps stable across configurations. Declared.

## Choices on the refusing side

- **A provider refusal at run time fails the Job** before any intent (the
  profile or its tool changed since admission), as for every workspace
  operation on this Runtime; Swift's run escapes and leaves the Job `running`.
- **Legacy environment roots** (`ARKDECK_WORKSPACE_PROJECTS`) stay unread:
  the inspection reads the registered roots only.

## One shared change: an empty product

Swift's Artifact store publishes an empty product as it publishes any other;
the oracle's absent symbol and clean status publish zero-byte products that
verify. The Rust publisher refused an empty payload (the platform's
`publish_document` refuses zero bytes), which failed such a Job
`artifactPublicationFailed`. It now writes the payload through
`replace_document`, the same synchronized fresh-file publication without that
refusal; every other check (existing payload, quota, seal, index) is
unchanged.

## `operation.list` and project answers

Not changed by this PR. `operation.list` still reports every workspace
operation `provider_not_registered`, and `workspace.project.list/show` the
restart projection; both follow in the projection slice. (The provider's
per-profile availability is now coded as `operation.list` codes it, in
preparation; nothing reads the codes yet.)

## Tests

- `workspace_read_oracle` (hoststore, 3):
  - the 49 frames replayed in order over the same fixed root, profiles,
    registered roots, tools and clock, every answer Swift's (the plan's
    additive review digest aside); the published products and the two parked
    records byte for byte; ten children started in all;
  - a pinned tool (git) changed after admission refuses the fresh action
    before any intent, with nothing started; an inspector changed after the
    daemon composed it is refused at its dispatch and never runs (a marker the
    changed bytes would write is never written);
  - over a production-shaped profile the host's own `/usr/bin/grep`,
    `/usr/bin/sed` and `/usr/bin/git`, in the clean base environment, publish
    exactly what each prints when run directly with the provider's argv.
- `workspace_read_process` (agentd, 1): the production daemon over a
  temporary home with `ARKDECK_WORKSPACE_INSPECTOR=/usr/bin/grep`, a
  registered OpenHarmony project inside a git working copy, restarted to
  compose it: each read plans under the default read-only policy, runs,
  verifies and publishes what the host tool prints (the inspection's account
  home redacted, as Swift's store redacts text), and an option given as the
  revision is refused by name.
- `production_composition`: the configured inspector is no longer reported as
  an input this Runtime leaves unread.
- Unit tests: the screening of scopes, symbols, revisions, pathspecs and
  readable paths (Swift's `Character` semantics measured with `swiftc` on this
  host: a CRLF is not a line feed, `..` and a leading `-` or `/` are whole
  characters, `URL.appending(path:)` drops every trailing separator and
  rewrites nothing else); the verdicts; the persisted actions' round trip.

Mutations (`scratchpad/s28/mutate_a.py`), each caught by a failing test and
restored by checksum:

| Mutation | Caught by |
|---|---|
| A scope with a separator accepted | the recorded sequence |
| A symbol with a line feed of its own accepted | the recorded sequence |
| The inspection's argv without its option terminator | the recorded sequence (the plan digest) |
| The status without its `-- .` pathspec | the recorded sequence (the plan digest) |
| A pinned tool that drifted left available | the drift test |
| The dispatch opens the tool by its current digest, not the pinned one | the drift test (the changed inspector ran) |
| A lost read reconciled as still unknown | the recorded sequence |
| An empty product refused | the recorded sequence |
| The inspection run in the project root | the recorded sequence (the plan digest) |
| An inverted line range admitted | the recorded sequence |
| A path outside the profile's scope readable | the recorded sequence |
| The persisted inspection naming its root | the recorded sequence (the parked record) |

The first variant of the drift mutation (a guard that could never hold) did
not compile, so it proved nothing; the mutation that removes the refusal is
caught.

## Local targeted checks

With `CARGO_BUILD_JOBS=2` and this tree's own target; logs are
`/private/tmp/arkdeck-s28-*.log`.

| Check | Command | Exit | Log |
|---|---|---|---|
| Format | `cargo fmt --all --check --manifest-path rust/Cargo.toml` | 0 | — |
| Lints | `cargo clippy --manifest-path rust/Cargo.toml -p arkdeck-hoststore -p arkdeck-agentd -p arkdeck-soak --all-targets -- -D warnings` | 0 | `arkdeck-s28-a-clippy.log` |
| Lints, cross | the same with `--target x86_64-unknown-linux-gnu` and `--target x86_64-pc-windows-msvc` | 0, 0 | `arkdeck-s28-a-clippy-<target>.log` |
| Tests | `cargo test --manifest-path rust/Cargo.toml -p arkdeck-hoststore -p arkdeck-agentd -p arkdeck-soak --no-fail-fast` (after `cargo build -p arkdeck-cli`): 101 targets, 785 passed, 0 failed, the 14 existing ignored | 0 | `arkdeck-s28-a-tests.log` |
| The oracle | `cargo test -p arkdeck-hoststore --test workspace_read_oracle`: 3 passed | 0 | in the tests log |
| The daemon | `cargo test -p arkdeck-agentd --test workspace_read_process --test production_composition`: 1 and 12 passed | 0 | in the tests log |
| Swift recording | `ARKDECK_RUST_WORKSPACE_READ_RECORD=<dir> sh Packages/ArkDeckKit/Scripts/run-swiftpm.sh test --filter WorkspaceReadOracleContractTests`, twice (identical), then in verify mode over the checked-in fixture | 0, 0, 0 | `arkdeck-s28-swift-read-{record-1,record-2,verify-1}.log` |
| Read-only surface | `check-readonly.py --bin-dir <target>/debug` (validation venv) over the freshly built `arkdeck` and `arkdeck-agentd` | 0 | `arkdeck-s28-a-check-readonly.log` |
| Mutations | `scratchpad/s28/mutate_a.py`, every source restored by checksum | 12/12 caught | `arkdeck-s28-a-mutations{,-5}.log` |
| SDD | `sh scripts/check-sdd.sh` (validation venv) | 0 | `arkdeck-s28-a-check-sdd.log` |

No daemon, child or temporary root of these tests was left running or
behind. Not run: `generate-contract.py --check` and `check-contracts.py`, as
no contract input changed (the new frames live under `rust/tests/fixtures/`
and validate against the published schemas); the Swift class with
`--parallel` (it holds one test, over a root no other class uses); the App,
signing, the installed service and real devices, none of which this change
touches.

## CI

Pending.
