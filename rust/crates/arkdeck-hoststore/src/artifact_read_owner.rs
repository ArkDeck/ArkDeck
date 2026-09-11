//! Read-only Job Artifact owner. No publication, import leases, quota mutation,
//! snapshot persistence or payload-verification-document writes occur here.
use crate::artifact_usage::decode_index;
use arkdeck_platform::HostDirectory;
use serde_json::Value;
use std::{
    io,
    path::{Path, PathBuf},
};

const MAX_INDEX: usize = 16 * 1024 * 1024;
pub const MAX_ARTIFACT_READ_BYTES: usize = 4_194_304;

pub struct ArtifactReadStore {
    root: HostDirectory,
    path: PathBuf,
}

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
    !value.is_empty()
        && !value.starts_with("imp-")
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
        })
    }

    fn index(&self, id: &str) -> io::Result<(HostDirectory, Vec<u8>, Vec<Value>)> {
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

    fn unchanged(&self, id: &str, job: &HostDirectory, index: &[u8]) -> io::Result<()> {
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

    pub fn inspect(&self, job_id: &str, artifact_id: &str) -> io::Result<Value> {
        self.verified_rows(job_id)?
            .into_iter()
            .find(|row| row["artifactID"] == artifact_id)
            .ok_or_else(not_found)
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
