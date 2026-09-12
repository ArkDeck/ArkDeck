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
    if command == "artifact.import.inspect" {
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
    ImportProjection::parse(&value).map_err(|_| invalid())
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
            .ok_or_else(|| {
                CliError::new(
                    "clientTimeout",
                    "Import timed out; inspect or retry the same request identity",
                )
            })
    };
    let mut send = |method: &str, params: Map<String, Value>| request(method, params, remaining()?);
    let fields = invocation.params.as_ref().ok_or_else(invalid)?;
    let result = (|| {
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
        if invocation.command == "artifact.import.inspect" {
            let value = send("artifact.import.inspection", fields.clone())?;
            arkdeck_contract::validate_method_value("artifact.import.inspection", "result", &value)
                .map_err(|_| invalid())?;
            let imported =
                arkdeck_contract::validate_import_inspection(&value).map_err(|_| invalid())?;
            if fields
                .get("importId")
                .is_some_and(|v| v != &json!(imported.id))
                || fields
                    .get("importRequestId")
                    .is_some_and(|v| v != &json!(imported.intent.request_id))
            {
                return Err(invalid());
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
            if remaining().is_err() {
                CliError::new(
                    "clientTimeout",
                    "Import source hashing exceeded the deadline",
                )
            } else {
                CliError::new(
                    if e.kind() == std::io::ErrorKind::InvalidData {
                        "artifactIntegrityFailed"
                    } else {
                        "invalidInput"
                    },
                    format!("Import source cannot be opened within its registered bound: {e}"),
                )
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
            if target_value["schemaVersion"] != "arkdeck.target/1"
                || target_value["targetId"] != target
            {
                return Err(invalid());
            }
            target_value["bindingRevision"]
                .as_u64()
                .filter(|n| *n > 0 && *n <= i64::MAX as u64)
                .ok_or_else(invalid)?
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
                "Import source metadata is outside its registered kind",
            )
        })?;
        if let Some(existing) = &existing
            && existing.intent != intent {
                let old = &existing.intent;
                return Err(
                    if old.kind == intent.kind
                        && old.target_id == intent.target_id
                        && old.name == intent.name
                        && old.device_profile == intent.device_profile
                        && (old.sha256 != intent.sha256 || old.byte_count != intent.byte_count)
                    {
                        CliError::new(
                            "artifactIntegrityFailed",
                            "Import source changed; staged data remains under its original identity",
                        )
                    } else {
                        CliError::new(
                            "idempotencyConflict",
                            "Import request identity names different metadata",
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
        if current.intent != intent || !import_id(&current.id) {
            return Err(invalid());
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
                .map_err(|_| {
                    CliError::new(
                        "artifactIntegrityFailed",
                        "Import source changed; staged data remains resumable",
                    )
                })?;
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
                        return Err(invalid());
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
                        return Err(invalid());
                    }
                    current = recovered;
                }
                Err(error) => return Err(error),
            }
        }
        source.check_identity().map_err(|_| {
            CliError::new(
                "artifactIntegrityFailed",
                "Import source changed before commit",
            )
        })?;
        if matches!(current.state.as_str(), "inProgress" | "committing") {
            let owner = current.id.clone();
            let params = json!({"importId":owner,"generation":current.generation.to_string()})
                .as_object()
                .expect("commit")
                .clone();
            current = match send("artifact.import.commit", params.clone()) {
                Ok(value) => projection(value)?,
                Err(error) if uncertain(&error) => {
                    let recovered = projection(send("artifact.import.inspect", selector())?)?;
                    if recovered.id != owner || recovered.intent != intent {
                        return Err(invalid());
                    }
                    if matches!(recovered.state.as_str(), "inProgress" | "committing") {
                        projection(send("artifact.import.commit", params)?)?
                    } else {
                        recovered
                    }
                }
                Err(error) => return Err(error),
            };
            if current.id != owner || current.intent != intent {
                return Err(invalid());
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
