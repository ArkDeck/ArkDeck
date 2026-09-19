//! Swift `HeadlessHDCControlImpactSource`, with `HDCControlServerObserver`
//! (CHG-2026-074, TASK-XPA-014): what a restart of the daemon's managed HDC
//! server would affect, read by the Runtime itself — never from a caller.
//!
//! One reading pins the configured executable and reads its native
//! signature; observes the server at the endpoint (for the registered 3.2.0d
//! executable a `checkserver` between two identity observations proves its
//! health; any other executable's commandless identity proves none); reads
//! the current Jobs and the durable Targets, the devices of a fresh Target
//! observation (`list targets -v` bracketed by the USB relations), then the
//! Targets and Jobs again; observes the server identity once more; and
//! re-proves the executable between the steps. Inventory that changed between
//! its two reads, or a device without a proved relation, leaves the critical
//! Job gate unknown; a server identity that changed leaves no generation,
//! health or version. Any failure leaves the impact unavailable.
//!
//! What needs the kernel, the dispatch or the owners is the source's seam:
//! the daemon composes `CommandlessIdentity`, `NativeSignature`,
//! `SystemManagedProcess`, its development HDC dispatch (the managed server's
//! gate applies to both commands), the Job owner's current Jobs, the Target
//! store and the Target observation owner. No supervisor is composed: the
//! managed launch alone proves ownership.
use crate::hdc_control_action::{Impact, ImpactReading, ImpactSource};
use arkdeck_contract::sha256_hex;
use arkdeck_platform::{ServerIdentityReceipt, VerifiedTool};
use arkdeck_provider_hdc::{
    HdcDispatch, IdentityObservation, IdentityObserver, ManagedLaunch, ManagedProcessVerifier,
    ProcessPlan, Receipt, SignatureInspector, StatusExecutable, UsbRelation, generation,
    published_client_version, server_endpoint_ref,
};
use serde_json::{Value, json};
use std::collections::BTreeSet;
use std::path::Path;
use std::time::Duration;

/// The registered 3.2.0d executable (`HDCReadOnlyProbeRegistry
/// .targetExecutableSHA256`), whose server health `checkserver` proves.
const REGISTERED_3_2_0D: &str = "48395ba8d87115dffca47df2a640a6c868bc9a2bd4eb49611e4138ff88d8d260";
/// `HDCRegisteredGoldenFingerprint.checkserverHealthySHA256`: the exact
/// healthy output of that family, `Client version:Ver: 3.2.0d, server
/// version:Ver: 3.2.0d` and a line feed.
const CHECKSERVER_HEALTHY_SHA256: &str =
    "50e8dfe03cb770dfade5b91198523b964fd3bd6fd8855b541ceb46201f0d014a";
/// The server version that output names.
const CHECKSERVER_HEALTHY_VERSION: &str = "3.2.0d";
/// Swift's registered `checkserver` command budget.
const CHECKSERVER_TIMEOUT: Duration = Duration::from_secs(10);
const CHECKSERVER_CAPTURE: usize = 64 * 1024;

/// One current Job as the critical Job gate reads it (Swift
/// `RuntimeJobStatus`): its state, whether its outcome is unknown and its
/// outstanding cleanup residue.
#[derive(Clone, Debug, PartialEq, Eq)]
pub struct CurrentJob {
    pub job_id: String,
    pub state: String,
    pub outcome_unknown: bool,
    pub residues: i64,
}

/// One device of a Target observation: its observation identity, its
/// candidate state and the USB relation that proved it, if any.
#[derive(Clone, Debug, PartialEq, Eq)]
pub struct DeviceRow {
    pub observation_id: String,
    pub state: String,
    pub relation: Option<UsbRelation>,
}

/// One Target observation snapshot: its fact generation and its devices.
#[derive(Clone, Debug, PartialEq, Eq)]
pub struct DeviceReading {
    pub generation: u64,
    pub rows: Vec<DeviceRow>,
}

/// The impact source of the daemon's managed HDC server.
pub struct ManagedServerImpact<'a> {
    /// The configured executable, by the path it was configured with.
    pub executable: StatusExecutable,
    /// The selected endpoint, as `127.0.0.1:8710` spells it.
    pub endpoint: String,
    /// Swift `activeLaunch()`: the spawn record while the server runs.
    pub launch: &'a dyn Fn() -> Option<ManagedLaunch>,
    pub identity: &'a dyn IdentityObserver,
    pub signature: &'a dyn SignatureInspector,
    pub verifier: &'a dyn ManagedProcessVerifier,
    /// Where the registered `checkserver` runs.
    pub dispatch: &'a dyn HdcDispatch,
    /// Swift `listCurrentJobs()`.
    pub jobs: &'a dyn Fn() -> Result<Vec<CurrentJob>, String>,
    /// Swift `RuntimeTargetStore.list()`: every durable Target record.
    pub targets: &'a dyn Fn() -> Result<Vec<Value>, String>,
    /// Swift `TargetObservationCoordinator.snapshot()`.
    pub devices: &'a dyn Fn() -> Result<DeviceReading, String>,
}

/// Swift `HDCControlServerObservation`.
#[derive(Clone, Debug, PartialEq, Eq)]
struct ServerObservation {
    identity: Option<ServerIdentityReceipt>,
    health: &'static str,
    version: Option<String>,
    reason: Option<&'static str>,
}

/// Swift `classifyCheckserver`'s healthy family: exit 0, nothing on stderr,
/// exactly the registered healthy output.
fn healthy_checkserver(receipt: &Receipt) -> Option<&'static str> {
    (receipt.exit_status == 0
        && receipt.stderr.is_empty()
        && !receipt.truncated
        && sha256_hex(&receipt.stdout) == CHECKSERVER_HEALTHY_SHA256)
        .then_some(CHECKSERVER_HEALTHY_VERSION)
}

/// Swift `jobBlockers`: the current Jobs in identity order, each blocking at
/// no safe boundary, with the recovery its facts call for.
fn blockers(jobs: &[CurrentJob]) -> Vec<Value> {
    let mut jobs = jobs.to_vec();
    jobs.sort_by(|left, right| left.job_id.cmp(&right.job_id));
    jobs.iter()
        .map(|job| {
            let recovery = if job.outcome_unknown {
                "reconcileJob"
            } else if job.residues > 0 {
                "continueCleanup"
            } else {
                "waitForJob"
            };
            json!({"jobId": job.job_id, "stepId": null, "state": job.state,
                "safeBoundary": "blocked", "recovery": recovery})
        })
        .collect()
}

impl ManagedServerImpact<'_> {
    fn observed_identity(&self) -> Option<ServerIdentityReceipt> {
        match self.identity.observe(&self.executable, &self.endpoint) {
            IdentityObservation::Observed { identity, .. } => identity,
            _ => None,
        }
    }

    /// Swift `observeRegisteredExistingServer`: the identity, `checkserver`
    /// in its healthy family, and the same identity again with a
    /// representable generation.
    fn registered_health(&self) -> Option<(ServerIdentityReceipt, &'static str)> {
        let before = self.observed_identity()?;
        let receipt = self
            .dispatch
            .dispatch(&ProcessPlan {
                arguments: vec!["checkserver".into()],
                timeout: CHECKSERVER_TIMEOUT,
                capture_bytes: CHECKSERVER_CAPTURE,
            })
            .ok()?;
        let version = healthy_checkserver(&receipt)?;
        let after = self.observed_identity()?;
        (before == after && generation(&after).is_some()).then_some((after, version))
    }

    /// Swift `HDCControlServerObserver.observe`.
    fn observe_server(&self) -> ServerObservation {
        if self.executable.sha256 == REGISTERED_3_2_0D {
            return match self.registered_health() {
                Some((identity, version)) => ServerObservation {
                    identity: Some(identity),
                    health: "healthy",
                    version: Some(version.into()),
                    reason: None,
                },
                None => ServerObservation {
                    identity: None,
                    health: "unknown",
                    version: None,
                    reason: Some("hdc.registeredHealthObservationUnavailable"),
                },
            };
        }
        match self.identity.observe(&self.executable, &self.endpoint) {
            IdentityObservation::Observed { identity, .. } => ServerObservation {
                identity,
                health: "unknown",
                version: None,
                reason: Some("hdc.serverHealthUnproven"),
            },
            _ => ServerObservation {
                identity: None,
                health: "unknown",
                version: None,
                reason: Some("hdc.serverIdentityUnproven"),
            },
        }
    }

    /// The server's generation and ownership: the stable identity of this
    /// very executable at this endpoint, owned when it is the managed launch,
    /// read the same before and after its verification.
    fn server_facts(
        &self,
        stable: bool,
        server: &ServerObservation,
        launch_before: Option<&ManagedLaunch>,
    ) -> (Value, &'static str) {
        let Some(receipt) = server.identity.as_ref().filter(|receipt| {
            stable
                && receipt.executable_path == Path::new(&self.executable.path)
                && receipt.executable_sha256 == self.executable.sha256
                && receipt.endpoint.to_string() == self.endpoint
        }) else {
            return (Value::Null, "unknown");
        };
        let Some(observed) = generation(receipt) else {
            return (Value::Null, "unknown");
        };
        let managed = launch_before.is_some_and(|launch| {
            (self.launch)().as_ref() == Some(launch)
                && launch.matches(receipt)
                && self.verifier.verifies(receipt, &launch.arguments)
                && (self.launch)().as_ref() == Some(launch)
        });
        (
            json!(observed.to_string()),
            if managed { "arkDeckManaged" } else { "unknown" },
        )
    }
}

impl ImpactSource for ManagedServerImpact<'_> {
    fn endpoint_reference(&self) -> String {
        server_endpoint_ref(&self.endpoint)
    }

    fn read_impact(&self) -> Result<ImpactReading, String> {
        let pinned = VerifiedTool::open(&self.executable.path, &self.executable.sha256)
            .map_err(|error| error.to_string())?;
        let signature = self
            .signature
            .inspect(pinned.path())
            .map_err(|error| error.to_string())?;
        pinned.revalidate().map_err(|error| error.to_string())?;
        let launch_before = (self.launch)();
        let server = self.observe_server();
        pinned.revalidate().map_err(|error| error.to_string())?;
        let jobs = (self.jobs)()?;
        let targets_before = (self.targets)()?;
        let devices = (self.devices)()?;
        let targets_after = (self.targets)()?;
        let jobs_after = (self.jobs)()?;
        let (projection, final_jobs) = (blockers(&jobs), blockers(&jobs_after));
        let inventory_drifted = projection != final_jobs || targets_before != targets_after;
        // Every durable Target, since a disconnected participant can still
        // own affected work; no connect key becomes a Target identity.
        let target_ids: Vec<Value> = targets_after
            .iter()
            .map(|target| target.get("targetID").cloned().unwrap_or(Value::Null))
            .collect();
        let job_ids: BTreeSet<&str> = jobs
            .iter()
            .chain(&jobs_after)
            .map(|job| job.job_id.as_str())
            .collect();
        let revision = devices.generation.to_string();
        let (mut rows, mut relations, mut continuity_missing) = (Vec::new(), Vec::new(), false);
        for row in &devices.rows {
            let (authorization, health) = match row.state.as_str() {
                "Connected" => ("authorized", "connected"),
                "Unauthorized" => ("unauthorized", "unknown"),
                "Offline" => ("unknown", "offline"),
                _ => ("unknown", "unknown"),
            };
            rows.push(
                json!({"observationId": row.observation_id, "generation": revision,
                "authorization": authorization, "health": health}),
            );
            match &row.relation {
                Some(relation) => relations.push(json!({
                    "observationId": row.observation_id, "generation": revision,
                    "serial": relation.serial, "location": relation.location,
                    "attachmentId": relation.attachment_id.to_string(),
                    "vendorId": relation.vendor_id, "productId": relation.product_id,
                })),
                None => continuity_missing = true,
            }
        }
        relations.sort_by(|left, right| {
            let id = |value: &Value| {
                value
                    .get("observationId")
                    .and_then(Value::as_str)
                    .unwrap_or_default()
                    .to_owned()
            };
            id(left).cmp(&id(right))
        });
        let gate_unknown = inventory_drifted || continuity_missing;
        let (state, reason) = if gate_unknown {
            ("unknown", json!("hdc.participantInventoryUnproven"))
        } else if job_ids.is_empty() {
            ("clear", Value::Null)
        } else {
            ("blocked", json!("hdc.currentJobs"))
        };
        let final_identity = self.observed_identity();
        let stable = final_identity == server.identity;
        let (server_generation, ownership) =
            self.server_facts(stable, &server, launch_before.as_ref());
        pinned.revalidate().map_err(|error| error.to_string())?;
        let Value::Object(fields) = json!({
            "serverEndpointRef": server_endpoint_ref(&self.endpoint),
            "endpoint": self.endpoint, "serverOwnership": ownership,
            "serverGeneration": server_generation,
            "serverHealth": if stable { server.health } else { "unknown" },
            "serverVersion": if stable { server.version.clone() } else { None },
            "tool": {
                "reference": null, "executablePath": self.executable.path,
                "source": "runtimeConfiguration", "sha256": self.executable.sha256,
                "signature": signature,
                "version": published_client_version(&self.executable.sha256),
                "trust": "unverified",
            },
            "affectedTargetIds": target_ids, "affectedJobIds": job_ids,
            "detectedOtherClientIds": [], "otherClientsMayExist": true,
            "affectedDeviceObservations": rows,
            "criticalJobGate": {"state": state, "blocking": final_jobs, "reasonCode": reason},
            "interruption": {"kind": "hdcEndpointUnavailable", "affectsAllParticipants": true},
            "recovery": {"kind": "statusThenReconcile", "replayAllowed": false},
        }) else {
            unreachable!("an object literal")
        };
        let impact = Impact::new(fields).map_err(|error| error.message)?;
        Ok(ImpactReading {
            impact,
            relations,
            blocker: Some(if stable {
                server.reason
            } else {
                Some("hdc.serverFactsDrifted")
            })
            .flatten()
            .map(str::to_owned),
        })
    }
}

#[cfg(test)]
#[path = "hdc_impact_source_tests.rs"]
mod tests;
