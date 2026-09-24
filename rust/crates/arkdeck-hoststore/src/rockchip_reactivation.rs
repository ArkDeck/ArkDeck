//! Swift `RockchipRuntimeBindingReactivationProofSource`
//! (`RockchipBindingReactivationProof.swift`): the proof, recovered only from
//! the Runtime's own typed action records under `Agentd/rockchip-runtime`,
//! that an advanced Target displaced from the singleton Loader binding once
//! carried its retained HDC route at its current revision. It reads; it
//! writes no Runtime state and observes or dispatches nothing.
//!
//! Two independently durable facts are required: a current-revision
//! `wait-for-hdc` intent binding the exact Target, revision, Loader identity
//! and connect key, and a confirmed `observeHDCNormalUSB` reconciliation
//! receipt of the previous revision for that connect key with one USB
//! topology, produced by the same provider executable. Missing, malformed,
//! conflicting or shared records give no proof; an unusable root refuses.
use crate::rockchip_binding::{BindingError, BoundTarget, canonical_sha256, refuse};
use crate::swift_decoding::swift_integer;
use arkdeck_contract::{canonical_json, foundation_path::standardized, sha256_hex};
use serde_json::{Map, Value, json};
use std::collections::BTreeSet;
use std::io::Read;
use std::os::unix::fs::{MetadataExt, OpenOptionsExt};
use std::path::{Path, PathBuf};

/// Swift `maximumEntries`.
const MAXIMUM_ENTRIES: usize = 16_384;
/// Swift `maximumRecordBytes`.
const MAXIMUM_RECORD_BYTES: u64 = 1_048_576;

const INTENT_KEYS: [&str; 9] = [
    "action",
    "actionSHA256",
    "bindingRevision",
    "jobID",
    "providerExecutableSHA256",
    "schemaVersion",
    "stableIdentitySHA256",
    "stepID",
    "targetID",
];
const RECEIPT_KEYS: [&str; 15] = [
    "actionSHA256",
    "bindingRevision",
    "jobID",
    "providerExecutableSHA256",
    "schemaVersion",
    "stableIdentitySHA256",
    "stderrByteCount",
    "stderrSHA256",
    "stdoutByteCount",
    "stdoutSHA256",
    "stdoutTruncated",
    "stepID",
    "subprocessCount",
    "summary",
    "targetID",
];

/// Swift `RockchipBindingReactivationProof`.
#[derive(Clone, Debug, PartialEq, Eq)]
pub struct ReactivationProof {
    pub target_id: String,
    pub binding_revision: i64,
    pub stable_loader_identity_sha256: String,
    pub hdc_connect_key: String,
    pub hdc_identity_sha256: String,
    pub hdc_usb_topology: String,
    pub current_binding_intent_sha256: String,
    pub hdc_route_receipt_sha256: String,
}

/// The source over one root, `…/Agentd/rockchip-runtime`.
pub struct ReactivationProofSource {
    root: PathBuf,
}

/// Swift `IntentRecord`, decoded.
struct Intent {
    schema: String,
    job: String,
    step: String,
    target: String,
    revision: i64,
    identity: String,
    provider: String,
    action_sha256: String,
    kind: String,
    arguments: Map<String, Value>,
}

/// Swift `ReceiptRecord`, decoded.
struct Receipt {
    schema: String,
    job: String,
    step: String,
    target: String,
    revision: i64,
    identity: String,
    provider: String,
    action_sha256: String,
    summary: Map<String, Value>,
    stdout_sha256: String,
    stdout_bytes: i64,
    stderr_sha256: String,
    stderr_bytes: i64,
    truncated: bool,
    subprocesses: i64,
}

impl Receipt {
    /// Swift `matches(_:)`.
    fn matches(&self, intent: &Intent) -> bool {
        self.schema == "1.0.0"
            && self.job == intent.job
            && self.step == intent.step
            && self.target == intent.target
            && self.revision == intent.revision
            && self.identity == intent.identity
            && self.provider == intent.provider
            && self.action_sha256 == intent.action_sha256
    }

    /// Swift `isWellFormed`.
    fn is_well_formed(&self) -> bool {
        let keys: BTreeSet<&str> = self.summary.keys().map(String::as_str).collect();
        canonical_sha256(&self.stdout_sha256)
            && canonical_sha256(&self.stderr_sha256)
            && self.stdout_bytes >= 0
            && self.stderr_bytes >= 0
            && self.subprocesses >= 0
            && !self.truncated
            && keys == BTreeSet::from(["hdcNormalIdentitySha256", "usbState", "usbTopology"])
    }

    fn summary(&self, key: &str) -> Option<&str> {
        self.summary.get(key).and_then(Value::as_str)
    }
}

/// Swift `CurrentRoute`.
struct CurrentRoute {
    connect_key: String,
    topology: Option<String>,
    provider: String,
    intent_sha256: String,
}

/// Swift `ConfirmedRoute`.
struct ConfirmedRoute {
    connect_key: String,
    identity: String,
    topology: String,
    provider: String,
    receipt_sha256: String,
}

impl ReactivationProofSource {
    pub fn new(root: &Path) -> Self {
        Self {
            root: root.to_path_buf(),
        }
    }

    /// Swift `proof(for:)`.
    pub fn proof(
        &self,
        target: &BoundTarget<'_>,
    ) -> Result<Option<ReactivationProof>, BindingError> {
        if target.binding_revision <= 1
            || !canonical_sha256(target.identity_sha256)
            || target.connect_key.is_empty()
        {
            return Ok(None);
        }
        if !self.validate_root_if_present()? {
            return Ok(None);
        }
        let mut current = Vec::new();
        let mut confirmed = Vec::new();
        for job in child_directories(&self.root, |name| name.starts_with("job-"))? {
            let job_id = file_name(&job);
            if let Some((intent, bytes)) = read_intent(&job.join("wait-for-hdc/intent.json"))
                && intent.job == job_id
                && intent.step == "wait-for-hdc"
                && intent.target == target.target_id
                && intent.revision == target.binding_revision
                && intent.identity == target.identity_sha256
                && let Some(route) = current_route(&intent, &bytes)
                && route.connect_key == target.connect_key
            {
                current.push(route);
            }
            let actions = child_directories(&job, |name| {
                name.starts_with("reconcile-enter-loader-mode-")
            })?;
            for action in actions {
                let Some((intent, _)) = read_intent(&action.join("intent.json")) else {
                    continue;
                };
                let connect_key = string(&intent.arguments, "connectKey");
                let Some(connect_key) = connect_key.filter(|_| {
                    intent.job == job_id
                        && intent.step == file_name(&action)
                        && intent.target == target.target_id
                        && intent.revision == target.binding_revision - 1
                        && canonical_sha256(&intent.identity)
                        && intent.kind == "rockchip.observeHDCNormalUSB"
                        && intent.arguments.len() == 1
                }) else {
                    continue;
                };
                if connect_key != target.connect_key || !valid_action_hash(&intent) {
                    continue;
                }
                let Some((receipt, receipt_bytes)) = read_receipt(&action.join("receipt.json"))
                else {
                    continue;
                };
                let identity = sha256_hex(connect_key.as_bytes());
                let (Some("hdc-normal"), Some(observed), Some(topology)) = (
                    receipt.summary("usbState"),
                    receipt.summary("hdcNormalIdentitySha256"),
                    receipt.summary("usbTopology"),
                ) else {
                    continue;
                };
                if !receipt.matches(&intent)
                    || !receipt.is_well_formed()
                    || observed != identity
                    || !topology_text(topology)
                {
                    continue;
                }
                confirmed.push(ConfirmedRoute {
                    connect_key: connect_key.to_owned(),
                    identity,
                    topology: topology.to_owned(),
                    provider: intent.provider.clone(),
                    receipt_sha256: sha256_hex(&receipt_bytes),
                });
            }
        }
        if current.is_empty() || confirmed.is_empty() {
            return Ok(None);
        }
        let providers: BTreeSet<&str> = current.iter().map(|r| r.provider.as_str()).collect();
        let [provider] = providers.into_iter().collect::<Vec<_>>()[..] else {
            return Ok(None);
        };
        // A retained route from an older provider binary is not evidence for
        // this revision, and must not poison a newer exact pair: the current
        // intent's provider anchors the correlation.
        let matching: Vec<&ConfirmedRoute> = confirmed
            .iter()
            .filter(|r| r.provider == provider)
            .collect();
        let current_keys: BTreeSet<&str> = current.iter().map(|r| r.connect_key.as_str()).collect();
        let direct: BTreeSet<&str> = current
            .iter()
            .filter_map(|r| r.topology.as_deref())
            .collect();
        let confirmed_keys: BTreeSet<&str> =
            matching.iter().map(|r| r.connect_key.as_str()).collect();
        let identities: BTreeSet<&str> = matching.iter().map(|r| r.identity.as_str()).collect();
        let topologies: BTreeSet<&str> = matching.iter().map(|r| r.topology.as_str()).collect();
        let connect_identity = sha256_hex(target.connect_key.as_bytes());
        let one = |set: &BTreeSet<&str>, value: &str| set.len() == 1 && set.contains(value);
        let Some(topology) = topologies.iter().next().copied() else {
            return Ok(None);
        };
        if !one(&current_keys, target.connect_key)
            || !one(&confirmed_keys, target.connect_key)
            || !one(&identities, &connect_identity)
            || topologies.len() != 1
            || !(direct.is_empty() || direct == topologies)
        {
            return Ok(None);
        }
        let (Some(intent), Some(receipt)) = (
            current.iter().map(|r| r.intent_sha256.as_str()).min(),
            matching.iter().map(|r| r.receipt_sha256.as_str()).min(),
        ) else {
            return Ok(None);
        };
        Ok(Some(ReactivationProof {
            target_id: target.target_id.to_owned(),
            binding_revision: target.binding_revision,
            stable_loader_identity_sha256: target.identity_sha256.to_owned(),
            hdc_connect_key: target.connect_key.to_owned(),
            hdc_identity_sha256: connect_identity,
            hdc_usb_topology: topology.to_owned(),
            current_binding_intent_sha256: intent.to_owned(),
            hdc_route_receipt_sha256: receipt.to_owned(),
        }))
    }

    /// Swift `validateRootIfPresent()`: an absent root holds no proof; a
    /// present one must be an absolute, already standardized, owner-only
    /// directory of this user.
    fn validate_root_if_present(&self) -> Result<bool, BindingError> {
        let metadata = match std::fs::symlink_metadata(&self.root) {
            Ok(metadata) => metadata,
            Err(error) if error.kind() == std::io::ErrorKind::NotFound => return Ok(false),
            Err(_) => {
                return Err(refuse(
                    "Runtime reactivation record root cannot be inspected",
                ));
            }
        };
        if !self.root.is_absolute()
            || standardized(&self.root) != self.root
            || !metadata.is_dir()
            || metadata.uid() != arkdeck_platform::effective_user_id()
            || metadata.mode() & 0o077 != 0
        {
            return Err(refuse("Runtime reactivation record root is not owner-only"));
        }
        Ok(true)
    }
}

fn file_name(path: &Path) -> String {
    path.file_name()
        .map(|name| name.to_string_lossy().into_owned())
        .unwrap_or_default()
}

/// Swift `validateDirectory(_:)`: an owner-only directory of this user, not
/// through a link.
fn owner_only_directory(path: &Path) -> bool {
    std::fs::symlink_metadata(path).is_ok_and(|metadata| {
        metadata.is_dir()
            && metadata.uid() == arkdeck_platform::effective_user_id()
            && metadata.mode() & 0o077 == 0
    })
}

/// Swift `childDirectories(of:where:)`: the visible entries a predicate
/// names, in name order and bounded, that are owner-only directories; none
/// under a parent that is not one.
fn child_directories(
    parent: &Path,
    predicate: impl Fn(&str) -> bool,
) -> Result<Vec<PathBuf>, BindingError> {
    if !owner_only_directory(parent) {
        return Ok(Vec::new());
    }
    let unreadable = || refuse("Runtime reactivation record directory cannot be read");
    let mut names = Vec::new();
    for entry in std::fs::read_dir(parent).map_err(|_| unreadable())? {
        let name = entry.map_err(|_| unreadable())?.file_name();
        let name = name.to_string_lossy().into_owned();
        if !name.starts_with('.') && predicate(&name) {
            names.push(name);
        }
    }
    names.sort();
    if names.len() > MAXIMUM_ENTRIES {
        return Err(refuse(
            "Runtime reactivation record directory exceeds its bound",
        ));
    }
    Ok(names
        .into_iter()
        .map(|name| parent.join(name))
        .filter(|path| owner_only_directory(path))
        .collect())
}

/// Swift `readOwnerOnlyRecord(_:)`: a single-link regular file of this user,
/// mode exactly 0600, not empty and at most 1 MiB, opened through no final
/// link.
fn read_owner_only(path: &Path) -> Option<Vec<u8>> {
    let mut file = std::fs::OpenOptions::new()
        .read(true)
        .custom_flags(libc::O_NOFOLLOW)
        .open(path)
        .ok()?;
    let metadata = file.metadata().ok()?;
    if !metadata.is_file()
        || metadata.nlink() != 1
        || metadata.uid() != arkdeck_platform::effective_user_id()
        || metadata.mode() & 0o777 != 0o600
        || metadata.len() == 0
        || metadata.len() > MAXIMUM_RECORD_BYTES
    {
        return None;
    }
    let mut bytes = Vec::new();
    file.read_to_end(&mut bytes).ok()?;
    (bytes.len() as u64 == metadata.len()).then_some(bytes)
}

/// A record whose top level is an object with exactly `keys`.
fn record(path: &Path, keys: &[&str]) -> Option<(Map<String, Value>, Vec<u8>)> {
    let bytes = read_owner_only(path)?;
    let Value::Object(members) = serde_json::from_slice(&bytes).ok()? else {
        return None;
    };
    let present: BTreeSet<&str> = members.keys().map(String::as_str).collect();
    (present == keys.iter().copied().collect()).then_some((members, bytes))
}

fn text(members: &Map<String, Value>, key: &str) -> Option<String> {
    members.get(key)?.as_str().map(str::to_owned)
}

fn integer(members: &Map<String, Value>, key: &str) -> Option<i64> {
    members.get(key)?.as_number().and_then(swift_integer)
}

/// Swift `readIntent(from:)`, where any refusal is no record.
fn read_intent(path: &Path) -> Option<(Intent, Vec<u8>)> {
    let (members, bytes) = record(path, &INTENT_KEYS)?;
    let action = members.get("action")?.as_object()?;
    Some((
        Intent {
            schema: text(&members, "schemaVersion")?,
            job: text(&members, "jobID")?,
            step: text(&members, "stepID")?,
            target: text(&members, "targetID")?,
            revision: integer(&members, "bindingRevision")?,
            identity: text(&members, "stableIdentitySHA256")?,
            provider: text(&members, "providerExecutableSHA256")?,
            action_sha256: text(&members, "actionSHA256")?,
            kind: text(action, "kind")?,
            arguments: action.get("arguments")?.as_object()?.clone(),
        },
        bytes,
    ))
}

/// Swift `readReceipt(from:)`, where any refusal is no record.
fn read_receipt(path: &Path) -> Option<(Receipt, Vec<u8>)> {
    let (members, bytes) = record(path, &RECEIPT_KEYS)?;
    let summary = members.get("summary")?.as_object()?;
    if !summary.values().all(Value::is_string) {
        return None;
    }
    Some((
        Receipt {
            schema: text(&members, "schemaVersion")?,
            job: text(&members, "jobID")?,
            step: text(&members, "stepID")?,
            target: text(&members, "targetID")?,
            revision: integer(&members, "bindingRevision")?,
            identity: text(&members, "stableIdentitySHA256")?,
            provider: text(&members, "providerExecutableSHA256")?,
            action_sha256: text(&members, "actionSHA256")?,
            summary: summary.clone(),
            stdout_sha256: text(&members, "stdoutSHA256")?,
            stdout_bytes: integer(&members, "stdoutByteCount")?,
            stderr_sha256: text(&members, "stderrSHA256")?,
            stderr_bytes: integer(&members, "stderrByteCount")?,
            truncated: members.get("stdoutTruncated")?.as_bool()?,
            subprocesses: integer(&members, "subprocessCount")?,
        },
        bytes,
    ))
}

/// Swift `validActionHash(_:)`: the digest of the action as
/// `CanonicalJSONEncoders.canonical()` encodes what was decoded of it.
fn valid_action_hash(intent: &Intent) -> bool {
    canonical_json(&json!({"kind": intent.kind, "arguments": intent.arguments}))
        .is_ok_and(|bytes| sha256_hex(&bytes) == intent.action_sha256)
}

fn string<'a>(arguments: &'a Map<String, Value>, key: &str) -> Option<&'a str> {
    arguments.get(key)?.as_str()
}

/// Swift `isTopology`: ASCII digits, and no leading zero but `0`.
fn topology_text(value: &str) -> bool {
    !value.is_empty()
        && value.bytes().all(|byte| byte.is_ascii_digit())
        && (value == "0" || !value.starts_with('0'))
}

/// Swift `currentRoute(from:bytes:)`: the retained HDC route a current
/// `wait-for-hdc` intent names, through either of its two reconnect actions.
fn current_route(intent: &Intent, bytes: &[u8]) -> Option<CurrentRoute> {
    if intent.schema != "1.0.0"
        || !canonical_sha256(&intent.provider)
        || !canonical_sha256(&intent.action_sha256)
        || !valid_action_hash(intent)
    {
        return None;
    }
    let keys: BTreeSet<&str> = intent.arguments.keys().map(String::as_str).collect();
    let route = |connect_key: &str, topology: Option<&str>| CurrentRoute {
        connect_key: connect_key.to_owned(),
        topology: topology.map(str::to_owned),
        provider: intent.provider.clone(),
        intent_sha256: sha256_hex(bytes),
    };
    match intent.kind.as_str() {
        "rockchip.waitForHDCReconnect" => {
            let connect_key = string(&intent.arguments, "connectKey")?;
            (keys == BTreeSet::from(["connectKey"]) && !connect_key.is_empty())
                .then(|| route(connect_key, None))
        }
        "rockchip.waitForBoundHDCReconnect" => {
            let connect_key = string(&intent.arguments, "previousConnectKey")?;
            let identity = string(&intent.arguments, "previousIdentitySha256")?;
            let topology = string(&intent.arguments, "usbTopology")?;
            (keys
                == BTreeSet::from([
                    "previousConnectKey",
                    "previousIdentitySha256",
                    "usbTopology",
                ])
                && identity == sha256_hex(connect_key.as_bytes())
                && topology_text(topology))
            .then(|| route(connect_key, Some(topology)))
        }
        _ => None,
    }
}
