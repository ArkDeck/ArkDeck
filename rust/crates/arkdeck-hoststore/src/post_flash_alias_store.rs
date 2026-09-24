//! Swift `RockchipPostFlashHDCBindingStore`: the owner-only document under
//! the product's Application Support root (the parent of the daemon state
//! directory) that keeps an adopted Target usable after a flash rotates its
//! HDC serial, with its lock, its atomic commit, its archived epochs and its
//! reissue repair — over the `arkdeck_platform` host primitives, replaying
//! the Swift oracle (`rust/tests/fixtures/post-flash-alias`) byte for byte.
//! The decisions live in `post_flash_alias`; nothing here chooses.
use crate::post_flash_alias::{
    LiveTarget, ObservedHdc, PostFlashAliasError, PostFlashBinding, Publication, Reconciliation,
    admit, reissue, resolve,
};
use arkdeck_platform::{
    DocumentPublishError, ExclusiveOutcome, HostDirectory, OwnerOnlyReadFailure,
};
use std::path::{Path, PathBuf};

/// The store at one root. Reads take no lock, as Swift's do not; `publish`
/// and `reconcile_reissued_lineage` hold the store's lock, waited for.
pub struct PostFlashAliasStore {
    root: PathBuf,
}

impl PostFlashAliasStore {
    /// Swift `RockchipPostFlashHDCBindingStore.fileName`.
    pub const FILE_NAME: &'static str = "rockchip-post-flash-hdc-binding.json";
    /// Swift `lockName`, created empty and owner-only by the first writer.
    pub const LOCK_NAME: &'static str = ".rockchip-post-flash-hdc-binding.lock";
    /// Swift `maximumBytes`, the trailing newline included.
    pub const MAXIMUM_BYTES: usize = 64 * 1_024;

    /// Swift `init(rootURL:)`: nothing is touched until a call.
    pub fn new(root: &Path) -> Self {
        Self {
            root: root.to_path_buf(),
        }
    }

    /// Swift `loadIfPresent`: the root prepared, the document read without a
    /// lock — `None` when absent.
    pub fn load_if_present(&self) -> Result<Option<PostFlashBinding>, PostFlashAliasError> {
        let root = self.prepare_root()?;
        Self::load(&root)
    }

    /// Swift `publish(_:expectedPreviousHDCIdentitySHA256:)`: the candidate
    /// admitted before anything is touched, then, under the lock, the stored
    /// record read and the three-way resolution applied — the stored record
    /// returned unchanged for the same proof, the superseded epoch archived
    /// before a revision advance, the candidate committed and read back.
    pub fn publish(
        &self,
        candidate: &PostFlashBinding,
        expected_previous_hdc_identity_sha256: &str,
    ) -> Result<PostFlashBinding, PostFlashAliasError> {
        admit(candidate, expected_previous_hdc_identity_sha256)?;
        let root = self.prepare_root()?;
        let _lock = Self::lock(&root)?;
        let existing = Self::load(&root)?;
        match resolve(
            existing.as_ref(),
            candidate,
            expected_previous_hdc_identity_sha256,
        )? {
            Publication::Idempotent(stored) => Ok(stored.clone()),
            Publication::ArchiveThenCommit => {
                if let Some(existing) = &existing {
                    Self::archive_superseded(&root, existing)?;
                }
                Self::commit(&root, candidate)
            }
            Publication::Commit => Self::commit(&root, candidate),
        }
    }

    /// Swift `reconcileReissuedLineage`: under the lock, a stored alias ahead
    /// of the live Target that agrees with it and with the observed device on
    /// every identity fact is archived and republished at the live revision;
    /// anything else is `None` and writes nothing.
    pub fn reconcile_reissued_lineage(
        &self,
        target: &LiveTarget<'_>,
        observed: &ObservedHdc<'_>,
        now_utc: &str,
    ) -> Result<Option<Reconciliation>, PostFlashAliasError> {
        let root = self.prepare_root()?;
        let _lock = Self::lock(&root)?;
        let Some(existing) = Self::load(&root)? else {
            return Ok(None);
        };
        let Some(republished) = reissue(&existing, target, observed, now_utc) else {
            return Ok(None);
        };
        republished.validate()?;
        Self::archive_superseded(&root, &existing)?;
        Self::commit(&root, &republished)?;
        Ok(Some(Reconciliation {
            archived_revision: existing.binding_revision,
            published_revision: target.binding_revision,
            target_id: existing.target_id,
            hdc_identity_sha256: existing.hdc_identity_sha256,
        }))
    }

    /// Swift `prepareRoot`: an absolute root, created owner-only when absent
    /// and made owner-only whether or not it existed.
    fn prepare_root(&self) -> Result<HostDirectory, PostFlashAliasError> {
        if !self.root.is_absolute() {
            return Err(failure("post-flash binding root must be absolute"));
        }
        HostDirectory::open_or_create_private(&self.root)
            .map_err(|_| failure("post-flash binding root cannot be opened"))
    }

    /// Swift's blocking `flock(LOCK_EX)` on the owner-only lock file, which is
    /// never unlinked and never synchronized.
    fn lock(root: &HostDirectory) -> Result<arkdeck_platform::HostReadLock, PostFlashAliasError> {
        root.wait_lock(Self::LOCK_NAME, false)
            .map_err(|_| failure("post-flash binding lock cannot be acquired"))
    }

    /// Swift `load(rootDescriptor:)`: absence is `None`; a present document
    /// must be the owner's 0600 single-link regular file within the limit,
    /// decode, and validate — each refusal in Swift's words.
    fn load(root: &HostDirectory) -> Result<Option<PostFlashBinding>, PostFlashAliasError> {
        let Some(bytes) = root
            .read_owner_only_detailed(Self::FILE_NAME, Self::MAXIMUM_BYTES)
            .map_err(|refused| {
                failure(match refused {
                    OwnerOnlyReadFailure::Open(_) => "post-flash binding cannot be opened",
                    OwnerOnlyReadFailure::Identity => {
                        "post-flash binding must be an owner-only regular file"
                    }
                    OwnerOnlyReadFailure::Size => "post-flash binding size is invalid",
                    OwnerOnlyReadFailure::Truncated => "post-flash binding is truncated",
                })
            })?
        else {
            return Ok(None);
        };
        let record = PostFlashBinding::decode(&bytes)?;
        record.validate()?;
        Ok(Some(record))
    }

    /// Swift `commit`: the canonical bytes within the limit, written to a
    /// fresh owner-only temporary file, synchronized, renamed over the
    /// document, the directory synchronized, and the document read back and
    /// compared field for field.
    fn commit(
        root: &HostDirectory,
        candidate: &PostFlashBinding,
    ) -> Result<PostFlashBinding, PostFlashAliasError> {
        let bytes = candidate.encode()?;
        if bytes.len() > Self::MAXIMUM_BYTES {
            return Err(failure("post-flash binding document exceeds its limit"));
        }
        root.publish_document(Self::FILE_NAME, &bytes, Self::MAXIMUM_BYTES)
            .map_err(|error| match error {
                DocumentPublishError::BeforePublication(_) => {
                    failure("post-flash binding temporary file cannot be synchronized")
                }
                DocumentPublishError::OutcomeUnknown(_) => {
                    failure("post-flash binding cannot be committed")
                }
            })?;
        match Self::load(root)? {
            Some(readback) if readback == *candidate => Ok(readback),
            _ => Err(failure("post-flash binding readback failed")),
        }
    }

    /// Swift `archiveSuperseded`: the superseded record's bytes created once
    /// at its archive name; a name already holding exactly those bytes is the
    /// archive itself, any other occupant refuses the whole operation.
    fn archive_superseded(
        root: &HostDirectory,
        existing: &PostFlashBinding,
    ) -> Result<(), PostFlashAliasError> {
        let name = existing.archive_name();
        let bytes = existing.encode()?;
        match root.create_exclusive_or_match(&name, &bytes, Self::MAXIMUM_BYTES) {
            Ok(ExclusiveOutcome::Created | ExclusiveOutcome::Matched) => Ok(()),
            Ok(ExclusiveOutcome::Different) => Err(failure(format!(
                "superseded post-flash binding archive {name} already holds a different entry"
            ))),
            Err(_) => Err(failure(
                "superseded post-flash binding archive cannot be created",
            )),
        }
    }
}

fn failure(detail: impl Into<String>) -> PostFlashAliasError {
    PostFlashAliasError::new(detail)
}
