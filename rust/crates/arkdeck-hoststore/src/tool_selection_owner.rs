//! The production tool-selection coordinator. Only Runtime composition supplies
//! registry, impact and lifecycle ports; no RPC accepts a driver or audit facts.
use super::*;
use crate::{ImpactReading, ImpactSource, OwnerContext};
use arkdeck_bootstrap::{
    DurableSelectionOutcome, SelectionCandidate, StartupSelection, ToolRegistryStore,
};
use arkdeck_platform::HostDirectory;

/// The existing bootstrap ledger, separated for deterministic failure fixtures.
pub trait ToolSelectionRegistry: Send + Sync {
    fn candidate(
        &self,
        tool: &str,
        generation: u64,
        pending: Option<&str>,
    ) -> Result<SelectionCandidate, WireError>;
    fn prepare(
        &self,
        action: &str,
        tool: &str,
        generation: u64,
    ) -> Result<StartupSelection, WireError>;
    fn fail(&self, action: &str, reason: &str) -> Result<(), WireError>;
    fn outcome(&self, action: &str) -> Result<DurableSelectionOutcome, WireError>;
    fn acknowledge(&self, action: &str) -> Result<(), WireError>;
}
impl ToolSelectionRegistry for ToolRegistryStore {
    fn candidate(
        &self,
        tool: &str,
        generation: u64,
        pending: Option<&str>,
    ) -> Result<SelectionCandidate, WireError> {
        self.selection_candidate(tool, &generation.to_string(), pending)
    }
    fn prepare(
        &self,
        action: &str,
        tool: &str,
        generation: u64,
    ) -> Result<StartupSelection, WireError> {
        self.prepare_selection(action, tool, &generation.to_string())?;
        self.startup_selection()?
            .filter(|s| {
                s.pending_action_id.as_deref() == Some(action)
                    && s.tool_ref == tool
                    && s.active_generation == generation
            })
            .ok_or_else(|| {
                record_unreadable("prepared tool selection lost its exact durable executable")
            })
    }
    fn fail(&self, action: &str, reason: &str) -> Result<(), WireError> {
        self.fail_pending_selection(action, reason).map(|_| ())
    }
    fn outcome(&self, action: &str) -> Result<DurableSelectionOutcome, WireError> {
        self.selection_outcome(action)
    }
    fn acknowledge(&self, action: &str) -> Result<(), WireError> {
        self.acknowledge_selection_outcome(action)
    }
}

/// The daemon's identity-bound lifecycle executor. Returning after a launch
/// requests recomposition; the old provider graph must never admit more Jobs.
pub trait ToolSelectionDriver {
    fn restart_selected(
        &self,
        selected: &StartupSelection,
        reading: &ImpactReading,
        audit: &ToolSelectionAudit<'_>,
    ) -> Result<(), WireError>;
}

impl ToolFacts {
    fn registry_projection(source: &Value) -> Result<Self, WireError> {
        let trust = &source["trust"];
        let unavailable = || {
            refused(
                "operationUnavailable",
                "registered candidate lacks a published HDC identity and bounded trust facts",
            )
        };
        if source["schemaVersion"] != "arkdeck.runtime-tool/1"
            || source["kind"] != "hdc"
            || source["platform"] != "macos"
            || trust["registeredIdentity"] != true
            || trust["policy"] != "arkdeck.host-tool-inspection/1"
            || !trust["toolVersion"].is_string()
        {
            return Err(unavailable());
        }
        let profiles = trust["profileReferences"]
            .as_array()
            .ok_or_else(unavailable)?;
        if !profiles.windows(2).all(|w| w[0].as_str() < w[1].as_str()) {
            return Err(record_unreadable(
                "published HDC profile references are not canonical",
            ));
        }
        let optional = |key: &str| {
            trust
                .get(key)
                .filter(|v| optional_text(Some(v), 256))
                .cloned()
                .unwrap_or(Value::Null)
        };
        let value = json!({"toolRef": source["toolRef"], "recordGeneration":source["generation"],
            "contentSHA256":source["contentDigest"],"executableSHA256":source["executableSHA256"],
            "signature":{"state":trust["signature"],"identifier":optional("signingIdentifier"),
                "teamIdentifier":optional("teamIdentifier"),"codeDirectoryIdentitySHA256":trust["codeDirectoryIdentitySHA256"]},
            "version":trust["toolVersion"],"trust":{"policy":"arkdeck.host-tool-inspection/1","registeredIdentity":true,
                "platformTrust":trust.get("platformTrust").cloned().unwrap_or(json!("unverified")),
                "executionAssessment":trust.get("executionAssessment").cloned().unwrap_or(json!("notPerformed")),
                "profileReferences":profiles}});
        Self::parse(value.as_object().ok_or_else(unavailable)?.clone())
    }
}

#[derive(Clone, Debug, PartialEq)]
struct Reading {
    impact: SelectionImpact,
    hdc: ImpactReading,
}

/// Serialized by the union owner's gate, as Swift serializes its actor.
pub struct ToolSelectionActions {
    store: ToolSelectionRecords,
    context: OwnerContext,
    registry: Box<dyn ToolSelectionRegistry>,
}
impl ToolSelectionActions {
    pub fn open(
        directory: &Path,
        context: OwnerContext,
        registry: Box<dyn ToolSelectionRegistry>,
    ) -> io::Result<Self> {
        let root = HostDirectory::open(directory)?;
        root.private_child("records")?;
        root.private_child("snapshots")?;
        Ok(Self {
            store: ToolSelectionRecords::open(&directory.join("records"))?,
            context,
            registry,
        })
    }
    fn clock(&self) -> Result<u64, WireError> {
        (self.context.clock)().ok_or_else(|| {
            refused(
                "orchestrationClockUntrusted",
                "tool-selection time is unavailable",
            )
        })
    }
    fn uuid(&self) -> Result<String, WireError> {
        (self.context.uuid)()
    }
    fn required(&self, id: &str) -> Result<ToolSelectionRecord, WireError> {
        self.store
            .load(id)?
            .ok_or_else(|| refused("resourceNotFound", "control action does not exist"))
    }
    fn save(
        &self,
        old: &ToolSelectionRecord,
        next: ToolSelectionRecord,
    ) -> Result<ToolSelectionRecord, WireError> {
        self.store.replace(&next, old.generation)?;
        Ok(next)
    }
    fn invalidate(
        &self,
        before: &ToolSelectionRecord,
        reason: &str,
        expired: bool,
    ) -> Result<ToolSelectionRecord, WireError> {
        let latest = self.required(&before.id)?;
        if latest.generation != before.generation {
            return Ok(latest);
        }
        self.save(&latest, latest.invalidated(reason, expired, self.clock()?)?)
    }
    fn refresh(&self, record: ToolSelectionRecord) -> Result<ToolSelectionRecord, WireError> {
        if ![
            "observing",
            "previewReady",
            "awaitingImpactApproval",
            "approvalRecorded",
            "dispatchPrepared",
            "blocked",
        ]
        .contains(&record.state.as_str())
        {
            return Ok(record);
        }
        // Preview expiry must not erase a prepared registry transaction's
        // durable pre-launch boundary. Startup must settle it before restoring
        // the old tool; an unreadable ledger also leaves that evidence intact.
        if ["approvalRecorded", "dispatchPrepared"].contains(&record.state.as_str())
            && self.registry.outcome(&record.id)? == DurableSelectionOutcome::Pending
        {
            return Ok(record);
        }
        let now = self.clock()?;
        let (Some(last), Some(expires)) = (time(&record.observed), time(&record.expires)) else {
            return Err(refused(
                "orchestrationClockUntrusted",
                "tool-selection clock moved backwards",
            ));
        };
        if now < last {
            return Err(refused(
                "orchestrationClockUntrusted",
                "tool-selection clock moved backwards",
            ));
        }
        let reason = if now >= expires {
            "controlAction.expired"
        } else if record.epoch != self.context.epoch {
            "controlAction.runtimeRestarted"
        } else {
            return Ok(record);
        };
        self.invalidate(&record, reason, now >= expires)
    }
    fn read(
        &self,
        intent: &ToolSelectionIntent,
        source: &dyn ImpactSource,
        pending: Option<&str>,
    ) -> Result<Reading, WireError> {
        let hdc = source.read_impact().map_err(|_| {
            refused(
                "factsDrifted",
                "tool-selection impact observation is unavailable",
            )
        })?;
        let candidate = self
            .registry
            .candidate(&intent.tool, intent.generation, pending)?;
        let impact = SelectionImpact::new(
            hdc.impact.clone(),
            ToolFacts::registry_projection(&candidate.selection.active_tool)?,
            ToolFacts::registry_projection(&candidate.new_tool)?,
            candidate.selection.active_generation,
        )?;
        Ok(Reading { impact, hdc })
    }
    fn blocker<'a>(reading: &'a Reading, intent: &ToolSelectionIntent) -> Option<&'a str> {
        if reading.impact.generation != intent.generation {
            Some("tool.activeGenerationChanged")
        } else if reading.impact.new.tool != intent.tool {
            Some("tool.candidateChanged")
        } else if !reading.hdc.impact.critical_gate_is_clear() {
            Some("hdc.criticalJobsUnresolved")
        } else if reading.hdc.impact.value()["serverHealth"] != "healthy" {
            Some("hdc.serverHealthUnproven")
        } else {
            reading.hdc.blocker.as_deref()
        }
    }
    fn finish_observation(
        &self,
        before: ToolSelectionRecord,
        source: &dyn ImpactSource,
    ) -> Result<ToolSelectionRecord, WireError> {
        let record = self.refresh(self.required(&before.id)?)?;
        if record.state != "observing" {
            return Ok(record);
        }
        let Ok(reading) = self.read(&record.intent, source, None) else {
            return self.invalidate(&record, "tool.selectionFactsUnavailable", false);
        };
        let latest = self.refresh(self.required(&record.id)?)?;
        if latest.state != "observing" || latest.generation != record.generation {
            return Ok(latest);
        }
        let published = self.save(
            &latest,
            latest.publishing(
                &reading.impact,
                &reading.hdc.relations,
                Self::blocker(&reading, &record.intent),
                self.clock()?,
                &self.uuid()?,
            )?,
        )?;
        if published.state != "previewReady" {
            return Ok(published);
        }
        if self.read(&record.intent, source, None)? != reading {
            return self.invalidate(&published, "tool.selectionPreviewDrifted", false);
        }
        self.save(
            &published,
            published.requesting_impact_approval(self.clock()?, &self.uuid()?, &self.uuid()?)?,
        )
    }
    pub fn select(
        &self,
        fields: &Map<String, Value>,
        source: &dyn ImpactSource,
    ) -> Result<Value, WireError> {
        let intent = ToolSelectionIntent::parse(fields)?;
        let record = if let Some(record) = self.store.load_request(&intent.request)? {
            if record.intent != intent {
                return Err(refused(
                    "idempotencyConflict",
                    "the request identity belongs to a different tool-selection intent",
                ));
            }
            self.refresh(record)?
        } else {
            self.store.begin(
                &intent,
                &self.context.catalog,
                &self.context.epoch,
                self.clock()?,
                &self.uuid()?,
            )?
        };
        Ok(if record.state == "observing" {
            self.finish_observation(record, source)?
        } else {
            record
        }
        .projection())
    }
    pub fn list_records(&self) -> Result<Vec<ToolSelectionRecord>, WireError> {
        self.store
            .list()?
            .into_iter()
            .map(|r| self.refresh(r))
            .collect()
    }
    pub fn show(&self, id: &str, source: &dyn ImpactSource) -> Result<Value, WireError> {
        let record = self.refresh(self.required(id)?)?;
        if record.state == "observing" {
            return Ok(self.finish_observation(record, source)?.projection());
        }
        if record.state != "outcomeUnknown" {
            return Ok(record.projection());
        }
        let next = match self.registry.outcome(id)? {
            DurableSelectionOutcome::Pending => return Ok(record.projection()),
            DurableSelectionOutcome::Succeeded {
                active_tool_ref,
                active_generation,
            } => record.settled(
                "succeeded",
                &active_tool_ref,
                active_generation,
                None,
                self.clock()?,
            )?,
            DurableSelectionOutcome::Failed {
                active_tool_ref,
                active_generation,
                reason_code,
            } => record.settled(
                "failed",
                &active_tool_ref,
                active_generation,
                Some(&reason_code),
                self.clock()?,
            )?,
            DurableSelectionOutcome::Absent => {
                return Err(record_unreadable(
                    "pending tool selection lost its durable registry outcome",
                ));
            }
        };
        let settled = self.save(&record, next)?;
        self.registry.acknowledge(id)?;
        Ok(settled.projection())
    }
    pub(crate) fn human_action_rows(
        &self,
        owner: Option<&str>,
    ) -> Result<Vec<crate::agent_execution::ActionRow>, WireError> {
        if owner.is_some_and(|id| !identifier(id)) {
            return Err(refused("invalidInput", "invalid human-action owner"));
        }
        Ok(self
            .store
            .list()?
            .into_iter()
            .filter(|r| owner.is_none_or(|id| id == r.id))
            .filter_map(|r| {
                let human = r.approval?;
                Some(crate::agent_execution::ActionRow {
                    created: human.value()["createdAt"].as_str()?.into(),
                    id: human.action_id().into(),
                    value: human.projection(),
                })
            })
            .collect())
    }
    pub fn issue_interactive_challenge(
        &self,
        action: &str,
        reference: &str,
    ) -> Result<Value, WireError> {
        let mut rows: Vec<_> = self
            .store
            .list()?
            .into_iter()
            .filter(|r| {
                r.approval.as_ref().is_some_and(|a| {
                    a.action_id() == action && a.value()["resumeReference"] == reference
                })
            })
            .collect();
        if rows.len() != 1 {
            return Err(refused("resourceNotFound", "human action does not exist"));
        }
        let record = self.refresh(rows.remove(0))?;
        if record.state != "awaitingImpactApproval"
            || record
                .approval
                .as_ref()
                .is_none_or(|a| a.status() != "waiting")
        {
            return Err(refused(
                "humanActionExpired",
                "impact approval is no longer waiting",
            ));
        }
        let random = self.uuid()?.replace('-', "").to_ascii_uppercase();
        let challenge = format!(
            "ARKDECK-{}",
            random
                .get(..9)
                .ok_or_else(|| record_unreadable("challenge identity is unavailable"))?
        );
        let next = self.save(
            &record,
            record.issuing_interactive_challenge(&challenge, self.clock()?, &self.uuid()?)?,
        )?;
        let issued = &next.value["interactionChallenge"];
        Ok(
            json!({"schemaVersion":"arkdeck.impact-approval-challenge/1","interactionOrigin":"interactiveConsole",
            "challenge":challenge,"challengeId":issued["challengeId"],"expiresAt":issued["expiresAt"],
            "humanAction":next.approval.as_ref().ok_or_else(|| record_unreadable("interactive challenge was not persisted"))?.projection(),
            "controlAction":next.projection(),"binding":{"controlActionId":issued["controlActionId"],"humanActionId":issued["humanActionId"],
                "previewId":issued["previewId"],"previewDigest":issued["previewDigest"],"generation":issued["controlActionGeneration"]},"newDispatchCount":0}),
        )
    }
    pub fn consume_interactive_challenge(
        &self,
        id: &str,
        reference: &str,
        response: &str,
        jobs: &crate::JobStore,
        source: &dyn ImpactSource,
        driver: &dyn ToolSelectionDriver,
    ) -> Result<Value, WireError> {
        if response.len() != 17
            || !response.starts_with("ARKDECK-")
            || !response[8..]
                .bytes()
                .all(|c| c.is_ascii_digit() || c.is_ascii_uppercase())
        {
            return Err(refused(
                "admissionDenied",
                "interactive tool selection is unavailable",
            ));
        }
        let before = self.refresh(self.required(id)?)?;
        if before.state != "awaitingImpactApproval"
            || before
                .approval
                .as_ref()
                .is_none_or(|a| a.value()["resumeReference"] != reference)
            || before.challenge.is_none()
        {
            return Err(refused(
                "humanActionExpired",
                "impact approval is no longer awaiting this challenge",
            ));
        }
        let interlock = jobs.acquire_hdc_lifecycle_interlock()?;
        let reading = self.read(&before.intent, source, None)?;
        let latest = self.refresh(self.required(id)?)?;
        if latest.generation != before.generation
            || latest.approval != before.approval
            || latest.challenge != before.challenge
            || latest
                .preview
                .as_ref()
                .is_none_or(|p| p.impact != reading.impact)
            || latest.value["observationRelations"] != json!(reading.hdc.relations)
            || Self::blocker(&reading, &latest.intent).is_some()
        {
            let invalid = self.invalidate(&latest, "tool.selectionPreviewDrifted", false)?;
            return Err(action_error(
                "factsDrifted",
                "fresh tool-selection impact differs before approval",
                &invalid,
            ));
        }
        let approved = self.save(
            &latest,
            latest.recording_interactive_approval(response, self.clock()?, &self.uuid()?)?,
        )?;
        self.save(&approved, approved.prepared(self.clock()?)?)?;
        let audit = ToolSelectionAudit {
            owner: self,
            id,
            source,
            approved: &reading,
            interlock: &interlock,
            entered: std::sync::atomic::AtomicBool::new(false),
        };
        let result = (|| {
            let selected =
                self.registry
                    .prepare(id, &approved.intent.tool, approved.intent.generation)?;
            driver.restart_selected(&selected, &reading.hdc, &audit)?;
            if audit.record()?.state != "outcomeUnknown" {
                return Err(record_unreadable(
                    "selected HDC lifecycle did not enter its durable launch window",
                ));
            }
            Ok(())
        })();
        match result {
            _ if audit.entered() => audit.record().map(|record| record.projection()).map_err(|_| WireError {
                code:"recordUnreadable".into(), message:format!("tool-selection outcome unknown: query control-action {id} after Runtime startup; do not replay the request"), details:None,
            }),
            Ok(()) => Err(record_unreadable("selected HDC lifecycle returned without its durable launch marker")),
            Err(_) => {
                let record = audit.record()?;
                if self.registry.fail(id, "tool.lifecycleFailedBeforeLaunch").is_err()
                    && !matches!(self.registry.outcome(id), Ok(DurableSelectionOutcome::Failed { .. })) {
                    return Err(action_error("recordUnreadable", "pre-launch tool-selection failure could not be settled in the registry; startup reconciliation is required", &record));
                }
                let failed = self.save(&record, record.failed_before_launch("tool.lifecycleFailedBeforeLaunch", self.clock()?)?)?;
                Err(action_error("operationFailed", "tool selection failed before a confirmed lifecycle effect", &failed))
            }
        }
    }
}
fn action_error(code: &str, message: &str, record: &ToolSelectionRecord) -> WireError {
    WireError {
        code: code.into(),
        message: message.into(),
        details: Some(Map::from_iter([(
            "controlAction".into(),
            record.projection(),
        )])),
    }
}

/// Bound audit adapter for the selected executable. Its launch marker freezes
/// the entire old provider graph until process replacement, even on unwind.
pub struct ToolSelectionAudit<'a> {
    owner: &'a ToolSelectionActions,
    id: &'a str,
    source: &'a dyn ImpactSource,
    approved: &'a Reading,
    interlock: &'a crate::HdcLifecycleInterlock<'a>,
    entered: std::sync::atomic::AtomicBool,
}
impl ToolSelectionAudit<'_> {
    pub fn record(&self) -> Result<ToolSelectionRecord, WireError> {
        self.owner.required(self.id)
    }
    pub fn entered(&self) -> bool {
        self.entered.load(std::sync::atomic::Ordering::Acquire)
    }
    pub fn append(&self, kind: &str, audit_id: &str, payload: Value) -> Result<(), WireError> {
        let record = self.record()?;
        let events: Vec<_> = record
            .audit()
            .iter()
            .filter(|e| e.get("auditId").is_some())
            .collect();
        const ORDER: [&str; 7] = [
            "impactPreview",
            "confirmation",
            "intent",
            "actualCommand",
            "launchWindowEntered",
            "outcome",
            "reconciliation",
        ];
        if events.len() >= ORDER.len()
            || ORDER[events.len()] != kind
            || events
                .iter()
                .enumerate()
                .any(|(i, e)| e["kind"] != ORDER[i] || e["auditId"] != audit_id)
            || !crate::hdc_control_action::lifecycle::valid_payload(kind, &payload)
        {
            return Err(record_unreadable(
                "tool-selection lifecycle audit order or payload differs",
            ));
        }
        let hdc = self.approved.hdc.impact.value();
        if kind == "impactPreview"
            && (payload["endpoint"] != hdc["endpoint"]
                || payload["generation"].as_u64()
                    != hdc["serverGeneration"]
                        .as_str()
                        .and_then(|s| s.parse().ok())
                || payload["ownership"] != hdc["serverOwnership"]
                || payload["affectedDeviceCoordinators"] != hdc["affectedTargetIds"]
                || payload["affectedJobs"] != hdc["affectedJobIds"])
        {
            return Err(record_unreadable("tool-selection lifecycle scope differs"));
        }
        if kind == "confirmation"
            && [
                "previewId",
                "action",
                "endpoint",
                "generation",
                "ownership",
                "scopeHash",
            ]
            .iter()
            .any(|k| payload[*k] != events[0]["payload"][*k])
        {
            return Err(record_unreadable(
                "tool-selection lifecycle confirmation differs",
            ));
        }
        if kind == "intent"
            && [
                ("confirmationId", "confirmationId"),
                ("action", "action"),
                ("endpoint", "endpoint"),
                ("expectedGeneration", "generation"),
                ("expectedOwnership", "ownership"),
                ("impactSnapshotHash", "scopeHash"),
            ]
            .iter()
            .any(|(a, b)| payload[*a] != events[1]["payload"][*b])
        {
            return Err(record_unreadable("tool-selection lifecycle intent differs"));
        }
        if events.len() >= 3 && payload["stepId"] != events[2]["payload"]["stepId"] {
            return Err(record_unreadable("tool-selection lifecycle step differs"));
        }
        if kind == "actualCommand" {
            let fresh = self
                .owner
                .read(&record.intent, self.source, Some(self.id))?;
            if fresh.impact != self.approved.impact
                || fresh.hdc.blocker.is_some()
                || payload["endpoint"] != hdc["endpoint"]
            {
                return Err(refused(
                    "factsDrifted",
                    "tool-selection impact changed before durable dispatch authorization",
                ));
            }
        }
        if kind == "launchWindowEntered" {
            let prior = &events[3]["payload"];
            if ["stepId", "executable", "argv", "endpoint"]
                .iter()
                .any(|k| payload[*k] != prior[*k])
                || payload["executableSha256"] != self.approved.impact.new.value["executableSHA256"]
                || payload["inodeLaunchPath"]
                    != json!(format!(
                        "/.vol/{}/{}",
                        payload["executableDevice"].as_str().unwrap_or_default(),
                        payload["executableInode"].as_str().unwrap_or_default()
                    ))
            {
                return Err(record_unreadable(
                    "selected HDC launch identity differs from the approved executable",
                ));
            }
        }
        self.owner.save(
            &record,
            record.appending_lifecycle_audit(
                kind,
                audit_id,
                payload
                    .as_object()
                    .ok_or_else(|| record_unreadable("tool-selection audit payload is malformed"))?
                    .clone(),
                self.owner.clock()?,
            )?,
        )?;
        if kind == "launchWindowEntered" {
            self.interlock.retain_until_restart();
            self.entered
                .store(true, std::sync::atomic::Ordering::Release);
        }
        Ok(())
    }
}

#[cfg(test)]
#[path = "tool_selection_owner_tests.rs"]
mod tests;
