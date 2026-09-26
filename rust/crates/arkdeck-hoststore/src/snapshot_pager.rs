//! Private immutable pages for resource discovery. A cursor identifies a stored
//! page and its query; it never causes another inventory scan or a silent restart.
//!
//! Neither storing nor reading a snapshot holds it twice. Storing encodes each
//! row once, into the stored document, and keeps only the first page's rows for
//! the answer. Reading a stored page streams the retained file in two passes:
//! the first validates the whole document exactly as decoding it whole did
//! (strict JSON, its closed members, every page's bounds) while holding one
//! page at a time; the second keeps only the page the cursor names.
use arkdeck_contract::{StrictValue, WireError, canonical_json, sha256_hex, strict_json};
use arkdeck_platform::{HostDirectory, HostDocument, HostDocumentPass, HostReadLock, random_bytes};
use serde::Deserialize;
use serde::de::{self, DeserializeSeed, MapAccess, SeqAccess, Visitor};
use serde_json::{Map, Value, json};
use std::{
    cell::Cell,
    collections::BTreeSet,
    fmt,
    io::{self, Read},
    path::{Path, PathBuf},
};

const MAX_SNAPSHOT: usize = 16 * 1024 * 1024;
const MAX_PAGE: usize = 1024 * 1024;
const MAX_TOTAL: u64 = 64 * 1024 * 1024;
const LOCK: &str = ".snapshots.lock";
const SCHEMA: &str = "arkdeck.runtime-snapshot/1";
/// The read-ahead of one pass over a stored snapshot.
const PASS_BUFFER: usize = 64 * 1024;

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
/// Swift `RuntimeSnapshotPager.invalidCursor()`: one sentence for a cursor of
/// the wrong shape, of another query, or of a reclaimed snapshot.
fn invalid_cursor() -> WireError {
    failure(
        "invalidCursor",
        "cursor is invalid, belongs to another query or its snapshot was reclaimed",
    )
}
/// A failed read of a stored snapshot: one no longer present was reclaimed.
fn read_failure(error: io::Error) -> WireError {
    if error.kind() == io::ErrorKind::NotFound {
        invalid_cursor()
    } else {
        unreadable(error)
    }
}

pub(crate) struct SnapshotPager {
    root: HostDirectory,
    path: PathBuf,
    /// Whether the pager holds its own lock document; a pager whose owner
    /// already serializes every request keeps none.
    locked: bool,
}

/// The page an answer carries.
struct Page {
    revision: String,
    items: Vec<Value>,
    more: bool,
    next: Option<String>,
}

/// A snapshot being stored, built as its rows arrive in answer order, in
/// pages of at most `page_size` rows and `MAX_PAGE` bytes. The document is
/// the canonical encoding of the snapshot, written as it is built: its
/// members in canonical order put the pages before their tokens, and each
/// row is encoded once, straight into it. Only the first page's rows are
/// kept as values, for the answer.
struct Draft {
    page_size: usize,
    document: Vec<u8>,
    first: Vec<Value>,
    /// Pages closed so far, and rows on the open one.
    pages: usize,
    current: usize,
    /// Bytes on the open page, and in every page so far.
    bytes: usize,
    total: usize,
    /// The refusal of the first row the snapshot could not take; no later
    /// row is encoded.
    refused: Option<WireError>,
}

impl Draft {
    fn new(order: &str, page_size: usize) -> Result<Self, WireError> {
        let mut document = b"{\"order\":".to_vec();
        document.extend(canonical_json(&json!(order)).map_err(unreadable)?);
        document.extend_from_slice(b",\"pages\":[");
        Ok(Self {
            page_size,
            document,
            first: Vec::new(),
            pages: 0,
            current: 0,
            bytes: 2,
            total: 0,
            refused: None,
        })
    }

    fn push(&mut self, row: Value) {
        if self.refused.is_none()
            && let Err(refusal) = self.add(row)
        {
            self.refused = Some(refusal);
        }
    }

    fn add(&mut self, row: Value) -> Result<(), WireError> {
        let encoded = canonical_json(&row).map_err(unreadable)?;
        let size = encoded.len() + 1;
        if size + 2 > MAX_PAGE {
            return Err(failure(
                "inputTooLarge",
                "resource projection exceeds its page bound",
            ));
        }
        if self.current == self.page_size || self.bytes + size > MAX_PAGE {
            self.document.push(b']');
            self.pages += 1;
            self.current = 0;
            self.bytes = 2;
        }
        self.total += size;
        if self.total > MAX_SNAPSHOT {
            return Err(failure(
                "operationUnavailable",
                "snapshot exceeds its storage bound",
            ));
        }
        let separator: &[u8] = match (self.pages, self.current) {
            (0, 0) => b"[",
            (_, 0) => b",[",
            _ => b",",
        };
        self.document.extend_from_slice(separator);
        self.document.extend(encoded);
        if self.pages == 0 {
            self.first.push(row);
        }
        self.current += 1;
        self.bytes += size;
        Ok(())
    }
}

pub(crate) fn uuid() -> Result<String, WireError> {
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
            locked: true,
        })
    }

    /// A pager whose owner serializes every request itself, as Swift's
    /// agent execution owner (an actor) does: no lock document beside the
    /// snapshots, as Swift's `RuntimeSnapshotPager` keeps none.
    pub(crate) fn open_serialized(path: &Path) -> io::Result<Self> {
        Ok(Self {
            locked: false,
            ..Self::open(path)?
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
        self.page_filtered(method, &json!({}), order, page_size, cursor, items)
    }

    pub(crate) fn page_filtered(
        &self,
        method: &str,
        filters: &Value,
        order: &str,
        page_size: usize,
        cursor: Option<&str>,
        items: impl FnOnce() -> Result<Vec<Value>, WireError>,
    ) -> Result<Value, WireError> {
        self.page_with(method, filters, order, page_size, cursor, |draft| {
            for row in items()? {
                draft.push(row);
            }
            Ok(())
        })
    }

    /// [`Self::page_filtered`] for an owner that hands its rows over one at a
    /// time, in answer order, rather than all at once: a new snapshot holds
    /// the encoding of each row and the values of its first page only. The
    /// owner's refusal, returned once it has handed over what it had, comes
    /// before any refusal of a row it handed over, as when it refused before
    /// the snapshot was built.
    pub(crate) fn page_streamed(
        &self,
        method: &str,
        filters: &Value,
        order: &str,
        page_size: usize,
        cursor: Option<&str>,
        rows: impl FnOnce(&mut dyn FnMut(Value)) -> Result<(), WireError>,
    ) -> Result<Value, WireError> {
        self.page_with(method, filters, order, page_size, cursor, |draft| {
            rows(&mut |row| draft.push(row))
        })
    }

    fn page_with(
        &self,
        method: &str,
        filters: &Value,
        order: &str,
        page_size: usize,
        cursor: Option<&str>,
        fill: impl FnOnce(&mut Draft) -> Result<(), WireError>,
    ) -> Result<Value, WireError> {
        if !(1..=1000).contains(&page_size) {
            return Err(failure(
                "invalidInput",
                "pageSize must be between 1 and 1000",
            ));
        }
        let query = canonical_json(
            &json!({"method":method,"filters":filters,"order":order,"pageSize":page_size}),
        )
        .map_err(unreadable)?;
        let digest = sha256_hex(&query);
        self.root.validate_path(&self.path).map_err(unreadable)?;
        let lock = if self.locked {
            Some(self.root.lock_document(LOCK).map_err(|error| {
                if error.kind() == io::ErrorKind::WouldBlock {
                    failure("resourceConflict", "Snapshot storage is being updated")
                } else {
                    unreadable(error)
                }
            })?)
        } else {
            None
        };
        let page = if let Some(cursor) = cursor {
            let (revision, _) = cursor_parts(cursor).ok_or_else(invalid_cursor)?;
            self.read(revision, cursor, &digest, order)?
        } else {
            let mut draft = Draft::new(order, page_size)?;
            fill(&mut draft)?;
            self.store(lock.as_ref(), &digest, draft)?
        };
        if let Some(lock) = &lock {
            lock.validate_link(&self.root, LOCK).map_err(unreadable)?;
        }
        self.root.validate_path(&self.path).map_err(unreadable)?;
        // The answer `json!` would build, in its member order, with the page's
        // rows moved into it rather than copied.
        let mut answer = Map::new();
        answer.insert("schemaVersion".into(), json!("arkdeck.cli.page/1"));
        answer.insert("pageKind".into(), json!("snapshot"));
        answer.insert("items".into(), Value::Array(page.items));
        answer.insert("order".into(), json!(order));
        answer.insert("snapshotRevision".into(), Value::String(page.revision));
        answer.insert("hasMore".into(), Value::Bool(page.more));
        answer.insert(
            "nextCursor".into(),
            page.next.map_or(Value::Null, Value::String),
        );
        Ok(Value::Object(answer))
    }

    /// Store a drafted snapshot and answer its first page.
    fn store(
        &self,
        lock: Option<&HostReadLock>,
        digest: &str,
        draft: Draft,
    ) -> Result<Page, WireError> {
        let revision = uuid()?;
        let Draft {
            mut document,
            first,
            pages,
            current,
            refused,
            ..
        } = draft;
        if let Some(refusal) = refused {
            return Err(refusal);
        }
        // The last page closes; a snapshot of no rows has one empty page.
        document.extend_from_slice(if current > 0 { b"]" } else { b"[]" });
        let pages = pages + 1;
        let tokens = (0..pages)
            .map(|_| uuid().map(|token| format!("{revision}.{token}")))
            .collect::<Result<Vec<_>, _>>()?;
        let canonical = |value: Value| canonical_json(&value).map_err(unreadable);
        document.extend_from_slice(b"],\"queryDigest\":");
        document.extend(canonical(json!(digest))?);
        document.extend_from_slice(b",\"revision\":");
        document.extend(canonical(json!(revision))?);
        document.extend_from_slice(b",\"schemaVersion\":");
        document.extend(canonical(json!(SCHEMA))?);
        document.extend_from_slice(b",\"tokens\":");
        document.extend(canonical(json!(tokens))?);
        document.push(b'}');
        if document.len() > MAX_SNAPSHOT {
            return Err(failure(
                "operationUnavailable",
                "snapshot exceeds its encoded storage bound",
            ));
        }
        self.retain_space(document.len())?;
        if let Some(lock) = lock {
            lock.validate_link(&self.root, LOCK).map_err(unreadable)?;
        }
        self.root.validate_path(&self.path).map_err(unreadable)?;
        self.root
            .publish_document(&filename(&revision), &document, MAX_SNAPSHOT)
            .map_err(unreadable)?;
        Ok(Page {
            next: tokens.into_iter().nth(1),
            more: pages > 1,
            revision,
            items: first,
        })
    }

    /// The page `cursor` names in stored snapshot `revision`, if that
    /// snapshot answers this query. One pass validates the whole document,
    /// holding a page at a time, and notes where each page lies; only then is
    /// the cursor's page found, and just its bytes are read again, from the
    /// same inode.
    fn read(
        &self,
        revision: &str,
        cursor: &str,
        digest: &str,
        order: &str,
    ) -> Result<Page, WireError> {
        let document = self
            .root
            .open_document(&filename(revision), MAX_SNAPSHOT)
            .map_err(read_failure)?;
        let (stored, length) = pass(&document)?;
        if stored.schema_version != SCHEMA
            || stored.revision != revision
            || stored.pages.is_empty()
            || stored.pages.len() != stored.tokens.len()
            || stored.tokens.iter().collect::<BTreeSet<_>>().len() != stored.tokens.len()
            || stored
                .tokens
                .iter()
                .any(|token| cursor_parts(token).is_none_or(|(id, _)| id != revision))
        {
            return Err(unreadable(()));
        }
        if stored.query_digest != digest || stored.order != order {
            return Err(invalid_cursor());
        }
        let index = stored
            .tokens
            .iter()
            .position(|value| value == cursor)
            .ok_or_else(invalid_cursor)?;
        let place = &stored.pages[index];
        let bytes = document
            .read_range(place.start..place.end)
            .map_err(read_failure)?;
        document.check(length).map_err(read_failure)?;
        Ok(Page {
            revision: revision.into(),
            items: place.decode(&bytes).ok_or_else(|| unreadable(()))?,
            more: index + 1 < stored.pages.len(),
            next: stored.tokens.into_iter().nth(index + 1),
        })
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

/// The pass over a stored snapshot, from its first byte to its end, and the
/// bytes it read, answered as a whole read and then a whole decode answered:
/// a failed read is that read's failure; a document that changed, was
/// replaced or was removed while it was read is refused before anything
/// decoded from it counts; any other refusal is `recordUnreadable`.
fn pass(document: &HostDocument<'_>) -> Result<(Stored, u64), WireError> {
    let handed = Cell::new(0);
    let mut reader = Counted {
        pass: document.pass(),
        buffer: vec![0; PASS_BUFFER].into_boxed_slice(),
        start: 0,
        end: 0,
        handed: &handed,
    };
    let decoded = decode(&mut reader, &handed);
    if let Err(error) = &decoded
        && let Some(kind) = error.io_error_kind()
    {
        return Err(read_failure(kind.into()));
    }
    // A whole read reads to the end before anything is decoded, and the read
    // is judged first. So is a document refused part way through.
    if decoded.is_err() {
        io::copy(&mut reader.pass, &mut io::sink()).map_err(read_failure)?;
    }
    let length = reader.pass.position();
    document.check(length).map_err(read_failure)?;
    Ok((decoded.map_err(unreadable)?, length))
}

/// A pass's bytes, buffered, counting the bytes handed on to the decoder: how
/// far it has read, from which the pass notes where each page lies.
struct Counted<'a> {
    pass: HostDocumentPass<'a>,
    buffer: Box<[u8]>,
    start: usize,
    end: usize,
    handed: &'a Cell<u64>,
}

impl Read for Counted<'_> {
    fn read(&mut self, into: &mut [u8]) -> io::Result<usize> {
        if self.start == self.end {
            self.end = self.pass.read(&mut self.buffer)?;
            self.start = 0;
        }
        let count = into.len().min(self.end - self.start);
        into[..count].copy_from_slice(&self.buffer[self.start..self.start + count]);
        self.start += count;
        self.handed.set(self.handed.get() + count as u64);
        Ok(count)
    }
}

/// The members of a stored snapshot, in the order its type declared them.
const MEMBERS: [&str; 6] = [
    "schemaVersion",
    "revision",
    "queryDigest",
    "order",
    "tokens",
    "pages",
];

/// Every member of a stored snapshot but its pages, of which the pass keeps
/// where each lies.
struct Stored {
    schema_version: String,
    revision: String,
    query_digest: String,
    order: String,
    tokens: Vec<String>,
    pages: Vec<Place>,
}

/// Where a page lies in the stored document, from its opening bracket to its
/// closing one, and the length of its canonical encoding.
struct Place {
    start: u64,
    end: u64,
    encoded: usize,
}

impl Place {
    /// The page's rows, decoded again from its bytes, which the pass decoded
    /// in place, within the whole document: the same bracketed array of the
    /// same encoding, or nothing.
    fn decode(&self, bytes: &[u8]) -> Option<Vec<Value>> {
        if bytes.first() != Some(&b'[') || bytes.last() != Some(&b']') {
            return None;
        }
        let page = strict_json(bytes).ok()?;
        if canonical_json(&page).ok()?.len() != self.encoded {
            return None;
        }
        match page {
            Value::Array(rows) => Some(rows),
            _ => None,
        }
    }
}

/// Decode a stored snapshot from `reader` exactly as `strict_json` and the
/// snapshot's derived decoding decoded it whole: each row a [`StrictValue`],
/// decoded in place at the depth the whole document gives it; the members
/// closed, each once, of their types; nothing but whitespace after the
/// document; and every page within its bounds. `handed` counts the bytes the
/// decoder has taken from `reader`.
fn decode(reader: impl Read, handed: &Cell<u64>) -> serde_json::Result<Stored> {
    let mut decoder = serde_json::Deserializer::from_reader(reader);
    let stored = de::Deserializer::deserialize_struct(
        &mut decoder,
        "Snapshot",
        &MEMBERS,
        Envelope { handed },
    )?;
    decoder.end()?;
    Ok(stored)
}

struct Envelope<'a> {
    handed: &'a Cell<u64>,
}

fn missing<E: de::Error>() -> E {
    E::custom("a snapshot member is missing")
}

/// A member named twice is refused, as `strict_json` refuses it.
fn once<T, E: de::Error>(slot: &Option<T>) -> Result<(), E> {
    match slot {
        Some(_) => Err(E::custom("a snapshot member is repeated")),
        None => Ok(()),
    }
}

impl<'de> Visitor<'de> for Envelope<'_> {
    type Value = Stored;

    fn expecting(&self, formatter: &mut fmt::Formatter<'_>) -> fmt::Result {
        formatter.write_str("a Runtime snapshot")
    }

    fn visit_map<A: MapAccess<'de>>(self, mut map: A) -> Result<Stored, A::Error> {
        let (mut schema_version, mut revision, mut query_digest, mut order) =
            (None, None, None, None);
        let (mut tokens, mut pages) = (None, None);
        while let Some(name) = map.next_key::<String>()? {
            match name.as_str() {
                "schemaVersion" => {
                    once(&schema_version)?;
                    schema_version = Some(map.next_value()?);
                }
                "revision" => {
                    once(&revision)?;
                    revision = Some(map.next_value()?);
                }
                "queryDigest" => {
                    once(&query_digest)?;
                    query_digest = Some(map.next_value()?);
                }
                "order" => {
                    once(&order)?;
                    order = Some(map.next_value()?);
                }
                "tokens" => {
                    once(&tokens)?;
                    tokens = Some(map.next_value()?);
                }
                "pages" => {
                    once(&pages)?;
                    pages = Some(map.next_value_seed(Pages {
                        handed: self.handed,
                    })?);
                }
                _ => return Err(de::Error::custom("a snapshot member is not published")),
            }
        }
        Ok(Stored {
            schema_version: schema_version.ok_or_else(missing)?,
            revision: revision.ok_or_else(missing)?,
            query_digest: query_digest.ok_or_else(missing)?,
            order: order.ok_or_else(missing)?,
            tokens: tokens.ok_or_else(missing)?,
            pages: pages.ok_or_else(missing)?,
        })
    }

    /// The derived decoding also takes a struct's members as an array in
    /// their declared order, so this does too: the documents accepted stay
    /// exactly those accepted before.
    fn visit_seq<A: SeqAccess<'de>>(self, mut seq: A) -> Result<Stored, A::Error> {
        Ok(Stored {
            schema_version: seq.next_element()?.ok_or_else(missing)?,
            revision: seq.next_element()?.ok_or_else(missing)?,
            query_digest: seq.next_element()?.ok_or_else(missing)?,
            order: seq.next_element()?.ok_or_else(missing)?,
            tokens: seq.next_element()?.ok_or_else(missing)?,
            pages: seq
                .next_element_seed(Pages {
                    handed: self.handed,
                })?
                .ok_or_else(missing)?,
        })
    }
}

/// A stored snapshot's pages, each decoded, checked against its bounds and
/// dropped, keeping only where it lies.
struct Pages<'a> {
    handed: &'a Cell<u64>,
}

impl<'de> DeserializeSeed<'de> for Pages<'_> {
    type Value = Vec<Place>;

    fn deserialize<D: de::Deserializer<'de>>(self, decoder: D) -> Result<Self::Value, D::Error> {
        decoder.deserialize_seq(self)
    }
}

impl<'de> Visitor<'de> for Pages<'_> {
    type Value = Vec<Place>;

    fn expecting(&self, formatter: &mut fmt::Formatter<'_>) -> fmt::Result {
        formatter.write_str("snapshot pages")
    }

    fn visit_seq<A: SeqAccess<'de>>(self, mut seq: A) -> Result<Self::Value, A::Error> {
        let mut places = Vec::new();
        while let Some(place) = seq.next_element_seed(PageSeed {
            handed: self.handed,
        })? {
            places.push(place);
        }
        Ok(places)
    }
}

/// One page, decoded in place. When it is handed to this seed the decoder
/// has taken the page's opening bracket, looking ahead for it; when the page
/// is decoded it has taken the closing bracket and nothing after it.
struct PageSeed<'a> {
    handed: &'a Cell<u64>,
}

impl<'de> DeserializeSeed<'de> for PageSeed<'_> {
    type Value = Place;

    fn deserialize<D: de::Deserializer<'de>>(self, decoder: D) -> Result<Place, D::Error> {
        let start = self.handed.get().checked_sub(1).ok_or_else(missing)?;
        let page = Vec::<StrictValue>::deserialize(decoder)?;
        let end = self.handed.get();
        let page: Vec<Value> = page.into_iter().map(|StrictValue(row)| row).collect();
        // Every stored page holds at most 1000 rows and `MAX_PAGE` bytes
        // encoded.
        let encoded = (page.len() <= 1000)
            .then(|| canonical_json(&Value::Array(page)).ok())
            .flatten()
            .map(|bytes| bytes.len())
            .filter(|length| *length <= MAX_PAGE)
            .ok_or_else(|| de::Error::custom("a snapshot page exceeds its bounds"))?;
        Ok(Place {
            start,
            end,
            encoded,
        })
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
    /// A cursor of another query, and one naming a reclaimed snapshot, are
    /// refused as Swift's `RuntimeSnapshotPager` refuses them: Swift's
    /// recorded `session.list` answer, whose handler passes the pager's
    /// refusal through (ControlFrames `session.list.jsonl`, line 1).
    #[test]
    fn a_foreign_or_reclaimed_cursor_is_refused_in_swifts_words() {
        let recorded: Value = {
            let path = std::path::Path::new(env!("CARGO_MANIFEST_DIR")).join(
                "../../../Packages/ArkDeckKit/Tests/ArkDeckContractTests/Fixtures/ControlFrames/session.list.jsonl",
            );
            let text = fs::read_to_string(path).unwrap();
            serde_json::from_str::<Value>(text.lines().next().unwrap()).unwrap()["error"].clone()
        };
        let answered = |error: WireError| json!({"code": error.code, "message": error.message, "details": error.details});
        let root = Root::new();
        let cursor = first(&root.pager())["nextCursor"]
            .as_str()
            .unwrap()
            .to_owned();
        let pager = root.pager();
        let foreign = pager
            .page(
                "session.list",
                "startedAtDescSessionIdAsc",
                1,
                Some(&cursor),
                || panic!("a refused cursor never rescans"),
            )
            .unwrap_err();
        assert_eq!(answered(foreign), recorded);
        for entry in fs::read_dir(&root.0).unwrap() {
            let path = entry.unwrap().path();
            if path
                .extension()
                .is_some_and(|extension| extension == "json")
            {
                fs::remove_file(path).unwrap();
            }
        }
        let reclaimed = pager
            .page(
                "session.list",
                "completedAtDescSessionIdAsc",
                1,
                Some(&cursor),
                || panic!("a refused cursor never rescans"),
            )
            .unwrap_err();
        assert_eq!(answered(reclaimed), recorded);
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

#[cfg(test)]
#[path = "snapshot_pager_tests.rs"]
mod bounded_tests;
