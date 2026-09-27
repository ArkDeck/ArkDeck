//! Swift's selected-HDC startup transaction: verify/start before publication,
//! then recover the prior active executable only through the registry ledger.
use arkdeck_hoststore::{
    DurableSelectionOutcome, StartupSelection, ToolRegistryStore, ToolSelectionRecords,
};

pub(crate) trait StartupRegistry {
    fn selection(&self) -> Result<Option<StartupSelection>, String>;
    fn publish(&self, action: &str) -> Result<(), String>;
    fn fail(&self, action: &str, reason: &str) -> Result<(), String>;
    fn outcome(&self, action: &str) -> Result<DurableSelectionOutcome, String>;
    fn acknowledge(&self, action: &str) -> Result<(), String>;
}
impl StartupRegistry for ToolRegistryStore {
    fn acknowledge(&self, action: &str) -> Result<(), String> {
        self.acknowledge_selection_outcome(action)
            .map_err(|e| e.message)
    }
    fn selection(&self) -> Result<Option<StartupSelection>, String> {
        self.startup_selection().map_err(|e| e.message)
    }
    fn publish(&self, action: &str) -> Result<(), String> {
        self.publish_pending_selection(action)
            .map(|_| ())
            .map_err(|e| e.message)
    }
    fn fail(&self, action: &str, reason: &str) -> Result<(), String> {
        self.fail_pending_selection(action, reason)
            .map(|_| ())
            .map_err(|e| e.message)
    }
    fn outcome(&self, action: &str) -> Result<DurableSelectionOutcome, String> {
        self.selection_outcome(action).map_err(|e| e.message)
    }
}

/// `start` owns cleanup (the production value is `Launched`). A failed publish
/// drops that exact server before attempting the prior executable. No server
/// already on an endpoint is adopted, stopped, or treated as a successful start.
pub(crate) fn start_and_settle<T>(
    registry: &dyn StartupRegistry,
    selection: StartupSelection,
    mut start: impl FnMut(&StartupSelection) -> Result<T, String>,
) -> Result<(T, StartupSelection), String> {
    let started = match start(&selection) {
        Ok(started) => started,
        Err(error) => {
            let Some(action) = &selection.pending_action_id else {
                return Err(error);
            };
            let _ = registry.fail(action, "tool.selectedStartupVerificationFailed");
            return restore(registry, &mut start, error);
        }
    };
    let Some(action) = &selection.pending_action_id else {
        return Ok((started, selection));
    };
    match registry.publish(action) {
        Ok(()) => Ok((started, selection)),
        Err(error) => match registry.outcome(action)? {
            DurableSelectionOutcome::Succeeded { .. } => Ok((started, selection)),
            DurableSelectionOutcome::Pending => {
                drop(started);
                registry.fail(action, "tool.selectionPublishFailed")?;
                restore(registry, &mut start, error)
            }
            DurableSelectionOutcome::Failed { .. } => {
                drop(started);
                restore(registry, &mut start, error)
            }
            DurableSelectionOutcome::Absent => Err(error),
        },
    }
}
pub(crate) fn restore<T>(
    registry: &dyn StartupRegistry,
    start: &mut impl FnMut(&StartupSelection) -> Result<T, String>,
    original: String,
) -> Result<(T, StartupSelection), String> {
    let old = registry
        .selection()?
        .filter(|s| s.pending_action_id.is_none())
        .ok_or(original)?;
    start(&old).map(|host| (host, old))
}

/// A prepare without a durable launch must never turn into execution merely
/// because the daemon restarted. Settle its ledger before restoring old HDC.
pub(crate) fn recover_prelaunch(
    registry: &dyn StartupRegistry,
    records: &ToolSelectionRecords,
    selection: StartupSelection,
    now: u64,
) -> Result<StartupSelection, String> {
    let Some(action) = &selection.pending_action_id else {
        return Ok(selection);
    };
    let record = records
        .load(action)
        .map_err(|e| e.message)?
        .ok_or("pending HDC selection lost its durable control action")?;
    if record.value()["intent"]["tool"] != selection.tool_ref
        || record.value()["intent"]["expectedActiveGeneration"]
            .as_str()
            .and_then(|s| s.parse::<u64>().ok())
            != Some(selection.active_generation)
    {
        return Err("pending HDC selection differs from its approved control action".into());
    }
    let events = record.value()["selectionAudit"]
        .as_array()
        .ok_or("pending selection has no audit")?;
    let entered = events.iter().any(|e| e["kind"] == "launchWindowEntered");
    if entered {
        if record.state() != "outcomeUnknown" || record.value()["dispatchCount"] != 1 {
            return Err("pending selection launch record is inconsistent".into());
        }
        return Ok(selection);
    }
    if !["approvalRecorded", "dispatchPrepared", "failed"].contains(&record.state())
        || record.value()["dispatchCount"] != 0
    {
        return Err("pending selection has no proved pre-launch boundary".into());
    }
    let reason = "tool.lifecycleFailedBeforeLaunch";
    if registry.fail(action, reason).is_err()
        && !matches!(
            registry.outcome(action),
            Ok(DurableSelectionOutcome::Failed { .. })
        )
    {
        return Err("pending pre-launch selection could not be settled; no HDC was started".into());
    }
    if record.state() != "failed" {
        let failed = record
            .failed_before_launch(reason, now)
            .map_err(|e| e.message)?;
        records
            .replace(&failed, record.generation())
            .map_err(|e| e.message)?;
    }
    registry.acknowledge(action)?;
    registry
        .selection()?
        .filter(|s| s.pending_action_id.is_none())
        .ok_or("pre-launch selection lost its prior active HDC".into())
}
