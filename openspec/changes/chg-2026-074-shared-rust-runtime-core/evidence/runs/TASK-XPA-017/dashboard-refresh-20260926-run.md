# TASK-XPA-017 — the macOS dashboard refreshed on protected main `4eb8c677`, every number recounted (macOS, 2026-09-26)

Documentation only. This record and `evidence/macos-remaining.md` are the only files changed: no
code, contract input, `tasks.md`, traceability or lock file, and no Task status. Nothing was run
against a device, an installed Runtime or the account's state; the one build is the Rust CLI's
debug binary, whose only use here is `arkdeck commands --output json`, a local rendering that
connects to no Runtime.

## Pin and attribution

- Pin: protected `main` `4eb8c677886e92b4438ba3d03ff80897644c5019` (#2230), the newest `main` when
  the counts were taken. The previous refresh was pinned on `b958ff44` (#2083); 145 merges lie
  between them, #2085–#2230 (#2087 among them is that refresh itself). The counts were first
  taken at `64d3e3c0` (#2226) and taken again at this pin, after #2230 merged; every output is
  byte for byte the same at both.
- Task: the dashboard names no owning task, and `tasks.md` mentions it only in the change-wide r11
  paragraph (item 8) and in TASK-XPA-018's note on its CLI row. The two previous refreshes were
  filed under TASK-XPA-016 (#2084, #2087) and the one before them under none (#2068). This one is
  filed under TASK-XPA-017, the task whose M5 exit the six numbers measure progress towards.

## The six numbers

Each count below was taken twice at the pin, and both passes printed the same bytes (`cmp`); the
last column is the first 16 hex digits of that output's SHA-256.

| Measure (definition unchanged) | Previous pin (`b958ff44`) | This pin (`4eb8c677`) | Command | Output SHA-256, both passes |
| --- | --- | --- | --- | --- |
| Routed methods | 90 / 105 | 105 / 105 | the dashboard's PYCOUNT | `75637b22b4068e16` |
| Operations executable in Rust | 4 / 30 | 17 / 30 | `count_operations.py` below | `48abb62f7c9733b1` |
| Golden Journeys on Rust | 0 / 5 | 0 / 5 | the two commands under "Golden Journeys" | `e3d0c2b7a8783d06` |
| App facades on ClientKit | 9; 6 remain in Workflows | 16; 0 remain | the dashboard's PYCOUNT | as the first row |
| Registered CLI feature names | 98 / 256 (101 parser names) | 131 / 256 (187 parser names) | the dashboard's PYCOUNT | as the first row |
| Swift targets deleted | 0 / 6 | 0 / 6 | the dashboard's PYCOUNT | as the first row |

The previous-pin column is the same PYCOUNT with its `ref` set to `b958ff44`: it prints the
previous refresh's row exactly (90; 101 and 98; 9 and 6; 0 of 6), so the two columns are one
definition at two refs. It also prints, for that ref, 11 App files importing `ArkDeckWorkflows`,
8 `project.pbxproj` lines naming it and `MATERIALIZED` 11 / 30.

Where each routed-method increase came from, by running the method count at every first-parent
commit in the range: #2085 (+1, `cleanupDebt.continue`), #2108 (+2, `debug.probe`,
`debug.template.run`), #2133 (+1, `trace.probe`), #2148 (+3, `flash.reconcile-alias`,
`debug.status`, `recovery.flash-invocation.list`), #2150 (+2, `flash.bootloader-status`,
`flash.prerequisites`), #2151 (+1, `flash.device-access`), #2154 (+1,
`flash.bind-current-loader`), #2163 (+1, `trace.inspect`), #2166 (+2, `debug.start`,
`debug.evaluate`) and #2170 (+1, `flash.lanePlanPreview`).

## The supplementary numbers, and what each adds

The instruction for this refresh was to keep every definition and to put a more informative
number beside a measure that no longer discriminates. Each supplement below says how it relates to
the number it stands beside.

| Beside | Supplement at the pin | Relation |
| --- | --- | --- |
| Methods (saturated since #2170) | 104 / 105 routes reach an owner the daemon's `Host` composes; `trace.inspect` alone answers the `HostServices` default (`operationUnavailable`, owner `traceInspectionOwner`), as Swift's daemon without a Trace inspector answers (#2163, kept by #2176). The installed facade still serves 3 methods itself and forwards the rest to Swift's daemon | a subset of the 105 routes |
| Operations | 25 / 30 run end to end through a standalone daemon's control socket on either composition: the isolated development root (the 17) or the production composition (#2136) under a temporary `CFFIXED_USER_HOME`. 28 / 30 are in the planner's `MATERIALIZED` list | 17 ⊆ 25 ⊆ 28 |
| CLI | 197 / 209 registry leaves answered: 187 ported — exactly the 187 parser names, 9 of them the non-executable leaves Swift itself answers by name — and 10 answered by name as `blockedByProductDefect` (`blocked_leaves.rs`). `cli-parity-audit.py`: 244 / 256 ledger entries implemented, 2 leaf missing with the daemon routed, 5 owner missing, 5 tombstones; 9 of the 244 resolve to a `blockedByProductDefect` leaf | the 131 are the parser names that happen to be spelled as a ledger `feature` |
| App facades (saturated) | `import ArkDeckWorkflows` in `ArkDeckApp`: 0 files (11 at `b958ff44`); `project.pbxproj` lines naming `ArkDeckWorkflows`: 0 (8). The App's package products are ArkDeckClientKit, ArkDeckCore and ArkDeckTraceAdapter | the App no longer links a retirement target (#2139) |
| Swift targets deleted | all six still declared; their remaining clients are the Swift CLI (`ArkDeckCLI`) and the Swift daemon (`ArkDeckAgentDaemonMain`); the helper pair the release script builds is Swift unless `ARKDECK_HELPER_RUNTIME=rust` (#2218) | — |

## Findings about the definitions

1. **Methods is saturated.** Every published method has been routed since #2170, so the number
   can no longer move. It stays as defined; the supplement above is the one that still
   discriminates, and the installed-product fact (3 methods served by the facade) is the one that
   moves at M5.
2. **Operations names one composition.** The definition counts the isolated development root
   (`ARKDECK_DEVELOPMENT_STATE_ROOT`). Since #2136 the production composition runs under a
   temporary home in committed process tests, and eight `workspace.*` operations have run end to
   end only there: `revert-patch`, the four reads, `create-checkpoint`, `sweep-isolated-copies`
   and `symbolize-crash`. They are not counted. Whether a production-composition run under a
   temporary home satisfies the measure is the maintainer's call, as #2081's rehearsal was on
   2026-09-20; the supplement counts them meanwhile. Two further readings are applied as the
   previous refresh applied them: a host-only operation involves no HDC, so "against a fake HDC"
   binds only device operations (`analyzer.extract-crash-signature@1` was counted on those
   terms), and a recorded rehearsal or host acceptance run counts as a committed test does
   (`debug.hap@1` was counted on #2081's record).
3. **Where the operations evidence is weaker than CI.** `rust/scripts/check-corpus-replay.py`,
   which `observe.device@1` and `capture.diagnostics@1` rest on, runs in no CI workflow; its last
   recorded pass against the isolated daemon is 2026-09-24 (`capture-diagnostics-legs-run.md`).
   The two ArkTrace analyzers' daemon tests run only where a reviewed ArkTrace distribution is
   named (`ARKDECK_REVIEWED_ARKTRACE_*`), so CI skips them; their pass is recorded in
   `TASK-XPA-015/analyzers-trace-inspect-run.md`. Rehearsal records are dated at their own base.
4. **The CLI definition undercounts by spelling.** It intersects parser names with ledger
   `feature` names, and the ledger spells most features as a daemon method, a Catalog operation
   or an App feature: 56 of the 187 ported names are not spelled as any feature (for example
   `workspace status` serves `workspace.inspect-git-status@1`, and `device wait` serves
   `device.observations`). The registry count and the audit, which join on each entry's target
   command, are the ones that track served behaviour.
5. **The dashboard's Status column had drifted from `tasks.md`.** The previous refresh showed
   XPA-015 as `ready (r11)`, XPA-019 as `in-progress` and XPA-025 as `in-progress`; at both pins
   `tasks.md` says `in-progress` (since 2026-09-19), `ready` and `ready`, and XPA-017 `blocked`.
   This refresh shows `tasks.md`'s words. Several of those status lines still carry their 2026-09-11/14 text
   although work under them has merged since; flipping or restating one belongs to the PR that
   implements it, so none is changed here.
6. **`cli-parity-audit.py`'s operation notes are stale.** Its `EXECUTABLE` and
   `FIXED_ROOT_ONLY` sets are its 2026-09-19 view (three executable operations). They only word
   the note on an unserved domain leaf, of which `flash run` is the one left, and that note is
   still true, so its category counts are unaffected. The script belongs to TASK-XPA-018 and is not changed here.
7. **"Revision 11" in the dashboard's header is the change's revision.** It arrived with the r11
   proposal (#1910) and names `proposal.md`'s `revision: 11` (and `verification.md`'s `@r11`);
   every refresh since has kept it. The request for this refresh said "revision 12", which would
   name a revision of CHG-2026-074 that does not exist, so the header keeps "revision 11" and this
   refresh is named by its date and pin.

## Scripts

Save each block under the name its heading gives and run it from the repository root, read-only.
`count_operations.py` reads everything at the ref it is given; `count_cli.py` reads the registry
and `blocked_leaves.rs` from the working tree, so run it in a checkout of the pin.

### `count_operations.py`: every cited piece of evidence checked at a ref

`python3 count_operations.py <ref>` prints the Catalog's size, the measure, the supplement,
`MATERIALIZED`'s size, each operation's verified compositions and any citation that does not
verify. A test citation must name a function that exists at the ref, in a file that starts the
daemon with the composition's variable and names the operation; a record citation must hold its
quoted text. A new piece of evidence is one more row.

```python
import json
import re
import subprocess
import sys

ref = sys.argv[1]
RUNS = "openspec/changes/chg-2026-074-shared-rust-runtime-core/evidence/runs/"
TESTS = "rust/crates/arkdeck-agentd/tests/"
ISOLATED = '.env("ARKDECK_DEVELOPMENT_STATE_ROOT"'
PRODUCTION = '.env("ARKDECK_RUNTIME_COMPOSITION", "production")'
GJ5 = RUNS + "TASK-XPA-015/gj5-fake-rehearsal-2026-09-25.md"
TRACE = RUNS + "TASK-XPA-015/analyzers-trace-inspect-run.md"
REHEARSAL = RUNS + "TASK-XPA-014/"
GESTURES = "agent_run_answers_a_workspace_copy_and_every_gesture_through_the_cli"
PATCH = "the_production_daemon_patches_a_copy_and_reverts_it_with_the_real_patch"
READS = "the_production_daemon_serves_the_workspace_reads_with_the_host_tools"
CHECKPOINT = "the_production_daemon_checkpoints_and_sweeps_with_the_host_tools"


def read(path):
    try:
        return subprocess.check_output(
            ["git", "show", f"{ref}:{path}"], text=True, stderr=subprocess.DEVNULL)
    except subprocess.CalledProcessError:
        return None


# (operation, composition, file, test function or None for a record, text it must hold)
EVIDENCE = [
    ("analyzer.extract-crash-signature@1", "isolated", TESTS + "crash_ledger_analyzer.rs",
     "the_runtime_runs_the_daemon_as_its_own_crash_ledger_analyzer",
     "analyzer.extract-crash-signature@1"),
    ("analyzer.summarize-hilog@1", "isolated", TESTS + "hilog_summary_analyzer.rs",
     "the_runtime_runs_the_daemon_as_its_own_hilog_summary_analyzer",
     "analyzer.summarize-hilog@1"),
    ("analyzer.summarize-trace@1", "isolated", TESTS + "trace_summary_analyzer.rs",
     "a_reviewed_distribution_summarizes_the_fixture_trace_on_the_daemon_as_swift_did",
     "analyzer.summarize-trace@1"),
    ("analyzer.summarize-trace@1", "isolated", TRACE, None,
     "describes `analyzer.summarize-trace@1` as available"),
    ("analyzer.analyze-trace@1", "isolated", TESTS + "trace_summary_analyzer.rs",
     "a_reviewed_distribution_analyzes_the_fixture_trace_on_the_daemon_as_swift_did",
     "analyzer.analyze-trace@1"),
    ("analyzer.analyze-trace@1", "isolated", TRACE, None,
     "the context Job run directly and the analysis Job owned by"),
    ("observe.device@1", "isolated", REHEARSAL + "observe-device-run.md", None,
     "`observe.device@1` end to end on the isolated daemon"),
    ("observe.device@1", "isolated", REHEARSAL + "capture-diagnostics-legs-run.md", None,
     "`observe-device`"),
    ("capture.diagnostics@1", "isolated", REHEARSAL + "capture-diagnostics-run.md", None,
     "`capture.diagnostics@1` on the isolated Rust daemon"),
    ("capture.diagnostics@1", "isolated", GJ5, None, "`agent run capture.diagnostics@1`"),
    ("debug.template@1", "isolated", GJ5, None, "`agent run` of all four templates"),
    ("debug.hap@1", "isolated", REHEARSAL + "gj2-fake-hdc-rehearsal-20260920.md", None,
     "GJ-2's fake-HDC rehearsal on the isolated Rust daemon"),
    ("debug.hap@1", "isolated", GJ5, None, "`agent run debug.hap@1`"),
    ("deploy.native-library.app-owned@1", "isolated",
     REHEARSAL + "gj3-fake-hdc-rehearsal-20260920.md", None,
     "`deploy.native-library.app-owned@1` deployed and rolled back on a real isolated daemon"),
    ("port-forward.create@1", "isolated", REHEARSAL + "port-forward-fake-rehearsal-20260920.md",
     None, "`createForward`, `removeForward`, `createReverse`, `removeReverse`"),
    ("port-forward.remove@1", "isolated", REHEARSAL + "port-forward-fake-rehearsal-20260920.md",
     None, "`createForward`, `removeForward`, `createReverse`, `removeReverse`"),
    ("capture.screen-sequence@1", "isolated",
     REHEARSAL + "screen-sequence-fake-rehearsal-20260920.md", None,
     "`captured`, `scaled`, `gap`"),
    ("input.tap@1", "isolated", TESTS + "agent_run_cli_process.rs", GESTURES, "input.tap@1"),
    ("input.long-press@1", "isolated", TESTS + "agent_run_cli_process.rs", GESTURES,
     "input.long-press@1"),
    ("input.swipe@1", "isolated", TESTS + "agent_run_cli_process.rs", GESTURES,
     "input.swipe@1"),
    ("workspace.prepare-isolated-copy@1", "isolated", TESTS + "workspace_isolation_process.rs",
     "the_isolated_daemon_copies_a_registered_project_and_adopts_the_copy_after_restart",
     "workspace.prepare-isolated-copy"),
    ("workspace.prepare-isolated-copy@1", "isolated", TESTS + "agent_run_cli_process.rs",
     GESTURES, "workspace.prepare-isolated-copy@1"),
    ("workspace.apply-patch@1", "isolated", GJ5, None, "| Patch the copy |"),
    ("workspace.prepare-isolated-copy@1", "production", TESTS + "workspace_patch_process.rs",
     PATCH, "workspace.prepare-isolated-copy"),
    ("workspace.apply-patch@1", "production", TESTS + "workspace_patch_process.rs", PATCH,
     "workspace.apply-patch"),
    ("workspace.revert-patch@1", "production", TESTS + "workspace_patch_process.rs", PATCH,
     "workspace.revert-patch"),
    ("workspace.inspect-source@1", "production", TESTS + "workspace_read_process.rs", READS,
     "workspace.inspect-source"),
    ("workspace.read-source-range@1", "production", TESTS + "workspace_read_process.rs", READS,
     "workspace.read-source-range"),
    ("workspace.inspect-git-status@1", "production", TESTS + "workspace_read_process.rs", READS,
     "workspace.inspect-git-status"),
    ("workspace.inspect-diff@1", "production", TESTS + "workspace_read_process.rs", READS,
     "workspace.inspect-diff"),
    ("workspace.create-checkpoint@1", "production", TESTS + "workspace_checkpoint_process.rs",
     CHECKPOINT, "workspace.create-checkpoint"),
    ("workspace.sweep-isolated-copies@1", "production",
     TESTS + "workspace_checkpoint_process.rs", CHECKPOINT, "workspace.sweep-isolated-copies"),
    ("workspace.symbolize-crash@1", "production", TESTS + "workspace_symbolize_process.rs",
     "the_production_daemon_symbolizes_a_devices_crash_with_its_own_one_shot_mode",
     "workspace.symbolize-crash"),
]

catalog = []
for path in subprocess.check_output(
        ["git", "ls-tree", "--name-only", ref, "Catalog/operations/"], text=True).split():
    document = json.loads(read(path))
    version = document.get("version")
    catalog.append(f"{document['id']}@{version}" if version else document["id"])
plan = read("rust/crates/arkdeck-hoststore/src/job_plan.rs")
materialized = plan.split("const MATERIALIZED: [&str; ", 1)[1].split("];", 1)[0]
materialized = re.findall(r'"([a-z.-]+@[0-9]+)"', materialized) + (
    ["deploy.native-library.app-owned@1"] if "device_steps::NATIVE" in materialized else [])

verified = {}
failures = []
for operation, composition, path, test, needle in EVIDENCE:
    text = read(path)
    ok = text is not None and needle in text
    if ok and test is not None:
        marker = ISOLATED if composition == "isolated" else PRODUCTION
        ok = f"fn {test}(" in text and marker in text
    if not ok:
        failures.append((operation, path, test))
        continue
    assert operation in catalog, operation
    verified.setdefault(operation, set()).add(composition)

isolated = sorted(op for op, kinds in verified.items() if "isolated" in kinds)
print(f"Catalog operations: {len(catalog)}")
print(f"Measure (isolated development root, control socket, end to end): "
      f"{len(isolated)} / {len(catalog)}")
print(f"Supplement (isolated root or production composition in a temporary home): "
      f"{len(verified)} / {len(catalog)}")
print(f"MATERIALIZED in job_plan.rs: {len(materialized)} / {len(catalog)}")
for operation in sorted(catalog):
    kinds = sorted(verified.get(operation, ()))
    print(f"  {operation}: {', '.join(kinds) if kinds else '-'}"
          f"{'' if operation in materialized else ' (not in MATERIALIZED)'}")
print("Citations that did not verify:", failures or "none")
```

Output at the pin, both passes (SHA-256 prefix `48abb62f7c9733b1`):

```text
Catalog operations: 30
Measure (isolated development root, control socket, end to end): 17 / 30
Supplement (isolated root or production composition in a temporary home): 25 / 30
MATERIALIZED in job_plan.rs: 28 / 30
  analyzer.analyze-trace@1: isolated
  analyzer.extract-crash-signature@1: isolated
  analyzer.summarize-hilog@1: isolated
  analyzer.summarize-trace@1: isolated
  capture.diagnostics@1: isolated
  capture.screen-sequence@1: isolated
  debug.hap@1: isolated
  debug.template@1: isolated
  deploy.native-library.app-owned@1: isolated
  flash.dayu200: - (not in MATERIALIZED)
  flash.full-restore@1: - (not in MATERIALIZED)
  input.long-press@1: isolated
  input.swipe@1: isolated
  input.tap@1: isolated
  observe.device@1: isolated
  port-forward.create@1: isolated
  port-forward.remove@1: isolated
  workspace.apply-patch@1: isolated, production
  workspace.build-openharmony@1: -
  workspace.create-checkpoint@1: production
  workspace.inspect-diff@1: production
  workspace.inspect-git-status@1: production
  workspace.inspect-source@1: production
  workspace.prepare-isolated-copy@1: isolated, production
  workspace.read-source-range@1: production
  workspace.revert-patch@1: production
  workspace.run-tests@1: -
  workspace.sign-openharmony-hap@1: -
  workspace.sweep-isolated-copies@1: production
  workspace.symbolize-crash@1: production
Citations that did not verify: none
```

The committed tests the script cites run in the macOS Rust workspace job of every PR's CI. The
last `main` run of that workflow that completed before this record is Swift CI 36193377600 at
`a9d840f0d` (#2221), successful; the runs for the heads merged after it were cancelled by the
next merge, and each of those PRs passed its own required checks before it merged (#2220 added
`agent_run_cli_process.rs`).

### `count_cli.py`: registry leaves answered, ported and blocked

Build the CLI at the pin in your own target directory, then run
`python3 count_cli.py <target>/debug/arkdeck`:

```bash
CARGO_TARGET_DIR=<your target> CARGO_BUILD_JOBS=2 \
  cargo build --manifest-path rust/Cargo.toml -p arkdeck-cli --bin arkdeck
```

```python
import json
import re
import subprocess
import sys

cli = sys.argv[1]
registry = json.load(open("rust/crates/arkdeck-cli/src/command_registry.json"))
leaves = {entry["command"]: entry for entry in registry["commands"]}
answer = json.loads(subprocess.check_output([cli, "commands", "--output", "json"]))
served = {entry["command"] for entry in answer["result"]["commands"]}
source = open("rust/crates/arkdeck-cli/src/blocked_leaves.rs").read()
table = source.split("const BLOCKED: &[(&str, &str)] = &[", 1)[1].split("];", 1)[0]
blocked = set(re.findall(r'\(\s*"([a-z.-]+)",', table))
assert served <= set(leaves), sorted(served - set(leaves))
assert blocked <= served, sorted(blocked - served)
by_name = sorted(name for name in served if leaves[name]["kind"] != "executable")
print(f"Registry leaves: {len(leaves)}")
print(f"Served (answerable): {len(served)}")
print(f"  answered by name as blockedByProductDefect: {len(blocked)} {sorted(blocked)}")
print(f"  ported: {len(served) - len(blocked)}"
      f" (of which {len(by_name)} non-executable leaves Swift itself refuses by name: {by_name})")
unserved = sorted(set(leaves) - served)
print(f"Not served: {len(unserved)}")
for name in unserved:
    spec = leaves[name]
    print(f"  {name}: kind={spec['kind']} lifecycle={spec['lifecycleStatus']}"
          f" operation={spec['catalogOperation']} runtime={spec['connectsToRuntime']}")
```

Output at the pin, both passes (SHA-256 prefix `5905d560500df258`):

```text
Registry leaves: 209
Served (answerable): 197
  answered by name as blockedByProductDefect: 10 ['maintainer.update-feed.assemble', 'maintainer.update-feed.prepare', 'runtime.update.cancel', 'runtime.update.check', 'runtime.update.cleanup', 'runtime.update.download', 'runtime.update.handoff', 'runtime.update.status', 'update-feed.assemble', 'update-feed.prepare']
  ported: 187 (of which 9 non-executable leaves Swift itself refuses by name: ['agent.chat', 'capability.draft', 'capability.install', 'capability.revoke', 'flash.continue', 'flash.execute', 'flash.plan', 'flash.postflight', 'flash.preview'])
Not served: 12
  flash.install-binding: kind=executable lifecycle=legacy operation=None runtime=False
  flash.run: kind=executable lifecycle=current operation=flash.full-restore@1 runtime=True
  runtime.signing.install: kind=executable lifecycle=current operation=None runtime=False
  runtime.signing.install-sdk-release: kind=executable lifecycle=current operation=None runtime=False
  runtime.signing.migrate-deveco: kind=executable lifecycle=current operation=None runtime=False
  runtime.signing.remove: kind=executable lifecycle=current operation=None runtime=False
  runtime.support-bundle.export: kind=executable lifecycle=current operation=None runtime=False
  runtime.support-bundle.preview: kind=executable lifecycle=current operation=None runtime=False
  signing.install: kind=executable lifecycle=deprecated operation=None runtime=False
  signing.install-sdk-release: kind=executable lifecycle=deprecated operation=None runtime=False
  signing.migrate-deveco: kind=executable lifecycle=deprecated operation=None runtime=False
  signing.remove: kind=executable lifecycle=deprecated operation=None runtime=False
```

The served set minus the blocked set equals the positional-match parser names of the dashboard's
PYCOUNT exactly (checked as sets at the pin), which is why "ported" and "parser names" are one
number. The audit is the existing
`python3 openspec/changes/chg-2026-074-shared-rust-runtime-core/evidence/runs/TASK-XPA-018/cli-parity-audit.py <target>/debug/arkdeck`,
whose summary at the pin is 244 / 2 / 5 / 5.

### Golden Journeys

```bash
git diff b958ff44865248be482d9cbc78600aabb45a12f3 <pin> -- \
  openspec/changes/chg-2026-074-shared-rust-runtime-core docs/design/references \
  | grep '^+' | grep 'REAL_DEVICE_PASS'
git log --diff-filter=A --name-only --format=%h b958ff44865248be482d9cbc78600aabb45a12f3..<pin> \
  -- docs/design/references
```

The first prints 22 added lines, every one of them a statement that some evidence is not
`REAL_DEVICE_PASS`; the second prints nothing: no acceptance record was added since `b958ff44`.
The helper pair the release script builds is still Swift's unless `ARKDECK_HELPER_RUNTIME=rust`
is set (`Packages/ArkDeckKit/Distribution/macOS/build-helpers.sh`, #2218), and the production
composition is not activated (#2136), so no installed pure-Rust daemon exists for a pass to have
run on. 0 / 5.

## Local targeted checks

- The dashboard's PYCOUNT, `count_operations.py`, `count_cli.py` and the two Golden Journey
  commands at the pin, each twice, run as extracted from these two files: exit 0 and the same
  output both times (`cmp`). `count_operations.py` also printed the same as the scratch copy it
  was written from.
- The same PYCOUNT at `b958ff44`: the previous refresh's row (90; 101 and 98; 9 and 6; 0 of 6).
- `cargo build -p arkdeck-cli --bin arkdeck` (`CARGO_BUILD_JOBS=2`, the A lane's target
  `/private/tmp/arkdeck-1330-rust-target`) at `64d3e3c0` and again at the pin: exit 0 both times,
  logs `/private/tmp/arkdeck-s34-build2.log` and `/private/tmp/arkdeck-s34-build3.log`.
- `cli-parity-audit.py` at `64d3e3c0` and at the pin: exit 0, 244 / 2 / 5 / 5, the same table.
- `ARKDECK_PYTHON=/private/tmp/arkdeck-validation-venv/bin/python sh scripts/check-sdd.sh`: exit 0,
  0 errors, 0 warnings, 121 acceptance IDs (log `/private/tmp/arkdeck-s34-check-sdd.log`).

Not run: any Rust, Swift or App test (nothing but documentation changed), `generate-contract.py`
(no contract input changed), `check-corpus-replay.py` and the ArkTrace host acceptance (their
records are cited as they stand).

## CI

Pending.
