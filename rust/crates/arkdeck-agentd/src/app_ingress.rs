//! Standalone App composition: device/Runtime discovery, History filters and reads.
//! This is deliberately opt-in on the isolated development owner. It neither
//! activates a LaunchAgent nor changes the installed service. The transport
//! authenticates the actual XPC connection, never an identity in request JSON.
use arkdeck_contract::{
    ContractError, MAX_RESPONSE_BYTES, Request, Response, decode_request, encode_frame,
    strict_json, validate_method_value,
};
use arkdeck_control::{Control, HostServices};
use arkdeck_platform::{HostDirectory, PeerOrigin, listen_mach};
use serde_json::Value;
use std::{ffi::OsStr, io, os::unix::fs::MetadataExt, path::Path, sync::Arc};

const SERVICE: &str = "com.arkdeck.agentd";
// Same policy as AgentXPCContract and the production facade. No caller override.
const APP_REQUIREMENT: &str = "anchor apple generic and certificate leaf[subject.OU] = \"8AQTYW5FKR\" and identifier \"com.arkdeck.desktop\"";

pub(crate) struct Configuration {
    owner_uid: u32,
}
impl Configuration {
    pub(crate) fn from_environment(root: Option<&OsStr>) -> io::Result<Option<Self>> {
        let Some(mode) = std::env::var_os("ARKDECK_APP_INGRESS") else {
            return Ok(None);
        };
        // Pairing is incompatible even if the executable would infer its Swift
        // sibling instead of receiving ARKDECK_SWIFT_DAEMON explicitly.
        if mode != "history" || crate::facade::swift_executable().is_some() {
            return Err(invalid(
                "App ingress requires standalone history composition",
            ));
        }
        if std::env::var_os("CFFIXED_USER_HOME").is_some() {
            return Err(invalid("App ingress cannot override the account home"));
        }
        let root = root.ok_or_else(|| invalid("App ingress requires an isolated state root"))?;
        let home = arkdeck_platform::runtime_home()
            .ok_or_else(|| invalid("account home is unavailable"))?;
        Self::isolated(Path::new(root), Path::new(&home)).map(Some)
    }

    fn isolated(root: &Path, home: &Path) -> io::Result<Self> {
        if !root.is_absolute() || std::fs::symlink_metadata(root)?.file_type().is_symlink() {
            return Err(invalid(
                "App ingress requires an existing physical absolute state root",
            ));
        }
        let physical = root.canonicalize()?;
        let installed = home
            .canonicalize()?
            .join("Library/Application Support/ArkDeck");
        let installed_physical = installed
            .canonicalize()
            .unwrap_or_else(|_| installed.clone());
        if root.starts_with(&installed)
            || physical.starts_with(&installed)
            || physical.starts_with(&installed_physical)
        {
            return Err(invalid("App ingress cannot use installed ArkDeck state"));
        }
        // HostDirectory enforces current owner, private permissions and safe
        // directory traversal. This inspection creates no documents or stores.
        let directory = HostDirectory::open(root)?;
        directory.validate_path(root)?;
        Ok(Self {
            owner_uid: std::fs::metadata(root)?.uid(),
        })
    }

    pub(crate) fn listen<H: HostServices + 'static>(
        self,
        control: Arc<Control<H>>,
    ) -> io::Result<()> {
        let ingress = AppIngress::new(control, self.owner_uid);
        // libxpc installs the fixed code-signing requirement before activating
        // peers and checks their kernel euid. Only its authenticated callback
        // can enter here; PeerOrigin is never decoded from a request.
        listen_mach(
            SERVICE,
            APP_REQUIREMENT,
            Box::new(move |frame, peer| ingress.handle(frame, peer)),
        )
    }
}
fn invalid(message: &str) -> io::Error {
    io::Error::new(io::ErrorKind::InvalidInput, message)
}

struct AppIngress<H: HostServices> {
    control: Arc<Control<H>>,
    owner_uid: u32,
    #[cfg(test)]
    dispatches: std::sync::atomic::AtomicUsize,
}
impl<H: HostServices> AppIngress<H> {
    fn new(control: Arc<Control<H>>, owner_uid: u32) -> Self {
        Self {
            control,
            owner_uid,
            #[cfg(test)]
            dispatches: Default::default(),
        }
    }
    fn handle(&self, frame: &[u8], peer: PeerOrigin) -> Vec<u8> {
        // Defense in depth for transport composition. The signature decision
        // stays inside libxpc; a UID/PID supplied in JSON grants no authority.
        if peer.euid != self.owner_uid || peer.pid <= 1 || peer.foreground_console {
            return refusal(
                "-",
                "rejected",
                "authenticated App transport origin is required",
            );
        }
        let request = match decode_request(frame) {
            Ok(request) => request,
            Err(error) => {
                let code = match error {
                    ContractError::UnsupportedVersion | ContractError::ContractMismatch => {
                        "unsupportedProtocolVersion"
                    }
                    ContractError::UnknownMethod => "unknownMethod",
                    _ => "malformedFrame",
                };
                let id = if matches!(
                    error,
                    ContractError::UnsupportedVersion
                        | ContractError::ContractMismatch
                        | ContractError::UnknownMethod
                ) {
                    strict_json(frame)
                        .ok()
                        .and_then(|value| value["id"].as_str().map(str::to_owned))
                        .unwrap_or_else(|| "-".into())
                } else {
                    "-".into()
                };
                return refusal(
                    &id,
                    code,
                    "App ingress requires the exact current request frame",
                );
            }
        };
        if !matches!(
            request.method.as_str(),
            "health"
                | "operation.list"
                | "target.list"
                | "device.observations"
                | "runtime.hdc.status"
                | "runtime.storage.status"
                | "history.filter.list"
                | "history.filter.save"
                | "history.filter.delete"
                | "job.list"
                | "job.show"
                | "job.timeline"
                | "job.evidence"
                | "artifact.list"
                | "artifact.read"
        ) {
            return refusal(
                &request.id,
                "rejected",
                "method is not available through the standalone App ingress",
            );
        }
        if !closed_parameters(&request) {
            return refusal(
                &request.id,
                "invalidParams",
                "App request requires its complete closed parameters",
            );
        }
        #[cfg(test)]
        self.dispatches
            .fetch_add(1, std::sync::atomic::Ordering::Relaxed);
        // Exactly once, without a retry, response cache or Swift fallback. The
        // owner keeps CAS, query validation and outcomeUnknown semantics.
        self.control.handle_frame(frame)
    }
}
fn closed_parameters(request: &Request) -> bool {
    let params = request.params.clone().unwrap_or_default();
    // Observation references name Runtime-owned snapshots, never caller facts.
    // The broad recorded schema alone also admits retired input shapes.
    if request.method == "device.observations" {
        return params.is_empty()
            || (params.len() == 1
                && params
                    .get("following")
                    .and_then(Value::as_object)
                    .is_some_and(|reference| {
                        arkdeck_hoststore::parse_reference(reference).is_ok()
                    }));
    }
    // Read schemas close every parameter object, including Artifact owner.
    // Resource owners retain defaults, identity/range/cursor validation and
    // sensitive-content admission; this boundary grants no execution authority.
    if matches!(
        request.method.as_str(),
        "job.list"
            | "job.show"
            | "job.timeline"
            | "job.evidence"
            | "artifact.list"
            | "artifact.read"
    ) {
        return validate_method_value(&request.method, "request", &Value::Object(params)).is_ok();
    }
    let keys: &[&str] = match request.method.as_str() {
        "health"
        | "history.filter.list"
        | "operation.list"
        | "target.list"
        | "runtime.hdc.status"
        | "runtime.storage.status" => &[],
        "history.filter.delete" => &["expectedGeneration"],
        "history.filter.save" => &[
            "expectedGeneration",
            "search",
            "status",
            "mode",
            "sessionId",
            "targetId",
            "timeRange",
            "activity",
        ],
        _ => return false,
    };
    params.len() == keys.len()
        && keys.iter().all(|key| params.contains_key(*key))
        && validate_method_value(&request.method, "request", &Value::Object(params)).is_ok()
}
fn refusal(id: &str, code: &str, message: &str) -> Vec<u8> {
    let response = Response::failure(id, code, message).value();
    encode_frame(&response, MAX_RESPONSE_BYTES).expect("bounded App ingress refusal")
}

#[cfg(test)]
mod tests;
