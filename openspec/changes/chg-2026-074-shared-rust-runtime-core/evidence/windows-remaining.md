# Remaining Windows work

Updated 2026-09-30 against protected main `659f6474` (#2372), with this PR's coverage change
(TASK-XPA-018, `runs/TASK-XPA-018/windows-coverage-refresh-run.md`). Phase S is the software;
phase A is the maintainer's real-host and DAYU200 acceptance (proposal r12, r13: Windows 11 x64
only). The table is refreshed once per milestone, in its own docs commit, not in every slice.

| Operations executable on Windows (/30) | Methods the Windows daemon answers (/105) | GJ software-ready on Windows (/5) | GJ real device on Windows (/5, phase A) | CLI coverage `windows: implemented` (/256) | Client pages (/6 + 1 skeleton) | SPK-3 / SPK-4 / SPK-5 |
| --- | --- | --- | --- | --- | --- | --- |
| 0 (`operation.list` names all 30, none `available`) | 28 answered by a composed owner (7 results, 21 owner refusals); 2 non-conforming answers; 75 no owner | 0 | 0 | 18 (116 `partial`, 6 `notImplemented`, 116 unset) | skeleton done (#2365); 1 of 6 pages in progress (Device, #2375) | host rows run, maintainer rows open / WinUI 3 go (provisional) / go |

Previous refresh (main `66b7474b`, before r12): 0 · 3 by design, not measured · 0 · 0 · 0 · 0 + 0 ·
not run / not run / not run.

How each number is read and measured:

- **Operations executable.** A Catalog operation the Rust CLI runs end to end on Windows through
  the named pipe against the Rust daemon, with a fake HDC or stand-in lane on the device side.
  Plan-only or fixture replay does not count.
  - Measured by `rust/scripts/windows-method-census.py`: the development daemon's `operation.list`
    names all 30 operations and marks none `available`.
  - No Windows HDC tuple is registered (its integration change waits for the maintainer's samples).
  - No Job owner is composed on Windows yet (#2361 open).
  - No provider lane is composed.
- **Methods answered.** Measured with a client over the named pipe by
  `rust/scripts/windows-method-census.py <arkdeck-agentd.exe>`.
  - It starts a development daemon over a fresh root and sends each of the 105 published methods
    the requests the committed control-frame corpus records for it.
  - It counts a method as answered when a composed owner replies: a result, or that owner's own
    refusal. The owner's refusal covers its validation, a reference absent from the fresh root, or
    a dependency owner it names that is not composed.
  - Owners composed: `targets, artifacts, workspaceProjects, traceCache`.
  - The two non-conforming answers are defects, listed in the run record:
    - `target.display-name.clear` of an absent Target;
    - `artifact.import.list` without the Import owner.
- **GJ software-ready.** Every runbook step of that Golden Journey passes on Windows with the fake
  HDC (exit condition 2 of `docs/design/cross-platform/windows-phase-agent-prompt.md`). None does
  yet:
  - GJ-1 needs the Job owner (#2361) and a registered HDC tuple;
  - GJ-2..5 need their owners and lanes.
- **GJ real device.** `REAL_DEVICE_PASS` on the current Catalog digest, phase A only.
- **CLI coverage.** `implementationStatusByPlatform.windows == "implemented"` in
  `openspec/contracts/cli-feature-coverage.json`, generated from
  `rust/crates/arkdeck-cli/src/feature_coverage.rs`.
  - The 18 are the leaves that need no Runtime (`help`, `commands`, `completion`, the capability
    stubs) plus `WINDOWS_MEASURED_LEAVES`:
    - `doctor`, `operation list`;
    - `target list|show|display-name set|clear`;
    - `workspace project register|list|show`, `workspace preset list|show`;
    - `trace cache status`.
  - Each measured leaf is run through the real CLI against a development-signed daemon
    (`crates/arkdeck-cli/tests/windows_signed_runtime.rs`).
  - Ruling 9: a refusal because an owner is not composed stays `partial`.
- **Client pages.** The XPA-007 skeleton and the six XPA-020 surfaces (Debug, Flash, Viewer,
  Diagnostics, Settings, Device), each wired to the real Windows daemon.
  - The skeleton is on main (#2365).
  - #2375 built the Device Targets and display names (and the History Job detail and Trace
    inspection, which are not among the six). Device is in progress; the other five wait for
    their Golden Journey owners.
- **Spikes.**
  - **SPK-3:** host-side rows run (`runs/TASK-XPA-002/spk-3-20260930-run.md`); the rows that need
    the maintainer (signing identity, second account, elevation, remote host, MSIX registration)
    are open.
  - **SPK-4:** WinUI 3 go, provisional until the maintainer rows (`runs/TASK-XPA-007/spk-4-20260930-run.md`).
  - **SPK-5:** go (`runs/TASK-XPA-005/spk-5-20260930-run.md`).

Open PRs that move these numbers when they land:

| PR | Effect |
| --- | --- |
| #2361 | the Job store owner on the daemon (`job.*` reads; the Artifact leaves' Job proof) |
| #2373 | the Session owner and snapshot pages; `job.list`/`job.timeline` paging |
| #2376 | the Job planner and admitter (`job.plan`, `job.submit`) |
| #2377 | Session removal, cleanup and export; the Session owner on the daemon |
| the Windows HDC integration change | operations and GJ-1 |
