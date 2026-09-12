//! Metadata event stream. Encrypted cursors grant no execution authority.
use crate::{
    job_journal::JournalEvent,
    job_record::{failure, unreadable},
};
use aes_gcm::{
    Aes256Gcm, KeyInit, Nonce,
    aead::{Aead, Payload},
};
use arkdeck_contract::{WireError, sha256_hex, strict_json};
use arkdeck_platform::HostJournal;
use serde::{Deserialize, Serialize};
use serde_json::{Value, json};
use std::{collections::BTreeSet, path::Path};
const MAX_RECORD: usize = 16 * 1024 * 1024;
const AAD: &[u8] = b"arkdeck.job.events.cursor/1:streamPositionAsc";
#[derive(Serialize, Deserialize)]
#[serde(rename_all = "camelCase", deny_unknown_fields)]
struct Cursor {
    #[serde(rename = "jobID")]
    job_id: String,
    device: i64,
    inode: u64,
    generation: u32,
    origin_hash: String,
    offset: u64,
    position: u64,
    previous_offset: u64,
    previous_hash: String,
    high_water_position: u64,
    high_water_offset: u64,
}
fn invalid_cursor() -> WireError {
    failure(
        "invalidCursor",
        "The opaque cursor does not belong to this Job event stream",
    )
}
const ALPHABET: &[u8; 64] = b"ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789-_";
fn base64(bytes: &[u8]) -> String {
    let mut result = String::new();
    for chunk in bytes.chunks(3) {
        let n = (u32::from(chunk[0]) << 16)
            | (u32::from(*chunk.get(1).unwrap_or(&0)) << 8)
            | u32::from(*chunk.get(2).unwrap_or(&0));
        for shift in [18, 12, 6, 0].into_iter().take(chunk.len() + 1) {
            result.push(ALPHABET[((n >> shift) & 63) as usize] as char);
        }
    }
    result
}
fn unbase64(text: &str) -> Result<Vec<u8>, WireError> {
    if text.is_empty() || text.len() > 2043 || text.len() % 4 == 1 {
        return Err(invalid_cursor());
    }
    let mut result = Vec::new();
    let mut bits = 0_u32;
    let mut count = 0;
    for byte in text.bytes() {
        let value = ALPHABET
            .iter()
            .position(|v| *v == byte)
            .ok_or_else(invalid_cursor)? as u32;
        bits = (bits << 6) | value;
        count += 6;
        if count >= 8 {
            count -= 8;
            result.push((bits >> count) as u8);
        }
    }
    if base64(&result) != text {
        return Err(invalid_cursor());
    }
    Ok(result)
}
impl Cursor {
    fn encode(&self, key: &[u8; 32]) -> Result<String, WireError> {
        let cipher = Aes256Gcm::new_from_slice(key).map_err(unreadable)?;
        let nonce = arkdeck_platform::random_bytes::<12>().map_err(unreadable)?;
        let payload = serde_json::to_vec(self).map_err(unreadable)?;
        let encrypted = cipher
            .encrypt(
                Nonce::from_slice(&nonce),
                Payload {
                    msg: &payload,
                    aad: AAD,
                },
            )
            .map_err(unreadable)?;
        let mut combined = nonce.to_vec();
        combined.extend(encrypted);
        Ok(format!("jec1.{}", base64(&combined)))
    }
    fn decode(text: &str, key: &[u8; 32], job: &str) -> Result<Self, WireError> {
        let bytes = unbase64(text.strip_prefix("jec1.").ok_or_else(invalid_cursor)?)?;
        if bytes.len() < 28 {
            return Err(invalid_cursor());
        }
        let cipher = Aes256Gcm::new_from_slice(key).map_err(|_| invalid_cursor())?;
        let plain = cipher
            .decrypt(
                Nonce::from_slice(&bytes[..12]),
                Payload {
                    msg: &bytes[12..],
                    aad: AAD,
                },
            )
            .map_err(|_| invalid_cursor())?;
        let value = strict_json(&plain).map_err(|_| invalid_cursor())?;
        let result: Self = serde_json::from_value(value).map_err(|_| invalid_cursor())?;
        if result.job_id != job
            || result.offset > i64::MAX as u64
            || result.position > i64::MAX as u64
            || result.high_water_position > i64::MAX as u64
            || result.high_water_offset > i64::MAX as u64
            || result.high_water_position < result.position
            || result.high_water_offset < result.offset
            || result.previous_offset > result.offset
            || (result.position == 0) != (result.offset == 0)
        {
            return Err(invalid_cursor());
        }
        Ok(result)
    }
}
struct Row {
    bytes: Vec<u8>,
    end: u64,
    event: JournalEvent,
}
struct Reader<'a> {
    file: &'a HostJournal,
    offset: u64,
    limit: u64,
    buffer: Vec<u8>,
    consumed: usize,
    read_offset: u64,
}
impl<'a> Reader<'a> {
    fn new(file: &'a HostJournal, offset: u64, limit: u64) -> Self {
        Self {
            file,
            offset,
            limit,
            buffer: Vec::new(),
            consumed: 0,
            read_offset: offset,
        }
    }
    fn next(&mut self) -> Result<Option<Row>, WireError> {
        let mut line = Vec::new();
        loop {
            if self.consumed < self.buffer.len() {
                let remainder = &self.buffer[self.consumed..];
                let newline = remainder.iter().position(|b| *b == 10);
                let n = newline.unwrap_or(remainder.len());
                if line.len() + n > MAX_RECORD {
                    return Err(unreadable("oversized Journal record"));
                }
                line.extend_from_slice(&remainder[..n]);
                self.offset += n as u64;
                self.consumed += n;
                if newline.is_some() {
                    self.offset += 1;
                    self.consumed += 1;
                    let event = JournalEvent::decode(&line).map_err(unreadable)?;
                    return Ok(Some(Row {
                        bytes: line,
                        end: self.offset,
                        event,
                    }));
                }
            }
            if self.read_offset >= self.limit {
                return Ok(None);
            }
            self.buffer = self
                .file
                .read(
                    self.read_offset,
                    (self.limit - self.read_offset).min(65536) as usize,
                )
                .map_err(unreadable)?;
            self.read_offset += self.buffer.len() as u64;
            self.consumed = 0;
        }
    }
}
fn tail(file: &HostJournal) -> Result<Row, WireError> {
    let end = file.byte_count();
    let mut start = end;
    let mut last_lf = None;
    while start > 0 {
        let count = start.min(65536) as usize;
        start -= count as u64;
        if end - start > (MAX_RECORD * 2 + 65536) as u64 {
            return Err(unreadable("oversized Journal tail"));
        }
        let chunk = file.read(start, count).map_err(unreadable)?;
        for (index, byte) in chunk.iter().enumerate().rev() {
            if *byte != 10 {
                continue;
            }
            if let Some(last) = last_lf {
                let begin = start + index as u64 + 1;
                let length = last - begin;
                if length == 0 || length > MAX_RECORD as u64 {
                    return Err(unreadable("invalid Journal tail"));
                }
                let bytes = file.read(begin, length as usize).map_err(unreadable)?;
                let event = JournalEvent::decode(&bytes).map_err(unreadable)?;
                return Ok(Row {
                    bytes,
                    end: last + 1,
                    event,
                });
            }
            last_lf = Some(start + index as u64);
        }
    }
    let last = last_lf
        .filter(|n| *n > 0 && *n <= MAX_RECORD as u64)
        .ok_or_else(|| unreadable("missing Journal origin"))?;
    let bytes = file.read(0, last as usize).map_err(unreadable)?;
    let event = JournalEvent::decode(&bytes).map_err(unreadable)?;
    Ok(Row {
        bytes,
        end: last + 1,
        event,
    })
}
pub fn page(
    directory: &Path,
    job: &str,
    session: &str,
    after: Option<&str>,
    page_size: usize,
) -> Result<Value, WireError> {
    if !(1..=1000).contains(&page_size) {
        return Err(failure(
            "invalidInput",
            "pageSize must be between 1 and 1000",
        ));
    }
    let file = HostJournal::open(directory).map_err(unreadable)?;
    let key = file.cursor_key(after.is_some()).map_err(|error| {
        if after.is_some() && error.kind() == std::io::ErrorKind::NotFound {
            invalid_cursor()
        } else {
            unreadable(error)
        }
    })?;
    let cursor = after
        .map(|text| Cursor::decode(text, &key, job))
        .transpose()?;
    let origin = Reader::new(&file, 0, file.byte_count())
        .next()?
        .ok_or_else(|| unreadable("missing Journal origin"))?;
    if origin.event.sequence() != 0
        || origin.event.kind() != "jobCreated"
        || origin.event.job_id() != job
        || origin.event.session_id() != session
    {
        return Err(unreadable("invalid Journal origin"));
    }
    let origin_hash = sha256_hex(&origin.bytes);
    let tail = tail(&file)?;
    if tail.event.job_id() != job
        || tail.event.session_id() != session
        || tail.event.sequence() >= i64::MAX as u64
    {
        return Err(unreadable("invalid Journal tail"));
    }
    let high_water = tail.event.sequence() + 1;
    let durable_end = tail.end;
    let mut state = Cursor {
        job_id: job.into(),
        device: file.device(),
        inode: file.inode(),
        generation: file.generation(),
        origin_hash,
        offset: 0,
        position: 0,
        previous_offset: 0,
        previous_hash: String::new(),
        high_water_position: high_water,
        high_water_offset: durable_end,
    };
    if let Some(cursor) = cursor {
        if cursor.device != state.device
            || cursor.inode != state.inode
            || cursor.generation != state.generation
            || cursor.origin_hash != state.origin_hash
            || cursor.high_water_position > high_water
            || cursor.high_water_offset > durable_end
            || cursor.offset > durable_end
        {
            return Err(unreadable("replaced or truncated Journal"));
        }
        if cursor.position > 0 {
            let prior = Reader::new(&file, cursor.previous_offset, cursor.offset)
                .next()?
                .ok_or_else(|| unreadable("missing cursor predecessor"))?;
            if prior.end != cursor.offset
                || prior.event.job_id() != job
                || prior.event.session_id() != session
                || prior.event.sequence() != cursor.position - 1
                || sha256_hex(&prior.bytes) != cursor.previous_hash
            {
                return Err(unreadable("changed cursor predecessor"));
            }
        }
        state.offset = cursor.offset;
        state.position = cursor.position;
        state.previous_offset = cursor.previous_offset;
        state.previous_hash = cursor.previous_hash;
    }
    let mut reader = Reader::new(&file, state.offset, durable_end);
    let mut items = Vec::new();
    let mut response_bytes = 0;
    let mut ids = BTreeSet::new();
    while items.len() < page_size {
        let Some(row) = reader.next()? else {
            break;
        };
        if row.event.job_id() != job
            || row.event.session_id() != session
            || row.event.sequence() != state.position
            || !ids.insert(row.event.event_id().to_owned())
        {
            return Err(unreadable("invalid Journal sequence or identity"));
        }
        let projection = row.event.projection().map_err(unreadable)?;
        let estimate = serde_json::to_vec(&projection).map_err(unreadable)?.len() + 2048;
        if !items.is_empty() && response_bytes + estimate > 1024 * 1024 {
            break;
        }
        state.previous_offset = state.offset;
        state.previous_hash = sha256_hex(&row.bytes);
        state.offset = row.end;
        state.position += 1;
        items.push(json!({"eventId":row.event.event_id(), "streamPosition":state.position.to_string(), "runtimeRevision":high_water.to_string(),
            "cursor":state.encode(&key)?, "type":if row.event.kind() == "stateTransition" { "stateChanged" } else { "journalEvent" }, "data":projection}));
        response_bytes += estimate;
    }
    if state.position > high_water || (state.offset < durable_end) != (state.position < high_water)
    {
        return Err(unreadable("inconsistent Journal high water"));
    }
    file.validate().map_err(unreadable)?;
    Ok(
        json!({"schemaVersion":"arkdeck.cli.page/1","pageKind":"eventStream","items":items,"order":"streamPositionAsc", "snapshotRevision":high_water.to_string(),"hasMore":state.offset < durable_end,"nextCursor":state.encode(&key)?}),
    )
}

#[cfg(test)]
mod tests {
    use super::*;
    use std::{fs, io::Write, os::unix::fs::PermissionsExt, path::PathBuf};
    const JOURNAL: &str = include_str!("../../../tests/fixtures/journal/all-event-kinds.jsonl");
    struct Root(PathBuf);
    impl Root {
        fn new() -> Self {
            let n = u128::from_ne_bytes(arkdeck_platform::random_bytes::<16>().unwrap());
            let p = PathBuf::from(format!("/private/tmp/arkdeck-events-{n:032x}"));
            fs::create_dir(&p).unwrap();
            fs::set_permissions(&p, fs::Permissions::from_mode(0o700)).unwrap();
            fs::write(p.join("journal.jsonl"), JOURNAL).unwrap();
            Self(p)
        }
        fn page(&self, after: Option<&str>, size: usize) -> Result<Value, WireError> {
            page(&self.0, "job-1", "session-1", after, size)
        }
        fn append(&self, bytes: &[u8]) {
            let mut f = fs::OpenOptions::new()
                .append(true)
                .open(self.0.join("journal.jsonl"))
                .unwrap();
            f.write_all(bytes).unwrap();
            f.sync_all().unwrap();
        }
    }
    impl Drop for Root {
        fn drop(&mut self) {
            fs::remove_dir_all(&self.0).unwrap();
        }
    }
    #[test]
    fn closed_swift_fixture_kinds_and_immutable_metadata_pages() {
        let mut kinds = BTreeSet::new();
        for (index, line) in JOURNAL.lines().enumerate() {
            let event = JournalEvent::decode(line.as_bytes())
                .unwrap_or_else(|error| panic!("row {index}: {error:?}"));
            kinds.insert(event.kind().to_owned());
            let mut altered: Value = serde_json::from_str(line).unwrap();
            altered["future"] = json!(true);
            assert!(JournalEvent::decode(&serde_json::to_vec(&altered).unwrap()).is_err());
        }
        assert_eq!(
            kinds,
            crate::JOURNAL_KINDS.iter().map(|s| s.to_string()).collect()
        );
        let root = Root::new();
        let first = root.page(None, 2).unwrap();
        assert_eq!(first["items"][0]["streamPosition"], "1");
        assert_eq!(first["snapshotRevision"], "19");
        let after_first_row = first["items"][0]["cursor"].as_str().unwrap();
        let resumed = root.page(Some(after_first_row), 100).unwrap();
        assert_eq!(resumed["items"][0]["streamPosition"], "2");
        assert_eq!(resumed["items"].as_array().unwrap().len(), 18);
        assert_eq!(resumed["hasMore"], false);
        let empty = root.page(resumed["nextCursor"].as_str(), 100).unwrap();
        assert_eq!(empty["items"], json!([]));
        let bytes = serde_json::to_string(&resumed).unwrap();
        for private in [
            "/usr/bin/true",
            "remote-task-unknown",
            "candidate-1",
            "argumentsHash",
            "fixture.warning",
        ] {
            assert!(!bytes.contains(private));
        }
        assert_eq!(
            fs::read(root.0.join("journal.jsonl")).unwrap(),
            JOURNAL.as_bytes()
        );
        assert_eq!(
            fs::metadata(root.0.join("event-cursor-key.v1"))
                .unwrap()
                .permissions()
                .mode()
                & 0o777,
            0o600
        );
    }
    #[test]
    fn interrupted_append_resumes_only_after_a_complete_line() {
        let root = Root::new();
        let end = root.page(None, 100).unwrap();
        let token = end["nextCursor"].as_str().unwrap();
        let mut next: Value = serde_json::from_str(JOURNAL.lines().nth(16).unwrap()).unwrap();
        next["eventId"] = json!("next");
        next["sequence"] = json!(19);
        let mut bytes = serde_json::to_vec(&next).unwrap();
        bytes.push(10);
        let split = bytes.len() - 12;
        root.append(&bytes[..split]);
        assert_eq!(root.page(Some(token), 100).unwrap()["items"], json!([]));
        root.append(&bytes[split..]);
        let result = root.page(Some(token), 100).unwrap();
        assert_eq!(result["items"][0]["eventId"], "next");
        assert_eq!(result["snapshotRevision"], "20");
    }
    #[test]
    fn forged_wrong_job_missing_key_and_replaced_journal_are_refused() {
        let root = Root::new();
        let first = root.page(None, 2).unwrap();
        let token = first["nextCursor"].as_str().unwrap();
        for value in [
            format!("{token}x"),
            format!("{token}="),
            "jec1.0".into(),
            "../journal.jsonl".into(),
        ] {
            assert_eq!(
                root.page(Some(&value), 100).unwrap_err().code,
                "invalidCursor"
            );
        }
        assert_eq!(
            page(&root.0, "another-job", "session-1", Some(token), 100)
                .unwrap_err()
                .code,
            "invalidCursor"
        );
        fs::rename(root.0.join("journal.jsonl"), root.0.join("old-journal")).unwrap();
        fs::write(root.0.join("journal.jsonl"), JOURNAL).unwrap();
        assert_eq!(
            root.page(Some(token), 100).unwrap_err().code,
            "recordUnreadable"
        );
        fs::remove_file(root.0.join("event-cursor-key.v1")).unwrap();
        assert_eq!(
            root.page(Some(token), 100).unwrap_err().code,
            "invalidCursor"
        );
        assert!(!root.0.join("event-cursor-key.v1").exists());
    }
    #[test]
    fn malformed_complete_tail_duplicate_sequence_and_link_replacement_fail_closed() {
        let root = Root::new();
        root.append(b"{broken}\n");
        assert_eq!(root.page(None, 100).unwrap_err().code, "recordUnreadable");
        let root = Root::new();
        root.append(JOURNAL.lines().last().unwrap().as_bytes());
        root.append(b"\n");
        assert_eq!(root.page(None, 100).unwrap_err().code, "recordUnreadable");
        let root = Root::new();
        let held = HostJournal::open(&root.0).unwrap();
        fs::rename(root.0.join(".manifest.lock"), root.0.join("old-lock")).unwrap();
        fs::write(root.0.join(".manifest.lock"), b"").unwrap();
        assert!(held.validate().is_err());
    }
}
