//! Replays every Job index the Swift oracle recorded under `rust/tests/fixtures`
//! through `job_index` on the platform's own SQLite, and requires the facts the
//! oracle recorded of it (schema text, `user_version`, journal mode and every
//! row, each record by its SHA-256) to read back equal once the owner is
//! closed: through a read-only connection, and again with the index reopened
//! for writing (TASK-XPA-005). The recorded order keys are replayed as
//! recorded; computing them is the Runtime timestamp owner's, not SQLite's.
use crate::job_index::{self, Admission, AdmissionVerdict, DATABASE, ROWS};
use arkdeck_platform::{HostSqlite, SqliteValue as Sql};
use serde_json::{Value, json};
use std::path::{Path, PathBuf};

fn fixtures() -> PathBuf {
    Path::new(env!("CARGO_MANIFEST_DIR")).join("../../tests/fixtures")
}

/// Every recorded Job index snapshot: an `index.json` with `userVersion`.
fn recorded(dir: &Path, found: &mut Vec<(PathBuf, Value)>) {
    let mut entries: Vec<_> = std::fs::read_dir(dir)
        .unwrap()
        .map(|entry| entry.unwrap().path())
        .collect();
    entries.sort();
    for path in entries {
        if path.is_dir() {
            recorded(&path, found);
        } else if path.file_name().is_some_and(|name| name == "index.json") {
            let Ok(value) = serde_json::from_slice::<Value>(&std::fs::read(&path).unwrap()) else {
                continue;
            };
            if value.get("userVersion").is_some() {
                found.push((path, value));
            }
        }
    }
}

/// The oracle's projection of the index (`tests/support::index`).
fn project(db: &mut HostSqlite) -> Value {
    let cell = |value: &Sql| match value {
        Sql::Null => Value::Null,
        Sql::Integer(n) => json!(n),
        Sql::Text(text) => json!(text),
        Sql::Blob(bytes) => json!(arkdeck_contract::sha256_hex(bytes)),
    };
    let mut query = |sql: &str| db.query(sql, &[], 64 << 20).unwrap();
    let schema: Vec<Value> =
        query("SELECT name, type, tbl_name, sql FROM sqlite_schema ORDER BY name")
            .iter()
            .map(|row| {
                json!({"name": cell(&row[0]), "type": cell(&row[1]), "tableName": cell(&row[2]),
                "sql": cell(&row[3])})
            })
            .collect();
    let rows: Vec<Value> = query(
        "SELECT job_id, idempotency_key, request_hash, state, admission_sequence, created_at_utc, created_at_order_key, updated_at_utc, version, initial_record_json FROM runtime_job ORDER BY admission_sequence",
    )
    .iter()
    .map(|row| {
        json!({"jobId": cell(&row[0]), "idempotencyKey": cell(&row[1]),
            "requestHash": cell(&row[2]), "state": cell(&row[3]),
            "admissionSequence": cell(&row[4]), "createdAtUTC": cell(&row[5]),
            "createdAtOrderKey": cell(&row[6]), "updatedAtUTC": cell(&row[7]),
            "version": cell(&row[8]), "recordSHA256": cell(&row[9])})
    })
    .collect();
    let version = cell(&query("PRAGMA user_version")[0][0]);
    let mode = cell(&query("PRAGMA journal_mode")[0][0]);
    json!({"userVersion": version, "journalMode": mode, "schema": schema, "rows": rows})
}

fn text<'a>(row: &'a Value, key: &str) -> &'a str {
    row[key].as_str().unwrap()
}

fn transaction<T>(db: &mut HostSqlite, body: impl FnOnce(&mut HostSqlite) -> T) -> T {
    db.execute("BEGIN IMMEDIATE", &[]).unwrap();
    let value = body(db);
    db.execute("COMMIT", &[]).unwrap();
    value
}

#[test]
fn recorded_swift_indexes_replay_on_the_linked_sqlite() {
    let mut found = Vec::new();
    recorded(&fixtures(), &mut found);
    // 153 recorded snapshots when this test was written; never vacuous.
    assert!(found.len() >= 150, "{} recorded indexes", found.len());
    let nonce = u128::from_ne_bytes(arkdeck_platform::random_bytes::<16>().unwrap());
    let scratch = std::env::temp_dir()
        .canonicalize()
        .unwrap()
        .join(format!("job-index-replay-{nonce:x}"));
    std::fs::create_dir(&scratch).unwrap();
    let (mut rows, mut with_record) = (0, 0);
    for (number, (path, oracle)) in found.iter().enumerate() {
        let label = path.strip_prefix(fixtures()).unwrap().display().to_string();
        let root = scratch.join(number.to_string());
        std::fs::create_dir(&root).unwrap();
        let database = root.join(DATABASE);
        let mut owner = HostSqlite::open(&database, false, true).unwrap();
        job_index::create(&mut owner).unwrap();
        job_index::current_layout(&mut owner).unwrap();
        job_index::owner_journal(&mut owner).unwrap();
        // The index facts; a snapshot may record more beside them.
        let mut expected = json!({
            "userVersion": oracle["userVersion"],
            "journalMode": oracle["journalMode"],
            "schema": oracle["schema"],
            "rows": oracle["rows"],
        });
        for (at, row) in oracle["rows"].as_array().unwrap().iter().enumerate() {
            rows += 1;
            let (id, key, hash) = (
                text(row, "jobId"),
                text(row, "idempotencyKey"),
                text(row, "requestHash"),
            );
            let (created, updated) = (text(row, "createdAtUTC"), text(row, "updatedAtUTC"));
            let version = row["version"].as_i64().unwrap();
            // The record the index holds is the Job's latest record file.
            let file = path
                .parent()
                .unwrap()
                .join("jobs")
                .join(id)
                .join("job-record.json");
            let record = match std::fs::read(&file) {
                Ok(bytes) if arkdeck_contract::sha256_hex(&bytes) == row["recordSHA256"] => {
                    with_record += 1;
                    bytes
                }
                _ => {
                    let placeholder = format!("{{\"jobId\":\"{id}\"}}").into_bytes();
                    expected["rows"][at]["recordSHA256"] =
                        json!(arkdeck_contract::sha256_hex(&placeholder));
                    placeholder
                }
            };
            // Admission indexes the creation time as the update time.
            assert!(version > 1 || created == updated, "{label} {id}");
            let job = Admission {
                id,
                idempotency_key: key,
                request_hash: hash,
                state: text(row, "state"),
                created,
                created_key: text(row, "createdAtOrderKey"),
                record: &record,
            };
            let verdict = transaction(&mut owner, |db| job_index::admit(db, &job).unwrap());
            assert_eq!(verdict, AdmissionVerdict::Admitted, "{label} {id}");
            for _ in 1..version {
                transaction(&mut owner, |db| {
                    job_index::update(db, id, key, created, text(row, "state"), updated, &record)
                        .unwrap()
                });
            }
            // The key now answers with its own Job, or a conflict.
            let again = transaction(&mut owner, |db| job_index::admit(db, &job).unwrap());
            assert_eq!(again, AdmissionVerdict::Duplicate(id.into()), "{label}");
            let other = Admission {
                request_hash: "other",
                ..job
            };
            let conflict = transaction(&mut owner, |db| job_index::admit(db, &other).unwrap());
            assert_eq!(conflict, AdmissionVerdict::Conflict, "{label}");
            // A record may only advance the row that indexes it.
            owner.execute("BEGIN IMMEDIATE", &[]).unwrap();
            assert!(job_index::update(&mut owner, id, key, "other", "s", updated, b"{}").is_err());
            owner.execute("ROLLBACK", &[]).unwrap();
        }
        assert_eq!(
            owner.query("PRAGMA synchronous", &[], 1024).unwrap(),
            [[Sql::Integer(2)]],
            "{label}"
        );
        // After the owner closes: a read-only connection, as the oracle's
        // own reader (`tests/support::index`) reads a closed store, then the
        // index reopened for writing, as after a restart.
        drop(owner);
        let mut reader = HostSqlite::open(&database, true, false).unwrap();
        job_index::current_layout(&mut reader).unwrap();
        assert_eq!(project(&mut reader), expected, "{label}");
        drop(reader);
        let mut reopened = HostSqlite::open(&database, false, false).unwrap();
        job_index::current_layout(&mut reopened).unwrap();
        assert_eq!(project(&mut reopened), expected, "{label}");
        // The Job list's order: creation order key, then identity bytes.
        let listed: Vec<String> = reopened
            .query(
                &format!("{ROWS} ORDER BY created_at_order_key, job_id COLLATE BINARY"),
                &[],
                64 << 20,
            )
            .unwrap()
            .into_iter()
            .map(|row| row[0].text().unwrap().to_owned())
            .collect();
        let mut order: Vec<(&str, &str)> = expected["rows"]
            .as_array()
            .unwrap()
            .iter()
            .map(|row| (text(row, "createdAtOrderKey"), text(row, "jobId")))
            .collect();
        order.sort_unstable();
        assert_eq!(
            listed,
            order.iter().map(|(_, id)| *id).collect::<Vec<_>>(),
            "{label}"
        );
        drop(reopened);
    }
    println!(
        "replayed {} recorded indexes, {rows} rows, {with_record} with their recorded record bytes",
        found.len()
    );
    // Nearly every recorded row carries its record file; keep it that way.
    assert!(with_record * 10 >= rows * 9, "{with_record}/{rows}");
    std::fs::remove_dir_all(scratch).unwrap();
}

/// A store whose layout is not v1 is refused, as Swift requireCurrentLayout
/// refuses it: a future `user_version`, a changed or an extra object.
#[test]
fn a_layout_that_is_not_v1_is_refused() {
    let nonce = u128::from_ne_bytes(arkdeck_platform::random_bytes::<16>().unwrap());
    let root = std::env::temp_dir()
        .canonicalize()
        .unwrap()
        .join(format!("job-index-layout-{nonce:x}"));
    std::fs::create_dir(&root).unwrap();
    let changes = [
        "PRAGMA user_version=2",
        "CREATE INDEX runtime_job_state_idx ON runtime_job(state)",
        "DROP INDEX runtime_job_updated_idx",
        "CREATE TABLE extra(v)",
    ];
    for (number, change) in changes.into_iter().enumerate() {
        let mut db =
            HostSqlite::open(&root.join(format!("{number}.sqlite3")), false, true).unwrap();
        job_index::create(&mut db).unwrap();
        job_index::current_layout(&mut db).unwrap();
        db.execute(change, &[]).unwrap();
        let error = job_index::current_layout(&mut db).unwrap_err();
        assert_eq!(error.kind(), std::io::ErrorKind::InvalidData, "{change}");
    }
    std::fs::remove_dir_all(root).unwrap();
}
