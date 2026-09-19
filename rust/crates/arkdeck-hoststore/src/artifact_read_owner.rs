//! Read-only Job Artifact source owner. Explicit export only writes the caller's
//! external destination. Artifact publication, import leases, quota mutation,
//! snapshot persistence and payload-verification-document writes stay separate.
use crate::artifact_usage::decode_index;
use arkdeck_platform::{HostDirectory, HostEntryKind, PayloadCheck};
use serde_json::Value;
use std::{
    io,
    path::{Path, PathBuf},
};

const MAX_INDEX: usize = 16 * 1024 * 1024;
const IMPORT_NAMESPACE: &str = ".imports-v1";
const IMPORT_OWNER_LOCK: &str = ".owner.lock";
const IMPORT_SKELETON: [&str; 3] = ["records", "identities", "payloads"];
pub const MAX_ARTIFACT_READ_BYTES: usize = 4_194_304;

pub struct ArtifactReadStore {
    root: HostDirectory,
    pub(crate) path: PathBuf,
    pub(crate) export_lock: std::sync::Mutex<()>,
    trace_retention: std::sync::Mutex<()>,
    fault: Option<PublicationFault>,
}

/// Where a Job product's publication can be stopped for a crash test.
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub enum ArtifactPublicationFault {
    /// The payload has its final name, still owner-writable; no index names it.
    AfterPayload,
    /// The payload is sealed owner read-only; no index names it.
    AfterSeal,
    /// The index names the product.
    AfterIndex,
}
type PublicationFault =
    std::sync::Arc<dyn Fn(ArtifactPublicationFault) -> io::Result<()> + Send + Sync>;

/// An in-memory immutable snapshot; it is deliberately not a Runtime wire cursor.
/// Holding this value retains its metadata even if the source index changes.
#[derive(Debug)]
pub struct ArtifactReadSnapshot {
    rows: Vec<Value>,
}

#[derive(Debug, PartialEq)]
pub struct ArtifactReadPage {
    pub items: Vec<Value>,
    pub next_offset: Option<usize>,
}

#[derive(Debug, PartialEq)]
pub struct ArtifactReadRange {
    pub artifact_id: String,
    pub sha256: String,
    pub offset: u64,
    pub next_offset: u64,
    pub total_byte_count: u64,
    pub eof: bool,
    pub bytes: Vec<u8>,
}

/// A published Job Artifact a lease names, resolved as Swift
/// `RuntimeArtifactStore.resolveLease` resolves it.
pub(crate) struct LeasedArtifact {
    pub(crate) job_id: String,
    pub(crate) artifact_id: String,
    pub(crate) row: Value,
    pub(crate) path: PathBuf,
}

/// Swift's interpolation of a `String`: quoted, with its escapes.
pub(crate) fn swift_string(text: &str) -> String {
    let mut quoted = String::with_capacity(text.len() + 2);
    quoted.push('"');
    for character in text.chars() {
        match character {
            '"' => quoted.push_str("\\\""),
            '\\' => quoted.push_str("\\\\"),
            '\n' => quoted.push_str("\\n"),
            '\r' => quoted.push_str("\\r"),
            '\t' => quoted.push_str("\\t"),
            '\0' => quoted.push_str("\\0"),
            other => quoted.push(other),
        }
    }
    quoted.push('"');
    quoted
}

/// Swift's interpolation of a `RuntimeArtifactError`, which has no
/// description of its own: the case name and its quoted payload.
fn swift_artifact_error(case: &str, payload: &str) -> String {
    format!("{case}({})", swift_string(payload))
}

fn invalid_input() -> io::Error {
    io::Error::new(
        io::ErrorKind::InvalidInput,
        "Invalid Artifact reference or range",
    )
}
fn corrupt() -> io::Error {
    io::Error::new(
        io::ErrorKind::InvalidData,
        "Artifact inventory or payload changed or is unreadable",
    )
}
fn not_found() -> io::Error {
    io::Error::new(
        io::ErrorKind::NotFound,
        "Artifact has no published content or does not exist",
    )
}
fn job_id(value: &str) -> bool {
    if value.starts_with("imp-") {
        return arkdeck_contract::import_id(value);
    }
    !value.is_empty()
        && value.len() <= 128
        && value
            .bytes()
            .all(|b| b.is_ascii_alphanumeric() || b"-_".contains(&b))
}

impl ArtifactReadSnapshot {
    pub fn len(&self) -> usize {
        self.rows.len()
    }
    pub fn is_empty(&self) -> bool {
        self.rows.is_empty()
    }
    /// Rows retain the frozen durable metadata field set and sort by
    /// parsed creation time descending, then artifactID ascending (UTF-8 byte order).
    pub fn page(&self, offset: usize, page_size: usize) -> io::Result<ArtifactReadPage> {
        if !(1..=1000).contains(&page_size) || offset > self.rows.len() {
            return Err(invalid_input());
        }
        let end = offset.saturating_add(page_size).min(self.rows.len());
        Ok(ArtifactReadPage {
            items: self.rows[offset..end].to_vec(),
            next_offset: (end < self.rows.len()).then_some(end),
        })
    }
}

impl ArtifactReadStore {
    pub fn open(path: &Path) -> io::Result<Self> {
        Ok(Self {
            root: HostDirectory::open(path)?,
            path: path.into(),
            export_lock: std::sync::Mutex::new(()),
            trace_retention: std::sync::Mutex::new(()),
            fault: None,
        })
    }

    /// Bounded host fault injection for crash tests, never a wire field: the
    /// production composition opens the store with `open`.
    pub fn open_with_fault(path: &Path, fault: PublicationFault) -> io::Result<Self> {
        Ok(Self {
            fault: Some(fault),
            ..Self::open(path)?
        })
    }

    pub(crate) fn publication_fault(&self, point: ArtifactPublicationFault) -> io::Result<()> {
        match &self.fault {
            Some(fault) => fault(point),
            None => Ok(()),
        }
    }

    pub(crate) fn root(&self) -> &HostDirectory {
        &self.root
    }

    /// Swift `directory(for:)`: a Job's private Artifact directory, created
    /// on first use under the root this owner opened.
    pub(crate) fn job_directory(&self, id: &str) -> io::Result<HostDirectory> {
        if !job_id(id) {
            return Err(invalid_input());
        }
        self.root.validate_path(&self.path)?;
        self.root.private_child(id)
    }

    pub(crate) fn index(&self, id: &str) -> io::Result<(HostDirectory, Vec<u8>, Vec<Value>)> {
        if !job_id(id) {
            return Err(invalid_input());
        }
        self.root.validate_path(&self.path)?;
        let job = self.root.child(id)?;
        let bytes = match job.read("index.json", MAX_INDEX) {
            Ok(bytes) => bytes,
            Err(error) if error.kind() == io::ErrorKind::NotFound => Vec::new(),
            Err(error) => return Err(error),
        };
        let rows = if bytes.is_empty() {
            // A present empty document is corrupt, not an empty inventory.
            if job.document_metadata("index.json").is_ok() {
                return Err(corrupt());
            }
            Vec::new()
        } else {
            decode_index(&bytes, id)?
        };
        Ok((job, bytes, rows))
    }

    pub(crate) fn unchanged(&self, id: &str, job: &HostDirectory, index: &[u8]) -> io::Result<()> {
        match job.read("index.json", MAX_INDEX) {
            Ok(current) if !index.is_empty() && current == index => (),
            Err(error) if index.is_empty() && error.kind() == io::ErrorKind::NotFound => (),
            _ => return Err(corrupt()),
        }
        job.validate_path(&self.path.join(id))?;
        self.root.validate_path(&self.path)
    }

    fn verified_rows(&self, job_id: &str) -> io::Result<Vec<Value>> {
        let (job, index, rows) = self.index(job_id)?;
        for row in &rows {
            if row["status"].get("published").is_some() {
                job.verify_payload(
                    row["artifactID"].as_str().ok_or_else(corrupt)?,
                    row["byteCount"].as_u64().ok_or_else(corrupt)?,
                    row["sha256"].as_str().ok_or_else(corrupt)?,
                )?;
            }
        }
        self.unchanged(job_id, &job, &index)?;
        Ok(rows)
    }

    /// Keep the real Artifact census guarded through Trace maintenance. The
    /// read owner cannot yet prove any retained reference inactive, including
    /// cleanup debt, so any Job directory, unknown namespace or retained file
    /// preserves every Trace entry. The Import owner creates its empty
    /// `.imports-v1` skeleton at startup; that namespace retains Trace data
    /// only while it holds an upload record, identity or payload, or anything
    /// this owner does not recognise. Future Artifact writers must join this
    /// guard before publication.
    pub fn with_trace_retention<R>(&self, action: impl FnOnce(bool) -> R) -> io::Result<R> {
        let _guard = self.trace_retention.lock().map_err(|_| corrupt())?;
        self.root.validate_path(&self.path)?;
        let names = self.root.names(4096)?;
        let mut retain_all = false;
        for name in &names {
            if name == IMPORT_NAMESPACE
                && self.root.owned_kind_and_size(name)?.0 == HostEntryKind::Directory
            {
                retain_all |= Self::import_namespace_retains(&self.root.child(name)?)?;
            } else {
                retain_all = true;
            }
        }
        let mut visited = 0;
        Self::inspect_retained_tree(&self.root, 0, &mut visited)?;
        // Validate supported Job indices rather than hiding corrupt known
        // metadata behind a nonempty-directory signal. Unknown namespaces are
        // retained, never decoded into a guessed inactive interpretation.
        for name in &names {
            if job_id(name) && self.root.owned_kind_and_size(name)?.0 == HostEntryKind::Directory {
                let job = self.root.child(name)?;
                match job.read("index.json", MAX_INDEX) {
                    Ok(bytes) => {
                        decode_index(&bytes, name)?;
                    }
                    Err(error) if error.kind() == io::ErrorKind::NotFound => (),
                    Err(error) => return Err(error),
                }
            }
        }
        if self.root.names(4096)? != names {
            return Err(corrupt());
        }
        self.root.validate_path(&self.path)?;
        let result = action(retain_all);
        self.root.validate_path(&self.path)?;
        Ok(result)
    }

    /// The retention guard's lock alone, for the retention sweep: it excludes
    /// every publication and Trace maintenance, as the guard does, without
    /// the Trace census, whose bound on the Artifact tree the sweep exists to
    /// bring the store back under.
    pub(crate) fn with_retention_lock<R>(&self, action: impl FnOnce() -> R) -> io::Result<R> {
        let _guard = self.trace_retention.lock().map_err(|_| corrupt())?;
        self.root.validate_path(&self.path)?;
        let result = action();
        self.root.validate_path(&self.path)?;
        Ok(result)
    }

    /// The idle Import skeleton is `records`, `identities` and `payloads`
    /// beside the owner lock. Any member of those directories, and any other
    /// entry, is retained state this read owner cannot interpret.
    fn import_namespace_retains(imports: &HostDirectory) -> io::Result<bool> {
        let mut retained = false;
        for name in imports.names(4096)? {
            match imports.owned_kind_and_size(&name)?.0 {
                HostEntryKind::Directory if IMPORT_SKELETON.contains(&name.as_str()) => {
                    retained |= !imports.child(&name)?.names(4096)?.is_empty();
                }
                HostEntryKind::Regular if name == IMPORT_OWNER_LOCK => (),
                HostEntryKind::Other => return Err(corrupt()),
                _ => retained = true,
            }
        }
        Ok(retained)
    }

    fn inspect_retained_tree(
        directory: &HostDirectory,
        depth: usize,
        visited: &mut usize,
    ) -> io::Result<()> {
        for name in directory.names(4096)? {
            *visited += 1;
            if *visited > 4096 {
                return Err(corrupt());
            }
            match directory.owned_kind_and_size(&name)?.0 {
                HostEntryKind::Directory => {
                    if depth >= 8 {
                        return Err(corrupt());
                    }
                    Self::inspect_retained_tree(&directory.child(&name)?, depth + 1, visited)?;
                }
                HostEntryKind::Regular => {
                    directory.document_metadata(&name)?;
                }
                HostEntryKind::Other => return Err(corrupt()),
            }
        }
        Ok(())
    }

    pub fn list(&self, job_id: &str) -> io::Result<ArtifactReadSnapshot> {
        let mut dated = self
            .verified_rows(job_id)?
            .into_iter()
            .map(|row| {
                let date = crate::format_time::format_timestamp_seconds(
                    row["createdAtUTC"].as_str().ok_or_else(corrupt)?,
                )
                .ok_or_else(corrupt)?;
                Ok((date, row))
            })
            .collect::<io::Result<Vec<_>>>()?;
        dated.sort_by(|(left_date, left), (right_date, right)| {
            right_date.total_cmp(left_date).then_with(|| {
                left["artifactID"]
                    .as_str()
                    .cmp(&right["artifactID"].as_str())
            })
        });
        let rows = dated.into_iter().map(|(_, row)| row).collect();
        Ok(ArtifactReadSnapshot { rows })
    }

    /// Swift `list(jobID:)` as `artifact.list` reads it: a Job without an
    /// Artifact directory has no Artifact (Swift creates the directory as it
    /// reads; this reader writes nothing).
    pub(crate) fn listed_rows(&self, job_id: &str) -> io::Result<Vec<Value>> {
        if let Err(error) = self.root.kind_and_size(job_id)
            && error.kind() == io::ErrorKind::NotFound
        {
            return Ok(Vec::new());
        }
        Ok(self.list(job_id)?.rows)
    }

    pub fn inspect(&self, job_id: &str, artifact_id: &str) -> io::Result<Value> {
        self.verified_rows(job_id)?
            .into_iter()
            .find(|row| row["artifactID"] == artifact_id)
            .ok_or_else(not_found)
    }

    /// Swift `RuntimeArtifactStore.resolveLease` for a Job Artifact: the
    /// published row and the payload path the Artifact store names, the
    /// payload opened through no link and hashed. A refusal is the
    /// `RuntimeArtifactError` Swift throws, spelled as Swift interpolates it,
    /// because Swift planning reports that spelling. Unlike Swift, a missing
    /// Job directory is not created and a verified payload is not resealed.
    /// Import leases belong to the Import owner and are not resolved here.
    pub(crate) fn lease(&self, reference: &str) -> Result<LeasedArtifact, String> {
        let parts: Vec<&str> = reference.split(':').collect();
        if parts.len() != 3 || parts[0] != "lease-v1" {
            return Err(swift_artifact_error(
                "artifactNotFound",
                "malformed Artifact lease",
            ));
        }
        let (job_id, artifact_id) = (parts[1], parts[2]);
        // Swift `directory(for:)`.
        if job_id.is_empty()
            || job_id.len() > 128
            || !job_id
                .bytes()
                .all(|byte| byte.is_ascii_alphanumeric() || b"-_".contains(&byte))
        {
            return Err(swift_artifact_error(
                "ioFailure",
                "malformed job identifier",
            ));
        }
        if job_id.starts_with("imp-") {
            return Err("an Import lease is resolved by the Import owner".into());
        }
        self.owned_lease(job_id, artifact_id)
    }

    /// Import callers must have verified their receipt under the lifetime lock.
    pub(crate) fn owned_lease(
        &self,
        job_id: &str,
        artifact_id: &str,
    ) -> Result<LeasedArtifact, String> {
        let unreadable = || swift_artifact_error("indexCorrupted", "artifact index is unreadable");
        let absent = || swift_artifact_error("artifactNotFound", artifact_id);
        let (job, index, rows) = match self.index(job_id) {
            Ok(found) => found,
            Err(error) if error.kind() == io::ErrorKind::NotFound => return Err(absent()),
            Err(_) => return Err(unreadable()),
        };
        let row = rows
            .into_iter()
            .find(|row| row["artifactID"] == artifact_id)
            .ok_or_else(absent)?;
        let digest = row["sha256"]
            .as_str()
            .filter(|digest| digest.len() == 64 && row["status"].get("published").is_some())
            .ok_or_else(|| {
                swift_artifact_error("artifactNotFound", "Artifact lease is not readable")
            })?;
        let length = row["byteCount"].as_u64().ok_or_else(unreadable)?;
        let drifted = |detail: &str| Err(swift_artifact_error("indexCorrupted", detail));
        match job.check_payload(artifact_id, length, digest) {
            Ok(PayloadCheck::Verified) => (),
            Ok(PayloadCheck::Unopenable(errno)) => {
                return drifted(&format!(
                    "artifact payload is missing, linked or unreadable (errno {errno})"
                ));
            }
            Ok(PayloadCheck::TypeOrSize) => {
                return drifted("artifact payload type or size drifted");
            }
            Ok(PayloadCheck::DigestOrIdentity) | Err(_) => {
                return drifted("artifact payload digest or identity drifted");
            }
        }
        self.unchanged(job_id, &job, &index)
            .map_err(|_| unreadable())?;
        Ok(LeasedArtifact {
            job_id: job_id.to_owned(),
            artifact_id: artifact_id.to_owned(),
            path: self.path.join(job_id).join(artifact_id),
            row,
        })
    }

    /// Whether a leased payload still holds exactly its published bytes, read
    /// through no link; Swift's analyzer action re-reads them before lowering.
    pub(crate) fn payload_matches(&self, leased: &LeasedArtifact) -> bool {
        let (Some(length), Some(digest)) = (
            leased.row["byteCount"].as_u64(),
            leased.row["sha256"].as_str(),
        ) else {
            return false;
        };
        self.root
            .child(&leased.job_id)
            .and_then(|job| job.check_payload(&leased.artifact_id, length, digest))
            .is_ok_and(|check| check == PayloadCheck::Verified)
    }

    pub fn read(
        &self,
        job_id: &str,
        artifact_id: &str,
        offset: u64,
        maximum_bytes: usize,
        allow_sensitive: bool,
    ) -> io::Result<ArtifactReadRange> {
        self.read_with_metadata(job_id, artifact_id, offset, maximum_bytes, allow_sensitive)
            .map(|(_, range)| range)
    }

    pub(crate) fn read_with_metadata(
        &self,
        job_id: &str,
        artifact_id: &str,
        offset: u64,
        maximum_bytes: usize,
        allow_sensitive: bool,
    ) -> io::Result<(Value, ArtifactReadRange)> {
        if maximum_bytes == 0 || maximum_bytes > MAX_ARTIFACT_READ_BYTES {
            return Err(invalid_input());
        }
        let (job, index, rows) = self.index(job_id)?;
        let row = rows
            .iter()
            .find(|row| row["artifactID"] == artifact_id)
            .ok_or_else(not_found)?;
        let length = row["byteCount"].as_u64().ok_or_else(corrupt)?;
        if offset > length {
            return Err(invalid_input());
        }
        if row["status"].get("published").is_none() {
            return Err(not_found());
        }
        if row["privacy"] == "sensitive" && !allow_sensitive {
            return Err(io::Error::new(
                io::ErrorKind::PermissionDenied,
                "Sensitive Artifact requires explicit opt-in",
            ));
        }
        // Match list/inspect fail-closed behavior for other indexed publications.
        for other in &rows {
            if other["artifactID"] != artifact_id && other["status"].get("published").is_some() {
                job.verify_payload(
                    other["artifactID"].as_str().ok_or_else(corrupt)?,
                    other["byteCount"].as_u64().ok_or_else(corrupt)?,
                    other["sha256"].as_str().ok_or_else(corrupt)?,
                )?;
            }
        }
        let digest = row["sha256"].as_str().ok_or_else(corrupt)?;
        let bytes = job.verify_payload_range(artifact_id, length, digest, offset, maximum_bytes)?;
        self.unchanged(job_id, &job, &index)?;
        let next_offset = offset + bytes.len() as u64;
        Ok((
            row.clone(),
            ArtifactReadRange {
                artifact_id: artifact_id.into(),
                sha256: digest.into(),
                offset,
                next_offset,
                total_byte_count: length,
                eof: next_offset == length,
                bytes,
            },
        ))
    }
}
