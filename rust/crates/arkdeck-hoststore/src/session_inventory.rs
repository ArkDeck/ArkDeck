//! Session census with separate read-only and explicit owner entry points.
//! The fixture reader never writes; resource pin transitions hold the catalog lock.
use crate::session_manifest::{ManifestError, ManifestSummary, decode_manifest, identifier};
use crate::session_time::session_timestamp;
use crate::{decode_session_configuration, roundtrip};
use arkdeck_platform::{
    DocumentPublishError, HostDirectory, HostEntryKind, host_gregorian_add_days,
    host_gregorian_timestamp,
};
use serde::{Deserialize, Serialize};
use serde_json::{Value, json};
use std::collections::{BTreeMap, BTreeSet};
use std::{io, path::Path};

#[path = "session_cleanup_inventory.rs"]
mod cleanup;
pub use cleanup::{CleanupSession, CleanupSnapshot, session_cleanup_snapshot};
#[path = "session_export_inventory.rs"]
mod export;
pub use export::{SessionExportSnapshot, session_export_snapshot};

const METADATA: &str = ".arkdeck-retention-catalog.json";
const LOCK: &str = ".arkdeck-retention-catalog.lock";
fn invalid() -> io::Error {
    io::Error::new(io::ErrorKind::InvalidData, "Session snapshot refused")
}
fn coverage() -> io::Error {
    io::Error::new(
        io::ErrorKind::Unsupported,
        "Session shadow coverage incomplete",
    )
}

#[derive(Deserialize, Serialize)]
#[serde(deny_unknown_fields, rename_all = "camelCase")]
struct Identity {
    schema_version: String,
    session_id: String,
    job_id: String,
}
#[derive(Clone, Deserialize, Serialize)]
#[serde(deny_unknown_fields, rename_all = "camelCase")]
struct Entry {
    session_id: String,
    completed_at: String,
    expires_at: String,
    is_pinned: bool,
    policy_generation: u64,
}
#[derive(Deserialize, Serialize)]
#[serde(deny_unknown_fields, rename_all = "camelCase")]
struct Catalog {
    schema_version: String,
    generation: u64,
    entries: Vec<Entry>,
}
struct Scanned {
    manifest: ManifestSummary,
    manifest_bytes: u64,
    bytes: u64,
    location: [String; 3],
}
#[derive(Default)]
struct Tree {
    sessions: Vec<Scanned>,
    observed: Vec<String>,
    unknown: BTreeSet<String>,
    bytes: u64,
    incomplete: bool,
    unscoped: bool,
}
fn add(tree: &mut Tree, bytes: u64) {
    match tree.bytes.checked_add(bytes) {
        Some(sum) => tree.bytes = sum,
        None => {
            tree.bytes = u64::MAX;
            tree.incomplete = true;
        }
    }
}
fn measure(parent: &HostDirectory, name: &str) -> io::Result<u64> {
    match parent.owned_kind_and_size(name)? {
        (HostEntryKind::Regular, size) => Ok(size),
        (HostEntryKind::Directory, _) => measure_directory(&parent.child(name)?),
        _ => Err(invalid()),
    }
}
fn measure_directory(root: &HostDirectory) -> io::Result<u64> {
    let mut sum = 0_u64;
    // The frozen Swift Session census has no node-count or depth cutoff.
    // Trace has its own published enumeration bounds; do not import them here.
    for name in root.names(usize::MAX)? {
        sum = sum.checked_add(measure(root, &name)?).ok_or_else(invalid)?;
    }
    Ok(sum)
}
fn unknown(tree: &mut Tree, parent: &HostDirectory, name: &str, display: String) {
    tree.incomplete = true;
    tree.unknown.insert(display);
    if let Ok(bytes) = measure(parent, name) {
        add(tree, bytes);
    }
}
fn scan_session(
    parent: &HostDirectory,
    year: &str,
    month: &str,
    name: &str,
) -> io::Result<Scanned> {
    let root = parent.child(name)?;
    let bytes = root.read(".session-identity.json", 4096)?;
    let (identity, canonical) =
        roundtrip::<Identity>(&bytes, 4096, false).map_err(|_| invalid())?;
    if canonical != bytes
        || identity.schema_version != "1.0.0"
        || identity.session_id != name
        || !identifier(&identity.session_id)
        || !identifier(&identity.job_id)
    {
        return Err(invalid());
    }
    let bytes = root.read("manifest.json", 16 * 1024 * 1024)?;
    let manifest = decode_manifest(&bytes).map_err(|e| match e {
        ManifestError::Invalid => invalid(),
        ManifestError::Unsupported => coverage(),
    })?;
    if manifest.session_id != name || manifest.job_id != identity.job_id {
        return Err(invalid());
    }
    let manifest_bytes = bytes.len() as u64;
    let bytes = measure_directory(&root)?;
    Ok(Scanned {
        manifest,
        manifest_bytes,
        bytes,
        location: [year.into(), month.into(), name.into()],
    })
}
fn scan(root: &HostDirectory) -> io::Result<Tree> {
    let mut tree = Tree::default();
    for year in root.names(usize::MAX)? {
        if year == METADATA || year == LOCK {
            continue;
        }
        let year_root = if year.len() == 4 && year.bytes().all(|b| b.is_ascii_digit()) {
            root.child(&year).ok()
        } else {
            None
        };
        let Some(year_root) = year_root else {
            tree.unscoped = true;
            unknown(&mut tree, root, &year, year.clone());
            continue;
        };
        for month in year_root.names(usize::MAX)? {
            let month_root = if month.len() == 2
                && month.bytes().all(|b| b.is_ascii_digit())
                && month
                    .parse::<u8>()
                    .ok()
                    .is_some_and(|m| (1..=12).contains(&m))
            {
                year_root.child(&month).ok()
            } else {
                None
            };
            let Some(month_root) = month_root else {
                tree.unscoped = true;
                unknown(&mut tree, &year_root, &month, format!("{year}/{month}"));
                continue;
            };
            for name in month_root.names(usize::MAX)? {
                tree.observed.push(name.clone());
                let result = if identifier(&name) {
                    scan_session(&month_root, &year, &month, &name)
                } else {
                    Err(invalid())
                };
                match result {
                    Ok(session) => {
                        add(&mut tree, session.bytes);
                        tree.sessions.push(session);
                    }
                    Err(error) if error.kind() == io::ErrorKind::Unsupported => return Err(error),
                    Err(_) => unknown(
                        &mut tree,
                        &month_root,
                        &name,
                        format!("{year}/{month}/{name}"),
                    ),
                }
            }
        }
    }
    Ok(tree)
}
fn catalog(root: &HostDirectory) -> Option<Catalog> {
    let bytes = root.read(METADATA, 16 * 1024 * 1024).ok()?;
    let (doc, canonical) = roundtrip::<Catalog>(&bytes, 16 * 1024 * 1024, false).ok()?;
    if bytes != canonical || doc.schema_version != "1.0.0" {
        return None;
    }
    let mut ids = BTreeSet::new();
    for row in &doc.entries {
        if !identifier(&row.session_id)
            || !ids.insert(&row.session_id)
            || session_timestamp(&row.completed_at).is_none()
            || session_timestamp(&row.expires_at).is_none()
        {
            return None;
        }
    }
    Some(doc)
}

pub fn session_inventory(configuration: &[u8], path: &Path) -> io::Result<Value> {
    inventory(configuration, path, false)
}

/// Scan and durably reconcile the retention catalog of a private Session root.
/// Existing unknown or corrupt entries are never registered, erased, or repaired.
pub fn session_inventory_owned(configuration: &[u8], path: &Path) -> io::Result<Value> {
    inventory(configuration, path, true)
}

/// The configuration owner remains locked by the caller. Reconcile first,
/// then read a fresh tree under the catalog lock used for the pin CAS itself.
pub(crate) fn session_resource_rows(
    configuration: &[u8],
    path: &Path,
    selected: Option<&str>,
    pin: Option<(u64, bool)>,
) -> Result<Vec<Value>, arkdeck_contract::WireError> {
    use crate::snapshot_pager::failure;
    let unreadable = |_| failure("recordUnreadable", "Session catalog cannot be read safely");
    let conflict = |error: io::Error| {
        if error.kind() == io::ErrorKind::WouldBlock {
            failure("resourceConflict", "Session catalog is being updated")
        } else {
            unreadable(error)
        }
    };
    session_inventory_owned(configuration, path).map_err(conflict)?;
    let root = HostDirectory::open_session_tree(path).map_err(unreadable)?;
    let owner = HostDirectory::open(path).map_err(unreadable)?;
    let lock = owner.lock_document(LOCK).map_err(conflict)?;
    let mut document = catalog(&root).ok_or_else(|| unreadable(invalid()))?;
    if document.generation > i64::MAX as u64 {
        return Err(unreadable(invalid()));
    }
    let tree = scan(&root).map_err(unreadable)?;
    let mut observed = BTreeSet::new();
    let mut duplicates = BTreeSet::new();
    for id in &tree.observed {
        if !observed.insert(id) {
            duplicates.insert(id.clone());
        }
    }
    let by_id: BTreeMap<_, _> = document
        .entries
        .iter()
        .map(|entry| (entry.session_id.as_str(), entry))
        .collect();
    let mut unknown = tree.unknown.clone();
    unknown.extend(duplicates.iter().cloned());
    let mut retained = Vec::new();
    for row in &tree.sessions {
        if by_id
            .get(row.manifest.session_id.as_str())
            .is_some_and(|entry| {
                session_timestamp(&entry.completed_at) == Some(row.manifest.completed_at)
            })
        {
            retained.push(row);
        } else {
            unknown.insert(row.manifest.session_id.clone());
        }
    }
    let scoped = pin.is_none() && selected.is_some();
    if tree.unscoped
        || !duplicates.is_empty()
        || (!unknown.is_empty()
            && (!scoped
                || unknown.iter().any(|reference| {
                    selected
                        .is_some_and(|id| reference == id || reference.ends_with(&format!("/{id}")))
                })))
        || (tree.incomplete && unknown.is_empty())
    {
        let mut summary = unknown
            .iter()
            .take(8)
            .map(String::as_str)
            .collect::<Vec<_>>()
            .join(", ");
        if unknown.len() > 8 {
            summary.push_str(&format!(", and {} more", unknown.len() - 8));
        }
        if summary.is_empty() {
            summary = "the measurement is incomplete; no individual leaf could be named".into();
        }
        return Err(failure(
            "operationUnavailable",
            &format!("Session catalog contains unaccounted content: {summary}"),
        ));
    }
    if document.entries.iter().any(|entry| {
        !retained
            .iter()
            .any(|row| row.manifest.session_id == entry.session_id)
            && !(scoped
                && unknown.iter().any(|reference| {
                    reference == &entry.session_id
                        || reference.ends_with(&format!("/{}", entry.session_id))
                }))
    }) {
        return Err(unreadable(invalid()));
    }
    let configuration = decode_session_configuration(configuration)
        .map_err(|_| unreadable(invalid()))?
        .projection;
    let policy_generation = configuration["generation"]
        .as_str()
        .ok_or_else(|| unreadable(invalid()))?;
    let days = configuration["policy"]["retentionDays"]
        .as_str()
        .and_then(|value| value.parse::<i32>().ok())
        .ok_or_else(|| unreadable(invalid()))?;
    let plain = |at| {
        host_gregorian_timestamp(at)
            .map(|value| format!("{}Z", value.split('.').next().unwrap_or(&value)))
    };
    // Validate every projected field before any pin publication. A later
    // encoding failure must not conceal an already applied pin transition.
    for row in &retained {
        let entry = by_id[row.manifest.session_id.as_str()];
        let expiry = session_timestamp(&entry.expires_at).ok_or_else(|| unreadable(invalid()))?;
        if Some(expiry) != host_gregorian_add_days(row.manifest.completed_at, days)
            || entry.policy_generation.to_string() != policy_generation
            || row.bytes > i64::MAX as u64
            || plain(row.manifest.completed_at).is_none()
            || plain(expiry).is_none()
        {
            return Err(unreadable(invalid()));
        }
    }
    if pin.is_some_and(|(expected, _)| expected != document.generation) {
        return Err(failure(
            "resourceConflict",
            "Session catalog generation changed",
        ));
    }
    if let Some(id) = selected
        && !retained.iter().any(|row| row.manifest.session_id == id)
    {
        return Err(failure(
            "resourceNotFound",
            "Session is not present in the Runtime catalog",
        ));
    }
    let mut published = false;
    if let Some((_, pinned)) = pin {
        let entry = document
            .entries
            .iter_mut()
            .find(|entry| Some(entry.session_id.as_str()) == selected)
            .ok_or_else(|| {
                failure(
                    "resourceNotFound",
                    "Session is not present in the Runtime catalog",
                )
            })?;
        if entry.is_pinned != pinned {
            if document.generation == i64::MAX as u64 {
                return Err(failure(
                    "resourceConflict",
                    "Session catalog generation is exhausted",
                ));
            }
            entry.is_pinned = pinned;
            document.generation += 1;
            document
                .entries
                .sort_by(|a, b| a.session_id.cmp(&b.session_id));
            let value = serde_json::to_value(&document).map_err(|_| unreadable(invalid()))?;
            let bytes = serde_json::to_vec(&value).map_err(|_| unreadable(invalid()))?;
            lock.validate_link(&owner, LOCK).map_err(unreadable)?;
            owner.validate_path(path).map_err(unreadable)?;
            owner.publish_document(METADATA, &bytes, 16 * 1024 * 1024).map_err(|error| match error {
                DocumentPublishError::BeforePublication(_) => failure("ioFailure", "Session pin could not be published"),
                DocumentPublishError::OutcomeUnknown(_) => failure("outcomeUnknown", "Session pin publication is uncertain; read current generation before another update"),
            })?;
            published = true;
            if root.read(METADATA, 16 * 1024 * 1024).ok().as_ref() != Some(&bytes)
                || lock.validate_link(&owner, LOCK).is_err()
                || owner.validate_path(path).is_err()
            {
                return Err(failure(
                    "outcomeUnknown",
                    "Session pin publication cannot be read back exactly",
                ));
            }
            let after = scan(&root).map_err(|_| {
                failure(
                    "outcomeUnknown",
                    "Session content cannot be read back after pin publication",
                )
            })?;
            let signature = |tree: &Tree| {
                tree.sessions
                    .iter()
                    .map(|row| {
                        (
                            row.manifest.session_id.clone(),
                            (
                                row.manifest.job_id.clone(),
                                row.manifest.completed_at.to_bits(),
                                row.bytes,
                            ),
                        )
                    })
                    .collect::<BTreeMap<_, _>>()
            };
            if after.incomplete
                || after.observed.len() != tree.observed.len()
                || signature(&after) != signature(&tree)
            {
                return Err(failure(
                    "outcomeUnknown",
                    "Session content changed during pin publication",
                ));
            }
        }
    }
    let mut rows = Vec::new();
    for row in retained {
        let entry = document
            .entries
            .iter()
            .find(|entry| entry.session_id == row.manifest.session_id)
            .ok_or_else(|| unreadable(invalid()))?;
        let expiry = session_timestamp(&entry.expires_at).ok_or_else(|| unreadable(invalid()))?;
        let completed = plain(row.manifest.completed_at).ok_or_else(|| unreadable(invalid()))?;
        rows.push((completed.clone(), row.manifest.session_id.clone(), json!({
            "schemaVersion":"arkdeck.session/1", "sessionId":row.manifest.session_id,
            "generation":document.generation.to_string(), "completedAtUtc":completed,
            "expiresAtUtc":plain(expiry).ok_or_else(|| unreadable(invalid()))?,"sizeBytes":row.bytes.to_string(),
            "pinned":entry.is_pinned,"policyGeneration":entry.policy_generation.to_string()
        })));
    }
    // Consumers order the published whole-second timestamp. Hidden fractional
    // seconds must not reverse the required identity order within a wire tie.
    rows.sort_by(|a, b| b.0.cmp(&a.0).then_with(|| a.1.cmp(&b.1)));
    if lock.validate_link(&owner, LOCK).is_err() || root.validate_path(path).is_err() {
        return Err(failure(
            if published {
                "outcomeUnknown"
            } else {
                "recordUnreadable"
            },
            "Session catalog owner changed during access",
        ));
    }
    Ok(rows
        .into_iter()
        .filter(|(_, id, _)| selected.is_none_or(|selected| selected == id))
        .map(|(_, _, value)| value)
        .collect())
}

fn inventory(configuration: &[u8], path: &Path, owns_catalog: bool) -> io::Result<Value> {
    let mut projection = decode_session_configuration(configuration)
        .map_err(|_| invalid())?
        .projection;
    let root_path = projection["rootPath"].as_str().ok_or_else(invalid)?;
    if Path::new(root_path).canonicalize()? != path {
        return Err(invalid());
    }
    let generation = projection["generation"]
        .as_str()
        .ok_or_else(invalid)?
        .parse::<u64>()
        .map_err(|_| invalid())?;
    let days = projection["policy"]["retentionDays"]
        .as_str()
        .ok_or_else(invalid)?
        .parse::<u64>()
        .map_err(|_| invalid())?;
    let root = HostDirectory::open_session_tree(path)?;
    let owner = if owns_catalog {
        Some(HostDirectory::open(path)?)
    } else {
        None
    };
    let lock = if let Some(owner) = &owner {
        owner.lock_document(LOCK)?
    } else {
        root.try_lock_existing(LOCK)?.ok_or_else(|| {
            io::Error::new(
                io::ErrorKind::WouldBlock,
                "Session snapshot lock unavailable",
            )
        })?
    };
    let marker = root.read(LOCK, 1)?;
    if !marker.is_empty() && marker != [0xA5] {
        return Err(invalid());
    }
    let fresh = marker.is_empty();
    let mut tree = scan(&root)?;
    let mut observed = BTreeSet::new();
    let mut duplicates = BTreeSet::new();
    for id in &tree.observed {
        if !observed.insert(id.clone()) {
            duplicates.insert(id.clone());
        }
    }
    for id in &duplicates {
        tree.unknown.insert(id.clone());
        tree.incomplete = true;
    }
    let absent =
        matches!(root.kind_and_size(METADATA), Err(e) if e.kind() == io::ErrorKind::NotFound);
    let current = catalog(&root);
    let seal_existing = owns_catalog && fresh && current.is_some();
    let mut catalog_generation = None;
    let mut publication = None;
    let (mut session_count, mut pinned_count, mut pinned_bytes) = (0_usize, 0_usize, 0_u64);
    let expiry = |at| -> io::Result<f64> {
        host_gregorian_add_days(at, i32::try_from(days).map_err(|_| invalid())?).ok_or_else(invalid)
    };
    if absent && fresh {
        let mut entries = Vec::new();
        for row in &tree.sessions {
            if !duplicates.contains(&row.manifest.session_id) {
                let expires = expiry(row.manifest.completed_at)?;
                if owns_catalog {
                    entries.push(Entry {
                        session_id: row.manifest.session_id.clone(),
                        completed_at: host_gregorian_timestamp(row.manifest.completed_at)
                            .ok_or_else(invalid)?,
                        expires_at: host_gregorian_timestamp(expires).ok_or_else(invalid)?,
                        is_pinned: false,
                        policy_generation: generation,
                    });
                }
                session_count += 1;
            }
        }
        catalog_generation = Some(0);
        if owns_catalog {
            publication = Some(Catalog {
                schema_version: "1.0.0".into(),
                generation: 0,
                entries,
            });
        }
    } else if let Some(mut doc) = current {
        let by_id: BTreeMap<_, _> = doc
            .entries
            .iter()
            .map(|e| (e.session_id.as_str(), e))
            .collect();
        let mut retained = BTreeSet::new();
        let mut changed = false;
        let mut updated = BTreeMap::new();
        for row in &tree.sessions {
            let id = row.manifest.session_id.as_str();
            let entry = by_id.get(id).copied().filter(|e| {
                !duplicates.contains(id)
                    && session_timestamp(&e.completed_at) == Some(row.manifest.completed_at)
            });
            let Some(entry) = entry else {
                tree.incomplete = true;
                tree.unknown.insert(id.to_owned());
                continue;
            };
            if session_timestamp(&entry.expires_at) != Some(expiry(row.manifest.completed_at)?)
                || entry.policy_generation != generation
            {
                changed = true;
                if owns_catalog {
                    let mut next = entry.clone();
                    next.expires_at = host_gregorian_timestamp(expiry(row.manifest.completed_at)?)
                        .ok_or_else(invalid)?;
                    next.policy_generation = generation;
                    updated.insert(id.to_owned(), next);
                }
            }
            retained.insert(id.to_owned());
            if entry.is_pinned {
                pinned_bytes = pinned_bytes.saturating_add(row.bytes);
            }
        }
        for entry in &doc.entries {
            if tree.unscoped
                || retained.contains(&entry.session_id)
                || observed.contains(&entry.session_id)
            {
                session_count += 1;
                if entry.is_pinned {
                    pinned_count += 1;
                }
            } else {
                changed = true;
            }
        }
        catalog_generation = Some(if changed {
            doc.generation.checked_add(1).ok_or_else(invalid)?
        } else {
            doc.generation
        });
        if owns_catalog && changed {
            doc.entries.retain(|entry| {
                tree.unscoped
                    || retained.contains(&entry.session_id)
                    || observed.contains(&entry.session_id)
            });
            for entry in &mut doc.entries {
                if let Some(next) = updated.remove(&entry.session_id) {
                    *entry = next;
                }
            }
            doc.generation = catalog_generation.ok_or_else(invalid)?;
            publication = Some(doc);
        }
    } else {
        tree.incomplete = true;
        for row in &tree.sessions {
            tree.unknown.insert(row.manifest.session_id.clone());
        }
    }
    // Configuration is an immutable caller-supplied byte snapshot. Validate
    // its root binding again; this shadow command does not own a live config
    // file or claim that a concurrent config publication was observed.
    if Path::new(root_path).canonicalize()? != path || root.read(LOCK, 1)? != marker {
        return Err(invalid());
    }
    root.validate_path(path)?;
    lock.validate_link(&root, LOCK)?;
    if let Some(mut document) = publication {
        let owner = owner.as_ref().ok_or_else(invalid)?;
        document
            .entries
            .sort_by(|a, b| a.session_id.cmp(&b.session_id));
        let value = serde_json::to_value(document).map_err(|_| invalid())?;
        let bytes = serde_json::to_vec(&value).map_err(|_| invalid())?;
        owner
            .publish_document(METADATA, &bytes, 16 * 1024 * 1024)
            .map_err(|error| match error {
                DocumentPublishError::BeforePublication(error) => error,
                DocumentPublishError::OutcomeUnknown(error) => io::Error::other(format!(
                    "Session catalog publication outcome unknown: {error}"
                )),
            })?;
        lock.mark_catalog_initialized(owner, LOCK)?;
        owner.validate_path(path)?;
    } else if seal_existing {
        let owner = owner.as_ref().ok_or_else(invalid)?;
        lock.mark_catalog_initialized(owner, LOCK)?;
        owner.validate_path(path)?;
    }
    let fields = projection.as_object_mut().ok_or_else(invalid)?;
    fields.insert(
        "schemaVersion".into(),
        json!("arkdeck.session-storage-status/1"),
    );
    fields.insert(
        "catalogGeneration".into(),
        catalog_generation
            .map(|g| json!(g.to_string()))
            .unwrap_or(Value::Null),
    );
    fields.insert("usage".into(), json!({"usedBytes": tree.bytes.to_string(), "pinnedBytes": pinned_bytes.to_string(),
        "sessionCount": session_count.to_string(), "pinnedSessionCount": pinned_count.to_string(),
        "unaccountedSessionCount": tree.unknown.len().to_string(), "measurementIncomplete": tree.incomplete}));
    Ok(projection)
}

#[cfg(test)]
mod owner_tests {
    use super::*;
    use std::{fs, os::unix::fs::DirBuilderExt, path::PathBuf};
    struct Root(PathBuf);
    impl Root {
        fn new() -> Self {
            let nonce = u128::from_ne_bytes(arkdeck_platform::random_bytes::<16>().unwrap());
            let path = std::env::temp_dir()
                .canonicalize()
                .unwrap()
                .join(format!("session-owner-{nonce:x}"));
            fs::DirBuilder::new().mode(0o700).create(&path).unwrap();
            Self(path)
        }
        fn config(&self) -> Vec<u8> {
            let mut bytes = serde_json::to_vec(&json!({"schemaVersion":"arkdeck.session-storage-store/1", "generation":1,
                "rootKind":"default", "rootPath":self.0, "policy":{"totalQuotaBytes":20000,"safetyMarginBytes":1000,"retentionDays":90}})).unwrap();
            bytes.push(b'\n');
            bytes
        }
        fn scan(&self) -> Value {
            session_inventory_owned(&self.config(), &self.0).unwrap()
        }
    }
    impl Drop for Root {
        fn drop(&mut self) {
            fs::remove_dir_all(&self.0).unwrap();
        }
    }
    #[test]
    fn initializes_once_and_does_not_rebuild_a_lost_catalog() {
        let root = Root::new();
        let first = root.scan();
        assert_eq!(first["catalogGeneration"], "0");
        assert_eq!(fs::read(root.0.join(LOCK)).unwrap(), [0xA5]);
        let original = fs::read(root.0.join(METADATA)).unwrap();
        assert!(catalog(&HostDirectory::open(&root.0).unwrap()).is_some());
        assert_eq!(root.scan(), first);
        assert_eq!(fs::read(root.0.join(METADATA)).unwrap(), original);
        fs::remove_file(root.0.join(METADATA)).unwrap();
        let missing = root.scan();
        assert!(missing["catalogGeneration"].is_null());
        assert_eq!(missing["usage"]["measurementIncomplete"], true);
        assert!(!root.0.join(METADATA).exists());
    }
    #[test]
    fn unknown_content_counts_bytes_and_lock_conflict_never_initializes() {
        let root = Root::new();
        let owner = HostDirectory::open(&root.0).unwrap();
        let lock = owner.lock_document(LOCK).unwrap();
        assert_eq!(
            session_inventory_owned(&root.config(), &root.0)
                .unwrap_err()
                .kind(),
            io::ErrorKind::WouldBlock
        );
        assert!(!root.0.join(METADATA).exists());
        drop(lock);
        fs::write(root.0.join("unregistered"), b"12345").unwrap();
        let value = root.scan();
        assert_eq!(value["usage"]["usedBytes"], "5");
        assert_eq!(value["usage"]["measurementIncomplete"], true);
        assert_eq!(value["usage"]["sessionCount"], "0");
    }
    #[test]
    fn seals_valid_publication_after_restart_and_preserves_corrupt_bytes() {
        let root = Root::new();
        let owner = HostDirectory::open(&root.0).unwrap();
        drop(owner.lock_document(LOCK).unwrap());
        let data = br#"{"entries":[],"generation":3,"schemaVersion":"1.0.0"}"#;
        owner.publish_document(METADATA, data, 4096).unwrap();
        assert_eq!(root.scan()["catalogGeneration"], "3");
        assert_eq!(fs::read(root.0.join(LOCK)).unwrap(), [0xA5]);
        fs::write(root.0.join(METADATA), b"bad catalog").unwrap();
        assert!(root.scan()["catalogGeneration"].is_null());
        assert_eq!(fs::read(root.0.join(METADATA)).unwrap(), b"bad catalog");
    }
}
