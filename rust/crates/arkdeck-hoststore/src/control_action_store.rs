//! The store each Swift control-action owner keeps for its records
//! (CHG-2026-074): `RuntimeHDCControlActionStore` for the HDC lifecycle owner
//! (`hdc_control_action.rs`) and `RuntimeToolSelectionControlActionStore` for
//! the tool-selection owner (`tool_selection.rs`), twins in Swift but for the
//! record each reads. One canonical JSON document per request identity,
//! `action-<sha256(requestId)>.json`, in the owner's private directory; every
//! read and write under the transaction lock beside them (`.lock`, taken
//! without waiting); a record replaced only by the exact next generation of
//! the same action, on its owner's conditions.
use crate::control_action::{identifier, refused, unreadable};
use crate::control_action_value::{digest, record_unreadable};
use arkdeck_contract::{WireError, canonical_json, sha256_hex, strict_json};
use arkdeck_platform::{DocumentPublishError, HostDirectory};
use serde_json::{Map, Value};
use std::collections::BTreeSet;
use std::io;
use std::marker::PhantomData;
use std::path::{Path, PathBuf};

/// Both stores' bounds.
const MAX_RECORDS: usize = 4096;
const MAX_RECORD: usize = 1024 * 1024;
const MAX_STORE: usize = 64 * 1024 * 1024;
const MAX_TEMPORARIES: usize = 8;

/// One durable control action, as its owner's record reads it.
pub(crate) trait StoredAction: Clone {
    /// Swift's `init(value:)`: the record, or why it is unreadable.
    fn parse(value: Map<String, Value>) -> Result<Self, WireError>;
    fn value(&self) -> &Map<String, Value>;
    /// `controlActionId`.
    fn id(&self) -> &str;
    /// The request identity the record's file is named by.
    fn request(&self) -> &str;
    fn generation(&self) -> u64;
    /// `createdAt`, as written.
    fn created(&self) -> &str;
    /// The owner's own conditions for `next` to replace `previous`, beyond
    /// being the same action's exact next generation: the facts it may not
    /// change and the transitions it permits.
    fn replaces(previous: &Self, next: &Self) -> bool;
}

fn filename(request: &str) -> String {
    format!("action-{}.json", sha256_hex(request.as_bytes()))
}

/// A pre-rename publication: Swift's `.action-<digest>.json.<uuid>.tmp` or
/// the shared Rust publisher's `.action-<digest>.json.<32 hex>.part`.
fn temporary(name: &str) -> bool {
    let Some(rest) = name.strip_prefix(".action-") else {
        return false;
    };
    let Some((hex, rest)) = rest.split_once(".json.") else {
        return false;
    };
    if !digest(hex) {
        return false;
    }
    if let Some(uuid) = rest.strip_suffix(".tmp") {
        return uuid.len() == 36
            && uuid.bytes().enumerate().all(|(index, byte)| {
                if [8, 13, 18, 23].contains(&index) {
                    byte == b'-'
                } else {
                    byte.is_ascii_digit() || (b'a'..=b'f').contains(&byte)
                }
            });
    }
    rest.strip_suffix(".part").is_some_and(|nonce| {
        nonce.len() == 32
            && nonce
                .bytes()
                .all(|byte| byte.is_ascii_digit() || (b'a'..=b'f').contains(&byte))
    })
}

/// An owner's records, one document per request identity, changed only
/// under the transaction lock beside them.
pub(crate) struct ActionStore<R> {
    path: PathBuf,
    root: HostDirectory,
    records: PhantomData<fn() -> R>,
}

impl<R: StoredAction> ActionStore<R> {
    pub(crate) fn open(path: &Path) -> io::Result<Self> {
        Ok(Self {
            root: HostDirectory::open(path)?,
            path: path.into(),
            records: PhantomData,
        })
    }

    fn validate_directory(&self) -> Result<(), WireError> {
        self.root
            .validate_path(&self.path)
            .map_err(|_| record_unreadable("control-action directory identity changed"))
    }

    /// One transaction: the directory still this one, its lock held without
    /// waiting, and both still so after `body`.
    fn transaction<T>(&self, body: impl FnOnce() -> Result<T, WireError>) -> Result<T, WireError> {
        self.validate_directory()?;
        let lock = self.root.lock_document(".lock").map_err(|error| {
            if error.kind() == io::ErrorKind::WouldBlock {
                refused(
                    "resourceConflict",
                    "another Runtime owner holds the control-action transaction",
                )
            } else {
                record_unreadable("control-action lock cannot be opened")
            }
        })?;
        if !self
            .root
            .document_metadata(".lock")
            .is_ok_and(|metadata| metadata.len() == 0)
        {
            return Err(record_unreadable("unsafe control-action lock"));
        }
        self.validate_directory()?;
        let result = body()?;
        self.validate_directory()?;
        lock.validate_link(&self.root, ".lock")
            .map_err(|_| record_unreadable("control-action lock changed during transaction"))?;
        Ok(result)
    }

    /// Every record, in file-name order; an interrupted publication's
    /// temporary file is removed.
    fn records(&self) -> Result<Vec<R>, WireError> {
        let bound = || record_unreadable("control-action directory exceeds its bound");
        let names = self
            .root
            .names(MAX_RECORDS + MAX_TEMPORARIES + 1)
            .map_err(|_| bound())?;
        let (mut files, mut temporaries) = (Vec::new(), Vec::new());
        for name in names {
            if name == ".lock" {
                continue;
            }
            if temporary(&name) {
                temporaries.push(name);
            } else if name
                .strip_prefix("action-")
                .and_then(|rest| rest.strip_suffix(".json"))
                .is_some_and(digest)
            {
                files.push(name);
            } else {
                return Err(record_unreadable(
                    "unexpected content in control-action directory",
                ));
            }
            if files.len() > MAX_RECORDS || temporaries.len() > MAX_TEMPORARIES {
                return Err(bound());
            }
        }
        let (mut total, mut records, mut identities) = (0, Vec::new(), BTreeSet::new());
        for name in files {
            let bytes = self
                .root
                .read(&name, MAX_RECORD)
                .ok()
                .filter(|bytes| !bytes.is_empty())
                .ok_or_else(|| {
                    record_unreadable("control-action record has unsafe identity or size")
                })?;
            total += bytes.len();
            if total > MAX_STORE {
                return Err(record_unreadable(
                    "control-action store exceeds its byte bound",
                ));
            }
            let Ok(Value::Object(fields)) = strict_json(&bytes) else {
                return Err(unreadable());
            };
            let record = R::parse(fields)?;
            if name != filename(record.request()) || !identities.insert(record.id().to_owned()) {
                return Err(record_unreadable(
                    "control-action record name or identity is inconsistent",
                ));
            }
            records.push(record);
        }
        for name in temporaries {
            let removed = self
                .root
                .document_metadata(&name)
                .ok()
                .filter(|metadata| metadata.len() <= MAX_RECORD as u64)
                .is_some_and(|metadata| self.root.remove_document(&name, &metadata).is_ok());
            if !removed {
                return Err(record_unreadable(
                    "unsafe interrupted control-action publication",
                ));
            }
        }
        Ok(records)
    }

    /// The record of `request`, or a new one `create` makes. An existing
    /// record `same` does not recognize belongs to a different intent.
    pub(crate) fn begin(
        &self,
        request: &str,
        same: impl FnOnce(&R) -> bool,
        create: impl FnOnce() -> Result<R, WireError>,
    ) -> Result<R, WireError> {
        self.transaction(|| {
            let all = self.records()?;
            if let Some(existing) = all.iter().find(|record| record.request() == request) {
                if !same(existing) {
                    return Err(refused(
                        "idempotencyConflict",
                        "action request identity already belongs to a different intent",
                    ));
                }
                return Ok(existing.clone());
            }
            if all.len() >= MAX_RECORDS {
                return Err(refused(
                    "operationUnavailable",
                    "control-action record limit reached",
                ));
            }
            let record = create()?;
            self.write(&record, None, &all)?;
            Ok(record)
        })
    }

    pub(crate) fn load(&self, id: &str) -> Result<Option<R>, WireError> {
        if !identifier(id) {
            return Err(refused("invalidInput", "invalid control-action identity"));
        }
        self.transaction(|| Ok(self.records()?.into_iter().find(|record| record.id() == id)))
    }

    pub(crate) fn load_request(&self, request: &str) -> Result<Option<R>, WireError> {
        if !identifier(request) {
            return Err(refused("invalidInput", "invalid action request identity"));
        }
        self.transaction(|| {
            Ok(self
                .records()?
                .into_iter()
                .find(|record| record.request() == request))
        })
    }

    /// Creation time, then identity in byte order.
    pub(crate) fn list(&self) -> Result<Vec<R>, WireError> {
        self.transaction(|| {
            let mut records = self.records()?;
            records.sort_by(|left, right| {
                (left.created().as_bytes(), left.id().as_bytes())
                    .cmp(&(right.created().as_bytes(), right.id().as_bytes()))
            });
            Ok(records)
        })
    }

    /// The exact next generation of the same action, on the owner's
    /// conditions (`StoredAction::replaces`).
    pub(crate) fn replace(&self, record: &R, expected: u64) -> Result<(), WireError> {
        self.transaction(|| {
            let all = self.records()?;
            let consistent = all
                .iter()
                .find(|previous| previous.id() == record.id())
                .filter(|previous| {
                    previous.generation() == expected
                        && expected < i64::MAX as u64
                        && record.generation() == expected + 1
                        && R::replaces(previous, record)
                });
            let Some(previous) = consistent else {
                return Err(refused(
                    "resourceConflict",
                    "control action changed or update replaces immutable facts",
                ));
            };
            let previous = previous.clone();
            self.write(record, Some(&previous), &all)
        })
    }

    fn write(&self, record: &R, replacing: Option<&R>, all: &[R]) -> Result<(), WireError> {
        R::parse(record.value().clone())?;
        let bytes =
            canonical_json(&Value::Object(record.value().clone())).map_err(|_| unreadable())?;
        if bytes.len() > MAX_RECORD {
            return Err(refused(
                "inputTooLarge",
                "control-action record is too large",
            ));
        }
        let mut total = bytes.len();
        for other in all
            .iter()
            .filter(|other| Some(other.id()) != replacing.map(StoredAction::id))
        {
            total += canonical_json(&Value::Object(other.value().clone()))
                .map_err(|_| unreadable())?
                .len();
        }
        if total > MAX_STORE {
            return Err(refused(
                "operationUnavailable",
                "control-action store byte limit reached",
            ));
        }
        self.validate_directory()?;
        self.root
            .publish_document(&filename(record.request()), &bytes, MAX_RECORD)
            .map_err(|error| match error {
                DocumentPublishError::BeforePublication(_) => {
                    record_unreadable("control-action temporary file cannot be created")
                }
                DocumentPublishError::OutcomeUnknown(_) => {
                    record_unreadable("control-action atomic publication failed")
                }
            })
    }
}
