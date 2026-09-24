# The isolated-copy Job, recorded through the control plane (TASK-XPA-015, M3)

This change is Swift-only. One Swift contract test drives a whole
`workspace.prepare-isolated-copy@1` Job through the production control plane —
`job.plan`, `job.submit`, `job.run`, `job.result` — over a Runtime whose only
provider is the production `WorkspaceOperationsProvider` and whose isolation
manager is the production `EvolutionWorkspaceManager`. It records the four
frames in order, and the copy the Runtime owns afterwards. The Rust port of
the operation then replays it without touching Swift, as tasks.md r11 (7)
asks.

Base: protected `main` `ec7436f6`.

| Already on `main` | This oracle delivers | Still remaining (M3) |
|---|---|---|
| The workspace project and preset owner, and the DevEco toolchain pin, on the Rust owner (#2056, #2073, #2076) | `WorkspaceIsolationOracleContractTests`; four recorded frames and the durable copy in `rust/tests/fixtures/workspace-isolation-oracle/` | the Rust port of `prepare-isolated-copy`, then `apply-patch`/`revert-patch` and `sweep-isolated-copies`; the other nine `workspace.*` operations; GJ-5 |

## Why a new recording

The committed `job.plan`, `job.submit`, `job.run` and `job.result` corpora
carry no frame of any of the 13 `workspace.*` operations, and each corpus is
deduplicated by shape, so no sequence could be replayed out of them. This
records one causal sequence, as `workspace-mutation-oracle` records the
project and preset control plane.

## What the recording shows

| Step | Answer |
|---|---|
| `job.plan` | planned, not admitted: `jobAdmitted` false, with the materialized plan digest, the effective effect and the authorization policy |
| `job.submit` | `job-825787507429b81047c9726a1373a83b` |
| `job.run` | `succeeded` |
| `job.result` | terminal, with the operation's one derived artifact |

The copy the Runtime owns afterwards is `evo-e2ae7c7152894a5b51d95e92` under
`evolution-workspaces/`, registered as `evolution-e2ae7c7152894a5b51d9` and
held by `runtime-job-8257…`, the Job that asked for it. Two facts the Rust
port has to match, and neither is visible from the descriptors:

- **The copy holds the whole profile scope.** The request's narrower globs
  become the copy's own `allowedPaths`, which is what may be written in it,
  not what is copied into it. The recorded tree carries both source files
  while `allowedPaths` carries one.
- **Every identity is deterministic.** The clock is fixed and the request
  carries no path, so the Job's identity, the copy's identity and its base
  revision repeat exactly. A Rust replay can compare them literally.

## How the oracle is held

`provenance.json` pins the SHA-256 of every other file. Run again without the
recording variable, the test plays the same sequence and compares: every
checked-in frame against the answer this handler gives now, the manifest once
host paths are set aside, and the copied tree by path and digest. A drift in
the provider, the manager or the control plane fails the test rather than
silently re-recording.

## What the Rust slices still need

- `prepare-isolated-copy` needs no external tool and no capability: its
  authorization is `defaultReadOnly` and its execution is in-process file
  work. It is the first Rust slice.
- `apply-patch` and `revert-patch` run `/usr/bin/patch`. The coordinator has
  ruled that this stays an absolute path pinned by SHA-256 at first use, with
  the argv Swift builds, rather than a registered toolchain reference: the
  design's "`/usr/bin/git` replaced by a registered toolchain reference" line
  is about project toolchains (git, hvigor, ohpm), and `patch` is a system
  tool Swift itself calls by absolute path. Recorded here as an
  interpretation of design §J.4's TASK-XPA-015 line, to be restated the next
  time that document is revised.
- Measured for those slices: `/usr/bin/patch` writes byte-identical stdout and
  stderr for the same input, on success and on a refused hunk, so the artifact
  may keep embedding their digests as Swift does.
- `workspace.build-openharmony@1` cannot pass on this host at all: the bundled
  `ninja` is x86_64 and the host has no Rosetta.

## Local targeted checks

| Check | Exit | Result |
|---|---|---|
| `run-swiftpm.sh test --filter WorkspaceIsolationOracleContractTests` with `ARKDECK_RUST_WORKSPACE_ISOLATION_RECORD` and `ARKDECK_CONTROL_FRAME_LOG` | 0 | 1 test, 0 failures; the recording |
| The same without the variables, against the checked-in oracle | 0 | 1 test, 0 failures (0.14 s) |
| `sh scripts/check-sdd.sh` | 0 | 0 errors, 0 warnings |

## CI

The PR's `guard` and `swift` aggregate are the unified gate. The Swift lane
ran because a Swift test changed. Both were green at head `25ae8556`, and #2094
merged as `64ff5380`; the Rust port (`workspace-isolation-run.md`) records it.

| Workflow run | Job | Result |
|---|---|---|
| Swift CI 35500055858 | `swift` aggregate | pass |
| Swift CI 35500055858 | `swift-tests` | pass (4m) |
| Swift CI 35500055858 | Rust workspace on macos-26, ubuntu-latest and windows-latest; host-independent checks | pass (9m20s, 1m45s, 3m56s, 28s) |
| Swift CI 35500055858 | `app-build` | skipped by the plan: no App source changed |
| SDD Guard 35500055733 | `guard` | pass |
| Agent PR 35500055724 | `open-pr` | pass |
