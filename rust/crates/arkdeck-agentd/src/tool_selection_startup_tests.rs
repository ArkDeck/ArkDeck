use crate::tool_selection_startup::*;
use arkdeck_hoststore::{DurableSelectionOutcome, StartupSelection};
use std::cell::RefCell;
use std::rc::Rc;
struct Registry {
    state: RefCell<(Option<StartupSelection>, DurableSelectionOutcome)>,
    publish: &'static str,
    events: Rc<RefCell<Vec<String>>>,
}
fn selection(tool: &str, pending: bool) -> StartupSelection {
    StartupSelection {
        tool_ref: tool.into(),
        active_generation: 1,
        pending_action_id: pending.then(|| "action".into()),
        executable: format!("/fixture/{tool}").into(),
        executable_sha256: "a".repeat(64),
        dependencies: vec![],
    }
}
impl StartupRegistry for Registry {
    fn acknowledge(&self, _: &str) -> Result<(), String> {
        Ok(())
    }
    fn selection(&self) -> Result<Option<StartupSelection>, String> {
        Ok(self.state.borrow().0.clone())
    }
    fn publish(&self, _: &str) -> Result<(), String> {
        self.events.borrow_mut().push("publish".into());
        if self.publish != "before" {
            *self.state.borrow_mut() = (
                Some(selection("new", false)),
                DurableSelectionOutcome::Succeeded {
                    active_tool_ref: "new".into(),
                    active_generation: 2,
                },
            );
        }
        if self.publish == "ok" {
            Ok(())
        } else {
            Err("publish failed".into())
        }
    }
    fn fail(&self, _: &str, reason: &str) -> Result<(), String> {
        self.events.borrow_mut().push(reason.into());
        if self.publish == "fail" {
            return Err("fixture ledger is unavailable".into());
        }
        *self.state.borrow_mut() = (
            Some(selection("old", false)),
            DurableSelectionOutcome::Failed {
                active_tool_ref: "old".into(),
                active_generation: 1,
                reason_code: reason.into(),
            },
        );
        Ok(())
    }
    fn outcome(&self, _: &str) -> Result<DurableSelectionOutcome, String> {
        Ok(self.state.borrow().1.clone())
    }
}
struct Host {
    tool: String,
    events: Rc<RefCell<Vec<String>>>,
}
impl Drop for Host {
    fn drop(&mut self) {
        self.events.borrow_mut().push(format!("stop:{}", self.tool));
    }
}
fn run(mode: &'static str, fail_start: bool) -> (Vec<String>, String) {
    let events = Rc::new(RefCell::new(vec![]));
    let initial = selection("new", true);
    let registry = Registry {
        state: RefCell::new((Some(initial.clone()), DurableSelectionOutcome::Pending)),
        publish: mode,
        events: events.clone(),
    };
    let (host, result) = start_and_settle(&registry, initial, |s| {
        events.borrow_mut().push(format!("start:{}", s.tool_ref));
        if fail_start && s.tool_ref == "new" {
            return Err("identity verification failed".into());
        }
        Ok(Host {
            tool: s.tool_ref.clone(),
            events: events.clone(),
        })
    })
    .unwrap();
    assert_eq!(host.tool, result.tool_ref);
    let history = events.borrow().clone();
    (history, result.tool_ref)
}
#[test]
fn verified_selected_host_is_published() {
    assert_eq!(
        run("ok", false),
        (vec!["start:new".into(), "publish".into()], "new".into())
    );
}
#[test]
fn startup_failure_settles_and_starts_prior_tool() {
    assert_eq!(
        run("ok", true),
        (
            vec![
                "start:new".into(),
                "tool.selectedStartupVerificationFailed".into(),
                "start:old".into()
            ],
            "old".into()
        )
    );
}
#[test]
fn publish_failure_stops_new_before_restoring_old() {
    assert_eq!(
        run("before", false),
        (
            vec![
                "start:new".into(),
                "publish".into(),
                "stop:new".into(),
                "tool.selectionPublishFailed".into(),
                "start:old".into()
            ],
            "old".into()
        )
    );
}
#[test]
fn ambiguous_publish_reads_success_without_replaying_or_rolling_back() {
    assert_eq!(
        run("after", false),
        (vec!["start:new".into(), "publish".into()], "new".into())
    );
}
#[test]
fn absent_prior_selection_never_invents_a_fallback() {
    let events = Rc::new(RefCell::new(vec![]));
    let registry = Registry {
        state: RefCell::new((None, DurableSelectionOutcome::Absent)),
        publish: "ok",
        events,
    };
    assert!(
        restore::<()>(
            &registry,
            &mut |_| panic!("no fallback launch"),
            "original".into()
        )
        .is_err()
    );
}
#[test]
fn ordinary_start_failure_does_not_write_selection() {
    let events = Rc::new(RefCell::new(vec![]));
    let registry = Registry {
        state: RefCell::new((
            Some(selection("old", false)),
            DurableSelectionOutcome::Absent,
        )),
        publish: "ok",
        events: events.clone(),
    };
    assert!(
        start_and_settle::<()>(&registry, selection("old", false), |_| Err(
            "occupied endpoint".into()
        ))
        .is_err()
    );
    assert!(events.borrow().is_empty());
}

#[test]
fn only_a_durable_launch_can_reach_selected_tool_startup() {
    use arkdeck_hoststore::ToolSelectionRecords;
    use serde_json::Value;
    use std::os::unix::fs::{DirBuilderExt, PermissionsExt};
    use std::path::{Path, PathBuf};
    struct Root(PathBuf);
    impl Drop for Root {
        fn drop(&mut self) {
            let _ = std::fs::remove_dir_all(&self.0);
        }
    }
    for (case, fail) in [
        ("oracle-prepared", false),
        ("oracle-prepared", true),
        ("oracle-launched", false),
    ] {
        let source =
            Path::new(env!("CARGO_MANIFEST_DIR")).join("../../tests/fixtures/tool-selection-store");
        let cases: Value =
            serde_json::from_slice(&std::fs::read(source.join("cases.json")).unwrap()).unwrap();
        let name = cases[case]["file"].as_str().unwrap();
        let bytes = std::fs::read(source.join(name)).unwrap();
        let record: Value = serde_json::from_slice(&bytes).unwrap();
        let root = Root(std::env::temp_dir().canonicalize().unwrap().join(format!(
            "selection-startup-{:032x}",
            u128::from_ne_bytes(arkdeck_platform::random_bytes::<16>().unwrap())
        )));
        std::fs::DirBuilder::new()
            .mode(0o700)
            .create(&root.0)
            .unwrap();
        std::fs::DirBuilder::new()
            .mode(0o700)
            .create(root.0.join("records"))
            .unwrap();
        std::fs::write(root.0.join(name), bytes).unwrap();
        std::fs::set_permissions(root.0.join(name), std::fs::Permissions::from_mode(0o600))
            .unwrap();
        let records = ToolSelectionRecords::open(&root.0.join("records")).unwrap();
        let mut initial = selection(record["intent"]["tool"].as_str().unwrap(), true);
        initial.pending_action_id = Some(record["controlActionId"].as_str().unwrap().into());
        let events = Rc::new(RefCell::new(vec![]));
        let registry = Registry {
            state: RefCell::new((Some(initial.clone()), DurableSelectionOutcome::Pending)),
            publish: if fail { "fail" } else { "ok" },
            events: events.clone(),
        };
        let result = recover_prelaunch(&registry, &records, initial.clone(), 1_800_000_000_000);
        let stored = records
            .load(initial.pending_action_id.as_ref().unwrap())
            .unwrap()
            .unwrap();
        if fail {
            assert!(result.is_err());
            assert_eq!(stored.state(), "dispatchPrepared");
            assert_eq!(stored.value()["dispatchCount"], 0);
        } else if case == "oracle-launched" {
            assert_eq!(result.unwrap(), initial);
            assert!(events.borrow().is_empty());
            assert_eq!(stored.state(), "outcomeUnknown");
        } else {
            assert_eq!(result.unwrap().tool_ref, "old");
            assert_eq!(stored.state(), "failed");
            assert_eq!(stored.value()["dispatchCount"], 0);
            assert_eq!(*events.borrow(), ["tool.lifecycleFailedBeforeLaunch"]);
        }
    }
}
