# Isolated Rust Trace cache status owner

2026-09-11. Built on approved main
`b3fe9a7bfbfb9a4ef211f4c642bd6f96b3553da5`; conflict repair rebased onto
`bbd28b1fded1a43fb8693c89df30caee9df279e1`, then adopted the merged
baseline at `22cf5d29919abefd3015633e511c5b1f45cbc8d9`.

The isolated Rust daemon now answers the existing `trace.cache.status` method
from a fixed private `trace-cache` directory. The Rust CLI accepts the current
`trace cache status` command and checks the closed response, bounded counts,
canonical byte count and active/inactive relationship before printing it.
The existing inventory implementation and current metadata format are reused;
no parser compatibility expansion or new protocol shape is introduced.

The owner holds a descriptor to its configured root and validates the path
before and after reading. Existing key locks and entry leases determine active
entries. Unaccounted metadata remains active. Callers cannot select a path,
and Session configuration excludes the cache root to keep both stores disjoint.
Purge, database preparation and installed Swift owner detachment remain pending.

Validation:

- The real Rust daemon passed `check-trace-cache-owner.py` with both Rust and
  current Swift CLI consumers: 13 control exchanges per run plus CLI calls.
  It checks empty/nonempty inventory, active key/lease contention, restart,
  invalid parameters, Session root overlap, unsafe links and root replacement.
  Fixture bytes remain unchanged. The database fixture is not a parsed trace.
- CLI tests passed, including rejected path options and inconsistent response
  counters, sizes and schema markers.
- Clippy passed for the host-store, daemon, CLI and control crates.

The candidate contract runner includes this process harness. After PR #1846
merged, the final unified plan passed on the complete worktree diff: common
checks, Rust workspace formatting/Clippy/tests, published and candidate contract
checks including this owner harness, cargo deny and cargo vet (26 fully audited).
The plan selected no Swift/App lane for this Rust-only change. An initial format
check found one indentation error; it was corrected before the successful run.

```sh
python3 scripts/ci/plan.py --repo-root . --base-revision origin/main \
  --head-revision HEAD --merge-base --include-worktree --run-local
```

The local Python environment includes CI-pinned PyYAML/jsonschema. These are
host checks, not installed Runtime or device acceptance.


PR #1848 conflict repair retained both Session export/cleanup and Trace cache
CLI help entries and process harness registrations. The rebased CLI tests and
13-exchange actual Trace owner process check passed. The initial rebased local
plan and all three remote Rust lanes identified the same stale baseline for six
merged Session inputs. After the separate PR #1849 re-pin merged, the branch
was rebased onto `22cf5d29` and the complete local plan passed: common checks,
formatting, Clippy, workspace tests, published and candidate replay, all actual
owner process checks, cargo deny and cargo vet (26 fully audited). No checks were
skipped or relaxed to resolve either the conflict or the CI failure.
