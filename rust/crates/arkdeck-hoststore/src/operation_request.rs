//! The current strict Runtime operation request, decoded as Swift
//! `RuntimeOperationCodec.decodeRequest` decodes `RuntimeOperationRequest`:
//! exact format identity, closed member sets, governance and retired-authority
//! refusals, then the typed fields and their bounds, in Swift's order.
//! `canonical_bytes` is Swift `CanonicalJSONEncoders.canonical()` of the typed
//! request, so its SHA-256 is the request fingerprint admission records.
use crate::job_repository::identifier;
use crate::session_graphemes::graphemes;
use crate::session_json;
use serde_json::{Map, Value, json};
use std::collections::BTreeMap;

pub const MAXIMUM_REQUEST_BYTES: usize = 1 << 20;
const DOCUMENT_TYPE: &str = "runtime-operation-request";
const SCHEMA_VERSION: &str = "1.0.0";
const FORBIDDEN_INPUT_KEYS: [&str; 7] = [
    "argv",
    "shell",
    "exec",
    "command",
    "runhdc",
    "rawcommand",
    "executable",
];
const FORBIDDEN_GOVERNANCE_KEYS: [&str; 9] = [
    "changeid",
    "taskid",
    "approvalprnumber",
    "maincommitoid",
    "authorizationbloboid",
    "prnumber",
    "pullrequestnumber",
    "sourcetaskid",
    "sourcechangeid",
];
const RETIRED_AUTHORITY_KEYS: [&str; 4] = [
    "standingauthorization",
    "evolutioncampaignconfirmation",
    "chatconfirmation",
    "campaignreservation",
];
const REQUESTED_OUTPUTS: [&str; 4] = [
    "rawArtifacts",
    "derivedArtifacts",
    "analysisReport",
    "hardwareEvidence",
];
const THREAD_PROVENANCE_KEY: &str = "arkdeck.threadId";

/// Swift `RuntimeOperationErrorCode`.
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub enum RequestErrorCode {
    InvalidRequest,
    UnknownOperation,
    InvalidInput,
    TargetNotFound,
    AuthorizationRequired,
    Conflict,
    UnsupportedProfile,
    UnsupportedVersion,
    GovernanceFieldRejected,
    RequestTooLarge,
    DeviceBusyBySession,
}

impl RequestErrorCode {
    /// The control-plane code Swift's Job lifecycle handler maps it to.
    pub fn wire_code(self) -> &'static str {
        match self {
            Self::InvalidRequest | Self::InvalidInput | Self::GovernanceFieldRejected => {
                "invalidInput"
            }
            Self::RequestTooLarge => "inputTooLarge",
            Self::UnknownOperation | Self::UnsupportedProfile | Self::UnsupportedVersion => {
                "operationUnavailable"
            }
            Self::TargetNotFound => "resourceNotFound",
            Self::AuthorizationRequired => "admissionDenied",
            Self::Conflict | Self::DeviceBusyBySession => "resourceConflict",
        }
    }
}

/// Swift `RuntimeOperationRequestRejection`.
#[derive(Clone, Debug, PartialEq, Eq)]
pub struct RequestRejection {
    pub code: RequestErrorCode,
    pub path: String,
    pub message: String,
}

fn reject(
    code: RequestErrorCode,
    path: impl Into<String>,
    message: impl Into<String>,
) -> RequestRejection {
    RequestRejection {
        code,
        path: path.into(),
        message: message.into(),
    }
}

const DICTIONARY: &str = "Dictionary<String, Any>";

/// A member Swift's typed decoder cannot read escapes as a `DecodingError`,
/// which the codec reports at `$` in Swift's own description of that error.
fn undecodable(description: String) -> RequestRejection {
    reject(
        RequestErrorCode::InvalidRequest,
        "$",
        format!("undecodable current request: DecodingError.{description}"),
    )
}

/// Foundation `JSONDecoder`'s name for the JSON value it met.
fn found(value: &Value) -> &'static str {
    match value {
        Value::Array(_) => "an array",
        Value::Object(_) => "a dictionary",
        Value::String(_) => "a string",
        Value::Number(_) => "number",
        Value::Bool(_) => "bool",
        Value::Null => "null",
    }
}

/// The coding path a nested `DecodingError` description names.
fn at(path: &str) -> String {
    if path.is_empty() {
        String::new()
    } else {
        format!(" Path: {path}.")
    }
}

fn type_mismatch(expected: &str, path: &str, value: &Value) -> RequestRejection {
    undecodable(format!(
        "typeMismatch: expected value of type {expected}.{} Debug description: Expected to decode {expected} but found {} instead.",
        at(path),
        found(value)
    ))
}

fn value_not_found(expected: &str, path: &str) -> RequestRejection {
    undecodable(format!(
        "valueNotFound: Expected value of type {expected} but found null instead.{} Debug description: Cannot get value of type {expected} -- found null value instead",
        at(path)
    ))
}

/// Swift `RuntimeClientContext`.
#[derive(Clone, Debug, PartialEq, Eq)]
pub struct ClientContext {
    pub client_name: Option<String>,
    pub provenance: Option<BTreeMap<String, String>>,
}

/// Swift `RuntimeOperationRequest`. `inputs` keep Foundation `JSONValue`
/// semantics, so re-encoding them reproduces Swift's canonical bytes.
#[derive(Clone, Debug, PartialEq)]
pub struct OperationRequest {
    pub request_id: String,
    pub idempotency_key: String,
    pub target_id: String,
    pub expected_binding_revision: Option<i64>,
    pub operation_id: String,
    pub operation_version: Option<i64>,
    pub inputs: Map<String, Value>,
    pub requested_outputs: Vec<String>,
    pub capability_id: Option<String>,
    pub client_context: Option<ClientContext>,
    /// The caller's reviewed plan precondition. It is no member of the typed
    /// request, so it never reaches the canonical bytes or the fingerprint.
    pub reviewed_plan_digest: Option<String>,
}

fn sorted_keys(fields: &Map<String, Value>) -> Vec<&String> {
    let mut keys: Vec<&String> = fields.keys().collect();
    keys.sort();
    keys
}

fn closed(
    fields: &Map<String, Value>,
    allowed: &[&str],
    path: &str,
) -> Result<(), RequestRejection> {
    match sorted_keys(fields)
        .into_iter()
        .find(|key| !allowed.contains(&key.as_str()))
    {
        Some(key) => Err(reject(
            RequestErrorCode::InvalidRequest,
            format!("{path}.{key}"),
            "unknown field in the current Runtime contract",
        )),
        None => Ok(()),
    }
}

fn lowercase_sha256(value: &str) -> bool {
    value.len() == 64
        && value
            .bytes()
            .all(|byte| byte.is_ascii_digit() || (b'a'..=b'f').contains(&byte))
}

/// Swift `RuntimeWireValidation.requestFields`.
fn request_fields(fields: &Map<String, Value>) -> Result<(), RequestRejection> {
    for key in sorted_keys(fields) {
        let normalized = key.to_lowercase().replace('_', "");
        if FORBIDDEN_GOVERNANCE_KEYS.contains(&normalized.as_str()) {
            return Err(reject(
                RequestErrorCode::GovernanceFieldRejected,
                format!("$.{key}"),
                "repository governance fields are not runtime fields; use PublishedOperationBundleManifest for build provenance",
            ));
        }
        if RETIRED_AUTHORITY_KEYS.contains(&normalized.as_str()) {
            return Err(reject(
                RequestErrorCode::AuthorizationRequired,
                format!("$.{key}"),
                "retired authority fields cannot enter the current Runtime contract",
            ));
        }
    }
    if fields.get("schemaVersion") != Some(&json!(SCHEMA_VERSION)) {
        return Err(reject(
            RequestErrorCode::UnsupportedVersion,
            "$.schemaVersion",
            format!("schemaVersion must be exactly \"{SCHEMA_VERSION}\""),
        ));
    }
    if fields
        .get("documentType")
        .is_some_and(|value| value != DOCUMENT_TYPE)
    {
        return Err(reject(
            RequestErrorCode::InvalidRequest,
            "$.documentType",
            format!("expected {DOCUMENT_TYPE}"),
        ));
    }
    closed(
        fields,
        &[
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
        ],
        "$",
    )?;
    for (key, allowed) in [
        ("target", &["targetId", "expectedBindingRevision"][..]),
        ("operation", &["id", "version"][..]),
        ("authorization", &["capabilityId"][..]),
        ("clientContext", &["clientName", "provenance"][..]),
    ] {
        if let Some(Value::Object(nested)) = fields.get(key) {
            closed(nested, allowed, &format!("$.{key}"))?;
        }
    }
    if let Some(value) = fields.get("reviewedPlanDigest")
        && !value.as_str().is_some_and(lowercase_sha256)
    {
        return Err(reject(
            RequestErrorCode::InvalidRequest,
            "$.reviewedPlanDigest",
            "reviewedPlanDigest must be a lowercase SHA-256 precondition",
        ));
    }
    Ok(())
}

/// Swift `required(...)`: absent or null is required; any other failure to
/// read the member is malformed.
fn required<'a>(
    fields: &'a Map<String, Value>,
    key: &str,
    path: &str,
    shape: &str,
) -> Result<&'a Value, RequestRejection> {
    match fields.get(key) {
        None | Some(Value::Null) => Err(reject(
            RequestErrorCode::InvalidRequest,
            path,
            format!("{path} is required ({shape})"),
        )),
        Some(value) => Ok(value),
    }
}

fn malformed(path: &str, shape: &str) -> RequestRejection {
    reject(
        RequestErrorCode::InvalidRequest,
        path,
        format!("{path} is malformed ({shape})"),
    )
}

/// A Swift `Int` member: an exact integral number within Int64.
fn optional_int(value: Option<&Value>) -> Result<Option<i64>, ()> {
    match value {
        None | Some(Value::Null) => Ok(None),
        Some(value) => value.as_i64().map(Some).ok_or(()),
    }
}

fn required_string(
    fields: &Map<String, Value>,
    key: &str,
    path: &str,
    shape: &str,
) -> Result<String, RequestRejection> {
    required(fields, key, path, shape)?
        .as_str()
        .map(str::to_owned)
        .ok_or_else(|| malformed(path, shape))
}

impl OperationRequest {
    pub fn decode(bytes: &[u8]) -> Result<Self, RequestRejection> {
        if bytes.len() > MAXIMUM_REQUEST_BYTES {
            return Err(reject(
                RequestErrorCode::RequestTooLarge,
                "$",
                format!("request exceeds {MAXIMUM_REQUEST_BYTES} bytes"),
            ));
        }
        let value = session_json::parse_foundation(bytes).map_err(|_| {
            reject(
                RequestErrorCode::InvalidRequest,
                "$",
                "malformed or duplicate-key JSON",
            )
        })?;
        let fields = match value {
            Value::Object(fields) => fields,
            Value::Null => {
                return Err(undecodable(format!(
                    "valueNotFound: Expected value of type {DICTIONARY} but found null instead. Debug description: Cannot get keyed decoding container -- found null value instead"
                )));
            }
            other => return Err(type_mismatch(DICTIONARY, "", &other)),
        };
        request_fields(&fields)?;
        let request_id =
            required_string(&fields, "requestId", "$.requestId", "an identifier string")?;
        let idempotency_key = required_string(
            &fields,
            "idempotencyKey",
            "$.idempotencyKey",
            "an identifier string of at least 8 characters",
        )?;
        let target_shape = "an object carrying targetId";
        let target = required(&fields, "target", "$.target", target_shape)?
            .as_object()
            .ok_or_else(|| malformed("$.target", target_shape))?;
        let target_id = target
            .get("targetId")
            .and_then(Value::as_str)
            .ok_or_else(|| malformed("$.target", target_shape))?
            .to_owned();
        let expected_binding_revision = optional_int(target.get("expectedBindingRevision"))
            .map_err(|()| malformed("$.target", target_shape))?;
        let operation_shape = "an object carrying id and an optional version";
        let operation = required(&fields, "operation", "$.operation", operation_shape)?
            .as_object()
            .ok_or_else(|| malformed("$.operation", operation_shape))?;
        let operation_id = operation
            .get("id")
            .and_then(Value::as_str)
            .ok_or_else(|| malformed("$.operation", operation_shape))?
            .to_owned();
        let operation_version = optional_int(operation.get("version"))
            .map_err(|()| malformed("$.operation", operation_shape))?;
        let inputs = match fields.get("inputs") {
            None | Some(Value::Null) => Map::new(),
            Some(Value::Object(inputs)) => inputs.clone(),
            Some(other) => return Err(type_mismatch(DICTIONARY, "inputs", other)),
        };
        let requested_outputs = match fields.get("requestedOutputs") {
            None | Some(Value::Null) => vec!["derivedArtifacts".to_owned()],
            Some(Value::Array(items)) => items
                .iter()
                .enumerate()
                .map(|(index, item)| {
                    let path = format!("requestedOutputs[{index}]");
                    match item {
                        Value::String(value) if REQUESTED_OUTPUTS.contains(&value.as_str()) => {
                            Ok(value.clone())
                        }
                        Value::String(value) => Err(undecodable(format!(
                            "dataCorrupted: Data was corrupted. Path: {path}. Debug description: Cannot initialize RuntimeRequestedOutput from invalid String value {value}"
                        ))),
                        Value::Null => Err(value_not_found("String", &path)),
                        other => Err(type_mismatch("String", &path, other)),
                    }
                })
                .collect::<Result<_, _>>()?,
            Some(other) => return Err(type_mismatch("Array<Any>", "requestedOutputs", other)),
        };
        let capability_id = match fields.get("authorization") {
            None | Some(Value::Null) => None,
            Some(Value::Object(authorization)) => Some(match authorization.get("capabilityId") {
                Some(Value::String(capability)) => capability.clone(),
                None => {
                    return Err(undecodable(
                        "keyNotFound: Key 'capabilityId' not found in keyed decoding container. Path: authorization. Debug description: No value associated with key CodingKeys(stringValue: \"capabilityId\", intValue: nil) (\"capabilityId\").".into(),
                    ));
                }
                Some(Value::Null) => {
                    return Err(value_not_found("String", "authorization.capabilityId"));
                }
                Some(other) => {
                    return Err(type_mismatch("String", "authorization.capabilityId", other));
                }
            }),
            Some(other) => return Err(type_mismatch(DICTIONARY, "authorization", other)),
        };
        let client_context = match fields.get("clientContext") {
            None | Some(Value::Null) => None,
            Some(Value::Object(context)) => {
                let client_name = match context.get("clientName") {
                    None | Some(Value::Null) => None,
                    Some(Value::String(name)) => Some(name.clone()),
                    Some(other) => {
                        return Err(type_mismatch("String", "clientContext.clientName", other));
                    }
                };
                let provenance = match context.get("provenance") {
                    None | Some(Value::Null) => None,
                    Some(Value::Object(entries)) => Some(
                        entries
                            .iter()
                            .map(|(key, value)| {
                                let path = format!("clientContext.provenance.{key}");
                                match value {
                                    Value::String(text) => Ok((key.clone(), text.clone())),
                                    Value::Null => Err(value_not_found("String", &path)),
                                    other => Err(type_mismatch("String", &path, other)),
                                }
                            })
                            .collect::<Result<_, _>>()?,
                    ),
                    Some(other) => {
                        return Err(type_mismatch(DICTIONARY, "clientContext.provenance", other));
                    }
                };
                Some(ClientContext {
                    client_name,
                    provenance,
                })
            }
            Some(other) => return Err(type_mismatch(DICTIONARY, "clientContext", other)),
        };
        let request = Self {
            request_id,
            idempotency_key,
            target_id,
            expected_binding_revision,
            operation_id,
            operation_version,
            inputs,
            requested_outputs,
            capability_id,
            client_context,
            reviewed_plan_digest: fields
                .get("reviewedPlanDigest")
                .and_then(Value::as_str)
                .map(str::to_owned),
        };
        request.validate()?;
        Ok(request)
    }

    /// Swift `RuntimeOperationRequest.validate`.
    fn validate(&self) -> Result<(), RequestRejection> {
        let identifier_rejection = |path: &str| {
            reject(
                RequestErrorCode::InvalidRequest,
                path,
                "identifier must be 1..128 ASCII [A-Za-z0-9._-] starting alphanumeric",
            )
        };
        if !identifier(&self.request_id) {
            return Err(identifier_rejection("$.requestId"));
        }
        if graphemes(&self.idempotency_key).count() < 8 {
            return Err(reject(
                RequestErrorCode::InvalidRequest,
                "$.idempotencyKey",
                "idempotency key must be at least 8 characters",
            ));
        }
        if !identifier(&self.idempotency_key) {
            return Err(identifier_rejection("$.idempotencyKey"));
        }
        if !identifier(&self.target_id) {
            return Err(identifier_rejection("$.target.targetId"));
        }
        if self
            .expected_binding_revision
            .is_some_and(|revision| revision < 1)
        {
            return Err(reject(
                RequestErrorCode::InvalidRequest,
                "$.target.expectedBindingRevision",
                "binding revision must be >= 1",
            ));
        }
        let operation = self.operation_id.as_bytes();
        if operation.is_empty()
            || operation.len() > 64
            || !operation[0].is_ascii_lowercase()
            || !operation.iter().all(|byte| {
                byte.is_ascii_lowercase() || byte.is_ascii_digit() || b".-".contains(byte)
            })
        {
            return Err(reject(
                RequestErrorCode::UnknownOperation,
                "$.operation.id",
                "malformed operation id",
            ));
        }
        if self.operation_version.is_some_and(|version| version < 1) {
            return Err(reject(
                RequestErrorCode::UnknownOperation,
                "$.operation.version",
                "operation version must be >= 1",
            ));
        }
        if let Some(capability) = &self.capability_id {
            let count = graphemes(capability).take(129).count();
            if !capability.starts_with("CAP-RT-") || count <= 7 || count > 128 {
                return Err(reject(
                    RequestErrorCode::AuthorizationRequired,
                    "$.authorization.capabilityId",
                    "authorization must reference a runtime capability (CAP-RT-...)",
                ));
            }
        }
        if let Some(context) = &self.client_context {
            if context
                .client_name
                .as_ref()
                .is_some_and(|name| name.is_empty() || graphemes(name).take(129).count() > 128)
            {
                return Err(reject(
                    RequestErrorCode::InvalidRequest,
                    "$.clientContext.clientName",
                    "client name must be 1..128 characters",
                ));
            }
            if let Some(provenance) = &context.provenance {
                if provenance.len() > 16 {
                    return Err(reject(
                        RequestErrorCode::InvalidRequest,
                        "$.clientContext.provenance",
                        "at most 16 provenance entries",
                    ));
                }
                for (key, value) in provenance {
                    if key.is_empty()
                        || graphemes(key).take(65).count() > 64
                        || graphemes(value).take(401).count() > 400
                    {
                        return Err(reject(
                            RequestErrorCode::InvalidRequest,
                            format!("$.clientContext.provenance.{key}"),
                            "malformed provenance entry",
                        ));
                    }
                }
                if let Some(thread) = provenance.get(THREAD_PROVENANCE_KEY) {
                    let bytes = thread.as_bytes();
                    if bytes.is_empty()
                        || bytes.len() > 64
                        || !bytes[0].is_ascii_alphanumeric()
                        || !bytes
                            .iter()
                            .all(|byte| byte.is_ascii_alphanumeric() || b"._-".contains(byte))
                    {
                        return Err(reject(
                            RequestErrorCode::InvalidRequest,
                            format!("$.clientContext.provenance.{THREAD_PROVENANCE_KEY}"),
                            "thread id must be 1..64 characters of [A-Za-z0-9._-]",
                        ));
                    }
                }
            }
        }
        let mut outputs = self.requested_outputs.clone();
        outputs.sort();
        outputs.dedup();
        if self.requested_outputs.len() > 8 || outputs.len() != self.requested_outputs.len() {
            return Err(reject(
                RequestErrorCode::InvalidRequest,
                "$.requestedOutputs",
                "requested outputs must be unique, at most 8",
            ));
        }
        if self.inputs.len() > 64 {
            return Err(reject(
                RequestErrorCode::InvalidInput,
                "$.inputs",
                "at most 64 typed inputs",
            ));
        }
        for key in sorted_keys(&self.inputs) {
            let bytes = key.as_bytes();
            if bytes.is_empty()
                || bytes.len() > 64
                || !bytes[0].is_ascii_lowercase()
                || !bytes.iter().all(u8::is_ascii_alphanumeric)
            {
                return Err(reject(
                    RequestErrorCode::InvalidInput,
                    format!("$.inputs.{key}"),
                    "input keys must be lowerCamelCase ASCII",
                ));
            }
            if FORBIDDEN_INPUT_KEYS.contains(&key.to_ascii_lowercase().as_str()) {
                return Err(reject(
                    RequestErrorCode::InvalidInput,
                    format!("$.inputs.{key}"),
                    "input key would carry an executable surface",
                ));
            }
        }
        Ok(())
    }

    /// `id@version`, or the bare id of an unversioned operation.
    pub fn reference(&self) -> String {
        match self.operation_version {
            Some(version) => format!("{}@{version}", self.operation_id),
            None => self.operation_id.clone(),
        }
    }

    /// The typed request as Swift encodes it: nil optionals are omitted.
    pub fn canonical_value(&self) -> Value {
        let mut target = Map::new();
        target.insert("targetId".into(), json!(self.target_id));
        if let Some(revision) = self.expected_binding_revision {
            target.insert("expectedBindingRevision".into(), json!(revision));
        }
        let mut operation = Map::new();
        operation.insert("id".into(), json!(self.operation_id));
        if let Some(version) = self.operation_version {
            operation.insert("version".into(), json!(version));
        }
        let mut object = Map::new();
        object.insert("documentType".into(), json!(DOCUMENT_TYPE));
        object.insert("schemaVersion".into(), json!(SCHEMA_VERSION));
        object.insert("requestId".into(), json!(self.request_id));
        object.insert("idempotencyKey".into(), json!(self.idempotency_key));
        object.insert("target".into(), Value::Object(target));
        object.insert("operation".into(), Value::Object(operation));
        object.insert("inputs".into(), Value::Object(self.inputs.clone()));
        object.insert("requestedOutputs".into(), json!(self.requested_outputs));
        if let Some(capability) = &self.capability_id {
            object.insert("authorization".into(), json!({"capabilityId": capability}));
        }
        if let Some(context) = &self.client_context {
            let mut fields = Map::new();
            if let Some(name) = &context.client_name {
                fields.insert("clientName".into(), json!(name));
            }
            if let Some(provenance) = &context.provenance {
                fields.insert("provenance".into(), json!(provenance));
            }
            object.insert("clientContext".into(), Value::Object(fields));
        }
        Value::Object(object)
    }

    /// Swift `CanonicalJSONEncoders.canonical()` of the typed request.
    pub fn canonical_bytes(&self) -> Vec<u8> {
        session_json::encode(&self.canonical_value())
            .expect("a decoded request holds only finite Foundation values")
    }

    /// The request fingerprint: SHA-256 of the canonical typed request.
    pub fn fingerprint(&self) -> String {
        arkdeck_contract::sha256_hex(&self.canonical_bytes())
    }
}
