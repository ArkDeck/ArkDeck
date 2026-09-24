//! `runtime service verify --job`: Swift `RuntimeHeadlessVerifier.
//! verifyPersistedJob`, the read-only closure proof for one completed,
//! profiled Runtime Job. It joins only daemon-owned status, evidence and
//! immutable Artifact metadata (`health`, `job.status`, `job.evidence`,
//! `artifact.list`); it never submits, runs, cancels or reconciles a Job, so it
//! proves persistence after a restart without causing device work.
//!
//! Every document here is encoded as Swift's `JSONEncoder` encodes the typed
//! value it decoded: members it does not model are dropped and an absent
//! optional is omitted, never `null`.
use crate::job_resources::date_seconds;
use serde_json::{Map, Value, json};
use std::collections::BTreeSet;
use std::time::{Duration, Instant};

const REOPEN_SCHEMA: &str = "arkdeck-headless-runtime-reopen/v1";
const OBSERVE: &str = "observe.device@1";
const OBSERVE_ARTIFACTS: [&str; 3] = [
    "binding-snapshot.json",
    "device-facts.json",
    "tool-facts.json",
];
const OBSERVE_STEPS: [&str; 4] = [
    "probeDevice",
    "probeHDCServer",
    "probeHostTool",
    "runApprovedRemoteRead",
];
const FLASH_REFERENCES: [&str; 2] = ["flash.full-restore@1", "flash.dayu200"];
const FLASH_REQUIRED_ARTIFACTS: [&str; 2] = ["flash-report.json", "post-flash-facts.json"];
const FLASH_OPTIONAL_ARTIFACT: &str = "post-flash-hilog.txt";
const FLASH_STEPS: [&str; 5] = [
    "flashPartition",
    "verifyRemoteState",
    "rebootDevice",
    "waitForReconnect",
    "probeDevice",
];
const EFFECTS: [&str; 4] = ["hostOnly", "readOnly", "deviceMutation", "destructive"];
const AUTHORITY_KINDS: [&str; 4] = [
    "defaultReadOnlyPolicy",
    "runtimeCapability",
    "standingAuthorization",
    "evolutionCampaignConfirmation",
];
const TRANSPORTS: [&str; 3] = ["usb", "tcp", "uart"];

/// The answer of one reopen: the report, and the reason when it failed.
#[derive(Clone, Debug, PartialEq)]
pub enum ReopenOutcome {
    Verified(Value),
    Failed { reason: String, report: Value },
}

/// Swift `validSHA256`.
fn sha256(value: &str) -> bool {
    value.len() == 64
        && value
            .bytes()
            .all(|byte| matches!(byte, b'0'..=b'9' | b'a'..=b'f'))
}

/// Swift `validIdentifier`: 1–160 ASCII letters, digits, `.`, `_` or `-`.
fn safe_identifier(value: &str) -> bool {
    !value.is_empty()
        && value.len() <= 160
        && value
            .bytes()
            .all(|byte| byte.is_ascii_alphanumeric() || b"._-".contains(&byte))
}

fn parse_date(value: Option<&str>) -> Option<f64> {
    date_seconds(&json!(value?))
}

/// One `Decodable` object read as Swift's `JSONDecoder` reads it, re-encoded
/// as its `JSONEncoder` writes it.
struct Decoded<'a> {
    fields: &'a Map<String, Value>,
    out: Map<String, Value>,
    path: &'a str,
}

impl<'a> Decoded<'a> {
    fn new(value: &'a Value, path: &'a str) -> Result<Self, String> {
        Ok(Self {
            fields: value
                .as_object()
                .ok_or_else(|| format!("{path} is not an object"))?,
            out: Map::new(),
            path,
        })
    }

    fn missing(&self, key: &str) -> String {
        format!("{}.{key} is missing or has the wrong type", self.path)
    }

    /// A present, non-null member, or `None` when it is absent or null.
    fn present(&self, key: &str) -> Option<&'a Value> {
        self.fields.get(key).filter(|value| !value.is_null())
    }

    fn string(&mut self, key: &str) -> Result<String, String> {
        let value = self
            .present(key)
            .and_then(Value::as_str)
            .ok_or_else(|| self.missing(key))?
            .to_owned();
        self.out.insert(key.into(), json!(value));
        Ok(value)
    }

    fn optional_string(&mut self, key: &str) -> Result<Option<String>, String> {
        match self.present(key) {
            None => Ok(None),
            Some(value) => {
                let value = value.as_str().ok_or_else(|| self.missing(key))?.to_owned();
                self.out.insert(key.into(), json!(value));
                Ok(Some(value))
            }
        }
    }

    fn closed(&mut self, key: &str, allowed: &[&str]) -> Result<String, String> {
        let value = self.string(key)?;
        if allowed.contains(&value.as_str()) {
            Ok(value)
        } else {
            Err(format!("{}.{key} is not a known value", self.path))
        }
    }

    fn optional_closed(&mut self, key: &str, allowed: &[&str]) -> Result<Option<String>, String> {
        match self.optional_string(key)? {
            Some(value) if !allowed.contains(&value.as_str()) => {
                Err(format!("{}.{key} is not a known value", self.path))
            }
            other => Ok(other),
        }
    }

    fn integer(&mut self, key: &str) -> Result<i64, String> {
        let value = self
            .present(key)
            .and_then(Value::as_i64)
            .ok_or_else(|| self.missing(key))?;
        self.out.insert(key.into(), json!(value));
        Ok(value)
    }

    fn optional_integer(&mut self, key: &str) -> Result<Option<i64>, String> {
        match self.present(key) {
            None => Ok(None),
            Some(value) => {
                let value = value.as_i64().ok_or_else(|| self.missing(key))?;
                self.out.insert(key.into(), json!(value));
                Ok(Some(value))
            }
        }
    }

    fn boolean(&mut self, key: &str) -> Result<bool, String> {
        let value = self
            .present(key)
            .and_then(Value::as_bool)
            .ok_or_else(|| self.missing(key))?;
        self.out.insert(key.into(), json!(value));
        Ok(value)
    }

    fn strings(&mut self, key: &str) -> Result<Vec<String>, String> {
        let value = self.present(key).ok_or_else(|| self.missing(key))?;
        let items = strings(value).ok_or_else(|| self.missing(key))?;
        self.out.insert(key.into(), json!(items));
        Ok(items)
    }

    fn optional_strings(&mut self, key: &str) -> Result<Option<Vec<String>>, String> {
        match self.present(key) {
            None => Ok(None),
            Some(value) => {
                let items = strings(value).ok_or_else(|| self.missing(key))?;
                self.out.insert(key.into(), json!(items));
                Ok(Some(items))
            }
        }
    }

    /// A nested object when present, decoded by `decode` and re-encoded in
    /// its place.
    fn optional_object<T>(
        &mut self,
        key: &str,
        decode: impl FnOnce(&Value, &str) -> Result<(T, Value), String>,
    ) -> Result<Option<T>, String> {
        match self.present(key) {
            None => Ok(None),
            Some(value) => {
                let path = format!("{}.{key}", self.path);
                let (typed, encoded) = decode(value, &path)?;
                self.out.insert(key.into(), encoded);
                Ok(Some(typed))
            }
        }
    }

    fn array<T>(
        &mut self,
        key: &str,
        mut decode: impl FnMut(&Value, &str) -> Result<(T, Value), String>,
    ) -> Result<Vec<T>, String> {
        let items = self
            .present(key)
            .and_then(Value::as_array)
            .ok_or_else(|| self.missing(key))?;
        let (mut typed, mut encoded) = (Vec::new(), Vec::new());
        for (index, item) in items.iter().enumerate() {
            let (one, value) = decode(item, &format!("{}.{key}[{index}]", self.path))?;
            typed.push(one);
            encoded.push(value);
        }
        self.out.insert(key.into(), Value::Array(encoded));
        Ok(typed)
    }

    fn finish(self) -> Value {
        Value::Object(self.out)
    }
}

fn strings(value: &Value) -> Option<Vec<String>> {
    value
        .as_array()?
        .iter()
        .map(|item| item.as_str().map(str::to_owned))
        .collect()
}

/// Swift `RuntimeHardwareEvidenceAuthority`.
#[derive(Clone, Debug, Default)]
struct Authority {
    kind: String,
    reference: String,
    admitted_at: String,
    valid_until: Option<String>,
    consumption_fingerprint: Option<String>,
    reservation_id: Option<String>,
    use_ordinal: Option<i64>,
    step_set_digest: Option<String>,
    artifact_digest: Option<String>,
    plan_digest: Option<String>,
    target_binding_digest: Option<String>,
}

fn recovery_epoch(value: &Value, path: &str) -> Result<((), Value), String> {
    let mut epoch = Decoded::new(value, path)?;
    epoch.string("epochId")?;
    epoch.string("source")?;
    epoch.string("stableTargetIdentitySha256")?;
    epoch.integer("bindingRevision")?;
    epoch.array("coveredIntents", |item, path| {
        let mut intent = Decoded::new(item, path)?;
        intent.string("jobId")?;
        intent.string("intentEventId")?;
        intent.string("operationReference")?;
        intent.string("profileReference")?;
        intent.string("observedAtUtc")?;
        intent.strings("possibleEffects")?;
        Ok(((), intent.finish()))
    })?;
    for key in [
        "uncertainEffectSetSha256",
        "coverageContractVersion",
        "coveredEffectSetSha256",
        "recoveryJobId",
        "recoveryIntentEventId",
        "operationReference",
        "profileReference",
        "materializedPlanDigestSha256",
        "artifactSha256",
        "providerExecutableSha256",
    ] {
        epoch.string(key)?;
    }
    epoch.strings("confirmedStepIds")?;
    epoch.string("resultingTargetEpochSha256")?;
    epoch.string("establishedAtUtc")?;
    epoch.string("epochSha256")?;
    Ok(((), epoch.finish()))
}

fn authority(value: &Value, path: &str) -> Result<(Authority, Value), String> {
    let mut fields = Decoded::new(value, path)?;
    let authority = Authority {
        kind: fields.closed("kind", &AUTHORITY_KINDS)?,
        reference: fields.string("reference")?,
        admitted_at: fields.string("admittedAtUtc")?,
        valid_until: fields.optional_string("validUntilUtc")?,
        consumption_fingerprint: fields.optional_string("consumptionFingerprintSha256")?,
        reservation_id: fields.optional_string("reservationId")?,
        use_ordinal: fields.optional_integer("useOrdinal")?,
        step_set_digest: fields.optional_string("stepSetDigest")?,
        artifact_digest: fields.optional_string("artifactDigest")?,
        plan_digest: fields.optional_string("planDigest")?,
        target_binding_digest: fields.optional_string("targetBindingDigest")?,
    };
    fields.optional_object("recoveryEpoch", recovery_epoch)?;
    Ok((authority, fields.finish()))
}

/// Swift `RuntimeHardwareEvidenceObservation`.
#[derive(Clone, Debug, Default)]
struct Observation {
    target_id: Option<String>,
    binding_revision: Option<i64>,
    stable_identity: Option<String>,
    model: Option<String>,
    firmware: Option<String>,
    transport: Option<String>,
    provider_id: String,
    tool_version: String,
    tool_sha256: String,
    confirmed_at: Option<String>,
    confirmation_method: String,
}

fn observation(value: &Value, path: &str) -> Result<(Observation, Value), String> {
    let mut fields = Decoded::new(value, path)?;
    let observation = Observation {
        target_id: fields.optional_string("targetId")?,
        binding_revision: fields.optional_integer("bindingRevision")?,
        stable_identity: fields.optional_string("stableIdentitySha256")?,
        model: fields.optional_string("model")?,
        firmware: fields.optional_string("firmware")?,
        transport: fields.optional_closed("transport", &TRANSPORTS)?,
        provider_id: fields.string("providerId")?,
        tool_version: fields.string("toolVersion")?,
        tool_sha256: fields.string("toolSha256")?,
        confirmed_at: fields.optional_string("confirmedAtUtc")?,
        confirmation_method: fields.string("confirmationMethod")?,
    };
    fields.array("preflightSteps", |item, path| {
        let mut step = Decoded::new(item, path)?;
        step.string("stepId")?;
        step.string("stepKind")?;
        step.string("outcomeAtUtc")?;
        Ok(((), step.finish()))
    })?;
    Ok((observation, fields.finish()))
}

/// Swift `RuntimeHardwareEvidenceArtifact`.
#[derive(Clone, Debug)]
struct EvidenceArtifact {
    reference: String,
    sha256: String,
    job_id: String,
    target_id: String,
    binding_revision: Option<i64>,
    stable_identity: Option<String>,
    provider_id: String,
    byte_count: i64,
    bytes_verified: bool,
}

fn evidence_artifact(value: &Value, path: &str) -> Result<(EvidenceArtifact, Value), String> {
    let mut fields = Decoded::new(value, path)?;
    let artifact = EvidenceArtifact {
        reference: fields.string("reference")?,
        sha256: fields.string("sha256")?,
        job_id: fields.string("jobId")?,
        target_id: fields.string("targetId")?,
        binding_revision: fields.optional_integer("bindingRevision")?,
        stable_identity: fields.optional_string("stableIdentitySha256")?,
        provider_id: fields.string("providerId")?,
        byte_count: fields.integer("byteCount")?,
        bytes_verified: fields.boolean("bytesVerified")?,
    };
    Ok((artifact, fields.finish()))
}

/// Swift `RuntimeHardwareEvidenceTrustedFacts`.
#[derive(Clone, Debug)]
struct TrustedFacts {
    job_id: String,
    operation_reference: String,
    catalog_digest: String,
    target_id: String,
    binding_revision: Option<i64>,
    provider_id: String,
    actual_effect: Option<String>,
    authority: Option<Authority>,
    observation: Option<Observation>,
    actual_step_kinds: Option<Vec<String>>,
    execution_mode: String,
    terminal_state: String,
    outcome_unknown: bool,
    started_at: Option<String>,
    first_evidence_step_at: Option<String>,
    finished_at: Option<String>,
    artifacts: Vec<EvidenceArtifact>,
    blockers: Vec<String>,
    encoded: Value,
}

/// Swift `CurrentRuntimeResourceReads.evidence`: the current evidence
/// resource, its Artifact counts converted from their canonical decimal
/// strings, decoded as the trusted facts.
fn trusted_facts(value: &Value) -> Result<TrustedFacts, String> {
    let undecodable = |detail: String| {
        format!("job.evidence contains undecodable trusted Runtime facts: {detail}")
    };
    let mut value = value.clone();
    if value["schemaVersion"] != "arkdeck.job-evidence/1" || !value["artifacts"].is_array() {
        return Err(undecodable(
            "Job evidence is not the current resource".into(),
        ));
    }
    for artifact in value["artifacts"].as_array_mut().into_iter().flatten() {
        let count = artifact
            .get("byteCount")
            .and_then(Value::as_str)
            .and_then(|text| {
                text.parse::<i64>()
                    .ok()
                    .filter(|count| *count >= 0 && count.to_string() == text)
            })
            .ok_or_else(|| undecodable("Evidence Artifact count is not canonical".into()))?;
        artifact
            .as_object_mut()
            .ok_or_else(|| undecodable("Evidence Artifact count is not canonical".into()))?
            .insert("byteCount".into(), json!(count));
    }
    let mut fields = Decoded::new(&value, "evidence").map_err(undecodable)?;
    let mut decode = || -> Result<TrustedFacts, String> {
        Ok(TrustedFacts {
            job_id: fields.string("jobId")?,
            operation_reference: fields.string("operationReference")?,
            catalog_digest: fields.string("catalogDigest")?,
            target_id: fields.string("targetId")?,
            binding_revision: fields.optional_integer("bindingRevision")?,
            provider_id: fields.string("providerId")?,
            actual_effect: fields.optional_closed("actualEffect", &EFFECTS)?,
            authority: fields.optional_object("authority", authority)?,
            observation: fields.optional_object("observation", observation)?,
            actual_step_kinds: fields.optional_strings("actualStepKinds")?,
            execution_mode: fields.string("executionMode")?,
            terminal_state: fields.string("terminalState")?,
            outcome_unknown: fields.boolean("outcomeUnknown")?,
            started_at: fields.optional_string("startedAtUtc")?,
            first_evidence_step_at: fields.optional_string("firstEvidenceStepAtUtc")?,
            finished_at: fields.optional_string("finishedAtUtc")?,
            artifacts: {
                fields.optional_object("recoveryEpoch", recovery_epoch)?;
                fields.array("artifacts", evidence_artifact)?
            },
            blockers: fields.strings("blockers")?,
            encoded: Value::Null,
        })
    };
    let mut facts = decode().map_err(undecodable)?;
    facts.encoded = fields.finish();
    Ok(facts)
}

/// Swift `RuntimeHeadlessPersistedJobStatus`, read from `job.status`.
#[derive(Clone, Debug)]
struct PersistedStatus {
    job_id: String,
    operation_reference: String,
    target_id: String,
    state: String,
    waiting_for_human: bool,
    outcome_unknown: bool,
    outstanding_residue_count: i64,
    execution_mode: Option<String>,
    actual_effect: Option<String>,
    started_at: Option<String>,
    finished_at: Option<String>,
}

impl PersistedStatus {
    fn read(value: &Value) -> Result<Self, String> {
        let text = |key: &str| value.get(key).and_then(Value::as_str).map(str::to_owned);
        let incomplete = || "job.status contains incomplete persisted Runtime facts".to_owned();
        Ok(Self {
            job_id: text("jobId").ok_or_else(incomplete)?,
            operation_reference: text("operation").ok_or_else(incomplete)?,
            target_id: text("targetId").ok_or_else(incomplete)?,
            state: text("state").ok_or_else(incomplete)?,
            waiting_for_human: value
                .get("waitingForHuman")
                .and_then(Value::as_bool)
                .ok_or_else(incomplete)?,
            outcome_unknown: value
                .get("outcomeUnknown")
                .and_then(Value::as_bool)
                .ok_or_else(incomplete)?,
            outstanding_residue_count: value
                .get("outstandingResidueCount")
                .and_then(Value::as_i64)
                .ok_or_else(incomplete)?,
            execution_mode: text("executionMode"),
            actual_effect: text("actualEffect"),
            started_at: text("startedAtUtc"),
            finished_at: text("finishedAtUtc"),
        })
    }

    fn json(&self) -> Value {
        let mut fields = Map::from_iter([
            ("jobId".to_owned(), json!(self.job_id)),
            (
                "operationReference".to_owned(),
                json!(self.operation_reference),
            ),
            ("targetId".to_owned(), json!(self.target_id)),
            ("state".to_owned(), json!(self.state)),
            ("waitingForHuman".to_owned(), json!(self.waiting_for_human)),
            ("outcomeUnknown".to_owned(), json!(self.outcome_unknown)),
            (
                "outstandingResidueCount".to_owned(),
                json!(self.outstanding_residue_count),
            ),
        ]);
        for (key, value) in [
            ("executionMode", &self.execution_mode),
            ("actualEffect", &self.actual_effect),
            ("startedAtUtc", &self.started_at),
            ("finishedAtUtc", &self.finished_at),
        ] {
            if let Some(value) = value {
                fields.insert(key.into(), json!(value));
            }
        }
        Value::Object(fields)
    }
}

/// Swift `RuntimeHeadlessArtifact`: metadata only, never contents.
#[derive(Clone, Debug)]
struct InventoryArtifact {
    artifact_id: String,
    job_id: String,
    name: String,
    byte_count: i64,
    sha256: String,
    status: String,
    source_operation: String,
    target_id: String,
    binding_revision: Option<i64>,
    stable_identity: Option<String>,
}

impl InventoryArtifact {
    /// Swift `decodeArtifact`, over a row the page validation already passed.
    fn decode(row: &Value) -> Result<Self, String> {
        let incomplete = || "artifact.list contains incomplete metadata".to_owned();
        let text = |value: &Value| value.as_str().map(str::to_owned);
        let binding = row["binding"].as_object().ok_or_else(incomplete)?;
        if row["owner"]["kind"] != "job"
            || !(row["artifactDigest"].is_null() || row["artifactDigest"].is_string())
        {
            return Err(incomplete());
        }
        let artifact_id = text(&row["artifactId"])
            .filter(|id| safe_identifier(id))
            .ok_or_else(incomplete)?;
        let target_id = binding
            .get("targetId")
            .and_then(Value::as_str)
            .filter(|id| safe_identifier(id))
            .ok_or_else(incomplete)?
            .to_owned();
        Ok(Self {
            artifact_id,
            job_id: text(&row["owner"]["id"]).ok_or_else(incomplete)?,
            name: text(&row["name"])
                .filter(|name| !name.is_empty())
                .ok_or_else(incomplete)?,
            byte_count: row["byteCount"]
                .as_i64()
                .filter(|count| *count >= 0)
                .ok_or_else(incomplete)?,
            sha256: text(&row["artifactDigest"]).unwrap_or_default(),
            status: text(&row["status"]).ok_or_else(incomplete)?,
            source_operation: text(&row["sourceOperation"]).ok_or_else(incomplete)?,
            target_id,
            binding_revision: binding.get("bindingRevision").and_then(Value::as_i64),
            stable_identity: binding
                .get("stableIdentitySha256")
                .and_then(Value::as_str)
                .map(str::to_owned),
        })
    }

    fn json(&self) -> Value {
        let mut fields = Map::from_iter([
            ("artifactId".to_owned(), json!(self.artifact_id)),
            ("jobId".to_owned(), json!(self.job_id)),
            ("name".to_owned(), json!(self.name)),
            ("byteCount".to_owned(), json!(self.byte_count)),
            ("sha256".to_owned(), json!(self.sha256)),
            ("status".to_owned(), json!(self.status)),
            ("sourceOperation".to_owned(), json!(self.source_operation)),
            ("targetId".to_owned(), json!(self.target_id)),
        ]);
        if let Some(revision) = self.binding_revision {
            fields.insert("bindingRevision".into(), json!(revision));
        }
        if let Some(identity) = &self.stable_identity {
            fields.insert("stableIdentitySha256".into(), json!(identity));
        }
        Value::Object(fields)
    }
}

/// Swift `CurrentRuntimeResourceReads.artifactInventory`: every page of one
/// Job's Artifact snapshot within a 30 s client deadline, each page valid,
/// one snapshot revision, the order continuing across pages and no cursor
/// repeated.
fn artifact_inventory<F>(job_id: &str, request: &F) -> Result<Vec<InventoryArtifact>, String>
where
    F: Fn(&str, Option<Map<String, Value>>) -> Result<Value, String>,
{
    let deadline = Instant::now() + Duration::from_secs(30);
    let owner = json!({"kind": "job", "id": job_id});
    let (mut cursor, mut revision): (Option<String>, Option<Value>) = (None, None);
    let mut seen = BTreeSet::new();
    let mut previous: Option<(f64, String)> = None;
    let mut rows = Vec::new();
    loop {
        if Instant::now() >= deadline {
            return Err("the client wait deadline expired; no cancellation was requested".into());
        }
        let mut params = Map::from_iter([
            ("owner".to_owned(), owner.clone()),
            ("pageSize".to_owned(), json!(1000)),
        ]);
        if let Some(cursor) = &cursor {
            params.insert("cursor".into(), json!(cursor));
        }
        let page = request("artifact.list", Some(params))?;
        crate::validate_artifact_page(&page, &owner, 1000).map_err(|error| error.message)?;
        if revision
            .as_ref()
            .is_some_and(|revision| *revision != page["snapshotRevision"])
        {
            return Err("Artifact snapshot changed between pages".into());
        }
        revision = Some(page["snapshotRevision"].clone());
        for row in page["items"].as_array().into_iter().flatten() {
            let created = date_seconds(&row["createdAtUtc"])
                .ok_or("Artifact inventory order or identity repeated")?;
            let id = row["artifactId"].as_str().unwrap_or_default().to_owned();
            if previous.as_ref().is_some_and(|(time, before)| {
                !(*time > created || (*time == created && before.as_str() < id.as_str()))
            }) {
                return Err("Artifact inventory order or identity repeated".into());
            }
            previous = Some((created, id));
            rows.push(InventoryArtifact::decode(row)?);
        }
        match page["nextCursor"].as_str() {
            Some(next) => {
                if !seen.insert(next.to_owned()) {
                    return Err("Artifact inventory repeated a cursor".into());
                }
                cursor = Some(next.to_owned());
            }
            None => break,
        }
    }
    rows.sort_by(|left, right| left.artifact_id.cmp(&right.artifact_id));
    Ok(rows)
}

/// The profile a persisted Job is verified against.
struct Profile {
    effect: &'static str,
    authority: &'static str,
    required_artifacts: BTreeSet<&'static str>,
    allowed_artifacts: BTreeSet<&'static str>,
    required_steps: BTreeSet<&'static str>,
}

fn profile(reference: &str) -> Option<Profile> {
    if reference == OBSERVE {
        return Some(Profile {
            effect: "readOnly",
            authority: "defaultReadOnlyPolicy",
            required_artifacts: OBSERVE_ARTIFACTS.into_iter().collect(),
            allowed_artifacts: OBSERVE_ARTIFACTS.into_iter().collect(),
            required_steps: OBSERVE_STEPS.into_iter().collect(),
        });
    }
    if FLASH_REFERENCES.contains(&reference) {
        let required: BTreeSet<&'static str> = FLASH_REQUIRED_ARTIFACTS.into_iter().collect();
        let mut allowed = required.clone();
        allowed.insert(FLASH_OPTIONAL_ARTIFACT);
        return Some(Profile {
            effect: "destructive",
            authority: "runtimeCapability",
            required_artifacts: required,
            allowed_artifacts: allowed,
            required_steps: FLASH_STEPS.into_iter().collect(),
        });
    }
    None
}

/// Swift `persistedAuthorityVerified`.
fn authority_verified(
    authority: Option<&Authority>,
    expected: Option<&str>,
    finished_at: Option<f64>,
) -> bool {
    let (Some(authority), Some(expected), Some(finished_at)) = (authority, expected, finished_at)
    else {
        return false;
    };
    if authority.kind != expected
        || !parse_date(Some(&authority.admitted_at)).is_some_and(|admitted| admitted <= finished_at)
    {
        return false;
    }
    let digest = |value: &Option<String>| value.as_deref().is_some_and(sha256);
    match expected {
        "defaultReadOnlyPolicy" => authority.reference == "default-read-only-policy",
        "runtimeCapability" => {
            safe_identifier(&authority.reference)
                && digest(&authority.consumption_fingerprint)
                && authority
                    .reservation_id
                    .as_deref()
                    .is_some_and(|id| !id.is_empty())
                && authority.use_ordinal.unwrap_or(0) >= 1
                && digest(&authority.plan_digest)
                && digest(&authority.step_set_digest)
                && digest(&authority.target_binding_digest)
                && digest(&authority.artifact_digest)
                && parse_date(authority.valid_until.as_deref())
                    .is_some_and(|valid_until| valid_until >= finished_at)
        }
        _ => false,
    }
}

/// Swift `reopenReport`.
fn reopen_report(
    catalog_digest: &str,
    status: &PersistedStatus,
    facts: &TrustedFacts,
    inventory: &[InventoryArtifact],
    additional_blockers: Vec<String>,
) -> Value {
    let mut blockers: Vec<String> = facts
        .blockers
        .iter()
        .cloned()
        .chain(additional_blockers)
        .collect();
    let profile = profile(&status.operation_reference);
    if profile.is_none() {
        blockers.push(format!(
            "operation:persisted verification has no published profile for {}",
            status.operation_reference
        ));
    }
    let uds_health_verified = sha256(catalog_digest) && facts.catalog_digest == catalog_digest;
    if !uds_health_verified {
        blockers.push("udsHealth:catalog digest is missing or drifted".into());
    }
    let started_at = parse_date(status.started_at.as_deref());
    let finished_at = parse_date(status.finished_at.as_deref());
    let times_verified =
        matches!((started_at, finished_at), (Some(start), Some(end)) if start <= end);
    let effect = profile.as_ref().map(|profile| profile.effect);
    let terminal_status_verified = profile.is_some()
        && status.job_id == facts.job_id
        && status.operation_reference == facts.operation_reference
        && status.target_id == facts.target_id
        && status.state == "succeeded"
        && status.state == facts.terminal_state
        && !status.waiting_for_human
        && !status.outcome_unknown
        && !facts.outcome_unknown
        && status.outstanding_residue_count == 0
        && status.execution_mode.as_deref() == Some("execute")
        && status.execution_mode.as_deref() == Some(facts.execution_mode.as_str())
        && status.actual_effect.as_deref() == effect
        && facts.actual_effect.as_deref() == effect
        && times_verified
        && status.started_at == facts.started_at
        && status.finished_at == facts.finished_at
        && facts.binding_revision.unwrap_or(0) >= 1;
    if !terminal_status_verified {
        blockers.push("terminalStatus:persisted Runtime status and evidence drifted".into());
    }

    let observation = facts.observation.as_ref();
    let confirmed_at = parse_date(observation.and_then(|o| o.confirmed_at.as_deref()));
    let first_evidence_at = parse_date(facts.first_evidence_step_at.as_deref());
    let evidence_times_verified = matches!(
        (started_at, confirmed_at, first_evidence_at, finished_at),
        (Some(start), Some(confirmed), Some(first), Some(end))
            if start <= confirmed && confirmed <= first && first <= end
    );
    let authority_ok = authority_verified(
        facts.authority.as_ref(),
        profile.as_ref().map(|profile| profile.authority),
        finished_at,
    );
    let trusted_evidence_verified = profile.is_some()
        && facts.actual_effect.as_deref() == effect
        && authority_ok
        && observation.is_some_and(|observation| {
            facts.provider_id == observation.provider_id
                && Some(&facts.target_id) == observation.target_id.as_ref()
                && facts.binding_revision == observation.binding_revision
                && observation.stable_identity.as_deref().is_some_and(sha256)
                && observation
                    .model
                    .as_deref()
                    .is_some_and(|model| !model.is_empty())
                && observation
                    .firmware
                    .as_deref()
                    .is_some_and(|firmware| !firmware.is_empty())
                && observation.transport.is_some()
                && !observation.tool_version.is_empty()
                && sha256(&observation.tool_sha256)
                && observation.confirmation_method == "machineReadback"
        })
        && evidence_times_verified;
    if !trusted_evidence_verified {
        blockers.push("trustedEvidence:daemon-owned target/tool observation is incomplete".into());
    }

    let names: BTreeSet<&str> = inventory
        .iter()
        .map(|artifact| artifact.name.as_str())
        .collect();
    let ids: BTreeSet<&str> = inventory
        .iter()
        .map(|artifact| artifact.artifact_id.as_str())
        .collect();
    let references: BTreeSet<&str> = facts
        .artifacts
        .iter()
        .map(|artifact| artifact.reference.as_str())
        .collect();
    let observed_identity = observation.and_then(|observation| observation.stable_identity.clone());
    let artifacts_verified = profile.as_ref().is_some_and(|profile| {
        !inventory.is_empty()
            && names.is_superset(&profile.required_artifacts)
            && names.is_subset(&profile.allowed_artifacts)
            && names.len() == inventory.len()
            && inventory.len() == facts.artifacts.len()
            && ids.len() == inventory.len()
            && references.len() == facts.artifacts.len()
            && inventory.iter().all(|artifact| {
                let reference = format!(
                    "arkdeck-artifact://{}/{}",
                    artifact.job_id, artifact.artifact_id
                );
                facts
                    .artifacts
                    .iter()
                    .find(|evidence| evidence.reference == reference)
                    .is_some_and(|evidence| {
                        artifact.status == "published"
                            && artifact.source_operation == facts.operation_reference
                            && artifact.job_id == facts.job_id
                            && artifact.target_id == facts.target_id
                            && artifact.binding_revision == facts.binding_revision
                            && artifact.stable_identity == observed_identity
                            && sha256(&artifact.sha256)
                            && artifact.sha256 == evidence.sha256
                            && artifact.byte_count == evidence.byte_count
                            && evidence.job_id == facts.job_id
                            && evidence.target_id == facts.target_id
                            && evidence.binding_revision == facts.binding_revision
                            && evidence.stable_identity == observed_identity
                            && evidence.provider_id == facts.provider_id
                            && evidence.bytes_verified
                    })
            })
    });
    if !artifacts_verified {
        blockers.push("artifacts:required immutable inventory is incomplete or drifted".into());
    }

    // Unknown steps are not verified steps: absent `actualStepKinds` fails
    // exactly as an incomplete list does.
    let runtime_postflight_verified = terminal_status_verified
        && trusted_evidence_verified
        && artifacts_verified
        && facts.actual_step_kinds.as_ref().is_some_and(|kinds| {
            let unique: BTreeSet<&str> = kinds.iter().map(String::as_str).collect();
            !kinds.is_empty()
                && unique.len() == kinds.len()
                && !kinds.iter().any(String::is_empty)
                && profile
                    .as_ref()
                    .is_none_or(|profile| unique.is_superset(&profile.required_steps))
        });
    if !runtime_postflight_verified {
        blockers.push(
            "runtimePostflight:typed steps, evidence or Artifact closure is incomplete".into(),
        );
    }

    let blockers: Vec<String> = blockers
        .into_iter()
        .collect::<BTreeSet<_>>()
        .into_iter()
        .collect();
    json!({
        "schemaVersion": REOPEN_SCHEMA,
        "classification": "persistedRuntimeReceipt",
        "daemonCatalogDigest": catalog_digest,
        "status": status.json(),
        "trustedFacts": facts.encoded,
        "artifactInventory": inventory.iter().map(InventoryArtifact::json).collect::<Vec<_>>(),
        "checks": {
            "udsHealthVerified": uds_health_verified,
            "terminalStatusVerified": terminal_status_verified,
            "trustedEvidenceVerified": trusted_evidence_verified,
            "artifactsVerified": artifacts_verified,
            "runtimePostflightVerified": runtime_postflight_verified,
        },
        "runtimeVerified": blockers.is_empty(),
        "blockers": blockers,
    })
}

/// Swift `verifyPersistedJob`. A failure to read any daemon fact (health,
/// status, evidence) is an error of the whole call; an unreadable Artifact
/// inventory is a blocker of an otherwise complete report.
pub fn verify_persisted_job<F>(job_id: &str, request: &F) -> Result<ReopenOutcome, String>
where
    F: Fn(&str, Option<Map<String, Value>>) -> Result<Value, String>,
{
    if !safe_identifier(job_id) {
        return Err("persisted verification job id is unsafe".into());
    }
    let health = request("health", None)?;
    let catalog_digest = health["catalogDigest"]
        .as_str()
        .filter(|digest| sha256(digest))
        .ok_or("LaunchAgent UDS health lacks a valid catalog digest")?
        .to_owned();
    let job = Map::from_iter([("jobId".to_owned(), json!(job_id))]);
    let status = PersistedStatus::read(&request("job.status", Some(job.clone()))?)?;
    let facts = trusted_facts(&request("job.evidence", Some(job))?)?;
    let (inventory, blockers) = match artifact_inventory(job_id, request) {
        Ok(inventory) => (inventory, Vec::new()),
        Err(error) => (Vec::new(), vec![format!("artifactInventory:{error}")]),
    };
    let report = reopen_report(&catalog_digest, &status, &facts, &inventory, blockers);
    if report["runtimeVerified"] == true {
        Ok(ReopenOutcome::Verified(report))
    } else {
        Ok(ReopenOutcome::Failed {
            reason:
                "persisted Runtime status, evidence, Artifact or postflight verification failed"
                    .into(),
            report,
        })
    }
}
