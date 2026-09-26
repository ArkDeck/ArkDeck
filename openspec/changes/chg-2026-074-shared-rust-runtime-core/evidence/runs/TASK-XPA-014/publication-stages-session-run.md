# A Session publication is written aside and renamed whole under the storage lock (TASK-XPA-014, macOS, 2026-09-26)

TASK-XPA-014 / CHG-2026-074. #2207's record left one race for a ruling: Rust's continuity scan
can meet a Session while it is being published and refuse a device mutation, where Swift never
refuses. The coordinator weighed two designs on 2026-09-26:
- **A**: the publisher holds the Session storage lock, `.session-storage.lock` (S), for the whole
  write.
- **A'**: the Session is written aside and renamed into place.

It set a rule in advance: A only if S is held at most 300 ms at P99 with a Journal of ten thousand
records. A holds S for one durable append per record, 3 ms each, so about 30 s for such a
Journal, with no bound. The coordinator therefore chose A'. The hub then ruled on its open
questions:
- **The scan takes no storage lock.** A deterministic test must show that, with the rename
  stopped, the scan cannot see the Session.
- **A restart only removes what it proves its own.** It never publishes again: only
  `job.reconcile`'s release path publishes a Job's Session again.
- **What nothing proves is kept.** It is named on the daemon's standard error and by `doctor` as
  a warning.

Base: protected `main` `9f1fdcce3` (#2222, the storage request waits). Developed on #2222's head
`fdf5efb97` over `3315a9cba`; see Local targeted checks for what ran on which. Disposable host
data only; nothing here is device evidence.

## The race

The publication (`session_publication.rs`, `SessionPublisher::attempt`) wrote the Session in
place:
- its directories created (step 5);
- the Job's Journal copied record by record (step 6);
- the Manifest published (step 7).

It held S only for the status read (step 0) and for the catalog entry (step 8). A device
mutation's proof (`MutationAuthority::require_state`) read the status under S and then scanned the
Session root without it. Rust's scan descends to `YYYY/MM/session-ID` and replays each Session's
Journal. Met mid-write, it refused:
- a Session with only its directories (a depth-3 container);
- a Journal whose copy has an intent whose outcome is not copied yet.

The deterministic test below, with the scan no longer passing `.staging` over, shows it:

```
{"error":{"code":"admissionDenied","details":{"newDispatchCount":0,"phase":"preAdmission"},...},"ok":false}
```

## Swift

- `RuntimeSessionPublicationWriter.attempt` writes the Session in place. It takes S for
  `status()` and for `registerPublishedSession` alone.
- It copies the Journal record by record (`appendAndSynchronize`).
- A failure after the Session is created leaves what was written.
- A restart never resumes a publication.
- `RuntimeStateContinuity` looks only at the Session root's direct children, so it never reads a
  Session's Journal.

## Change

- **The Session is written aside.** The publication creates `.staging/<UUID>` in the Sessions root
  under S. It writes the Session tree, the Journal copy, the outcome audit and the write-once
  Manifest there without S.
- **The rename, under S.** It renames the Session whole to `yyyy/mm/session-<job>` with
  `renameatx_np(RENAME_EXCL)`, never over another entry. It then removes `.staging` once it is
  empty and registers the catalog entry.
- **When S is held.** Only for the status read, the creation of staging, and the rename with the
  catalog entry. Never while the Session is written.
- **A taken name refuses where Swift's does.** A Session name something already holds refuses at
  step 5, before anything is staged ("Session already exists"). `RENAME_EXCL` is the last guard;
  it too refuses.
- **A publication that fails short of its rename** moves its staged Session to its name as it
  stands. That is exactly what Swift, writing in place, leaves. The staging is removed only when
  the name is taken.
- **Both scans pass over exactly `.staging` of a Sessions root.**
  - The continuity scan does it at depth 0 (`mutation_state_continuity.rs`).
  - The inventory does it in `scan` (`session_inventory.rs`), which status, resources, export
    and cleanup read.
  - A staged Session is a terminal Job's Journal copied in part or in full. The Job's own Journal
    and the capability ledger hold its mutation state. No answer counts staging.
- **The admission is #2207's.** `require_state` reads the status under S, waiting for it
  (`SessionStore::waited_status`), and releases it before the continuity scan.
  `state_proven_now` reads it without waiting.
  - The rename is atomic, and the scan passes staging over. A scan without S therefore meets
    either no Session at the name or the whole one.
  - Holding S through the scan would stall every storage request for as long as the scan takes:
    9.4 s over one retained Session with a 10,013-record Journal (see Cost).
- **`SessionStore::hold`** returns a `StorageHold` (`session_owner.rs`).
  - `status`, `publication_status`, `register_published_session` and `configured_root` work under
    the lock already held.
  - The publication renames and registers under one hold. A second `flock` on another descriptor
    would wait for the first.
- **New `HostDirectory` methods** (`arkdeck-platform`, `host_session_publication.rs`):
  `move_exclusive`, `remove_tree` (descriptors only, refusing a link) and `remove_if_empty`.
- **`StorageProbe::reached(PublicationPoint)`**, a default no-op, lets a test stop or time a
  publication:
  - `SessionCreated`;
  - `JournalCopied { copied, of }`;
  - `ManifestPublished`;
  - `Moving` (S held, not yet renamed);
  - `StorageReleased { held }`.

## Restart: a staged Session left behind

A crash between staging and the rename leaves the staged Session in `.staging`.
`SessionPublisher::recover_staged` runs at the daemon's start, after the Job recovery and before
the daemon serves (`arkdeck-agentd` `main.rs`, `Host::recover_staged_sessions`).
- **What proves an entry this Runtime's:**
  - a staged name (Swift's `UUID().uuidString` form, as `uuid` makes it);
  - a private directory of this Runtime's;
  - the Session identity a publication creates, canonical, naming a Job this Runtime holds.
- **A proved entry is removed.** The daemon names it on its standard output: "removed staged
  Session <entry> of job <job>, which a stopped publication left". Nothing is published again, as
  Swift's restart resumes nothing.
  - The Job keeps its record and Journal as the crash left them: no publication marker, so every
    read reports `noCurrentPublicationRecord`.
  - `job.reconcile` publishes again only after the writer's confirmed refusal of an unbound
    source, as Swift's does (`job_reconcile.rs`). A crash leaves no such marker.
- **Anything else is kept exactly as it is.** The daemon names it on its standard error and every
  `doctor` report names it: `storage.stagedSessionQuarantined`, severity `warning`, scope
  `storage`.
  - No admission or answer reads staging, so the finding never makes a report unready.
  - A staging the start cannot read at all is kept whole and named the same way. The start goes
    on.
- **`.staging` itself** is removed under S once it is empty, as a publication removes it.
- The status read is not used at the start: it would create a catalog. The start reads only the
  configured root (`StorageHold::configured_root`).

## Declared differences from Swift

- **The write order before the rename.** The Session is written aside and appears whole. What is
  published, and every answer, is Swift's:
  - `job_publication` replays Swift's publications and all they leave, byte for byte;
  - `device_reconcile` does the same with a publication stopped before its Manifest.
- **A crash's leftovers.** After a crash mid-publication Swift leaves a partial Session at its
  name. Rust leaves nothing at the name, and its next start removes the staged copy. Neither
  publishes it again.
- **A `doctor` finding Swift never gives:** `storage.stagedSessionQuarantined`.

## Lock order

The order stays: Job slot → Target lane → capability reservation guard → S → retention catalog
lock. A' adds no edge.

**Entering a publication.** Every publication goes through `Run::release` (`job_run.rs:299`):
- `JobRunner::handle` (`job_run.rs:496`), from `job.run` or an agent execution's background run.
  - The run holds its `RunSlot`, a registration in `running`.
  - A device run has dropped its Target lane (`device_run.rs:388`; a HAP failure's finalization
    at `:410`) and settled its capability use before `release`.
- `JobCanceller` (`job_cancel.rs:265`).
- `job.reconcile` (`job_reconcile.rs:406`, through `:694`, `:710` and `:731`).

**What a holder of S takes.**
- The status read (step 0): the retention catalog lock, as every status read does.
- The staging creation: nothing.
- The rename, the removal of staging and the catalog entry: the retention catalog lock
  (`register_session` waits for it).
- A failed publication's move of what it staged (`Staged`'s drop): nothing.
- The start's `recover_staged`: nothing.

The Job directory's and the Session's `.manifest.lock`, the publication shards and `activity` are
taken outside S. So the edges S → `.manifest.lock` and S → `activity` that A would have added do
not exist.

**Who waits for S, holding what.**

| Waiter | Holds while it waits |
| --- | --- |
| an admission (`preauthorize`), for its status read | the `hdc_lifecycle` read guard (`job_owner.rs:81`); on the agent path also the gate (`agent_execution.rs:1394`) |
| a consumption, for its status read | the reservation guard (`mutation_execution.rs:67`, `237`, `617`), its lane, its `RunSlot` |
| a storage request | nothing |
| a publication | its `RunSlot` |
| the daemon's start | nothing; nothing is served yet |

No holder of S waits for any of these. Session cleanup still only tries S
(`session_cleanup_owner.rs:212`) while it holds `activity`. The slice that makes it wait must
take S before `activity`.

## Tests

- **`pointer_input_run::a_gesture_submitted_while_the_previous_one_writes_its_session_is_admitted_at_once`.**
  1. The tap's publication stops once its staged Journal ends at `intent-inject-pointer-input`.
     S is not held.
  2. The long press, submitted then, is admitted at once, as Swift admitted it.
  3. A scan of the root passes the staged Session over.
  4. The tap ends as Swift's did.
  - Negative control: with the scan not passing `.staging` over, the long press answered
    `admissionDenied` (`preAdmission`).
- **`pointer_input_run::a_gesture_submitted_while_the_previous_one_renames_its_session_waits_for_it`.**
  The publication stops at `Moving`, with S held and the Session not renamed.
  - A scan (`JobStore::require_mutation_state`) answers at once, and no Session is at the name.
    The scan cannot see the Session until the rename moves it whole.
  - The long press gives no answer until the publication goes on. Its status read waits for S.
    It is then admitted as Swift admitted it.
  - Negative control: with `Moving` reported after the rename, the test failed. At the stop,
    staging no longer held the Session: it was already at its name.
- **`pointer_input_run::a_publication_stopped_before_its_rename_is_removed_at_the_next_start`.**
  A child process of the test binary runs the tap and exits (75) once the staged Manifest is
  published.
  - Three entries nothing proves are added: a name no publication stages, a staged name without
    an identity, and a canonical identity naming a Job this Runtime does not hold.
  - `recover_staged` removes the staged Session and names its Job. It keeps the three with their
    reasons.
  - Nothing is published: no Session at the name. The Job's record and Journal are byte for byte
    what the crash left.
  - A second start changes nothing. With the three removed, a third start removes `.staging`.
  - Negative control: with the identity and Job checks skipped, the three were removed too, and
    the test failed.
- **`production_composition::the_start_removes_a_stopped_publications_staged_session_and_keeps_what_nothing_proves`**
  (`arkdeck-agentd`). A production daemon starts over a parked Job's staged Session and an
  unprovable entry.
  - Its standard output names the removal, and its standard error names the kept entry.
  - `doctor` reports the kept entry, standard and deep.
  - `job.show` reports no publication, and nothing is at the Session's name.
  - Negative control: with the Host not handing the kept entries to `doctor`, the test failed.
- **`doctor_report::a_kept_staged_session_is_a_storage_warning`** (`arkdeck-control`). The finding
  comes right after `storage.sessionOutputOwnerUnavailable`, in both modes. It adds one warning
  and changes nothing else: every other finding, `ready`, and the blocker count stay the same.
- **`host_store::session_publication::staging_tests`** (`arkdeck-platform`): the moves, the refusal
  over an entry, the descriptor removal and a link refused.
- **The oracle replays, unchanged and passing:** `job_publication` (byte for byte), `device_reconcile`,
  `crash_window`, `job_cancel`, `job_reconcile`, `agent_execution_analyzer` and the rest of
  `pointer_input_run`.

## Cost

- **The storage lock during a 10,013-record publication**
  (`session_publication::measurement`, `#[ignore]`d). This is one sample, on a quiet host (Apple
  M3, 1-minute load 2.39, `/private/tmp/arkdeck-vj-logs/measure-a-prime.log`), taken on this
  slice's earlier revision. That revision had the same steps under S.
  - S was held 0.63 ms for the status read, 6.1 ms for the creation of staging, and 23.3 ms for
    the rename, the removal of staging and the catalog entry.
  - The whole publication took 50 s, without S.
- **The P99 run, in the hub's quiet window** (see below). It was not run with the slice: the
  host's 1-minute load was then 11.8, with five sessions building in parallel.
- **One proof, alone, over one retained 10,013-record Session: 9.4 s** (the same sample). The
  Journal replay grows with the square of a Journal's length (`ReplayState::validate` looks
  through every intent for each event). This is why the scan does not run under S. The next
  slice makes the replay linear.

**The P99 run.** The hub's quiet window, 2026-09-26 08:44–09:04: no build ran on the host. The hub measured the
1-minute load every 15 s: a median of 2.07 with every session's builds stopped, and a median of
2.66 (max 3.35) during these measurements. This session sampled it every second
(`window-load.log`): between 1.96 and 3.42. It ran a prebuilt debug binary, the
`arkdeck-hoststore` library tests as built on `eec3df485` with the cleanup slice's change, which
touches none of the measured paths, measuring only
(`window-measure.log`).
- `session_publication::measurement`: 12 samples, each publishing the 10,013-record Journal into
  a Sessions root of its own while another thread proves the mutation state over and over. The
  load was 1.97 to 3.22 before and after each sample.
- By then #2234 and #2240 were on `main`, so a proof no longer replays quadratically.

| What | n | Min | P50 | P95 | P99 | Max |
| --- | --- | --- | --- | --- | --- | --- |
| The storage lock held, each of a publication's three holds | 36 | 0.53 ms | 8.9 ms | 26.6 ms | 27.7 ms | 27.7 ms |
| A whole publication, without the lock | 12 | 33.0 s | 36.3 s | 37.7 s | 39.2 s | 39.2 s |
| A proof during a publication | 255,124 | 0.67 ms | 0.90 ms | 3.95 ms | 4.21 ms | 553 ms |
| A proof alone, over the one retained Session | 12 | 512 ms | 514 ms | 515 ms | 516 ms | 516 ms |

The storage lock's P99 is 27.7 ms, where the coordinator's rule for design A allowed 300 ms. The
longest proof during a publication, 553 ms, is the one that first met the renamed 10,013-record
Session.

## Contract

No contract input changes. The scan's refusal appears in no ControlFrames corpus frame, and no
wording changes. The `doctor` result schema enumerates no finding code, so the new finding
conforms to it.

## Local targeted checks

`CARGO_BUILD_JOBS=2`, target `/private/tmp/arkdeck-vj-rust-target`, logs in
`/private/tmp/arkdeck-vj-logs/`. The host was loaded (1-minute load between 5 and 32 at the
samples taken, five sessions building) while the crate tests ran.

**On `fdf5efb97` (#2222's head, over `3315a9cba`):**
- `cargo fmt --all --check --manifest-path rust/Cargo.toml`: exit 0 (`s3c-fmt.log`).
- `cargo clippy --manifest-path rust/Cargo.toml --all-targets -- -D warnings`: exit 0
  (`s3c-clippy.log`).
  - The changed crates: `arkdeck-platform`, `arkdeck-hoststore`, `arkdeck-control` and
    `arkdeck-agentd`.
  - The crates that depend on them: `arkdeck-soak`, `arkdeck-cli`, `arkdeck-client`,
    `arkdeck-bootstrap`, `arkdeck-provider-hdc`, `arkdeck-provider-workspace` and
    `arkdeck-provider-arkforge`.
- The same clippy for the changed crates with `--target x86_64-pc-windows-msvc` and
  `--target x86_64-unknown-linux-gnu`: exit 0 each (`s3c-cross-*.log`).
- `cargo test --manifest-path rust/Cargo.toml -p arkdeck-platform -p arkdeck-hoststore
  -p arkdeck-control -p arkdeck-agentd -p arkdeck-soak --no-fail-fast`: exit 0 (`s3c-test.log`).
  - 135 suites: 1041 passed, 0 failed, 20 ignored.
  - Three of the ignored are this slice's measurements. The others already existed.
- `python3 rust/scripts/check-session-owner.py`, `check-session-resources.py`,
  `check-session-export.py` and `check-session-cleanup.py`, each with `--bin-dir` on this tree's
  build: `PASS` each (23, 27, 15 and 27 control exchanges; `s3c-scripts.log`).
- The four negative controls above.

**After the rebase onto `9f1fdcce3`,** which brings #2218, #2220 and #2221:
- `cargo fmt --all --check`: exit 0 (`s3d-fmt.log`).
- `cargo clippy -p arkdeck-platform -p arkdeck-hoststore -p arkdeck-control -p arkdeck-agentd
  -p arkdeck-soak --all-targets -- -D warnings`: exit 0 (`s3d-clippy.log`).
- `cargo test -p arkdeck-agentd -p arkdeck-control --no-fail-fast`, then `-p arkdeck-hoststore`:
  exit 0 each (`s3d-test.log`).
  - 112 suites: 847 passed, 0 failed, 16 ignored.
  - They include #2220's `agent_run_cli_process`: an agent run of every gesture through the
    real daemon and CLI, each published through staging.
- `rust/scripts/check-job-run.py --swift-bin-dir <run-swiftpm debug products>`, in a Swift window
  the hub granted: `PASS`, 156 checks (`s3d-job-run.log`).
  - The standalone Swift daemon and the Rust owner, in turn over one state root, answer the 19
    runs and 10 cancellations identically.
  - Each owner publishes the same 18 Sessions, compared file by file with their modes.
  - A standalone Swift daemon given the Rust-run store reads all 16 Jobs and keeps the parked one
    parked. It lists and shows all 18 Rust-published Sessions with none unaccounted, and reads
    the 4 Rust-published products back.
  - Summary: `/private/tmp/arkdeck-vj-logs/s3d-job-run.json`, SHA-256
    `d603a7a0eb7145a3b7165c814c8603180ceede098ebc450fc6bea7f8757ad7c1`.
  - The Rust daemon: SHA-256 `cabd27bc2d2bedef40014e3db44d3ad5da28df0407b6fd51d50927df67f64589`.
- `sh scripts/check-sdd.sh` (validation venv): exit 0.

**Not run:**
- The 12-sample P99 measurement of S (see Cost).
- `generate-contract.py --check` and `check-contracts.py`: no contract input changes.
- The App: nothing of it changes.
- A device.

## CI

#2230, head `159fb4c8e`, run 36195413805: every selected lane passed.
- Rust workspace: macOS 12m20s, Ubuntu 2m15s, Windows 4m50s. Host-independent checks: 39s.
- `guard`; `swift` aggregate. `swift-tests` was not selected.

It merged as `4eb8c6778`. Recorded by a later slice (TASK-XPA-014, the Session verdict cache), as
AGENTS.md has it.
