//! Session manifest reader for the inventory candidate. Unsupported typed
//! branches stop the entire shadow comparison; they never become "unaccounted"
//! data or an assertion that a valid Session is corrupt.
use crate::session_time::session_timestamp;
use serde_json::{Map, Value};

type Object = Map<String, Value>;
#[derive(Debug)]
pub(super) enum ManifestError {
    Invalid,
    Unsupported,
}
type Result<T> = std::result::Result<T, ManifestError>;
#[derive(Debug)]
pub(super) struct ManifestSummary {
    pub session_id: String,
    pub job_id: String,
    pub completed_at: f64,
}

pub(super) fn identifier(value: &str) -> bool {
    (1..=128).contains(&value.len())
        && value.as_bytes()[0].is_ascii_alphanumeric()
        && value
            .bytes()
            .all(|b| b.is_ascii_alphanumeric() || b"._:-".contains(&b))
}
fn require(condition: bool) -> Result<()> {
    if condition {
        Ok(())
    } else {
        Err(ManifestError::Invalid)
    }
}
fn object(value: &Value) -> Result<&Object> {
    value.as_object().ok_or(ManifestError::Invalid)
}
fn text<'a>(value: &'a Object, key: &str) -> Result<&'a str> {
    value
        .get(key)
        .and_then(Value::as_str)
        .ok_or(ManifestError::Invalid)
}
fn array<'a>(value: &'a Object, key: &str) -> Result<&'a Vec<Value>> {
    value
        .get(key)
        .and_then(Value::as_array)
        .ok_or(ManifestError::Invalid)
}
fn nullable_text(value: &Object, key: &str) -> Result<Option<String>> {
    match value.get(key) {
        Some(Value::Null) => Ok(None),
        Some(Value::String(s)) => Ok(Some(s.clone())),
        _ => Err(ManifestError::Invalid),
    }
}
fn keys(value: &Object, required: &[&str], optional: &[&str]) -> Result<()> {
    require(
        required.iter().all(|k| value.contains_key(*k))
            && value
                .keys()
                .all(|k| required.contains(&k.as_str()) || optional.contains(&k.as_str())),
    )
}
fn choice<'a>(value: &'a Object, key: &str, choices: &[&str]) -> Result<&'a str> {
    let s = text(value, key)?;
    require(choices.contains(&s))?;
    Ok(s)
}
fn nonempty(value: &Object, key: &str) -> Result<()> {
    require(!text(value, key)?.is_empty())
}
fn timestamp(value: &Object, key: &str) -> Result<f64> {
    session_timestamp(text(value, key)?).ok_or(ManifestError::Invalid)
}
fn hash(value: &str) -> bool {
    value.len() == 64 && value.bytes().all(|b| b.is_ascii_hexdigit())
}

// The CLI canonical encoder is intentionally not reused: its integer limit
// and UTF-16 ordering are a different contract. Complex canonical JSON is an
// explicit remaining branch until its Foundation encoder parity is covered.
fn supported_json(value: &Value) -> Result<()> {
    match value {
        Value::Number(n) if !n.is_i64() && !n.is_u64() => Err(ManifestError::Unsupported),
        Value::Object(fields) => {
            if fields.keys().any(|key| !key.is_ascii()) {
                return Err(ManifestError::Unsupported);
            }
            fields.values().try_for_each(supported_json)
        }
        Value::Array(values) => values.iter().try_for_each(supported_json),
        _ => Ok(()),
    }
}

pub(super) fn decode_manifest(bytes: &[u8]) -> Result<ManifestSummary> {
    require(!bytes.is_empty() && bytes.len() <= 16 * 1024 * 1024)?;
    // Do not misclassify a valid deep document as corrupt because serde's own
    // recursion bound is lower than the current Swift reader's domain.
    let (mut depth, mut string, mut escaped) = (0_usize, false, false);
    for b in bytes {
        if string {
            if escaped {
                escaped = false;
            } else if *b == b'\\' {
                escaped = true;
            } else if *b == b'"' {
                string = false;
            }
        } else {
            match b {
                b'"' => string = true,
                b'{' | b'[' => {
                    depth += 1;
                    if depth > 64 {
                        return Err(ManifestError::Unsupported);
                    }
                }
                b'}' | b']' => depth = depth.saturating_sub(1),
                _ => (),
            }
        }
    }
    let value = arkdeck_contract::strict_json(bytes).map_err(|_| ManifestError::Invalid)?;
    let doc = object(&value)?;
    keys(
        doc,
        &[
            "schemaVersion",
            "appVersion",
            "coreSpecBaseline",
            "platformProfile",
            "sessionId",
            "jobId",
            "status",
            "executionMode",
            "executionAuthority",
            "outcomeCertainty",
            "sessionDisposition",
            "createdAt",
            "completedAt",
            "archivedAt",
            "originalTarget",
            "bindingHistory",
            "toolchain",
            "workflow",
            "steps",
            "parameters",
            "compensations",
            "confirmations",
            "artifacts",
            "warnings",
            "failure",
            "recovery",
        ],
        &["runtimeAuthority"],
    )?;
    require(text(doc, "schemaVersion")? == "1.0.0")?;
    nonempty(doc, "appVersion")?;
    nonempty(doc, "platformProfile")?;
    let baseline = text(doc, "coreSpecBaseline")?
        .strip_prefix("CORE-")
        .ok_or(ManifestError::Invalid)?;
    let version: Vec<_> = baseline.split('.').collect();
    require(
        version.len() == 3
            && version
                .iter()
                .all(|s| !s.is_empty() && s.bytes().all(|b| b.is_ascii_digit())),
    )?;
    let session_id = text(doc, "sessionId")?;
    let job_id = text(doc, "jobId")?;
    require(identifier(session_id) && identifier(job_id))?;
    let status = choice(
        doc,
        "status",
        &["planned", "succeeded", "failed", "cancelled", "interrupted"],
    )?;
    let mode = choice(doc, "executionMode", &["execute", "planOnly", "simulated"])?;
    choice(
        doc,
        "executionAuthority",
        &["interactiveUser", "standardAgent", "controlledHardwareLab"],
    )?;
    let certainty = choice(
        doc,
        "outcomeCertainty",
        &["confirmed", "outcomeUnknown", "mixed"],
    )?;
    let disposition = choice(doc, "sessionDisposition", &["finalized", "archived"])?;
    timestamp(doc, "createdAt")?;
    let completed_at = timestamp(doc, "completedAt")?;
    if disposition == "archived" {
        timestamp(doc, "archivedAt")?;
    } else {
        require(doc["archivedAt"].is_null())?;
    }

    let simulated = mode == "simulated";
    let target = object(&doc["originalTarget"])?;
    keys(
        target,
        &["kind", "connectKey", "transport", "identitySnapshot"],
        &[],
    )?;
    let target_kind = choice(target, "kind", &["real", "synthetic", "host"])?;
    let transport = choice(
        target,
        "transport",
        &["usb", "tcp", "uart", "synthetic", "host"],
    )?;
    let connect = nullable_text(target, "connectKey")?;
    require(!object(&target["identitySnapshot"])?.is_empty())?;
    let host = target_kind == "host";
    if simulated {
        require(target_kind == "synthetic" && transport == "synthetic" && connect.is_none())?;
    } else if host {
        require(transport == "host" && connect.is_none())?;
    } else {
        require(
            target_kind == "real"
                && ["usb", "tcp", "uart"].contains(&transport)
                && connect.is_some_and(|s| !s.is_empty()),
        )?;
    }
    let bindings = array(doc, "bindingHistory")?;
    require(host == bindings.is_empty())?;
    let mut previous = 0_i64;
    for row in bindings {
        let row = object(row)?;
        keys(
            row,
            &[
                "revision",
                "connectKey",
                "transport",
                "identitySnapshot",
                "evidence",
                "confirmedBy",
                "channelProtection",
            ],
            &[],
        )?;
        let revision = row["revision"].as_i64().ok_or(ManifestError::Invalid)?;
        require(revision > previous && !object(&row["identitySnapshot"])?.is_empty())?;
        previous = revision;
        let evidence = array(row, "evidence")?;
        require(
            !evidence.is_empty()
                && evidence
                    .iter()
                    .all(|s| s.as_str().is_some_and(|s| !s.is_empty())),
        )?;
        let connect = nullable_text(row, "connectKey")?;
        let transport = choice(row, "transport", &["usb", "tcp", "uart", "synthetic"])?;
        let actor = choice(row, "confirmedBy", &["corePolicy", "user", "simulation"])?;
        let protection = choice(
            row,
            "channelProtection",
            &[
                "encryptedVerified",
                "unverifiedAssumeUnprotected",
                "notApplicable",
            ],
        )?;
        if simulated {
            require(
                connect.is_none()
                    && transport == "synthetic"
                    && actor == "simulation"
                    && protection == "notApplicable",
            )?;
        } else {
            require(
                connect.is_some_and(|s| !s.is_empty())
                    && transport != "synthetic"
                    && actor != "simulation"
                    && protection != "notApplicable",
            )?;
        }
    }
    let tool = object(&doc["toolchain"])?;
    let kind = choice(
        tool,
        "kind",
        &["hdc", "hostTool", "runtimeProvider", "none"],
    )?;
    match kind {
        "none" => {
            keys(tool, &["kind"], &[])?;
            require(simulated || host)?;
        }
        "hostTool" => {
            keys(
                tool,
                &[
                    "kind",
                    "providerIdentity",
                    "profileIdentifier",
                    "reportedVersion",
                    "sha256",
                ],
                &[],
            )?;
            require(!simulated && host && hash(text(tool, "sha256")?))?;
            for key in ["providerIdentity", "profileIdentifier", "reportedVersion"] {
                nonempty(tool, key)?;
            }
        }
        "hdc" => {
            keys(
                tool,
                &[
                    "kind",
                    "source",
                    "path",
                    "sha256",
                    "clientVersion",
                    "serverVersion",
                    "endpoint",
                    "serverGeneration",
                    "serverOwnership",
                ],
                &[
                    "daemonVersion",
                    "providerIdentity",
                    "profileIdentifier",
                    "reportedVersion",
                ],
            )?;
            require(
                !simulated
                    && !host
                    && hash(text(tool, "sha256")?)
                    && tool["serverGeneration"].as_i64().is_some_and(|n| n >= 0),
            )?;
            for key in [
                "source",
                "path",
                "clientVersion",
                "serverVersion",
                "endpoint",
            ] {
                nonempty(tool, key)?;
            }
            choice(
                tool,
                "serverOwnership",
                &["external", "arkDeckManaged", "unknown"],
            )?;
            if tool.contains_key("daemonVersion") {
                nullable_text(tool, "daemonVersion")?;
            }
        }
        _ => return Err(ManifestError::Unsupported),
    }
    require(!doc.contains_key("runtimeAuthority"))?;
    let workflow = object(&doc["workflow"])?;
    keys(
        workflow,
        &["kind", "profileVersion", "providerIdentity"],
        &["fixtureIdentity", "scenarioIdentity"],
    )?;
    for key in ["kind", "profileVersion", "providerIdentity"] {
        nonempty(workflow, key)?;
    }
    for key in ["fixtureIdentity", "scenarioIdentity"] {
        let value = if workflow.contains_key(key) {
            nullable_text(workflow, key)?
        } else {
            None
        };
        if simulated {
            require(value.is_some_and(|s| !s.is_empty()))?;
        }
    }
    for key in ["steps", "compensations", "confirmations"] {
        if !array(doc, key)?.is_empty() {
            return Err(ManifestError::Unsupported);
        }
    }
    validate_parameters(array(doc, "parameters")?, status)?;
    validate_artifacts(array(doc, "artifacts")?)?;
    require(
        array(doc, "warnings")?
            .iter()
            .all(|s| s.as_str().is_some_and(|s| !s.is_empty())),
    )?;
    if !doc["failure"].is_null() {
        let failure = object(&doc["failure"])?;
        keys(failure, &["stage", "code", "summary"], &[])?;
        nonempty(failure, "stage")?;
        nonempty(failure, "summary")?;
        require(identifier(text(failure, "code")?))?;
    }
    if !doc["recovery"].is_null() {
        return Err(ManifestError::Unsupported);
    }
    require(!(mode == "planOnly" && status == "succeeded"))?;
    match status {
        "planned" => {
            require(mode == "planOnly" && certainty == "confirmed" && doc["failure"].is_null())?
        }
        "succeeded" | "cancelled" => require(certainty == "confirmed" && doc["failure"].is_null())?,
        "failed" => require(certainty == "confirmed" && !doc["failure"].is_null())?,
        _ => return Err(ManifestError::Invalid),
    }
    supported_json(&value)?;
    require(serde_json::to_vec(&value).map_err(|_| ManifestError::Invalid)? == bytes)?;
    Ok(ManifestSummary {
        session_id: session_id.to_owned(),
        job_id: job_id.to_owned(),
        completed_at,
    })
}

fn relative_path(value: &str) -> bool {
    let b = value.as_bytes();
    !value.is_empty()
        && value.len() <= 1024
        && !value.starts_with('/')
        && !(b.len() >= 2 && b[0].is_ascii_alphabetic() && b[1] == b':')
        && value.split('/').all(|part| {
            !part.is_empty()
                && ![".", ".."].contains(&part)
                && !part.ends_with(['.', ' '])
                && part
                    .chars()
                    .all(|c| c as u32 > 0x1f && c != '\u{7f}' && !"<>:\"/\\|?*".contains(c))
        })
}
fn base64(text: &str) -> Result<Vec<u8>> {
    let input = text.as_bytes();
    require(!input.is_empty() && input.len().is_multiple_of(4) && input.len() <= 21848)?;
    let digit = |b| -> Result<u32> {
        Ok(match b {
            b'A'..=b'Z' => u32::from(b - b'A'),
            b'a'..=b'z' => u32::from(b - b'a' + 26),
            b'0'..=b'9' => u32::from(b - b'0' + 52),
            b'+' => 62,
            b'/' => 63,
            _ => return Err(ManifestError::Invalid),
        })
    };
    let mut bytes = Vec::new();
    for (i, group) in input.as_chunks::<4>().0.iter().enumerate() {
        let last = (i + 1) * 4 == input.len();
        let a = digit(group[0])?;
        let b = digit(group[1])?;
        bytes.push(((a << 2) | (b >> 4)) as u8);
        if group[2] == b'=' {
            require(last && group[3] == b'=' && b & 15 == 0)?;
            continue;
        }
        let c = digit(group[2])?;
        bytes.push(((b << 4) | (c >> 2)) as u8);
        if group[3] == b'=' {
            require(last && c & 3 == 0)?;
            continue;
        }
        bytes.push(((c << 6) | digit(group[3])?) as u8);
    }
    require(bytes.len() <= 16 * 1024)?;
    Ok(bytes)
}
fn provenance(origin: &str) -> Result<Vec<String>> {
    let bytes = base64(
        origin
            .strip_prefix("derived:")
            .ok_or(ManifestError::Invalid)?,
    )?;
    let value = arkdeck_contract::strict_json(&bytes).map_err(|_| ManifestError::Invalid)?;
    let doc = object(&value)?;
    keys(
        doc,
        &["operation", "inputHashes", "parameters", "statistics"],
        &[],
    )?;
    let operation = text(doc, "operation")?;
    require(!operation.is_empty() && operation.len() <= 256)?;
    let hashes = array(doc, "inputHashes")?;
    require(!hashes.is_empty() && hashes.len() <= 256)?;
    let mut result = Vec::new();
    for value in hashes {
        let text = value.as_str().ok_or(ManifestError::Invalid)?;
        // Swift normalizes these hashes before its canonical-origin comparison.
        require(hash(text) && text == text.to_ascii_lowercase())?;
        result.push(text.to_owned());
    }
    let parameters = object(&doc["parameters"])?;
    let statistics = object(&doc["statistics"])?;
    require(
        !parameters.is_empty()
            && parameters.len() <= 256
            && !statistics.is_empty()
            && statistics.len() <= 256,
    )?;
    require(parameters.iter().all(|(k, v)| {
        !k.is_empty() && k.len() <= 128 && v.as_str().is_some_and(|v| v.len() <= 4096)
    }))?;
    require(
        statistics
            .iter()
            .all(|(k, v)| !k.is_empty() && k.len() <= 128 && v.as_i64().is_some_and(|v| v >= 0)),
    )?;
    supported_json(&value)?;
    require(serde_json::to_vec(&value).map_err(|_| ManifestError::Invalid)? == bytes)?;
    Ok(result)
}
fn validate_artifacts(values: &[Value]) -> Result<()> {
    use std::collections::{BTreeMap, BTreeSet, VecDeque};
    struct Artifact {
        hash: String,
        sources: Vec<String>,
        source_hashes: Vec<String>,
    }
    let mut artifacts = BTreeMap::new();
    for value in values {
        let row = object(value)?;
        keys(
            row,
            &["id", "role", "origin", "relativePath", "size", "sha256"],
            &["mediaType", "derivedFrom"],
        )?;
        let id = text(row, "id")?;
        require(identifier(id))?;
        let role = choice(
            row,
            "role",
            &["raw", "derived", "log", "plan", "diagnostic", "partial"],
        )?;
        let origin = text(row, "origin")?;
        require(
            !origin.is_empty()
                && relative_path(text(row, "relativePath")?)
                && row["size"].as_i64().is_some_and(|n| n >= 0)
                && hash(text(row, "sha256")?),
        )?;
        if row.contains_key("mediaType") {
            require(nullable_text(row, "mediaType")?.is_none_or(|s| !s.is_empty()))?;
        }
        let (mut sources, mut source_hashes) = (Vec::new(), Vec::new());
        if row.contains_key("derivedFrom") {
            require(role == "derived")?;
            let lineage = array(row, "derivedFrom")?;
            let mut seen = BTreeSet::new();
            require(!lineage.is_empty())?;
            for value in lineage {
                let source = value.as_str().ok_or(ManifestError::Invalid)?;
                require(identifier(source) && seen.insert(source))?;
                sources.push(source.to_owned());
            }
            source_hashes = provenance(origin)?;
            require(sources.len() == source_hashes.len())?;
        } else {
            require(role != "derived")?;
        }
        require(
            artifacts
                .insert(
                    id.to_owned(),
                    Artifact {
                        hash: text(row, "sha256")?.to_ascii_lowercase(),
                        sources,
                        source_hashes,
                    },
                )
                .is_none(),
        )?;
    }
    let mut degrees = BTreeMap::new();
    let mut dependents: BTreeMap<&str, Vec<&str>> = BTreeMap::new();
    let mut ready = VecDeque::new();
    for (id, artifact) in &artifacts {
        degrees.insert(id.as_str(), artifact.sources.len());
        if artifact.sources.is_empty() {
            ready.push_back(id.as_str());
        }
        for (source, hash) in artifact.sources.iter().zip(&artifact.source_hashes) {
            require(
                artifacts
                    .get(source)
                    .is_some_and(|record| record.hash == *hash),
            )?;
            dependents.entry(source).or_default().push(id);
        }
    }
    let mut visited = 0;
    while let Some(source) = ready.pop_front() {
        visited += 1;
        for target in dependents.get(source).into_iter().flatten() {
            let count = degrees.get_mut(target).ok_or(ManifestError::Invalid)?;
            *count -= 1;
            if *count == 0 {
                ready.push_back(target);
            }
        }
    }
    require(visited == artifacts.len())
}

fn parameter_state(value: &Value) -> Result<&str> {
    let row = object(value)?;
    let state = text(row, "state")?;
    match state {
        "missing" => keys(row, &["state"], &[])?,
        "unreadable" => {
            keys(row, &["state", "reason"], &[])?;
            nonempty(row, "reason")?;
        }
        "value" => {
            keys(row, &["state", "value"], &[])?;
            require(
                arkdeck_platform::host_composed_text_within(text(row, "value")?, 4096)
                    .ok_or(ManifestError::Unsupported)?,
            )?;
        }
        _ => return Err(ManifestError::Invalid),
    }
    Ok(state)
}
fn validate_parameters(values: &[Value], status: &str) -> Result<()> {
    for value in values {
        let row = object(value)?;
        keys(
            row,
            &[
                "name",
                "beforeState",
                "desiredState",
                "afterState",
                "restoreState",
                "restoreDisposition",
            ],
            &[],
        )?;
        let name = text(row, "name")?;
        require(
            (1..=255).contains(&name.len())
                && name
                    .bytes()
                    .all(|b| b.is_ascii_alphanumeric() || b"_.-".contains(&b)),
        )?;
        let before = parameter_state(&row["beforeState"])?;
        require(parameter_state(&row["desiredState"])? == "value")?;
        parameter_state(&row["afterState"])?;
        let restore = parameter_state(&row["restoreState"])?;
        let disposition = choice(
            row,
            "restoreDisposition",
            &[
                "notRequired",
                "restored",
                "persistentChangeAccepted",
                "failed",
                "outcomeUnknown",
            ],
        )?;
        if disposition == "restored" {
            require(before == "value" && restore == "value")?;
            // Unlike display-name equality, a restored parameter must preserve
            // the captured original bytes, even for canonically equal text.
            require(
                text(object(&row["beforeState"])?, "value")?.as_bytes()
                    == text(object(&row["restoreState"])?, "value")?.as_bytes(),
            )?;
        }
        if status == "succeeded" {
            require(!["failed", "outcomeUnknown"].contains(&disposition))?;
        }
    }
    Ok(())
}
