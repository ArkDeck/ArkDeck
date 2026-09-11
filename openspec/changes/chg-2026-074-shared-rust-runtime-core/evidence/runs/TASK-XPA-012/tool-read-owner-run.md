# Bootstrap read owners and typed inspection — macOS, 2026-09-11

Base: approved main `4a112438` (Trace cache owner and policy-tool CI cache merged).

The isolated Rust daemon and CLI now inspect existing HDC tools, signed daemon
Bundles and DevEco toolchains through typed resource references. The daemon opens
its fixed Bootstrap directory and uses the actual existing shared registry locks.
The CLI keeps its client-only dependency boundary and checks the returned
reference, digest, generation, content schema and execution assessment.

All three readers strictly decode frozen index formats and revalidate current
content before producing the existing Swift projections. HDC inspection uses
bounded descriptor-relative reads, Mach-O dependency validation, quarantine and
Security.framework metadata. Bundle inspection applies the production signing and
entitlement policy and checks version and tree digests. DevEco inspection checks
its actual retained source root, signed resource envelope, child tools and current
metadata. Named/held identities, indexes and locks are rechecked before returning.
No read creates an index or lock, changes selection, registers tools or executes
host tools. `executionAssessment` remains `notPerformed`.

Two additive Swift RPC producers provide native result and refusal recordings.
The candidate registry contains 99 methods. The existing 97 method definitions
are unchanged except for their generated identity metadata. Health was freshly
recorded through the actual handler and registered-provider projection for both
existing provider-array shapes, with the current identity and method count. The
other 96 old corpus files and the published Rust pin remain unchanged. The detailed producer evidence and bounded
scope extensions are recorded in
[bootstrap-rpc-oracle-macos-20260911.md](bootstrap-rpc-oracle-macos-20260911.md).

## Validation

- Native platform/content/registry tests cover locks, index/content/root
  replacement, unsafe links and permissions, quarantine, changed native identity,
  closed dependency layouts, malformed indexes and forged durable trust claims.
- A real Swift registration of `/usr/bin/true` and Rust read-back have equal list
  projections. Actual existing HDC, three signed Bundle and DevEco projections
  also matched their Swift CLI reads while indexes and members stayed unchanged.
- Swift recorded the actual selected HDC's selection generation, dependency and
  published identity, and an actual unsigned temporary tool's nullable signature
  fields. No successful signature response was injected.
- The integrated Rust workspace tests and macOS warnings-denied Clippy passed.
  Cross-compilation of all targets for Linux passed after main integration.
- A 99-method isolated candidate build served the retained native Swift Tool,
  Bundle and DevEco fixtures through the real Rust CLI and daemon. Each result
  exactly matched a raw Swift recording of the same registry, including its
  original registration time. Bootstrap bytes, inode identities, modes and member
  sets stayed unchanged. Log: `/private/tmp/xpa012-bootstrap-process-compare.log`.
- The current generated Swift contracts and diff whitespace checks passed.

The complete Swift lane caught the missing CLI effect classification of the two
new RPC methods. Both are now explicitly read-only in `CLIControlMethodRegistry`;
the classification, coverage mapping and exported coverage have exact bounded
scope extensions. The actual exporter/checker reports 235 clean products after
adding the two RPC coverage entries. Missing Bootstrap
locks are also distinguished from real contention without creating locks or
changing other platform callers' missing-lock policy.

The initial complete candidate replay rejected the stale health identity. Fresh
actual handler recordings now pass all eight isolated candidate corpus tests,
including every method and recorded shape; the validator is unchanged.
Log: `/private/tmp/xpa012-bootstrap-health-candidate-replay.log`.

The final repository unified gate passed against `origin/main` at `4a112438`,
including common checks, full Swift tests, App build-for-testing, Rust workspace
and Clippy, isolated published/candidate conformance and real owner process checks,
plus cargo deny and cargo vet (26 fully audited). Command:

```sh
python3 scripts/ci/plan.py --repo-root . --base-revision origin/main \
  --head-revision HEAD --merge-base --include-worktree --run-local
```

Log: `/private/tmp/xpa012-bootstrap-full-gate-r4.log`. Dual-view recordings:
`rust/target/readonly-check/1203319bc8644289bde03fe72241744b`.
These checks are host verification, not installed Runtime or hardware acceptance.

## Remaining Task scope

This delivers inspect operations against existing registrations. Bootstrap write
operations, installed Swift owner detachment, remaining host stores and GJ-1
acceptance are still pending under TASK-XPA-012. The published contract pin must
be refreshed by TASK-XPA-002 after maintainer review and merge. Runtime capability,
Provider coverage, device state and installed Bootstrap data remain untouched.
