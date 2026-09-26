//! Swift `ArkForgeExecutionAuthority` (`ArkForgeExecutionAuthority.swift`):
//! ArkDeck's half of the split, which decides whether a step may run and says
//! so by signing a `StepPermit`.
//!
//! `arkforged` performs the write and cannot mint a permit. Every admission it
//! asks for is checked against facts this authority holds independently — the
//! plan it approved, the binding it confirmed and its own clock — never echoed
//! back. A refusal is an answer with a reason; a permit is stored complete
//! before it is returned, and a retransmitted admission replays those exact
//! bytes rather than deriving them again (ArkForge `architecture.md` 8.3,
//! 8.6).

use crate::loader::topology_digest;
use arkdeck_contract::{CborValue, canonical_cbor, sha256_hex};
use arkforge_authority_api::authority_side::mint_integrity_tag;
use arkforge_authority_api::{ControllerPairingSecret, PermitIntegrityTag, StepPermit};
use arkforge_core::{
    AttemptId, AuthorityBindingRef, AuthorityNamespace, ControllerSessionId, JobId, OpaqueId,
    PermitId, PlanId, Sha256Digest, StepId,
};
use arkforge_ipc::messages::StepAdmissionSnapshot;
use std::collections::{BTreeMap, HashMap};

/// Swift `ArkForgeAuthorityBinding`: the binding this authority confirmed.
#[derive(Clone, Debug, PartialEq, Eq)]
pub struct AuthorityBinding {
    pub authority_namespace: String,
    pub binding_id: String,
    pub binding_revision: u64,
    pub stable_identity_digest: Vec<u8>,
}

/// Swift `ApprovedPlan`: what this authority approved, held independently of
/// anything the daemon says.
#[derive(Clone, Debug, PartialEq, Eq)]
pub struct ApprovedPlan {
    /// ArkDeck's Job, until the daemon's own is adopted.
    pub job_id: String,
    pub plan_id: String,
    /// The plan digest this authority authorized.
    pub plan_sha256: Vec<u8>,
    /// The device facts digest of the confirmed binding.
    pub admitted_device_facts_sha256: Vec<u8>,
    /// ArkDeck's independently bound normal-mode USB location id; admissions
    /// carry ArkForge's digest of it and are checked against that.
    pub usb_topology: Option<String>,
    pub binding: AuthorityBinding,
    pub controller_session_id: String,
    /// How long a permit stays valid once signed: an unbounded permit is a
    /// standing authorization to write.
    pub permit_lifetime_ms: u64,
}

/// Swift's default permit lifetime.
pub const PERMIT_LIFETIME_MS: u64 = 60_000;

/// Swift `Refusal`: each a distinct fact that failed to match.
#[derive(Clone, Debug, PartialEq, Eq)]
pub enum Refusal {
    UnknownJob {
        asked: String,
        approved: String,
    },
    PlanMismatch,
    DeviceFactsMismatch,
    SnapshotExpired {
        observed_at_epoch_ms: u64,
        lifetime_ms: u64,
        now_epoch_ms: u64,
    },
    SnapshotFromTheFuture {
        observed_at_epoch_ms: u64,
        now_epoch_ms: u64,
    },
    MissingStepIdentity,
    /// The admission's identities cannot form ArkForge's permit: an
    /// identifier its typed ids refuse, or a digest that is not 32 bytes.
    /// Swift signs such bytes and leaves the refusal to the daemon; this
    /// authority refuses them itself, before anything is signed.
    Unsignable(String),
}

impl std::fmt::Display for Refusal {
    fn fmt(&self, f: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        match self {
            Self::UnknownJob { asked, approved } => write!(
                f,
                "admission names job {asked}; this authority approved {approved}"
            ),
            Self::PlanMismatch => write!(
                f,
                "the admission's plan digest is not the plan this authority approved"
            ),
            Self::DeviceFactsMismatch => write!(
                f,
                "the admission's device facts are not the binding this authority confirmed; the \
                 device under the daemon is not the device that was authorized"
            ),
            Self::SnapshotExpired {
                observed_at_epoch_ms,
                lifetime_ms,
                now_epoch_ms,
            } => write!(
                f,
                "the snapshot was read at {observed_at_epoch_ms} and lives {lifetime_ms} ms; it \
                 is now {now_epoch_ms}. Signing a stale snapshot authorizes a write against \
                 facts that have expired"
            ),
            Self::SnapshotFromTheFuture {
                observed_at_epoch_ms,
                now_epoch_ms,
            } => write!(
                f,
                "the snapshot claims to have been read at {observed_at_epoch_ms}, which is after \
                 this authority's own clock reads {now_epoch_ms}; freshness cannot be judged"
            ),
            Self::MissingStepIdentity => {
                write!(f, "the admission carries no step or attempt identity")
            }
            Self::Unsignable(detail) => write!(
                f,
                "the admission's identities cannot form a permit ({detail}); nothing was signed"
            ),
        }
    }
}

/// Swift `ArkForgeSignedPermit`: the canonical body and its tag, and the
/// epoch that travels beside them rather than inside.
#[derive(Clone, Debug, PartialEq, Eq)]
pub struct SignedPermit {
    pub permit_id: String,
    pub signing_body: Vec<u8>,
    pub integrity_tag: Vec<u8>,
    pub pairing_epoch: u64,
}

/// Swift `Decision`.
#[derive(Clone, Debug, PartialEq, Eq)]
pub enum Decision {
    Sign(SignedPermit),
    Refuse(Refusal),
}

/// Swift `ArkForgeExecutionAuthority`.
pub struct ExecutionAuthority {
    plan: ApprovedPlan,
    secret: ControllerPairingSecret,
    now: Box<dyn Fn() -> u64 + Send + Sync>,
    /// Permit id → the exact bytes signed, so a retransmission replays.
    issued: HashMap<String, SignedPermit>,
    /// The job `arkforged` assigned, adopted once at `startExecution`.
    daemon_job_id: Option<String>,
    /// Mode → topology digest, confirmed independently by ArkDeck.
    approved_topology_by_mode: HashMap<String, Vec<u8>>,
}

impl ExecutionAuthority {
    /// Swift `init(plan:secret:now:)`: the normal-mode topology the binding
    /// names is the first approved lineage entry. `now` is epoch
    /// milliseconds.
    pub fn new(
        plan: ApprovedPlan,
        secret: ControllerPairingSecret,
        now: impl Fn() -> u64 + Send + Sync + 'static,
    ) -> Self {
        let mut approved_topology_by_mode = HashMap::new();
        if let Some(digest) = plan.usb_topology.as_deref().and_then(topology_bytes) {
            approved_topology_by_mode.insert("hdc-normal".to_owned(), digest);
        }
        Self {
            plan,
            secret,
            now: Box::new(now),
            issued: HashMap::new(),
            daemon_job_id: None,
            approved_topology_by_mode,
        }
    }

    /// Swift `adoptDaemonJob(_:)`: records the job the daemon assigned; an
    /// empty name or any later call is ignored.
    pub fn adopt_daemon_job(&mut self, job_id: &str) {
        if self.daemon_job_id.is_none() && !job_id.is_empty() {
            self.daemon_job_id = Some(job_id.to_owned());
        }
    }

    /// Swift `recordManagedControlFacts(_:)`: extends the lineage only after
    /// the daemon accepted this authority's managed-control receipt, which is
    /// how Loader's different topology becomes admissible without weakening
    /// selection.
    pub fn record_managed_control_facts(&mut self, facts: &BTreeMap<String, String>) {
        let (Some(mode), Some(topology)) = (facts.get("mode"), facts.get("usbTopology")) else {
            return;
        };
        if let Some(digest) = topology_bytes(topology) {
            self.approved_topology_by_mode
                .insert(canonical_mode(mode), digest);
        }
    }

    /// Swift `recordMaterializedObservationMode(_:)`: the mode of the exact
    /// observation this authority selected and asked ArkForge to seal, for a
    /// recovery that starts with the board already in Loader.
    pub fn record_materialized_observation_mode(&mut self, mode: &str) {
        if let Some(digest) = self.plan.usb_topology.as_deref().and_then(topology_bytes) {
            self.approved_topology_by_mode
                .insert(canonical_mode(mode), digest);
        }
    }

    /// Swift `admit(_:)`: one admission answered, deterministically in its
    /// inputs.
    pub fn admit(&mut self, snapshot: &StepAdmissionSnapshot) -> Decision {
        let permit_id = permit_id(snapshot);
        // Retransmission first: the bytes were already authorized.
        if let Some(already) = self.issued.get(&permit_id) {
            return Decision::Sign(already.clone());
        }
        if snapshot.step_id.is_empty() || snapshot.attempt_id.is_empty() {
            return Decision::Refuse(Refusal::MissingStepIdentity);
        }
        let approved_job_id = self
            .daemon_job_id
            .clone()
            .unwrap_or_else(|| self.plan.job_id.clone());
        if snapshot.job_id != approved_job_id {
            return Decision::Refuse(Refusal::UnknownJob {
                asked: snapshot.job_id.clone(),
                approved: approved_job_id,
            });
        }
        if snapshot.plan_id != self.plan.plan_id || snapshot.plan_sha256 != self.plan.plan_sha256 {
            return Decision::Refuse(Refusal::PlanMismatch);
        }
        if has_raw_device_facts(snapshot) {
            let lineage = self
                .approved_topology_by_mode
                .get(&canonical_mode(&snapshot.observed_mode));
            if snapshot.transport_session_sha256.len() != 32
                || snapshot.malformed_descriptor
                || device_facts_digest(snapshot).as_slice()
                    != snapshot.admitted_device_facts_sha256.as_slice()
                || lineage != Some(&snapshot.topology_sha256)
            {
                return Decision::Refuse(Refusal::DeviceFactsMismatch);
            }
        } else if snapshot.admitted_device_facts_sha256 != self.plan.admitted_device_facts_sha256 {
            // Swift's compatibility branch for recorded v1 fixtures; a live
            // daemon sends the raw facts and takes the branch above.
            return Decision::Refuse(Refusal::DeviceFactsMismatch);
        }
        let now = (self.now)();
        if snapshot.observed_at_epoch_ms > now {
            return Decision::Refuse(Refusal::SnapshotFromTheFuture {
                observed_at_epoch_ms: snapshot.observed_at_epoch_ms,
                now_epoch_ms: now,
            });
        }
        if now - snapshot.observed_at_epoch_ms > snapshot.snapshot_lifetime_ms {
            return Decision::Refuse(Refusal::SnapshotExpired {
                observed_at_epoch_ms: snapshot.observed_at_epoch_ms,
                lifetime_ms: snapshot.snapshot_lifetime_ms,
                now_epoch_ms: now,
            });
        }
        let signed = match self.sign(&permit_id, &approved_job_id, snapshot, now) {
            Ok(signed) => signed,
            Err(detail) => return Decision::Refuse(Refusal::Unsignable(detail)),
        };
        // Stored before it is returned.
        self.issued.insert(permit_id, signed.clone());
        Decision::Sign(signed)
    }

    /// ArkForge's own permit, signed with the pairing secret. The step's
    /// three digests come from the snapshot by design: the daemon states what
    /// it is about to do, and the permit binds exactly that.
    fn sign(
        &self,
        permit_id: &str,
        job_id: &str,
        snapshot: &StepAdmissionSnapshot,
        now: u64,
    ) -> Result<SignedPermit, String> {
        let text = |name: &str, error: arkforge_core::IdError| format!("{name}: {error:?}");
        let binding = &self.plan.binding;
        let mut permit = StepPermit {
            permit_id: PermitId::new(permit_id).map_err(|error| text("permitId", error))?,
            authority_namespace: AuthorityNamespace::new(binding.authority_namespace.as_str())
                .map_err(|error| text("authorityNamespace", error))?,
            controller_session_id: ControllerSessionId::new(
                self.plan.controller_session_id.as_str(),
            )
            .map_err(|error| text("controllerSessionId", error))?,
            job_id: JobId::new(job_id).map_err(|error| text("jobId", error))?,
            plan_id: PlanId::new(self.plan.plan_id.as_str())
                .map_err(|error| text("planId", error))?,
            plan_digest: digest("planDigest", &self.plan.plan_sha256)?,
            step_id: StepId::new(snapshot.step_id.as_str())
                .map_err(|error| text("stepId", error))?,
            attempt_id: AttemptId::new(snapshot.attempt_id.as_str())
                .map_err(|error| text("attemptId", error))?,
            public_step_digest: digest("publicStepDigest", &snapshot.public_step_sha256)?,
            private_action_digest: digest("privateActionDigest", &snapshot.private_action_sha256)?,
            effect_set_digest: digest("effectSetDigest", &snapshot.effect_set_sha256)?,
            authority_binding: AuthorityBindingRef {
                authority_namespace: AuthorityNamespace::new(binding.authority_namespace.as_str())
                    .map_err(|error| text("authorityBinding.authorityNamespace", error))?,
                binding_id: OpaqueId::new(binding.binding_id.as_str())
                    .map_err(|error| text("authorityBinding.bindingId", error))?,
                binding_revision: binding.binding_revision,
                stable_identity_digest: digest(
                    "authorityBinding.stableIdentityDigest",
                    &binding.stable_identity_digest,
                )?,
            },
            admitted_device_facts_digest: digest(
                "admittedDeviceFactsDigest",
                &snapshot.admitted_device_facts_sha256,
            )?,
            issued_at_epoch_ms: now,
            expires_at_epoch_ms: now.saturating_add(self.plan.permit_lifetime_ms),
            // Never configurable: a permit that could be spent twice is not
            // one, and ArkForge refuses it outright.
            single_use: true,
            // Not part of the signed body; minted below.
            integrity_tag: PermitIntegrityTag {
                epoch: self.secret.epoch(),
                tag: Sha256Digest::from_bytes([0; 32]),
            },
        };
        let body = permit
            .signing_body()
            .map_err(|error| format!("permit body: {error:?}"))?;
        permit.integrity_tag = mint_integrity_tag(&permit, &self.secret)
            .map_err(|error| format!("integrity tag: {error:?}"))?;
        Ok(SignedPermit {
            permit_id: permit_id.to_owned(),
            signing_body: body,
            integrity_tag: permit.integrity_tag.tag.as_bytes().to_vec(),
            pairing_epoch: permit.integrity_tag.epoch.0,
        })
    }

    /// Swift `issuedCount`: one permit per admission, never one per request.
    pub fn issued_count(&self) -> usize {
        self.issued.len()
    }

    /// Swift `issuedPermit(_:)`.
    pub fn issued_permit(&self, permit_id: &str) -> Option<&SignedPermit> {
        self.issued.get(permit_id)
    }
}

/// Swift `permitID(for:)`: derived from the step and attempt, so a
/// retransmitted admission maps to the permit already issued.
pub fn permit_id(snapshot: &StepAdmissionSnapshot) -> String {
    format!(
        "PERMIT-{}-{}-{}",
        snapshot.job_id, snapshot.step_id, snapshot.attempt_id
    )
}

/// Swift `deviceFactsDigest(_:)`: SHA-256 of the domain and the canonical
/// CBOR of the admission's raw device facts — the facts the daemon's own
/// admission digest covers, in its map.
pub fn device_facts_digest(snapshot: &StepAdmissionSnapshot) -> Vec<u8> {
    let serial_digest = if snapshot.serial_evidence_kind == "absent" {
        CborValue::Null
    } else {
        CborValue::Bytes(snapshot.serial_sha256.clone())
    };
    let facts = CborValue::Map(vec![
        (
            "mode".to_owned(),
            CborValue::Text(snapshot.observed_mode.clone()),
        ),
        (
            "topologyDigest".to_owned(),
            CborValue::Bytes(snapshot.topology_sha256.clone()),
        ),
        (
            "descriptorDigest".to_owned(),
            CborValue::Bytes(snapshot.descriptor_sha256.clone()),
        ),
        (
            "serialEvidence".to_owned(),
            CborValue::Map(vec![
                (
                    "kind".to_owned(),
                    CborValue::Text(snapshot.serial_evidence_kind.clone()),
                ),
                ("digest".to_owned(), serial_digest),
            ]),
        ),
        (
            "protocolIdentity".to_owned(),
            CborValue::Array(
                snapshot
                    .protocol_identity
                    .iter()
                    .map(|pair| {
                        CborValue::Map(vec![
                            ("key".to_owned(), CborValue::Text(pair.key.clone())),
                            ("value".to_owned(), CborValue::Text(pair.value.clone())),
                        ])
                    })
                    .collect(),
            ),
        ),
        (
            "identityStrength".to_owned(),
            CborValue::Text(snapshot.identity_strength.clone()),
        ),
        (
            "malformedDescriptor".to_owned(),
            CborValue::Bool(snapshot.malformed_descriptor),
        ),
    ]);
    let mut preimage = DEVICE_FACTS_DOMAIN.to_vec();
    // Every value above is in the encoder's vocabulary.
    preimage.extend(canonical_cbor(&facts).unwrap_or_default());
    hex_to_bytes(&sha256_hex(&preimage)).unwrap_or_default()
}

/// The domain Swift's authority hashes the admission facts under, its
/// trailing NUL included. Kept as Swift spells it until the maintainer rules
/// on ArkForge's current domain (F2, 2026-09-26).
const DEVICE_FACTS_DOMAIN: &[u8] = b"arkforge/v1/device-facts\0";

/// Swift `canonicalMode(_:)`: the measured mode lineage's one key, whatever
/// spelling a receipt or an admission uses.
pub fn canonical_mode(mode: &str) -> String {
    let trimmed = mode.trim_matches(swift_whitespace_or_newline);
    match trimmed.to_lowercase().as_str() {
        "normal" | "hdc-normal" => "hdc-normal".to_owned(),
        "loader" | "updater" | "rockusb-loader" => "rockusb-loader".to_owned(),
        "maskrom" | "rockusb-maskrom" => "rockusb-maskrom".to_owned(),
        _ => trimmed.to_owned(),
    }
}

/// Foundation's `CharacterSet.whitespacesAndNewlines`: Unicode's White_Space
/// characters, which Rust's `char::is_whitespace` also reads.
fn swift_whitespace_or_newline(character: char) -> bool {
    character.is_whitespace()
}

/// Swift `hasRawDeviceFacts`: a live daemon's admission, carrying the facts
/// this authority recomputes rather than the v1 fixtures' digest alone.
fn has_raw_device_facts(snapshot: &StepAdmissionSnapshot) -> bool {
    snapshot.topology_sha256.len() == 32
        && snapshot.descriptor_sha256.len() == 32
        && snapshot.admitted_device_facts_sha256.len() == 32
        && !snapshot.serial_evidence_kind.is_empty()
        && !snapshot.identity_strength.is_empty()
}

/// The topology digest of `topology` as raw bytes, or `None` when it is not a
/// USB location id.
fn topology_bytes(topology: &str) -> Option<Vec<u8>> {
    hex_to_bytes(&topology_digest(topology)?)
}

fn hex_to_bytes(hex: &str) -> Option<Vec<u8>> {
    if hex.len() != 64 {
        return None;
    }
    (0..32)
        .map(|index| u8::from_str_radix(hex.get(index * 2..index * 2 + 2)?, 16).ok())
        .collect()
}

fn digest(name: &str, bytes: &[u8]) -> Result<Sha256Digest, String> {
    <[u8; 32]>::try_from(bytes)
        .map(Sha256Digest::from_bytes)
        .map_err(|_| format!("{name}: {} bytes, not 32", bytes.len()))
}

#[cfg(test)]
mod tests;
