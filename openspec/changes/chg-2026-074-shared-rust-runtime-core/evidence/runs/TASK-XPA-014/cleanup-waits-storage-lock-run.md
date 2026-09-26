# A Session cleanup waits for the storage lock, and takes the Job activity guard only under it (TASK-XPA-014, macOS, 2026-09-26)

TASK-XPA-014 / CHG-2026-074. A Session cleanup, preview or apply, took the Job owner's activity
guard for its census of active Sessions (`JobStore::with_active_sessions`). Under that guard it
only tried the Session storage lock, `.session-storage.lock` (S). While anything else held S, the
cleanup answered `resourceConflict` "Session storage is being updated". Swift's cleanup waits for
S. Taking S under the activity guard, as before, but waiting, would hold every Job write back for
as long as S is held. #2230's record left this for its own slice: take S before the activity
guard.

The coordinator approved the order on 2026-09-26: S, waited for; then the activity guard, under
S; then the retention catalog lock (C). It set the conditions:
- **No path that holds the activity guard waits for S**, proved one by one: in particular the
  Session publication at a Job's end, and a device mutation's admission.
- **Every activity path and every S path**, listed by file and line.
- **Deterministic hook tests**, at least one with a Job reaching its publication and one with an
  admission waiting for S, each with a timeout.
- **The build and tests** stay out of the hub's 08:40–09:00 quiet window.

Base: protected `main` `82706393d` (#2243), which holds #2242; every file and line below is on
this base with the change applied. Developed and first checked on `eec3df485` (#2241).
Disposable host data only; nothing here is device evidence.

## Swift

`RuntimeSessionResourceHandler.swift:32–48`: the handler first takes its census,
`await activeSessionIDs()`. That is a snapshot the engine actor answers
(`RuntimeJobEngine.activeSessionIDsForRetention`, `RuntimeJobEngine.swift:5626`), and nothing of it
stays held. The handler then calls `previewSessionCleanup` or `applySessionCleanup`, which wait for
S (`withLockedDocument`, `RuntimeSessionStorageStore.swift:476`).
- **What is the same:** a cleanup waits for S, and is never refused because S is held.
- **The declared difference:** Rust takes its census under S and under the activity guard, and
  keeps the guard through the removal. No Job becomes active between the census and the
  removal. Swift's census is a snapshot taken before S.

## Change

- **`ActiveSessions`** (`session_cleanup_owner.rs:12`) is public. It answers which Sessions are
  active, under whatever guard keeps them so:
  - `JobStore` answers under its activity guard;
  - a fixed `BTreeSet` answers as it is.
- **`SessionStore::preview_cleanup` (`:80`) and `apply_cleanup` (`:115`)** take an
  `&dyn ActiveSessions`. Under `with_waited_session_configuration` (`:214`), which waits for S,
  they run the cleanup inside `active.with_active`.
  - The daemon passes its `JobStore` (`arkdeck-agentd` `host.rs:2336`, `:2347`) and no longer
    wraps the call in `with_active_sessions`.
  - The apply still checks its preview tuple before any lock. The census's identities are
    checked under it.
- **The storage lock is never tried any more.** Export and cleanup both wait: the try, and its
  refusal, are gone.
- **`rust/scripts/check-session-cleanup.py`.** A preview made while the script holds S used to
  be refused. It now gives no answer for as long as S is held, and is answered once S is
  released.

## Lock order

On `82706393d` with the change: S → the activity guard → C, and S → C. Nothing takes them in any
other order.

**Every activity guard** (`JobStore.activity`, a private mutex, `job_owner.rs:49`):

| Where | What runs under it | Waits for S |
| --- | --- | --- |
| `job_owner.rs:266` `publish_record_file` | the Job's record file | no |
| `job_owner.rs:325` `admit_interlocked` | the index admission | no |
| `job_owner.rs:347` `job_directory` | the Job directory | no |
| `job_owner.rs:384` `persist` | the record and index row | no |
| `arkforge_job_state.rs:200` `persist_arkforge_state` | the ArkForge state document | no |
| `mutation_state_continuity.rs:426` `require_mutation_state_reusing` | the continuity scan, which takes no lock since #2230, and #2242's reading of a failed publication's record and Journal | no |
| `mutation_state_continuity.rs:502` `require_retained_sessions` (#2242) | the same scan over one Sessions root | no |
| `import_references.rs:95` `with_import_references` | callers `import_lifecycle.rs:208`, `:244`: Import records | no |
| `job_retention_census.rs:23` `with_retention_keep` | caller `artifact_retention.rs:77`: the Artifact sweep | no |
| `workspace_references.rs:51` `for_each_active_workspace_job` | through `workspace_reference_facts`, caller `workspace_run.rs:1805`: workspace references | no |
| `job_owner.rs:475` `with_active_sessions` | callers `host.rs:2120` (Trace cache purge: the Artifact and Trace stores) and, now only under S, the cleanup | no |

None of these bodies or callbacks calls `SessionStore`, a publication, or `require_state`.

**The two paths the coordinator named:**
- **(a) The Session publication** runs from `Run::release`, called at `job_run.rs:500`,
  `job_cancel.rs:265` and `job_reconcile.rs:410`, `:698`, `:718`, `:739`.
  - None of these is inside an activity guard: none is called from the callbacks above.
  - Under S, the publication (`session_publication.rs:206`, `:336`, `:486`) takes only C. The
    stopped publication's move (`:693`) and the start's staging cleanup (`:573`, `:620`) take
    nothing.
- **(b) A device mutation's admission and consumption** read the storage status with
  `MutationAuthority::require_state`. It is called at `job_admission.rs:386`, `:512`,
  `flash_admission.rs:220`, `flash_run.rs:1037`, `:1208`, and `mutation_execution.rs:107`, `:167`,
  `:241`, `:354`, `:500`, `:645`.
  - They hold the `hdc_lifecycle` read guard (with the agent gate on the agent path), or the
    reservation guard, a lane and a `RunSlot`. They never hold the activity guard.
  - `require_state` releases S after its status read, before its proof takes the guard.

**Every wait for S**, and what is taken under it:

| Where | Who | Taken under S |
| --- | --- | --- |
| `session_owner.rs:192` `resource_lock` | `session.list`, `.show`, `.pin`, `.unpin` | C (`session_inventory.rs:308`) |
| `session_owner.rs:364` `hold` | `require_state`'s status read; the publication; the start's staging cleanup | C (`session_inventory.rs:235`, `:308`), or nothing |
| `session_owner.rs:448` `handle` | `runtime.storage.status`, `.policy`, `.root` | C |
| `session_cleanup_owner.rs:226` | export: C. Cleanup: the activity guard, then C (`session_inventory.rs:560`) | as said |

`session_owner.rs:349` (`status_without_waiting`, the availability report) only tries S. Under S
nothing takes a Job slot, a Target lane, the reservation guard, `hdc_lifecycle` or the agent
gate. C is taken last and held by leaf work only.

## Tests

`session_owner::cleanup::lock_order_tests`, in `session_cleanup_owner.rs`:
- Each test stops one side at a hook (`Stopped`: an `ActiveSessions` that reports it holds S and
  waits to be told to go on before it takes the activity guard) and lets the other run into it.
- A wait that does not end within 60 s is a lock cycle. The process is aborted rather than left
  hanging.
- An early answer is checked with a 200 ms bound, which only lets one arrive.

The tests:
- **`a_cleanup_waiting_for_the_storage_lock_holds_no_activity_guard`.** With S held by the test,
  the preview waits. Meanwhile a Job is admitted and written (`admit`, `persist`) and the active
  Sessions are read. Once S is released, the preview is answered.
- **`a_cleanup_holding_the_storage_lock_and_a_publication_both_finish`.**
  1. A writer holds the activity guard.
  2. The cleanup takes S and runs into the guard.
  3. The pointer oracle's tap, terminal and unpublished, reaches its publication, which waits
     for S.
  4. The writer lets go. The cleanup finishes, then the publication, with its receipt.
- **`a_cleanup_holding_the_storage_lock_and_an_admission_both_finish`.** The cleanup holds S. A
  device mutation's `require_state` waits for S. The cleanup goes on, takes the guard, which the
  admission does not hold, and finishes. The admission then proves the state.

**Negative controls, each aborting its test after the 60 s bound (SIGABRT):**
- **The first test.** The cleanup took the activity guard first and then waited for S. The Job
  write waited behind it.
- **The second test.** The publication held the activity guard while it waited for S.
- **The third test.** `require_state` read the status under the activity guard.

In the second and third, the cleanup, holding S, waited for the guard: a cycle each time.

`check-session-cleanup.py` also passes with the waiting preview (27 control exchanges).

**The test the change broke.**
`session_owner::tests::cleanup_preview_is_durable_and_refuses_configuration_contention_or_unknown_content`
held S and required the preview's refusal. With the change, the preview waited for the test's
own lock, and the first full run hung on it (stopped by hand).
- Renamed `cleanup_preview_is_durable_waits_for_the_storage_lock_and_refuses_unknown_content`.
- The preview made while the test holds S gives no answer within the 200 ms bound, and is answered
  once S is released.
- It leaves a second preview record beside the first, so the directory now holds two.
- The rest of the test is unchanged.

**This slice also records the hub's quiet-window measurements** (2026-09-26 08:44–09:04) in the
run records of #2230, #2234 and #2240.

## Contract

No contract input changes. `resourceConflict` stays in the cleanup methods' schemas: a stale
preview still answers it.

## Local targeted checks

`CARGO_BUILD_JOBS=2`, target `/private/tmp/arkdeck-vj-rust-target`, logs in
`/private/tmp/arkdeck-vj-logs/`, on `eec3df485`, before and after the hub's 08:44–09:04 quiet window
and never in it. The 1-minute load was 2 to 8.

- `cargo fmt --all --check --manifest-path rust/Cargo.toml`: exit 0 (`cl-fmt.log`).
- `cargo clippy --manifest-path rust/Cargo.toml -p arkdeck-hoststore -p arkdeck-agentd
  -p arkdeck-soak --all-targets -- -D warnings`: exit 0 (`cl-clippy.log`).
- `cargo test --manifest-path rust/Cargo.toml -p arkdeck-hoststore -p arkdeck-agentd
  -p arkdeck-soak --no-fail-fast`: exit 0 (`cl-test.log`): 113 suites, 844 passed, 0 failed, 18
  ignored (the ignores already existed).
  - The first full run, before the window, hung on the old test described above. It was
    stopped by hand, and the rewritten test passes.
- `python3 rust/scripts/check-session-owner.py`, `check-session-resources.py`,
  `check-session-export.py` and `check-session-cleanup.py`, each with `--bin-dir` on this tree's
  build: `PASS` each (`cl-scripts.log`).
- The three negative controls above.
- `sh scripts/check-sdd.sh` (validation venv): exit 0.

**After the rebase onto `82706393d`,** which brings #2242 and three M4 Flash slices:
- fmt, the same clippy and the build: exit 0 each (`cl2-fmt.log`, `cl2-clippy.log`).
- The same crate tests: exit 0 (`cl2-test.log`): 114 suites, 849 passed, 0 failed, 18 ignored.
- The four `check-session-*.py` scripts: `PASS` each (`cl2-scripts.log`).
- `sh scripts/check-sdd.sh`: exit 0.
- The lock tables above were taken again on this tree.

**Not run:**
- `generate-contract.py --check` and `check-contracts.py`: no contract input changes.
- The App and a device.

## CI

Pending.
