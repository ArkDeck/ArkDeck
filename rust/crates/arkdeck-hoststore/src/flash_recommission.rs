//! Proposed CHG-2026-086: one independently bounded recovery of one expired
//! retained-risk archive. Only Runtime admission can reserve this allocation.
//! Neither a caller nor an archive/restart can reset or replenish it.
use super::JobStore;
use crate::flash_facts::RockchipFacts;
use crate::job_record::digest;
use arkdeck_contract::sha256_hex;
use arkdeck_platform::HostDirectory;
use serde::{Deserialize, Serialize};
use serde_json::json;

pub(crate) const OPERATION: &str = "flash.recommission@1";
pub(crate) const CHAIN_FACT: &str = "dayu200RecommissionIdentityChain";
const DOCUMENT: &str = "flash-recommission-allocations.json";
const LOCK: &str = ".flash-recommission-allocations.lock";
const LIMIT: usize = 4 * 1024 * 1024;
const BUDGET_MS: u64 = 1_800_000;

pub(crate) fn clock_millis(now: &str) -> Option<u64> {
    crate::format_time::precise_utc_millis(now)
        .or_else(|| crate::format_time::plain_utc_seconds(now)?.checked_mul(1000))
}

/// Stable material only. Observation timestamps and read-receipt hashes are
/// preserved separately and cannot make a fresh identical plan drift.
#[derive(Clone, Debug, Eq, PartialEq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase", deny_unknown_fields)]
pub(crate) struct IdentityChain {
    pub(crate) target_id: String,
    pub(crate) binding_revision: i64,
    pub(crate) normal_identity_sha256: String,
    pub(crate) hardware_serial_sha256: String,
    pub(crate) loader_serial_sha256: String,
    pub(crate) connector_sha256: String,
    pub(crate) usb_topology: String,
    pub(crate) provider_sha256: String,
    pub(crate) binding_snapshot_sha256: String,
}

impl IdentityChain {
    pub(crate) fn validate(&self) -> Result<(), String> {
        if self.target_id.is_empty()
            || self.normal_identity_sha256 == self.loader_serial_sha256
            || self.binding_revision != 1
            || !crate::rockchip_binding::canonical_topology(&self.usb_topology)
            || [
                &self.normal_identity_sha256,
                &self.hardware_serial_sha256,
                &self.loader_serial_sha256,
                &self.connector_sha256,
                &self.provider_sha256,
                &self.binding_snapshot_sha256,
            ]
            .iter()
            .any(|value| !digest(value))
        {
            return Err("recommission.identityChainIncomplete".into());
        }
        Ok(())
    }

    pub(crate) fn from_facts(facts: &RockchipFacts) -> Result<Self, String> {
        let value = facts
            .server_facts
            .get(CHAIN_FACT)
            .ok_or("recommission.freshIdentityChainMissing")?;
        let chain: Self =
            serde_json::from_str(value).map_err(|_| "recommission.identityChainMalformed")?;
        chain.validate()?;
        if facts.device_mode != "hdc"
            || facts.target_id != chain.target_id
            || facts.binding_revision != chain.binding_revision
            || facts.identity_sha256 != chain.normal_identity_sha256
            || sha256_hex(facts.execution_connect_key.as_bytes()) != chain.normal_identity_sha256
            || facts.tool_sha256 != chain.provider_sha256
            || facts
                .server_facts
                .get("dayu200CrossModeBinding")
                .map(String::as_str)
                != Some("satisfied")
        {
            return Err("recommission.identityChainDrifted".into());
        }
        Ok(chain)
    }

    pub(crate) fn sha256(&self) -> String {
        sha256_hex(&serde_json::to_vec(self).expect("fixed identity-chain fields"))
    }
}

/// Immutable reservation body. Consumption is a separate monotone flag in the
/// private ledger. The body is also pinned into the recovery policy/evidence.
#[derive(Clone, Debug, Eq, PartialEq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase", deny_unknown_fields)]
pub(crate) struct Allocation {
    pub(crate) source_job_id: String,
    pub(crate) source_sha256: String,
    pub(crate) recovery_job_id: String,
    pub(crate) request_fingerprint_sha256: String,
    pub(crate) materialized_plan_sha256: String,
    pub(crate) artifact_sha256: String,
    pub(crate) uncertain_effect_set_sha256: String,
    pub(crate) identity_chain: IdentityChain,
    pub(crate) reserved_at_epoch_ms: u64,
    pub(crate) expires_at_epoch_ms: u64,
}

impl Allocation {
    pub(crate) fn validate(&self) -> Result<(), String> {
        self.identity_chain.validate()?;
        if !super::identifier(&self.source_job_id)
            || !super::identifier(&self.recovery_job_id)
            || self.source_job_id == self.recovery_job_id
            || self.reserved_at_epoch_ms.checked_add(BUDGET_MS) != Some(self.expires_at_epoch_ms)
            || [
                &self.source_sha256,
                &self.request_fingerprint_sha256,
                &self.materialized_plan_sha256,
                &self.artifact_sha256,
                &self.uncertain_effect_set_sha256,
            ]
            .iter()
            .any(|value| !digest(value))
        {
            return Err("recommission.allocationMalformed".into());
        }
        Ok(())
    }

    pub(crate) fn sha256(&self) -> String {
        sha256_hex(&serde_json::to_vec(self).expect("fixed allocation fields"))
    }

    fn current(&self, now: u64) -> Result<(), String> {
        if now < self.reserved_at_epoch_ms || now >= self.expires_at_epoch_ms {
            return Err("recommission.independentBudgetExpired".into());
        }
        Ok(())
    }
}

#[derive(Serialize, Deserialize)]
#[serde(rename_all = "camelCase", deny_unknown_fields)]
struct Entry {
    allocation: Allocation,
    consumed: bool,
    postflight: Option<Postflight>,
    last_observed_epoch_ms: u64,
    budget_closed: bool,
}

impl Entry {
    fn check_budget(&mut self, now: u64) -> Result<(), String> {
        self.budget_closed |=
            now < self.last_observed_epoch_ms || self.allocation.current(now).is_err();
        self.last_observed_epoch_ms = self.last_observed_epoch_ms.max(now);
        if self.budget_closed {
            Err("recommission.independentBudgetExpired".into())
        } else {
            Ok(())
        }
    }
}

#[derive(Serialize, Deserialize)]
#[serde(rename_all = "camelCase", deny_unknown_fields)]
struct Postflight {
    identity_chain_sha256: String,
    observation_sha256: String,
    confirmed_at_epoch_ms: u64,
}

#[derive(Serialize, Deserialize)]
#[serde(rename_all = "camelCase", deny_unknown_fields)]
struct Ledger {
    schema_version: String,
    allocations: Vec<Entry>,
}

fn load(root: &HostDirectory) -> Result<Ledger, String> {
    let bytes = match root.read(DOCUMENT, LIMIT) {
        Ok(bytes) => bytes,
        Err(error) if error.kind() == std::io::ErrorKind::NotFound => {
            return Ok(Ledger {
                schema_version: "1.0.0".into(),
                allocations: Vec::new(),
            });
        }
        Err(_) => return Err("recommission.allocationLedgerUnreadable".into()),
    };
    let ledger: Ledger =
        serde_json::from_slice(&bytes).map_err(|_| "recommission.allocationLedgerMalformed")?;
    if ledger.schema_version != "1.0.0" {
        return Err("recommission.allocationLedgerVersionUnsupported".into());
    }
    let mut identities = std::collections::BTreeSet::new();
    for entry in &ledger.allocations {
        entry.allocation.validate()?;
        if entry.last_observed_epoch_ms < entry.allocation.reserved_at_epoch_ms {
            return Err("recommission.allocationClockMalformed".into());
        }
        if let Some(proof) = &entry.postflight
            && (!entry.consumed
                || proof.identity_chain_sha256 != entry.allocation.identity_chain.sha256()
                || !digest(&proof.observation_sha256)
                || proof.confirmed_at_epoch_ms < entry.allocation.reserved_at_epoch_ms
                || proof.confirmed_at_epoch_ms >= entry.allocation.expires_at_epoch_ms)
        {
            return Err("recommission.postflightProofMalformed".into());
        }
        if !identities.insert(&entry.allocation.identity_chain.normal_identity_sha256) {
            return Err("recommission.duplicateAllocation".into());
        }
    }
    Ok(ledger)
}

fn persist(root: &HostDirectory, ledger: &Ledger) -> Result<(), String> {
    let bytes = serde_json::to_vec(ledger).map_err(|_| "recommission.allocationEncodingFailed")?;
    root.replace_document(DOCUMENT, &bytes, LIMIT)
        .map_err(|_| "recommission.allocationPersistenceFailed")?;
    if root
        .read(DOCUMENT, LIMIT)
        .map_err(|_| "recommission.allocationReadbackFailed")?
        != bytes
    {
        return Err("recommission.allocationReadbackMismatch".into());
    }
    Ok(())
}

impl JobStore {
    /// A retained unknown Session is continuous only when it is the exact
    /// published copy owned by the source Job. Admission may account for that
    /// one source; ordinary mutations require its completed supersession.
    pub(crate) fn recommission_session_accounted(
        &self,
        session_path: &std::path::Path,
        manifest: &[u8],
        journal: &[u8],
        requested: Option<(&str, &str)>,
    ) -> bool {
        let prove = || -> Option<()> {
            let document: serde_json::Value = arkdeck_contract::strict_json(manifest).ok()?;
            let id = document["jobId"].as_str()?;
            let record = crate::JobRecord::decode(&self.record_bytes(id).ok()?).ok()?;
            let marker = record.session_publication()?;
            let expected = std::path::Path::new(marker["root"]["path"].as_str()?)
                .join(marker["relativeSessionPath"].as_str()?);
            if expected.canonicalize().ok()? != session_path.canonicalize().ok()?
                || marker["receipt"]["manifestSHA256"] != sha256_hex(manifest)
                || journal.is_empty()
                || !self.journal_bytes(id).ok()?.starts_with(journal)
            {
                return None;
            }
            let identity = record.materialized_identity()?;
            if let Some((source, now)) = requested {
                if id != source {
                    return None;
                }
                self.recommission_source(id, identity, now).ok()?;
            } else {
                let ledger = load(&self.root).ok()?;
                let entry = ledger
                    .allocations
                    .iter()
                    .find(|entry| entry.allocation.source_job_id == id)?;
                let chain = &entry.allocation.identity_chain;
                if verified_identity_chain(&self.path, &chain.target_id, identity).ok()?? != *chain
                {
                    return None;
                }
            }
            Some(())
        };
        prove().is_some()
    }

    pub(crate) fn recommission_source_execution(
        &self,
        id: &str,
    ) -> Result<arkdeck_provider_arkforge::Execution, String> {
        let state = self
            .arkforge_state(id)
            .map_err(|_| "recommission.sourceProviderStateUnreadable")?;
        let execution = state
            .execution
            .ok_or("recommission.sourceProviderExecutionMissing")?;
        let record = self
            .read_snapshot(id)
            .map_err(|_| "recommission.sourceUnreadable")?;
        if state.completion.is_some()
            || execution.arkdeck_job_id != id
            || execution.daemon_job_id.is_empty()
            || Some(execution.stable_identity_sha256.as_str()) != record.materialized_identity()
            || Some(execution.binding_revision) != record.materialized_binding()
            || record.request["target"]["targetId"] != execution.target_id
            || !digest(&execution.plan_sha256)
            || !digest(&execution.toolchain_sha256)
        {
            return Err("recommission.sourceProviderCorrelationInvalid".into());
        }
        Ok(execution)
    }
    pub(crate) fn publish_recommission_binding(
        &self,
        targets: &crate::TargetStore,
        chain: &IdentityChain,
    ) -> Result<(), String> {
        publish_identity_lineage(&self.path, targets, chain)
    }
    /// Closed source eligibility. No mutation of the historical Job, journal,
    /// publication marker, budget or capability lineage occurs here.
    pub(crate) fn recommission_source(
        &self,
        id: &str,
        identity: &str,
        now: &str,
    ) -> Result<String, String> {
        if !super::identifier(id) || self.holds_resident(id) {
            return Err("recommission.sourceUnavailable".into());
        }
        let bytes = self
            .record_bytes(id)
            .map_err(|_| "recommission.sourceUnreadable")?;
        let record =
            crate::JobRecord::decode(&bytes).map_err(|_| "recommission.sourceUnreadable")?;
        let (facts, events) = crate::rockchip_startup::journal(&self.jobs_path().join(id))?;
        if record.state != "interrupted"
            || !record.dayu200_flash()
            || record.operation() == OPERATION
            || record.materialized_identity() != Some(identity)
            || record.materialized_binding() != Some(1)
            || !facts.retained_risk_archive
            || facts.pending_abandonment.is_some()
            || !facts.finalized
            || !crate::job_archive::retains_capability_lineage(&record, &facts, &events, now)
            || record.session_publication().is_none_or(|marker| {
                marker["phase"] != "catalogPublished"
                    || marker["receipt"]["manifestSHA256"]
                        .as_str()
                        .is_none_or(|value| !digest(value))
            })
        {
            return Err("recommission.sourceNotExpiredPublishedRetainedArchive".into());
        }
        self.recommission_source_execution(id)?;
        let marker = record
            .session_publication()
            .ok_or("recommission.archiveMissing")?;
        let manifest = published_manifest(marker, id)?;
        if manifest["jobId"] != id
            || manifest["status"] != "interrupted"
            || manifest["outcomeCertainty"] != "outcomeUnknown"
            || !events.iter().any(|event| {
                event["kind"] == "finalized"
                    && event["payload"]["manifestSha256"] == marker["receipt"]["manifestSHA256"]
            })
        {
            return Err("recommission.archiveManifestMismatch".into());
        }
        source_digest(&self.root, id)
    }

    /// Admission calls this under the Job admission interlock, after complete
    /// identity/coverage/materialization checks. The ledger lock also serializes
    /// distinct Runtime clients. A failed later admission cannot refund it.
    pub(crate) fn reserve_recommission(
        &self,
        mut candidate: Allocation,
        now: &str,
    ) -> Result<Allocation, String> {
        let now = clock_millis(now).ok_or("recommission.clockUnavailable")?;
        candidate.reserved_at_epoch_ms = now;
        candidate.expires_at_epoch_ms = now
            .checked_add(BUDGET_MS)
            .ok_or("recommission.clockUnavailable")?;
        candidate.validate()?;
        let _guard = self
            .root
            .wait_lock(LOCK, false)
            .map_err(|_| "recommission.ledgerBusy")?;
        let mut ledger = load(&self.root)?;
        if let Some(entry) = ledger.allocations.iter_mut().find(|entry| {
            entry.allocation.identity_chain.normal_identity_sha256
                == candidate.identity_chain.normal_identity_sha256
        }) {
            candidate.reserved_at_epoch_ms = entry.allocation.reserved_at_epoch_ms;
            candidate.expires_at_epoch_ms = entry.allocation.expires_at_epoch_ms;
            if entry.allocation != candidate || entry.consumed {
                return Err("recommission.independentEpochAlreadyAllocated".into());
            }
            let budget = entry.check_budget(now);
            let allocation = entry.allocation.clone();
            persist(&self.root, &ledger)?;
            budget?;
            return Ok(allocation);
        }
        ledger.allocations.push(Entry {
            allocation: candidate.clone(),
            consumed: false,
            postflight: None,
            last_observed_epoch_ms: now,
            budget_closed: false,
        });
        persist(&self.root, &ledger)?;
        Ok(candidate)
    }

    /// One-way consume precedes capability consume and Provider preparation.
    /// A crash in between burns the allocation and leaves all risks held.
    pub(crate) fn consume_recommission(
        &self,
        allocation: &Allocation,
        now: &str,
    ) -> Result<(), String> {
        let now = clock_millis(now).ok_or("recommission.clockUnavailable")?;
        allocation.validate()?;
        let _guard = self
            .root
            .wait_lock(LOCK, false)
            .map_err(|_| "recommission.ledgerBusy")?;
        let mut ledger = load(&self.root)?;
        let entry = ledger
            .allocations
            .iter_mut()
            .find(|entry| entry.allocation == *allocation)
            .ok_or("recommission.exactAllocationMissing")?;
        if entry.consumed {
            return Err("recommission.independentEpochAlreadyConsumed".into());
        }
        if let Err(error) = entry.check_budget(now) {
            persist(&self.root, &ledger)?;
            return Err(error);
        }
        entry.consumed = true;
        persist(&self.root, &ledger)
    }

    /// This is reached only after the Provider's complete-plan receipt and a
    /// fresh, independently repeated Normal observation. The old records are
    /// rehashed again before the new proof becomes durable.
    pub(crate) fn record_recommission_postflight(
        &self,
        allocation: &Allocation,
        facts: &RockchipFacts,
        now: &str,
    ) -> Result<(), String> {
        let time = clock_millis(now).ok_or("recommission.clockUnavailable")?;
        let chain = IdentityChain::from_facts(facts)?;
        if chain != allocation.identity_chain
            || self.recommission_source(
                &allocation.source_job_id,
                &chain.normal_identity_sha256,
                now,
            )? != allocation.source_sha256
        {
            return Err("recommission.postflightOrHistoryDrifted".into());
        }
        let observation = facts
            .server_facts
            .get("dayu200RecommissionObservationSHA256")
            .filter(|value| digest(value))
            .ok_or("recommission.postflightObservationMissing")?;
        let _guard = self
            .root
            .wait_lock(LOCK, false)
            .map_err(|_| "recommission.ledgerBusy")?;
        let mut ledger = load(&self.root)?;
        let entry = ledger
            .allocations
            .iter_mut()
            .find(|entry| entry.allocation == *allocation && entry.consumed)
            .ok_or("recommission.consumedAllocationMissing")?;
        if let Err(error) = entry.check_budget(time) {
            persist(&self.root, &ledger)?;
            return Err(error);
        }
        if entry.postflight.is_none() {
            entry.postflight = Some(Postflight {
                identity_chain_sha256: chain.sha256(),
                observation_sha256: observation.clone(),
                confirmed_at_epoch_ms: time,
            });
            persist(&self.root, &ledger)?;
        }
        Ok(())
    }

    pub(crate) fn require_recommission_postflight(
        &self,
        allocation: &Allocation,
    ) -> Result<(), String> {
        if source_digest(&self.root, &allocation.source_job_id)? != allocation.source_sha256 {
            return Err("recommission.historicalBytesDrifted".into());
        }
        let _guard = self
            .root
            .wait_lock(LOCK, false)
            .map_err(|_| "recommission.ledgerBusy")?;
        let ledger = load(&self.root)?;
        if !ledger.allocations.iter().any(|entry| {
            entry.allocation == *allocation && entry.consumed && entry.postflight.is_some()
        }) {
            return Err("recommission.durablePostflightMissing".into());
        }
        Ok(())
    }
}

fn source_digest(root: &HostDirectory, id: &str) -> Result<String, String> {
    let failed = |_| "recommission.sourceDigestUnavailable".to_owned();
    let job = root
        .child("jobs")
        .and_then(|jobs| jobs.child(id))
        .map_err(failed)?;
    let record = job
        .read_without_repair("job-record.json", LIMIT)
        .map_err(failed)?;
    let journal = job
        .read_without_repair("journal.jsonl", LIMIT)
        .map_err(failed)?;
    let provider = job
        .read_without_repair(super::arkforge_job_state::FILE, LIMIT)
        .map_err(failed)?;
    Ok(sha256_hex(
        &serde_json::to_vec(&json!({
            "recordSHA256": sha256_hex(&record), "journalSHA256": sha256_hex(&journal),
            "providerStateSHA256": sha256_hex(&provider),
        }))
        .map_err(|_| "recommission.sourceDigestUnavailable")?,
    ))
}

/// The receipt must still name the same private Session root and immutable
/// Manifest. Caller paths are never inputs to this read.
fn published_manifest(marker: &serde_json::Value, job: &str) -> Result<serde_json::Value, String> {
    let missing = || "recommission.publishedArchiveUnverifiable".to_owned();
    let root = published_root(std::path::Path::new(
        marker["root"]["path"].as_str().ok_or_else(missing)?,
    ))
    .map_err(|_| missing())?;
    let facts = root.export_facts().map_err(|_| missing())?;
    if marker["root"]["device"].as_str() != Some(facts.device.to_string().as_str())
        || marker["root"]["inode"].as_str() != Some(facts.inode.to_string().as_str())
        || marker["root"]["volumeIdentity"] != facts.volume_identity
    {
        return Err(missing());
    }
    let relative = marker["relativeSessionPath"].as_str().ok_or_else(missing)?;
    let parts: Vec<_> = relative.split('/').collect();
    if parts.len() != 3
        || parts[0].len() != 4
        || parts[1].len() != 2
        || !parts[..2]
            .iter()
            .all(|part| part.bytes().all(|byte| byte.is_ascii_digit()))
        || parts[2] != format!("session-{job}")
    {
        return Err(missing());
    }
    let session = root
        .child(parts[0])
        .and_then(|root| root.child(parts[1]))
        .and_then(|root| root.child(parts[2]))
        .map_err(|_| missing())?;
    let bytes = session
        .read_without_repair("manifest.json", LIMIT)
        .map_err(|_| missing())?;
    let hash = sha256_hex(&bytes);
    if marker["receipt"]["manifestSHA256"] != hash || marker["proposal"]["manifestSHA256"] != hash {
        return Err(missing());
    }
    serde_json::from_slice(&bytes).map_err(|_| missing())
}

#[cfg(windows)]
fn published_root(path: &std::path::Path) -> std::io::Result<HostDirectory> {
    HostDirectory::open(path)
}

/// Invert only SessionPublisher's `/private` shortening. The long spelling
/// must itself pass the canonical, no-link private-directory check, and the
/// recorded spelling must still name that same directory. The receipt's
/// device/inode/volume pins are checked against the held root by the caller.
#[cfg(target_os = "macos")]
fn published_root(path: &std::path::Path) -> std::io::Result<HostDirectory> {
    use std::os::unix::fs::MetadataExt;
    HostDirectory::open(path).or_else(|error| {
        let Some(short) = path
            .to_str()
            .filter(|text| text.starts_with('/') && !text.starts_with("/private/"))
        else {
            return Err(error);
        };
        let canonical = std::path::PathBuf::from(format!("/private{short}"));
        let root = HostDirectory::open(&canonical)?;
        let facts = root.export_facts()?;
        let alias = std::fs::metadata(path)?;
        if !alias.is_dir()
            || u64::from(alias.dev() as u32) != facts.device
            || alias.ino() != facts.inode
        {
            return Err(error);
        }
        Ok(root)
    })
}

/// A consumed allocation alone never grants a reusable identity mapping. The
/// separate successful recovery epoch must match every material pin. Reading
/// the relation is idempotent, including after a crash before terminal projection.
pub(crate) fn verified_identity_chain(
    state: &std::path::Path,
    target: &str,
    identity: &str,
) -> Result<Option<IdentityChain>, String> {
    let root = HostDirectory::open(state).map_err(|_| "recommission.stateUnavailable")?;
    let ledger = {
        let _guard = root
            .wait_lock(LOCK, false)
            .map_err(|_| "recommission.ledgerBusy")?;
        load(&root)?
    };
    let Some(entry) = ledger.allocations.into_iter().find(|entry| {
        entry.allocation.identity_chain.target_id == target
            && (entry.allocation.identity_chain.normal_identity_sha256 == identity
                || entry.allocation.identity_chain.loader_serial_sha256 == identity)
    }) else {
        return Ok(None);
    };
    if !entry.consumed || entry.postflight.is_none() {
        return Ok(None);
    }
    let allocation = &entry.allocation;
    if source_digest(&root, &allocation.source_job_id)? != allocation.source_sha256 {
        return Err("recommission.historicalBytesDrifted".into());
    }
    let epochs = crate::recovery_epoch::list_recovery_epochs(&root)
        .map_err(|_| "recommission.recoveryEpochUnreadable")?;
    let established = epochs.iter().any(|epoch| {
        let draft = &epoch.draft;
        draft.operation_reference == OPERATION
            && draft.recovery_job_id == allocation.recovery_job_id
            && draft.stable_target_identity_sha256
                == allocation.identity_chain.normal_identity_sha256
            && draft.binding_revision == allocation.identity_chain.binding_revision
            && draft.materialized_plan_digest_sha256 == allocation.materialized_plan_sha256
            && draft.artifact_sha256 == allocation.artifact_sha256
            && draft.provider_executable_sha256 == allocation.identity_chain.provider_sha256
            && draft.uncertain_effect_set_sha256 == allocation.uncertain_effect_set_sha256
            && !draft.covered_intents.is_empty()
            && draft
                .covered_intents
                .iter()
                .all(|intent| intent.job_id == allocation.source_job_id)
    });
    Ok(established.then_some(entry.allocation.identity_chain))
}

pub(crate) fn publish_identity_lineage(
    state: &std::path::Path,
    targets: &crate::TargetStore,
    chain: &IdentityChain,
) -> Result<(), String> {
    let verified = verified_identity_chain(state, &chain.target_id, &chain.normal_identity_sha256)?;
    if verified.as_ref() != Some(chain) {
        return Err("recommission.successfulRecoveryEpochRequired".into());
    }
    targets.advance_binding_lineage_for_target(
        &crate::rockchip_binding::LineageAdvance {
            previous_identity_sha256: chain.normal_identity_sha256.clone(),
            previous_revision: chain.binding_revision,
            current_identity_sha256: chain.loader_serial_sha256.clone(),
            current_revision: chain.binding_revision + 1,
        },
        Some(&chain.target_id),
    )?;
    Ok(())
}

pub(crate) fn verified_recovery_job(
    state: &std::path::Path,
    chain: &IdentityChain,
) -> Result<String, String> {
    if verified_identity_chain(state, &chain.target_id, &chain.normal_identity_sha256)?.as_ref()
        != Some(chain)
    {
        return Err("recommission.successfulRecoveryEpochRequired".into());
    }
    let root = HostDirectory::open(state).map_err(|_| "recommission.stateUnavailable")?;
    let _guard = root
        .wait_lock(LOCK, false)
        .map_err(|_| "recommission.ledgerBusy")?;
    load(&root)?
        .allocations
        .into_iter()
        .find(|entry| entry.allocation.identity_chain == *chain)
        .map(|entry| entry.allocation.recovery_job_id)
        .ok_or_else(|| "recommission.consumedAllocationMissing".into())
}

pub(crate) fn reconcile_bindings(
    state: &std::path::Path,
    targets: &crate::TargetStore,
) -> Result<(), String> {
    let root = HostDirectory::open(state).map_err(|_| "recommission.stateUnavailable")?;
    // Startup precedes the first Job index. An absent ledger has no lineage
    // to reconcile and must not create a lock in that pristine repository.
    match root.owned_kind_and_size(DOCUMENT) {
        Err(error) if error.kind() == std::io::ErrorKind::NotFound => return Ok(()),
        Ok((arkdeck_platform::HostEntryKind::Regular, size)) if size <= LIMIT as u64 => (),
        _ => return Err("recommission.allocationLedgerUnreadable".into()),
    }
    let ledger = {
        let _guard = root
            .wait_lock(LOCK, false)
            .map_err(|_| "recommission.ledgerBusy")?;
        load(&root)?
    };
    for entry in ledger.allocations {
        let chain = &entry.allocation.identity_chain;
        if entry.consumed
            && entry.postflight.is_some()
            && verified_identity_chain(state, &chain.target_id, &chain.normal_identity_sha256)?
                .is_some()
        {
            publish_identity_lineage(state, targets, chain)?;
        }
    }
    Ok(())
}

#[cfg(test)]
#[path = "flash_recommission/tests.rs"]
mod tests;
