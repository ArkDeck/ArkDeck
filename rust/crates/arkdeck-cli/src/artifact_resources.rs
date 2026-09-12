//! Current Artifact resources. Metadata and content stay bound to the caller's
//! tagged owner; a read checks metadata before requesting one bounded range.
use crate::read_only_resources::{date, keys};
use crate::{CliError, Invocation};
use serde_json::{Map, Value, json};

const MAX_BYTES: u64 = 4_194_304;
const MAX_SAFE: u64 = 9_007_199_254_740_991;
fn invalid() -> CliError {
    CliError::new(
        "recordUnreadable",
        "Runtime returned inconsistent Artifact metadata or content",
    )
}
fn identifier(s: &str) -> bool {
    crate::valid_correlation(s) && !s.contains(':')
}
fn digest(v: &Value) -> bool {
    v.as_str().is_some_and(|s| {
        s.len() == 64
            && s.bytes()
                .all(|b| b.is_ascii_digit() || (b'a'..=b'f').contains(&b))
    })
}
fn count(v: &Value) -> Option<u64> {
    v.as_u64().filter(|n| *n <= MAX_SAFE)
}
fn text(v: &Value, maximum: usize) -> bool {
    v.as_str()
        .is_some_and(|s| !s.is_empty() && s.len() <= maximum)
}
fn owner(v: &Value) -> bool {
    if !keys(v, &["kind", "id"]) {
        return false;
    }
    let Some(id) = v["id"].as_str().filter(|id| identifier(id)) else {
        return false;
    };
    match v["kind"].as_str() {
        Some("job") => !id.starts_with("imp-"),
        Some("import") => id.strip_prefix("imp-").is_some_and(|s| {
            s.len() == 36
                && s.bytes().enumerate().all(|(i, b)| {
                    if [8, 13, 18, 23].contains(&i) {
                        b == b'-'
                    } else {
                        b.is_ascii_digit() || (b'a'..=b'f').contains(&b)
                    }
                })
        }),
        _ => false,
    }
}
pub(crate) fn configure(
    command: &str,
    fields: &mut Map<String, Value>,
    help: bool,
) -> Result<Option<u64>, CliError> {
    if help
        || !matches!(
            command,
            "artifact.inspect" | "artifact.read" | "artifact.export"
        )
    {
        return Ok(None);
    }
    let job = fields.remove("jobId");
    let imported = fields.remove("import");
    let (kind, id) = match (job, imported) {
        (Some(id), None) => ("job", id),
        (None, Some(id)) => ("import", id),
        (None, None) => {
            return Err(CliError::new(
                "invalidOption",
                "Artifact requires --job or --import and --artifact",
            ));
        }
        _ => {
            return Err(CliError::new(
                "invalidInput",
                "Select exactly one Job or Import owner",
            ));
        }
    };
    let value = json!({"kind":kind,"id":id});
    if !owner(&value) {
        return Err(CliError::new(
            "invalidInput",
            "Artifact owner identity is malformed",
        ));
    }
    fields.insert("owner".into(), value);
    let id = fields
        .get("artifactId")
        .and_then(Value::as_str)
        .ok_or_else(|| CliError::new("invalidOption", "Artifact requires --artifact"))?;
    if !identifier(id) {
        return Err(CliError::new(
            "invalidInput",
            "Artifact identity is malformed",
        ));
    }
    if command == "artifact.read" {
        for (key, fallback, minimum, maximum) in [
            ("offset", 0, 0, MAX_SAFE),
            ("maxBytes", 1_048_576, 1, MAX_BYTES),
        ] {
            let n = match fields.remove(key) {
                Some(v) => v
                    .as_str()
                    .filter(|s| !s.is_empty() && s.bytes().all(|b| b.is_ascii_digit()))
                    .and_then(|s| s.parse::<u64>().ok())
                    .filter(|n| *n >= minimum && *n <= maximum)
                    .ok_or_else(|| {
                        CliError::new("invalidInput", "Artifact range exceeds its published bound")
                    })?,
                None => fallback,
            };
            fields.insert(key.into(), json!(n));
        }
        fields.entry("allowSensitive").or_insert(json!(false));
    }
    if command == "artifact.export" {
        let destination = fields.remove("destinationPath").ok_or_else(|| {
            CliError::new("invalidOption", "Artifact export requires --destination")
        })?;
        if !destination
            .as_str()
            .is_some_and(|s| !s.is_empty() && s.len() <= 4096 && !s.chars().any(char::is_control))
        {
            return Err(CliError::new(
                "invalidInput",
                "Artifact export destination is malformed",
            ));
        }
        fields.insert("destinationDirectory".into(), destination);
        fields.entry("allowSensitive").or_insert(json!(false));
        fields.entry("overwrite").or_insert(json!(false));
    }
    let timeout = fields.remove("timeout").unwrap_or(json!("1h"));
    crate::read_only_resources::duration(timeout.as_str().unwrap_or_default())
        .map(Some)
        .ok_or_else(|| {
            CliError::new(
                "invalidInput",
                "Artifact timeout must be a positive duration bounded by 24h",
            )
        })
}

pub fn validate_artifact_metadata(
    params: &Map<String, Value>,
    value: &Value,
) -> Result<(), CliError> {
    arkdeck_contract::validate_method_value("artifact.inspect", "result", value)
        .map_err(|_| invalid())?;
    let binding = &value["binding"];
    let retention = &value["retention"];
    if value["schemaVersion"] != "arkdeck.artifact/1"
        || !owner(&value["owner"])
        || params.get("owner") != Some(&value["owner"])
        || !value["artifactId"].as_str().is_some_and(identifier)
        || params.get("artifactId") != Some(&value["artifactId"])
        || !text(&value["name"], 1024)
        || !text(&value["mediaType"], 256)
        || !matches!(value["privacy"].as_str(), Some("standard" | "sensitive"))
        || count(&value["byteCount"]).is_none()
        || !date(&value["createdAtUtc"])
        || !text(&value["sourceOperation"], 256)
        || !text(&value["providerId"], 128)
        || !matches!(
            value["status"].as_str(),
            Some("published" | "missing" | "truncated")
        )
        || !binding["targetId"].as_str().is_some_and(identifier)
        || (!binding["bindingRevision"].is_null()
            && !count(&binding["bindingRevision"]).is_some_and(|n| n > 0))
        || (!binding["stableIdentitySha256"].is_null() && !digest(&binding["stableIdentitySha256"]))
        || !matches!(
            retention["class"].as_str(),
            Some("default" | "shortLived" | "pinnedUntilVerified")
        )
        || (!retention["deadlineUtc"].is_null() && !date(&retention["deadlineUtc"]))
        || !(digest(&value["artifactDigest"])
            || (value["status"] != "published" && value["artifactDigest"].is_null()))
    {
        return Err(invalid());
    }
    if !value["lease"].is_null()
        && !(value["status"] == "published"
            && value["lease"]
                == format!(
                    "lease-v1:{}:{}",
                    value["owner"]["id"].as_str().unwrap(),
                    value["artifactId"].as_str().unwrap()
                ))
    {
        return Err(invalid());
    }
    let window = &value["observationWindow"];
    if !window.is_null() {
        let start = crate::job_resources::date_seconds(&window["startUtc"]).ok_or_else(invalid)?;
        let end = crate::job_resources::date_seconds(&window["endUtc"]).ok_or_else(invalid)?;
        if end < start {
            return Err(invalid());
        }
    }
    Ok(())
}
/// Strict canonical Base64 decoding with the same range bound as the wire.
/// Padding bits and trailing content are checked before any bytes are emitted.
pub fn artifact_bytes(value: &Value) -> Result<Vec<u8>, CliError> {
    let encoded = value["base64"].as_str().ok_or_else(invalid)?.as_bytes();
    let expected = count(&value["byteCount"])
        .filter(|n| *n <= MAX_BYTES)
        .ok_or_else(invalid)? as usize;
    if encoded.len() != expected.div_ceil(3) * 4 {
        return Err(invalid());
    }
    let sextet = |b| match b {
        b'A'..=b'Z' => Some(b - b'A'),
        b'a'..=b'z' => Some(b - b'a' + 26),
        b'0'..=b'9' => Some(b - b'0' + 52),
        b'+' => Some(62),
        b'/' => Some(63),
        _ => None,
    };
    let mut bytes = Vec::with_capacity(expected);
    for (i, chunk) in encoded.as_chunks::<4>().0.iter().enumerate() {
        let a = sextet(chunk[0]).ok_or_else(invalid)?;
        let b = sextet(chunk[1]).ok_or_else(invalid)?;
        let last = (i + 1) * 4 == encoded.len();
        let remaining = expected - bytes.len();
        bytes.push(a << 2 | b >> 4);
        if last && remaining == 1 {
            if chunk[2] != b'=' || chunk[3] != b'=' || b & 15 != 0 {
                return Err(invalid());
            }
            continue;
        }
        let c = sextet(chunk[2]).ok_or_else(invalid)?;
        bytes.push(b << 4 | c >> 2);
        if last && remaining == 2 {
            if chunk[3] != b'=' || c & 3 != 0 {
                return Err(invalid());
            }
            continue;
        }
        let d = sextet(chunk[3]).ok_or_else(invalid)?;
        bytes.push(c << 6 | d);
    }
    if bytes.len() != expected {
        return Err(invalid());
    }
    Ok(bytes)
}
pub fn validate_artifact_read(
    invocation: &Invocation,
    metadata: &Value,
    value: &Value,
) -> Result<(), CliError> {
    let params = invocation.params.as_ref().ok_or_else(invalid)?;
    validate_artifact_metadata(params, metadata)?;
    arkdeck_contract::validate_method_value("artifact.read", "result", value)
        .map_err(|_| invalid())?;
    let offset = count(&value["offset"]).ok_or_else(invalid)?;
    let next = count(&value["nextOffset"]).ok_or_else(invalid)?;
    let total = count(&value["totalByteCount"]).ok_or_else(invalid)?;
    let bytes = artifact_bytes(value)?;
    if metadata["status"] != "published"
        || !digest(&value["artifactDigest"])
        || value["artifactId"] != metadata["artifactId"]
        || value["artifactDigest"] != metadata["artifactDigest"]
        || value["totalByteCount"] != metadata["byteCount"]
        || Some(&value["offset"]) != params.get("offset")
        || offset > next
        || next > total
        || next - offset != bytes.len() as u64
        || value["eof"] != (next == total)
        || (bytes.is_empty() && next != total)
        || bytes.len() as u64 > params["maxBytes"].as_u64().ok_or_else(invalid)?
    {
        return Err(invalid());
    }
    Ok(())
}

fn export_destination(input: &str) -> Result<String, CliError> {
    use std::path::{Component, Path, PathBuf};
    let invalid = || {
        CliError::new(
            "invalidInput",
            "Artifact export destination must be a bounded local directory",
        )
    };
    if input.is_empty() || input.len() > 4096 || input.chars().any(char::is_control) {
        return Err(invalid());
    }
    let path = if Path::new(input).is_absolute() {
        PathBuf::from(input)
    } else {
        std::env::current_dir().map_err(|_| invalid())?.join(input)
    };
    let mut clean = PathBuf::from("/");
    for component in path.components() {
        match component {
            Component::RootDir | Component::CurDir => {}
            Component::ParentDir => {
                clean.pop();
            }
            Component::Normal(value) => clean.push(value),
            Component::Prefix(_) => return Err(invalid()),
        }
    }
    for prefix in ["/tmp", "/var", "/etc"] {
        if let Ok(tail) = clean.strip_prefix(prefix) {
            clean = Path::new("/private")
                .join(prefix.trim_start_matches('/'))
                .join(tail);
            break;
        }
    }
    let text = clean
        .to_str()
        .filter(|s| s.len() <= 4096)
        .ok_or_else(invalid)?;
    Ok(text.into())
}
/// Resolve the user's explicit local destination without probing or creating it.
/// The owner still authenticates the directory and performs all publication.
pub fn artifact_export_params(invocation: &Invocation) -> Result<Map<String, Value>, CliError> {
    let mut params = invocation.params.clone().ok_or_else(invalid)?;
    let input = params
        .get("destinationDirectory")
        .and_then(Value::as_str)
        .ok_or_else(invalid)?;
    let destination = export_destination(input)?;
    params.insert("destinationDirectory".into(), json!(destination));
    Ok(params)
}
pub fn validate_artifact_export(
    invocation: &Invocation,
    metadata: &Value,
    value: &Value,
) -> Result<(), CliError> {
    let uncertain = || {
        CliError::new(
            "outcomeUnknown",
            "Artifact export receipt is inconsistent; inspect the exact destination before retrying",
        )
    };
    let params = artifact_export_params(invocation).map_err(|_| uncertain())?;
    validate_artifact_metadata(&params, metadata).map_err(|_| uncertain())?;
    arkdeck_contract::validate_method_value("artifact.export", "result", value)
        .map_err(|_| uncertain())?;
    let safe_name = metadata["name"]
        .as_str()
        .ok_or_else(uncertain)?
        .replace('/', "_")
        .replace("..", "_");
    let directory = params["destinationDirectory"]
        .as_str()
        .ok_or_else(uncertain)?
        .trim_end_matches('/');
    let path = format!(
        "{directory}/{}-{safe_name}",
        metadata["artifactId"].as_str().ok_or_else(uncertain)?
    );
    if value["schemaVersion"] != "arkdeck.artifact-export/1"
        || metadata["status"] != "published"
        || value["owner"] != metadata["owner"]
        || value["artifactId"] != metadata["artifactId"]
        || value["artifactDigest"] != metadata["artifactDigest"]
        || value["byteCount"] != metadata["byteCount"]
        || value["privacy"] != metadata["privacy"]
        || value["exportedPath"] != path
        || (value["overwritten"] == true && params["overwrite"] != true)
    {
        return Err(uncertain());
    }
    Ok(())
}
