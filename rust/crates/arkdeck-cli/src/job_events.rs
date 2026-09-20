//! Validate a complete unary event page before emitting any data.
use crate::{
    CliError,
    read_only_resources::{date, invalid, keys, known_job_state},
};
use serde_json::{Map, Value, json};
use std::collections::BTreeSet;
const KINDS: &[&str] = &[
    "jobCreated",
    "stateTransition",
    "stepIntent",
    "stepOutcome",
    "compensationIntent",
    "compensationOutcome",
    "bindingCandidate",
    "bindingConfirmed",
    "bindingRejected",
    "serverGenerationChanged",
    "sleep",
    "wake",
    "reconcileStarted",
    "reconcileOutcome",
    "abandonIntent",
    "abandonOutcome",
    "warning",
    "error",
    "finalized",
];
/// `arkdeck.cli.event/1`, the one schema every streamed line carries.
const EVENT_SCHEMA: &str = "arkdeck.cli.event/1";

/// `job watch`'s own grammar, which Swift's handler judges rather than its
/// registry: the Job identity, the page size, the cursor and the bound.
pub(super) fn configure_watch(fields: &mut Map<String, Value>) -> Result<Option<u64>, CliError> {
    // The registry requires the option, so a caller who left it out hears the
    // registry's answer; what the value *means* is the handler's, as Swift
    // splits them (`invalidOption` 64 against `invalidInput` 65).
    let Some(job) = fields.get("jobId").and_then(Value::as_str) else {
        return Err(CliError::new("invalidOption", "job.watch requires --job"));
    };
    if !crate::read_only_resources::identifier(job) {
        return Err(CliError::new(
            "invalidInput",
            "an exact Job identity is required",
        ));
    }
    let timeout = fields.remove("timeout").map_or(Some(30_000), |value| {
        value
            .as_str()
            .and_then(crate::read_only_resources::duration)
    });
    let timeout = timeout
        .ok_or_else(|| CliError::new("invalidInput", "timeout must be a bounded duration"))?;
    configure(fields)?;
    Ok(Some(timeout))
}

pub(super) fn configure(fields: &mut Map<String, Value>) -> Result<(), CliError> {
    let size = fields
        .get("pageSize")
        .map_or(Some(100), |v| {
            v.as_str().and_then(|s| s.parse::<u64>().ok())
        })
        .filter(|n| (1..=1000).contains(n))
        .ok_or_else(|| CliError::new("invalidInput", "invalid event page size"))?;
    fields.insert("pageSize".into(), json!(size));
    if fields.get("afterCursor").is_some_and(|v| !cursor(v)) {
        return Err(CliError::new(
            "invalidCursor",
            "after-cursor must be a bounded opaque cursor",
        ));
    }
    Ok(())
}
fn decimal(value: &Value) -> Option<i64> {
    let text = value.as_str()?;
    let n = text.parse::<i64>().ok()?;
    (n >= 0 && n.to_string() == text).then_some(n)
}
fn cursor(value: &Value) -> bool {
    value
        .as_str()
        .is_some_and(|s| !s.is_empty() && s.len() <= 2048)
}
fn bounded(value: &Value, nonempty: bool) -> bool {
    value
        .as_str()
        .is_some_and(|s| (!nonempty || !s.is_empty()) && s.len() <= 512)
}
pub(super) fn validate(params: &Map<String, Value>, value: &Value) -> Result<(), CliError> {
    if !keys(
        value,
        &[
            "schemaVersion",
            "pageKind",
            "items",
            "order",
            "snapshotRevision",
            "hasMore",
            "nextCursor",
        ],
    ) || value["schemaVersion"] != "arkdeck.cli.page/1"
        || value["pageKind"] != "eventStream"
        || value["order"] != "streamPositionAsc"
        || !cursor(&value["nextCursor"])
    {
        return Err(invalid());
    }
    let revision = decimal(&value["snapshotRevision"]).ok_or_else(invalid)?;
    let items = value["items"].as_array().ok_or_else(invalid)?;
    let more = value["hasMore"].as_bool().ok_or_else(invalid)?;
    if items.len() as u64
        > params
            .get("pageSize")
            .and_then(Value::as_u64)
            .unwrap_or(100)
        || (more && items.is_empty())
    {
        return Err(invalid());
    }
    let mut previous = None;
    let mut ids = BTreeSet::new();
    for row in items {
        let position = decimal(&row["streamPosition"]).ok_or_else(invalid)?;
        if !keys(
            row,
            &[
                "eventId",
                "streamPosition",
                "runtimeRevision",
                "cursor",
                "type",
                "data",
            ],
        ) || !bounded(&row["eventId"], true)
            || !ids.insert(row["eventId"].as_str().unwrap())
            || position == 0
            || position > revision
            || previous.is_some_and(|p: i64| p.checked_add(1) != Some(position))
            || decimal(&row["runtimeRevision"]) != Some(revision)
            || !cursor(&row["cursor"])
        {
            return Err(invalid());
        }
        let data = &row["data"];
        let kind = data["journalKind"].as_str().ok_or_else(invalid)?;
        let mut expected = vec![
            "jobId",
            "sessionId",
            "journalKind",
            "timestamp",
            "stepId",
            "attempt",
            "bindingRevision",
        ];
        if kind == "stateTransition" {
            expected.extend(["fromState", "toState"]);
        }
        if !KINDS.contains(&kind)
            || row["type"]
                != (if kind == "stateTransition" {
                    "stateChanged"
                } else {
                    "journalEvent"
                })
            || !keys(data, &expected)
            || data["jobId"] != params["jobId"]
            || !bounded(&data["sessionId"], true)
            || !date(&data["timestamp"])
            || (!data["stepId"].is_null() && !bounded(&data["stepId"], false))
            || ["attempt", "bindingRevision"]
                .iter()
                .any(|k| !data[*k].is_null() && decimal(&data[*k]).is_none())
        {
            return Err(invalid());
        }
        if kind == "stateTransition"
            && ["fromState", "toState"]
                .iter()
                .any(|k| !data[*k].as_str().is_some_and(known_job_state))
        {
            return Err(invalid());
        }
        previous = Some(position);
    }
    if !more && previous.is_some_and(|p| p != revision) {
        return Err(invalid());
    }
    Ok(())
}

/// Swift `emitJobEventObservation`'s stream bookkeeping: which rows of a page
/// may be delivered, in order, and what a page may never do to the stream it
/// has already delivered.
///
/// Observation is not a replay: a page the Runtime serves again is recognised
/// by each row's stable identity and skipped, while a new identity at a
/// position the stream already passed, a gap, or a page that does not advance
/// the stream are all refused rather than papered over.
pub struct EventStream {
    job: String,
    size: u64,
    cursor: Option<String>,
    last_cursor: Option<String>,
    last_position: Option<i64>,
    last_revision: Option<i64>,
    /// The dedup window, oldest first, and each identity's position.
    recent: std::collections::VecDeque<String>,
    positions: Map<String, Value>,
    sequence: u64,
}

impl EventStream {
    pub fn new(params: &Map<String, Value>) -> Self {
        Self {
            job: params["jobId"].as_str().unwrap_or_default().to_owned(),
            size: params
                .get("pageSize")
                .and_then(Value::as_u64)
                .unwrap_or(100),
            cursor: params
                .get("afterCursor")
                .and_then(Value::as_str)
                .map(str::to_owned),
            last_cursor: None,
            last_position: None,
            last_revision: None,
            recent: std::collections::VecDeque::new(),
            positions: Map::new(),
            sequence: 1,
        }
    }

    /// The next page's request, which resumes after the last row delivered.
    pub fn request(&self) -> Map<String, Value> {
        let mut fields = Map::from_iter([
            ("jobId".to_owned(), json!(self.job)),
            ("pageSize".to_owned(), json!(self.size)),
        ]);
        if let Some(cursor) = &self.cursor {
            fields.insert("afterCursor".to_owned(), json!(cursor));
        }
        fields
    }

    /// The whole page, checked before any of it is delivered.
    pub fn page(&mut self, value: &Value) -> Result<(), CliError> {
        validate(&self.request(), value)?;
        let revision = decimal(&value["snapshotRevision"]).ok_or_else(invalid)?;
        if self.last_revision.is_some_and(|last| revision < last) {
            return Err(unreadable("event high-water revision moved backwards"));
        }
        Ok(())
    }

    /// One row of a checked page: the row to deliver, or nothing when the
    /// Runtime served an identity this stream already delivered.
    pub fn row(&mut self, row: &Value) -> Result<Option<Value>, CliError> {
        let position = decimal(&row["streamPosition"]).ok_or_else(invalid)?;
        let id = row["eventId"].as_str().unwrap_or_default().to_owned();
        if let Some(delivered) = self.positions.get(&id).and_then(Value::as_i64) {
            if delivered != position {
                return Err(unreadable("event identity was reused at a new position"));
            }
            return Ok(None);
        }
        if self
            .last_position
            .is_some_and(|last| last == i64::MAX || position != last + 1)
        {
            return Err(unreadable(
                "event history is not a contiguous exclusive stream",
            ));
        }
        if self.cursor.is_none() && self.last_position.is_none() && position != 1 {
            let mut error = CliError::new(
                "eventHistoryUnavailable",
                "the retained stream origin is unavailable",
            );
            error.details.insert(
                "earliestRetainedPosition".into(),
                json!(position.to_string()),
            );
            return Err(error);
        }
        self.last_position = Some(position);
        self.last_cursor = row["cursor"].as_str().map(str::to_owned);
        // Advance immediately after delivery, so an interruption or a failure
        // resumes from the last row delivered rather than from the end of a
        // page nobody saw.
        self.cursor.clone_from(&self.last_cursor);
        self.positions.insert(id.clone(), json!(position));
        self.recent.push_back(id);
        if self.recent.len() > 1000
            && let Some(oldest) = self.recent.pop_front()
        {
            self.positions.remove(&oldest);
        }
        Ok(Some(row.clone()))
    }

    /// The page is finished: it must have advanced the stream it delivered,
    /// and the next request resumes from the page's own cursor.
    pub fn finish(&mut self, value: &Value) -> Result<bool, CliError> {
        let revision = decimal(&value["snapshotRevision"]).ok_or_else(invalid)?;
        let rows = value["items"].as_array().cloned().unwrap_or_default();
        let last = rows.last().and_then(|row| decimal(&row["streamPosition"]));
        let advanced = if rows.is_empty() {
            (self.last_position.is_none() || Some(revision) == self.last_position)
                && (self.cursor.is_some() || revision == 0)
        } else {
            self.last_position == last
        };
        if !advanced {
            return Err(unreadable(
                "event page did not advance the delivered stream",
            ));
        }
        self.cursor = value["nextCursor"].as_str().map(str::to_owned);
        self.last_revision = Some(revision);
        Ok(value["hasMore"].as_bool().unwrap_or_default())
    }

    /// The cursor a caller could resume from, which is null until this call has
    /// delivered a Runtime event (CLI spec §8.3): a cursor is a resume point,
    /// and inventing one would say it can continue from somewhere it never was.
    pub fn last_cursor(&self) -> Option<&str> {
        self.last_cursor.as_deref()
    }

    pub fn cursor(&self) -> Option<&str> {
        self.cursor.as_deref()
    }

    /// The next line's sequence number, which counts every line this call
    /// writes, the terminal one included.
    pub fn take_sequence(&mut self) -> u64 {
        let sequence = self.sequence;
        self.sequence += 1;
        sequence
    }

    pub fn sequence(&self) -> u64 {
        self.sequence
    }

    pub fn job(&self) -> &str {
        &self.job
    }
}

fn unreadable(message: &str) -> CliError {
    CliError::new("recordUnreadable", message)
}

/// One delivered Runtime event, as `arkdeck.cli.event/1`: the row's own fields,
/// and the stream's.
pub fn event_line(command: &str, sequence: u64, row: &Value, id: &str) -> Value {
    let mut value = row.as_object().cloned().unwrap_or_default();
    value.insert("schemaVersion".into(), json!(EVENT_SCHEMA));
    value.insert("command".into(), json!(command));
    value.insert("controlRequestId".into(), json!(id));
    value.insert("sequence".into(), json!(sequence));
    Value::Object(value)
}

/// The one terminal line every stream ends with, whichever way it ended.
pub fn terminal_line(
    command: &str,
    sequence: u64,
    id: &str,
    last_cursor: Option<&str>,
    outcome: Result<&Value, &CliError>,
) -> Value {
    let mut value = Map::from_iter([
        ("schemaVersion".to_owned(), json!(EVENT_SCHEMA)),
        ("sequence".to_owned(), json!(sequence)),
        ("type".to_owned(), json!("terminal")),
        ("command".to_owned(), json!(command)),
        ("controlRequestId".to_owned(), json!(id)),
        (
            "lastCursor".to_owned(),
            last_cursor.map_or(Value::Null, |cursor| json!(cursor)),
        ),
    ]);
    match outcome {
        Ok(result) => {
            value.insert("ok".to_owned(), json!(true));
            value.insert("exitCode".to_owned(), json!(0));
            value.insert("result".to_owned(), result.clone());
        }
        Err(error) => {
            value.insert("ok".to_owned(), json!(false));
            value.insert("exitCode".to_owned(), json!(error.exit_code()));
            let mut fields = Map::from_iter([
                ("code".to_owned(), json!(error.code)),
                ("message".to_owned(), json!(error.message)),
                (
                    "controlRequestRetryable".to_owned(),
                    json!(matches!(
                        error.code,
                        "clientTimeout" | "resultNotReady" | "runtimeUnavailable"
                    )),
                ),
                (
                    "attentionRequired".to_owned(),
                    json!(matches!(error.exit_code(), 2 | 75 | 77)),
                ),
            ]);
            if !error.details.is_empty() {
                fields.insert("details".to_owned(), json!(error.details));
            }
            value.insert("error".to_owned(), Value::Object(fields));
        }
    }
    Value::Object(value)
}

#[cfg(test)]
mod stream_tests {
    use super::*;

    fn row(position: i64, revision: i64, id: &str) -> Value {
        json!({"eventId":id,"streamPosition":position.to_string(),
            "runtimeRevision":revision.to_string(),"cursor":format!("cursor-{id}"),
            "type":"journalEvent",
            "data":{"jobId":"job-a","sessionId":"session-a","journalKind":"sleep",
                "timestamp":"2026-09-20T00:00:00.000Z","stepId":null,"attempt":null,
                "bindingRevision":null}})
    }

    fn page(rows: Vec<Value>, revision: i64, more: bool, next: &str) -> Value {
        json!({"schemaVersion":"arkdeck.cli.page/1","pageKind":"eventStream",
            "order":"streamPositionAsc","items":rows,"snapshotRevision":revision.to_string(),
            "hasMore":more,"nextCursor":next})
    }

    fn follower() -> EventStream {
        EventStream::new(&Map::from_iter([
            ("jobId".to_owned(), json!("job-a")),
            ("pageSize".to_owned(), json!(100)),
        ]))
    }

    /// Every row of a page, in order, as the leaf delivers them.
    fn deliver(stream: &mut EventStream, page: &Value) -> Result<Vec<Value>, CliError> {
        stream.page(page)?;
        let mut delivered = Vec::new();
        for row in page["items"].as_array().cloned().unwrap_or_default() {
            if let Some(row) = stream.row(&row)? {
                delivered.push(row);
            }
        }
        stream.finish(page)?;
        Ok(delivered)
    }

    #[test]
    fn the_request_resumes_from_the_cursor_the_last_page_ended_with() {
        let mut stream = follower();
        assert_eq!(
            Value::Object(stream.request()),
            json!({"jobId":"job-a","pageSize":100})
        );
        let first = page(vec![row(1, 2, "e1"), row(2, 2, "e2")], 2, false, "page-a");
        assert_eq!(deliver(&mut stream, &first).unwrap().len(), 2);
        assert_eq!(
            Value::Object(stream.request()),
            json!({"jobId":"job-a","pageSize":100,"afterCursor":"page-a"})
        );
        // A row's own cursor is what a caller could resume from, and it is the
        // one the terminal line names.
        assert_eq!(stream.last_cursor(), Some("cursor-e2"));
        assert_eq!(stream.cursor(), Some("page-a"));
        // The same page again delivers nothing and still advances.
        let again = page(vec![row(2, 2, "e2")], 2, false, "page-b");
        assert!(deliver(&mut stream, &again).unwrap().is_empty());
        assert_eq!(stream.cursor(), Some("page-b"));
    }

    /// A stream resumed from a cursor the caller was given: its origin was
    /// proved by whoever issued that cursor.
    fn resumed() -> EventStream {
        EventStream::new(&Map::from_iter([
            ("jobId".to_owned(), json!("job-a")),
            ("pageSize".to_owned(), json!(100)),
            ("afterCursor".to_owned(), json!("given")),
        ]))
    }

    #[test]
    fn a_stream_that_cannot_be_followed_is_refused_rather_than_papered_over() {
        // A first page that does not start at the origin: the caller asked for
        // everything, and everything is no longer retained.
        let mut stream = follower();
        let error = deliver(
            &mut stream,
            &page(vec![row(3, 3, "e3")], 3, false, "page-a"),
        )
        .unwrap_err();
        assert_eq!(
            (error.code, error.message.as_str()),
            (
                "eventHistoryUnavailable",
                "the retained stream origin is unavailable"
            )
        );
        assert_eq!(error.details["earliestRetainedPosition"], json!("3"));
        assert_eq!(error.exit_code(), 75);

        // A gap after a delivered row is not a new origin but a broken stream.
        let mut stream = follower();
        deliver(
            &mut stream,
            &page(vec![row(1, 1, "e1")], 1, false, "page-a"),
        )
        .unwrap();
        let error = deliver(
            &mut stream,
            &page(vec![row(3, 3, "e3")], 3, false, "page-b"),
        )
        .unwrap_err();
        assert_eq!(
            (error.code, error.message.as_str()),
            (
                "recordUnreadable",
                "event history is not a contiguous exclusive stream"
            )
        );

        // The same identity at a new position is a reuse, not a replay.
        let mut stream = follower();
        deliver(
            &mut stream,
            &page(vec![row(1, 1, "e1")], 1, false, "page-a"),
        )
        .unwrap();
        let error = deliver(
            &mut stream,
            &page(vec![row(2, 2, "e1")], 2, false, "page-b"),
        )
        .unwrap_err();
        assert_eq!(
            (error.code, error.message.as_str()),
            (
                "recordUnreadable",
                "event identity was reused at a new position"
            )
        );

        // A revision that moved backwards is refused before any of its rows.
        let mut stream = resumed();
        deliver(
            &mut stream,
            &page(vec![row(5, 5, "e5")], 5, false, "page-a"),
        )
        .unwrap();
        let error = deliver(
            &mut stream,
            &page(vec![row(2, 2, "e2")], 2, false, "page-b"),
        )
        .unwrap_err();
        assert_eq!(
            (error.code, error.message.as_str()),
            (
                "recordUnreadable",
                "event high-water revision moved backwards"
            )
        );

        // An empty page that claims a revision the delivered stream never
        // reached leaves events undelivered behind it.
        let mut stream = follower();
        deliver(
            &mut stream,
            &page(vec![row(1, 1, "e1")], 1, false, "page-a"),
        )
        .unwrap();
        let error = deliver(&mut stream, &page(Vec::new(), 3, false, "page-b")).unwrap_err();
        assert_eq!(
            (error.code, error.message.as_str()),
            (
                "recordUnreadable",
                "event page did not advance the delivered stream"
            )
        );
    }

    #[test]
    fn every_line_carries_the_stream_it_belongs_to() {
        let mut stream = follower();
        let delivered = deliver(
            &mut stream,
            &page(vec![row(1, 1, "e1")], 1, false, "page-a"),
        )
        .unwrap();
        let line = event_line("job.watch", stream.take_sequence(), &delivered[0], "ctl-a");
        assert_eq!(line["schemaVersion"], "arkdeck.cli.event/1");
        assert_eq!(line["command"], "job.watch");
        assert_eq!(line["controlRequestId"], "ctl-a");
        assert_eq!(line["sequence"], json!(1));
        // The row's own fields are the line's, `type` included: a delivered
        // event says what it is, never `terminal`.
        assert_eq!(line["eventId"], "e1");
        assert_eq!(line["type"], "journalEvent");
        let failure = CliError::new("clientTimeout", "stopped");
        let terminal = terminal_line(
            "job.watch",
            stream.take_sequence(),
            "ctl-a",
            stream.last_cursor(),
            Err(&failure),
        );
        assert_eq!(
            terminal,
            json!({"schemaVersion":"arkdeck.cli.event/1","sequence":2,"type":"terminal",
                "command":"job.watch","controlRequestId":"ctl-a","lastCursor":"cursor-e1",
                "ok":false,"exitCode":75,
                "error":{"code":"clientTimeout","message":"stopped","controlRequestRetryable":true,
                    "attentionRequired":true}})
        );
        // Nothing delivered, nothing to resume from.
        let quiet = follower();
        let terminal = terminal_line("job.watch", 1, "ctl-a", quiet.last_cursor(), Err(&failure));
        assert_eq!(terminal["lastCursor"], Value::Null);
        let done = json!({"state":"succeeded"});
        let terminal = terminal_line("job.wait", 3, "ctl-a", Some("cursor-e1"), Ok(&done));
        assert_eq!(terminal["ok"], true);
        assert_eq!(terminal["exitCode"], 0);
        assert_eq!(terminal["result"], done);
    }
}
