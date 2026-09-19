//! The workspace project store's one document and its owner transaction, as
//! Swift `RuntimeWorkspaceProjectStore.withDocument` runs it: the document is
//! loaded and validated under the store lock, a retained dependency mutation
//! is reconciled before anything reads it, and only then does the request see
//! the document. Every write is Swift's `save`.
use super::preset_mutations::{PendingMutation, PresetRecord};
use super::*;
use arkdeck_platform::HostReadLock;

/// The typed document. Swift's `Document`, whose nil pending mutation is
/// omitted and whose presets are always written.
#[derive(Clone, Debug, Default)]
pub(super) struct Document {
    pub records: Vec<Record>,
    pub presets: Vec<PresetRecord>,
    pub pending: Option<PendingMutation>,
}

fn malformed() -> WireError {
    failure(
        "recordUnreadable",
        "workspace project store document is malformed",
    )
}

impl Document {
    fn decode(bytes: &[u8]) -> Result<Self, WireError> {
        let value = strict_json(bytes).map_err(|_| malformed())?;
        let records = validate_records(&value)?;
        let presets = if value["presets"].is_null() {
            Vec::new()
        } else {
            serde_json::from_value(value["presets"].clone()).map_err(|_| malformed())?
        };
        let pending = if value["pendingToolchainMutation"].is_null() {
            None
        } else {
            Some(
                serde_json::from_value(value["pendingToolchainMutation"].clone())
                    .map_err(|_| malformed())?,
            )
        };
        Ok(Self {
            records,
            presets,
            pending,
        })
    }

    fn encode(&self) -> Result<Vec<u8>, WireError> {
        let cannot = || {
            failure(
                "recordUnreadable",
                "workspace project store document cannot be encoded",
            )
        };
        let mut records = self.records.clone();
        records.sort_by(|a, b| a.project_ref.cmp(&b.project_ref));
        let mut fields = Map::new();
        fields.insert(
            "schemaVersion".into(),
            json!("arkdeck.workspace-project-store/3"),
        );
        fields.insert(
            "records".into(),
            serde_json::to_value(&records).map_err(|_| cannot())?,
        );
        fields.insert(
            "presets".into(),
            serde_json::to_value(&self.presets).map_err(|_| cannot())?,
        );
        if let Some(pending) = &self.pending {
            fields.insert(
                "pendingToolchainMutation".into(),
                serde_json::to_value(pending).map_err(|_| cannot())?,
            );
        }
        crate::session_json::encode(&Value::Object(fields)).map_err(|_| cannot())
    }
}

/// The held store lock, through which every write of one request goes.
pub(super) struct Transaction<'a> {
    store: &'a WorkspaceProjectStore,
    lock: HostReadLock,
}

impl Transaction<'_> {
    /// Swift `save(_:rootFD:)`: a bounded canonical document, staged and
    /// renamed into place. A staging failure published nothing; a failed
    /// rename or directory flush may have.
    pub(super) fn save(&self, document: &Document) -> Result<(), WireError> {
        let encoded = document.encode()?;
        if encoded.len() > MAXIMUM {
            return Err(failure(
                "quotaExceeded",
                "workspace project store document exceeds its bound",
            ));
        }
        let store = self.store;
        store
            .root
            .publish_document(DOCUMENT, &encoded, MAXIMUM)
            .map_err(|error| match error {
                DocumentPublishError::BeforePublication(_) => failure(
                    "ioFailure",
                    "workspace project store staging file cannot be created",
                ),
                DocumentPublishError::OutcomeUnknown(_) => failure(
                    "outcomeUnknown",
                    "workspace project store publication could not be verified",
                ),
            })?;
        self.lock
            .validate_link(&store.root, LOCK)
            .and_then(|_| store.root.validate_path(&store.path))
            .map_err(|_| {
                failure(
                    "outcomeUnknown",
                    "workspace project namespace changed during publication",
                )
            })
    }
}

/// A pinning owner's refusal, as Swift rethrows it: its code and message,
/// under this owner's evidence.
fn owner_refusal(error: WireError) -> WireError {
    failure(&error.code, &error.message)
}

impl WorkspaceProjectStore {
    /// One owner transaction. `precondition` runs under the process lock and
    /// before the store lock, where Swift consults its use tokens and the
    /// durable Job census.
    pub(super) fn with_document<T>(
        &self,
        precondition: impl FnOnce() -> Result<(), WireError>,
        body: impl FnOnce(&Transaction<'_>, Document) -> Result<T, WireError>,
    ) -> Result<T, WireError> {
        let _process = self.transaction.lock().map_err(unreadable)?;
        precondition()?;
        self.root.validate_path(&self.path).map_err(unreadable)?;
        let lock = self.root.lock_document(LOCK).map_err(|error| {
            if error.kind() == io::ErrorKind::WouldBlock {
                failure("resourceConflict", "workspace project store lock is busy")
            } else {
                unreadable(error)
            }
        })?;
        let document = match self
            .root
            .read_owner_only(DOCUMENT, MAXIMUM)
            .map_err(unreadable)?
        {
            Some(bytes) => Document::decode(&bytes)?,
            None => Document::default(),
        };
        lock.validate_link(&self.root, LOCK).map_err(unreadable)?;
        self.root.validate_path(&self.path).map_err(unreadable)?;
        let transaction = Transaction { store: self, lock };
        let document = self.reconcile(&transaction, document)?;
        body(&transaction, document)
    }

    /// Swift `requireDependencyOwners`.
    pub(super) fn require_dependency_owners(
        &self,
        toolchain: Option<&str>,
        credential: Option<&str>,
    ) -> Result<(), WireError> {
        if toolchain.is_some() && self.toolchain_pinning.is_none() {
            return Err(failure(
                "operationUnavailable",
                "DevEco toolchain reference owner is unavailable",
            ));
        }
        if credential.is_some() && self.credential_pinning.is_none() {
            return Err(failure(
                "operationUnavailable",
                "signing credential reference owner is unavailable",
            ));
        }
        Ok(())
    }

    /// Swift `requirePresetDependencies`: the owners, then the credential's
    /// project binding, both before the store writes its intent.
    pub(super) fn require_preset_dependencies(
        &self,
        project: &str,
        toolchain: Option<&str>,
        credential: Option<&str>,
    ) -> Result<(), WireError> {
        self.require_dependency_owners(toolchain, credential)?;
        if let (Some(credential), Some(pinning)) = (credential, &self.credential_pinning) {
            (pinning.validate_binding)(credential, project).map_err(owner_refusal)?;
        }
        Ok(())
    }

    /// Swift `reconcileDependencyMutation`: the persisted intent is completed
    /// before any request reads the document. Without the owners it names the
    /// intent stays, and every request is refused without a write.
    pub(super) fn reconcile(
        &self,
        transaction: &Transaction<'_>,
        document: Document,
    ) -> Result<Document, WireError> {
        let Some(pending) = document.pending.clone() else {
            return Ok(document);
        };
        self.require_dependency_owners(
            pending.toolchain_ref.as_deref(),
            pending.credential_ref.as_deref(),
        )?;
        let mut next = document.clone();
        match pending.action.as_str() {
            "acquire" => {
                let proposed = pending
                    .proposed_record
                    .as_ref()
                    .filter(|proposed| {
                        proposed.preset_ref == pending.preset_ref
                            && proposed.toolchain_ref == pending.toolchain_ref
                            && proposed.toolchain_generation == pending.toolchain_generation
                            && proposed.credential_ref == pending.credential_ref
                            && (pending.toolchain_ref.is_some() || pending.credential_ref.is_some())
                            && proposed.state == "available"
                    })
                    .ok_or_else(|| {
                        failure(
                            "recordUnreadable",
                            "workspace preset acquire transaction is inconsistent",
                        )
                    })?;
                document.validate_proposed(proposed)?;
                // The preset is added only after both pins succeed, so an
                // abandoned intent restores the document as it was before the
                // request; the refusal still reaches the caller.
                let pinned = (|| {
                    if let (Some(reference), Some(generation), Some(pinning)) = (
                        pending.toolchain_ref.as_deref(),
                        pending.toolchain_generation,
                        &self.toolchain_pinning,
                    ) {
                        (pinning.acquire)(reference, generation, &pending.preset_ref)
                            .map_err(owner_refusal)?;
                    }
                    if let (Some(reference), Some(pinning)) =
                        (pending.credential_ref.as_deref(), &self.credential_pinning)
                    {
                        (pinning.acquire)(reference, &pending.preset_ref, &proposed.project_ref)
                            .map_err(owner_refusal)?;
                    }
                    Ok(())
                })();
                if let Err(error) = pinned {
                    let mut abandoned = document;
                    abandoned.pending = None;
                    transaction.save(&abandoned)?;
                    return Err(error);
                }
                match next
                    .presets
                    .iter()
                    .position(|preset| preset.preset_ref == pending.preset_ref)
                {
                    Some(index) => next.presets[index] = proposed.clone(),
                    None => {
                        next.presets.push(proposed.clone());
                        next.presets
                            .sort_by(|left, right| left.preset_ref.cmp(&right.preset_ref));
                    }
                }
                next.pending = (pending.release_after_acquire_ref.is_some()
                    || pending.release_after_acquire_credential_ref.is_some())
                .then(|| {
                    PendingMutation::release(
                        &pending.preset_ref,
                        pending.release_after_acquire_ref.clone(),
                        pending.release_after_acquire_ref.as_ref().map(|_| 1),
                        pending.release_after_acquire_credential_ref.clone(),
                    )
                });
                transaction.save(&next)?;
                if next.pending.is_some() {
                    return self.reconcile(transaction, next);
                }
                Ok(next)
            }
            "release" => {
                if pending.proposed_record.is_some()
                    || pending.release_after_acquire_ref.is_some()
                    || pending.release_after_acquire_credential_ref.is_some()
                    || (pending.toolchain_ref.is_none() && pending.credential_ref.is_none())
                {
                    return Err(failure(
                        "recordUnreadable",
                        "workspace preset release transaction is inconsistent",
                    ));
                }
                let mismatch = || {
                    failure(
                        "recordUnreadable",
                        "workspace preset release does not match its durable record",
                    )
                };
                let retained = document
                    .presets
                    .iter()
                    .find(|preset| preset.preset_ref == pending.preset_ref)
                    .ok_or_else(mismatch)?;
                let matches = |released: &Option<String>, held: &Option<String>| {
                    released.as_ref().is_none_or(|reference| {
                        (retained.state == "removed" && held.as_ref() == Some(reference))
                            || (retained.state == "available" && held.as_ref() != Some(reference))
                    })
                };
                if !matches(&pending.toolchain_ref, &retained.toolchain_ref)
                    || !matches(&pending.credential_ref, &retained.credential_ref)
                {
                    return Err(mismatch());
                }
                if let (Some(reference), Some(pinning)) =
                    (pending.toolchain_ref.as_deref(), &self.toolchain_pinning)
                {
                    (pinning.release)(reference, &pending.preset_ref).map_err(owner_refusal)?;
                }
                if let (Some(reference), Some(pinning)) =
                    (pending.credential_ref.as_deref(), &self.credential_pinning)
                {
                    (pinning.release)(reference, &pending.preset_ref).map_err(owner_refusal)?;
                }
                next.pending = None;
                transaction.save(&next)?;
                Ok(next)
            }
            _ => Err(failure(
                "recordUnreadable",
                "workspace preset transaction action is invalid",
            )),
        }
    }
}
