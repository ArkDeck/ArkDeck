//! The bundle index's durable references (Swift `BootstrapBundleRegistry.
//! acquire`, `retainOnly` and `releaseAll`, CHG-2026-074): a trusted product
//! owner pins the exact bundle generation it installs before it changes any
//! state outside this store, keeps only the bundle it installed once that
//! change succeeded, and releases its pins once it has removed what it
//! installed. The CLI's zero-Runtime `runtime service install` and
//! `runtime service uninstall` are that owner, as `installation/
//! runtime-service-installation`.
//!
//! Each runs as Swift's does under the store's one lock, taken without
//! waiting: the bundle index strictly read (published empty first when it is
//! absent and nothing it would describe is retained, as the tool ledger reads
//! it), the retained content of the records Swift verifies verified again
//! (natively, against the store's helper policy), and the index published as
//! Swift's canonical bytes — by `acquire` only when it added a pin, by the
//! other two always. A refusal publishes no pin change (an absent index may
//! still have been published empty first, as Swift's reader does): a pin
//! that outlives its owner leaks storage, never the bytes an installation
//! runs.
use crate::BundleRegistryReadStore;
use crate::registry::{BundleIndex, Owner, identifier, read_bundles};
use crate::store::{self, BUNDLES, MAX_INDEX, binding, failure, index_bytes};
use arkdeck_contract::{WireError, canonical_json};
use arkdeck_platform::{DocumentPublishError, HostReadLock};
use std::{io, path::PathBuf};

/// Swift `ReferenceKind`: every kind of owner a retained bundle can have.
const KINDS: [&str; 9] = [
    "installation",
    "rollback",
    "controlAction",
    "job",
    "recovery",
    "agentExecution",
    "activeLease",
    "activeSelection",
    "workspacePreset",
];

/// Swift `BootstrapBundleRegistry.ReferenceOwner`: a closed kind and an
/// identifier.
#[derive(Clone, Debug, PartialEq, Eq)]
pub struct ReferenceOwner(Owner);

impl ReferenceOwner {
    /// Swift `ReferenceOwner(kind:id:)`: refused as `invalidInput` unless the
    /// kind is one Swift has and the identifier is a bounded identifier.
    pub fn new(kind: &str, id: &str) -> Result<Self, WireError> {
        if !KINDS.contains(&kind) || !identifier(id) {
            return Err(failure("invalidInput", "invalid bundle reference owner"));
        }
        Ok(Self(Owner {
            kind: kind.into(),
            id: id.into(),
        }))
    }

    /// The service installation's one owner, as Swift's CLI names it.
    pub fn service_installation() -> Self {
        Self(Owner {
            kind: "installation".into(),
            id: "runtime-service-installation".into(),
        })
    }
}

fn index_unreadable() -> WireError {
    failure(
        "recordUnreadable",
        "bundle index failed bounded schema and identity validation",
    )
}

/// Swift `saveIndex`'s refusals: the rename that publishes the index, then
/// the directory's flush after it.
fn publication(error: DocumentPublishError) -> WireError {
    match error {
        DocumentPublishError::BeforePublication(_) => {
            failure("recordUnreadable", "cannot commit bundle index")
        }
        DocumentPublishError::OutcomeUnknown(_) => failure(
            "outcomeUnknown",
            "bundle index was published but durability is unconfirmed; inspect the exact reference",
        ),
    }
}

/// One operation's hold on the store: its lock, the index as read, and the
/// index decoded.
struct Transaction<'a> {
    store: &'a BundleRegistryReadStore,
    lock: HostReadLock,
    bytes: Vec<u8>,
    index: BundleIndex,
}

impl BundleRegistryReadStore {
    /// Swift `locked`: the lock taken without waiting, the bundle index read,
    /// `body`, and the store still the one locked.
    fn transaction<T>(
        &self,
        body: impl FnOnce(&mut Transaction<'_>) -> Result<T, WireError>,
    ) -> Result<T, WireError> {
        let lock = store::lock(&self.root, &self.path)?;
        let bytes = index_bytes(&self.root, &self.path, &lock, BUNDLES)?;
        let (index, _) = read_bundles(&bytes).map_err(|_| index_unreadable())?;
        let mut transaction = Transaction {
            store: self,
            lock,
            bytes,
            index,
        };
        let result = body(&mut transaction)?;
        binding(&self.root, &self.path, &transaction.lock)?;
        Ok(result)
    }

    /// Swift `acquire`: the exact available generation pinned for `owner`
    /// (the index published only when the pin is new), and the retained
    /// content's path. It precedes any external intent.
    pub fn acquire(
        &self,
        reference: &str,
        expected_generation: &str,
        owner: &ReferenceOwner,
    ) -> Result<PathBuf, WireError> {
        self.transaction(|transaction| {
            let position = transaction.find(reference)?;
            let record = &transaction.index.records[position];
            if record.state != "available" || expected_generation != record.generation.to_string() {
                return Err(failure(
                    "resourceConflict",
                    "bundle is removed or its generation changed",
                ));
            }
            transaction.verify(position)?;
            let references = &mut transaction.index.records[position].references;
            if !references.contains(&owner.0) {
                if references.len() >= 1024 {
                    return Err(failure("quotaExceeded", "bundle reference bound reached"));
                }
                references.push(owner.0.clone());
                sort(references);
                transaction.save()?;
            }
            Ok(transaction.content(position))
        })
    }

    /// Swift `retainOnly`: once the installation `owner` pinned succeeded,
    /// every other bundle's pin for it released. The exact bundle must still
    /// hold the pin; every record's retained content is verified first; the
    /// index is published even when nothing else held one.
    pub fn retain_only(&self, reference: &str, owner: &ReferenceOwner) -> Result<(), WireError> {
        self.transaction(|transaction| {
            let position = transaction.find(reference)?;
            let selected = &transaction.index.records[position];
            if selected.state != "available" || !selected.references.contains(&owner.0) {
                return Err(failure(
                    "resourceConflict",
                    "installed bundle does not hold its durable installation reference",
                ));
            }
            for each in 0..transaction.index.records.len() {
                transaction.verify(each)?;
            }
            for (other, record) in transaction.index.records.iter_mut().enumerate() {
                if other != position {
                    record.references.retain(|held| *held != owner.0);
                }
            }
            transaction.save()
        })
    }

    /// Swift `releaseAll`: after what `owner` installed is confirmed removed,
    /// every pin it holds released. Every record's retained content is
    /// verified first; the index is published even when it held none.
    pub fn release_all(&self, owner: &ReferenceOwner) -> Result<(), WireError> {
        self.transaction(|transaction| {
            for each in 0..transaction.index.records.len() {
                transaction.verify(each)?;
            }
            for record in &mut transaction.index.records {
                record.references.retain(|held| *held != owner.0);
            }
            transaction.save()
        })
    }
}

fn sort(references: &mut [Owner]) {
    references.sort_by(|left, right| (&left.kind, &left.id).cmp(&(&right.kind, &right.id)));
}

impl Transaction<'_> {
    /// Swift `find`: an exact content-addressed reference that is registered.
    fn find(&self, reference: &str) -> Result<usize, WireError> {
        if !reference
            .strip_prefix("bundle:sha256:")
            .is_some_and(|digest| {
                digest.len() == 64
                    && digest
                        .bytes()
                        .all(|b| b.is_ascii_digit() || (b'a'..=b'f').contains(&b))
            })
        {
            return Err(failure(
                "invalidInput",
                "expected a content-addressed daemon bundle reference",
            ));
        }
        self.index
            .records
            .iter()
            .position(|record| record.reference == reference)
            .ok_or_else(|| failure("resourceNotFound", "bundle reference does not exist"))
    }

    /// Swift `verify`: the retained content measured again, as recorded, and
    /// held to the store's helper policy.
    fn verify(&self, position: usize) -> Result<(), WireError> {
        let record = serde_json::to_value(&self.index.records[position]).map_err(|_| {
            failure(
                "recordUnreadable",
                "registered bundle content failed integrity validation",
            )
        })?;
        self.store.verify_record(&record).map_err(|error| {
            if error.kind() == io::ErrorKind::PermissionDenied {
                failure(
                    "admissionDenied",
                    "registered bundle failed the production helper trust policy",
                )
            } else {
                failure(
                    "recordUnreadable",
                    "registered bundle content failed integrity validation",
                )
            }
        })
    }

    /// Where the record's content is retained.
    fn content(&self, position: usize) -> PathBuf {
        self.store.path.join(format!(
            "bundle-{}.app",
            self.index.records[position].digest
        ))
    }

    /// Swift `saveIndex`: the index as its canonical bytes, published in place
    /// of the one read while the lock and the index are still those read.
    fn save(&mut self) -> Result<(), WireError> {
        let encoded = serde_json::to_value(&self.index)
            .ok()
            .and_then(|value| canonical_json(&value).ok())
            .ok_or_else(index_unreadable)?;
        if encoded.len() > MAX_INDEX {
            return Err(failure("quotaExceeded", "bundle index exceeds its bound"));
        }
        read_bundles(&encoded).map_err(|_| index_unreadable())?;
        binding(&self.store.root, &self.store.path, &self.lock)?;
        if self.store.root.read(BUNDLES, MAX_INDEX).ok().as_deref() != Some(&self.bytes[..]) {
            return Err(index_unreadable());
        }
        self.store
            .root
            .publish_document(BUNDLES, &encoded, MAX_INDEX)
            .map_err(publication)?;
        self.bytes = encoded;
        Ok(())
    }
}

#[cfg(test)]
#[path = "bundle_references_tests.rs"]
mod tests;
