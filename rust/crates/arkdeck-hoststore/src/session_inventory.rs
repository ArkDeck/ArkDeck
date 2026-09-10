//! Read-only Session census and retention projection over one explicit fixture
//! root. Nothing is created, repaired, pinned, deleted, or published here.
use crate::session_manifest::{ManifestError, ManifestSummary, decode_manifest, identifier};
use crate::session_time::session_timestamp;
use crate::{decode_session_configuration, roundtrip};
use arkdeck_platform::{HostDirectory, HostEntryKind, host_gregorian_add_days};
use serde::{Deserialize, Serialize};
use serde_json::{Value, json};
use std::collections::{BTreeMap, BTreeSet};
use std::{io, path::Path};

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
    bytes: u64,
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
struct Budget {
    remaining: usize,
}
impl Budget {
    fn visit(&mut self, depth: usize) -> io::Result<()> {
        if depth > 64 || self.remaining == 0 {
            return Err(coverage());
        }
        self.remaining -= 1;
        Ok(())
    }
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
fn measure(
    parent: &HostDirectory,
    name: &str,
    budget: &mut Budget,
    depth: usize,
) -> io::Result<u64> {
    budget.visit(depth)?;
    match parent.owned_kind_and_size(name)? {
        (HostEntryKind::Regular, size) => Ok(size),
        (HostEntryKind::Directory, _) => measure_directory(&parent.child(name)?, budget, depth + 1),
        _ => Err(invalid()),
    }
}
fn measure_directory(root: &HostDirectory, budget: &mut Budget, depth: usize) -> io::Result<u64> {
    let mut sum = 0_u64;
    for name in root.names(100_000)? {
        sum = sum
            .checked_add(measure(root, &name, budget, depth)?)
            .ok_or_else(invalid)?;
    }
    Ok(sum)
}
fn unknown(
    tree: &mut Tree,
    parent: &HostDirectory,
    name: &str,
    display: String,
    budget: &mut Budget,
) -> io::Result<()> {
    tree.incomplete = true;
    tree.unknown.insert(display);
    match measure(parent, name, budget, 0) {
        Ok(bytes) => add(tree, bytes),
        Err(error) if error.kind() == io::ErrorKind::Unsupported => return Err(error),
        Err(_) => (), // Current Swift measurement leaves unsafe entries unmeasured.
    }
    Ok(())
}
fn scan_session(parent: &HostDirectory, name: &str, budget: &mut Budget) -> io::Result<Scanned> {
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
    let bytes = measure_directory(&root, budget, 0)?;
    Ok(Scanned { manifest, bytes })
}
fn scan(root: &HostDirectory) -> io::Result<Tree> {
    let mut tree = Tree::default();
    let mut budget = Budget { remaining: 100_000 };
    for year in root.names(100_000)? {
        if year == METADATA || year == LOCK {
            continue;
        }
        budget.visit(0)?;
        let year_root = if year.len() == 4 && year.bytes().all(|b| b.is_ascii_digit()) {
            root.child(&year).ok()
        } else {
            None
        };
        let Some(year_root) = year_root else {
            tree.unscoped = true;
            unknown(&mut tree, root, &year, year.clone(), &mut budget)?;
            continue;
        };
        for month in year_root.names(100_000)? {
            budget.visit(1)?;
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
                unknown(
                    &mut tree,
                    &year_root,
                    &month,
                    format!("{year}/{month}"),
                    &mut budget,
                )?;
                continue;
            };
            for name in month_root.names(100_000)? {
                budget.visit(2)?;
                tree.observed.push(name.clone());
                let result = if identifier(&name) {
                    scan_session(&month_root, &name, &mut budget)
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
                        &mut budget,
                    )?,
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
    let _lock = root.try_lock_existing(LOCK)?.ok_or_else(|| {
        io::Error::new(
            io::ErrorKind::WouldBlock,
            "Session snapshot lock unavailable",
        )
    })?;
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
    let mut catalog_generation = None;
    let (mut session_count, mut pinned_count, mut pinned_bytes) = (0_usize, 0_usize, 0_u64);
    let expiry = |at| -> io::Result<f64> {
        host_gregorian_add_days(at, i32::try_from(days).map_err(|_| invalid())?).ok_or_else(invalid)
    };
    if absent && fresh {
        // Predict the current owner's first catalog, without writing it.
        for row in &tree.sessions {
            if !duplicates.contains(&row.manifest.session_id) {
                expiry(row.manifest.completed_at)?;
                session_count += 1;
            }
        }
        catalog_generation = Some(0);
    } else if let Some(doc) = current {
        let by_id: BTreeMap<_, _> = doc
            .entries
            .iter()
            .map(|e| (e.session_id.as_str(), e))
            .collect();
        let mut retained = BTreeSet::new();
        let mut changed = false;
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
    } else {
        tree.incomplete = true;
        for row in &tree.sessions {
            tree.unknown.insert(row.manifest.session_id.clone());
        }
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
