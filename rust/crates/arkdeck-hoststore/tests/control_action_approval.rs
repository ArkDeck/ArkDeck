//! The combined human-action owner over a control action's impact approval
//! (TASK-XPA-014): Swift's `RuntimeHumanActionResourceCoordinator` lists and
//! shows the approval a restart requested beside the physical assistance
//! agent executions ask for, and the daemon's resume handlers look it up
//! there before the agent execution owner is asked. No request reaches this
//! Runtime from a foreground console, so a resume answers as Swift's daemon
//! answers every other request: `human-action.resume` gets the approval back
//! unchanged, `agent.resume` cannot consume it, and a reference two owners
//! hold is unreadable, each refusal in Swift's order and with its handler's
//! proof. The execution beside the approvals is the physical-assistance
//! oracle's (`rust/tests/fixtures/agent-human-action`): abandoned, its trust
//! action expired, whose identities some approvals here are made to share.
#![cfg(target_os = "macos")]

mod support;

use arkdeck_contract::{WireError, sha256_hex};
use arkdeck_hoststore::{
    AgentExecutionStore, ControlActionResources, HdcControlActions, HumanActionResources, Impact,
    ImpactReading, ImpactSource, OwnerContext,
};
use serde_json::{Map, Value, json};
use std::collections::VecDeque;
use std::fs;
use std::path::PathBuf;
use std::sync::Mutex;
use support::chmod;

/// The oracle's abandoned execution `har-trust`.
const TRUST: &str =
    "execution-9be87d0b82afa6b6f432df5cd89bb755326fea7489acf981de9d32401698e564.json";
/// Its expired trust action, as the oracle's labels `<har-2>` and
/// `<resume-2>` read.
const PHYSICAL_ACTION: &str = "har-00000000-0000-4000-8000-000000000002";
const PHYSICAL_RESUME: &str = "resume-00000000-0000-4000-8000-000000000002";
/// The random identity that makes an approval's `har-` or `resume-` one of
/// those.
const SHARED: &str = "00000000-0000-4000-8000-000000000002";
/// 2026-09-19T00:00:00.000Z.
const NOW: u64 = 1_789_776_000_000;

fn reference() -> String {
    format!("hdc-endpoint:{}", sha256_hex(b"127.0.0.1:8710"))
}

/// A source whose impact a restart may approve: a healthy server of the
/// intent's generation, nothing affected.
struct Ready;

impl ImpactSource for Ready {
    fn endpoint_reference(&self) -> String {
        reference()
    }

    fn read_impact(&self) -> Result<ImpactReading, String> {
        let Value::Object(fields) = json!({
            "serverEndpointRef": reference(), "endpoint": "127.0.0.1:8710",
            "serverOwnership": "unknown", "serverGeneration": "100000023",
            "serverHealth": "healthy", "serverVersion": "3.2.0d",
            "tool": {"reference": null, "executablePath": "/fixture/hdc",
                "source": "runtimeConfiguration", "sha256": "b".repeat(64), "signature": null,
                "version": "3.2.0d", "trust": "unknown"},
            "affectedTargetIds": [], "affectedJobIds": [], "detectedOtherClientIds": [],
            "otherClientsMayExist": true, "affectedDeviceObservations": [],
            "criticalJobGate": {"state": "clear", "blocking": [], "reasonCode": null},
            "interruption": {"kind": "hdcEndpointUnavailable", "affectsAllParticipants": true},
            "recovery": {"kind": "statusThenReconcile", "replayAllowed": false},
        }) else {
            unreachable!("an object literal")
        };
        Ok(ImpactReading {
            impact: Impact::new(fields).map_err(|error| error.message)?,
            relations: Vec::new(),
            blocker: None,
        })
    }
}

/// A private root with the oracle's abandoned execution and the owners'
/// directories, as the isolated daemon makes them.
struct Root(PathBuf);

impl Root {
    fn new(name: &str) -> Self {
        let root = std::env::temp_dir().canonicalize().unwrap().join(format!(
            "control-action-approval-{name}-{:032x}",
            u128::from_ne_bytes(arkdeck_platform::random_bytes::<16>().unwrap())
        ));
        for directory in [
            "",
            "agent-executions",
            "hdc-control-actions",
            "control-action-snapshots",
            "human-action-snapshots",
        ] {
            let path = root.join(directory);
            fs::create_dir_all(&path).unwrap();
            chmod(&path, 0o700);
        }
        let text = fs::read_to_string(
            support::fixture("agent-human-action")
                .join("agent-executions")
                .join(TRUST),
        )
        .unwrap()
        .replace("<har-2>", PHYSICAL_ACTION)
        .replace("<resume-2>", PHYSICAL_RESUME)
        .replace("<obs-1>", "obs-00000000-0000-4000-8000-000000000001");
        let record = root.join("agent-executions").join(TRUST);
        fs::write(&record, text).unwrap();
        chmod(&record, 0o600);
        Self(root)
    }
}

impl Drop for Root {
    fn drop(&mut self) {
        let _ = fs::remove_dir_all(&self.0);
    }
}

/// The owners over a root, the HDC owner drawing `ids` in order.
struct Owners {
    agents: AgentExecutionStore,
    controls: ControlActionResources,
    humans: HumanActionResources,
}

impl Owners {
    fn new(root: &Root, ids: &[&str]) -> Self {
        let ids = Mutex::new(
            ids.iter()
                .map(|id| (*id).to_owned())
                .collect::<VecDeque<_>>(),
        );
        let hdc = HdcControlActions::open(
            &root.0.join("hdc-control-actions"),
            OwnerContext {
                epoch: "epoch".into(),
                catalog: "a".repeat(64),
                clock: Box::new(|| Some(NOW)),
                uuid: Box::new(move || Ok(ids.lock().unwrap().pop_front().expect("an identity"))),
            },
        )
        .unwrap();
        Self {
            agents: AgentExecutionStore::open(&root.0.join("agent-executions")).unwrap(),
            controls: ControlActionResources::open(&root.0.join("control-action-snapshots"))
                .unwrap()
                .with_hdc(hdc),
            humans: HumanActionResources::open(&root.0.join("human-action-snapshots")).unwrap(),
        }
    }

    fn params(value: Value) -> Map<String, Value> {
        value.as_object().unwrap().clone()
    }

    /// A ready preview of `request`, then its restart: the awaiting action.
    fn awaiting(&self, request: &str) -> Value {
        let ready = self
            .controls
            .answer(
                "runtime.hdc.impact-preview",
                &Self::params(json!({"action": "restart", "actionRequestId": request,
                    "serverEndpointRef": reference(), "expectedServerGeneration": "100000023"})),
                Some(&Ready),
            )
            .unwrap();
        assert_eq!(ready["state"], "previewReady");
        let awaiting = self
            .controls
            .answer(
                "runtime.hdc.restart",
                &Self::params(json!({"controlAction": ready["controlActionId"],
                    "previewId": ready["preview"]["previewId"],
                    "previewDigest": ready["preview"]["previewDigest"]})),
                Some(&Ready),
            )
            .unwrap();
        assert_eq!(awaiting["state"], "awaitingImpactApproval");
        awaiting
    }

    fn human(&self, method: &str, params: Value) -> Result<Value, WireError> {
        self.humans.answer(
            method,
            &Self::params(params),
            &self.agents,
            Some(&self.controls),
        )
    }

    fn resume(&self, method: &str, params: Value) -> Option<Result<Value, WireError>> {
        self.humans.resume_control_action(
            method,
            &Self::params(params),
            &self.agents,
            &self.controls,
        )
    }
}

/// The owner-refusal proof the combined human-action handler attaches.
fn proof() -> Map<String, Value> {
    Map::from_iter([
        ("newDispatchCount".into(), json!(0)),
        ("phase".into(), json!("preAdmission")),
    ])
}

fn refused(code: &str, message: &str, details: Map<String, Value>) -> WireError {
    WireError {
        code: code.into(),
        message: message.into(),
        details: Some(details),
    }
}

#[test]
fn an_approval_is_listed_shown_and_answered_to_a_resume_without_advancing() {
    let root = Root::new("answered");
    let owners = Owners::new(&root, &["one", "preview-one", "approval", "resume"]);
    let awaiting = owners.awaiting("request-one");
    let approval = awaiting["humanAction"].clone();
    assert_eq!(approval["actionId"], "har-approval");
    assert_eq!(approval["resumeReference"], "resume-resume");
    let physical = owners
        .human("human-action.show", json!({"humanAction": PHYSICAL_ACTION}))
        .unwrap();
    assert_eq!(physical["owner"]["kind"], "agentExecution");
    assert_eq!(physical["status"], "expired");

    // Shown and listed beside the physical action: newest first, one owner
    // filter at a time.
    assert_eq!(
        owners
            .human("human-action.show", json!({"humanAction": "har-approval"}))
            .unwrap(),
        approval
    );
    for (filters, expected) in [
        (json!({}), vec![approval.clone(), physical.clone()]),
        (
            json!({"ownerKind": "controlAction", "owner": "control-action-one"}),
            vec![approval.clone()],
        ),
        (
            json!({"ownerKind": "agentExecution", "owner": "har-trust"}),
            vec![physical.clone()],
        ),
        (
            json!({"ownerKind": "controlAction", "owner": "har-trust"}),
            Vec::new(),
        ),
        (
            json!({"ownerKind": "agentExecution", "owner": "control-action-one"}),
            Vec::new(),
        ),
    ] {
        let page = owners.human("human-action.list", filters.clone()).unwrap();
        assert_eq!(page["items"], json!(expected), "{filters}");
        assert_eq!(page["order"], "createdAtDescActionIdAsc");
        assert_eq!(page["hasMore"], false);
    }

    // `human-action.resume` gets the approval back, a preseeded challenge
    // response too; a selection is refused.
    let named = json!({"humanAction": "har-approval", "resumeReference": "resume-resume"});
    assert_eq!(
        owners.resume("human-action.resume", named.clone()),
        Some(Ok(approval.clone()))
    );
    let mut preseeded = named.clone();
    preseeded["challengeResponse"] = json!("ARKDECK-028AE8044");
    assert_eq!(
        owners.resume("human-action.resume", preseeded),
        Some(Ok(approval.clone()))
    );
    let mut selected = named.clone();
    selected["selection"] = json!("candidate-1");
    assert_eq!(
        owners.resume("human-action.resume", selected),
        Some(Err(refused(
            "invalidInput",
            "impact approval accepts no selection",
            proof()
        )))
    );
    // `agent.resume` cannot consume it, with or without a selection.
    let mut denied = proof();
    denied.insert("humanAction".into(), approval.clone());
    for params in [
        json!({"resumeReference": "resume-resume"}),
        json!({"resumeReference": "resume-resume", "selection": "candidate-1"}),
    ] {
        assert_eq!(
            owners.resume("agent.resume", params),
            Some(Err(refused(
                "admissionDenied",
                "agent resume cannot consume an impact approval",
                denied.clone()
            )))
        );
    }
    // Anything else is the agent execution owner's: another reference or
    // action, the physical action, fields or identities Swift's handler
    // refuses before its lookup, and other methods.
    for (method, params) in [
        (
            "human-action.resume",
            json!({"humanAction": "har-approval", "resumeReference": PHYSICAL_RESUME}),
        ),
        (
            "human-action.resume",
            json!({"humanAction": "har-other", "resumeReference": "resume-resume"}),
        ),
        (
            "human-action.resume",
            json!({"humanAction": PHYSICAL_ACTION, "resumeReference": PHYSICAL_RESUME}),
        ),
        ("agent.resume", json!({"resumeReference": PHYSICAL_RESUME})),
        (
            "human-action.resume",
            json!({"humanAction": "har-approval", "resumeReference": "resume-resume", "x": 1}),
        ),
        (
            "human-action.resume",
            json!({"resumeReference": "resume-resume"}),
        ),
        (
            "human-action.resume",
            json!({"humanAction": "har approval", "resumeReference": "resume-resume"}),
        ),
        (
            "agent.resume",
            json!({"resumeReference": "resume-resume", "humanAction": "har-approval"}),
        ),
        ("agent.resume", json!({"resumeReference": "resume:resume"})),
        ("human-action.show", json!({"humanAction": "har-approval"})),
    ] {
        assert_eq!(
            owners.resume(method, params.clone()),
            None,
            "{method} {params}"
        );
    }
    // Nothing advanced the action or its approval.
    assert_eq!(
        owners
            .controls
            .answer(
                "control-action.show",
                &Owners::params(json!({"controlAction": "control-action-one"})),
                Some(&Ready),
            )
            .unwrap(),
        awaiting
    );
}

#[test]
fn a_reference_two_owners_hold_is_refused_as_each_handler_refuses_it() {
    // The approval's resume reference is the physical action's.
    let root = Root::new("reference");
    let owners = Owners::new(&root, &["two", "preview-two", "approval-two", SHARED]);
    let approval = owners.awaiting("request-two")["humanAction"].clone();
    assert_eq!(approval["resumeReference"], PHYSICAL_RESUME);
    // `agent.resume` names only the reference: the execution handler's
    // refusal, which proves nothing for an unreadable owner.
    assert_eq!(
        owners.resume("agent.resume", json!({"resumeReference": PHYSICAL_RESUME})),
        Some(Err(refused(
            "recordUnreadable",
            "human action reference has multiple owners",
            Map::new()
        )))
    );
    // `human-action.resume` names the action too, which only one holds.
    assert_eq!(
        owners.resume(
            "human-action.resume",
            json!({"humanAction": "har-approval-two", "resumeReference": PHYSICAL_RESUME}),
        ),
        Some(Ok(approval))
    );
    drop(owners);
    drop(root);

    // Both identities are the physical action's.
    let root = Root::new("identity");
    let owners = Owners::new(&root, &["three", "preview-three", SHARED, SHARED]);
    owners.awaiting("request-three");
    assert_eq!(
        owners.resume(
            "human-action.resume",
            json!({"humanAction": PHYSICAL_ACTION, "resumeReference": PHYSICAL_RESUME}),
        ),
        Some(Err(refused(
            "recordUnreadable",
            "human action reference has multiple owners",
            proof()
        )))
    );
    assert_eq!(
        owners.human("human-action.show", json!({"humanAction": PHYSICAL_ACTION})),
        Err(refused(
            "recordUnreadable",
            "human action has multiple owners",
            proof()
        ))
    );
    assert_eq!(
        owners.human("human-action.list", json!({})),
        Err(refused(
            "recordUnreadable",
            "human action identity has multiple owners",
            proof()
        ))
    );
}
