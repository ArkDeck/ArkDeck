# TASK-XPA-022 / WM6: phase A runbook refresh (2026-10-04)

- **Kind:** documentation only, host-only. No `hdc` was run, the DAYU200 was not touched, and no
  certificate store or system setting was changed.
- **Base:** protected `main` `982d4e6d` (#2518).
- **Product:** `docs/design/cross-platform/windows-phase-a-runbook.md`, refreshed from the
  2026-09-30 version (`phase-a-runbook-20260930-run.md`).

## What changed

| § | Change |
| --- | --- |
| header | Version 2026-10-04, against `982d4e6d` |
| 2 | Marked **done**: the samples (#2456, #2457), CHG-2026-078 r2 (#2459), WHR-002 (#2472) and WHR-003 (#2469). `c2` is the only registered tuple |
| 4 | Rewritten (see below) |
| 7 | Order with the state on `main` and the blocker of each step |

§4 now covers:

- **4.0, for every row:**
  - which daemon is used, with a table of what the account daemon and a development root
    compose on `main`;
  - install and configuration in the session that starts the daemon;
  - registering the `c2` `hdc.exe` into the Bootstrap registry;
  - the fixed facts to read;
  - the board and host rules, with the read-only `hdc` host-fact check;
  - rehearsal on a development root, which is never row evidence;
  - how a row becomes `REAL_DEVICE_PASS`: only from saved Runtime outputs, criteria applied
    mechanically, maintainer-merged.
- **4.1 to 4.5, one section per WIN-GJ row:**
  - gates;
  - the maintainer's physical actions and inputs;
  - the agent's exact CLI sequence, with Windows paths and spellings checked against the CLI's
    command registry;
  - the authority each step uses (Runtime-issued capability, no `--capability`);
  - destructive steps;
  - software readiness, with PR references;
  - blocking gaps.
- **4.4 (GJ-4)** now names the Windows ArkForge configuration surface that replaced the "TBD":
  `ARKDECK_ARKFORGE_BUNDLE_PATH` and `ARKDECK_ARKFORGE_CAMPAIGN` in the daemon-starting session,
  then `runtime service restart`.
- **4.5 (GJ-5)** replaces the `--build-profile` signing form, which is `unsupportedOnPlatform` on
  Windows, with the explicit console-prompt form.
- **4.6** is the gap table (G1 to G9), and **4.7** the per-row readiness table.

## Per-row readiness (main `982d4e6d`)

| Row | Software path on Windows | Real-device blockers | Maintainer gate | Destructive |
| --- | --- | --- | --- | --- |
| WIN-GJ1-001 | candidates and adopt live on a development root; observe and capture on the fake (#2518) | G1 (G2 risk) | board window; unplug and replug | no |
| WIN-GJ2-001 | full oracle replay end to end (#2505) | G1 | device window; HAP input | no (device mutation) |
| WIN-GJ3-001 | full oracle replay end to end (#2505); helper packaged | G1, G3 | device window; `.so` and rollback fixture | no (device mutation) |
| WIN-GJ4-001 | lane, plan, run, reconcile on fakes (#2504); broker (#2519, open) | G1, G4, G5, G6 | HardwareCampaign go; ArkForge bundle; image archive | **yes** |
| WIN-GJ5-001 | reads, isolate, sweep measured (#2500); sign replayed (#2495); patch (#2506) and registered signing (#2508) open | G1, G7, G8 | DevEco install; console secret entry; inputs | no (device mutation) |

**G1 blocks every row.** On `main`:

- The account daemon (the trusted installed daemon that the rows require) composes no HDC. The
  HDC tuple gate runs only for a development root (`windows_lifecycle.rs`).
- A development root composes the managed `c2` HDC but holds no device mutation authority and no
  signing owner. Its evidence is never `REAL_DEVICE_PASS`.
- `runtime tool register --kind hdc` admits `c2` into the account registry, but nothing selects
  it into a running daemon: no Windows tool-selection owner exists, and that port is in flight.

## Gaps found while refreshing (not fixed here)

These are stale texts that contradict the code on `main`:

- `rust/README.md` still says "No Windows HDC tuple is registered yet", in the Windows Target
  owners section and the provider tuples paragraph. `windows_lifecycle.rs` doc comments say the
  same.
- README text from before #2500 still says the trusted system tools are not composed. The comment
  in `feature_coverage.rs` above the workspace leaves says no profile resolves.
- The README Windows Import paragraph says a `flash-bundle` Import is refused at publication. Its
  upload is measured (`feature_coverage.rs`).
- `openspec/platforms/windows/conformance-cases.yaml` `support_cells` still says
  `package_format: pending-maintainer-decision`. Profile decision 8 settles it (MSIX plus xcopy).
  The file belongs to the §6 flip PR, so it is not edited here.
- `openspec/platforms/windows/profile.md` decision 3 lists `runtime service uninstall` as
  unsupported. It is measured on Windows (#2411).
- The record path for Windows GJ results: `verification.md` (Golden Journeys row) names
  `docs/design/references/v1.6-goal/gj-headless-rerun-<date>-<platform>.json`, while the old
  §4 named a run note. The refresh uses both: the machine record at the verification matrix's
  path, and a run note per owning task.

## Delegated minor decisions, pending the next rulings batch

1. **Who runs the rows.** An agent drives every step through the CLI (the acceptance guide). The
   maintainer does the physical actions and every gated step: certificates, the console secret
   entry, the HardwareCampaign go and AF-W1.
2. **Rehearsal.** A development root with the registered `hdc.exe` may rehearse read-only steps
   before G1. Its results go only under "rehearsal" in the run note.
3. **Signing on Windows.** The credential is installed with explicit `--java/--jar/--keystore/
   --certificate/--profile` paths and the console prompt. Gap G8 (the plaintext passwords) is the
   maintainer's material question.

## Checks

- `PYTHONUTF8=1 sh scripts/check-sdd.sh`: 0 errors, 0 warnings.
- `git diff --check`: clean.

## Follow-up 2026-10-05: G8 closed

#2532 ports `runtime signing install --build-profile` and `migrate-deveco` to Windows. §4.5 now
installs the GJ-5 credential from the project's `build-profile.json5`, as the headless runbook §6
does, with the typed prompt kept only as the fallback. G8 is marked closed in §4.6, §4.7 and §7.
This supersedes delegated decision 3 above: the credential is installed from the build profile,
and no maintainer handles a plaintext password.

## Follow-up 2026-10-05: G1 closed

Brought up to date with protected `main` `162c94f3`:

- **G1 is closed** (#2524, #2526, #2536; live run #2530,
  `runs/TASK-XPA-012/windows-account-hdc-live-c2-20261005-run.md`). The account daemon composes
  the registered `c2` HDC from `ARKDECK_HDC_PATH` through its Bootstrap selection.
- **§4.0.1:** the daemon table, plus the caveat that the awaiting-approval HDC restart and
  tool-selection paths need #2501's health proof (in CI) and, for a selection, a second tuple.
  No WIN-GJ step uses those paths.
- **§4.0.2:** `ARKDECK_HDC_PATH` is set in the daemon session, and registering the tool by hand
  is optional.
- **§4.1–§4.5, §4.6, §4.7 and §7:** updated.
- **G4 and G6 marked closed as well**, because main carries them: #2535 serves `flash
  install-binding` on Windows, and #2531/#2535 measure device-access, lane-preview and bind-loader
  through the CLI over stand-ins.
- **Still open:** G2 (risk), G5 and G7. No row has run on the board.

## Follow-up 2026-10-05: G7 closed

Brought up to date with protected `main` `a72df529` (#2549):

- **G7 closed.** `workspace build` and `workspace test` run end to end on Windows with the real
  DevEco, through the pinned DevEco JDK, `NoDefaultCurrentDirectoryInExePath`, in-tree junction
  recreation and long paths. Both are measured `implemented`.
- **§4.5.** The DevEco record now pins `jbr\bin\java.exe`, so a pre-#2549 record must be registered
  again. A test preset is registered beside the build preset.
  - `ohpm install --all` runs in the project as maintainer preparation before the window.
  - The agent steps are now isolate, patch, build and test on the same copy.
  - `workspace symbolize` stays `partial`, since it needs a device-captured crash. GJ-5's own
    repro provides one, as an optional extra step.
- **§4.6, §4.7 and §7.** G7 is closed, WIN-GJ5-001 has no software blocker left, and GJ-5 opens
  after GJ-2 on the same digest.
- **Platform-wide note, H3's.** Building a project runs its own `hvigorfile.ts` and the Hvigor
  plugins it declares, with the build child's rights, on macOS as on Windows. The
  working-directory hardening does not make building an untrusted project safe. It is recorded
  in §4.5 and in the G7 row; the further boundary is an open design question
  (`runs/TASK-XPA-011/windows-workspace-hvigor-cwd-run.md`).
- **Remaining.** G2 (risk) and G5. No row has run on the board.
