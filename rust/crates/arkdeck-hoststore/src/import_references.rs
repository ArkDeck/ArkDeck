//! Exact typed Import references and a complete, read-only durable Job census.
//! This grants no execution authority and never repairs uncertain history.
use super::*;
use crate::operation_catalog::CatalogOperation;
use crate::operation_request::OperationRequest;
use std::collections::{BTreeMap, BTreeSet};

#[derive(Clone, Debug, Eq, PartialEq, Ord, PartialOrd)]
pub(crate) struct ImportReference {
    pub(crate) value: String,
    pub(crate) import_id: String,
    pub(crate) artifact_id: String,
}
impl ImportReference {
    pub(crate) fn parse(value: &str) -> Result<Option<Self>, WireError> {
        let parts: Vec<_> = value.split(':').collect();
        if parts.len() < 2 || parts[0] != "lease-v1" || !parts[1].starts_with("imp-") {
            return Ok(None);
        }
        if parts.len() != 3
            || !arkdeck_contract::import_id(parts[1])
            || parts[2].len() != 36
            || !parts[2].starts_with("ART-")
            || !parts[2][4..]
                .bytes()
                .all(|c| c.is_ascii_digit() || (b'a'..=b'f').contains(&c))
        {
            return Err(failure(
                "invalidInput",
                "imported input requires an exact registered lease",
            ));
        }
        Ok(Some(Self {
            value: value.into(),
            import_id: parts[1].into(),
            artifact_id: parts[2].into(),
        }))
    }
    pub(crate) fn inputs(
        inputs: &Map<String, Value>,
        descriptor: &CatalogOperation,
    ) -> Result<Vec<Self>, WireError> {
        let malformed = || failure("invalidInput", "Import input references are malformed");
        if inputs
            .keys()
            .any(|key| !descriptor.inputs.iter().any(|field| &field.name == key))
        {
            return Err(malformed());
        }
        let mut found = BTreeSet::new();
        for field in &descriptor.inputs {
            if field.required && !inputs.contains_key(&field.name) {
                return Err(malformed());
            }
            let values: Vec<&Value> = match (field.kind.as_str(), inputs.get(&field.name)) {
                ("artifactLease" | "artifactReference", Some(value)) => vec![value],
                ("artifactLeaseArray", Some(Value::Array(items))) => items.iter().collect(),
                ("artifactLeaseArray", Some(_)) => return Err(malformed()),
                _ => continue,
            };
            for value in values {
                if let Some(reference) = Self::parse(value.as_str().ok_or_else(malformed)?)? {
                    found.insert(reference);
                }
            }
        }
        Ok(found.into_iter().collect())
    }
}

fn shaped(value: &Value, found: &mut BTreeSet<ImportReference>) {
    match value {
        Value::String(text) => {
            if let Ok(Some(reference)) = ImportReference::parse(text) {
                found.insert(reference);
            }
        }
        Value::Array(values) => {
            for value in values {
                shaped(value, found);
            }
        }
        _ => (),
    }
}

impl JobStore {
    /// Caller holds the Import lifetime mutex through this census and its
    /// release checkpoint. Every admission bridges that interval with a hold.
    pub(crate) fn with_import_references<R>(
        &self,
        import: &str,
        action: impl FnOnce(&[(String, bool)]) -> Result<R, WireError>,
    ) -> Result<R, WireError> {
        let _guard = self.activity.lock().map_err(unreadable)?;
        self.root.validate_path(&self.path).map_err(unreadable)?;
        let rows = self.repository.rows(None).map_err(unreadable)?;
        let indexed: BTreeSet<_> = rows.iter().map(|row| row.id.as_str()).collect();
        let mut directories = BTreeMap::new();
        match self.root.child("jobs") {
            Ok(jobs) => {
                for id in jobs.names(100_000).map_err(unreadable)? {
                    if !indexed.contains(id.as_str()) {
                        return Err(unreadable(()));
                    }
                    directories.insert(id.clone(), jobs.child(&id).map_err(unreadable)?);
                }
            }
            Err(error) if error.kind() == io::ErrorKind::NotFound => (),
            Err(error) => return Err(unreadable(error)),
        }
        let mut found = Vec::new();
        for row in &rows {
            let record = JobRecord::from_row(row)?;
            if !record.verifies_submission(&row.request_hash) {
                return Err(unreadable(()));
            }
            // Rust persists the record before advancing SQLite. A crash between
            // those writes must not hide a later uncertain input owner.
            if crate::job_record::terminal(&record.state) && !directories.contains_key(&row.id) {
                // Every durable terminal transition has a Journal. A missing
                // directory cannot prove that this input owner ended safely.
                return Err(unreadable(()));
            }
            if let Some(directory) = directories.get(&row.id) {
                match directory.read("job-record.json", RECORD_BOUND) {
                    Ok(bytes) => {
                        if JobRecord::decode(&bytes)?.value()? != record.value()? {
                            return Err(unreadable(()));
                        }
                    }
                    Err(error)
                        if error.kind() == io::ErrorKind::NotFound
                            && !crate::job_record::terminal(&record.state) => {}
                    Err(error) => return Err(unreadable(error)),
                }
                if crate::job_record::terminal(&record.state) && !record.outcome_unknown() {
                    let bytes = directory
                        .read("journal.jsonl", 64 * 1024 * 1024)
                        .map_err(unreadable)?;
                    for line in bytes
                        .split(|byte| *byte == b'\n')
                        .filter(|line| !line.is_empty())
                    {
                        let event =
                            crate::job_journal::JournalEvent::decode(line).map_err(unreadable)?;
                        if event.job_id() != row.id
                            || event.session_id() != format!("session-{}", row.id)
                        {
                            return Err(unreadable(()));
                        }
                    }
                    let replay = crate::job_journal_replay::ReplayState::replay(&bytes)
                        .map_err(unreadable)?;
                    let facts = replay.state.facts(replay.torn);
                    if facts.has_torn_tail
                        || facts.current_state.as_deref() != Some(&record.state)
                        || !facts.finalized
                        || !facts.outstanding_intents.is_empty()
                        || !facts.unknown_outcomes.is_empty()
                        || facts.requires_unknown_finalized_outcome
                    {
                        return Err(unreadable(()));
                    }
                }
            }
            if !record.requires_session_retention() {
                continue;
            }
            let request =
                OperationRequest::decode(&serde_json::to_vec(&record.request).map_err(unreadable)?)
                    .map_err(unreadable)?;
            let refs = if record.catalog_digest() == arkdeck_contract::CATALOG_DIGEST {
                if let Some(descriptor) =
                    CatalogOperation::lookup(&request.operation_id, request.operation_version)
                {
                    ImportReference::inputs(&request.inputs, descriptor).map_err(unreadable)?
                } else {
                    let mut refs = BTreeSet::new();
                    for value in request.inputs.values() {
                        shaped(value, &mut refs);
                    }
                    refs.into_iter().collect()
                }
            } else {
                let mut refs = BTreeSet::new();
                for value in request.inputs.values() {
                    shaped(value, &mut refs);
                }
                refs.into_iter().collect()
            };
            if refs.iter().any(|reference| reference.import_id == import) {
                if found.len() >= 1000 {
                    return Err(failure(
                        "inputTooLarge",
                        "Import reference inspection exceeds its Job bound",
                    ));
                }
                found.push((record.job_id.clone(), record.outcome_unknown()));
            }
        }
        found.sort();
        action(&found)
    }
}
