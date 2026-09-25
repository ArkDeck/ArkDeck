//! What a Flash reads of the Job owner's state root beyond its Jobs: the
//! superseding recovery epochs (Swift `RuntimeSupersedingRecoveryStore`).
use super::JobStore;
use crate::{RecoveryEpoch, RecoveryEpochError};

impl JobStore {
    /// Swift `RuntimeSupersedingRecoveryStore.list()`: every epoch, read
    /// under the store's exclusive lock, which Swift's read also creates.
    pub(crate) fn recovery_epochs(&self) -> Result<Vec<RecoveryEpoch>, RecoveryEpochError> {
        crate::list_recovery_epochs(&self.root)
    }
}
