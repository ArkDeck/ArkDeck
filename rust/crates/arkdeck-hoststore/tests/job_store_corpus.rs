//! GJ-1 hop for the Job store owner on this host's durable store (NTFS on
//! Windows), with the recorded Swift Job stores under `rust/tests/fixtures`
//! as the oracle:
//!
//! * every recorded `job-record.json` the Rust record reader decodes is
//!   re-encoded to its exact bytes (T0);
//! * every recorded Job index (`index.json` holding `userVersion`) whose rows
//!   all carry their record is admitted and advanced again, row by row in
//!   admission order, through `JobStore::open_owner`, and the index read back
//!   after the owner is dropped equals the recorded projection — schema,
//!   `user_version`, journal mode and every row, the order key computed by
//!   the Rust owner (T1); every `job-record.json` the owner published is the
//!   recorded bytes (T0);
//! * where the fixture also records Swift's answers to the Job reads
//!   (`reads.json`), the store reopened as a reader (a restart), with the
//!   recorded Journals beside the records, answers `job.status`, `job.show`
//!   and `job.events` exactly as Swift answered.
#![cfg(any(target_os = "macos", windows))]

mod journal_scratch;

use arkdeck_hoststore::{AdmissionVerdict, JobRecord, JobStore};
use arkdeck_platform::{HostSqlite, SqliteValue as Sql};
use journal_scratch::{Root, fixtures, private_directories, write_private_file};
use serde_json::{Map, Value, json};

use std::fs;
use std::path::{Path, PathBuf};

/// Every recorded Job index snapshot, by the directory that holds it.
fn recorded_indexes() -> Vec<(PathBuf, Value)> {
    let (mut found, mut pending) = (Vec::new(), vec![fixtures()]);
    while let Some(directory) = pending.pop() {
        for entry in fs::read_dir(&directory).unwrap() {
            let path = entry.unwrap().path();
            if path.is_dir() {
                pending.push(path);
            } else if path.file_name().is_some_and(|name| name == "index.json")
                && let Ok(value) = serde_json::from_slice::<Value>(&fs::read(&path).unwrap())
                && value.get("userVersion").is_some()
            {
                found.push((directory.clone(), value));
            }
        }
    }
    found.sort_by(|a, b| a.0.cmp(&b.0));
    found
}

/// The projection the Swift oracle records of a Job index (the
/// `tests/support::index` projection), read through a connection that only
/// reads after the owner has closed.
fn index(path: &Path) -> Value {
    let mut db = HostSqlite::open(&path.join("runtime-jobs.sqlite3"), false, false).unwrap();
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

/// A Job read answered as the oracle records it.
fn answer(outcome: Result<Value, arkdeck_contract::WireError>) -> Value {
    match outcome {
        Ok(result) => json!({"ok": true, "result": result}),
        Err(error) => {
            let mut body = json!({"code": error.code, "message": error.message});
            if let Some(details) = error.details {
                body["details"] = Value::Object(details);
            }
            json!({"ok": false, "error": body})
        }
    }
}

/// The reads this build answers on this host from the Job store alone.
const READS: [&str; 3] = ["job.status", "job.show", "job.events"];

/// Reads Swift answered from a resident record ahead of the durable one (the
/// Job whose `job.reconcile` failed after its Journal moved; `job_reconcile.rs`
/// reads it in memory), which a restarted reader of the store cannot see.
const RESIDENT: [(&str, &str); 1] = [(
    "job-reconcile-analyzer",
    "job-a3b9503ec0f740f04133c0c85be778b3",
)];

#[test]
fn recorded_job_records_reencode_to_their_exact_bytes() {
    let (mut decoded, mut refused, mut pending) = (0, Vec::new(), vec![fixtures()]);
    while let Some(directory) = pending.pop() {
        for entry in fs::read_dir(&directory).unwrap() {
            let path = entry.unwrap().path();
            if path.is_dir() {
                pending.push(path);
            } else if path
                .file_name()
                .is_some_and(|name| name == "job-record.json")
            {
                let bytes = fs::read(&path).unwrap();
                match JobRecord::decode(&bytes) {
                    Ok(record) => {
                        assert_eq!(record.durable_bytes().unwrap(), bytes, "{}", path.display());
                        decoded += 1;
                    }
                    Err(error) => refused.push(format!("{}: {}", path.display(), error.code)),
                }
            }
        }
    }
    eprintln!(
        "job-record.json: {decoded} re-encoded to their bytes; {} refused by the reader",
        refused.len()
    );
    for line in &refused {
        eprintln!("  refused {line}");
    }
    assert!(decoded >= 400, "{decoded}");
}

#[test]
fn recorded_job_indexes_are_rebuilt_by_the_owner_and_read_back_after_a_restart() {
    let indexes = recorded_indexes();
    let (mut rebuilt, mut rows_rebuilt, mut incomplete) = (0, 0, 0);
    let mut reads_compared = std::collections::BTreeMap::<String, usize>::new();
    let mut differences = Vec::new();
    for (at, (directory, recorded)) in indexes.iter().enumerate() {
        let rows = recorded["rows"].as_array().unwrap();
        // Every row's record as recorded, or the store is not rebuilt.
        let records: Option<Vec<(Vec<u8>, JobRecord)>> = rows
            .iter()
            .map(|row| {
                let bytes = fs::read(
                    directory
                        .join("jobs")
                        .join(text(row, "jobId"))
                        .join("job-record.json"),
                )
                .ok()?;
                (arkdeck_contract::sha256_hex(&bytes) == text(row, "recordSHA256")).then_some(())?;
                let record = JobRecord::decode(&bytes).ok()?;
                Some((bytes, record))
            })
            .collect();
        let Some(records) = records else {
            incomplete += 1;
            continue;
        };
        let root = Root::new(&format!("job-store-{at}"));
        let store = JobStore::open_owner(&root.0).unwrap();
        let mut order: Vec<usize> = (0..rows.len()).collect();
        order.sort_by_key(|&n| rows[n]["admissionSequence"].as_i64().unwrap());
        for n in order {
            let (row, (_, record)) = (&rows[n], &records[n]);
            assert_eq!(
                store.admit(record, text(row, "requestHash")).unwrap(),
                AdmissionVerdict::Admitted,
                "{} {}",
                directory.display(),
                record.job_id
            );
            for _ in 1..row["version"].as_i64().unwrap() {
                store.persist(record, text(row, "updatedAtUTC")).unwrap();
            }
        }
        drop(store);
        let mut expected = recorded.clone();
        expected.as_object_mut().unwrap().remove("jobRecords");
        let actual = index(&root.0);
        if actual != expected {
            differences.push(format!(
                "{}:\n  swift {expected}\n  rust  {actual}",
                directory.display()
            ));
            continue;
        }
        for (row, (bytes, _)) in rows.iter().zip(&records) {
            let file = root
                .0
                .join("jobs")
                .join(text(row, "jobId"))
                .join("job-record.json");
            if row["version"].as_i64().unwrap() > 1 {
                assert_eq!(&fs::read(&file).unwrap(), bytes, "{}", file.display());
            }
        }
        rebuilt += 1;
        rows_rebuilt += rows.len();

        // The recorded Swift answers to the Job reads over this store, from
        // the rebuilt store reopened as a reader, with the recorded Journals.
        let Some(reads) = directory
            .parent()
            .map(|parent| parent.join("reads.json"))
            .filter(|path| directory.ends_with("store") && path.is_file())
        else {
            continue;
        };
        for row in rows {
            let id = text(row, "jobId");
            let journal = directory.join("jobs").join(id).join("journal.jsonl");
            if let Ok(bytes) = fs::read(&journal) {
                let target = root.0.join("jobs").join(id);
                private_directories(&target);
                write_private_file(&target.join("journal.jsonl"), &bytes);
            }
        }
        let reader = JobStore::open(&root.0).unwrap();
        let reads: Value = serde_json::from_slice(&fs::read(&reads).unwrap()).unwrap();
        for (job, answers) in reads.as_object().unwrap() {
            if RESIDENT
                .iter()
                .any(|(fixture, id)| directory.parent().unwrap().ends_with(fixture) && id == job)
            {
                continue;
            }
            for (method, recorded) in answers.as_object().unwrap() {
                if !READS.contains(&method.as_str()) {
                    continue;
                }
                let actual = answer(
                    reader.handle_resource(method, &Map::from_iter([("jobId".into(), json!(job))])),
                );
                *reads_compared.entry(method.clone()).or_default() += 1;
                if &actual != recorded {
                    differences.push(format!(
                        "{} {job} {method}:\n  swift {recorded}\n  rust  {actual}",
                        directory.display()
                    ));
                }
            }
        }
    }
    eprintln!(
        "{} recorded Job indexes: {rebuilt} rebuilt ({rows_rebuilt} rows) and read back; \
         {incomplete} not rebuilt (a row's record is not part of the snapshot or is not \
         a current record); recorded Job reads compared: {reads_compared:?}",
        indexes.len()
    );
    assert!(differences.is_empty(), "{}", differences.join("\n"));
    assert!(rebuilt >= 100, "{rebuilt}");
}
