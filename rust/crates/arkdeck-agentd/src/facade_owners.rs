//! Host-only stores the macOS facade serves itself (TASK-XPA-012 installed
//! composition). The paired Swift authority is composed without them, so no
//! lock below ever has two processes behind it. Every other method is still
//! forwarded unchanged.
use arkdeck_contract::{ContractError, DeviceObservationsResult, WireError};
use arkdeck_control::{Control, HdcStatus, HostServices};
use serde_json::{Map, Value, json};
use std::{
    path::PathBuf,
    sync::{Mutex, PoisonError},
};

/// Keep in step with Swift `AgentFacadeHostOwnership.methods`, which composes
/// the paired authority without these owners.
pub const LOCAL_METHODS: [&str; 3] = [
    "history.filter.delete",
    "history.filter.list",
    "history.filter.save",
];

pub struct FacadeOwners(Control<StateOwners>);

impl FacadeOwners {
    /// `state` is the paired authority's state directory: the same path the
    /// facade hands to Swift as `--state-dir`, or its installed default.
    pub fn new(state: PathBuf) -> Result<Self, ContractError> {
        Ok(Self(Control::new(StateOwners {
            state,
            history: Mutex::new(()),
        })?))
    }

    /// The reply for a locally owned method; `None` belongs to the paired
    /// authority. The frame is the complete current request without its LF.
    pub fn handle(&self, method: &str, frame: &[u8]) -> Option<Vec<u8>> {
        LOCAL_METHODS
            .contains(&method)
            .then(|| self.0.handle_frame(frame))
    }
}

struct StateOwners {
    state: PathBuf,
    history: Mutex<()>,
}

impl HostServices for StateOwners {
    fn history_filter(
        &self,
        method: &str,
        params: &Map<String, Value>,
    ) -> Result<Value, WireError> {
        // The Swift owner this replaces waited for its lock, so concurrent App
        // and CLI requests to this process queue instead of refusing each
        // other as a foreign owner. Another process holding the lock is still
        // refused. The guard protects no data, so a poisoned one is reusable.
        let _serial = self.history.lock().unwrap_or_else(PoisonError::into_inner);
        // Reopen per request: a replaced or unsafe directory fails that
        // request only, and a repaired one needs no facade restart.
        arkdeck_hoststore::HistoryStore::open(&self.state)
            .map_err(|_| unreadable())?
            .handle(method, params, &crate::host::utc_now())
    }

    fn observed_at(&self) -> String {
        crate::host::utc_now()
    }

    fn hdc_status(&self, deep: bool) -> HdcStatus {
        HdcStatus::unavailable(deep, "hdc.notConfigured")
    }

    fn observations(&self) -> Result<DeviceObservationsResult, WireError> {
        Err(WireError {
            code: "rejected".into(),
            message: "device observations belong to the paired Runtime authority".into(),
            details: None,
        })
    }
}

fn unreadable() -> WireError {
    WireError {
        code: "recordUnreadable".into(),
        message: "History filter storage is unreadable or unsafe".into(),
        details: Some(Map::from_iter([
            ("phase".into(), json!("historyFilterOwner")),
            ("newDispatchCount".into(), json!(0)),
        ])),
    }
}
