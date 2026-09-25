//! Swift `RuntimeDebugInvocationController.start` and `.evaluate`, the writes
//! of the protected Flash recovery broker (`debug.start`, `debug.evaluate`),
//! over the same invocation documents its reads answer from.
//!
//! - `start` pins one unprivileged typed request whose plan-only preview is
//!   the Runtime's own and destructive, and opens a four-hour invocation over
//!   it.
//! - `evaluate` takes one effect-level candidate action: observe the pinned
//!   request again (plan-only, dispatch-free), stop, or execute it.
//!
//! This Runtime does not execute a Flash yet. `executePinnedRequest` is
//! therefore refused where Swift would begin its attempt: after every check
//! Swift makes before it writes anything, and before any permit, epoch or
//! evaluation is written. That is a declared difference, never a silent one.
//!
//! Every broker failure is answered `rejected` with Swift's description of
//! it; any other failure `internalError`, a planning refusal with Swift's
//! rendering of the error its planner threw.
use super::*;
use crate::PlanRefusal;
use crate::format_time::{plain_utc_seconds, precise_utc_millis, utc_timestamp};
use arkdeck_contract::sha256_hex;
use std::collections::BTreeSet;

/// Swift `RuntimeDebugInvocationController.maximumDurationSeconds`.
const LIFETIME_SECONDS: u64 = 4 * 60 * 60;
/// Swift `RuntimeDebugCandidateActionCodec`.
const ACTION_SCHEMA_VERSION: &str = "1.0.0";
const MAXIMUM_ACTION_BYTES: usize = 8 * 1_024;
const CLOCK: &str = "Runtime clock is not ISO-8601";

/// What `debug.start` and `debug.evaluate` read beyond the documents.
pub struct InvocationBroker<'a> {
    /// Swift's driver `prepare`: the Runtime's plan-only preview of a request,
    /// as `job.plan` answers it.
    pub plan: &'a dyn Fn(&[u8]) -> Result<Value, PlanRefusal>,
    /// The Runtime clock.
    pub now: &'a dyn Fn() -> Option<String>,
    /// A new invocation's identity, `debug-<lowercase UUID>`.
    pub mint: &'a dyn Fn() -> Option<String>,
}

/// Swift `RuntimeDebugInvocationError`, every case of which the broker's two
/// methods answer `rejected`, with its description and no details.
enum Refusal {
    InvalidSeedRequest(String),
    InvalidCandidate(&'static str),
    InvalidProvenance,
    NotFound(String),
    NotActive(String),
    Expired,
    EpochBudgetExhausted,
    AlreadyRunning,
    PredecessorBlocks(String),
    Persistence(String),
}

impl Refusal {
    fn wire(self) -> WireError {
        let message = match self {
            Self::InvalidSeedRequest(detail) => {
                format!("invalidSeedRequest({})", swift_quoted(&detail))
            }
            Self::InvalidCandidate(case) => {
                format!("invalidCandidate({})", swift_quoted(case))
            }
            Self::InvalidProvenance => format!(
                "invalidProvenance({})",
                swift_quoted("candidate source and build provenance must be lowercase SHA-256")
            ),
            Self::NotFound(identity) => {
                format!("invocationNotFound({})", swift_quoted(&identity))
            }
            Self::NotActive(state) => format!("invocationNotActive({})", swift_quoted(&state)),
            Self::Expired => "invocationExpired".into(),
            Self::EpochBudgetExhausted => "epochBudgetExhausted".into(),
            Self::AlreadyRunning => "evaluationAlreadyRunning".into(),
            Self::PredecessorBlocks(detail) => {
                format!("predecessorBlocksContinuation({})", swift_quoted(&detail))
            }
            Self::Persistence(detail) => format!("persistenceFailure({})", swift_quoted(&detail)),
        };
        WireError {
            code: "rejected".into(),
            message,
            details: None,
        }
    }
}

impl From<ReadError> for Refusal {
    fn from(error: ReadError) -> Self {
        match error {
            ReadError::NotFound(identity) => Self::NotFound(identity),
            ReadError::Persistence(detail) => Self::Persistence(detail.into()),
        }
    }
}

/// Where Swift would begin its attempt, this Runtime refuses: it does not
/// run the pinned Flash, and nothing about the invocation has changed.
fn execution_unavailable() -> WireError {
    WireError {
        code: "rejected".into(),
        message: "executePinnedRequest is not available on the Rust Runtime yet: it runs the \
                  pinned Flash, which this Runtime does not execute; the invocation is unchanged"
            .into(),
        details: None,
    }
}

/// Swift `RuntimeDebugCandidateAction`.
enum Action {
    Observe,
    Execute,
    Stop(String),
}

impl Action {
    fn name(&self) -> &'static str {
        match self {
            Self::Observe => "observePinnedRequest",
            Self::Execute => "executePinnedRequest",
            Self::Stop(_) => "stop",
        }
    }

    /// Swift `canonicalActionData(_:)`.
    fn canonical(&self) -> Vec<u8> {
        let mut object = Map::from_iter([
            ("schemaVersion".to_owned(), json!(ACTION_SCHEMA_VERSION)),
            ("action".to_owned(), json!(self.name())),
        ]);
        if let Self::Stop(reason) = self {
            object.insert("reasonCode".into(), json!(reason));
        }
        crate::session_json::encode(&Value::Object(object))
            .expect("an action document holds only strings")
    }
}

/// Swift `RuntimeDebugCandidateActionCodec.decode(_:)`, each refusal its
/// `RuntimeDebugCandidateActionError` case. Swift reads the document as the
/// `details` of a Session audit record, which must be one non-empty object
/// without a duplicate member, as Foundation decodes it.
fn decode_action(bytes: &[u8]) -> Result<Action, &'static str> {
    if bytes.is_empty() || bytes.len() > MAXIMUM_ACTION_BYTES {
        return Err("invalidDocument");
    }
    let object = match crate::session_json::parse_foundation(bytes) {
        Ok(Value::Object(object)) if !object.is_empty() => object,
        _ => return Err("invalidDocument"),
    };
    if object.get("schemaVersion") != Some(&json!(ACTION_SCHEMA_VERSION)) {
        return Err("unsupportedSchemaVersion");
    }
    let Some(Value::String(action)) = object.get("action") else {
        return Err("unsupportedAction");
    };
    let exactly = |keys: &[&str]| {
        if object.len() == keys.len() && keys.iter().all(|key| object.contains_key(*key)) {
            Ok(())
        } else {
            Err("closedShapeViolation")
        }
    };
    match action.as_str() {
        "observePinnedRequest" => exactly(&["schemaVersion", "action"]).map(|()| Action::Observe),
        "executePinnedRequest" => exactly(&["schemaVersion", "action"]).map(|()| Action::Execute),
        "stop" => {
            exactly(&["schemaVersion", "action", "reasonCode"])?;
            match object.get("reasonCode") {
                Some(Value::String(reason)) if valid_identity(reason) => {
                    Ok(Action::Stop(reason.clone()))
                }
                _ => Err("invalidReasonCode"),
            }
        }
        _ => Err("unsupportedAction"),
    }
}

/// Swift `RuntimeOperationRequestRejection` as Swift prints the value.
fn rejection_description(rejection: &crate::operation_request::RequestRejection) -> String {
    format!(
        "RuntimeOperationRequestRejection(code: ArkDeckCore.RuntimeOperationErrorCode.{}, path: \
         {}, message: {})",
        rejection.code.swift_case(),
        swift_quoted(&rejection.path),
        swift_quoted(&rejection.message)
    )
}

fn lowercase_sha256(value: &str) -> bool {
    value.len() == 64
        && value
            .bytes()
            .all(|byte| byte.is_ascii_digit() || (b'a'..=b'f').contains(&byte))
}

/// Swift `ISO8601Timestamps.parse`, to the second: every instant the broker
/// compares is either the Runtime clock's, whole seconds, or one it wrote.
fn seconds(text: &str) -> Option<u64> {
    plain_utc_seconds(text).or_else(|| precise_utc_millis(text).map(|millis| millis / 1_000))
}

/// The Runtime clock's reading and its second (Swift `currentDate()`).
fn clock(broker: &InvocationBroker<'_>) -> Result<(String, u64), Refusal> {
    let now = (broker.now)().ok_or_else(|| Refusal::Persistence(CLOCK.into()))?;
    let second = seconds(&now).ok_or_else(|| Refusal::Persistence(CLOCK.into()))?;
    Ok((now, second))
}

/// One evaluation of an invocation at a time, as Swift's actor keeps its
/// `activeEvaluations`: released when dropped.
struct Running<'a> {
    active: &'a Mutex<BTreeSet<String>>,
    identity: String,
}

impl Drop for Running<'_> {
    fn drop(&mut self) {
        if let Ok(mut active) = self.active.lock() {
            active.remove(&self.identity);
        }
    }
}

impl FlashInvocations {
    /// `debug.start` and `debug.evaluate` from the frame's parameters,
    /// checked as Swift's handler checks them once its owner is composed.
    pub fn broker(
        &self,
        method: &str,
        params: &Map<String, Value>,
        broker: &InvocationBroker<'_>,
    ) -> Result<Value, WireError> {
        match method {
            "debug.start" => self.start(params, broker),
            "debug.evaluate" => self.evaluate(params, broker),
            _ => Err(internal("not a Flash invocation broker method")),
        }
    }

    /// Swift `start(seedRequestData:)`.
    fn start(
        &self,
        params: &Map<String, Value>,
        broker: &InvocationBroker<'_>,
    ) -> Result<Value, WireError> {
        let Some(Value::String(seed)) = params.get("requestJson").filter(|_| params.len() == 1)
        else {
            return Err(invalid_params("debug.start accepts exactly requestJson"));
        };
        let refused = |detail: &str| Refusal::InvalidSeedRequest(detail.into()).wire();
        let request = OperationRequest::decode(seed.as_bytes())
            .map_err(|rejection| refused(&rejection_description(&rejection)))?;
        if request.capability_id.is_some() || request.client_context.is_some() {
            return Err(refused(
                "debug invocation requires one unprivileged typed request without caller \
                 provenance",
            ));
        }
        let preview = (broker.plan)(seed.as_bytes())
            .map_err(|refusal| internal(&refusal.swift_description()))?;
        if preview["operation"] != json!(request.reference())
            || preview["targetId"] != json!(request.target_id)
            || preview["bindingRevision"] != json!(request.expected_binding_revision)
            || preview["inputs"] != Value::Object(request.inputs.clone())
            || preview["jobAdmitted"] != json!(false)
            || preview["dispatchDisposition"] != json!("notDispatched")
        {
            return Err(refused(
                "Runtime plan-only preview drifted from the pinned seed request",
            ));
        }
        let destructive = preview["steps"]
            .as_array()
            .is_some_and(|steps| steps.iter().any(|step| step["effect"] == "destructive"));
        if !destructive {
            return Err(refused(
                "Runtime debug is the protected destructive-recovery broker; ordinary Agent \
                 debugging is an external agent driving the published job surface",
            ));
        }
        if request.expected_binding_revision.is_none() {
            return Err(refused(
                "destructive recovery requires a binding-pinned target",
            ));
        }
        let Some(baseline) = preview["materializedPlanDigest"]
            .as_str()
            .map(str::to_owned)
        else {
            return Err(refused(
                "Runtime plan-only preview drifted from the pinned seed request",
            ));
        };
        let fingerprint = request.fingerprint();
        let (_, created) = clock(broker).map_err(Refusal::wire)?;
        let identity = (broker.mint)().ok_or_else(|| internal("no invocation identity"))?;
        let document = Document {
            state: "active".into(),
            seed: request,
            fingerprint,
            baseline,
            created: utc_timestamp(created),
            expires: utc_timestamp(created + LIFETIME_SECONDS),
            epochs: 0,
            evaluations: Vec::new(),
        };
        let _serial = self.lock()?;
        self.persist(&identity, &document).map_err(Refusal::wire)?;
        Ok(status(&identity, &document))
    }

    /// Swift `evaluate(invocationID:actionData:provenance:)`, with the
    /// handler's parameter and provenance checks before it.
    fn evaluate(
        &self,
        params: &Map<String, Value>,
        broker: &InvocationBroker<'_>,
    ) -> Result<Value, WireError> {
        let text = |key: &str| params.get(key).and_then(Value::as_str);
        let (4, Some(identity), Some(action), Some(source), Some(build)) = (
            params.len(),
            text("invocationId"),
            text("actionJson"),
            text("sourceSha256"),
            text("buildSha256"),
        ) else {
            return Err(invalid_params(
                "debug.evaluate accepts exactly invocationId, actionJson, sourceSha256 and \
                 buildSha256",
            ));
        };
        if !lowercase_sha256(source) || !lowercase_sha256(build) {
            return Err(Refusal::InvalidProvenance.wire());
        }
        let _running = self
            .running(identity)
            .ok_or_else(|| Refusal::AlreadyRunning.wire())?;
        let mut document = {
            let _serial = self.lock()?;
            self.load(identity)
                .map_err(|error| Refusal::from(error).wire())?
        };
        if document.state != "active" {
            return Err(Refusal::NotActive(document.state).wire());
        }
        let (_, now) = clock(broker).map_err(Refusal::wire)?;
        let expires =
            seconds(&document.expires).ok_or_else(|| Refusal::Persistence(CLOCK.into()).wire())?;
        if now > expires {
            document.state = "expired".into();
            let _serial = self.lock()?;
            self.persist(identity, &document).map_err(Refusal::wire)?;
            return Err(Refusal::Expired.wire());
        }
        let action = decode_action(action.as_bytes())
            .map_err(|case| Refusal::InvalidCandidate(case).wire())?;
        let action_sha256 = sha256_hex(&action.canonical());
        let same_candidate = |evaluation: &Value| {
            evaluation["candidateActionSHA256"] == action_sha256.as_str()
                && evaluation["candidateSourceSHA256"] == source
                && evaluation["candidateBuildSHA256"] == build
        };
        if let Some(interrupted) = document
            .evaluations
            .last()
            .filter(|evaluation| evaluation["disposition"] == "executing")
        {
            if !same_candidate(interrupted)
                || interrupted.get("requestID").is_none()
                || interrupted.get("idempotencyKey").is_none()
            {
                return Err(Refusal::PredecessorBlocks(
                    "an interrupted attempt must resume its exact candidate and provenance".into(),
                )
                .wire());
            }
            // Swift resumes the interrupted attempt here.
            return Err(execution_unavailable());
        }
        let ordinal = document.evaluations.len() + 1;
        let mut evaluation = Map::from_iter([
            ("ordinal".to_owned(), json!(ordinal)),
            ("candidateSourceSHA256".to_owned(), json!(source)),
            ("candidateBuildSHA256".to_owned(), json!(build)),
            ("candidateActionSHA256".to_owned(), json!(action_sha256)),
            ("candidateAction".to_owned(), json!(action.name())),
        ]);
        match &action {
            Action::Stop(reason) => {
                document.state = "stopped".into();
                evaluation.insert("disposition".into(), json!("stopped"));
                evaluation.insert("detail".into(), json!(reason));
            }
            Action::Observe => {
                let seed = document.seed.canonical_bytes();
                let preview = (broker.plan)(&seed)
                    .map_err(|refusal| internal(&refusal.swift_description()))?;
                let mut observation = Map::from_iter([
                    ("observationID".to_owned(), json!("pinnedRequest")),
                    (
                        "materializedPlanDigest".to_owned(),
                        preview["materializedPlanDigest"].clone(),
                    ),
                    ("targetID".to_owned(), preview["targetId"].clone()),
                ]);
                for (key, from) in [
                    ("bindingRevision", "bindingRevision"),
                    ("stableIdentitySHA256", "stableIdentitySha256"),
                ] {
                    if !preview[from].is_null() {
                        observation.insert(key.into(), preview[from].clone());
                    }
                }
                observation.insert(
                    "dispatchDisposition".into(),
                    preview["dispatchDisposition"].clone(),
                );
                evaluation.insert("disposition".into(), json!("observed"));
                evaluation.insert(
                    "detail".into(),
                    json!("fresh Runtime plan-only observation"),
                );
                evaluation.insert("observation".into(), Value::Object(observation));
            }
            Action::Execute => {
                if let Some(predecessor) = document
                    .evaluations
                    .iter()
                    .rev()
                    .find(|evaluation| evaluation.get("destructiveEpoch").is_some())
                {
                    match predecessor.get("outcome").and_then(Value::as_str) {
                        Some("safeToReflash" | "outcomeUnknown") => {}
                        None if predecessor["disposition"] == "executing" => {
                            if !same_candidate(predecessor) {
                                return Err(Refusal::PredecessorBlocks(
                                    "an interrupted attempt must resume its exact candidate".into(),
                                )
                                .wire());
                            }
                        }
                        outcome => {
                            let blocker = outcome.map(str::to_owned).unwrap_or_else(|| {
                                predecessor["disposition"]
                                    .as_str()
                                    .unwrap_or_default()
                                    .to_owned()
                            });
                            return Err(Refusal::PredecessorBlocks(blocker).wire());
                        }
                    }
                }
                if document.epochs >= MAXIMUM_DESTRUCTIVE_EPOCHS {
                    return Err(Refusal::EpochBudgetExhausted.wire());
                }
                // Swift persists the attempt's permit and begins it here.
                return Err(execution_unavailable());
            }
        }
        let (evaluated, _) = clock(broker).map_err(Refusal::wire)?;
        evaluation.insert("evaluatedAtUTC".into(), json!(evaluated));
        document.evaluations.push(Value::Object(evaluation));
        let _serial = self.lock()?;
        self.persist(identity, &document).map_err(Refusal::wire)?;
        Ok(status(identity, &document))
    }

    fn lock(&self) -> Result<std::sync::MutexGuard<'_, ()>, WireError> {
        self.serial
            .lock()
            .map_err(|_| internal("Flash invocation owner is poisoned"))
    }

    fn running(&self, identity: &str) -> Option<Running<'_>> {
        let mut active = self.active.lock().ok()?;
        active.insert(identity.to_owned()).then(|| Running {
            active: &self.active,
            identity: identity.to_owned(),
        })
    }

    /// Swift `persist(_:)`: the document's canonical bytes, atomically
    /// replacing the previous ones in the private invocation directory.
    fn persist(&self, identity: &str, document: &Document) -> Result<(), Refusal> {
        let failed = |error: &dyn std::fmt::Display| {
            Refusal::Persistence(format!(
                "the Flash invocation document could not be written: {error}"
            ))
        };
        let bytes = crate::session_json::encode(&stored(SCHEMA_VERSION, identity, document))
            .map_err(|_| failed(&"it has no canonical encoding"))?;
        let directory = arkdeck_platform::HostDirectory::open(&self.directory)
            .map_err(|error| failed(&error))?;
        directory
            .replace_document(
                &format!("{identity}.json"),
                &bytes,
                MAXIMUM_DOCUMENT_BYTES as usize,
            )
            .map_err(|error| match error {
                arkdeck_platform::DocumentPublishError::BeforePublication(error)
                | arkdeck_platform::DocumentPublishError::OutcomeUnknown(error) => failed(&error),
            })
    }
}
