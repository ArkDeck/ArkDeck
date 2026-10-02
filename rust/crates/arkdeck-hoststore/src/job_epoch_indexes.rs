//! Swift `recoveryEpochIndexes`: which superseding recovery epochs name a Job,
//! as every Job read projects them (`job.status`, `job.show`, `job.list`).
//! On Windows the reader is the same, so an epoch a complete-overwrite Flash
//! established (TASK-XPA-010) reads as on macOS.
use super::JobStore;
use crate::job_record::JobRecord;
use arkdeck_platform::HostDirectory;
use serde_json::{Value, json};
use std::collections::BTreeMap;
use std::io;

/// Swift `recoveryEpochIndexes`: for each Job, the epoch that superseded its
/// unknown intents and the epoch it established as the recovery.
#[derive(Default)]
pub(crate) struct EpochIndexes {
    superseded_by: BTreeMap<String, String>,
    established: BTreeMap<String, String>,
}

impl EpochIndexes {
    /// A Job's status with the epochs that name it.
    pub(crate) fn project(&self, job_id: &str, status: &mut Value) {
        if let Some(epoch) = self.superseded_by.get(job_id) {
            status["supersededByRecoveryEpochId"] = json!(epoch);
        }
        if let Some(epoch) = self.established.get(job_id) {
            status["recoveryEpochId"] = json!(epoch);
        }
    }

    /// A Job's history summary with the epochs that name it: an unknown
    /// outcome an epoch superseded no longer keeps a terminal Job current
    /// (Swift `isCurrentJob`).
    pub(crate) fn project_history(&self, record: &JobRecord, summary: &mut Value) {
        self.project(&record.job_id, summary);
        if self.superseded_by.contains_key(&record.job_id) {
            summary["current"] = json!(
                !crate::job_record::terminal(&record.state) || record.residues().unwrap_or(0) > 0
            );
        }
    }
}

/// The epoch document's probe before it is read: the store's private
/// document metadata on macOS (`document_metadata`: an owner-only regular
/// file, opened through no link); on Windows the store's owner check of the
/// entry, which refuses the same things.
#[cfg(target_os = "macos")]
pub(super) fn probe_private_document(root: &HostDirectory, name: &str) -> io::Result<()> {
    root.document_metadata(name).map(drop)
}

#[cfg(windows)]
pub(super) fn probe_private_document(root: &HostDirectory, name: &str) -> io::Result<()> {
    match root.owned_kind_and_size(name)? {
        (arkdeck_platform::HostEntryKind::Regular, _) => Ok(()),
        _ => Err(io::Error::new(
            io::ErrorKind::InvalidData,
            "not a private document",
        )),
    }
}

impl JobStore {
    /// Swift `recoveryEpochIndexes`. An absent or unreadable epoch document
    /// indexes nothing. Swift's read would also create the store's lock and
    /// an empty Target store below the state root, which this read does not
    /// create.
    pub(crate) fn epoch_indexes(&self) -> EpochIndexes {
        let mut indexes = EpochIndexes::default();
        if probe_private_document(&self.root, crate::RECOVERY_EPOCH_DOCUMENT).is_err() {
            return indexes;
        }
        for epoch in self.recovery_epochs().unwrap_or_default() {
            indexes
                .established
                .insert(epoch.draft.recovery_job_id.clone(), epoch.epoch_id.clone());
            for intent in &epoch.draft.covered_intents {
                indexes
                    .superseded_by
                    .insert(intent.job_id.clone(), epoch.epoch_id.clone());
            }
        }
        indexes
    }

    /// A Job's status as Swift's readers project it, with the recovery
    /// epochs that name it.
    pub(crate) fn indexed_status(&self, record: &JobRecord) -> Value {
        let mut status = record.status();
        self.epoch_indexes().project(&record.job_id, &mut status);
        status
    }
}
