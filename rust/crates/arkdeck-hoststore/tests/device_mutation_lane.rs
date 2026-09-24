//! A Target's device mutation lane (Swift `DeviceMutationLaneCoordinator`,
//! `device_lane.rs`) through the production Rust admitter and runner, over the
//! shared fake HDC with two adopted Targets (the pointer oracle's device and a
//! second one on its own connect key):
//! - two gestures on one Target run strictly one after another: the second,
//!   run while the first is held inside its gesture dispatch, waits in the
//!   lane having dispatched and written nothing, and runs once the first has
//!   concluded and settled its use;
//! - gestures on two Targets run at once;
//! - a gesture cancelled while it waits closes with nothing dispatched and
//!   leaves the queue;
//! - the lane is let go of when a gesture fails, parks on an unknown outcome
//!   or panics.
//!
//! Every wait below is for the fact it names, observed directly — a Job in
//! the lane's queue, a call the fake received, a run that returned — and the
//! first gesture is held on a gate the test alone opens; no clock decides
//! anything, and the sixty-second bounds only keep a broken lane from hanging
//! the suite. Never hardware acceptance.
#![cfg(target_os = "macos")]

mod support;

use arkdeck_contract::sha256_hex;
use arkdeck_hoststore::{
    ArtifactReadStore, CapabilityStore, DeviceHolds, HdcComposition, JobAdmitter, JobPlanner,
    JobRunner, JobStore, LaneState, MutationAuthority, MutationExecution, RunCancellation,
    RunRefusal, TargetStore,
};
use arkdeck_platform::VerifiedTool;
use arkdeck_provider_hdc::{
    DispatchFailure, HdcDispatch, ProcessDispatch, ProcessPlan, Receipt, stable_identity_sha256,
};
use serde_json::{Map, Value, json};
use std::fs;
use std::path::PathBuf;
use std::sync::{Arc, Condvar, Mutex, PoisonError};
use std::time::{Duration, Instant};
use support::{chmod, debug_hap, fixed_now, fixed_precise_now};

/// The pointer oracle's device, and a second one.
const FIRST_KEY: &str = "aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa";
const SECOND_KEY: &str = "bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb";

/// The pointer oracle's gesture answers, for both devices.
const ANSWERS: &str = r#"# input.tap@1 and input.long-press@1 answers for two devices, by mode.
case "$1 $2" in
"-t aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa"|"-t bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb") shift 2 ;;
esac
case "$*" in
"list targets -v")
  printf '%s\t\tUSB\tConnected\tlocalhost\n' aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb ;;
"shell param get const.product.name")
  printf 'OpenHarmony Reference Device\n' ;;
"shell param get const.ohos.fullname")
  printf 'OpenHarmony-4.1-release\n' ;;
"shell uinput "*)
  case "$mode" in
  rejected) printf 'parameter error, unable to run\n'; exit 0 ;;
  otherGesture) printf 'startX:100, startY:2200, endX:100, endY:1200\n'; exit 0 ;;
  esac
  shift 2
  [ "$1" = -D ] && shift 2
  case "$2" in
  -c) printf '   click coordinate: (%s, %s)\nclick interval time: 100ms\n' "$3" "$4" ;;
  -d) printf 'touch down %s %s\ntouch up %s %s\n' "$3" "$4" "$8" "$9" ;;
  esac
  printf 'If the command does not work as expected, check whether the specified coordinates exceed the screen boundary\n' ;;
*)
  printf 'unregistered fixture output\n' >&2
  exit 23 ;;
esac
"#;

/// Waits until `condition` holds; the bound only keeps a broken lane from
/// hanging the suite.
fn until(what: &str, condition: impl Fn() -> bool) {
    let started = Instant::now();
    while !condition() {
        assert!(
            started.elapsed() < Duration::from_secs(60),
            "never reached: {what}"
        );
        std::thread::yield_now();
    }
}

/// A probe the first Job's runner reads its clock through: the Target owner,
/// the lane and the Job waiting for it. Set by one test alone.
type SettleProbe = Option<(Arc<TargetStore>, String, String)>;
static SETTLE_PROBE: Mutex<SettleProbe> = Mutex::new(None);

/// The runners' clock. Once the Job waiting in the probed lane has been
/// handed it, a read on the first Job's thread means the first let go of its
/// lane before its run ended — before its use was settled, since settling
/// reads the clock last: that read then waits until the second Job's run has
/// ended in the lane, as a slower host would order them. While the first
/// holds its lane, as it must until it has settled, nothing waits here.
fn probing_now() -> Option<String> {
    let probe = SETTLE_PROBE
        .lock()
        .unwrap_or_else(PoisonError::into_inner)
        .clone();
    if let Some((targets, key, waiting)) = probe
        && std::thread::current().name() == Some("job-a")
        && targets.mutation_lane_state(&key, &waiting) == Some(LaneState::Active)
    {
        until("the second Job's run in the lane ended", || {
            targets.mutation_lane_state(&key, &waiting) != Some(LaneState::Active)
        });
    }
    fixed_now()
}

/// Clears the probe however its test ends.
struct Probing;

impl Drop for Probing {
    fn drop(&mut self) {
        *SETTLE_PROBE.lock().unwrap_or_else(PoisonError::into_inner) = None;
    }
}

/// The Target an adopted connect key names.
fn target(key: &str) -> String {
    format!("TGT-{}", &stable_identity_sha256(key)[..12])
}

fn tap(name: &str, key: &str, x: i64) -> Value {
    json!({"documentType": "runtime-operation-request", "schemaVersion": "1.0.0",
        "requestId": format!("req-lane-{name}"), "idempotencyKey": format!("idem-lane-{name}"),
        "operation": {"id": "input.tap", "version": 1},
        "target": {"targetId": target(key), "expectedBindingRevision": 1},
        "inputs": {"displayHeight": 2832, "displayWidth": 1280,
            "screenEpochUtc": "2026-09-14T00:00:00.000Z", "x": x, "y": 1500}})
}

fn long_press(name: &str, key: &str) -> Value {
    json!({"documentType": "runtime-operation-request", "schemaVersion": "1.0.0",
        "requestId": format!("req-lane-{name}"), "idempotencyKey": format!("idem-lane-{name}"),
        "operation": {"id": "input.long-press", "version": 1},
        "target": {"targetId": target(key), "expectedBindingRevision": 1},
        "inputs": {"displayHeight": 2832, "displayId": 2, "displayWidth": 1280,
            "durationMs": 1200, "screenEpochUtc": "2026-09-14T00:00:00.000Z", "x": 12, "y": 700}})
}

/// What the first gesture dispatch of one thread waits for: the test's leave
/// to go on. The thread named here is held; any other passes.
#[derive(Default)]
struct Gate {
    state: Mutex<GateState>,
    changed: Condvar,
}

#[derive(Default)]
struct GateState {
    held: Option<&'static str>,
    arrived: bool,
    open: bool,
}

impl Gate {
    fn hold(&self, thread: &'static str) {
        *self.state.lock().unwrap() = GateState {
            held: Some(thread),
            ..GateState::default()
        };
    }
    /// Blocks the calling thread's gesture if it is the one held.
    fn pass(&self) {
        let mut state = self.state.lock().unwrap();
        let this = std::thread::current();
        if state.arrived || state.held.is_none() || state.held != this.name() {
            return;
        }
        state.arrived = true;
        self.changed.notify_all();
        let (state, waited) = self
            .changed
            .wait_timeout_while(state, Duration::from_secs(60), |state| !state.open)
            .unwrap();
        drop(state);
        assert!(!waited.timed_out(), "the held gesture was never let go");
    }
    fn wait_arrived(&self) {
        let (state, waited) = self
            .changed
            .wait_timeout_while(
                self.state.lock().unwrap(),
                Duration::from_secs(60),
                |state| !state.arrived,
            )
            .unwrap();
        drop(state);
        assert!(!waited.timed_out(), "the held gesture was never dispatched");
    }
    fn open(&self) {
        self.state.lock().unwrap().open = true;
        self.changed.notify_all();
    }
}

/// Opens the gate however the test ends, so a failed assertion never leaves
/// a held run behind for its scope to wait on.
struct Opens<'a>(&'a Gate);

impl Drop for Opens<'_> {
    fn drop(&mut self) {
        self.0.open();
    }
}

/// The fake HDC's dispatch, each call recorded with the name of the thread
/// that made it; a held thread's first gesture waits at the gate, and a
/// thread named `panics` panics at its gesture.
struct Recorded {
    inner: ProcessDispatch,
    calls: Mutex<Vec<(String, String)>>,
    gate: Gate,
}

impl HdcDispatch for Recorded {
    fn dispatch(&self, plan: &ProcessPlan) -> Result<Receipt, DispatchFailure> {
        let gesture = plan.arguments.iter().any(|argument| argument == "uinput");
        let thread = std::thread::current().name().unwrap_or_default().to_owned();
        if gesture {
            self.gate.pass();
            assert!(thread != "panics", "the gesture's executor panicked");
        }
        self.calls
            .lock()
            .unwrap()
            .push((thread, plan.arguments.join(" ")));
        self.inner.dispatch(plan)
    }
    fn mutation_identity_current(&self) -> bool {
        self.inner.mutation_identity_current()
    }
}

/// The owners one daemon composes over the fixed root, as the pointer
/// oracle's replay composes them, with the fake answering two devices.
struct Owners {
    root: PathBuf,
    default_root: PathBuf,
    digest: String,
    targets: Arc<TargetStore>,
    artifacts: ArtifactReadStore,
    jobs: JobStore,
    capabilities: CapabilityStore,
    holds: DeviceHolds,
    dispatch: Recorded,
}

impl Owners {
    /// The pointer oracle's root rebuilt, its fake answering both devices
    /// and both adopted. The caller holds [`debug_hap::exclusive`].
    fn open() -> Self {
        let root = debug_hap::rebuild(&support::fixture("pointer-input"));
        fs::write(root.join("hdc-answers.sh"), ANSWERS).unwrap();
        let adopted = |key: &str| {
            json!({"adoptedAtUTC": "2026-09-14T00:00:00Z", "bindingRevision": 1, "connectKey": key,
                "stablePhysicalIdentitySHA256": stable_identity_sha256(key), "targetID": target(key),
                "toolVersion": "3.2.0d"})
        };
        let targets = root.join("targets-state/targets.json");
        fs::write(
            &targets,
            serde_json::to_vec_pretty(&json!({"schemaVersion": "1.0.0",
                "targets": [adopted(FIRST_KEY), adopted(SECOND_KEY)]}))
            .unwrap(),
        )
        .unwrap();
        chmod(&targets, 0o600);
        let digest = sha256_hex(&fs::read(root.join("hdc")).unwrap());
        let default_root = root.join("store");
        let jobs = JobStore::open_owner(&default_root).unwrap();
        Self {
            targets: Arc::new(TargetStore::open(&root.join("targets-state")).unwrap()),
            artifacts: ArtifactReadStore::open(&root.join("artifacts")).unwrap(),
            capabilities: CapabilityStore::open(&default_root.join("capabilities")).unwrap(),
            holds: DeviceHolds::default(),
            dispatch: Recorded {
                inner: ProcessDispatch::new(
                    VerifiedTool::open(root.join("hdc"), &digest).unwrap(),
                    None,
                ),
                calls: Mutex::default(),
                gate: Gate::default(),
            },
            jobs,
            default_root,
            digest,
            root,
        }
    }

    fn hdc(&self) -> HdcComposition<'_> {
        HdcComposition {
            targets: &self.targets,
            dispatch: &self.dispatch,
            receive_root: None,
            tool_sha256: &self.digest,
            now: fixed_now,
            code_sign_helper: None,
        }
    }

    fn authority(&self) -> MutationAuthority<'_> {
        MutationAuthority {
            default_root: &self.default_root,
            sessions: None,
            capabilities: &self.capabilities,
            holds: &self.holds,
        }
    }

    /// The admitted Job's identity.
    fn submit(&self, request: &Value) -> String {
        let hdc = self.hdc();
        let admitted = JobAdmitter {
            planner: JobPlanner {
                imports: None,
                artifacts: Some(&self.artifacts),
                analyzer: None,
                state_root: &self.root,
                hdc: Some(&hdc),
                workspace: None,
            },
            jobs: &self.jobs,
            now: fixed_now,
            authority: Some(self.authority()),
        }
        .handle(&Map::from_iter([(
            "requestJson".into(),
            json!(request.to_string()),
        )]))
        .unwrap_or_else(|refusal| panic!("{}: {}", refusal.code, refusal.message));
        admitted["jobId"].as_str().unwrap().to_owned()
    }

    /// `job.run` of `job`, a canceller reaching it through `cancellation`.
    fn run(&self, job: &str, cancellation: Option<&RunCancellation>) -> Result<Value, RunRefusal> {
        let hdc = self.hdc();
        JobRunner {
            imports: None,
            mutation: Some(MutationExecution {
                authority: self.authority(),
                state_root: &self.root,
            }),
            jobs: &self.jobs,
            artifacts: &self.artifacts,
            analyzer: None,
            quota: u64::MAX,
            home: "/private/tmp",
            now: probing_now,
            precise_now: fixed_precise_now,
            sessions: None,
            cancellation,
            after_commit: None,
            hdc: Some(&hdc),
            workspace: None,
        }
        .handle(&Map::from_iter([("jobId".into(), json!(job))]))
    }

    /// The fake's calls a thread made, in order.
    fn calls(&self, thread: &str) -> Vec<String> {
        self.dispatch
            .calls
            .lock()
            .unwrap()
            .iter()
            .filter(|(caller, _)| caller == thread)
            .map(|(_, call)| call.clone())
            .collect()
    }

    fn journal(&self, job: &str) -> String {
        fs::read_to_string(
            self.default_root
                .join("jobs")
                .join(job)
                .join("journal.jsonl"),
        )
        .unwrap()
    }

    fn state(&self, job: &str) -> String {
        self.jobs.read_snapshot(job).unwrap().state
    }

    /// The use events of the capability store's ledger, in order: each
    /// consumption's and each outcome's Job.
    fn uses(&self) -> Vec<(String, String)> {
        fs::read_to_string(
            self.default_root
                .join("capabilities/runtime-capabilities.ledger"),
        )
        .unwrap_or_default()
        .lines()
        .map(|line| {
            let row: Value = serde_json::from_str(line).unwrap();
            let kind = row["kind"].as_str().unwrap().to_owned();
            let job = match kind.as_str() {
                "consumed" => &row["consumption"]["jobID"],
                _ => &row["outcome"]["jobID"],
            };
            (kind, job.as_str().unwrap().to_owned())
        })
        .collect()
    }

    /// Whether `holder` holds, awaits, or is absent from `key`'s lane.
    fn lane(&self, key: &str, holder: &str) -> Option<LaneState> {
        self.targets.mutation_lane_state(key, holder)
    }

    /// Whether nobody holds or awaits `key`'s lane: a fresh request enters
    /// at once.
    fn free(&self, key: &str) -> bool {
        self.targets.mutation_lane_queue(key).is_empty()
            && matches!(
                self.targets
                    .enter_mutation_lane(key, "lane-probe", Some(&|| true)),
                Ok(Some(_))
            )
    }
}

fn spawn_named<'scope, T: Send + 'scope>(
    scope: &'scope std::thread::Scope<'scope, '_>,
    name: &'static str,
    body: impl FnOnce() -> T + Send + 'scope,
) -> std::thread::ScopedJoinHandle<'scope, T> {
    std::thread::Builder::new()
        .name(name.into())
        .spawn_scoped(scope, body)
        .unwrap()
}

fn succeeded(answer: Result<Value, RunRefusal>) -> Value {
    let status = answer.unwrap_or_else(|refusal| panic!("{}: {}", refusal.code, refusal.message));
    assert_eq!(status["state"], "succeeded", "{status}");
    status
}

/// Swift's engine runs a device mutation Job's steps in its Target's lane:
/// a second one on the same device waits, dispatching nothing, until the
/// first has concluded. Rust holds the lane until the first's use is also
/// settled, so the second's consumption never meets it pending; the runners'
/// clock ([`probing_now`]) lets a first Job that let go of its lane earlier
/// meet the second Job's whole run before its own settling, every time.
#[test]
fn two_gestures_on_one_target_run_one_after_another() {
    let _lock = debug_hap::exclusive();
    let owners = Owners::open();
    let first = owners.submit(&tap("first", FIRST_KEY, 640));
    let second = owners.submit(&long_press("second", FIRST_KEY));
    let key = owners
        .targets
        .mutation_lane_key(&target(FIRST_KEY))
        .unwrap();
    let _probing = Probing;
    *SETTLE_PROBE.lock().unwrap() = Some((owners.targets.clone(), key.clone(), second.clone()));
    owners.dispatch.gate.hold("job-a");
    let (a, b) = std::thread::scope(|scope| {
        let _opens = Opens(&owners.dispatch.gate);
        let a = spawn_named(scope, "job-a", || owners.run(&first, None));
        owners.dispatch.gate.wait_arrived();
        let b = spawn_named(scope, "job-b", || owners.run(&second, None));
        // The second Job either waits in the lane or has begun to run beside
        // the first; whichever is seen first decides.
        until("the second Job queued or dispatching", || {
            owners.lane(&key, &second) == Some(LaneState::Queued)
                || !owners.calls("job-b").is_empty()
                || b.is_finished()
        });
        // While the first is held inside its gesture, the second has sent
        // nothing, and nothing of it is durable: no running transition, no
        // use.
        assert!(
            owners.calls("job-b").is_empty(),
            "{:?}",
            owners.calls("job-b")
        );
        assert_eq!(owners.state(&second), "preflight");
        assert!(!owners.journal(&second).contains("steps-start"));
        assert!(owners.uses().iter().all(|(_, job)| *job != second));
        // It waits in the first's lane, which the first holds.
        assert_eq!(owners.lane(&key, &second), Some(LaneState::Queued));
        assert_eq!(owners.lane(&key, &first), Some(LaneState::Active));
        owners.dispatch.gate.open();
        (a.join().unwrap(), b.join().unwrap())
    });
    succeeded(a);
    succeeded(b);
    // The first Job's use was consumed and settled before the second's was
    // consumed; each gesture was sent once, the first before any call of the
    // second.
    assert_eq!(
        owners.uses(),
        [
            ("consumed".into(), first.clone()),
            ("outcome".into(), first.clone()),
            ("consumed".into(), second.clone()),
            ("outcome".into(), second.clone()),
        ]
    );
    let calls = owners.dispatch.calls.lock().unwrap().clone();
    let last_of_a = calls.iter().rposition(|(thread, _)| thread == "job-a");
    let first_of_b = calls.iter().position(|(thread, _)| thread == "job-b");
    assert!(last_of_a < first_of_b, "{calls:?}");
    assert!(
        calls[last_of_a.unwrap()]
            .1
            .contains("uinput -T -c 640 1500")
    );
    assert_eq!(
        calls
            .iter()
            .filter(|(_, call)| call.contains("uinput"))
            .count(),
        2,
        "{calls:?}"
    );
    assert!(owners.free(&key));
}

/// Swift keeps one lane per device: a gesture on another Target runs to its
/// end while the first is held inside its own.
#[test]
fn gestures_on_two_targets_run_at_once() {
    let _lock = debug_hap::exclusive();
    let owners = Owners::open();
    let first = owners.submit(&tap("first", FIRST_KEY, 640));
    let other = owners.submit(&tap("other", SECOND_KEY, 320));
    let (first_key, other_key) = (
        owners
            .targets
            .mutation_lane_key(&target(FIRST_KEY))
            .unwrap(),
        owners
            .targets
            .mutation_lane_key(&target(SECOND_KEY))
            .unwrap(),
    );
    assert_ne!(first_key, other_key);
    owners.dispatch.gate.hold("job-a");
    std::thread::scope(|scope| {
        let _opens = Opens(&owners.dispatch.gate);
        let a = spawn_named(scope, "job-a", || owners.run(&first, None));
        owners.dispatch.gate.wait_arrived();
        let c = spawn_named(scope, "job-c", || owners.run(&other, None));
        until("the other Target's Job concluded or queued", || {
            c.is_finished() || owners.lane(&other_key, &other) == Some(LaneState::Queued)
        });
        assert_ne!(owners.lane(&other_key, &other), Some(LaneState::Queued));
        succeeded(c.join().unwrap());
        // Its gesture was sent while the first is still held inside its own.
        assert!(
            owners
                .calls("job-c")
                .iter()
                .any(|call| call.contains(&format!("-t {SECOND_KEY} shell uinput -T -c 320 1500")))
        );
        assert!(
            owners
                .calls("job-a")
                .iter()
                .all(|call| !call.contains("uinput"))
        );
        owners.dispatch.gate.open();
        succeeded(a.join().unwrap());
    });
    assert!(owners.free(&first_key) && owners.free(&other_key));
}

/// A request to cancel a Job that waits for its lane is answered while the
/// holder still holds it: the Job closes `cancelled` at its first step
/// boundary, having dispatched and consumed nothing, and leaves the queue.
#[test]
fn a_gesture_cancelled_while_it_waits_never_touches_the_device() {
    let _lock = debug_hap::exclusive();
    let owners = Owners::open();
    let first = owners.submit(&tap("first", FIRST_KEY, 640));
    let second = owners.submit(&long_press("second", FIRST_KEY));
    let key = owners
        .targets
        .mutation_lane_key(&target(FIRST_KEY))
        .unwrap();
    let cancellation = RunCancellation::default();
    owners.dispatch.gate.hold("job-a");
    std::thread::scope(|scope| {
        let _opens = Opens(&owners.dispatch.gate);
        let a = spawn_named(scope, "job-a", || owners.run(&first, None));
        owners.dispatch.gate.wait_arrived();
        let b = spawn_named(scope, "job-b", || owners.run(&second, Some(&cancellation)));
        until("the second Job queued", || {
            owners.lane(&key, &second) == Some(LaneState::Queued) || b.is_finished()
        });
        assert_eq!(owners.lane(&key, &second), Some(LaneState::Queued));
        // The canceller is answered while the first Job still holds the lane.
        let canceller = scope.spawn(|| arkdeck_hoststore::cancel_running(&cancellation));
        until("the waiting Job answered its canceller", || {
            canceller.is_finished()
        });
        assert_eq!(
            canceller.join().unwrap(),
            Some(json!({"cancelRequested": true}))
        );
        let status = b.join().unwrap().unwrap();
        assert_eq!(status["state"], "cancelled", "{status}");
        assert_eq!(owners.lane(&key, &first), Some(LaneState::Active));
        assert_eq!(owners.lane(&key, &second), None);
        assert!(
            owners.calls("job-b").is_empty(),
            "{:?}",
            owners.calls("job-b")
        );
        owners.dispatch.gate.open();
        succeeded(a.join().unwrap());
    });
    let record = owners.jobs.read_snapshot(&second).unwrap();
    let transitions: Vec<&str> = record
        .timeline
        .iter()
        .filter_map(|entry| entry.strip_prefix("reason: "))
        .collect();
    assert_eq!(
        transitions,
        [
            "steps-start",
            "durable client cancellation intent",
            "safe-boundary",
            "steps-drained"
        ],
        "{:?}",
        record.timeline
    );
    assert!(!owners.journal(&second).contains("\"stepIntent\""));
    assert!(owners.uses().iter().all(|(_, job)| *job != second));
    assert!(owners.free(&key));
}

/// Whatever ends a mutation Job — a confirmed failure, an unknown outcome
/// that parks it, a panic in its executor — lets go of its Target's lane.
#[test]
fn the_lane_is_let_go_of_after_a_failure_a_park_and_a_panic() {
    let _lock = debug_hap::exclusive();
    let owners = Owners::open();
    let first_key = owners
        .targets
        .mutation_lane_key(&target(FIRST_KEY))
        .unwrap();
    let other_key = owners
        .targets
        .mutation_lane_key(&target(SECOND_KEY))
        .unwrap();
    let mode = |mode: &str| fs::write(owners.root.join("hdc-mode"), format!("{mode}\n")).unwrap();

    // The fake refuses the gesture: a confirmed failure.
    let rejected = owners.submit(&tap("rejected", FIRST_KEY, 640));
    mode("rejected");
    let status = owners.run(&rejected, None).unwrap();
    assert_eq!(status["state"], "failed", "{status}");
    assert!(owners.free(&first_key));

    // The executor panics inside the gesture: the run unwinds, as the
    // daemon catches it.
    mode("normal");
    let panicked = owners.submit(&tap("panicked", FIRST_KEY, 600));
    let unwound = std::thread::scope(|scope| {
        spawn_named(scope, "panics", || {
            std::panic::catch_unwind(std::panic::AssertUnwindSafe(|| owners.run(&panicked, None)))
                .is_err()
        })
        .join()
        .unwrap()
    });
    assert!(unwound);
    assert!(owners.free(&first_key));

    // The fake answers another gesture than the one sent: an unknown
    // outcome parks the Job.
    let parked = owners.submit(&tap("parked", SECOND_KEY, 640));
    mode("otherGesture");
    let status = owners.run(&parked, None).unwrap();
    assert_eq!(status["state"], "waitingForRecovery", "{status}");
    assert!(owners.free(&other_key));
}
