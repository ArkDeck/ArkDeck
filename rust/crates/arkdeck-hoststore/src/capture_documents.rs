//! Swift `RuntimeArtifactService.finalArtifactContents` and `markersDocument`:
//! the products a run synthesizes at finalization. A capture's log is its
//! timeline as the run finalizes; its markers are the host's own marks and
//! what the run already knows, with what it could not derive said so; its
//! index and summary state every other declared product's final status, so a
//! partial capture can never read as a whole one, and for a Trace capture
//! what its two snapshots read of the trace parameters. A screen sequence's
//! `sequence.json` is what its run of stills measured. Built from the record
//! and the Artifact index alone: no product's bytes are opened.
use crate::job_record::JobRecord;
use crate::operation_catalog::CatalogOperation;
use crate::session_json;
use arkdeck_provider_hdc::TraceRequest;
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
    if reference == CAPTURE
        && let Some(tags) = record.request["inputs"]["traceCategories"]
            .as_array()
            .filter(|tags| !tags.is_empty())
    {
        payload["trace"] = trace(record, recorded, tags);
    }
    session_json::encode_canonical_pretty(&payload)
        .map_err(|_| "the document cannot be encoded".into())
}

/// Swift `TraceDebugParameterCatalog.definitions`: each Trace parameter in
/// catalog order, with the value the debug profile wants it to hold.
const TRACE_PROFILE: [(&str, &str); 9] = [
    ("persist.ace.trace.syntax.enabled", "true"),
    ("persist.ace.trace.layout.enabled", "true"),
    ("persist.ace.trace.build.enabled", "true"),
    ("persist.ace.trace.measure.debug.enabled", "true"),
    ("persist.ace.trace.sync.debug.enabled", "true"),
    ("persist.ace.debug.enabled", "1"),
    ("persist.ace.performance.monitor.enabled", "true"),
    ("persist.sys.graphic.openDebugTrace", "1"),
    ("persist.rosen.animationtrace.enabled", "1"),
];

/// What a Trace capture's index and summary say of it: the tool and family
/// its first snapshot read, the tags the request named, each parameter's
/// wanted value and what the two snapshots read of it (never restored), the
/// window and buffer the request set, and the published trace's identity.
fn trace(record: &JobRecord, recorded: &[Value], tags: &[Value]) -> Value {
    let before = record.trace_probe(true);
    let after = record.trace_probe(false);
    // Swift `traceParameterJSON`: the reading, or that none was taken.
    let reading = |snapshot: Option<&Value>, name: &str| {
        let Some(observation) = snapshot
            .and_then(|snapshot| snapshot["parameters"].as_array())
            .and_then(|readings| readings.iter().find(|reading| reading["name"] == name))
        else {
            return json!({"state": "unobserved"});
        };
        let mut fields = Map::from_iter([("state".to_owned(), observation["state"].clone())]);
        for key in ["value", "detail"] {
            if let Some(value) = observation.get(key) {
                fields.insert(key.to_owned(), value.clone());
            }
        }
        Value::Object(fields)
    };
    let parameters: Vec<Value> = TRACE_PROFILE
        .iter()
        .map(|(name, desired)| {
            json!({"name": name, "desired": desired, "before": reading(before, name),
                "after": reading(after, name), "restored": null})
        })
        .collect();
    let member = |key: &str| {
        before
            .and_then(|snapshot| snapshot.get(key))
            .cloned()
            .unwrap_or(Value::Null)
    };
    let mut trace = json!({"toolIdentity": member("tool"), "adapterFamily": member("family"),
        "tags": tags, "parameters": parameters});
    let inputs = &record.request["inputs"];
    if let Some(duration) = inputs["durationSeconds"].as_i64() {
        trace["durationSeconds"] = json!(duration);
    }
    if let Some(buffer) = inputs["traceBufferKB"].as_i64() {
        trace["bufferKB"] = json!(buffer);
    }
    if let Some(raw) = recorded
        .iter()
        .find(|row| row["name"] == "trace.htrace" && published(row))
    {
        trace["rawArtifactId"] = raw["artifactID"].clone();
        trace["rawSha256"] = raw["sha256"].clone();
        trace["rawByteCount"] = raw["byteCount"].clone();
    }
    trace
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
    let mut document = json!({
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
    // The ring's coverage anchor, when this capture armed one: what to look
    // for and where, not a claim that the search succeeded, since the run
    // never opened the trace. Whether the ring held it is the capture's own
    // readback, or said not to be established where no readback reported.
    if inputs["ringBuffered"] == true {
        let ring = record.ring_coverage();
        let anchor = ring.and_then(|ring| ring["anchor"].as_str()).map_or_else(
            || TraceRequest::anchor(&record.job_id, "capture-trace"),
            str::to_owned,
        );
        let trace = row(recorded, "trace.htrace").is_some_and(published);
        document["coverage"] = json!({
            "anchor": anchor,
            "writtenIntoTheDeviceRingAt": "capture-trace",
            "checkAgainst": "trace.htrace",
            "traceStatus": if trace { "published" } else { "absent" },
            "how": "the anchor marks where this snapshot reaches back to; finding it in the \
                trace is a string search, no decoder needed",
            "ringHeldAnchor": ring
                .and_then(|ring| ring["ringHeldAnchor"].as_bool())
                .map_or_else(|| json!("notEstablished"), |held| json!(held)),
        });
    }
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
