//! Private immutable pages for resource discovery. A cursor identifies a stored
//! page and its query; it never causes another inventory scan or a silent restart.
use arkdeck_contract::{WireError, canonical_json, sha256_hex, strict_json};
use arkdeck_platform::{HostDirectory, random_bytes};
use serde::{Deserialize, Serialize};
use serde_json::{Value, json};
use std::{
    collections::BTreeSet,
    io,
    path::{Path, PathBuf},
};

const MAX_SNAPSHOT: usize = 16 * 1024 * 1024;
const MAX_PAGE: usize = 1024 * 1024;
const MAX_TOTAL: u64 = 64 * 1024 * 1024;
const LOCK: &str = ".snapshots.lock";

pub(crate) fn failure(code: &str, message: &str) -> WireError {
    WireError {
        code: code.into(),
        message: message.into(),
        details: Some(serde_json::Map::from_iter([
            ("phase".into(), json!("sessionOwner")),
            ("newDispatchCount".into(), json!(0)),
        ])),
    }
}

fn unreadable(_: impl std::fmt::Debug) -> WireError {
    failure(
        "recordUnreadable",
        "Session snapshot storage is unreadable or unsafe",
    )
}
fn invalid_cursor() -> WireError {
    failure(
        "invalidCursor",
        "Cursor is invalid, belongs to another query, or its snapshot was reclaimed",
    )
}

#[derive(Serialize, Deserialize)]
#[serde(deny_unknown_fields, rename_all = "camelCase")]
struct Snapshot {
    schema_version: String,
    revision: String,
    query_digest: String,
    order: String,
    tokens: Vec<String>,
    pages: Vec<Vec<Value>>,
}

pub(crate) struct SnapshotPager {
    root: HostDirectory,
    path: PathBuf,
}

fn uuid() -> Result<String, WireError> {
    let mut bytes = random_bytes::<16>().map_err(unreadable)?;
    bytes[6] = (bytes[6] & 0x0f) | 0x40;
    bytes[8] = (bytes[8] & 0x3f) | 0x80;
    let hex: String = bytes.iter().map(|b| format!("{b:02x}")).collect();
    Ok(format!(
        "{}-{}-{}-{}-{}",
        &hex[..8],
        &hex[8..12],
        &hex[12..16],
        &hex[16..20],
        &hex[20..]
    ))
}
fn valid_uuid(value: &str) -> bool {
    value.len() == 36
        && value.bytes().enumerate().all(|(index, byte)| {
            if [8, 13, 18, 23].contains(&index) {
                byte == b'-'
            } else {
                byte.is_ascii_digit() || (b'a'..=b'f').contains(&byte)
            }
        })
}
fn cursor_parts(value: &str) -> Option<(&str, &str)> {
    let (revision, token) = value.split_once('.')?;
    (valid_uuid(revision) && valid_uuid(token)).then_some((revision, token))
}
fn filename(revision: &str) -> String {
    format!("snapshot-{revision}.json")
}

impl SnapshotPager {
    pub(crate) fn open(path: &Path) -> io::Result<Self> {
        Ok(Self {
            root: HostDirectory::open(path)?,
            path: path.into(),
        })
    }

    pub(crate) fn page(
        &self,
        method: &str,
        order: &str,
        page_size: usize,
        cursor: Option<&str>,
        items: impl FnOnce() -> Result<Vec<Value>, WireError>,
    ) -> Result<Value, WireError> {
        if !(1..=1000).contains(&page_size) {
            return Err(failure(
                "invalidInput",
                "pageSize must be between 1 and 1000",
            ));
        }
        let query = canonical_json(
            &json!({"method":method,"filters":{},"order":order,"pageSize":page_size}),
        )
        .map_err(unreadable)?;
        let digest = sha256_hex(&query);
        self.root.validate_path(&self.path).map_err(unreadable)?;
        let lock = self.root.lock_document(LOCK).map_err(|error| {
            if error.kind() == io::ErrorKind::WouldBlock {
                failure("resourceConflict", "Snapshot storage is being updated")
            } else {
                unreadable(error)
            }
        })?;
        let (snapshot, index) = if let Some(cursor) = cursor {
            let (revision, _) = cursor_parts(cursor).ok_or_else(invalid_cursor)?;
            let snapshot = self.read(revision)?;
            if snapshot.query_digest != digest || snapshot.order != order {
                return Err(invalid_cursor());
            }
            let index = snapshot
                .tokens
                .iter()
                .position(|value| value == cursor)
                .ok_or_else(invalid_cursor)?;
            (snapshot, index)
        } else {
            let rows = items()?;
            let revision = uuid()?;
            let mut pages = Vec::new();
            let mut current = Vec::new();
            let (mut bytes, mut total) = (2, 0);
            for row in rows {
                let size = canonical_json(&row).map_err(unreadable)?.len() + 1;
                if size + 2 > MAX_PAGE {
                    return Err(failure(
                        "inputTooLarge",
                        "Resource projection exceeds its page bound",
                    ));
                }
                if current.len() == page_size || bytes + size > MAX_PAGE {
                    pages.push(current);
                    current = Vec::new();
                    bytes = 2;
                }
                total += size;
                if total > MAX_SNAPSHOT {
                    return Err(failure(
                        "operationUnavailable",
                        "Snapshot exceeds its storage bound",
                    ));
                }
                current.push(row);
                bytes += size;
            }
            if !current.is_empty() || pages.is_empty() {
                pages.push(current);
            }
            let tokens = pages
                .iter()
                .map(|_| uuid().map(|token| format!("{revision}.{token}")))
                .collect::<Result<Vec<_>, _>>()?;
            let snapshot = Snapshot {
                schema_version: "arkdeck.runtime-snapshot/1".into(),
                revision,
                query_digest: digest,
                order: order.into(),
                tokens,
                pages,
            };
            let bytes = canonical_json(&serde_json::to_value(&snapshot).map_err(unreadable)?)
                .map_err(unreadable)?;
            if bytes.len() > MAX_SNAPSHOT {
                return Err(failure(
                    "operationUnavailable",
                    "Snapshot exceeds its encoded storage bound",
                ));
            }
            self.retain_space(bytes.len())?;
            lock.validate_link(&self.root, LOCK).map_err(unreadable)?;
            self.root.validate_path(&self.path).map_err(unreadable)?;
            self.root
                .publish_document(&filename(&snapshot.revision), &bytes, MAX_SNAPSHOT)
                .map_err(unreadable)?;
            (snapshot, 0)
        };
        lock.validate_link(&self.root, LOCK).map_err(unreadable)?;
        self.root.validate_path(&self.path).map_err(unreadable)?;
        let more = index + 1 < snapshot.pages.len();
        Ok(
            json!({"schemaVersion":"arkdeck.cli.page/1","pageKind":"snapshot",
            "items":snapshot.pages[index],"order":snapshot.order,"snapshotRevision":snapshot.revision,
            "hasMore":more,"nextCursor":snapshot.tokens.get(index+1)}),
        )
    }

    fn read(&self, revision: &str) -> Result<Snapshot, WireError> {
        let bytes = self
            .root
            .read(&filename(revision), MAX_SNAPSHOT)
            .map_err(|error| {
                if error.kind() == io::ErrorKind::NotFound {
                    invalid_cursor()
                } else {
                    unreadable(error)
                }
            })?;
        let value = strict_json(&bytes).map_err(unreadable)?;
        let snapshot: Snapshot = serde_json::from_value(value).map_err(unreadable)?;
        if snapshot.schema_version != "arkdeck.runtime-snapshot/1"
            || snapshot.revision != revision
            || snapshot.pages.is_empty()
            || snapshot.pages.len() != snapshot.tokens.len()
            || snapshot.tokens.iter().collect::<BTreeSet<_>>().len() != snapshot.tokens.len()
            || snapshot
                .tokens
                .iter()
                .any(|token| cursor_parts(token).is_none_or(|(id, _)| id != revision))
            || snapshot.pages.iter().any(|page| page.len() > 1000)
        {
            return Err(unreadable(()));
        }
        for page in &snapshot.pages {
            if canonical_json(&json!(page)).map_err(unreadable)?.len() > MAX_PAGE {
                return Err(unreadable(()));
            }
        }
        Ok(snapshot)
    }

    fn retain_space(&self, bytes: usize) -> Result<(), WireError> {
        let mut records = Vec::new();
        let mut total = bytes as u64;
        for name in self.root.names(usize::MAX).map_err(unreadable)? {
            if !name.starts_with("snapshot-") || !name.ends_with(".json") {
                continue;
            }
            let metadata = self.root.document_metadata(&name).map_err(unreadable)?;
            if metadata.len() == 0 || metadata.len() > MAX_SNAPSHOT as u64 {
                return Err(unreadable(()));
            }
            total = total
                .checked_add(metadata.len())
                .ok_or_else(|| unreadable(()))?;
            records.push((metadata.modified().map_err(unreadable)?, name, metadata));
        }
        if records.len() > 32 {
            return Err(unreadable(()));
        }
        records.sort_by(|a, b| a.0.cmp(&b.0).then_with(|| a.1.cmp(&b.1)));
        let mut remaining = records.len();
        for (_, name, metadata) in records {
            if remaining < 32 && total <= MAX_TOTAL {
                break;
            }
            self.root
                .remove_document(&name, &metadata)
                .map_err(unreadable)?;
            total -= metadata.len();
            remaining -= 1;
        }
        Ok(())
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use std::{
        fs,
        os::unix::fs::{DirBuilderExt, PermissionsExt, symlink},
    };
    struct Root(PathBuf);
    impl Root {
        fn new() -> Self {
            let path = std::env::temp_dir()
                .canonicalize()
                .unwrap()
                .join(format!("session-pages-{}", uuid().unwrap()));
            fs::DirBuilder::new().mode(0o700).create(&path).unwrap();
            Self(path)
        }
        fn pager(&self) -> SnapshotPager {
            SnapshotPager::open(&self.0).unwrap()
        }
    }
    impl Drop for Root {
        fn drop(&mut self) {
            fs::remove_dir_all(&self.0).unwrap();
        }
    }
    fn first(pager: &SnapshotPager) -> Value {
        pager
            .page(
                "session.list",
                "completedAtDescSessionIdAsc",
                1,
                None,
                || Ok(vec![json!({"sessionId":"a"}), json!({"sessionId":"b"})]),
            )
            .unwrap()
    }
    #[test]
    fn cursor_survives_restart_without_rebuilding_inventory() {
        let root = Root::new();
        let page = first(&root.pager());
        let cursor = page["nextCursor"].as_str().unwrap();
        let pager = root.pager();
        let next = pager
            .page(
                "session.list",
                "completedAtDescSessionIdAsc",
                1,
                Some(cursor),
                || panic!("cursor must never rescan"),
            )
            .unwrap();
        assert_eq!(next["items"], json!([{"sessionId":"b"}]));
        assert_eq!(next["snapshotRevision"], page["snapshotRevision"]);
        assert_eq!(next["hasMore"], false);
        assert!(next["nextCursor"].is_null());
        assert_eq!(
            pager
                .page(
                    "session.list",
                    "completedAtDescSessionIdAsc",
                    2,
                    Some(cursor),
                    || panic!()
                )
                .unwrap_err()
                .code,
            "invalidCursor"
        );
        assert_eq!(
            pager
                .page(
                    "artifact.list",
                    "completedAtDescSessionIdAsc",
                    1,
                    Some(cursor),
                    || panic!()
                )
                .unwrap_err()
                .code,
            "invalidCursor"
        );
        fs::remove_file(
            root.0
                .join(filename(page["snapshotRevision"].as_str().unwrap())),
        )
        .unwrap();
        assert_eq!(
            pager
                .page(
                    "session.list",
                    "completedAtDescSessionIdAsc",
                    1,
                    Some(cursor),
                    || panic!()
                )
                .unwrap_err()
                .code,
            "invalidCursor"
        );
    }
    #[test]
    fn retention_reclaims_old_cursor_and_preserves_new_pages() {
        let root = Root::new();
        let pager = root.pager();
        let original = first(&pager);
        for _ in 0..32 {
            first(&pager);
        }
        let snapshots = fs::read_dir(&root.0)
            .unwrap()
            .filter(|entry| {
                entry
                    .as_ref()
                    .unwrap()
                    .file_name()
                    .to_string_lossy()
                    .starts_with("snapshot-")
            })
            .count();
        assert_eq!(snapshots, 32);
        assert_eq!(
            pager
                .page(
                    "session.list",
                    "completedAtDescSessionIdAsc",
                    1,
                    original["nextCursor"].as_str(),
                    || panic!()
                )
                .unwrap_err()
                .code,
            "invalidCursor"
        );
    }
    #[test]
    fn unsafe_snapshot_and_lock_contention_refuse_without_new_query() {
        let root = Root::new();
        let pager = root.pager();
        let page = first(&pager);
        let path = root
            .0
            .join(filename(page["snapshotRevision"].as_str().unwrap()));
        let cursor = page["nextCursor"].as_str();
        let owner = HostDirectory::open(&root.0).unwrap();
        let lock = owner.lock_document(LOCK).unwrap();
        assert_eq!(
            pager
                .page(
                    "session.list",
                    "completedAtDescSessionIdAsc",
                    1,
                    cursor,
                    || panic!()
                )
                .unwrap_err()
                .code,
            "resourceConflict"
        );
        drop(lock);
        fs::set_permissions(&path, fs::Permissions::from_mode(0o644)).unwrap();
        assert_eq!(
            pager
                .page(
                    "session.list",
                    "completedAtDescSessionIdAsc",
                    1,
                    cursor,
                    || panic!()
                )
                .unwrap_err()
                .code,
            "recordUnreadable"
        );
        fs::set_permissions(&path, fs::Permissions::from_mode(0o600)).unwrap();
        let outside = root.0.join("retained");
        fs::rename(&path, &outside).unwrap();
        symlink(&outside, &path).unwrap();
        let bytes = fs::read(&outside).unwrap();
        assert_eq!(
            pager
                .page(
                    "session.list",
                    "completedAtDescSessionIdAsc",
                    1,
                    cursor,
                    || panic!()
                )
                .unwrap_err()
                .code,
            "recordUnreadable"
        );
        assert!(
            pager
                .page(
                    "session.list",
                    "completedAtDescSessionIdAsc",
                    1,
                    None,
                    || Ok(vec![])
                )
                .is_err()
        );
        assert_eq!(fs::read(outside).unwrap(), bytes);
    }
    #[test]
    fn byte_bounds_apply_before_publication_and_corrupt_pages_never_escape() {
        let root = Root::new();
        let pager = root.pager();
        assert_eq!(
            pager
                .page("session.list", "order", 1, None, || Ok(vec![json!(
                    "x".repeat(MAX_PAGE)
                )]))
                .unwrap_err()
                .code,
            "inputTooLarge"
        );
        let page = first(&pager);
        let path = root
            .0
            .join(filename(page["snapshotRevision"].as_str().unwrap()));
        let mut snapshot: Value = serde_json::from_slice(&fs::read(&path).unwrap()).unwrap();
        snapshot["tokens"][1] = snapshot["tokens"][0].clone();
        fs::write(path, serde_json::to_vec(&snapshot).unwrap()).unwrap();
        assert_eq!(
            pager
                .page(
                    "session.list",
                    "completedAtDescSessionIdAsc",
                    1,
                    page["nextCursor"].as_str(),
                    || panic!()
                )
                .unwrap_err()
                .code,
            "recordUnreadable"
        );
    }
}
