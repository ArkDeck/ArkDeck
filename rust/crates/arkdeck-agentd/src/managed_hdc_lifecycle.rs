//! The managed host's confirmed restart chain. The durable control-action
//! owner supplies the approved scope and holds Job admission frozen. This
//! driver alone prepares and runs the typed lifecycle command; no RPC accepts
//! a command, audit, Supervisor state or replacement process identity.
use super::*;
use arkdeck_contract::{WireError, canonical_json, sha256_hex};
use arkdeck_hoststore::{HdcLifecycleAudit, HdcLifecycleDriver, ImpactReading};
use arkdeck_provider_hdc::{
    LifecycleAction, LifecycleBudget, LifecycleCommand, LifecycleOutcome, PostDispatchObservation,
    PreparedLifecycle,
};
use serde_json::json;

fn failure(code: &str, message: impl Into<String>) -> WireError {
    WireError {
        code: code.into(),
        message: message.into(),
        details: None,
    }
}
fn drift(message: impl Into<String>) -> WireError {
    failure("factsDrifted", message)
}
fn uuid() -> Result<String, WireError> {
    let mut bytes = arkdeck_platform::random_bytes::<16>()
        .map_err(|_| failure("internalError", "lifecycle identity is unavailable"))?;
    bytes[6] = (bytes[6] & 15) | 64;
    bytes[8] = (bytes[8] & 63) | 128;
    let hex: String = bytes.iter().map(|b| format!("{b:02x}")).collect();
    Ok(format!(
        "{}-{}-{}-{}-{}",
        &hex[..8],
        &hex[8..12],
        &hex[12..16],
        &hex[16..20],
        &hex[20..]
    ))
}

/// Swift HDCServerImpactSnapshot: fixed canonical fields with the same
/// participant order and other-client interpretation as the approved impact.
struct Scope {
    server: SupervisedServer,
    value: Value,
    hash: String,
    version: Value,
}
impl Scope {
    fn approved(reading: &ImpactReading, endpoint: &str) -> Result<Self, WireError> {
        let impact = reading.impact.value();
        let generation = impact["serverGeneration"]
            .as_str()
            .and_then(|g| g.parse::<i64>().ok())
            .filter(|g| *g > 0)
            .ok_or_else(|| drift("approved HDC generation is unavailable"))?;
        if reading.blocker.is_some()
            || impact["criticalJobGate"]["state"] != "clear"
            || impact["endpoint"] != endpoint
            || impact["serverHealth"] != "healthy"
            || impact["serverOwnership"] != "arkDeckManaged"
            || impact["affectedJobIds"] != json!([])
        {
            return Err(drift(
                "final HDC impact cannot reproduce the managed lifecycle scope",
            ));
        }
        let clients = &impact["detectedOtherClientIds"];
        let kind = if clients.as_array().is_some_and(|c| !c.is_empty()) {
            "detected"
        } else if impact["otherClientsMayExist"] == true {
            "unavailableExternalClientsMayStillExist"
        } else {
            "noneDetectedExternalClientsMayStillExist"
        };
        let value = json!({"schemaVersion":1,"action":"restartConfirmedGeneration",
            "endpoint":endpoint,"generation":generation,"ownership":"arkDeckManaged",
            "affectedDeviceCoordinators":impact["affectedTargetIds"],"affectedJobs":[],
            "otherClientDetection":{"kind":kind,"clients":clients},
            "expectedInterruption":"HDC requests using this endpoint will be interrupted.",
            "recoveryPath":"Re-probe the shared endpoint and reconcile every affected Job."});
        let hash = sha256_hex(
            &canonical_json(&value)
                .map_err(|_| drift("HDC scope cannot be canonically represented"))?,
        );
        Ok(Self {
            server: SupervisedServer {
                endpoint: endpoint.into(),
                healthy: true,
                generation,
                ark_deck_managed: true,
            },
            value,
            hash,
            version: impact["serverVersion"].clone(),
        })
    }
    fn observed(&self, current: Option<&SupervisedServer>) -> Value {
        if current != Some(&self.server) {
            return json!({"action":"restartConfirmedGeneration","endpoint":self.server.endpoint,
                "health":current.map(|s| if s.healthy { "healthy" } else { "unknown" }),
                "version":null,"generation":current.map(|s| s.generation),
                "generationEvidence":current.map(|s| json!({"kind":"known","value":s.generation,"reason":null})),
                "ownership":current.map(|s| if s.ark_deck_managed { "arkDeckManaged" } else { "unknown" }),
                "affectedDeviceCoordinators":self.value["affectedDeviceCoordinators"],"affectedJobs":[],
                "otherClientDetection":self.value["otherClientDetection"],"criticalJobs":[],
                "impactReliable":false,"scopeHash":null});
        }
        let version = if self.version.is_null() {
            json!({"kind":"unknown","value":null,"reason":"server version unavailable"})
        } else {
            json!({"kind":"known","value":self.version,"reason":null})
        };
        json!({"action":"restartConfirmedGeneration","endpoint":self.server.endpoint,
            "health":"healthy","version":version,"generation":self.server.generation,
            "generationEvidence":{"kind":"known","value":self.server.generation,"reason":null},
            "ownership":"arkDeckManaged","affectedDeviceCoordinators":self.value["affectedDeviceCoordinators"],
            "affectedJobs":[],"otherClientDetection":self.value["otherClientDetection"],"criticalJobs":[],
            "impactReliable":true,"scopeHash":self.hash})
    }
}

/// An entered launch window is uncertain unless terminal reconciliation and
/// replacement ownership both complete. Unwinding cannot reopen dispatch.
struct LaunchWindow<'a> {
    managed: &'a ManagedHdc,
    completed: bool,
}
impl Drop for LaunchWindow<'_> {
    fn drop(&mut self) {
        if !self.completed {
            if let Ok(mut ownership) = self.managed.ownership.lock()
                && !matches!(*ownership, DispatchOwnership::Stopped)
            {
                *ownership = DispatchOwnership::Unknown;
            }
            if let Ok(mut state) = self.managed.supervisor.lock()
                && let Some(state) = state.as_mut()
            {
                state.healthy = false;
            }
        }
    }
}

impl HdcLifecycleDriver for ManagedHdc {
    fn restart(
        &self,
        reading: &ImpactReading,
        audit: &HdcLifecycleAudit<'_>,
    ) -> Result<(), WireError> {
        let scope = Scope::approved(reading, self.endpoint())?;
        self.current().map_err(drift)?;
        if self.state(self.endpoint()).as_ref() != Some(&scope.server) {
            return Err(drift(
                "shared HDC Supervisor differs from the approved server identity",
            ));
        }
        let (audit_id, preview_id, confirmation_id, step_id) = (uuid()?, uuid()?, uuid()?, uuid()?);
        let mut preview = scope.value.as_object().unwrap().clone();
        preview.remove("schemaVersion");
        preview.insert("previewId".into(), json!(preview_id));
        preview.insert("scopeHash".into(), json!(scope.hash));
        audit.append("impactPreview", &audit_id, Value::Object(preview))?;
        audit.append("confirmation", &audit_id, json!({"confirmationId":confirmation_id,"previewId":preview_id,
            "action":"restartConfirmedGeneration","endpoint":self.endpoint(),"generation":scope.server.generation,
            "ownership":"arkDeckManaged","scopeHash":scope.hash}))?;
        audit.append("intent", &audit_id, json!({"stepId":step_id,"confirmationId":confirmation_id,
            "action":"restartConfirmedGeneration","endpoint":self.endpoint(),"expectedGeneration":scope.server.generation,
            "expectedOwnership":"arkDeckManaged","impactSnapshotHash":scope.hash}))?;
        // Recheck after durable intent before granting the executor its lease.
        self.current().map_err(drift)?;
        if self.state(self.endpoint()).as_ref() != Some(&scope.server) {
            return Err(drift(
                "shared HDC Supervisor changed after intent persistence",
            ));
        }
        let endpoint = self
            .endpoint()
            .parse()
            .map_err(|_| drift("selected endpoint is unavailable"))?;
        let command = LifecycleCommand::new(LifecycleAction::Restart, endpoint, &self.tool);
        let actual = json!({"stepId":step_id,"executable":command.executable,"argv":command.arguments,"endpoint":self.endpoint()});
        audit.append("actualCommand", &audit_id, actual.clone())?;
        let prepared =
            PreparedLifecycle::prepare(&self.tool, command, scope.server.generation as u64)
                .map_err(|e| {
                    failure(
                        "admissionDenied",
                        format!("HDC lifecycle preparation refused: {e}"),
                    )
                })?;
        let identity = prepared.identity();
        let mut marker = actual.as_object().unwrap().clone();
        marker.extend(json!({"authorizedExecutable":identity.authorized_path,"inodeLaunchPath":identity.inode_launch_path,
            "executableDevice":identity.device.to_string(),"executableInode":identity.inode.to_string(),
            "executableFileSize":identity.file_size,"executableMode":identity.mode.to_string(),"executableSha256":identity.sha256})
            .as_object().unwrap().clone());
        // The marker is durable before this host expects its exact child exit
        // or enters the verified process runner. Freeze ordinary HDC dispatch.
        let mut ownership = self
            .ownership
            .lock()
            .map_err(|_| drift("HDC ownership is unavailable"))?;
        if !matches!(
            *ownership,
            DispatchOwnership::Original | DispatchOwnership::Replacement(_)
        ) || self.state(self.endpoint()).as_ref() != Some(&scope.server)
        {
            return Err(drift("HDC dispatch lease changed before launch"));
        }
        self.revalidate_ownership(&ownership).map_err(drift)?;
        audit.append("launchWindowEntered", &audit_id, Value::Object(marker))?;
        *ownership = DispatchOwnership::Pending;
        let expected_exit = self.expect_confirmed_exit();
        drop(ownership);
        let mut window = LaunchWindow {
            managed: self,
            completed: false,
        };
        expected_exit.map_err(drift)?;
        let receipt = prepared.launch(&LifecycleBudget::default());
        let mut replacement = None;
        let mut outcome = match receipt.outcome {
            LifecycleOutcome::Succeeded {
                resulting_generation,
            } => {
                // Keep the exact new identity, not merely a numeric generation
                // or a process found later at this port.
                match LoopbackServerLease::acquire(&self.tool, endpoint) {
                    Ok(lease)
                        if generation(lease.identity()) == Some(resulting_generation)
                            && resulting_generation > scope.server.generation as u64
                            && i64::try_from(resulting_generation).is_ok() =>
                    {
                        replacement = Some(lease);
                        json!({"result":"succeeded","resultingGeneration":resulting_generation,"reason":null})
                    }
                    _ => {
                        unknown("replacement HDC identity changed before lifecycle reconciliation")
                    }
                }
            }
            LifecycleOutcome::OutcomeUnknown(reason) => unknown(&reason),
            LifecycleOutcome::Stopped => {
                unknown("restart did not establish a newer HDC generation")
            }
        };
        if self.state(self.endpoint()).as_ref() != Some(&scope.server) {
            outcome = unknown("server state changed before lifecycle outcome reconciliation");
        }
        audit.append(
            "outcome",
            &audit_id,
            json!({"stepId":step_id,"outcome":outcome}),
        )?;
        let mut ownership = self
            .ownership
            .lock()
            .map_err(|_| drift("HDC ownership is unavailable"))?;
        let mut state = self
            .supervisor
            .lock()
            .map_err(|_| drift("HDC Supervisor is unavailable"))?;
        let matches = state.as_ref() == Some(&scope.server)
            && matches!(*ownership, DispatchOwnership::Pending);
        let known = outcome["result"] == "succeeded"
            && matches
            && self.tool.revalidate().is_ok()
            && replacement.as_ref().is_some_and(|l| l.revalidate().is_ok());
        let reason = if known {
            "durable lifecycle outcome reconciled against unchanged supervisor scope"
        } else if outcome["result"] == "outcomeUnknown" {
            "entered lifecycle launch window has an uncertain external effect"
        } else {
            "server state changed during durable lifecycle outcome persistence"
        };
        let outward = if known || outcome["result"] == "outcomeUnknown" {
            outcome.clone()
        } else {
            unknown(reason)
        };
        let observation = match receipt.observation {
            Some(PostDispatchObservation::Generation(g)) => {
                json!({"kind":"generation","generation":g})
            }
            Some(PostDispatchObservation::Unavailable) => {
                json!({"kind":"unavailable","generation":null})
            }
            None => json!({"kind":"missing","generation":null}),
        };
        audit.append("reconciliation", &audit_id, json!({"reconciliationId":uuid()?,"stepId":step_id,
            "expectedScopeHash":scope.hash,"historicalOutcome":outcome,"outwardOutcome":outward,
            "postDispatchObservation":observation,"requiresReconcile":!known,"reason":reason,"observedScope":scope.observed(state.as_ref())}))?;
        if known {
            let lease = replacement.take().unwrap();
            *state = Some(SupervisedServer {
                generation: i64::try_from(generation(lease.identity()).unwrap())
                    .map_err(|_| drift("replacement generation is unrepresentable"))?,
                ..scope.server
            });
            *ownership = DispatchOwnership::Replacement(lease);
        } else {
            if let Some(state) = state.as_mut() {
                state.healthy = false;
            }
            if !matches!(*ownership, DispatchOwnership::Stopped) {
                *ownership = DispatchOwnership::Unknown;
            }
        }
        window.completed = true;
        Ok(())
    }
}
fn unknown(reason: &str) -> Value {
    json!({"result":"outcomeUnknown","resultingGeneration":null,"reason":reason})
}
