//! The HDC selection ledger in the bootstrap tool index (CHG-2026-074): Swift
//! `BootstrapToolRegistry`'s selection operations over `tools.json` — the
//! active tool and its generation, the one selection in flight, and its
//! outcome until acknowledged, with the pins that keep their bytes retained.
//! Each operation runs as Swift's does under the bootstrap owner's lock: the
//! shared bundle index and the tool index strictly read (each created empty
//! when absent and nothing it would describe is there), the tools it names
//! checked against their retained content, and the index published only where
//! Swift publishes it, as Swift's bytes. Nothing here launches a tool: a
//! startup selection names the retained executable its caller verifies.
use crate::registry::{
    Owner, PendingSelection, Selection, SelectionOutcome, ToolIndex, identifier, read_tools,
    tool_projection,
};
use crate::{ToolRegistryStore, decode_bundles};
use arkdeck_contract::{WireError, canonical_json};
use arkdeck_platform::{DocumentPublishError, HostReadLock};
use serde_json::{Map, Value, json};
use std::{io, path::Path, path::PathBuf};

const MAX_INDEX: usize = 4 * 1024 * 1024;
const BUNDLES: &str = "bundles.json";
const TOOLS: &str = "tools.json";
const EMPTY_BUNDLES: &[u8] = b"{\"records\":[],\"schemaVersion\":\"arkdeck.bootstrap-bundles/1\"}";
const EMPTY_TOOLS: &[u8] = b"{\"records\":[],\"schemaVersion\":\"arkdeck.bootstrap-tools/2\"}";
/// The one owner Swift pins the active tool for.
const ACTIVE: &str = "runtime-hdc-selection";

fn failure(code: &str, message: &str) -> WireError {
    WireError {
        code: code.into(),
        message: message.into(),
        details: Some(Map::from_iter([
            ("phase".into(), json!("bootstrapRegistryOwner")),
            ("newDispatchCount".into(), json!(0)),
        ])),
    }
}
fn index_unreadable() -> WireError {
    failure(
        "recordUnreadable",
        "tool index failed bounded schema and identity validation",
    )
}
fn content_unreadable() -> WireError {
    failure(
        "recordUnreadable",
        "registered host tool failed content, identity or trust validation",
    )
}
fn no_pending() -> WireError {
    failure(
        "resourceConflict",
        "the exact pending tool selection does not exist",
    )
}
fn generation_changed() -> WireError {
    failure(
        "resourceConflict",
        "active tool selection generation does not match",
    )
}

/// Swift `ReferenceOwner(kind:id:)`.
fn owner(kind: &str, id: &str) -> Result<Owner, WireError> {
    if !identifier(id) {
        return Err(failure("invalidInput", "invalid bundle reference owner"));
    }
    Ok(Owner {
        kind: kind.into(),
        id: id.into(),
    })
}

/// `arkdeck.runtime-tool-selection/1`: the active tool and what is pending.
#[derive(Clone, Debug, PartialEq)]
pub struct SelectionSnapshot {
    pub active_tool_ref: String,
    pub active_generation: u64,
    /// The active tool's `arkdeck.runtime-tool/1` row.
    pub active_tool: Value,
    pub pending_action_id: Option<String>,
    pub pending_tool_ref: Option<String>,
}

impl SelectionSnapshot {
    pub fn value(&self) -> Value {
        json!({
            "schemaVersion": "arkdeck.runtime-tool-selection/1",
            "activeToolRef": self.active_tool_ref,
            "activeGeneration": self.active_generation.to_string(),
            "activeTool": self.active_tool,
            "pendingControlActionId": self.pending_action_id,
            "pendingToolRef": self.pending_tool_ref,
        })
    }
}

/// A selection's candidate beside the selection it would replace.
#[derive(Clone, Debug, PartialEq)]
pub struct SelectionCandidate {
    pub selection: SelectionSnapshot,
    pub new_tool: Value,
}

/// The tool a starting daemon composes its HDC server from: the pending
/// selection's new tool while one is in flight, else the active tool.
#[derive(Clone, Debug, PartialEq)]
pub struct StartupSelection {
    pub tool_ref: String,
    pub active_generation: u64,
    pub pending_action_id: Option<String>,
    /// `<store>/tool-<contentDigest>.hdc/hdc`, as retained.
    pub executable: PathBuf,
    pub executable_sha256: String,
    /// The retained dependencies, as the tool's row lists them.
    pub dependencies: Vec<Value>,
}

#[derive(Clone, Debug, PartialEq, Eq)]
pub enum DurableSelectionOutcome {
    Pending,
    Succeeded {
        active_tool_ref: String,
        active_generation: u64,
    },
    Failed {
        active_tool_ref: String,
        active_generation: u64,
        reason_code: String,
    },
    Absent,
}

/// One operation's hold on the store: its lock, both indexes as read, and the
/// tool index decoded.
struct Ledger<'a> {
    store: &'a ToolRegistryStore,
    lock: HostReadLock,
    bundles: Vec<u8>,
    tools: Vec<u8>,
    index: ToolIndex,
}

/// The control action of the HDC tool selection pending in the bootstrap
/// store at `path`, as the cutover preflight reads it (the production
/// composition refuses to start beside one it has no owner to settle): the
/// tool index read whole — it is published atomically — without the store's
/// lock, without creating an absent index and without verifying any tool. An
/// absent store or index holds no selection.
pub(crate) fn cutover_pending_selection(path: &Path) -> Result<Option<String>, String> {
    let root = match arkdeck_platform::HostDirectory::open(path) {
        Ok(root) => root,
        Err(error) if error.kind() == io::ErrorKind::NotFound => return Ok(None),
        Err(error) => return Err(format!("the bootstrap store is unreadable: {error}")),
    };
    let bytes = match root.read(TOOLS, MAX_INDEX) {
        Ok(bytes) => bytes,
        Err(error) if error.kind() == io::ErrorKind::NotFound => return Ok(None),
        Err(error) => return Err(format!("the tool index is unreadable: {error}")),
    };
    let (index, _) =
        read_tools(&bytes).map_err(|_| "the tool index failed its bounded schema".to_owned())?;
    Ok(index
        .selection
        .and_then(|selection| selection.pending)
        .map(|pending| pending.action_id))
}

impl ToolRegistryStore {
    fn binding(&self, lock: &HostReadLock) -> Result<(), WireError> {
        lock.validate_link(&self.root, ".lock")
            .map_err(|_| failure("fileIdentityChanged", "bootstrap lock was replaced"))?;
        self.root
            .validate_path(&self.path)
            .map_err(|_| failure("fileIdentityChanged", "bootstrap store directory changed"))
    }

    /// Swift `readIndex(_:create:)` of either index: an absent one is created
    /// empty only when nothing it would describe is in the store.
    fn index_bytes(&self, lock: &HostReadLock, name: &str) -> Result<Vec<u8>, WireError> {
        let (missing, unreadable) = if name == BUNDLES {
            (
                "bundle index is missing beside retained bootstrap state",
                "bundle index failed bounded schema and identity validation",
            )
        } else {
            (
                "tool index is missing beside retained tool state",
                "tool index failed bounded schema and identity validation",
            )
        };
        match self.root.read(name, MAX_INDEX) {
            Ok(bytes) => Ok(bytes),
            Err(error) if error.kind() == io::ErrorKind::NotFound => {
                let names = self
                    .root
                    .names(65_536)
                    .map_err(|_| failure("recordUnreadable", unreadable))?;
                let occupied = if name == BUNDLES {
                    names.iter().any(|name| name != ".lock")
                } else {
                    names
                        .iter()
                        .any(|name| name.starts_with("tool-") || name.starts_with(".tool-"))
                };
                if occupied {
                    return Err(failure("recordUnreadable", missing));
                }
                self.binding(lock)?;
                let empty = if name == BUNDLES {
                    EMPTY_BUNDLES
                } else {
                    EMPTY_TOOLS
                };
                self.root
                    .publish_document(name, empty, MAX_INDEX)
                    .map_err(publication)?;
                Ok(empty.to_vec())
            }
            Err(_) => Err(failure("recordUnreadable", unreadable)),
        }
    }

    /// Swift `withSharedStore`: the lock taken without waiting, the shared
    /// bundle index and the tool index read, `body`, and the store still the
    /// one locked.
    fn ledger<T>(
        &self,
        body: impl FnOnce(&mut Ledger<'_>) -> Result<T, WireError>,
    ) -> Result<T, WireError> {
        self.root
            .validate_path(&self.path)
            .map_err(|_| failure("fileIdentityChanged", "bootstrap store directory changed"))?;
        let lock = self.root.lock_document(".lock").map_err(|error| {
            if error.kind() == io::ErrorKind::WouldBlock {
                failure(
                    "resourceConflict",
                    "another bootstrap operation holds the store; retry after it completes",
                )
            } else {
                failure("recordUnreadable", "bootstrap owner lock is unsafe")
            }
        })?;
        self.binding(&lock)?;
        let bundles = self.index_bytes(&lock, BUNDLES)?;
        decode_bundles(&bundles).map_err(|_| {
            failure(
                "recordUnreadable",
                "bundle index failed bounded schema and identity validation",
            )
        })?;
        let tools = self.index_bytes(&lock, TOOLS)?;
        let (index, _) = read_tools(&tools).map_err(|_| index_unreadable())?;
        let mut ledger = Ledger {
            store: self,
            lock,
            bundles,
            tools,
            index,
        };
        let result = body(&mut ledger)?;
        self.binding(&ledger.lock)?;
        Ok(result)
    }

    /// Establishes the first service selection from an exact registered tool;
    /// retrying the same exact selection is idempotent, and a different
    /// selection, one in flight or an unacknowledged outcome is never replaced.
    pub fn initialize_service_selection(
        &self,
        reference: &str,
        expected_generation: &str,
    ) -> Result<StartupSelection, WireError> {
        self.ledger(|ledger| {
            let position = ledger.find(reference)?;
            ledger.verify(position)?;
            let record = &ledger.index.records[position];
            if record.state != "available" || expected_generation != record.generation.to_string()
            {
                return Err(failure(
                    "resourceConflict",
                    "initial service tool is removed or its generation changed",
                ));
            }
            if !record.relocatable || ledger.known(&record.executable_sha256).is_none() {
                return Err(failure(
                    "operationUnavailable",
                    "initial service tool must be an exact available published relocatable HDC identity",
                ));
            }
            let active = owner("activeSelection", ACTIVE)?;
            if let Some(selection) = &ledger.index.selection {
                if selection.active_tool_ref != reference
                    || selection.pending.is_some()
                    || selection.last_outcome.is_some()
                    || !record.references.contains(&active)
                {
                    return Err(failure(
                        "resourceConflict",
                        "an existing or unreconciled HDC selection can change only through runtime tool select",
                    ));
                }
                return Ok(ledger.startup(position, selection.active_generation, None));
            }
            if ledger
                .index
                .records
                .iter()
                .any(|record| record.references.contains(&active))
            {
                return Err(failure(
                    "recordUnreadable",
                    "an active tool pin exists without its selection ledger",
                ));
            }
            ledger.pin(position, active);
            ledger.index.selection = Some(Selection {
                active_tool_ref: reference.into(),
                active_generation: 1,
                pending: None,
                last_outcome: None,
            });
            ledger.save()?;
            Ok(ledger.startup(position, 1, None))
        })
    }

    /// Swift's one-time migration of an installed LaunchAgent's configured
    /// HDC: the file registered, and selected only when no selection exists.
    pub fn adopt_installed_hdc(
        &self,
        source: &Path,
        now: &str,
    ) -> Result<SelectionSnapshot, WireError> {
        let registered = self.register(source, now)?;
        let reference = registered["toolRef"].as_str().ok_or_else(|| {
            failure(
                "recordUnreadable",
                "registered HDC omitted its typed reference",
            )
        })?;
        self.ledger(|ledger| {
            if ledger.index.selection.is_some() {
                return ledger.snapshot();
            }
            let position = ledger.find(reference)?;
            ledger.verify(position)?;
            let record = &ledger.index.records[position];
            if record.state != "available" || ledger.known(&record.executable_sha256).is_none() {
                return Err(failure(
                    "operationUnavailable",
                    "installed HDC has no published executable identity",
                ));
            }
            ledger.pin(position, owner("activeSelection", ACTIVE)?);
            ledger.index.selection = Some(Selection {
                active_tool_ref: reference.into(),
                active_generation: 1,
                pending: None,
                last_outcome: None,
            });
            ledger.save()?;
            ledger.snapshot()
        })
    }

    /// The selection `new_tool_ref` would replace, and its row; an in-flight
    /// selection answers only its own action.
    pub fn selection_candidate(
        &self,
        new_tool_ref: &str,
        expected_active_generation: &str,
        pending_action_id: Option<&str>,
    ) -> Result<SelectionCandidate, WireError> {
        self.ledger(|ledger| {
            let selection = ledger
                .index
                .selection
                .clone()
                .filter(|s| expected_active_generation == s.active_generation.to_string())
                .ok_or_else(generation_changed)?;
            let reconciliation = || {
                failure(
                    "resourceConflict",
                    "a prior tool selection requires reconciliation",
                )
            };
            if let Some(pending) = &selection.pending {
                if pending_action_id != Some(pending.action_id.as_str())
                    || pending.new_tool_ref != new_tool_ref
                    || pending.expected_active_generation != selection.active_generation
                {
                    return Err(reconciliation());
                }
            } else if selection.last_outcome.is_some() {
                return Err(reconciliation());
            }
            let position = ledger.find(new_tool_ref)?;
            ledger.verify(position)?;
            let candidate = &ledger.index.records[position];
            if candidate.state != "available"
                || ledger.known(&candidate.executable_sha256).is_none()
            {
                return Err(failure(
                    "operationUnavailable",
                    "candidate has no published HDC executable identity",
                ));
            }
            if new_tool_ref == selection.active_tool_ref {
                return Err(failure(
                    "resourceConflict",
                    "candidate is already the active HDC tool",
                ));
            }
            Ok(SelectionCandidate {
                selection: ledger.snapshot()?,
                new_tool: ledger.row(position),
            })
        })
    }

    /// Phase one of the selection's write-ahead log: both tools pinned for
    /// the action and the exact transition durable before the managed server
    /// may enter its launch window.
    pub fn prepare_selection(
        &self,
        action_id: &str,
        new_tool_ref: &str,
        expected_active_generation: &str,
    ) -> Result<SelectionSnapshot, WireError> {
        self.ledger(|ledger| {
            let mut selection = ledger
                .index
                .selection
                .clone()
                .filter(|s| expected_active_generation == s.active_generation.to_string())
                .ok_or_else(generation_changed)?;
            if let Some(pending) = &selection.pending {
                if pending.action_id != action_id
                    || pending.new_tool_ref != new_tool_ref
                    || pending.expected_active_generation != selection.active_generation
                {
                    return Err(failure(
                        "resourceConflict",
                        "another tool selection is already pending",
                    ));
                }
                return ledger.snapshot();
            }
            if selection.last_outcome.is_some() {
                return Err(failure(
                    "resourceConflict",
                    "the previous tool selection outcome is not reconciled",
                ));
            }
            let old = ledger.find(&selection.active_tool_ref)?;
            let new = ledger.find(new_tool_ref)?;
            ledger.verify(old)?;
            ledger.verify(new)?;
            let (old_record, new_record) = (&ledger.index.records[old], &ledger.index.records[new]);
            if old_record.state != "available"
                || new_record.state != "available"
                || ledger.known(&new_record.executable_sha256).is_none()
                || new_tool_ref == selection.active_tool_ref
            {
                return Err(failure(
                    "operationUnavailable",
                    "tool selection requires distinct available published HDC identities",
                ));
            }
            let pin = owner("controlAction", action_id)?;
            ledger.pin(old, pin.clone());
            ledger.pin(new, pin);
            selection.pending = Some(PendingSelection {
                action_id: action_id.into(),
                old_tool_ref: ledger.index.records[old].reference.clone(),
                new_tool_ref: ledger.index.records[new].reference.clone(),
                expected_active_generation: selection.active_generation,
            });
            ledger.index.selection = Some(selection);
            ledger.save()?;
            ledger.snapshot()
        })
    }

    /// The durable tool a starting daemon composes: a pending selection's new
    /// tool under the action's pin, else the active tool under its own.
    pub fn startup_selection(&self) -> Result<Option<StartupSelection>, WireError> {
        self.ledger(|ledger| {
            let Some(selection) = ledger.index.selection.clone() else {
                return Ok(None);
            };
            let (reference, dependency) = match &selection.pending {
                Some(pending) => (
                    pending.new_tool_ref.as_str(),
                    owner("controlAction", &pending.action_id)?,
                ),
                None => (
                    selection.active_tool_ref.as_str(),
                    owner("activeSelection", ACTIVE)?,
                ),
            };
            let position = ledger.find(reference)?;
            let record = &ledger.index.records[position];
            if record.state != "available"
                || !record.references.contains(&dependency)
                || ledger.known(&record.executable_sha256).is_none()
            {
                return Err(failure(
                    "recordUnreadable",
                    "durable HDC selection lost its exact executable owner",
                ));
            }
            ledger.verify(position)?;
            Ok(Some(ledger.startup(
                position,
                selection.active_generation,
                selection.pending.map(|pending| pending.action_id),
            )))
        })
    }

    /// Phase three: only a caller that verified the newly composed server
    /// publishes the new active tool.
    pub fn publish_pending_selection(
        &self,
        action_id: &str,
    ) -> Result<SelectionSnapshot, WireError> {
        self.ledger(|ledger| {
            let mut selection = ledger.index.selection.clone().ok_or_else(no_pending)?;
            let pending = selection
                .pending
                .clone()
                .filter(|pending| {
                    pending.action_id == action_id && selection.active_generation < u64::MAX
                })
                .ok_or_else(no_pending)?;
            let active = owner("activeSelection", ACTIVE)?;
            let pin = owner("controlAction", action_id)?;
            for record in &mut ledger.index.records {
                if record.reference == pending.old_tool_ref {
                    record
                        .references
                        .retain(|owner| *owner != active && *owner != pin);
                } else if record.reference == pending.new_tool_ref {
                    record.references.retain(|owner| *owner != pin);
                    if !record.references.contains(&active) {
                        record.references.push(active.clone());
                    }
                    sort(&mut record.references);
                }
            }
            selection.active_tool_ref = pending.new_tool_ref.clone();
            selection.active_generation += 1;
            selection.pending = None;
            selection.last_outcome = Some(SelectionOutcome {
                action_id: action_id.into(),
                result: "succeeded".into(),
                old_tool_ref: pending.old_tool_ref,
                new_tool_ref: pending.new_tool_ref,
                active_generation: selection.active_generation,
                reason_code: None,
            });
            ledger.index.selection = Some(selection);
            ledger.save()?;
            ledger.snapshot()
        })
    }

    /// The pending selection abandoned: its pins released and the failure
    /// kept as the outcome until acknowledged; the active tool is unchanged.
    pub fn fail_pending_selection(
        &self,
        action_id: &str,
        reason_code: &str,
    ) -> Result<SelectionSnapshot, WireError> {
        if !identifier(reason_code) {
            return Err(failure(
                "invalidInput",
                "invalid tool selection failure reason",
            ));
        }
        self.ledger(|ledger| {
            let mut selection = ledger.index.selection.clone().ok_or_else(no_pending)?;
            let pending = selection
                .pending
                .clone()
                .filter(|pending| pending.action_id == action_id)
                .ok_or_else(no_pending)?;
            let pin = owner("controlAction", action_id)?;
            for record in &mut ledger.index.records {
                record.references.retain(|owner| *owner != pin);
            }
            selection.pending = None;
            selection.last_outcome = Some(SelectionOutcome {
                action_id: action_id.into(),
                result: "failed".into(),
                old_tool_ref: pending.old_tool_ref,
                new_tool_ref: pending.new_tool_ref,
                active_generation: selection.active_generation,
                reason_code: Some(reason_code.into()),
            });
            ledger.index.selection = Some(selection);
            ledger.save()?;
            ledger.snapshot()
        })
    }

    pub fn selection_outcome(&self, action_id: &str) -> Result<DurableSelectionOutcome, WireError> {
        self.ledger(|ledger| {
            let Some(selection) = ledger.index.selection.clone() else {
                return Ok(DurableSelectionOutcome::Absent);
            };
            ledger.snapshot()?;
            if selection
                .pending
                .as_ref()
                .is_some_and(|pending| pending.action_id == action_id)
            {
                return Ok(DurableSelectionOutcome::Pending);
            }
            let Some(outcome) = selection
                .last_outcome
                .filter(|outcome| outcome.action_id == action_id)
            else {
                return Ok(DurableSelectionOutcome::Absent);
            };
            Ok(if outcome.result == "succeeded" {
                DurableSelectionOutcome::Succeeded {
                    active_tool_ref: selection.active_tool_ref,
                    active_generation: selection.active_generation,
                }
            } else {
                DurableSelectionOutcome::Failed {
                    active_tool_ref: selection.active_tool_ref,
                    active_generation: selection.active_generation,
                    reason_code: outcome
                        .reason_code
                        .unwrap_or_else(|| "tool.selectionFailed".into()),
                }
            })
        })
    }

    /// The outcome of `action_id` forgotten, and only that one.
    pub fn acknowledge_selection_outcome(&self, action_id: &str) -> Result<(), WireError> {
        self.ledger(|ledger| {
            let Some(selection) = &mut ledger.index.selection else {
                return Ok(());
            };
            if selection
                .last_outcome
                .as_ref()
                .is_some_and(|outcome| outcome.action_id == action_id)
            {
                selection.last_outcome = None;
                ledger.save()?;
            }
            Ok(())
        })
    }
}

fn sort(references: &mut [Owner]) {
    references.sort_by(|left, right| (&left.kind, &left.id).cmp(&(&right.kind, &right.id)));
}

fn publication(error: DocumentPublishError) -> WireError {
    match error {
        DocumentPublishError::BeforePublication(_) => {
            failure("ioFailure", "cannot publish tool index")
        }
        DocumentPublishError::OutcomeUnknown(_) => failure(
            "outcomeUnknown",
            "host tool index was published but durable completion is unconfirmed",
        ),
    }
}

impl Ledger<'_> {
    /// Swift `find`: an exact content-addressed reference that is registered.
    fn find(&self, reference: &str) -> Result<usize, WireError> {
        if !reference
            .strip_prefix("tool:sha256:")
            .is_some_and(|digest| {
                digest.len() == 64
                    && digest
                        .bytes()
                        .all(|b| b.is_ascii_digit() || (b'a'..=b'f').contains(&b))
            })
        {
            return Err(failure(
                "invalidInput",
                "expected a content-addressed HDC tool reference",
            ));
        }
        self.index
            .records
            .iter()
            .position(|record| record.reference == reference)
            .ok_or_else(|| failure("resourceNotFound", "tool reference does not exist"))
    }

    /// Swift `verify`: the retained content measured again, as recorded.
    fn verify(&self, position: usize) -> Result<(), WireError> {
        let record = serde_json::to_value(&self.index.records[position])
            .map_err(|_| content_unreadable())?;
        self.store
            .verify_record(&record)
            .map_err(|_| content_unreadable())
    }

    fn known(&self, sha256: &str) -> Option<Value> {
        (self.store.identities)(sha256)
    }

    /// The tool's `arkdeck.runtime-tool/1` row in this index.
    fn row(&self, position: usize) -> Value {
        let record = &self.index.records[position];
        tool_projection(&self.index, record, self.known(&record.executable_sha256))
    }

    fn pin(&mut self, position: usize, owner: Owner) {
        let references = &mut self.index.records[position].references;
        if !references.contains(&owner) {
            references.push(owner);
            sort(references);
        }
    }

    fn startup(
        &self,
        position: usize,
        active_generation: u64,
        pending_action_id: Option<String>,
    ) -> StartupSelection {
        let record = &self.index.records[position];
        let row = self.row(position);
        StartupSelection {
            tool_ref: record.reference.clone(),
            active_generation,
            pending_action_id,
            executable: self
                .store
                .path
                .join(format!("tool-{}.hdc", record.content_digest))
                .join("hdc"),
            executable_sha256: record.executable_sha256.clone(),
            dependencies: row["dependencies"].as_array().cloned().unwrap_or_default(),
        }
    }

    /// Swift `snapshot`: the active tool verified and durably pinned.
    fn snapshot(&self) -> Result<SelectionSnapshot, WireError> {
        let selection = self.index.selection.as_ref().ok_or_else(index_unreadable)?;
        let position = self.find(&selection.active_tool_ref)?;
        self.verify(position)?;
        let record = &self.index.records[position];
        if record.state != "available"
            || !record
                .references
                .iter()
                .any(|owner| owner.kind == "activeSelection" && owner.id == ACTIVE)
            || selection.active_generation == 0
        {
            return Err(failure(
                "recordUnreadable",
                "active tool selection is not durably pinned",
            ));
        }
        Ok(SelectionSnapshot {
            active_tool_ref: selection.active_tool_ref.clone(),
            active_generation: selection.active_generation,
            active_tool: self.row(position),
            pending_action_id: selection.pending.as_ref().map(|p| p.action_id.clone()),
            pending_tool_ref: selection.pending.as_ref().map(|p| p.new_tool_ref.clone()),
        })
    }

    /// Swift `saveIndex`: the index as its canonical bytes, published in place
    /// of the one read while the lock and both indexes are still those read.
    fn save(&mut self) -> Result<(), WireError> {
        self.index.schema_version = "arkdeck.bootstrap-tools/2".into();
        let encoded = serde_json::to_value(&self.index)
            .ok()
            .and_then(|value| canonical_json(&value).ok())
            .ok_or_else(index_unreadable)?;
        if encoded.len() > MAX_INDEX {
            return Err(failure(
                "quotaExceeded",
                "tool index exceeds its bounded storage",
            ));
        }
        // Swift writes whatever its transition made; no transition here makes
        // a ledger the reader refuses, and none is published if one did.
        read_tools(&encoded).map_err(|_| index_unreadable())?;
        self.store.binding(&self.lock)?;
        let root = &self.store.root;
        if root.read(BUNDLES, MAX_INDEX).ok().as_deref() != Some(&self.bundles[..])
            || root.read(TOOLS, MAX_INDEX).ok().as_deref() != Some(&self.tools[..])
        {
            return Err(index_unreadable());
        }
        root.publish_document(TOOLS, &encoded, MAX_INDEX)
            .map_err(publication)?;
        self.tools = encoded;
        Ok(())
    }
}

#[cfg(test)]
#[path = "tool_selection_ledger_tests.rs"]
mod tests;
