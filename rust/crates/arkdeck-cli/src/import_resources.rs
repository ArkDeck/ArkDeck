//! Existing typed Import CLI leaves. A lost upload reply is resolved only by
//! rediscovering the same durable request; bytes are sent at that exact prefix.
use crate::{CliError, Invocation};
#[cfg(target_os = "macos")]
use arkdeck_contract::{ImportIntent, ImportProjection, import_id};
use serde_json::{Map, Value, json};

pub(crate) fn configure(
    command: &str,
    fields: &mut Map<String, Value>,
    help: bool,
) -> Result<Option<u64>, CliError> {
    if help || !command.starts_with("artifact.import.") {
        return Ok(None);
    }
    let invalid = || {
        CliError::new(
            "invalidOption",
            "Import requires its exact request identity, owner and options",
        )
    };
    if command == "artifact.import.list" {
        if let Some(size) = fields.remove("pageSize") {
            let size = size
                .as_str()
                .and_then(|s| s.parse::<u64>().ok())
                .filter(|n| (1..=1000).contains(n))
                .ok_or_else(invalid)?;
            fields.insert("pageSize".into(), json!(size));
        }
        if let Some(target) = fields.remove("targetId") {
            fields.insert("target".into(), target);
        }
        if fields
            .get("target")
            .is_some_and(|v| !v.as_str().is_some_and(arkdeck_contract::import_identifier))
            || fields.get("state").is_some_and(|v| {
                !v.as_str().is_some_and(|s| {
                    [
                        "inProgress",
                        "committing",
                        "committed",
                        "aborted",
                        "released",
                    ]
                    .contains(&s)
                })
            })
            || fields
                .get("pageSize")
                .is_some_and(|v| !v.as_u64().is_some_and(|n| (1..=1000).contains(&n)))
            || fields
                .get("cursor")
                .is_some_and(|v| !v.as_str().is_some_and(|s| !s.is_empty() && s.len() <= 2048))
        {
            return Err(invalid());
        }
    } else if command == "artifact.import.release" {
        // The registry's grammar: `--import` opaque, `--generation` a positive
        // integer. Swift sends the identity as given; the Runtime judges it.
        let id = fields.remove("import").ok_or_else(invalid)?;
        if !fields
            .get("generation")
            .and_then(Value::as_str)
            .and_then(|s| s.parse::<u64>().ok())
            .is_some_and(|n| (1..=9_007_199_254_740_991).contains(&n))
        {
            return Err(invalid());
        }
        fields.insert("importId".into(), id);
    } else if command == "artifact.import.inspect" {
        if fields.contains_key("import") == fields.contains_key("importRequestId") {
            return Err(invalid());
        }
        if let Some(id) = fields.remove("import") {
            // CLI opaque identity grammar is checked by the Runtime owner.
            fields.insert("importId".into(), id);
        }
    } else {
        let required: &[&str] = if command == "artifact.import.abort" {
            &["importRequestId", "expectedGeneration"]
        } else {
            &["importRequestId", "targetId", "file"]
        };
        if required.iter().any(|key| !fields.contains_key(*key)) {
            return Err(invalid());
        }
        if command == "artifact.import.abort" {
            let value = fields.remove("expectedGeneration").ok_or_else(invalid)?;
            fields.insert("generation".into(), value);
        }
    }
    if fields
        .get("importRequestId")
        .is_some_and(|v| !v.as_str().is_some_and(crate::valid_correlation))
        || fields.get("deviceProfile").is_some_and(|v| v != "dayu200")
    {
        return Err(invalid());
    }
    let timeout = fields.remove("timeout").unwrap_or(json!("1h"));
    crate::read_only_resources::duration(timeout.as_str().unwrap_or_default())
        .map(Some)
        .ok_or_else(|| {
            CliError::new(
                "invalidInput",
                "Import timeout must be a positive duration bounded by 24h",
            )
        })
}
#[cfg(target_os = "macos")]
fn invalid() -> CliError {
    CliError::new(
        "recordUnreadable",
        "Runtime Import response changed its metadata, owner or committed prefix",
    )
}
#[cfg(target_os = "macos")]
fn projection(value: Value) -> Result<ImportProjection, CliError> {
    ImportProjection::parse(&value).map_err(|_| projection_invalid())
}
// Swift's CLI refusals of an Import response it cannot accept
// (`CLIImports.swift`, `ArtifactImportProjection`), in its words.
#[cfg(target_os = "macos")]
fn projection_invalid() -> CliError {
    CliError::new(
        "recordUnreadable",
        "Runtime returned an invalid Import projection",
    )
}
#[cfg(target_os = "macos")]
fn source_changed() -> CliError {
    CliError::new(
        "artifactIntegrityFailed",
        "Import source changed; staged data was not overwritten or aborted",
    )
}
#[cfg(target_os = "macos")]
fn timed_out() -> CliError {
    CliError::new(
        "clientTimeout",
        "Import client timed out; inspect or retry the same request identity",
    )
}
#[cfg(target_os = "macos")]
fn uncertain(error: &CliError) -> bool {
    matches!(error.code, "outcomeUnknown" | "runtimeUnavailable")
}
#[cfg(target_os = "macos")]
fn request_fields(key: &str, value: &str) -> Map<String, Value> {
    Map::from_iter([(key.into(), json!(value))])
}

/// The request adapter must establish a new authenticated connection for each
/// call, bounded by the remaining time. This also permits exact crash-window tests.
#[cfg(target_os = "macos")]
pub fn execute_import(
    invocation: &Invocation,
    mut request: impl FnMut(&str, Map<String, Value>, u64) -> Result<Value, CliError>,
) -> Result<Value, CliError> {
    use arkdeck_contract::{encode_import_chunk, sha256_hex};
    use arkdeck_platform::HostImportSource;
    use std::time::{Duration, Instant};
    let deadline = Instant::now()
        .checked_add(Duration::from_millis(
            invocation.timeout_ms.unwrap_or(3_600_000),
        ))
        .ok_or_else(invalid)?;
    let remaining = || {
        deadline
            .checked_duration_since(Instant::now())
            .map(|v| v.as_millis() as u64)
            .filter(|n| *n > 0)
            .ok_or_else(timed_out)
    };
    let mut send = |method: &str, params: Map<String, Value>| request(method, params, remaining()?);
    let fields = invocation.params.as_ref().ok_or_else(invalid)?;
    let result = (|| {
        if invocation.command == "artifact.import.list" {
            // Swift `ArtifactImportProjection.validatePage`: the page, each
            // row's projection, then the rows' order and identities.
            let page_invalid = || {
                CliError::new(
                    "recordUnreadable",
                    "Runtime returned an invalid Import page",
                )
            };
            let order_changed = || {
                CliError::new(
                    "recordUnreadable",
                    "Import snapshot order or owner identity changed",
                )
            };
            let value = send(invocation.method, fields.clone())?;
            arkdeck_contract::validate_method_value(invocation.method, "result", &value)
                .map_err(|_| page_invalid())?;
            let revision = value["snapshotRevision"]
                .as_str()
                .filter(|s| crate::session_resources::uuid(s))
                .ok_or_else(page_invalid)?;
            let rows = value["items"].as_array().ok_or_else(page_invalid)?;
            let more = value["hasMore"].as_bool().ok_or_else(page_invalid)?;
            if value["schemaVersion"] != "arkdeck.cli.page/1"
                || value["pageKind"] != "snapshot"
                || value["order"] != "createdAtDescImportIdAsc"
                || rows.len() as u64
                    > fields
                        .get("pageSize")
                        .and_then(Value::as_u64)
                        .unwrap_or(100)
                || (more && rows.is_empty())
                || (if more {
                    !value["nextCursor"].as_str().is_some_and(|s| {
                        s.len() <= 2048
                            && s.strip_prefix(revision)
                                .is_some_and(|tail| tail.starts_with('.'))
                    })
                } else {
                    !value["nextCursor"].is_null()
                })
            {
                return Err(page_invalid());
            }
            let mut seen = std::collections::BTreeSet::new();
            let mut previous: Option<(f64, String)> = None;
            for row in rows {
                let imported = ImportProjection::parse(row).map_err(|_| projection_invalid())?;
                let created = row["createdAtUtc"]
                    .as_str()
                    .and_then(arkdeck_contract::import_timestamp)
                    .ok_or_else(order_changed)?;
                if !seen.insert(imported.id.clone())
                    || fields
                        .get("target")
                        .is_some_and(|v| v != &imported.intent.target_id)
                    || fields.get("state").is_some_and(|v| v != &imported.state)
                    || previous.as_ref().is_some_and(|(date, id)| {
                        created > *date || (created == *date && imported.id <= *id)
                    })
                {
                    return Err(order_changed());
                }
                previous = Some((created, imported.id));
            }
            return Ok(value);
        }
        if invocation.command == "artifact.import.abort" {
            let current = projection(send(invocation.method, fields.clone())?)?;
            if fields.get("importRequestId") != Some(&json!(current.intent.request_id))
                || current.state != "aborted"
                || current.generation != 2
                || fields.get("generation") != Some(&json!("1"))
            {
                return Err(invalid());
            }
            return Ok(current.value);
        }
        if invocation.command == "artifact.import.release" {
            // Swift `ArtifactImportReleaseProjection`, then its CLI's check
            // that the receipt is the one it asked for.
            let malformed =
                || CliError::new("recordUnreadable", "Import release receipt is malformed");
            let value = send(invocation.method, fields.clone())?;
            arkdeck_contract::validate_method_value(invocation.method, "result", &value)
                .map_err(|_| malformed())?;
            let id = value["importId"]
                .as_str()
                .filter(|id| import_id(id))
                .ok_or_else(malformed)?;
            let artifact = value["artifactId"].as_str().ok_or_else(malformed)?;
            let released = value["releasedAtUtc"]
                .as_str()
                .and_then(arkdeck_contract::import_timestamp)
                .ok_or_else(malformed)?;
            let deadline = value["retention"]["deadlineUtc"]
                .as_str()
                .and_then(arkdeck_contract::import_timestamp)
                .ok_or_else(malformed)?;
            if value["schemaVersion"] != "arkdeck.import-release/1"
                || value["owner"] != json!({"kind":"import","id":id})
                || value["releasedGeneration"] != "2"
                || value["generation"] != "3"
                || value["state"] != "released"
                || artifact.len() != 36
                || !artifact.starts_with("ART-")
                || !artifact[4..]
                    .bytes()
                    .all(|c| c.is_ascii_digit() || (b'a'..=b'f').contains(&c))
                || value["lease"] != format!("lease-v1:{id}:{artifact}")
                || !value["importRequestId"]
                    .as_str()
                    .is_some_and(arkdeck_contract::import_identifier)
                || value["retention"]["class"] != "default"
                || value["retention"]["pinned"] != false
                || deadline <= released
            {
                return Err(malformed());
            }
            if fields["importId"] != id || fields["generation"] != "2" {
                return Err(CliError::new(
                    "recordUnreadable",
                    "Import release receipt does not match the requested owner and generation",
                ));
            }
            return Ok(value);
        }
        if invocation.command == "artifact.import.inspect" {
            // Swift `ArtifactImportInspectionProjection`, then its CLI's check
            // that the inspection is of the Import it asked for.
            let malformed = || {
                CliError::new(
                    "recordUnreadable",
                    "Import reference inspection is malformed",
                )
            };
            let value = send("artifact.import.inspection", fields.clone())?;
            arkdeck_contract::validate_method_value("artifact.import.inspection", "result", &value)
                .map_err(|_| malformed())?;
            let imported =
                arkdeck_contract::validate_import_inspection(&value).map_err(|_| malformed())?;
            if fields
                .get("importId")
                .is_some_and(|v| v != &json!(imported.id))
                || fields
                    .get("importRequestId")
                    .is_some_and(|v| v != &json!(imported.intent.request_id))
            {
                return Err(CliError::new(
                    "recordUnreadable",
                    "Import inspection returned another requested owner",
                ));
            }
            return Ok(value);
        }
        let kind = invocation
            .command
            .strip_prefix("artifact.import.")
            .ok_or_else(invalid)?;
        let request_id = fields["importRequestId"].as_str().ok_or_else(invalid)?;
        let target = fields["targetId"].as_str().ok_or_else(invalid)?;
        let maximum = match kind {
            "flash-bundle" => 8 * 1024 * 1024 * 1024,
            "workspace-patch" => 512 * 1024,
            _ => 64 * 1024 * 1024,
        };
        let source = HostImportSource::open(
            std::path::Path::new(fields["file"].as_str().ok_or_else(invalid)?),
            maximum,
            || {
                remaining()
                    .map(|_| ())
                    .map_err(|e| std::io::Error::other(e.message))
            },
        )
        .map_err(|e| {
            // Swift `CLIImportSource`'s refusals: the deadline, a source that
            // changed while it was read, one outside its kind's bound, and one
            // that cannot be opened.
            if remaining().is_err() {
                return timed_out();
            }
            match e.kind() {
                std::io::ErrorKind::InvalidData => source_changed(),
                std::io::ErrorKind::InvalidInput => CliError::new(
                    "invalidInput",
                    "Import source exceeds its registered regular-file bound",
                ),
                // Swift answers a short read artifactIntegrityFailed "Import
                // source could not be read completely"; its code is left to
                // the next change (TASK-XPA-013 X6).
                std::io::ErrorKind::UnexpectedEof => CliError::new(
                    "invalidInput",
                    format!("Import source cannot be opened within its registered bound: {e}"),
                ),
                _ => CliError::new("invalidInput", "Import source cannot be opened"),
            }
        })?;
        let selector = || request_fields("importRequestId", request_id);
        let existing = match send("artifact.import.inspect", selector()) {
            Ok(value) => Some(projection(value)?),
            Err(error) if error.code == "resourceNotFound" => None,
            Err(error) => return Err(error),
        };
        let revision = if let Some(existing) = &existing {
            existing.intent.binding_revision
        } else {
            let target_value = send("target.show", request_fields("targetId", target))?;
            let unbound = || {
                CliError::new(
                    "recordUnreadable",
                    "target has no exact current binding reference",
                )
            };
            if target_value["schemaVersion"] != "arkdeck.target/1"
                || target_value["targetId"] != target
            {
                return Err(unbound());
            }
            target_value["bindingRevision"]
                .as_u64()
                .filter(|n| *n > 0 && *n <= i64::MAX as u64)
                .ok_or_else(unbound)?
        };
        let name = match kind {
            "flash-bundle" => "images.tar.gz".to_owned(),
            "native-library" => canonical_native_name(&source.name)?,
            _ => source.name.clone(),
        };
        let intent = ImportIntent {
            request_id: request_id.into(),
            kind: kind.into(),
            target_id: target.into(),
            binding_revision: revision,
            device_profile: (kind == "flash-bundle").then(|| "dayu200".into()),
            name,
            byte_count: source.byte_count,
            sha256: source.sha256.clone(),
        };
        intent.validate().map_err(|_| {
            CliError::new(
                "invalidInput",
                "Import requires registered metadata and exact target/binding references",
            )
        })?;
        if let Some(existing) = &existing
            && existing.intent != intent
        {
            let old = &existing.intent;
            return Err(
                if old.kind == intent.kind
                    && old.target_id == intent.target_id
                    && old.name == intent.name
                    && old.device_profile == intent.device_profile
                    && (old.sha256 != intent.sha256 || old.byte_count != intent.byte_count)
                {
                    source_changed()
                } else {
                    CliError::new(
                        "idempotencyConflict",
                        "Import request identity already names different metadata",
                    )
                },
            );
        }
        let metadata = || {
            intent
                .projection()
                .as_object()
                .expect("typed intent")
                .clone()
        };
        let mut current = if let Some(existing) = existing {
            existing
        } else {
            match send("artifact.import.begin", metadata()) {
                Ok(value) => projection(value)?,
                Err(error) if uncertain(&error) => {
                    match send("artifact.import.inspect", selector()) {
                        Ok(value) => projection(value)?,
                        Err(error) if error.code == "resourceNotFound" => {
                            projection(send("artifact.import.begin", metadata())?)?
                        }
                        Err(error) => return Err(error),
                    }
                }
                Err(error) => return Err(error),
            }
        };
        if !import_id(&current.id) {
            return Err(projection_invalid());
        }
        if current.intent != intent {
            return Err(CliError::new(
                "recordUnreadable",
                "Import receipt changed the upload metadata",
            ));
        }
        let mut recoveries = 0;
        while current.state == "inProgress" && current.next_offset < source.byte_count {
            remaining()?;
            let offset = current.next_offset;
            let chunk = source
                .chunk(
                    offset,
                    current.maximum_chunk_bytes.min(source.byte_count - offset) as usize,
                )
                .map_err(|_| source_changed())?;
            let append = json!({"importId":current.id,"generation":current.generation.to_string(),"offset":offset.to_string(),
                "byteCount":chunk.len().to_string(),"sha256":sha256_hex(&chunk),"base64":encode_import_chunk(&chunk).map_err(|_| invalid())?});
            match send(
                "artifact.import.append",
                append.as_object().expect("append fields").clone(),
            ) {
                Ok(value) => {
                    let next = projection(value)?;
                    if next.id != current.id
                        || next.intent != intent
                        || next.next_offset != offset + chunk.len() as u64
                        || next.generation != current.generation
                        || next.state != "inProgress"
                    {
                        return Err(CliError::new(
                            "recordUnreadable",
                            "Import append returned another owner or offset",
                        ));
                    }
                    current = next;
                }
                Err(error) if uncertain(&error) && recoveries < 2 => {
                    recoveries += 1;
                    let recovered = projection(send("artifact.import.inspect", selector())?)?;
                    if recovered.id != current.id
                        || recovered.intent != intent
                        || recovered.next_offset < offset
                    {
                        return Err(CliError::new(
                            "recordUnreadable",
                            "Import recovery changed its owner or committed prefix",
                        ));
                    }
                    current = recovered;
                }
                Err(error) => return Err(error),
            }
        }
        source.check_identity().map_err(|_| source_changed())?;
        if matches!(current.state.as_str(), "inProgress" | "committing") {
            let commit_owner_changed =
                || CliError::new("recordUnreadable", "Import commit returned another owner");
            let owner = current.id.clone();
            let params = json!({"importId":owner,"generation":current.generation.to_string()})
                .as_object()
                .expect("commit")
                .clone();
            current = match send("artifact.import.commit", params) {
                Ok(value) => projection(value)?,
                Err(error) if uncertain(&error) => {
                    let recovered = projection(send("artifact.import.inspect", selector())?)?;
                    if recovered.id != owner || recovered.intent != intent {
                        return Err(commit_owner_changed());
                    }
                    // A durable prefix does not prove publication failed. The
                    // publication owner has not joined this migration, so an
                    // unknown commit is inspected once and never replayed.
                    if matches!(recovered.state.as_str(), "inProgress" | "committing") {
                        return Err(error);
                    }
                    recovered
                }
                Err(error) => return Err(error),
            };
            if current.id != owner || current.intent != intent {
                return Err(commit_owner_changed());
            }
        }
        match current.state.as_str() {
            "committed" => Ok(current.value),
            "aborted" | "released" => Err(CliError::new(
                "operationFailed",
                "Import request is terminal; use a new request identity for a new input",
            )),
            _ => Err(CliError::new(
                "resultNotReady",
                "Import remains resumable; retry with the same request identity",
            )),
        }
    })();
    result.map_err(|mut error| {
        for key in ["importRequestId", "importId"] {
            if let Some(value) = fields.get(key) {
                error.details.entry(key.to_owned()).or_insert(value.clone());
            }
        }
        error
    })
}
#[cfg(not(target_os = "macos"))]
pub fn execute_import(
    _: &Invocation,
    _: impl FnMut(&str, Map<String, Value>, u64) -> Result<Value, CliError>,
) -> Result<Value, CliError> {
    Err(CliError::new(
        "unsupportedOnPlatform",
        "Import upload is not supported on this platform",
    ))
}
#[cfg(target_os = "macos")]
fn canonical_native_name(source: &str) -> Result<String, CliError> {
    let stripped = source
        .strip_prefix("ART-")
        .and_then(|s| {
            s.get(..33)
                .filter(|s| {
                    s.as_bytes()[32] == b'-'
                        && s.as_bytes()[..32]
                            .iter()
                            .copied()
                            .all(|b| b.is_ascii_digit() || (b'a'..=b'f').contains(&b))
                })
                .map(|_| &source[37..])
        })
        .unwrap_or(source);
    if !stripped.starts_with("lib")
        || !stripped.ends_with(".so")
        || stripped.len() <= 6
        || !stripped
            .bytes()
            .all(|b| b.is_ascii_alphanumeric() || b"_.-".contains(&b))
    {
        return Err(CliError::new(
            "invalidInput",
            "Native-library Import requires a lib*.so name",
        ));
    }
    Ok(stripped.into())
}
