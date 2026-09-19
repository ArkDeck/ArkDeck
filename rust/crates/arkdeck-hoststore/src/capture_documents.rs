//! Swift `RuntimeArtifactService.finalArtifactContents` and `markersDocument`:
//! the products a run synthesizes at finalization. A capture's log is its
//! timeline as the run finalizes; its markers are the host's own marks and
//! what the run already knows, with what it could not derive said so; its
//! index and summary state every other declared product's final status, so a
//! partial capture can never read as a whole one. A screen sequence's
//! `sequence.json` is what its run of stills measured. Built from the record
//! and the Artifact index alone: no product's bytes are opened.
use crate::job_record::JobRecord;
use crate::operation_catalog::CatalogOperation;
use crate::session_json;
use serde_json::{Map, Value, json};

const CAPTURE: &str = "capture.diagnostics@1";

fn published(row: &Value) -> bool {
    row["status"].get("published").is_some()
}

/// The first index row that names `name`.
fn row<'a>(recorded: &'a [Value], name: &str) -> Option<&'a Value> {
    recorded.iter().find(|row| row["name"] == name)
}

/// The contents of the finalization product `name`, or why they cannot be
/// composed.
pub(crate) fn contents(
    name: &str,
    descriptor: &CatalogOperation,
    record: &JobRecord,
    recorded: &[Value],
    finalize_names: &[&str],
) -> Result<Vec<u8>, String> {
    let reference = descriptor.reference();
    if reference == CAPTURE && name == "capture.log" {
        let mut log = record.timeline.join("\n");
        log.push('\n');
        return Ok(log.into_bytes());
    }
    if reference == CAPTURE && name == "markers.json" {
        return markers(record, recorded);
    }
    if reference == crate::device_steps::SCREEN_SEQUENCE && name == "sequence.json" {
        return sequence(record);
    }
    let finalized = |name: &str| finalize_names.contains(&name);
    let mut artifacts = Map::new();
    for declaration in descriptor
        .artifacts
        .iter()
        .filter(|declaration| !finalized(&declaration.name))
    {
        let row = row(recorded, &declaration.name);
        let status = row.map(|row| &row["status"]);
        let (state, detail) = match status {
            Some(status) if status.get("published").is_some() => ("published", None),
            Some(status) if status.get("missing").is_some() => (
                "missing",
                status["missing"]["reason"].as_str().map(str::to_owned),
            ),
            Some(status) if status.get("truncated").is_some() => (
                "truncated",
                Some(format!("at {} bytes", status["truncated"]["atBytes"])),
            ),
            Some(_) => return Err("an Artifact index row has no status".into()),
            None => ("missing", Some("never produced".into())),
        };
        let mut entry = json!({"status": state, "required": declaration.required});
        if let Some(detail) = detail {
            entry["detail"] = json!(detail);
        }
        if let Some(row) = row.filter(|row| published(row)) {
            entry["artifactId"] = row["artifactID"].clone();
            entry["byteCount"] = row["byteCount"].clone();
            entry["sha256"] = row["sha256"].clone();
        }
        artifacts.insert(declaration.name.clone(), entry);
    }
    let missing_required: Vec<&str> = descriptor
        .artifacts
        .iter()
        .filter(|declaration| {
            declaration.required
                && !finalized(&declaration.name)
                && !row(recorded, &declaration.name).is_some_and(published)
        })
        .map(|declaration| declaration.name.as_str())
        .collect();
    let mut payload = json!({"operation": reference, "jobId": record.job_id,
        "artifacts": artifacts});
    if !name.contains("index") {
        payload["completeness"] = json!(if missing_required.is_empty() {
            "complete"
        } else {
            "incomplete"
        });
        payload["missingRequired"] = json!(missing_required);
    }
    let requested_trace = record.request["inputs"]["traceCategories"]
        .as_array()
        .is_some_and(|tags| !tags.is_empty());
    if reference == CAPTURE && requested_trace {
        // Swift adds the Trace capture's parameters here; a capture with
        // Trace legs is not planned by this Runtime.
        return Err("a Trace capture's summary is not composed by the Rust Runtime yet".into());
    }
    session_json::encode_canonical_pretty(&payload)
        .map_err(|_| "the document cannot be encoded".into())
}

/// Swift `markersDocument`: the host's marks, a crash log that arrived with
/// bytes and every step that failed, and the kinds nothing looked for.
fn markers(record: &JobRecord, recorded: &[Value]) -> Result<Vec<u8>, String> {
    let inputs = &record.request["inputs"];
    let mut marks = Vec::new();
    for raw in inputs["markers"]
        .as_array()
        .into_iter()
        .flatten()
        .filter_map(Value::as_str)
    {
        let (at, label) = match raw.split_once('#') {
            Some((at, label)) => (at, Some(label)),
            None => (raw, None),
        };
        let mut mark = json!({"kind": "manual", "atHostUTC": at});
        if let Some(label) = label.filter(|label| !label.is_empty()) {
            mark["label"] = json!(label);
        }
        marks.push(mark);
    }
    if let Some(crash) = row(recorded, "crash-log.txt").filter(|crash| published(crash))
        && let Some(count) = crash["byteCount"].as_u64().filter(|count| *count > 0)
    {
        marks.push(json!({"kind": "auto", "trigger": "crashLogCaptured",
            "evidenceArtifact": "crash-log.txt", "evidenceByteCount": count}));
    }
    for entry in record
        .timeline
        .iter()
        .filter(|entry| entry.starts_with("failed "))
    {
        marks.push(json!({"kind": "auto", "trigger": "stepFailed", "detail": entry}));
    }
    if inputs["ringBuffered"] == true {
        // Swift names the ring's coverage anchor here; a ring-buffered
        // capture is not planned by this Runtime.
        return Err(
            "a ring-buffered capture's markers are not composed by the Rust Runtime yet".into(),
        );
    }
    let document = json!({
        "documentType": "arkdeck-diagnostic-markers",
        "schemaVersion": "1.0.0",
        "jobId": record.job_id,
        "markers": marks,
        // Absence of a marker kind must not read as absence of the thing.
        "notDerived": [
            {"kind": "frameDeadline", "reason": "deriving it means reading the trace, and \
                finalization holds artifact metadata rather than artifact bytes"},
            {"kind": "logKeyword", "reason": "deriving it means reading the captured log, which \
                finalization does not open"},
        ],
    });
    session_json::encode_canonical_pretty(&document)
        .map_err(|_| "the document cannot be encoded".into())
}

/// Swift `sequenceDocument`: what the run achieved, so its frames can be laid
/// out on the spacing they were taken at — the counts, each frame's own
/// span, the rate over their sum and how many frames are missing — or, with
/// nothing measured, that absence rather than an empty run. Foundation's
/// `JSONEncoder` with sorted keys, pretty printed.
fn sequence(record: &JobRecord) -> Result<Vec<u8>, String> {
    let mut document = Map::from_iter([("schemaVersion".to_owned(), json!("1.0.0"))]);
    match record.screen_sequence() {
        Some(sequence) => {
            let integer = |key: &str| {
                sequence[key]
                    .as_i64()
                    .ok_or_else(|| format!("the recorded {key} is not an integer"))
            };
            let (requested, captured) = (
                integer("requestedFrameCount")?,
                integer("capturedFrameCount")?,
            );
            let durations: Vec<f64> = sequence["frameDurationsSeconds"]
                .as_array()
                .into_iter()
                .flatten()
                .map(|duration| {
                    duration
                        .as_f64()
                        .ok_or_else(|| "a recorded frame duration is not a number".to_owned())
                })
                .collect::<Result<_, _>>()?;
            // Swift `RuntimeScreenSequence.framesPerSecond`: frames over the
            // span they covered, summed in capture order, or zero.
            let elapsed: f64 = durations.iter().sum();
            let rate = if elapsed > 0.0 {
                captured as f64 / elapsed
            } else {
                0.0
            };
            document.insert("requestedFrameCount".into(), json!(requested));
            document.insert("capturedFrameCount".into(), json!(captured));
            document.insert(
                "frameDurationsSeconds".into(),
                sequence["frameDurationsSeconds"].clone(),
            );
            document.insert("observedFramesPerSecond".into(), json!(rate));
            document.insert("framesMissing".into(), json!((requested - captured).max(0)));
        }
        None => {
            document.insert("measured".into(), json!(false));
            document.insert(
                "reason".into(),
                json!("the capture step published no observed frame timings"),
            );
        }
    }
    session_json::encode_pretty(&Value::Object(document))
        .map_err(|_| "the document cannot be encoded".into())
}
