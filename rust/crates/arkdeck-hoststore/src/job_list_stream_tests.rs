//! The Job list handing each history row to its snapshot as the repository
//! reads it, newest first straight from SQLite (TASK-XPA-025), against the
//! list that collected every row, sorted them and handed them over at once:
//! the same pages, the same stored snapshots and the same refusals.
use super::*;
use arkdeck_platform::{HostSqlite, SqliteValue};
use std::os::unix::fs::DirBuilderExt;

struct Root(PathBuf);
impl Root {
    fn new() -> Self {
        let path = std::env::temp_dir().canonicalize().unwrap().join(format!(
            "arkdeck-job-list-stream-{:032x}",
            u128::from_ne_bytes(arkdeck_platform::random_bytes::<16>().unwrap())
        ));
        std::fs::DirBuilder::new()
            .mode(0o700)
            .create(&path)
            .unwrap();
        Self(path)
    }

    /// One Job row as Swift's repository stores it.
    fn seed(&self, id: &str, state: &str, created: &str, sequence: i64, target: &str) {
        let record = json!({"jobID":id, "request":{"documentType":"runtime-operation-request",
            "schemaVersion":"1.0.0", "requestId":format!("req-{id}"), "idempotencyKey":format!("idem-{id}"),
            "target":{"targetId":target, "expectedBindingRevision":1},
            "operation":{"id":"observe.device", "version":1}, "inputs":{}, "requestedOutputs":["derivedArtifacts"]},
            "operationReference":"observe.device@1", "catalogDigest":arkdeck_contract::CATALOG_DIGEST,
            "providerID":"hdc", "createdAtUTC":created, "actualEffect":"readOnly",
            "materializedPlanDigest":"a".repeat(64), "materializedBindingRevision":1, "state":state,
            "outcomeUnknown":state == "waitingForRecovery", "timeline":["created", format!("{state} {id}")],
            "actualStepKinds":[], "skipReasons":{}});
        self.insert(
            id,
            state,
            created,
            sequence,
            serde_json::to_vec(&record).unwrap(),
        );
    }

    fn insert(&self, id: &str, state: &str, created: &str, sequence: i64, record: Vec<u8>) {
        self.database()
            .execute(
                "INSERT INTO runtime_job VALUES(?, ?, ?, ?, ?, ?, ?, ?, ?, ?)",
                &[
                    SqliteValue::Text(id.into()),
                    SqliteValue::Text(format!("idem-{id}")),
                    SqliteValue::Text("b".repeat(64)),
                    SqliteValue::Text(state.into()),
                    SqliteValue::Integer(sequence),
                    SqliteValue::Text(created.into()),
                    SqliteValue::Text(order_key(created).unwrap()),
                    SqliteValue::Text(created.into()),
                    SqliteValue::Integer(1),
                    SqliteValue::Blob(record),
                ],
            )
            .unwrap();
    }
}
impl Drop for Root {
    fn drop(&mut self) {
        let _ = std::fs::remove_dir_all(&self.0);
    }
}
impl Root {
    fn database(&self) -> HostSqlite {
        HostSqlite::open(&self.0.join("runtime-jobs.sqlite3"), false, false).unwrap()
    }

    /// `count` Jobs, one created each second, in one transaction.
    fn seed_many(&self, count: usize) {
        let mut database = self.database();
        database.execute("BEGIN", &[]).unwrap();
        for index in 0..count {
            let id = format!("job-{index:05}");
            let created = format!(
                "2026-08-31T{:02}:{:02}:{:02}Z",
                index / 3600,
                index / 60 % 60,
                index % 60
            );
            let record = json!({"jobID":id, "request":{"documentType":"runtime-operation-request",
                "schemaVersion":"1.0.0", "requestId":format!("req-{id}"), "idempotencyKey":format!("idem-{id}"),
                "target":{"targetId":"TGT-a", "expectedBindingRevision":1},
                "operation":{"id":"observe.device", "version":1}, "inputs":{}, "requestedOutputs":["derivedArtifacts"]},
                "operationReference":"observe.device@1", "catalogDigest":arkdeck_contract::CATALOG_DIGEST,
                "providerID":"hdc", "createdAtUTC":created, "actualEffect":"readOnly",
                "materializedPlanDigest":"a".repeat(64), "materializedBindingRevision":1, "state":"succeeded",
                "outcomeUnknown":false, "timeline":["created", "completed"], "actualStepKinds":[], "skipReasons":{}});
            database
                .execute(
                    "INSERT INTO runtime_job VALUES(?, ?, ?, ?, ?, ?, ?, ?, ?, ?)",
                    &[
                        SqliteValue::Text(id.clone()),
                        SqliteValue::Text(format!("idem-{id}")),
                        SqliteValue::Text("b".repeat(64)),
                        SqliteValue::Text("succeeded".into()),
                        SqliteValue::Integer(index as i64 + 1),
                        SqliteValue::Text(created.clone()),
                        SqliteValue::Text(order_key(&created).unwrap()),
                        SqliteValue::Text(created),
                        SqliteValue::Integer(1),
                        SqliteValue::Blob(serde_json::to_vec(&record).unwrap()),
                    ],
                )
                .unwrap();
        }
        database.execute("COMMIT", &[]).unwrap();
    }
}

/// The Job list as it was before TASK-XPA-025, verbatim but for its option
/// checks, which the list under test makes first: every projected row
/// collected in creation order, sorted and handed over at once.
fn whole_list(store: &JobStore, params: &Map<String, Value>) -> Result<Value, WireError> {
    let flag = |key| params.get(key).and_then(Value::as_bool).unwrap_or(false);
    let timeline = flag("includeTimeline");
    let current = flag("includeCurrent");
    let order = params
        .get("order")
        .and_then(Value::as_str)
        .unwrap_or("createdAtDescJobIdAsc");
    let mut filters = json!({"includeCurrent":current, "includeTimeline":timeline});
    for key in ["state", "operation", "target", "thread"] {
        if let Some(value) = params.get(key) {
            filters[key] = value.clone();
        }
    }
    let (size, cursor) = pagination(params, MALFORMED_SNAPSHOT_CURSOR)?;
    SnapshotPager::open(&store.path.join("cli-job-snapshots"))
        .map_err(unreadable)?
        .page_filtered("job.list", &filters, order, size, cursor, || {
            let projected = store
                .repository
                .map_rows(None, |row| {
                    Ok((|| -> Result<_, WireError> {
                        let record = JobRecord::from_row(&row)?;
                        let value = record.history(timeline);
                        if [
                            ("state", "state"),
                            ("operation", "operation"),
                            ("target", "targetId"),
                            ("thread", "threadId"),
                        ]
                        .iter()
                        .any(|(filter, field)| {
                            filters
                                .get(*filter)
                                .is_some_and(|expected| expected != &value[*field])
                        }) {
                            return Ok(None);
                        }
                        Ok(Some((row.order_key, row.id, value)))
                    })())
                })
                .map_err(unreadable)?;
            let mut rows = projected
                .into_iter()
                .collect::<Result<Vec<_>, _>>()?
                .into_iter()
                .flatten()
                .collect::<Vec<_>>();
            rows.sort_by(|a, b| {
                (if order == "createdAtDescJobIdAsc" {
                    b.0.cmp(&a.0)
                } else {
                    a.0.cmp(&b.0)
                })
                .then(a.1.cmp(&b.1))
            });
            Ok(rows.into_iter().map(|(_, _, value)| value).collect())
        })
        .map_err(pager_refusal)
}

/// Every page of one list, from its first page through its cursors, each
/// with the stored snapshot it came from.
fn walk(
    store: &JobStore,
    params: &Value,
    list: impl Fn(&JobStore, &Map<String, Value>) -> Result<Value, WireError>,
) -> Result<(Vec<Value>, Vec<u8>), String> {
    let refusal = |error: WireError| serde_json::to_string(&error).unwrap();
    let mut params = params.as_object().unwrap().clone();
    let mut pages = vec![list(store, &params).map_err(refusal)?];
    let revision = pages[0]["snapshotRevision"].as_str().unwrap().to_owned();
    while let Some(cursor) = pages.last().unwrap()["nextCursor"].as_str() {
        params.insert("cursor".into(), json!(cursor));
        pages.push(list(store, &params).map_err(refusal)?);
    }
    let stored = std::fs::read(
        store
            .path
            .join("cli-job-snapshots")
            .join(format!("snapshot-{revision}.json")),
    )
    .unwrap();
    Ok((pages, stored))
}

/// Replace one list's random snapshot revision and page tokens with
/// another's, everywhere they appear.
fn renamed(text: &str, from: &Value, to: &Value) -> String {
    let tokens = |document: &Value| -> Vec<String> {
        serde_json::from_value(document["tokens"].clone()).unwrap()
    };
    let mut text = text.replace(
        from["revision"].as_str().unwrap(),
        to["revision"].as_str().unwrap(),
    );
    for (old, new) in tokens(from).iter().zip(tokens(to)) {
        let (old, new) = (
            old.rsplit('.').next().unwrap(),
            new.rsplit('.').next().unwrap(),
        );
        text = text.replace(old, new);
    }
    text
}

fn same_lists(store: &JobStore, params: Value, answered: bool) {
    let streamed = walk(store, &params, |store, params| {
        store.handle_resource("job.list", params)
    });
    let whole = walk(store, &params, whole_list);
    assert_eq!(whole.is_ok(), answered, "{params}: the case");
    match (streamed, whole) {
        (Ok((pages, stored)), Ok((whole_pages, whole_stored))) => {
            let document: Value = serde_json::from_slice(&stored).unwrap();
            let whole_document: Value = serde_json::from_slice(&whole_stored).unwrap();
            assert_eq!(
                renamed(
                    std::str::from_utf8(&whole_stored).unwrap(),
                    &whole_document,
                    &document
                ),
                std::str::from_utf8(&stored).unwrap(),
                "{params}: the stored snapshot"
            );
            assert_eq!(pages.len(), whole_pages.len(), "{params}: pages");
            for (page, whole_page) in pages.iter().zip(&whole_pages) {
                assert_eq!(
                    renamed(
                        &serde_json::to_string(whole_page).unwrap(),
                        &whole_document,
                        &document
                    ),
                    serde_json::to_string(page).unwrap(),
                    "{params}: a page"
                );
            }
        }
        (streamed, whole) => assert_eq!(
            streamed.map(|_| ()),
            whole.map(|_| ()),
            "{params}: the refusal"
        ),
    }
}

#[test]
fn a_streamed_list_is_the_list_that_collected_every_row() {
    let root = Root::new();
    drop(JobStore::open(&root.0).unwrap());
    // Jobs created in a handful of seconds, several in each, their identities
    // out of creation order, so that both orders and the identity tiebreak
    // decide pages.
    let states = [
        "succeeded",
        "cancelled",
        "failed",
        "queued",
        "waitingForRecovery",
    ];
    for index in 0..60_usize {
        let id = format!("job-{:02}", (index * 37) % 60);
        let created = format!("2026-08-31T12:00:{:02}Z", (index * 7) % 9);
        root.seed(
            &id,
            states[index % states.len()],
            &created,
            index as i64 + 1,
            ["TGT-a", "TGT-b", "TGT-c"][index % 3],
        );
    }
    let store = JobStore::open(&root.0).unwrap();
    for params in [
        json!({}),
        json!({"pageSize":7}),
        json!({"pageSize":7, "order":"createdAtAscJobIdAsc"}),
        json!({"pageSize":1, "order":"createdAtDescJobIdAsc"}),
        json!({"pageSize":5, "state":"succeeded"}),
        json!({"pageSize":3, "target":"TGT-b", "order":"createdAtAscJobIdAsc"}),
        json!({"pageSize":4, "includeTimeline":true}),
        json!({"pageSize":9, "includeCurrent":true}),
        json!({"operation":"observe.device@1"}),
        json!({"thread":"a-thread-no-Job-has"}),
        json!({"pageSize":1000}),
    ] {
        same_lists(&store, params, true);
    }
    drop(store);

    // A record the list cannot read refuses the whole list, in either order
    // and whether or not a filter would keep its row.
    root.insert(
        "job-bad",
        "succeeded",
        "2026-08-31T12:00:04Z",
        1000,
        b"{\"jobID\":\"another\"}".to_vec(),
    );
    let store = JobStore::open(&root.0).unwrap();
    for params in [
        json!({}),
        json!({"order":"createdAtAscJobIdAsc"}),
        json!({"pageSize":2, "state":"queued"}),
    ] {
        same_lists(&store, params, false);
    }
}

#[test]
fn a_new_job_list_holds_each_row_encoded_and_not_as_a_value() {
    // The most one first page holds, and the size of the snapshot it stores.
    let held = |count: usize| {
        let root = Root::new();
        drop(JobStore::open(&root.0).unwrap());
        root.seed_many(count);
        let store = JobStore::open(&root.0).unwrap();
        let params = Map::from_iter([("pageSize".into(), json!(10))]);
        let (answer, held) =
            arkdeck_platform::peak_allocation(|| store.handle_resource("job.list", &params));
        let answer = answer.unwrap();
        assert_eq!(answer["items"].as_array().map(Vec::len), Some(10));
        let revision = answer["snapshotRevision"].as_str().unwrap();
        let stored = std::fs::metadata(
            root.0
                .join("cli-job-snapshots")
                .join(format!("snapshot-{revision}.json")),
        )
        .unwrap()
        .len() as usize;
        (held, stored)
    };
    let ((small, small_stored), (large, large_stored)) = (held(200), held(800));
    let (rows, encoded) = (large - small, large_stored - small_stored);
    eprintln!(
        "600 more Jobs: a first page held {rows} more bytes at most, and stored {encoded} more"
    );
    // Holding every history row as a value costs several times its encoding;
    // the stored document itself, grown by doubling, less than twice.
    assert!(
        rows < 2 * encoded,
        "600 more Jobs made a first page hold {rows} more bytes for {encoded} more stored"
    );
}

/// The error Swift's Job read handler answered in the ControlFrames corpus,
/// at `line` of `method`'s recording.
fn recorded_error(method: &str, line: usize) -> Value {
    let path = std::path::Path::new(env!("CARGO_MANIFEST_DIR")).join(format!(
        "../../../Packages/ArkDeckKit/Tests/ArkDeckContractTests/Fixtures/ControlFrames/{method}.jsonl"
    ));
    let text = std::fs::read_to_string(path).unwrap();
    let frame: Value = serde_json::from_str(text.lines().nth(line - 1).unwrap()).unwrap();
    frame["error"].clone()
}

fn answered_error(result: Result<Value, WireError>) -> Value {
    let error = result.unwrap_err();
    json!({"code": error.code, "message": error.message, "details": error.details})
}

/// A cursor the Job reads refuse is refused in Swift's words and with its
/// handler's pre-admission proof: a cursor that is not a bounded string
/// (`RuntimeJobListQuery`), one not shaped as the pager's token, one of
/// another query, and a page size out of range.
#[test]
fn the_job_reads_refuse_a_cursor_as_swifts_handler_does() {
    let root = Root::new();
    drop(JobStore::open(&root.0).unwrap());
    for index in 0..3_i64 {
        root.seed(
            &format!("job-{index}"),
            "succeeded",
            "2026-08-31T12:00:00Z",
            index + 1,
            "TGT-a",
        );
    }
    let store = JobStore::open(&root.0).unwrap();
    let list = |params: Value| store.handle_resource("job.list", params.as_object().unwrap());
    let cursor = list(json!({"pageSize": 1})).unwrap()["nextCursor"]
        .as_str()
        .unwrap()
        .to_owned();
    for (params, method, line) in [
        (json!({"cursor": ""}), "job.list", 3),
        (json!({"pageSize": 0}), "job.list", 13),
        (json!({"cursor": "not-a-snapshot-token"}), "job.list", 54),
        // The same cursor for another query of the list.
        (json!({"cursor": cursor, "state": "failed"}), "job.list", 27),
    ] {
        assert_eq!(
            answered_error(list(params.clone())),
            recorded_error(method, line),
            "{params}"
        );
    }
    let timeline =
        |params: Value| store.handle_resource("job.timeline", params.as_object().unwrap());
    for (params, line) in [
        (json!({"jobId": "job-0", "cursor": ""}), 12),
        (
            json!({"jobId": "job-0", "cursor": "not-a-snapshot-token"}),
            13,
        ),
        // A list's cursor is another query's.
        (json!({"jobId": "job-0", "cursor": cursor}), 9),
    ] {
        assert_eq!(
            answered_error(timeline(params.clone())),
            recorded_error("job.timeline", line),
            "{params}"
        );
    }
}
