# Windows ancestor directory locks — 2026-10-13

## Result and scope

Native Windows 11 x64 observation reproduced an ineffective namespace lock in
protected main `db53c65dee316f58bf95746595f4ba9fb68d8a7d`. Opening a directory
with only `FILE_READ_ATTRIBUTES` and omitting `FILE_SHARE_DELETE` still permits
renaming that directory. The metadata-only open does not establish the intended
share-access restriction. A later retained image handle can block the rename,
which masked the gap in the existing verified-source integration test.

`lock_namespace` now requests `FILE_TRAVERSE | FILE_READ_ATTRIBUTES`, retaining
the same share flags, root-to-leaf order, reparse rejection and handle lifetime.
The handles prevent ancestor renames before the image or state-root handle is
opened. A pre-existing delete-access handle makes acquisition fail closed.
This implements the existing Windows profile sections 2–3; it changes no
operation, authority policy, capability or acceptance requirement.

The shared helper serves verified tools/sources, daemon launch and fingerprint,
peer process identity, and state-root ownership. No installed Runtime or device
was run from the candidate source. Publication still requires maintainer review.

## Native reproduction

An isolated Win32 probe opened each newly created test directory with
`FILE_FLAG_BACKUP_SEMANTICS | FILE_FLAG_OPEN_REPARSE_POINT`, sharing read/write
but not delete. It queried directory/reparse attributes and attempted rename.

| Desired access | Rename while handle retained | Rename after close |
| --- | --- | --- |
| `FILE_READ_ATTRIBUTES` | Succeeded: reproduces defect | Succeeded |
| `0` | Succeeded: not a repair | Succeeded |
| `FILE_TRAVERSE` | Refused, Win32 32 | Succeeded |

The repository regression deliberately holds no image file handle. On the old
implementation it failed because the first ancestor rename succeeded. After
the repair, leaf, intermediate and owned root directories all refuse rename
with `ERROR_SHARING_VIOLATION`, then permit it after releasing the handles.
A second regression verifies rejection when a directory is already open for
delete access. Both native regression tests passed.

The probe also made read-only opens of the protected Windows package directory;
all three access choices returned Win32 5. This repair therefore does **not**
establish mixed MSIX/xcopy support or justify skipping a namespace lock.
Actual package registration and mixed-installation observations are tracked
separately in the [MSIX run](../TASK-XPA-022/msix-development-signing-2026-10-13-run.md).

The private 24-hour owner soak was stopped to repair this observed defect;
its four-cycle partial record is described in the
[quiet-host run](../TASK-XPA-025/windows-quiet-capture-2026-10-13-run.md).
It is not a completed soak or hardware evidence.

## Local targeted checks

Logs remain outside Git under
`D:/temp/arkdeck-windows-acceptance-20261013`.

- Native access experiment: exit 0;
  `namespace-access-probe/observations.json`.
- Regression before repair: exit 101, one expected failing test;
  `namespace-regression-before.log`.
- Regression after repair: exit 0, two tests passed;
  `namespace-regression-after.log`.
- Workspace formatting hit Windows argv limit 206; equivalent batched
  `rustfmt --check` covered all 356 workspace target roots and passed.
  Logs: `namespace-checks/fmt-all.log`, `fmt-batched.log`.
- `python rust/scripts/run-cargo.py clippy -p <platform-and-consumers>
  --all-targets -- -D warnings`: exit 0 for all 11 crates;
  `namespace-checks/clippy.log` and `checks.json`.
- `python rust/scripts/run-cargo.py test -p arkdeck-platform --no-fail-fast`:
  exit 0, 263 passed, including both new regressions;
  `namespace-checks/test-arkdeck-platform.log`.
- The initial combined `test -p <platform-and-consumers>` stopped at two
  account-tool-selection fixtures because the real installed Runtime held
  their account guard. All three `account_tool_selection::` tests passed
  after stopping that Runtime through its published service command.
  Logs: `namespace-checks/test.log` and `agentd-account-fixture.log`.
  Remaining targets were continued without repeating completed targets.
- `python rust/scripts/test_catalog_test_views.py`: exit 0, 31 tests;
  `namespace-checks/catalog-routing.log`. The official `source_inventory`
  refreshed exactly the changed `identity.rs` source pin in the generated
  routing manifest; fixture hashes and test routing are unchanged.

Per-crate test exits and durations are retained in
`namespace-checks/followup-checks.json`. Platform, Bootstrap, CLI, client,
the three providers, Rockchip binding and soak each exited 0. Agentd retained
six failures across four integration targets; HostStore retained 28 across
13 targets. Every remaining failing function is already routed `historical`
in the unchanged manifest (`namespace-checks/classification.json`). Running
these direct tests against the current Catalog is not a historical-view pass;
CI runs the existing current/historical routing. No assertion was relaxed.

The full manifest loader passed with 927 source hashes, 6,499 fixtures and
333 targets (`namespace-checks/manifest-validation-final.log`, exit 0).
An earlier simultaneous attempt was refused by the same-session cache lock,
before running the validator; it was repeated only after the tests finished.

The original published Runtime's first restoration attempts failed closed
because an external, unregistered HDC executable had acquired its endpoint.
After the user explicitly authorized stopping that identified process, its
image hash, creation time and listener PID were checked again before stopping
it. Published doctor, service status and Job list then all exited 0; the
original signed Runtime was ready and all 57 complete Job items matched the
pre-maintenance inventory (`raw-namespace-restore-diagnostic`). No candidate
Runtime performed this account restoration.

- `sh scripts/check-sdd.sh`: exit 0, zero errors/warnings, 121 acceptance IDs;
  `namespace-checks/sdd-final.log`.
- `git diff --check`: exit 0. No contract input changed, so contract generation
  was not rerun.

The direct consumers are `arkdeck-agentd`, `arkdeck-bootstrap`, `arkdeck-cli`,
`arkdeck-client`, `arkdeck-hoststore`, `arkdeck-provider-arkforge`,
`arkdeck-provider-hdc`, `arkdeck-provider-workspace`,
`arkdeck-rockchip-binding` and `arkdeck-soak`. Checks use the official runner,
the session's fixed cache and its two-job build limit. No full local CI gate,
Swift test or App build is needed for this Windows-only platform repair.

## CI

The repair PR reports its own current-head CI. Green CI cannot replace
maintainer review, released MSIX acceptance or a completed 24-hour soak.
