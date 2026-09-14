//! The read side of Swift's `RuntimeCapabilityStore` (ArkDeckStorage), for
//! `capability.list` and `capability.inspect`.
//!
//! A store is a directory: the checkpoint `runtime-capabilities.json`, the
//! events appended to `runtime-capabilities.ledger` since the checkpoint was
//! last written, and `.runtime-capabilities.lock`, which every call holds with
//! a blocking exclusive `flock`. A read here is Swift's `loadDocument` under
//! that lock: the checkpoint and the ledger refused when either is a symbolic
//! link, a ledger without its checkpoint refused, the checkpoint checked for
//! duplicate and malformed JSON and decoded into the current shape alone
//! (each capability's model invariants and field shape included), every
//! appended event decoded and replayed over it with a torn final append
//! dropped, and the whole validated as Swift validates it: use accounting,
//! lineage order, and the receipt and outcome digests. A refusal is Swift's
//! error rendered as the daemon renders it. A read writes nothing but the lock
//! file, which Swift's reads create too.
//!
//! Numbers follow Foundation, as the oracle records it: a field Swift decodes
//! as `Int` takes a number with no fraction however it is spelled (`2.0` is
//! 2), and any other number fails the whole decode; a number inside
//! `exactInputs` is an integer when it has no fraction, as Swift's
//! `JSONValue` holds it. The refusal of a fraction quotes serde's spelling of
//! the number where Foundation quotes the document's.

use std::collections::HashSet;
use std::io;
use std::os::unix::fs::DirBuilderExt;
use std::path::{Path, PathBuf};

use serde_json::{Map, Value, json};

use crate::strict_json::{self, swift_quoted};
use crate::swift_decoding::{
    Decoding, Keyed, Step, characters, same_text, string, swift_value, text_key,
};

const CHECKPOINT: &str = "runtime-capabilities.json";
const LEDGER: &str = "runtime-capabilities.ledger";
const LOCK: &str = ".runtime-capabilities.lock";
const SCHEMA_VERSION: &str = "1.0.0";
/// Swift `CurrentDurableJSON`'s refusal of a record outside the current shape.
const DURABLE_SHAPE: &str = "record does not match the current durable field shape";

/// Swift `RuntimeCapabilityStoreError`: the cases a read can meet.
#[derive(Clone, Debug, PartialEq, Eq)]
pub enum CapabilityStoreError {
    /// `ioFailure`
    Io(String),
    /// `storeCorrupted`
    Corrupted(String),
}

impl CapabilityStoreError {
    /// Swift's interpolation of the error, which the daemon answers with.
    pub fn swift(&self) -> String {
        match self {
            Self::Io(detail) => format!("ioFailure({})", swift_quoted(detail)),
            Self::Corrupted(detail) => format!("storeCorrupted({})", swift_quoted(detail)),
        }
    }
}

/// A refused `capability.list` or `capability.inspect`: Swift's code and
/// message. Swift attaches no details to either.
#[derive(Clone, Debug, PartialEq, Eq)]
pub struct CapabilityRefusal {
    pub code: &'static str,
    pub message: String,
}

fn refusal(code: &'static str, message: impl Into<String>) -> CapabilityRefusal {
    CapabilityRefusal {
        code,
        message: message.into(),
    }
}

/// One Runtime capability store, read as Swift reads it.
pub struct CapabilityStore {
    directory: PathBuf,
}

impl CapabilityStore {
    /// Swift `RuntimeCapabilityStore.init`: the directory, created private
    /// when absent. Nothing in it is read or written until a call.
    pub fn open(directory: &Path) -> io::Result<Self> {
        std::fs::DirBuilder::new()
            .recursive(true)
            .mode(0o700)
            .create(directory)?;
        Ok(Self {
            directory: directory.to_path_buf(),
        })
    }

    /// The daemon's `capability.list` and `capability.inspect`. A list reads
    /// no parameter; an inspection names one capability by `capabilityId`.
    pub fn handle(
        &self,
        method: &str,
        params: &Map<String, Value>,
    ) -> Result<Value, CapabilityRefusal> {
        match method {
            "capability.list" => {
                self.read(|records| Value::Array(records.iter().map(Record::row).collect()))
            }
            "capability.inspect" => {
                let Some(Value::String(capability)) = params.get("capabilityId") else {
                    return Err(refusal("invalidParams", "capabilityId is required"));
                };
                self.read(|records| {
                    records
                        .iter()
                        .find(|record| same_text(&record.capability.id, capability))
                        .map(Record::status)
                })?
                .ok_or_else(|| refusal("notFound", "unknown capability"))
            }
            _ => Err(refusal(
                "unknownMethod",
                format!("{method} is not a capability read"),
            )),
        }
    }

    fn read<T>(&self, answer: impl FnOnce(&[Record]) -> T) -> Result<T, CapabilityRefusal> {
        let document = self
            .load()
            .map_err(|error| refusal("internalError", error.swift()))?;
        Ok(answer(&document.records))
    }

    /// Swift `loadDocument` under `withExclusiveLock`.
    fn load(&self) -> Result<Document, CapabilityStoreError> {
        let unavailable = || CapabilityStoreError::Io("cannot open capability store lock".into());
        let directory =
            arkdeck_platform::HostDirectory::open(&self.directory).map_err(|_| unavailable())?;
        let _lock = directory
            .wait_lock(LOCK, false)
            .map_err(|_| unavailable())?;
        let mut document = self.checkpoint()?;
        let events = self.ledger()?;
        for event in &events {
            apply(event, &mut document)?;
        }
        if !events.is_empty() {
            // Replayed state is validated as a whole, as a checkpoint is.
            validate(&document)?;
        }
        Ok(document)
    }

    /// Swift `loadCheckpoint`.
    fn checkpoint(&self) -> Result<Document, CapabilityStoreError> {
        let checkpoint = self.directory.join(CHECKPOINT);
        let ledger = self.directory.join(LEDGER);
        for path in [&checkpoint, &ledger] {
            if std::fs::symlink_metadata(path).is_ok_and(|metadata| metadata.is_symlink()) {
                return Err(CapabilityStoreError::Io(format!(
                    "cannot read capability store: symbolicLinkRejected({})",
                    swift_quoted(&path.to_string_lossy())
                )));
            }
        }
        let bytes = match std::fs::read(&checkpoint) {
            Ok(bytes) => bytes,
            Err(error) if error.kind() == io::ErrorKind::NotFound => {
                if ledger.exists() {
                    return Err(CapabilityStoreError::Corrupted(format!(
                        "capability checkpoint is missing beside an existing ledger; original state is preserved at {}",
                        self.directory.display()
                    )));
                }
                return Ok(Document {
                    schema_version: SCHEMA_VERSION.into(),
                    records: Vec::new(),
                });
            }
            Err(error) => {
                return Err(CapabilityStoreError::Io(format!(
                    "cannot read capability store: {error}"
                )));
            }
        };
        strict_json::validate(&bytes).map_err(|error| {
            CapabilityStoreError::Corrupted(format!(
                "duplicate or malformed JSON: {}",
                error.swift()
            ))
        })?;
        let document =
            decode_durable(&bytes, Document::decode, Document::value).map_err(|error| {
                CapabilityStoreError::Corrupted(format!(
                    "undecodable current store document: {error}"
                ))
            })?;
        validate(&document)?;
        Ok(document)
    }

    /// Swift `loadLedgerEvents`: a final line without its newline is a torn
    /// append that never happened, and is dropped.
    fn ledger(&self) -> Result<Vec<Event>, CapabilityStoreError> {
        let bytes = match std::fs::read(self.directory.join(LEDGER)) {
            Ok(bytes) => bytes,
            Err(error) if error.kind() == io::ErrorKind::NotFound => return Ok(Vec::new()),
            Err(error) => {
                return Err(CapabilityStoreError::Io(format!(
                    "cannot read capability ledger: {error}"
                )));
            }
        };
        if bytes.is_empty() {
            return Ok(Vec::new());
        }
        let mut lines: Vec<&[u8]> = bytes.split(|byte| *byte == b'\n').collect();
        if bytes.last() != Some(&b'\n') {
            lines.pop();
        }
        lines
            .into_iter()
            .filter(|line| !line.is_empty())
            .map(|line| {
                strict_json::validate(line)
                    .map_err(|error| error.swift())
                    .and_then(|()| decode_durable(line, Event::decode, Event::value))
                    .map_err(|error| {
                        CapabilityStoreError::Corrupted(format!(
                            "undecodable capability ledger event: {error}"
                        ))
                    })
            })
            .collect()
    }
}

/// Swift `CurrentDurableJSON.decode` after its duplicate check: the typed
/// decode, then the JSON must be exactly what the typed value encodes back to.
fn decode_durable<T>(
    bytes: &[u8],
    decode: impl Fn(&Value) -> Result<T, Decoding>,
    encode: impl Fn(&T) -> Value,
) -> Result<T, String> {
    let supplied: Value = serde_json::from_slice(bytes).map_err(|error| error.to_string())?;
    let value = decode(&supplied).map_err(|error| error.describe())?;
    if swift_value(&supplied) != encode(&value) {
        return Err(format!("malformed({})", swift_quoted(DURABLE_SHAPE)));
    }
    Ok(value)
}

// MARK: - The stored model

/// Swift `StoreDocument`.
struct Document {
    schema_version: String,
    records: Vec<Record>,
}

/// Swift `StoredRecord`.
struct Record {
    capability: Capability,
    remaining_uses: i64,
    consumptions: Vec<Consumption>,
}

/// Swift `RuntimeCapability`.
struct Capability {
    id: String,
    target_scope: TargetScope,
    operation_scope: Vec<OperationScope>,
    effect_ceiling: Effect,
    input_constraints: Vec<(String, Constraint)>,
    exact_inputs: Option<Map<String, Value>>,
    exact_artifact_facts: Option<Vec<(String, String)>>,
    issued_at: String,
    expires_at: String,
    maximum_uses: i64,
    issuer_kind: IssuerKind,
    issuer_reference: String,
    exact_plan_digest: Option<String>,
    exact_binding_revision: Option<i64>,
    revocation: Revocation,
}

enum TargetScope {
    AnyTarget,
    StablePhysicalIdentity(String),
    WorkspaceIdentity {
        sha256: String,
        expected_revision: String,
        allowed_scopes: String,
    },
}

struct OperationScope {
    operation_id: String,
    version: Option<i64>,
}

impl OperationScope {
    fn reference(&self) -> String {
        match self.version {
            Some(version) => format!("{}@{version}", self.operation_id),
            None => self.operation_id.clone(),
        }
    }
}

enum Constraint {
    ExactString(String),
    OneOfStrings(Vec<String>),
    IntegerRange(i64, i64),
}

#[derive(Clone, Copy, PartialEq, Eq)]
enum Effect {
    HostOnly,
    ReadOnly,
    DeviceMutation,
    Destructive,
}

impl Effect {
    fn parse(raw: &str) -> Option<Self> {
        Some(match raw {
            "hostOnly" => Self::HostOnly,
            "readOnly" => Self::ReadOnly,
            "deviceMutation" => Self::DeviceMutation,
            "destructive" => Self::Destructive,
            _ => return None,
        })
    }

    fn raw(self) -> &'static str {
        match self {
            Self::HostOnly => "hostOnly",
            Self::ReadOnly => "readOnly",
            Self::DeviceMutation => "deviceMutation",
            Self::Destructive => "destructive",
        }
    }
}

#[derive(Clone, Copy, PartialEq, Eq)]
enum IssuerKind {
    MaintainerMergedPr,
    RuntimeDefaultPolicy,
}

impl IssuerKind {
    fn parse(raw: &str) -> Option<Self> {
        match raw {
            "maintainerMergedPR" => Some(Self::MaintainerMergedPr),
            "runtimeDefaultPolicy" => Some(Self::RuntimeDefaultPolicy),
            _ => None,
        }
    }

    fn raw(self) -> &'static str {
        match self {
            Self::MaintainerMergedPr => "maintainerMergedPR",
            Self::RuntimeDefaultPolicy => "runtimeDefaultPolicy",
        }
    }
}

enum Revocation {
    Active,
    Revoked { at: String, reason: String },
}

/// Swift `StoredConsumption`: one use and its outcomes.
#[derive(Clone)]
struct Consumption {
    ordinal: i64,
    reservation: String,
    job: String,
    consumed_at: String,
    operation_reference: String,
    effect: String,
    target: Option<String>,
    binding_revision: Option<i64>,
    plan_digest: Option<String>,
    authorization_scope: String,
    query: String,
    remaining_after: i64,
    previous_lineage: Option<String>,
    receipt: String,
    outcomes: Vec<Outcome>,
}

impl Consumption {
    fn current(&self) -> UseOutcome {
        self.outcomes
            .last()
            .map_or(UseOutcome::Pending, |outcome| outcome.outcome)
    }

    fn lineage_tip(&self) -> &str {
        self.outcomes
            .last()
            .map_or(self.receipt.as_str(), |outcome| outcome.record.as_str())
    }
}

/// Swift `StoredOutcomeRecord`.
#[derive(Clone)]
struct Outcome {
    job: String,
    outcome: UseOutcome,
    terminal_state: String,
    recorded_at: String,
    previous_record: String,
    record: String,
}

#[derive(Clone, Copy, PartialEq, Eq)]
enum UseOutcome {
    Pending,
    Confirmed,
    SafeToReflash,
    OutcomeUnknown,
}

impl UseOutcome {
    fn parse(raw: &str) -> Option<Self> {
        Some(match raw {
            "pending" => Self::Pending,
            "confirmed" => Self::Confirmed,
            "safeToReflash" => Self::SafeToReflash,
            "outcomeUnknown" => Self::OutcomeUnknown,
            _ => return None,
        })
    }

    fn raw(self) -> &'static str {
        match self {
            Self::Pending => "pending",
            Self::Confirmed => "confirmed",
            Self::SafeToReflash => "safeToReflash",
            Self::OutcomeUnknown => "outcomeUnknown",
        }
    }

    fn settled(self) -> bool {
        matches!(self, Self::Confirmed | Self::SafeToReflash)
    }
}

/// Swift `StoredLedgerEvent`.
struct Event {
    kind: String,
    capability: String,
    consumption: Option<Consumption>,
    reservation: Option<String>,
    outcome: Option<Outcome>,
}

// MARK: - Decoding, in Swift's member order

impl Document {
    fn decode(value: &Value) -> Result<Self, Decoding> {
        let keyed = Keyed::of(value, Vec::new())?;
        let schema_version = keyed.string("schemaVersion")?;
        let records = keyed
            .array("records")?
            .into_iter()
            .map(|(record, path)| Record::decode(record, path))
            .collect::<Result<_, _>>()?;
        Ok(Self {
            schema_version,
            records,
        })
    }

    fn value(&self) -> Value {
        json!({
            "schemaVersion": self.schema_version,
            "records": self.records.iter().map(Record::value).collect::<Vec<_>>(),
        })
    }
}

impl Record {
    fn decode(value: &Value, path: Vec<Step>) -> Result<Self, Decoding> {
        let keyed = Keyed::of(value, path)?;
        let capability =
            Capability::decode(keyed.present("capability")?, keyed.path("capability"))?;
        let remaining_uses = keyed.int("remainingUses")?;
        let consumptions = keyed
            .array("consumptions")?
            .into_iter()
            .map(|(use_, path)| Consumption::decode(use_, path))
            .collect::<Result<_, _>>()?;
        Ok(Self {
            capability,
            remaining_uses,
            consumptions,
        })
    }

    fn value(&self) -> Value {
        json!({
            "capability": self.capability.value(),
            "remainingUses": self.remaining_uses,
            "consumptions": self
                .consumptions
                .iter()
                .map(|use_| use_.value("outcomes"))
                .collect::<Vec<_>>(),
        })
    }

    /// Swift `status(of:)`'s blocker: the first use without a settled
    /// outcome, else an exhausted budget.
    fn blocker(&self) -> Option<String> {
        if let Some(unresolved) = self
            .consumptions
            .iter()
            .find(|use_| !use_.current().settled())
        {
            return Some(format!(
                "use {} is {}",
                unresolved.ordinal,
                unresolved.current().raw()
            ));
        }
        (self.remaining_uses == 0).then(|| "maximumUses exhausted".to_owned())
    }

    /// The daemon's `capability.list` row.
    fn row(&self) -> Value {
        let blocker = self.blocker();
        json!({
            "capabilityId": self.capability.id,
            "effectCeiling": self.capability.effect_ceiling.raw(),
            "maximumUses": self.capability.maximum_uses,
            "remainingUses": self.remaining_uses,
            "consumptionCount": self.consumptions.len(),
            "lineageAllowsNewExecution": blocker.is_none(),
            "lineageBlocker": blocker,
        })
    }

    /// Swift `RuntimeCapabilityStatus`, encoded as `capability.inspect`
    /// answers it: an absent blocker has no member.
    fn status(&self) -> Value {
        let blocker = self.blocker();
        let mut status = Map::new();
        status.insert("capability".into(), self.capability.value());
        status.insert("remainingUses".into(), json!(self.remaining_uses));
        status.insert("consumptionCount".into(), json!(self.consumptions.len()));
        status.insert("lineageAllowsNewExecution".into(), json!(blocker.is_none()));
        if let Some(blocker) = blocker {
            status.insert("lineageBlocker".into(), json!(blocker));
        }
        status.insert(
            "lineage".into(),
            Value::Array(
                self.consumptions
                    .iter()
                    .map(|use_| use_.value("outcomeHistory"))
                    .collect(),
            ),
        );
        Value::Object(status)
    }
}

impl Capability {
    /// Swift `RuntimeCapability.init(from:)`: every member, then the model's
    /// invariants, then the exact current field shape.
    fn decode(value: &Value, path: Vec<Step>) -> Result<Self, Decoding> {
        let keyed = Keyed::of(value, path.clone())?;
        let id = keyed.string("capabilityID")?;
        let target_scope = TargetScope::decode(&keyed.keyed("targetScope")?)?;
        let operation_scope = keyed
            .array("operationScope")?
            .into_iter()
            .map(|(scope, path)| {
                let scope = Keyed::of(scope, path)?;
                Ok(OperationScope {
                    operation_id: scope.string("operationID")?,
                    version: scope.optional_int("version")?,
                })
            })
            .collect::<Result<_, Decoding>>()?;
        let effect_ceiling = keyed.raw("effectCeiling", "WorkflowEffect", Effect::parse)?;
        let constraints = keyed.keyed("inputConstraints")?;
        let input_constraints = constraints
            .members
            .iter()
            .map(|(name, constraint)| {
                Ok((
                    name.clone(),
                    Constraint::decode(&Keyed::of(constraint, constraints.path(name))?)?,
                ))
            })
            .collect::<Result<_, Decoding>>()?;
        let exact_inputs = keyed
            .optional("exactInputs")
            .map(|inputs| {
                Keyed::of(inputs, keyed.path("exactInputs")).map(|inputs| {
                    inputs
                        .members
                        .iter()
                        .map(|(name, input)| (name.clone(), swift_value(input)))
                        .collect()
                })
            })
            .transpose()?;
        let exact_artifact_facts = keyed
            .optional("exactArtifactFacts")
            .map(|facts| {
                let facts = Keyed::of(facts, keyed.path("exactArtifactFacts"))?;
                facts
                    .members
                    .iter()
                    .map(|(name, fact)| Ok((name.clone(), string(fact, facts.path(name))?)))
                    .collect::<Result<Vec<_>, Decoding>>()
            })
            .transpose()?;
        let issued_at = keyed.string("issuedAtUTC")?;
        let expires_at = keyed.string("expiresAtUTC")?;
        let maximum_uses = keyed.int("maximumUses")?;
        let issuer = keyed.keyed("issuer")?;
        let issuer_kind = issuer.raw("kind", "Kind", IssuerKind::parse)?;
        let issuer_reference = issuer.string("reference")?;
        let exact_plan_digest = keyed.optional_string("exactPlanDigest")?;
        let exact_binding_revision = keyed.optional_int("exactBindingRevision")?;
        let revocation = Revocation::decode(&keyed.keyed("revocation")?)?;
        let capability = Self {
            id,
            target_scope,
            operation_scope,
            effect_ceiling,
            input_constraints,
            exact_inputs,
            exact_artifact_facts,
            issued_at,
            expires_at,
            maximum_uses,
            issuer_kind,
            issuer_reference,
            exact_plan_digest,
            exact_binding_revision,
            revocation,
        };
        capability
            .invariants()
            .map_err(|violation| Decoding::DataCorrupted {
                description: format!("capability violates model invariants: {violation}"),
                path: path.clone(),
            })?;
        if swift_value(value) != capability.value() {
            return Err(Decoding::DataCorrupted {
                description: "unsupported current capability field shape".into(),
                path,
            });
        }
        Ok(capability)
    }

    /// The synthesized encoding: an absent optional has no member.
    fn value(&self) -> Value {
        let mut capability = Map::new();
        capability.insert("capabilityID".into(), json!(self.id));
        capability.insert("targetScope".into(), self.target_scope.value());
        capability.insert(
            "operationScope".into(),
            Value::Array(
                self.operation_scope
                    .iter()
                    .map(|scope| {
                        let mut value = Map::new();
                        value.insert("operationID".into(), json!(scope.operation_id));
                        if let Some(version) = scope.version {
                            value.insert("version".into(), json!(version));
                        }
                        Value::Object(value)
                    })
                    .collect(),
            ),
        );
        capability.insert("effectCeiling".into(), json!(self.effect_ceiling.raw()));
        capability.insert(
            "inputConstraints".into(),
            Value::Object(
                self.input_constraints
                    .iter()
                    .map(|(name, constraint)| (name.clone(), constraint.value()))
                    .collect(),
            ),
        );
        if let Some(inputs) = &self.exact_inputs {
            capability.insert("exactInputs".into(), Value::Object(inputs.clone()));
        }
        if let Some(facts) = &self.exact_artifact_facts {
            capability.insert(
                "exactArtifactFacts".into(),
                Value::Object(
                    facts
                        .iter()
                        .map(|(name, fact)| (name.clone(), json!(fact)))
                        .collect(),
                ),
            );
        }
        capability.insert("issuedAtUTC".into(), json!(self.issued_at));
        capability.insert("expiresAtUTC".into(), json!(self.expires_at));
        capability.insert("maximumUses".into(), json!(self.maximum_uses));
        capability.insert(
            "issuer".into(),
            json!({"kind": self.issuer_kind.raw(), "reference": self.issuer_reference}),
        );
        if let Some(digest) = &self.exact_plan_digest {
            capability.insert("exactPlanDigest".into(), json!(digest));
        }
        if let Some(revision) = self.exact_binding_revision {
            capability.insert("exactBindingRevision".into(), json!(revision));
        }
        capability.insert("revocation".into(), self.revocation.value());
        Value::Object(capability)
    }

    /// Swift `RuntimeCapability.validate()`: the first violated invariant, as
    /// Swift interpolates its `RuntimeCapabilityValidationError`.
    fn invariants(&self) -> Result<(), String> {
        let well_formed_id = self.id.strip_prefix("CAP-RT-").is_some_and(|suffix| {
            !suffix.is_empty()
                && suffix
                    .chars()
                    .all(|c| c.is_ascii_digit() || c.is_ascii_uppercase() || c == '-')
        });
        if !well_formed_id {
            return Err(case_text("malformedCapabilityID", &self.id));
        }
        if !matches!(
            self.effect_ceiling,
            Effect::DeviceMutation | Effect::Destructive
        ) {
            return Err(format!(
                "unsupportedEffectCeiling(ArkDeckCore.WorkflowEffect.{})",
                self.effect_ceiling.raw()
            ));
        }
        if self.operation_scope.is_empty() {
            return Err("emptyOperationScope".into());
        }
        for scope in &self.operation_scope {
            if scope.operation_id.is_empty()
                || scope.version.is_some_and(|version| version < 1)
                || !scope
                    .operation_id
                    .chars()
                    .all(|c| c.is_ascii_lowercase() || c.is_ascii_digit() || c == '.' || c == '-')
            {
                return Err(case_text("malformedOperationReference", &scope.reference()));
            }
        }
        if let TargetScope::StablePhysicalIdentity(sha256) = &self.target_scope
            && !hex_digest(sha256)
        {
            return Err(case_text("malformedStableIdentity", sha256));
        }
        let runtime_policy = self.issuer_kind == IssuerKind::RuntimeDefaultPolicy;
        if self.effect_ceiling == Effect::Destructive {
            if !matches!(self.target_scope, TargetScope::StablePhysicalIdentity(_)) {
                return Err("destructiveRequiresStableIdentityTarget".into());
            }
            if self.exact_plan_digest.is_none() {
                return Err("destructiveRequiresExactPlanDigest".into());
            }
            if self.maximum_uses != 1 {
                return Err("destructiveRequiresSingleUse".into());
            }
        }
        if runtime_policy && self.exact_inputs.is_none() {
            return Err("runtimePolicyRequiresExactInputs".into());
        }
        if self.effect_ceiling == Effect::Destructive
            && runtime_policy
            && self
                .exact_artifact_facts
                .as_ref()
                .is_none_or(|facts| facts.is_empty())
        {
            return Err("runtimePolicyRequiresExactArtifactFacts".into());
        }
        if self.exact_artifact_facts.as_ref().is_some_and(|facts| {
            facts.iter().any(|(name, fact)| {
                name.is_empty()
                    || fact.is_empty()
                    || characters(name) > 80
                    || characters(fact) > 256
            })
        }) {
            return Err("runtimePolicyRequiresExactArtifactFacts".into());
        }
        if let Some(digest) = &self.exact_plan_digest
            && !hex_digest(digest)
        {
            return Err(case_text("malformedPlanDigest", digest));
        }
        if let Some(revision) = self.exact_binding_revision
            && revision < 1
        {
            return Err(format!("malformedBindingRevision({revision})"));
        }
        for timestamp in [&self.issued_at, &self.expires_at] {
            if !fixed_utc(timestamp) {
                return Err(case_text("malformedTimestamp", timestamp));
            }
        }
        if self.expires_at <= self.issued_at {
            return Err("expiryNotAfterIssue".into());
        }
        if !(1..=10_000).contains(&self.maximum_uses) {
            return Err(format!("invalidMaximumUses({})", self.maximum_uses));
        }
        if self.issuer_reference.is_empty() || characters(&self.issuer_reference) > 200 {
            return Err(case_text(
                "malformedIssuerReference",
                &self.issuer_reference,
            ));
        }
        for (name, constraint) in &self.input_constraints {
            if !name.chars().next().is_some_and(char::is_lowercase)
                || !name.chars().all(|c| c.is_ascii_alphanumeric())
            {
                return Err(case_text("forbiddenInputConstraintKey", name));
            }
            let empty = match constraint {
                Constraint::OneOfStrings(values) => values.is_empty(),
                Constraint::IntegerRange(minimum, maximum) => minimum > maximum,
                Constraint::ExactString(_) => false,
            };
            if empty {
                return Err(case_text("emptyInputConstraint", name));
            }
        }
        Ok(())
    }
}

impl TargetScope {
    fn decode(keyed: &Keyed<'_>) -> Result<Self, Decoding> {
        let kind = keyed.string("kind")?;
        match kind.as_str() {
            "anyTarget" => Ok(Self::AnyTarget),
            "stablePhysicalIdentity" => Ok(Self::StablePhysicalIdentity(keyed.string("sha256")?)),
            "workspaceIdentity" => Ok(Self::WorkspaceIdentity {
                sha256: keyed.string("sha256")?,
                expected_revision: keyed.string("expectedWorkspaceRevision")?,
                allowed_scopes: keyed.string("allowedFileScopesDigest")?,
            }),
            _ => Err(keyed.corrupted("kind", format!("unknown target scope kind {kind}"))),
        }
    }

    fn value(&self) -> Value {
        match self {
            Self::AnyTarget => json!({"kind": "anyTarget"}),
            Self::StablePhysicalIdentity(sha256) => {
                json!({"kind": "stablePhysicalIdentity", "sha256": sha256})
            }
            Self::WorkspaceIdentity {
                sha256,
                expected_revision,
                allowed_scopes,
            } => json!({
                "kind": "workspaceIdentity",
                "sha256": sha256,
                "expectedWorkspaceRevision": expected_revision,
                "allowedFileScopesDigest": allowed_scopes,
            }),
        }
    }
}

impl Constraint {
    fn decode(keyed: &Keyed<'_>) -> Result<Self, Decoding> {
        let kind = keyed.string("kind")?;
        match kind.as_str() {
            "exactString" => Ok(Self::ExactString(keyed.string("value")?)),
            "oneOfStrings" => Ok(Self::OneOfStrings(
                keyed
                    .array("values")?
                    .into_iter()
                    .map(|(value, path)| string(value, path))
                    .collect::<Result<_, _>>()?,
            )),
            "integerRange" => Ok(Self::IntegerRange(
                keyed.int("minimum")?,
                keyed.int("maximum")?,
            )),
            _ => Err(keyed.corrupted("kind", format!("unknown constraint kind {kind}"))),
        }
    }

    fn value(&self) -> Value {
        match self {
            Self::ExactString(value) => json!({"kind": "exactString", "value": value}),
            Self::OneOfStrings(values) => json!({"kind": "oneOfStrings", "values": values}),
            Self::IntegerRange(minimum, maximum) => {
                json!({"kind": "integerRange", "minimum": minimum, "maximum": maximum})
            }
        }
    }
}

impl Revocation {
    fn decode(keyed: &Keyed<'_>) -> Result<Self, Decoding> {
        let state = keyed.string("state")?;
        match state.as_str() {
            "active" => Ok(Self::Active),
            "revoked" => Ok(Self::Revoked {
                at: keyed.string("atUTC")?,
                reason: keyed.string("reason")?,
            }),
            _ => Err(keyed.corrupted("state", format!("unknown revocation state {state}"))),
        }
    }

    fn value(&self) -> Value {
        match self {
            Self::Active => json!({"state": "active"}),
            Self::Revoked { at, reason } => {
                json!({"state": "revoked", "atUTC": at, "reason": reason})
            }
        }
    }
}

impl Consumption {
    fn decode(value: &Value, path: Vec<Step>) -> Result<Self, Decoding> {
        let keyed = Keyed::of(value, path)?;
        Ok(Self {
            ordinal: keyed.int("ordinal")?,
            reservation: keyed.string("reservationID")?,
            job: keyed.string("jobID")?,
            consumed_at: keyed.string("consumedAtUTC")?,
            operation_reference: keyed.string("operationReference")?,
            effect: keyed.string("effect")?,
            target: keyed.optional_string("targetStableIdentitySHA256")?,
            binding_revision: keyed.optional_int("bindingRevision")?,
            plan_digest: keyed.optional_string("materializedPlanDigest")?,
            authorization_scope: keyed.string("authorizationScopeFingerprintSHA256")?,
            query: keyed.string("queryFingerprintSHA256")?,
            remaining_after: keyed.int("remainingUsesAfter")?,
            previous_lineage: keyed.optional_string("previousLineageSHA256")?,
            receipt: keyed.string("receiptSHA256")?,
            outcomes: keyed
                .array("outcomes")?
                .into_iter()
                .map(|(outcome, path)| Outcome::decode(outcome, path))
                .collect::<Result<_, _>>()?,
        })
    }

    /// The use as the store holds it (`outcomes`) or as a status's lineage
    /// entry shows it (`outcomeHistory`).
    fn value(&self, outcomes: &str) -> Value {
        let mut use_ = self.material_members();
        use_.insert("receiptSHA256".into(), json!(self.receipt));
        use_.insert(
            outcomes.into(),
            Value::Array(self.outcomes.iter().map(Outcome::value).collect()),
        );
        Value::Object(use_)
    }

    /// Every member but the receipt and outcomes: what the receipt digests,
    /// apart from the capability's identity.
    fn material_members(&self) -> Map<String, Value> {
        let mut members = Map::new();
        members.insert("ordinal".into(), json!(self.ordinal));
        members.insert("reservationID".into(), json!(self.reservation));
        members.insert("jobID".into(), json!(self.job));
        members.insert("consumedAtUTC".into(), json!(self.consumed_at));
        members.insert("operationReference".into(), json!(self.operation_reference));
        members.insert("effect".into(), json!(self.effect));
        if let Some(target) = &self.target {
            members.insert("targetStableIdentitySHA256".into(), json!(target));
        }
        if let Some(revision) = self.binding_revision {
            members.insert("bindingRevision".into(), json!(revision));
        }
        if let Some(plan) = &self.plan_digest {
            members.insert("materializedPlanDigest".into(), json!(plan));
        }
        members.insert(
            "authorizationScopeFingerprintSHA256".into(),
            json!(self.authorization_scope),
        );
        members.insert("queryFingerprintSHA256".into(), json!(self.query));
        members.insert("remainingUsesAfter".into(), json!(self.remaining_after));
        if let Some(previous) = &self.previous_lineage {
            members.insert("previousLineageSHA256".into(), json!(previous));
        }
        members
    }

    /// Swift `ReceiptMaterial`.
    fn receipt_material(&self, capability: &str) -> Value {
        let mut material = self.material_members();
        material.insert("capabilityID".into(), json!(capability));
        Value::Object(material)
    }
}

impl Outcome {
    fn decode(value: &Value, path: Vec<Step>) -> Result<Self, Decoding> {
        let keyed = Keyed::of(value, path)?;
        Ok(Self {
            job: keyed.string("jobID")?,
            outcome: keyed.raw("outcome", "RuntimeCapabilityUseOutcome", UseOutcome::parse)?,
            terminal_state: keyed.string("terminalState")?,
            recorded_at: keyed.string("recordedAtUTC")?,
            previous_record: keyed.string("previousRecordSHA256")?,
            record: keyed.string("recordSHA256")?,
        })
    }

    fn value(&self) -> Value {
        json!({
            "jobID": self.job,
            "outcome": self.outcome.raw(),
            "terminalState": self.terminal_state,
            "recordedAtUTC": self.recorded_at,
            "previousRecordSHA256": self.previous_record,
            "recordSHA256": self.record,
        })
    }

    /// Swift `OutcomeMaterial`.
    fn material(&self, capability: &str, use_: &Consumption) -> Value {
        json!({
            "capabilityID": capability,
            "ordinal": use_.ordinal,
            "reservationID": use_.reservation,
            "jobID": self.job,
            "outcome": self.outcome.raw(),
            "terminalState": self.terminal_state,
            "recordedAtUTC": self.recorded_at,
            "previousRecordSHA256": self.previous_record,
        })
    }
}

impl Event {
    fn decode(value: &Value) -> Result<Self, Decoding> {
        let keyed = Keyed::of(value, Vec::new())?;
        Ok(Self {
            kind: keyed.string("kind")?,
            capability: keyed.string("capabilityID")?,
            consumption: keyed
                .optional("consumption")
                .map(|use_| Consumption::decode(use_, keyed.path("consumption")))
                .transpose()?,
            reservation: keyed.optional_string("reservationID")?,
            outcome: keyed
                .optional("outcome")
                .map(|outcome| Outcome::decode(outcome, keyed.path("outcome")))
                .transpose()?,
        })
    }

    fn value(&self) -> Value {
        let mut event = Map::new();
        event.insert("kind".into(), json!(self.kind));
        event.insert("capabilityID".into(), json!(self.capability));
        if let Some(use_) = &self.consumption {
            event.insert("consumption".into(), use_.value("outcomes"));
        }
        if let Some(reservation) = &self.reservation {
            event.insert("reservationID".into(), json!(reservation));
        }
        if let Some(outcome) = &self.outcome {
            event.insert("outcome".into(), outcome.value());
        }
        Value::Object(event)
    }
}

// MARK: - Replay and validation

/// Swift `apply(_:to:)`: one appended event over the replayed document.
fn apply(event: &Event, document: &mut Document) -> Result<(), CapabilityStoreError> {
    let corrupted = |detail: String| CapabilityStoreError::Corrupted(detail);
    let Some(record) = document
        .records
        .iter_mut()
        .find(|record| same_text(&record.capability.id, &event.capability))
    else {
        return Err(corrupted(format!(
            "ledger names capability {}, which the store does not hold",
            event.capability
        )));
    };
    match event.kind.as_str() {
        "consumed" => {
            let (Some(use_), None, None) = (&event.consumption, &event.reservation, &event.outcome)
            else {
                return Err(corrupted("ledger consume carries no use".into()));
            };
            if record
                .consumptions
                .iter()
                .any(|taken| same_text(&taken.reservation, &use_.reservation))
            {
                return Err(corrupted(format!(
                    "ledger replays reservation {} twice",
                    use_.reservation
                )));
            }
            record.consumptions.push(use_.clone());
            record.remaining_uses = use_.remaining_after;
        }
        "outcome" => {
            let (Some(reservation), Some(outcome), None) =
                (&event.reservation, &event.outcome, &event.consumption)
            else {
                return Err(corrupted("ledger outcome carries no record".into()));
            };
            let Some(use_) = record
                .consumptions
                .iter_mut()
                .find(|taken| same_text(&taken.reservation, reservation))
            else {
                return Err(corrupted(format!(
                    "ledger settles reservation {reservation}, which was never taken"
                )));
            };
            use_.outcomes.push(outcome.clone());
        }
        other => {
            return Err(corrupted(format!(
                "ledger holds an unknown event kind {other}"
            )));
        }
    }
    Ok(())
}

/// Swift `validate(_:)`: the schema, unique identities, use accounting,
/// lineage order, and each receipt and outcome as its digest binds it.
fn validate(document: &Document) -> Result<(), CapabilityStoreError> {
    let corrupted = |detail: String| Err(CapabilityStoreError::Corrupted(detail));
    if document.schema_version != SCHEMA_VERSION {
        return corrupted(format!(
            "unsupported schema version {}",
            document.schema_version
        ));
    }
    let mut identities = HashSet::new();
    if !document
        .records
        .iter()
        .all(|record| identities.insert(text_key(&record.capability.id)))
    {
        return corrupted("duplicate capability identity".into());
    }
    for record in &document.records {
        let id = &record.capability.id;
        let maximum = record.capability.maximum_uses;
        if record.remaining_uses < 0
            || record.remaining_uses > maximum
            || maximum - record.remaining_uses != record.consumptions.len() as i64
        {
            return corrupted(format!("inconsistent use accounting for {id}"));
        }
        let mut expected_previous: Option<&str> = None;
        let mut reservations = HashSet::new();
        for (offset, use_) in record.consumptions.iter().enumerate() {
            let expected_ordinal = offset as i64 + 1;
            if !lowercase_sha256(&use_.authorization_scope)
                || !lowercase_sha256(&use_.query)
                || use_.ordinal != expected_ordinal
                || use_.remaining_after != maximum - expected_ordinal
                || use_.previous_lineage.as_deref() != expected_previous
                || !reservations.insert(text_key(&use_.reservation))
            {
                return corrupted(format!("invalid lineage ordering for {id}"));
            }
            if digest(&use_.receipt_material(id)).as_deref() != Some(use_.receipt.as_str()) {
                return corrupted(format!(
                    "invalid receipt digest for {id} use {}",
                    use_.ordinal
                ));
            }
            let mut expected_outcome_previous = use_.receipt.as_str();
            let mut prior = UseOutcome::Pending;
            for outcome in &use_.outcomes {
                let allowed = prior == UseOutcome::Pending
                    || (prior == UseOutcome::OutcomeUnknown && outcome.outcome.settled());
                if !allowed
                    || outcome.outcome == UseOutcome::Pending
                    || outcome.job.is_empty()
                    || characters(&outcome.job) > 160
                    || outcome.previous_record != expected_outcome_previous
                {
                    return corrupted(format!(
                        "invalid outcome transition for {id} use {}",
                        use_.ordinal
                    ));
                }
                if digest(&outcome.material(id, use_)).as_deref() != Some(outcome.record.as_str()) {
                    return corrupted(format!(
                        "invalid outcome digest for {id} use {}",
                        use_.ordinal
                    ));
                }
                prior = outcome.outcome;
                expected_outcome_previous = &outcome.record;
            }
            expected_previous = Some(use_.lineage_tip());
        }
    }
    Ok(())
}

// MARK: - Helpers

/// Swift's digest of lineage material: SHA-256 of its canonical encoding
/// (`[.sortedKeys, .withoutEscapingSlashes]`).
fn digest(material: &Value) -> Option<String> {
    crate::session_json::encode(material)
        .ok()
        .map(|bytes| arkdeck_contract::sha256_hex(&bytes))
}

fn case_text(case: &str, payload: &str) -> String {
    format!("{case}({})", swift_quoted(payload))
}

/// `SHA256Hex.isLowercaseSHA256`.
fn lowercase_sha256(value: &str) -> bool {
    value.len() == 64
        && value
            .bytes()
            .all(|byte| matches!(byte, b'0'..=b'9' | b'a'..=b'f'))
}

/// `RuntimeCapability.isHexDigest`.
fn hex_digest(value: &str) -> bool {
    lowercase_sha256(value)
}

/// `RuntimeCapability.isFixedFormatUTC`: exactly `YYYY-MM-DDTHH:MM:SSZ`.
fn fixed_utc(value: &str) -> bool {
    value.len() == 20
        && value.bytes().enumerate().all(|(index, byte)| match index {
            4 | 7 => byte == b'-',
            10 => byte == b'T',
            13 | 16 => byte == b':',
            19 => byte == b'Z',
            _ => byte.is_ascii_digit(),
        })
}
