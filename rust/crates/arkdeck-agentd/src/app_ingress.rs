//! Standalone App composition: discovery, History, artifacts, App-owned Import
//! uploads, Trace cache, Debug probe and owned typed Jobs.
//! On the isolated development owner it is an explicit opt-in over an
//! isolated root; the production composition (`production.rs`) composes it
//! over the account's own state root. Neither activates a LaunchAgent nor
//! changes the installed service. The transport authenticates the actual XPC
//! connection, never an identity in request JSON.
use arkdeck_contract::{
    ContractError, MAX_RESPONSE_BYTES, Request, Response, decode_request, encode_frame,
    strict_json, validate_method_value,
};
use arkdeck_control::{Control, HostServices};
use arkdeck_platform::{HostDirectory, PeerOrigin, listen_mach};
use serde_json::Value;
use std::{ffi::OsStr, io, os::unix::fs::MetadataExt, path::Path, sync::Arc};

// Named by path, so that each resolves the same when `tests/spawning` compiles
// this module from its source (a `#[path]` module's children are its
// siblings).
#[path = "app_ingress/imports.rs"]
mod imports;
#[path = "app_ingress/jobs.rs"]
pub(crate) mod jobs;

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

    pub(crate) fn isolated(root: &Path, home: &Path) -> io::Result<Self> {
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

    /// The production composition's App ingress over the account's own
    /// state root: the fixed service Swift's LaunchAgent vends, Swift's
    /// code-signing requirement and the owner's effective UID, exactly as the
    /// isolated ingress has them. Only the isolated-root rule is gone, since
    /// this root is the installed Runtime's; it must still be the owner's
    /// private physical directory.
    pub(crate) fn production(state: &Path) -> io::Result<Self> {
        let directory = HostDirectory::open(state)?;
        directory.validate_path(state)?;
        Ok(Self {
            owner_uid: std::fs::metadata(state)?.uid(),
        })
    }

    pub(crate) fn listen<H: HostServices + 'static>(
        self,
        control: Arc<Control<H>>,
    ) -> io::Result<()> {
        self.listen_with(control, listen_mach)
    }

    /// What `listen` registers through `listen`: the fixed service, the fixed
    /// requirement, and the handler libxpc's authenticated callback enters.
    pub(crate) fn listen_with<H: HostServices + 'static>(
        self,
        control: Arc<Control<H>>,
        listen: impl FnOnce(&str, &str, Handler) -> io::Result<()>,
    ) -> io::Result<()> {
        let ingress = AppIngress::new(control, self.owner_uid);
        // libxpc installs the fixed code-signing requirement before activating
        // peers and checks their kernel euid. Only its authenticated callback
        // can enter here; PeerOrigin is never decoded from a request.
        listen(
            SERVICE,
            APP_REQUIREMENT,
            Box::new(move |frame, peer| ingress.handle(frame, peer)),
        )
    }
}
/// The authenticated callback `listen_mach` enters for each frame.
pub(crate) type Handler = Box<dyn Fn(&[u8], PeerOrigin) -> Vec<u8> + Send + Sync>;
fn invalid(message: &str) -> io::Error {
    io::Error::new(io::ErrorKind::InvalidInput, message)
}

pub(crate) struct AppIngress<H: HostServices> {
    pub(crate) control: Arc<Control<H>>,
    owner_uid: u32,
    jobs: jobs::Gate,
    #[cfg(test)]
    pub(crate) dispatches: std::sync::atomic::AtomicUsize,
}
impl<H: HostServices> AppIngress<H> {
    pub(crate) fn new(control: Arc<Control<H>>, owner_uid: u32) -> Self {
        Self {
            control,
            owner_uid,
            jobs: jobs::Gate::default(),
            #[cfg(test)]
            dispatches: Default::default(),
        }
    }
    pub(crate) fn handle(&self, frame: &[u8], peer: PeerOrigin) -> Vec<u8> {
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
        let job = match jobs::Action::parse(&request) {
            Ok(action) => action,
            Err(()) => {
                return refusal(
                    &request.id,
                    "rejected",
                    "a closed typed App Job request is required",
                );
            }
        };
        if job.is_none()
            && !matches!(
                request.method.as_str(),
                "health"
                    | "operation.list"
                    | "target.list"
                    | "device.observations"
                    | "runtime.hdc.status"
                    | "runtime.storage.status"
                    | "runtime.storage.policy"
                    | "runtime.storage.root"
                    | "history.filter.list"
                    | "history.filter.save"
                    | "history.filter.delete"
                    | "job.list"
                    | "job.show"
                    | "job.timeline"
                    | "job.evidence"
                    | "artifact.list"
                    | "artifact.read"
                    | "artifact.quota"
                    | "artifact.import.begin"
                    | "artifact.import.append"
                    | "artifact.import.abort"
                    | "artifact.import.commit"
                    | "trace.cache.status"
                    | "trace.cache.purge"
                    | "debug.probe"
                    | "trace.probe"
                    | "flash.bootloader-status"
                    | "flash.prerequisites"
                    | "flash.device-access"
                    | "flash.lanePlanPreview"
                    | "flash.bind-current-loader"
            )
        {
            return not_allowlisted(&request.id);
        }
        // Swift's App transport admits a begin only for complete, valid
        // metadata of one of the App's three kinds, before anything reaches
        // the Runtime.
        if request.method == "artifact.import.begin" && !imports::admitted_begin(&request) {
            return not_allowlisted(&request.id);
        }
        if job.is_none() && !closed_parameters(&request) {
            return refusal(
                &request.id,
                "invalidParams",
                "App request requires its complete closed parameters",
            );
        }
        // Retain the one-shot claim across the synchronous owner call, but
        // never hold the gate mutex while executing; a parallel cancel must enter.
        let _run = match &job {
            Some(jobs::Action::Run(id)) => match self.jobs.begin(id) {
                Some(run) => Some(run),
                None => {
                    return refusal(
                        &request.id,
                        "rejected",
                        "Job is not runnable by this App ingress",
                    );
                }
            },
            Some(jobs::Action::Cancel(id)) if !self.jobs.owns(id) => {
                return refusal(
                    &request.id,
                    "rejected",
                    "Job is not owned by this App ingress",
                );
            }
            _ => None,
        };
        #[cfg(test)]
        self.dispatches
            .fetch_add(1, std::sync::atomic::Ordering::Relaxed);
        // Exactly once, without a retry, response cache or Swift fallback. The
        // owner keeps CAS, query validation and outcomeUnknown semantics. The
        // App origin is this authenticated transport's, never the frame's: an
        // Import it begins is App-owned in the owner's own record, so an
        // Import reply (a lost commit receipt included) is returned as the
        // owner wrote it, never recorded, repeated or rewritten here.
        let reply = self.control.handle_app_frame(frame);
        if let Some(jobs::Action::Submit(kind)) = job
            && !self.jobs.record_reply(&reply, &request.id, kind)
        {
            // Submission may have committed. Do not fabricate zero dispatch
            // or retry the owner's response when ownership cannot be retained.
            return refusal(
                &request.id,
                "internalError",
                "App Job ownership could not be recorded",
            );
        }
        reply
    }
}
fn closed_parameters(request: &Request) -> bool {
    let params = request.params.clone().unwrap_or_default();
    // Only complete settings mutations cross this boundary. The existing owner
    // retains generation CAS, quota relationships and filesystem admission.
    if matches!(
        request.method.as_str(),
        "runtime.storage.policy" | "runtime.storage.root"
    ) {
        let positive = |key: &str| canonical_decimal(params.get(key), 1);
        let shape = if request.method == "runtime.storage.policy" {
            params.len() == 4
                && [
                    "expectedGeneration",
                    "totalQuotaBytes",
                    "safetyMarginBytes",
                    "retentionDays",
                ]
                .iter()
                .all(|key| positive(key))
        } else {
            params.len() == 2
                && positive("expectedGeneration")
                && ((params.get("rootPath").is_some_and(Value::is_string)
                    && !params.contains_key("resetToDefault"))
                    || (params.get("resetToDefault") == Some(&Value::Bool(true))
                        && !params.contains_key("rootPath")))
        };
        return shape
            && validate_method_value(&request.method, "request", &Value::Object(params)).is_ok();
    }
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
    // Uploads name only the App's own Import request and generation; the
    // owner resolves binding, bounds and App ownership.
    if imports::METHODS.contains(&request.method.as_str()) {
        return imports::closed(&request.method, &params);
    }
    let keys: &[&str] = match request.method.as_str() {
        // The Trace cache root and the Artifact root are fixed at composition;
        // the App cannot name a path, and the probe cannot carry a command.
        "health"
        | "history.filter.list"
        | "operation.list"
        | "target.list"
        | "runtime.hdc.status"
        | "runtime.storage.status"
        | "artifact.quota"
        | "trace.cache.status"
        | "trace.cache.purge"
        // The App's Flash workspace reads the attached board's disposition,
        // the flashing modes ArkForge sees and one Target's prerequisites for
        // a published profile; none reaches the board or names a path.
        | "flash.bootloader-status"
        | "flash.device-access" => &[],
        "debug.probe" | "trace.probe" => &["targetId"],
        "flash.prerequisites" => &["targetId", "profileReference"],
        // The App previews the lane plan one imported archive would anchor
        // for one Target and profile: a digest names the archive, never a
        // path, topology or plan of the App's own.
        "flash.lanePlanPreview" => &["targetId", "profileReference", "archiveSha256"],
        // The App selects an adopted Target and the revision it saw; every
        // identity and port is read afresh by the Runtime, which writes only
        // its own binding and the Target's lineage.
        "flash.bind-current-loader" => &["targetId", "expectedBindingRevision"],
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
/// A canonical decimal string of at least `minimum` within Int64, as the
/// Runtime spells generations and counts: no sign, no leading zero.
fn canonical_decimal(value: Option<&Value>, minimum: i64) -> bool {
    value.and_then(Value::as_str).is_some_and(|text| {
        text.parse::<i64>()
            .is_ok_and(|number| number >= minimum && number.to_string() == text)
    })
}
fn refusal(id: &str, code: &str, message: &str) -> Vec<u8> {
    let response = Response::failure(id, code, message).value();
    encode_frame(&response, MAX_RESPONSE_BYTES).expect("bounded App ingress refusal")
}
/// Swift's App transport refusing a request outside its allowlist before the
/// Runtime (`AgentXPCEndpoint.responseFrame`): this code and these words,
/// and nothing else, whatever the method.
fn not_allowlisted(id: &str) -> Vec<u8> {
    refusal(
        id,
        "methodNotAllowlisted",
        "Runtime transport refused this request",
    )
}
