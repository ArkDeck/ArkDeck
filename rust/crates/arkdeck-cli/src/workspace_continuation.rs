//! `workspace continuation inspect|submit|run` (CLI spec §7.9): Swift
//! `CLIWorkspaceContinuationDraft` and `RuntimeCLI.runWorkspaceContinuation`.
//!
//! A continuation is a fresh typed request rebuilt from an exact terminal
//! source Job, never a replay of it. Every invocation reads the source again
//! and rechecks it against the current Catalog, the Runtime's health and, for
//! a device-bound source, the Target's current binding. It carries no
//! authority, and a new process finds the same Job again through the caller's
//! stable continuation identity. `inspect` only reads. `submit` admits the
//! request idempotently and reads the Job back. `run` also runs that Job once
//! if it is runnable.
//!
//! The Catalog rules are the Runtime's own (`arkdeck_contract::operation_catalog`).
//! The typed request is judged as Swift's `RuntimeOperationRequest` decodes
//! it, which decides only whether the recorded request is readable.
use crate::CliError;
use crate::job_resources::{validate_show, validate_status};
use crate::read_only_resources::{identifier, keys};
use arkdeck_contract::operation_catalog::CatalogOperation;
use arkdeck_contract::{CATALOG_DIGEST, CONTRACT_IDENTITY, METHODS, PROTOCOL_VERSION};
use serde_json::{Map, Value, json};
use std::collections::{BTreeMap, BTreeSet};
use unicode_segmentation::UnicodeSegmentation;

const SCHEMA_VERSION: &str = "arkdeck.workspace-continuation/1";
const CLIENT_NAME: &str = "arkdeck-cli-workspace-continuation";
const CONTINUED_FROM: &str = "arkdeck.continuedFromJob";
const THREAD: &str = "arkdeck.threadId";
const HEALTH_KEYS: [&str; 6] = [
    "status",
    "protocolVersion",
    "contractIdentity",
    "publishedMethods",
    "catalogDigest",
    "providers",
];
const TARGET_KEYS: [&str; 9] = [
    "schemaVersion",
    "targetId",
    "bindingRevision",
    "toolVersion",
    "adoptedAtUtc",
    "connectKey",
    "stablePhysicalIdentitySha256",
    "live",
    "observedFacts",
];
/// Swift `RuntimeWireValidation`: the request's closed members, and the input
/// names that would carry an executable surface. Swift refuses governance and
/// retired authority members by their normalized names before the closed
/// set, only to name them apart; none of them is a member, so for a decode
/// that only passes or fails the closed set decides.
const REQUEST_KEYS: [&str; 11] = [
    "documentType",
    "schemaVersion",
    "requestId",
    "idempotencyKey",
    "target",
    "operation",
    "inputs",
    "requestedOutputs",
    "authorization",
    "clientContext",
    "reviewedPlanDigest",
];
const FORBIDDEN_INPUT_KEYS: [&str; 7] = [
    "argv",
    "shell",
    "exec",
    "command",
    "runhdc",
    "rawcommand",
    "executable",
];
const OUTPUTS: [&str; 4] = [
    "rawArtifacts",
    "derivedArtifacts",
    "analysisReport",
    "hardwareEvidence",
];
/// Swift `RuntimeRequestedOutput`s a continuation asks for.
const CONTINUATION_OUTPUTS: [&str; 3] = ["rawArtifacts", "derivedArtifacts", "hardwareEvidence"];

fn fail(code: &'static str, message: impl Into<String>) -> CliError {
    CliError::new(code, message)
}

/// Swift `SHA256Hex.isLowercaseSHA256`.
fn sha256(value: &Value) -> bool {
    value.as_str().is_some_and(|text| {
        text.len() == 64
            && text
                .bytes()
                .all(|byte| byte.is_ascii_digit() || (b'a'..=b'f').contains(&byte))
    })
}

/// Swift `CLIWorkspaceContinuationDraft.nonnegativeInteger`.
fn nonnegative(value: &Value) -> Option<i64> {
    value.as_i64().filter(|number| *number >= 0)
}

/// Swift `decodeIfPresent(Int.self)`: absent or null is no value, and
/// anything but an integer is a refusal (`None`).
fn optional_integer(value: Option<&Value>) -> Option<Option<i64>> {
    match value {
        None | Some(Value::Null) => Some(None),
        Some(value) => value.as_i64().map(Some),
    }
}

/// A typed request as Swift's `RuntimeOperationRequest` decodes it: `None`
/// where Swift's decoding throws, otherwise the document it encodes back to
/// (`encode(to:)`), which is also what two requests are compared by. Swift
/// keeps no `reviewedPlanDigest`, so the document has none.
fn decode_request(value: &Value) -> Option<Map<String, Value>> {
    let fields = value.as_object()?;
    // `RuntimeWireValidation.requestFields`.
    if fields.get("schemaVersion") != Some(&json!("1.0.0"))
        || fields
            .get("documentType")
            .is_some_and(|kind| kind != "runtime-operation-request")
        || !fields
            .keys()
            .all(|key| REQUEST_KEYS.contains(&key.as_str()))
    {
        return None;
    }
    for (key, allowed) in [
        ("target", &["targetId", "expectedBindingRevision"][..]),
        ("operation", &["id", "version"]),
        ("authorization", &["capabilityId"]),
        ("clientContext", &["clientName", "provenance"]),
    ] {
        if let Some(Value::Object(nested)) = fields.get(key)
            && !nested.keys().all(|name| allowed.contains(&name.as_str()))
        {
            return None;
        }
    }
    if fields
        .get("reviewedPlanDigest")
        .is_some_and(|digest| !sha256(digest))
    {
        return None;
    }
    // The members Swift decodes, with the defaults it fills.
    let text = |key: &str| fields.get(key)?.as_str();
    let request_id = text("requestId")?;
    let idempotency_key = text("idempotencyKey")?;
    let target = fields.get("target")?.as_object()?;
    let target_id = target.get("targetId")?.as_str()?;
    let revision = optional_integer(target.get("expectedBindingRevision"))?;
    let operation = fields.get("operation")?.as_object()?;
    let operation_id = operation.get("id")?.as_str()?;
    let version = optional_integer(operation.get("version"))?;
    let inputs = match fields.get("inputs") {
        None | Some(Value::Null) => Map::new(),
        Some(Value::Object(inputs)) => inputs.clone(),
        Some(_) => return None,
    };
    let outputs: Vec<&str> = match fields.get("requestedOutputs") {
        None | Some(Value::Null) => vec!["derivedArtifacts"],
        Some(Value::Array(items)) => items
            .iter()
            .map(|item| item.as_str().filter(|output| OUTPUTS.contains(output)))
            .collect::<Option<_>>()?,
        Some(_) => return None,
    };
    let capability = match fields.get("authorization") {
        None | Some(Value::Null) => None,
        Some(Value::Object(authorization)) => Some(authorization.get("capabilityId")?.as_str()?),
        Some(_) => return None,
    };
    let context = match fields.get("clientContext") {
        None | Some(Value::Null) => None,
        Some(Value::Object(context)) => {
            let name = match context.get("clientName") {
                None | Some(Value::Null) => None,
                Some(Value::String(name)) => Some(name.as_str()),
                Some(_) => return None,
            };
            let provenance = match context.get("provenance") {
                None | Some(Value::Null) => None,
                Some(Value::Object(entries)) => Some(
                    entries
                        .iter()
                        .map(|(key, value)| Some((key.as_str(), value.as_str()?)))
                        .collect::<Option<BTreeMap<_, _>>>()?,
                ),
                Some(_) => return None,
            };
            Some((name, provenance))
        }
        Some(_) => return None,
    };
    // `RuntimeOperationRequest.validate`.
    let count = |text: &str| text.graphemes(true).count();
    let thread = |thread: &str| {
        let bytes = thread.as_bytes();
        (1..=64).contains(&bytes.len())
            && bytes[0].is_ascii_alphanumeric()
            && bytes
                .iter()
                .all(|byte| byte.is_ascii_alphanumeric() || b"._-".contains(byte))
    };
    let operation_bytes = operation_id.as_bytes();
    let mut unique = outputs.clone();
    unique.sort_unstable();
    unique.dedup();
    let valid = identifier(request_id)
        && count(idempotency_key) >= 8
        && identifier(idempotency_key)
        && identifier(target_id)
        && revision.is_none_or(|revision| revision >= 1)
        && (1..=64).contains(&operation_bytes.len())
        && operation_bytes[0].is_ascii_lowercase()
        && operation_bytes
            .iter()
            .all(|byte| byte.is_ascii_lowercase() || byte.is_ascii_digit() || b".-".contains(byte))
        && version.is_none_or(|version| version >= 1)
        && capability.is_none_or(|capability| {
            // Swift's `hasPrefix` compares characters, not bytes.
            capability
                .graphemes(true)
                .take(7)
                .eq("CAP-RT-".graphemes(true))
                && (8..=128).contains(&count(capability))
        })
        && context.as_ref().is_none_or(|(name, provenance)| {
            name.is_none_or(|name| (1..=128).contains(&count(name)))
                && provenance.as_ref().is_none_or(|entries| {
                    entries.len() <= 16
                        && entries.iter().all(|(key, value)| {
                            (1..=64).contains(&count(key)) && count(value) <= 400
                        })
                        && entries.get(THREAD).is_none_or(|value| thread(value))
                })
        })
        && outputs.len() <= 8
        && unique.len() == outputs.len()
        && inputs.len() <= 64
        && inputs.keys().all(|key| {
            let bytes = key.as_bytes();
            (1..=64).contains(&bytes.len())
                && bytes[0].is_ascii_lowercase()
                && bytes.iter().all(u8::is_ascii_alphanumeric)
                && !FORBIDDEN_INPUT_KEYS.contains(&key.to_ascii_lowercase().as_str())
        });
    if !valid {
        return None;
    }
    let mut target = Map::from_iter([("targetId".to_owned(), json!(target_id))]);
    if let Some(revision) = revision {
        target.insert("expectedBindingRevision".into(), json!(revision));
    }
    let mut operation = Map::from_iter([("id".to_owned(), json!(operation_id))]);
    if let Some(version) = version {
        operation.insert("version".into(), json!(version));
    }
    let mut document = Map::from_iter([
        (
            "documentType".to_owned(),
            json!("runtime-operation-request"),
        ),
        ("schemaVersion".to_owned(), json!("1.0.0")),
        ("requestId".to_owned(), json!(request_id)),
        ("idempotencyKey".to_owned(), json!(idempotency_key)),
        ("target".to_owned(), Value::Object(target)),
        ("operation".to_owned(), Value::Object(operation)),
        ("inputs".to_owned(), Value::Object(inputs)),
        ("requestedOutputs".to_owned(), json!(outputs)),
    ]);
    if let Some(capability) = capability {
        document.insert("authorization".into(), json!({"capabilityId": capability}));
    }
    if let Some((name, provenance)) = context {
        let mut context = Map::new();
        if let Some(name) = name {
            context.insert("clientName".into(), json!(name));
        }
        if let Some(provenance) = provenance {
            context.insert("provenance".into(), json!(provenance));
        }
        document.insert("clientContext".into(), Value::Object(context));
    }
    Some(document)
}

/// `id@version`, or the bare id of an unversioned operation.
fn reference(request: &Map<String, Value>) -> String {
    let operation = &request["operation"];
    let id = operation["id"].as_str().unwrap_or_default();
    match operation["version"].as_i64() {
        Some(version) => format!("{id}@{version}"),
        None => id.to_owned(),
    }
}

/// Swift `RuntimeOperationCatalog.descriptor(reference:)` for a decoded
/// request: the exact published operation, or none.
fn descriptor(request: &Map<String, Value>) -> Option<&'static CatalogOperation> {
    let operation = &request["operation"];
    CatalogOperation::lookup(
        operation["id"].as_str().unwrap_or_default(),
        operation["version"].as_i64(),
    )
}

/// Swift `CLIWorkspaceContinuationDraft.sourceRequiresCurrentTarget`: whether
/// the source's operation binds a device, and so its Target must be read.
/// `prepare` repeats every check; this grants nothing.
pub fn requires_current_target(show: &Value, source_job: &str) -> Result<bool, CliError> {
    validate_show(show, source_job)?;
    let request = decode_request(&show["request"]).ok_or_else(|| {
        fail(
            "recordUnreadable",
            "the source Job request is not a valid typed request",
        )
    })?;
    let operation = descriptor(&request).ok_or_else(|| {
        fail(
            "operationUnavailable",
            "the source operation is absent from the current Catalog",
        )
    })?;
    Ok(operation.binding() == "confirmedDevice")
}

/// Swift `CLIWorkspaceContinuationDraft.validTargetProjectionShape`: the
/// Target projection, with its display name only when both of its members
/// are there and well formed. Swift's name check also compares the name with
/// its precomposed form, but its `==` is canonical equivalence, so that
/// comparison never refuses (the oracle's `displayNameDecomposed`); the rest
/// is `target_resources::display_name`.
fn target_projection(target: &Value) -> bool {
    let Some(fields) = target.as_object() else {
        return false;
    };
    if keys(target, &TARGET_KEYS) {
        return true;
    }
    if fields.len() != TARGET_KEYS.len() + 2
        || !TARGET_KEYS.iter().all(|key| fields.contains_key(*key))
    {
        return false;
    }
    let generation = target["displayNameGeneration"]
        .as_str()
        .is_some_and(|text| {
            text.parse::<u64>().is_ok_and(|number| {
                number > 0 && number <= i64::MAX as u64 && number.to_string() == text
            })
        });
    generation
        && match &target["displayName"] {
            Value::Null => true,
            Value::String(name) => crate::target_resources::display_name(name),
            _ => false,
        }
}

/// The facts a continuation carries forward from its source Job, read again
/// from the Runtime on every invocation.
pub struct Draft {
    source_job: String,
    request: Map<String, Value>,
    catalog_digest: String,
    effect: String,
    binding_revision: Option<i64>,
    stable_identity: Option<String>,
}

impl Draft {
    fn operation(&self) -> String {
        reference(&self.request)
    }

    fn target(&self) -> &str {
        self.request["target"]["targetId"]
            .as_str()
            .unwrap_or_default()
    }

    fn thread(&self) -> Option<&str> {
        self.request
            .get("clientContext")
            .and_then(|context| context["provenance"][THREAD].as_str())
    }

    /// Swift `CLIWorkspaceContinuationDraft.prepare`, in its order and words.
    pub fn prepare(
        source_job: &str,
        show: &Value,
        health: &Value,
        target: Option<&Value>,
    ) -> Result<Self, CliError> {
        if !identifier(source_job) {
            return Err(fail(
                "invalidInput",
                "workspace continuation requires an exact source Job identity",
            ));
        }
        validate_show(show, source_job)?;
        let job = &show["job"];
        let methods = {
            let mut methods = METHODS.to_vec();
            methods.sort_unstable();
            json!(methods)
        };
        let providers = health["providers"].as_array();
        let closed = job.is_object()
            && show["request"].is_object()
            && sha256(&show["catalogDigest"])
            && keys(health, &HEALTH_KEYS)
            && health["status"] == "ok"
            && health["protocolVersion"] == PROTOCOL_VERSION
            && health["contractIdentity"] == CONTRACT_IDENTITY
            && health["publishedMethods"] == methods
            && providers.is_some_and(|providers| {
                providers
                    .iter()
                    .all(|provider| provider.as_str().is_some_and(|name| !name.is_empty()))
                    && providers
                        .iter()
                        .filter_map(Value::as_str)
                        .collect::<BTreeSet<_>>()
                        .len()
                        == providers.len()
            })
            && sha256(&health["catalogDigest"]);
        if !closed {
            return Err(fail(
                "recordUnreadable",
                "the Runtime returned no closed continuation source",
            ));
        }
        let source_digest = show["catalogDigest"].as_str().unwrap_or_default();
        let current_digest = health["catalogDigest"].as_str().unwrap_or_default();
        if source_digest != current_digest || current_digest != CATALOG_DIGEST {
            let mut error = fail(
                "factsDrifted",
                "the source Job, current Runtime and this CLI do not use the same Catalog",
            );
            error.details = Map::from_iter([
                ("sourceCatalogDigest".to_owned(), json!(source_digest)),
                ("runtimeCatalogDigest".to_owned(), json!(current_digest)),
                ("cliCatalogDigest".to_owned(), json!(CATALOG_DIGEST)),
            ]);
            return Err(error);
        }
        if !show["providerId"]
            .as_str()
            .is_some_and(|provider| providers.is_some_and(|all| all.contains(&json!(provider))))
        {
            return Err(fail(
                "operationUnavailable",
                "the source Job provider is not published by the current Runtime",
            ));
        }
        let request = decode_request(&show["request"]).ok_or_else(|| {
            fail(
                "recordUnreadable",
                "the source Job request is not a valid typed request",
            )
        })?;
        if request.contains_key("authorization") {
            return Err(fail(
                "admissionDenied",
                "workspace continuation never copies Runtime authority",
            ));
        }
        if job["jobId"] != source_job
            || job["operation"] != reference(&request)
            || job["targetId"] != request["target"]["targetId"]
        {
            return Err(fail(
                "recordUnreadable",
                "the source Job and typed request identities disagree",
            ));
        }
        if !job["state"]
            .as_str()
            .is_some_and(crate::read_only_resources::terminal_job_state)
        {
            return Err(fail("admissionDenied", "the source Job is not terminal"));
        }
        if job["outcomeUnknown"] != false
            || job["waitingForHuman"] != false
            || nonnegative(&job["outstandingResidueCount"]) != Some(0)
            || !job["supersededByRecoveryEpochId"].is_null()
        {
            return Err(fail(
                "admissionDenied",
                "the source Job has an unknown outcome, human wait, residue or superseding recovery",
            ));
        }
        let operation = descriptor(&request).ok_or_else(|| {
            fail(
                "operationUnavailable",
                "the source operation is absent from the current Catalog",
            )
        })?;
        let inputs = request["inputs"].as_object().expect("decoded inputs");
        if !operation.inputs_match_catalog(inputs) {
            return Err(fail(
                "recordUnreadable",
                "the source typed inputs do not match the current Catalog",
            ));
        }
        let effect = operation.effective_effect(inputs);
        if !matches!(effect.as_str(), "hostOnly" | "readOnly") || job["actualEffect"] != effect {
            return Err(fail(
                "admissionDenied",
                "workspace continuation accepts only a source whose recorded effect is hostOnly or readOnly",
            ));
        }
        if inputs
            .get("markers")
            .and_then(Value::as_array)
            .is_some_and(|markers| !markers.is_empty())
        {
            return Err(fail(
                "admissionDenied",
                "capture markers contain old timestamps and require a newly authored typed request",
            ));
        }
        let requested = request["target"]["expectedBindingRevision"].as_i64();
        let (binding_revision, stable_identity) = if operation.binding() == "confirmedDevice" {
            let identity = show["materializedStableIdentitySha256"]
                .as_str()
                .filter(|_| sha256(&show["materializedStableIdentitySha256"]));
            let current = match (requested, identity, target) {
                (Some(requested), Some(identity), Some(target)) => {
                    requested > 0
                        && nonnegative(&show["materializedBindingRevision"]) == Some(requested)
                        && target_projection(target)
                        && target["schemaVersion"] == "arkdeck.target/1"
                        && target["targetId"] == request["target"]["targetId"]
                        && nonnegative(&target["bindingRevision"]) == Some(requested)
                        && target["stablePhysicalIdentitySha256"] == identity
                }
                _ => false,
            };
            if !current {
                return Err(fail(
                    "bindingRevisionStale",
                    "the source Job target identity or binding revision is no longer current",
                ));
            }
            (requested, identity.map(str::to_owned))
        } else {
            if requested.is_some()
                || !show["materializedBindingRevision"].is_null()
                || !show["materializedStableIdentitySha256"].is_null()
                || target.is_some()
            {
                return Err(fail(
                    "recordUnreadable",
                    "a host-only continuation source carries an unexpected device binding",
                ));
            }
            (None, None)
        };
        Ok(Self {
            source_job: source_job.to_owned(),
            request,
            catalog_digest: current_digest.to_owned(),
            effect,
            binding_revision,
            stable_identity,
        })
    }

    /// Swift `request(continuationRequestID:)`: the fresh typed request, as
    /// the canonical document `job.submit` carries. Its identity is the
    /// caller's; target, operation and inputs are the source's; no authority
    /// is copied.
    pub fn request(&self, continuation: &str) -> Result<Map<String, Value>, CliError> {
        if continuation.len() < 8 || !identifier(continuation) {
            return Err(fail(
                "invalidInput",
                "--continuation-request-id must be 8...128 ASCII [A-Za-z0-9._-] characters",
            ));
        }
        let mut provenance = Map::from_iter([(CONTINUED_FROM.to_owned(), json!(self.source_job))]);
        if let Some(thread) = self.thread() {
            provenance.insert(THREAD.into(), json!(thread));
        }
        Ok(Map::from_iter([
            (
                "documentType".to_owned(),
                json!("runtime-operation-request"),
            ),
            ("schemaVersion".to_owned(), json!("1.0.0")),
            ("requestId".to_owned(), json!(continuation)),
            ("idempotencyKey".to_owned(), json!(continuation)),
            ("target".to_owned(), self.request["target"].clone()),
            ("operation".to_owned(), self.request["operation"].clone()),
            ("inputs".to_owned(), self.request["inputs"].clone()),
            ("requestedOutputs".to_owned(), json!(CONTINUATION_OUTPUTS)),
            (
                "clientContext".to_owned(),
                json!({"clientName": CLIENT_NAME, "provenance": provenance}),
            ),
        ]))
    }

    /// Swift `validateAcceptedJob`: the Job the continuation identity resolves
    /// to, which must hold exactly this fresh request, this binding and this
    /// Catalog's effect. Answers its status.
    pub fn validate_accepted_job(
        &self,
        show: &Value,
        job_id: &str,
        expected: &Map<String, Value>,
    ) -> Result<Value, CliError> {
        if job_id == self.source_job || !identifier(job_id) {
            return Err(fail(
                "recordUnreadable",
                "the continuation did not create a distinct Job identity",
            ));
        }
        validate_show(show, job_id)?;
        let job = &show["job"];
        if show["catalogDigest"] != self.catalog_digest.as_str()
            || !job.is_object()
            || job["jobId"] != job_id
            || job["operation"] != self.operation()
            || job["targetId"] != self.target()
            || job["outcomeUnknown"] != false
            || !job["supersededByRecoveryEpochId"].is_null()
        {
            return Err(fail(
                "recordUnreadable",
                "the accepted continuation Job does not match its source",
            ));
        }
        let recorded = decode_request(&show["request"]).ok_or_else(|| {
            fail(
                "recordUnreadable",
                "the continuation Job request is unreadable",
            )
        })?;
        if recorded != *expected {
            return Err(fail(
                "idempotencyConflict",
                "the continuation identity resolves to a Job with different typed inputs",
            ));
        }
        match self.binding_revision {
            Some(revision) => {
                if nonnegative(&show["materializedBindingRevision"]) != Some(revision)
                    || show["materializedStableIdentitySha256"].as_str()
                        != self.stable_identity.as_deref()
                {
                    return Err(fail(
                        "bindingRevisionStale",
                        "the continuation Job materialized a different device binding",
                    ));
                }
            }
            None => {
                if !show["materializedBindingRevision"].is_null()
                    || !show["materializedStableIdentitySha256"].is_null()
                {
                    return Err(fail(
                        "recordUnreadable",
                        "a host-only continuation gained a device binding",
                    ));
                }
            }
        }
        if !job["actualEffect"].is_null() && job["actualEffect"] != self.effect.as_str() {
            return Err(fail(
                "factsDrifted",
                "the continuation Job effect differs from its current Catalog",
            ));
        }
        Ok(job.clone())
    }

    /// Swift `projection`: what `inspect` answers, and `submit` and `run` with
    /// the Job the continuation identity resolved to.
    pub fn projection(
        &self,
        continuation: Option<&str>,
        job_id: Option<&str>,
        deduplicated: Option<bool>,
        dispatched: bool,
        job: Option<Value>,
    ) -> Value {
        json!({
            "schemaVersion": SCHEMA_VERSION,
            "eligible": true,
            "sourceJobId": self.source_job,
            "operation": self.operation(),
            "targetId": self.target(),
            "bindingRevision": self.binding_revision,
            "catalogDigest": self.catalog_digest,
            "effectiveEffect": self.effect,
            "inputs": self.request["inputs"],
            "threadId": self.thread(),
            "continuationRequestId": continuation,
            "jobId": job_id,
            "deduplicated": deduplicated,
            "dispatched": dispatched,
            "job": job.unwrap_or(Value::Null),
        })
    }
}

/// Parse-time checks for the three leaves, which Swift's registry makes
/// before its handler runs: the source Job, the continuation identity where
/// one is needed and the client deadline, 30 s unless `--timeout` names
/// another bounded one.
pub(super) fn configure(
    command: &str,
    fields: &mut Map<String, Value>,
    help: bool,
) -> Result<Option<u64>, CliError> {
    let Some(verb) = command.strip_prefix("workspace.continuation.") else {
        return Ok(None);
    };
    if help {
        return Ok(None);
    }
    let refused = |message: String| {
        let mut error = CliError::new("invalidOption", message);
        error.command = Some(match verb {
            "inspect" => "workspace.continuation.inspect",
            "submit" => "workspace.continuation.submit",
            _ => "workspace.continuation.run",
        });
        error
    };
    if !fields.contains_key("sourceJob") {
        return Err(refused(format!(
            "`workspace continuation {verb}` requires --source-job <job-id>"
        )));
    }
    if verb != "inspect" && !fields.contains_key("continuationRequestId") {
        return Err(refused(format!(
            "`workspace continuation {verb}` requires --continuation-request-id <id>"
        )));
    }
    let timeout = fields.remove("timeout").unwrap_or(json!("30s"));
    crate::read_only_resources::duration(timeout.as_str().unwrap_or_default())
        .map(Some)
        .ok_or_else(|| refused("timeout must be a bounded duration".into()))
}

/// The `requestJson` text `job.submit` carries, as Swift's
/// `CanonicalJSONEncoders.canonical()` writes the request: keys in order,
/// no slash escaped.
pub fn request_json(request: &Map<String, Value>) -> String {
    serde_json::to_string(request).expect("a JSON request document")
}

/// One Runtime exchange: a method and its parameters, answered or refused.
pub type Exchange<'a> = dyn FnMut(&str, Option<Map<String, Value>>) -> Result<Value, CliError> + 'a;

/// Swift `runWorkspaceContinuation` after its parse: every Runtime exchange,
/// in its order, through `request`, and the one document the leaf emits.
/// `run`'s terminal exit is its Job's, taken from that document once it is out
/// (`job_plan::run_exit`).
pub fn continue_workspace(
    verb: &str,
    fields: &Map<String, Value>,
    request: &mut Exchange<'_>,
) -> Result<Value, CliError> {
    let text = |key: &str| fields.get(key).and_then(Value::as_str);
    let source = text("sourceJob").unwrap_or_default();
    let health = request("health", None)?;
    let show = request(
        "job.show",
        Some(Map::from_iter([("jobId".to_owned(), json!(source))])),
    )?;
    let target = if requires_current_target(&show, source)? {
        let target_id = show["job"]["targetId"]
            .as_str()
            .ok_or_else(|| fail("recordUnreadable", "the source Job target is unreadable"))?;
        Some(request(
            "target.show",
            Some(Map::from_iter([("targetId".to_owned(), json!(target_id))])),
        )?)
    } else {
        None
    };
    let draft = Draft::prepare(source, &show, &health, target.as_ref())?;
    if verb == "inspect" {
        return Ok(draft.projection(None, None, None, false, None));
    }
    let continuation = text("continuationRequestId").unwrap_or_default();
    let fresh = draft.request(continuation)?;
    let accepted = request(
        "job.submit",
        Some(Map::from_iter([(
            "requestJson".to_owned(),
            json!(request_json(&fresh)),
        )])),
    )?;
    crate::job_plan::validate_acceptance(&accepted)?;
    let job_id = accepted["jobId"].as_str().unwrap_or_default();
    let deduplicated = accepted["deduplicated"].as_bool();
    let job = Map::from_iter([("jobId".to_owned(), json!(job_id))]);
    let shown = request("job.show", Some(job.clone()))?;
    let accepted_job = draft.validate_accepted_job(&shown, job_id, &fresh)?;
    if verb != "run" {
        return Ok(draft.projection(
            Some(continuation),
            Some(job_id),
            deduplicated,
            false,
            Some(accepted_job),
        ));
    }
    let state = accepted_job["state"]
        .as_str()
        .filter(|state| crate::read_only_resources::known_job_state(state))
        .ok_or_else(|| {
            fail(
                "recordUnreadable",
                "the continuation Job state is unreadable",
            )
        })?
        .to_owned();
    let mut dispatched = false;
    let mut final_job = accepted_job;
    if matches!(
        state.as_str(),
        "preflight" | "running" | "recoveringByCompleteOverwrite" | "resumeAtConfirmedSafeBoundary"
    ) {
        let status = request("job.run", Some(job.clone()))?;
        // Swift `CLIJobReadValidation.validate` for `status`.
        if !status.is_object() {
            return Err(fail(
                "recordUnreadable",
                "the Runtime returned an invalid Job read projection",
            ));
        }
        validate_status(&status, Some(job_id))?;
        if status["jobId"] != job_id
            || status["operation"] != draft.operation()
            || status["targetId"] != draft.target()
            || status["outcomeUnknown"] != false
        {
            return Err(fail(
                "outcomeUnknown",
                "the continuation run result is unconfirmed; inspect this Job and never replay it",
            ));
        }
        dispatched = true;
        let shown = request("job.show", Some(job))?;
        final_job = draft.validate_accepted_job(&shown, job_id, &fresh)?;
    } else if !crate::read_only_resources::terminal_job_state(&state) {
        return Err(fail(
            "resourceConflict",
            format!(
                "the continuation Job is {state}, not runnable; inspect or resume this exact Job"
            ),
        ));
    }
    Ok(draft.projection(
        Some(continuation),
        Some(job_id),
        deduplicated,
        dispatched,
        Some(final_job),
    ))
}

#[cfg(test)]
mod tests {
    use super::*;

    fn request() -> Value {
        json!({
            "documentType": "runtime-operation-request",
            "schemaVersion": "1.0.0",
            "requestId": "source-request-001",
            "idempotencyKey": "source-request-001",
            "target": {"targetId": "target-continuation", "expectedBindingRevision": 3},
            "operation": {"id": "observe.device", "version": 1},
            "inputs": {},
            "requestedOutputs": ["derivedArtifacts"],
            "clientContext": {
                "clientName": "source-client",
                "provenance": {"arkdeck.threadId": "thread-continuation"},
            },
        })
    }

    #[test]
    fn a_request_decodes_as_swifts_typed_request_does() {
        let decoded = decode_request(&request()).expect("a valid typed request");
        assert_eq!(Value::Object(decoded), request());
        // Swift fills the defaults and keeps no reviewed plan digest.
        let mut sparse = request();
        let fields = sparse.as_object_mut().unwrap();
        fields.remove("documentType");
        fields.remove("inputs");
        fields.remove("requestedOutputs");
        fields.insert("reviewedPlanDigest".into(), json!("a".repeat(64)));
        assert_eq!(Value::Object(decode_request(&sparse).unwrap()), request());
        for (path, value) in [
            ("/schemaVersion", json!("2.0.0")),
            ("/documentType", Value::Null),
            ("/change_ID", json!("x")),
            ("/campaignReservation", json!({})),
            ("/unknown", json!(1)),
            ("/target/unknown", json!(1)),
            ("/target/expectedBindingRevision", json!(0)),
            ("/target/expectedBindingRevision", json!(1.5)),
            ("/idempotencyKey", json!("short-1")),
            ("/requestId", json!("bad id")),
            ("/operation/id", json!("Observe.device")),
            ("/operation/version", json!(0)),
            ("/requestedOutputs", json!(["rawArtifacts", "rawArtifacts"])),
            ("/requestedOutputs", json!(["unknownOutput"])),
            ("/authorization", json!({"capabilityId": "CAP-RT-"})),
            ("/clientContext/clientName", json!("")),
            (
                "/clientContext/provenance/arkdeck.threadId",
                json!("bad thread"),
            ),
            ("/inputs/Upper", json!(true)),
            ("/inputs/argv", json!(true)),
            ("/reviewedPlanDigest", json!("A".repeat(64))),
        ] {
            let mut refused = request();
            let (parent, key) = path.rsplit_once('/').unwrap();
            refused
                .pointer_mut(if parent.is_empty() { "" } else { parent })
                .unwrap()
                .as_object_mut()
                .unwrap()
                .insert(key.to_owned(), value.clone());
            assert!(decode_request(&refused).is_none(), "{path} = {value}");
        }
        let mut with_authority = request();
        with_authority["authorization"] = json!({"capabilityId": "CAP-RT-FIXTURE"});
        assert!(
            decode_request(&with_authority)
                .unwrap()
                .contains_key("authorization")
        );
    }
}
