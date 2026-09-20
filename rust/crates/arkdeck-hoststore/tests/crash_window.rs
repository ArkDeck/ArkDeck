//! Replays the Swift crash-window oracle (`rust/tests/fixtures/crash-window`,
//! recorded by `CrashWindowOracleContractTests`) with the Rust runner killed
//! at the same four windows: the quadrants of "before or after an intent" and
//! "before or after the capability consume" XPA-AC-7 names.
//!
//! For each window a child of this test binary rebuilds the root, admits the
//! oracle's `input.tap@1` and runs it until the window, where it exits
//! without unwinding (`std::process::exit`), so nothing past the last
//! durable write happens:
//! - `beforeConsume`: at the tool identity check that opens the consume, once
//!   the last evidence step's outcome is durable;
//! - `afterReadOnlyIntent`: as `read-evidence-model` would launch the tool,
//!   its intent durable;
//! - `afterConsume`: at the first clock read once the Job record holds its
//!   `runtimeCapability` evidence (the intent's envelope);
//! - `afterIntent`: as `inject-pointer-input` would launch the injector, its
//!   intent durable.
//!
//! The parent then does what the Swift oracle did after its daemon died:
//! the store the run left must be Swift's (`crash/`), the daemon starts
//! twice (`recover_active_jobs`), the Job is reconciled twice, a new tap is
//! submitted, and the Job and capabilities are read. Every answer and every
//! store snapshot must be Swift's byte for byte, once each Job record's
//! volume, device, inode and claim generation are read as labels, and
//! neither a start nor a reconcile adds a call to the fake.
//!
//! Where Swift's fake took the copy while answering the call (the two
//! windows after an intent), its log holds that call and the Rust log does
//! not: the Rust runner died before launching the tool. The store is the
//! same either way; the logs differ by exactly that line.
//!
//! Because the Swift crash store and the Rust one are the same bytes, the
//! Rust starts over it are also the Rust daemon starting over the store a
//! Swift daemon died with. The runs spawn the fake, so this binary is theirs.
#![cfg(target_os = "macos")]

mod support;

use arkdeck_provider_hdc::{DispatchFailure, HdcDispatch, ProcessPlan, Receipt};
use serde_json::{Map, Value, json};
use std::fs;
use std::path::PathBuf;
use std::sync::OnceLock;
use support::debug_hap;
use support::reconcile::Daemon;

const WINDOWS: [(&str, i32); 4] = [
    ("beforeConsume", 81),
    ("afterReadOnlyIntent", 82),
    ("afterConsume", 83),
    ("afterIntent", 84),
];
const CHILD: &str = "ARKDECK_CRASH_WINDOW_CHILD";

fn exit_code(window: &str) -> i32 {
    WINDOWS.iter().find(|(name, _)| *name == window).unwrap().1
}

fn exchange<'a>(cases: &'a Value, name: &str) -> &'a Value {
    cases["exchanges"]
        .as_array()
        .unwrap()
        .iter()
        .find(|exchange| exchange["name"] == name)
        .unwrap()
}

/// The fake's dispatcher, which dies where the window names.
struct Dying<'a> {
    inner: &'a (dyn HdcDispatch + Sync),
    window: &'static str,
    journal: PathBuf,
}

impl HdcDispatch for Dying<'_> {
    fn mutation_identity_current(&self) -> bool {
        // The consume path opens with this check, after every evidence
        // step's outcome is durable and before anything is consumed.
        if self.window == "beforeConsume"
            && fs::read_to_string(&self.journal)
                .is_ok_and(|journal| journal.contains("\"outcome-read-evidence-firmware\""))
        {
            std::process::exit(exit_code(self.window));
        }
        self.inner.mutation_identity_current()
    }

    fn dispatch(&self, plan: &ProcessPlan) -> Result<Receipt, DispatchFailure> {
        let launches = |argument: &str| plan.arguments.iter().any(|a| a == argument);
        if (self.window == "afterReadOnlyIntent" && launches("const.product.name"))
            || (self.window == "afterIntent" && launches("uinput"))
        {
            std::process::exit(exit_code(self.window));
        }
        self.inner.dispatch(plan)
    }
}

/// The Job record the `afterConsume` clock watches.
static EVIDENCE: OnceLock<PathBuf> = OnceLock::new();

/// The oracle's clock, until the Job record on disk holds the consumed
/// capability's evidence: the next read is where `afterConsume` dies.
fn dying_clock() -> Option<String> {
    if let Some(record) = EVIDENCE.get()
        && fs::read_to_string(record).is_ok_and(|text| text.contains("\"runtimeCapability\""))
    {
        std::process::exit(exit_code("afterConsume"));
    }
    support::fixed_now()
}

/// The Rust daemon's run of the oracle's tap, dying at the window the
/// environment names. Run only as the child of the test below.
#[test]
fn crash_window_child() {
    let Ok(window) = std::env::var(CHILD) else {
        return;
    };
    let window = WINDOWS.iter().find(|(name, _)| *name == window).unwrap().0;
    let daemon = Daemon::open(&format!("crash-window/{window}"));
    let cases = support::document(&daemon.fixture, "cases.json");
    let job = cases["job"]["jobId"].as_str().unwrap();
    let submit = exchange(&cases, "tap.submit");
    assert_eq!(
        daemon.answer(&daemon.dispatch, submit),
        submit["answer"],
        "{window}: tap.submit"
    );
    let jobs = daemon.default_root.join("jobs").join(job);
    let dying = Dying {
        inner: &daemon.dispatch,
        window,
        journal: jobs.join("journal.jsonl"),
    };
    let now: fn() -> Option<String> = if window == "afterConsume" {
        EVIDENCE.set(jobs.join("job-record.json")).unwrap();
        dying_clock
    } else {
        support::fixed_now
    };
    let params = Map::from_iter([("jobId".into(), json!(job))]);
    let ran = daemon.run_on(&dying, &params, None, now);
    panic!("{window}: the run ended without reaching its window: {ran}");
}

/// The one leftover Swift's store does not share where no Session was
/// published. The Rust admission's storage-state check
/// (`MutationAuthority::require_state`, through the Session owner's
/// `runtime.storage.status`) takes the storage owner's lock and the retention
/// catalog's, which leaves both lock files and an empty catalog; Swift's
/// admission reads the Session root without them and writes them only when
/// it first publishes. They must be the bytes Swift writes then (as its
/// failed publication of `afterReadOnlyIntent` wrote them), and they are
/// removed before the tree is compared, so nothing else is excused.
fn excuse_admission_session_files(daemon: &Daemon, window: &str) {
    let files = [
        ("session-owner/.session-storage.lock", "session-owner"),
        ("sessions/.arkdeck-retention-catalog.json", "Sessions"),
        ("sessions/.arkdeck-retention-catalog.lock", "Sessions"),
    ];
    let tree = support::document(&daemon.fixture, "tree.json");
    let recorded = |path: &str| {
        tree.as_array()
            .unwrap()
            .iter()
            .any(|entry| entry["path"] == path)
    };
    if files.iter().all(|(path, _)| recorded(path)) {
        return;
    }
    assert!(
        files.iter().all(|(path, _)| !recorded(path)),
        "{window}: Swift left only some of the Session owner's files"
    );
    let swift = support::fixture("crash-window/afterReadOnlyIntent");
    for (path, directory) in files {
        let name = path.rsplit('/').next().unwrap();
        let actual = daemon.root.join(directory).join(name);
        assert_eq!(
            fs::read(&actual).unwrap(),
            fs::read(swift.join(path)).unwrap(),
            "{window}: {path}"
        );
        fs::remove_file(actual).unwrap();
    }
}

#[test]
fn rust_dies_at_each_crash_window_and_recovers_as_swift_does() {
    let _lock = debug_hap::exclusive();
    let mut differences = Vec::new();
    for (window, code) in WINDOWS {
        let output = std::process::Command::new(std::env::current_exe().unwrap())
            .args(["--exact", "crash_window_child", "--nocapture"])
            .env(CHILD, window)
            .output()
            .unwrap();
        assert_eq!(
            output.status.code(),
            Some(code),
            "{window}: {}{}",
            String::from_utf8_lossy(&output.stdout),
            String::from_utf8_lossy(&output.stderr)
        );
        let mut daemon = Daemon::attach(&format!("crash-window/{window}"));
        let cases = support::document(&daemon.fixture, "cases.json");

        // The store the dead run left is the one Swift's daemon left.
        daemon.assert_snapshot("crash");
        let at_death = daemon.calls();
        let swift = fs::read_to_string(daemon.fixture.join("hdc-invocations.log")).unwrap();
        assert_eq!(
            swift.len() as u64,
            cases["invocationsAtCrash"].as_u64().unwrap(),
            "{window}"
        );
        let answered = swift.strip_prefix(at_death.as_str()).unwrap_or_else(|| {
            panic!("{window}: the Rust calls are not Swift's first calls:\n{at_death}\n{swift}")
        });
        match window {
            "afterReadOnlyIntent" => assert!(answered.contains("const.product.name"), "{window}"),
            "afterIntent" => assert!(answered.contains("uinput"), "{window}"),
            _ => assert!(answered.is_empty(), "{window}: {answered}"),
        }

        // The daemon starts again over that root, and then once more.
        for start in cases["starts"].as_array().unwrap() {
            let recovered = daemon.restart();
            assert!(recovered.quarantined.is_empty() && recovered.refused.is_empty());
            assert_eq!(
                json!(recovered.statuses),
                start["recovered"],
                "{window}: {}",
                start["name"]
            );
            daemon.assert_snapshot(start["name"].as_str().unwrap());
        }
        assert_eq!(daemon.calls(), at_death, "{window}: a start dispatched");

        // Every request after the death, each reconcile followed by its store.
        for exchange in cases["exchanges"].as_array().unwrap() {
            if exchange["name"] == "tap.submit" {
                continue;
            }
            let actual = daemon.answer(&daemon.dispatch, exchange);
            if actual != exchange["answer"] {
                differences.push(format!(
                    "{window} {}:\n  swift {}\n  rust  {actual}",
                    exchange["name"], exchange["answer"]
                ));
            }
            if exchange["method"] == "job.reconcile" {
                daemon.assert_snapshot(&format!("steps/{}", exchange["name"].as_str().unwrap()));
            }
        }
        assert_eq!(
            daemon.calls(),
            at_death,
            "{window}: a reconcile or read dispatched"
        );
        assert!(differences.is_empty(), "{}", differences.join("\n"));

        // What the replay leaves: the Target document and the Job store,
        // capability store, Sessions, storage owner and tree, byte for byte.
        daemon.close();
        excuse_admission_session_files(&daemon, window);
        assert_eq!(
            fs::read(daemon.root.join("targets-state/targets.json")).unwrap(),
            fs::read(daemon.fixture.join("targets-state/targets.json")).unwrap(),
            "{window}: the Target document"
        );
        support::assert_leftovers_at(&daemon.fixture, &daemon.root, &daemon.default_root);
    }
    assert!(differences.is_empty(), "{}", differences.join("\n"));
}
