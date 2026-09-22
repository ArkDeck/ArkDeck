//! The existing Swift App Job gate: closed client/operation pairs and one run
//! of a successfully submitted Job. This is not Runtime execution authority.
use arkdeck_contract::{Request, decode_response, strict_json};
use arkdeck_hoststore::OperationRequest;
use serde_json::Value;
use std::{collections::BTreeMap, sync::Mutex};

#[derive(Clone, Copy, Debug, Eq, PartialEq)]
pub(super) enum Kind {
    Flash,
    Trace,
    Logs,
    NativeLibrary,
    Hap,
    Ports,
    Template,
    Screenshot,
    Recording,
    Input,
}
#[derive(Debug, Eq, PartialEq)]
pub(super) enum Action {
    Plan,
    Submit(Kind),
    Run(String),
    Cancel(String),
}

fn kind(text: &str) -> Option<Kind> {
    let request = OperationRequest::decode(text.as_bytes()).ok()?;
    // Even a null/unused authorization member is outside the App boundary.
    let raw = strict_json(text.as_bytes()).ok()?;
    if raw.get("authorization").is_some() || raw.get("campaignReservation").is_some() {
        return None;
    }
    let client = request.client_context.as_ref()?.client_name.as_deref()?;
    let operation = request.operation_id.as_str();
    if client == "ArkDeckApp.FlashWorkspace" {
        return match (operation, request.operation_version) {
            ("flash.full-restore", Some(1)) | ("flash.dayu200", None) => Some(Kind::Flash),
            _ => None,
        };
    }
    if request.operation_version != Some(1) {
        return None;
    }
    Some(match (client, operation) {
        ("ArkDeckApp.TraceWorkspace", "capture.diagnostics") => Kind::Trace,
        ("ArkDeckApp.DebugWorkspace.Logs", "capture.diagnostics") => Kind::Logs,
        ("ArkDeckApp.DebugWorkspace.Artifacts", "deploy.native-library.app-owned") => {
            Kind::NativeLibrary
        }
        ("ArkDeckApp.DebugWorkspace.Apps", "debug.hap") => Kind::Hap,
        ("ArkDeckApp.DebugWorkspace.Network", "port-forward.create" | "port-forward.remove") => {
            Kind::Ports
        }
        ("ArkDeckApp.DebugWorkspace.Commands", "debug.template") => Kind::Template,
        ("ArkDeckApp.Toolkit.DeviceControl", "capture.diagnostics") => Kind::Screenshot,
        ("ArkDeckApp.Toolkit.DeviceControl", "capture.screen-sequence") => Kind::Recording,
        ("ArkDeckApp.Toolkit.DeviceControl", "input.tap" | "input.long-press" | "input.swipe") => {
            Kind::Input
        }
        _ => return None,
    })
}
fn bounded_id(id: &str) -> bool {
    !id.is_empty() && id.chars().count() <= 128
}
impl Action {
    /// None means not a Job lifecycle method; Err means a refused Job request.
    pub(super) fn parse(request: &Request) -> Result<Option<Self>, ()> {
        if !matches!(
            request.method.as_str(),
            "job.plan" | "job.submit" | "job.run" | "job.cancel"
        ) {
            return Ok(None);
        }
        let params = request.params.as_ref().ok_or(())?;
        if params.len() != 1 {
            return Err(());
        }
        Ok(Some(match request.method.as_str() {
            "job.plan" | "job.submit" => {
                let kind = params
                    .get("requestJson")
                    .and_then(Value::as_str)
                    .and_then(kind)
                    .ok_or(())?;
                if request.method == "job.plan" {
                    Self::Plan
                } else {
                    Self::Submit(kind)
                }
            }
            "job.run" | "job.cancel" => {
                let id = params
                    .get("jobId")
                    .and_then(Value::as_str)
                    .filter(|id| bounded_id(id))
                    .ok_or(())?
                    .to_owned();
                if request.method == "job.run" {
                    Self::Run(id)
                } else {
                    Self::Cancel(id)
                }
            }
            _ => unreachable!(),
        }))
    }
}
#[derive(Default)]
struct State {
    runnable: BTreeMap<String, Kind>,
    running: BTreeMap<String, Kind>,
}
#[derive(Default)]
pub(super) struct Gate(Mutex<State>);
impl Gate {
    pub(super) fn record_reply(&self, reply: &[u8], request_id: &str, kind: Kind) -> bool {
        let Ok(response) = decode_response(reply.trim_ascii_end(), request_id, "job.submit") else {
            return false;
        };
        let Ok(result) = response.outcome else {
            return true;
        }; // Refusal grants no ownership.
        let Some(id) = result
            .get("jobId")
            .and_then(Value::as_str)
            .filter(|id| bounded_id(id))
        else {
            return false;
        };
        let Ok(mut state) = self.0.lock() else {
            return false;
        };
        state.runnable.insert(id.to_owned(), kind);
        true
    }
    pub(super) fn begin(&self, id: &str) -> Option<Run<'_>> {
        let mut state = self.0.lock().ok()?;
        if state.running.contains_key(id) {
            return None;
        }
        let kind = state.runnable.remove(id)?;
        state.running.insert(id.to_owned(), kind);
        Some(Run {
            gate: self,
            id: id.to_owned(),
        })
    }
    pub(super) fn owns(&self, id: &str) -> bool {
        self.0
            .lock()
            .is_ok_and(|state| state.runnable.contains_key(id) || state.running.contains_key(id))
    }
}
/// Removing both entries on every return preserves fail-closed one-shot behavior
/// after an unknown receipt or a panicking owner. No Job is adopted after restart.
pub(super) struct Run<'a> {
    gate: &'a Gate,
    id: String,
}
impl Drop for Run<'_> {
    fn drop(&mut self) {
        if let Ok(mut state) = self.gate.0.lock() {
            state.runnable.remove(&self.id);
            state.running.remove(&self.id);
        }
    }
}
