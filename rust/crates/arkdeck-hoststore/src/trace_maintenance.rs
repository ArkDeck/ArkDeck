//! Existing ArkTrace owner evidence, leased quarantine and inactive cache purge.
//! No source Artifact, request path, producer ownership or device authority is accepted.
use arkdeck_platform::{HostDirectory, HostEntryKind, HostReadLock};
use serde::{Deserialize, Serialize};
use serde_json::{Value, json};
use std::{
    io,
    path::{Path, PathBuf},
};

const LIMIT: usize = 4096;
fn invalid() -> io::Error {
    io::Error::new(io::ErrorKind::InvalidData, "trace maintenance refused")
}
#[derive(Clone, Debug, Deserialize, Serialize, PartialEq, Eq)]
#[serde(rename_all = "camelCase")]
struct Evidence {
    format_version: u64,
    state: String,
    #[serde(skip_serializing_if = "Option::is_none")]
    device: Option<u64>,
    #[serde(skip_serializing_if = "Option::is_none")]
    inode: Option<u64>,
    relative_path: String,
}
impl Evidence {
    fn read(root: &HostDirectory, name: &str) -> io::Result<Self> {
        let bytes = root.read(name, 4096)?;
        let text = crate::trace::json_text(&bytes).ok_or_else(invalid)?;
        let fields = serde_json::from_str::<crate::trace::FirstFields>(&text)
            .map_err(|_| invalid())?
            .0;
        let result: Self =
            serde_json::from_slice(&serde_json::to_vec(&fields)?).map_err(|_| invalid())?;
        if result.format_version != 1
            || !["creating", "session", "building", "ready"].contains(&result.state.as_str())
            || result.device.is_some() != result.inode.is_some()
            || result.relative_path.len() > 1024
            || !valid_location(&result.relative_path)
        {
            return Err(invalid());
        }
        Ok(result)
    }
    fn identity(&self) -> Option<(u64, u64)> {
        Some((self.device?, self.inode?))
    }
}
fn valid_location(path: &str) -> bool {
    let parts: Vec<_> = path.split('/').collect();
    !parts.is_empty()
        && parts.len() <= 8
        && parts.iter().all(|s| {
            !s.is_empty()
                && ![".", "..", ".owners", ".locks", ".leases"].contains(s)
                && !s.contains('\0')
        })
}
fn owner_name(name: &str) -> bool {
    !name.is_empty()
        && name.len() <= 96
        && name.bytes().all(|b| b.is_ascii_alphanumeric() || b == b'-')
}
fn canonical(path: &str) -> bool {
    let parts: Vec<_> = path.split('/').collect();
    parts.len() == 2
        && parts.iter().all(|s| {
            s.len() == 64
                && s.bytes()
                    .all(|b| b.is_ascii_digit() || (b'a'..=b'f').contains(&b))
        })
}
struct Owners {
    root: HostDirectory,
    path: PathBuf,
    recovery: HostDirectory,
    recovery_path: PathBuf,
}
impl Owners {
    fn open(owner: &Path, recovery: &Path) -> io::Result<Self> {
        let root = HostDirectory::open(owner)?.private_child(".owners")?;
        Ok(Self {
            root,
            path: owner.join(".owners"),
            recovery: HostDirectory::open(recovery)?,
            recovery_path: recovery.into(),
        })
    }
    fn validate(&self) -> io::Result<()> {
        self.root.validate_path(&self.path)?;
        self.recovery.validate_path(&self.recovery_path)
    }
    fn records(&self) -> io::Result<Vec<(String, Evidence)>> {
        self.validate()?;
        let mut records = Vec::new();
        for name in self.root.names(LIMIT * 3)? {
            let Some(base) = name.strip_suffix(".json") else {
                continue;
            };
            if !owner_name(base) {
                return Err(invalid());
            }
            records.push((base.to_owned(), Evidence::read(&self.root, &name)?));
            if records.len() > LIMIT {
                return Err(invalid());
            }
        }
        Ok(records)
    }
    fn lock(&self, base: &str) -> io::Result<Option<HostReadLock>> {
        let inventory = HostDirectory::open_trace_inventory(&self.path)?;
        inventory.try_trace_lock_existing(&format!("{base}.lock"), Some(4096))
    }
    fn reread(&self, base: &str, lock: &HostReadLock) -> io::Result<Evidence> {
        self.validate()?;
        lock.validate_link(&self.root, &format!("{base}.lock"))?;
        Evidence::read(&self.root, &format!("{base}.json"))
    }
    fn at(&self, relative: &str) -> io::Result<HostDirectory> {
        let mut directory = HostDirectory::open(&self.recovery_path)?;
        for name in relative.split('/') {
            directory = directory.child(name)?;
        }
        Ok(directory)
    }
    /// Pinned ArkTrace's bounded inode relocation recovery. A stale pathname
    /// never grants ownership of whatever replacement now occupies that name.
    fn locate(&self, evidence: &Evidence) -> io::Result<Option<String>> {
        let Some(expected) = evidence.identity().filter(|_| evidence.state != "creating") else {
            return Ok(None);
        };
        if self
            .at(&evidence.relative_path)
            .is_ok_and(|d| d.directory_identity().ok() == Some(expected))
        {
            return Ok(Some(evidence.relative_path.clone()));
        }
        let mut queue = vec![String::new()];
        let mut cursor = 0;
        let mut visited = 0usize;
        while cursor < queue.len() {
            let prefix = queue[cursor].clone();
            cursor += 1;
            let directory = if prefix.is_empty() {
                HostDirectory::open(&self.recovery_path)?
            } else {
                self.at(&prefix)?
            };
            for name in directory.names(LIMIT)? {
                visited += 1;
                if visited > LIMIT {
                    return Ok(None);
                }
                let path = if prefix.is_empty() {
                    name.clone()
                } else {
                    format!("{prefix}/{name}")
                };
                if !valid_location(&path)
                    || directory.kind_and_size(&name)?.0 != HostEntryKind::Directory
                {
                    continue;
                }
                let child = directory.child(&name)?;
                if child.directory_identity()? == expected {
                    return Ok(Some(path));
                }
                queue.push(path);
            }
        }
        Ok(None)
    }
    fn remove(
        &self,
        base: &str,
        lock: &HostReadLock,
        evidence: &Evidence,
        location: &str,
        checkpoint: &dyn Fn(&str) -> io::Result<()>,
    ) -> io::Result<()> {
        if self.reread(base, lock)? != *evidence {
            return Err(invalid());
        }
        let parts = location.split('/').map(str::to_owned).collect::<Vec<_>>();
        let mut prepared = self
            .recovery
            .prepare_trace_removal(&parts, evidence.identity().ok_or_else(invalid)?)?;
        self.validate()?;
        checkpoint("beforeQuarantine")?;
        let relative_path = prepared.quarantine(&self.recovery_path)?;
        checkpoint("afterQuarantine")?;
        self.validate()?;
        lock.validate_link(&self.root, &format!("{base}.lock"))?;
        let updated = Evidence {
            relative_path,
            ..evidence.clone()
        };
        let name = format!("{base}.json");
        self.root
            .publish_document(&name, &serde_json::to_vec(&updated)?, 4096)
            .map_err(|_| invalid())?;
        checkpoint("afterOwnerPublication")?;
        prepared.remove(&self.recovery_path)?;
        checkpoint("afterDirectoryRemoval")?;
        self.validate()?;
        if self.reread(base, lock)? != updated {
            return Err(invalid());
        }
        self.root
            .remove_document(&name, &self.root.document_metadata(&name)?)?;
        lock.validate_link(&self.root, &format!("{base}.lock"))?;
        let marker = format!("{base}.lock");
        self.root
            .remove_document(&marker, &self.root.document_metadata(&marker)?)
    }
    fn recover(
        &self,
        cache: bool,
        checkpoint: &dyn Fn(&str) -> io::Result<()>,
    ) -> io::Result<(usize, usize)> {
        let mut recovered = 0;
        for (base, evidence) in self.records()? {
            if !["session", "building"].contains(&evidence.state.as_str()) {
                continue;
            }
            let Some(lock) = self.lock(&base)? else {
                continue;
            };
            let current = self.reread(&base, &lock)?;
            if !["session", "building"].contains(&current.state.as_str()) {
                continue;
            }
            let Some(location) = self.locate(&current)? else {
                continue;
            };
            if cache && current.state == "building" && canonical(&location) {
                continue;
            }
            self.remove(&base, &lock, &current, &location, checkpoint)?;
            recovered += 1;
        }
        let mut orphaned = 0;
        for name in self.root.names(LIMIT * 3)? {
            let Some(base) = name.strip_suffix(".lock").filter(|s| owner_name(s)) else {
                continue;
            };
            let evidence_name = format!("{base}.json");
            match self.root.kind_and_size(&evidence_name) {
                Ok(_) => continue,
                Err(e) if e.kind() == io::ErrorKind::NotFound => (),
                Err(e) => return Err(e),
            }
            let Some(lock) = self.lock(base)? else {
                continue;
            };
            self.validate()?;
            match self.root.kind_and_size(&evidence_name) {
                Ok(_) => continue,
                Err(e) if e.kind() == io::ErrorKind::NotFound => (),
                Err(e) => return Err(e),
            }
            lock.validate_link(&self.root, &name)?;
            self.root
                .remove_document(&name, &self.root.document_metadata(&name)?)?;
            orphaned += 1;
        }
        Ok((recovered, orphaned))
    }
}
fn report_inventory(mut value: Value) -> Value {
    let object = value.as_object_mut().expect("inventory object");
    object.remove("schemaVersion");
    object.remove("purgeScope");
    value
}
fn report(
    before: Value,
    after: Value,
    recovered: usize,
    orphans: usize,
    removed: usize,
    skipped: usize,
) -> Value {
    json!({"schemaVersion":"arkdeck.trace-cache-purge/1", "before":report_inventory(before), "after":report_inventory(after),
        "recoveredPrivateDirectoryCount":recovered, "removedOrphanOwnerMarkerCount":orphans,
        "removedEntryCount":removed, "skippedActiveEntryCount":skipped, "purgeScope":"inactiveDerivedDatabases", "originalTraceArtifactRemovalCount":0})
}

pub(super) fn purge(
    path: &Path,
    retain_all: bool,
    checkpoint: &dyn Fn(&str) -> io::Result<()>,
) -> io::Result<Value> {
    let before_retention = crate::trace_inventory(path)?;
    if retain_all {
        let skipped = before_retention["entryCount"]
            .as_u64()
            .ok_or_else(invalid)? as usize;
        return Ok(report(
            before_retention.clone(),
            before_retention,
            0,
            0,
            0,
            skipped,
        ));
    }
    // These dedicated siblings are Runtime configuration, never request inputs.
    let parent = path
        .parent()
        .filter(|p| p.parent().is_some() && *p != Path::new("/"))
        .ok_or_else(invalid)?;
    if path.file_name().and_then(|s| s.to_str()) != Some("traces")
        || std::env::var_os("HOME").is_some_and(|h| parent == Path::new(&h))
    {
        return Err(invalid());
    }
    let root = HostDirectory::open(path)?;
    let staging = HostDirectory::open(parent)?.private_child("staging")?;
    let build = root.private_child(".staging")?;
    staging.validate_path(&parent.join("staging"))?;
    build.validate_path(&path.join(".staging"))?;
    let sessions = Owners::open(&parent.join("staging"), &parent.join("staging"))?;
    let builds = Owners::open(&path.join(".staging"), path)?;
    let (a, b) = sessions.recover(false, checkpoint)?;
    let (c, d) = builds.recover(true, checkpoint)?;
    let before = crate::trace_inventory(path)?;
    if before["totalByteCount"] == "0" {
        return Ok(report(before.clone(), before, a + c, b + d, 0, 0));
    }
    let records = builds.records()?;
    let mut removed = 0;
    let mut skipped = 0;
    let inventory = HostDirectory::open_trace_inventory(path)?;
    for entry in crate::trace::maintenance_entries(path)? {
        let relative = format!("{}/{}", entry.trace, entry.parser);
        if !entry.valid {
            skipped += 1;
            continue;
        }
        let id =
            arkdeck_contract::sha256_hex(format!("{}:{}", entry.trace, entry.parser).as_bytes());
        let lock_name = format!("{id}.lock");
        let lease_name = format!("{id}.lease");
        let lock_root = match inventory.child(".locks") {
            Ok(d) => d,
            Err(e) if e.kind() == io::ErrorKind::NotFound => {
                skipped += 1;
                continue;
            }
            Err(e) => return Err(e),
        };
        let Some(key_lock) = lock_root.try_trace_lock_existing(&lock_name, Some(4096))? else {
            skipped += 1;
            continue;
        };
        let lease_root = match inventory.child(".leases") {
            Ok(d) => d,
            Err(e) if e.kind() == io::ErrorKind::NotFound => {
                skipped += 1;
                continue;
            }
            Err(e) => return Err(e),
        };
        let Some(lease) = lease_root.try_trace_lock_existing(&lease_name, None)? else {
            skipped += 1;
            continue;
        };
        let Some((base, _)) = records.iter().find(|(_, e)| {
            ["ready", "building"].contains(&e.state.as_str())
                && e.identity() == Some(entry.identity)
                && (e.state == "building" || e.relative_path == relative)
        }) else {
            skipped += 1;
            continue;
        };
        let Some(owner_lock) = builds.lock(base)? else {
            skipped += 1;
            continue;
        };
        let current = builds.reread(base, &owner_lock)?;
        if !["ready", "building"].contains(&current.state.as_str())
            || current.identity() != Some(entry.identity)
            || builds.locate(&current)?.as_deref() != Some(&relative)
        {
            skipped += 1;
            continue;
        }
        root.validate_path(path)?;
        key_lock.validate_link(&lock_root, &lock_name)?;
        lease.validate_link(&lease_root, &lease_name)?;
        let parent_identity = root.child(&entry.trace)?.directory_identity()?;
        builds.remove(base, &owner_lock, &current, &relative, checkpoint)?;
        removed += 1;
        match root.remove_empty_directory(&entry.trace, parent_identity) {
            Ok(()) => (),
            Err(e) if e.kind() == io::ErrorKind::DirectoryNotEmpty => (),
            Err(e) => return Err(e),
        }
    }
    root.validate_path(path)?;
    Ok(report(
        before,
        crate::trace_inventory(path)?,
        a + c,
        b + d,
        removed,
        skipped,
    ))
}

#[cfg(test)]
#[path = "trace_maintenance_tests.rs"]
mod tests;
