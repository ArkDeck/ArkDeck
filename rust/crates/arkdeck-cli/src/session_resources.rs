//! Semantic checks required by the current Session CLI consumer, beyond the
//! generated structural schema. No partial page is printed on a failed check.
use crate::{CliError, Invocation, valid_correlation};
use serde_json::Value;
use std::collections::BTreeSet;

fn failure() -> CliError {
    CliError::new(
        "recordUnreadable",
        "The Runtime returned an invalid Session resource or page",
    )
}
fn decimal(value: &Value) -> Option<u64> {
    let text = value.as_str()?;
    let number = text.parse::<u64>().ok()?;
    (number <= i64::MAX as u64 && number.to_string() == text).then_some(number)
}
pub(super) fn uuid(text: &str) -> bool {
    text.len() == 36
        && text.bytes().enumerate().all(|(index, byte)| {
            if [8, 13, 18, 23].contains(&index) {
                byte == b'-'
            } else {
                byte.is_ascii_digit() || (b'a'..=b'f').contains(&byte)
            }
        })
}
fn plain_date(text: &str) -> bool {
    if text.len() != 20
        || !text.bytes().enumerate().all(|(index, byte)| match index {
            4 | 7 => byte == b'-',
            10 => byte == b'T',
            13 | 16 => byte == b':',
            19 => byte == b'Z',
            _ => byte.is_ascii_digit(),
        })
    {
        return false;
    }
    let number = |a, b| text[a..b].parse::<u32>().unwrap();
    let (year, month, day) = (number(0, 4), number(5, 7), number(8, 10));
    let days = match month {
        1 | 3 | 5 | 7 | 8 | 10 | 12 => 31,
        4 | 6 | 9 | 11 => 30,
        2 if year % 4 == 0 && (year % 100 != 0 || year % 400 == 0) => 29,
        2 => 28,
        _ => 0,
    };
    year > 0
        && day > 0
        && day <= days
        && number(11, 13) < 24
        && number(14, 16) < 60
        && number(17, 19) < 60
}
fn row(value: &Value) -> Result<(&str, u64, &str), CliError> {
    let fields = value.as_object().ok_or_else(failure)?;
    let keys = [
        "schemaVersion",
        "sessionId",
        "generation",
        "completedAtUtc",
        "expiresAtUtc",
        "sizeBytes",
        "pinned",
        "policyGeneration",
    ];
    if fields.len() != keys.len()
        || keys.iter().any(|key| !fields.contains_key(*key))
        || value["schemaVersion"] != "arkdeck.session/1"
        || !value["pinned"].is_boolean()
        || decimal(&value["sizeBytes"]).is_none()
        || decimal(&value["policyGeneration"]).is_none_or(|value| value == 0)
    {
        return Err(failure());
    }
    let id = value["sessionId"]
        .as_str()
        .filter(|id| valid_correlation(id))
        .ok_or_else(failure)?;
    let generation = decimal(&value["generation"]).ok_or_else(failure)?;
    let completed = value["completedAtUtc"]
        .as_str()
        .filter(|value| plain_date(value))
        .ok_or_else(failure)?;
    let expires = value["expiresAtUtc"]
        .as_str()
        .filter(|value| plain_date(value))
        .ok_or_else(failure)?;
    if expires <= completed {
        return Err(failure());
    }
    Ok((id, generation, completed))
}
pub fn validate_session_response(invocation: &Invocation, value: &Value) -> Result<(), CliError> {
    if invocation.command == "session.export.apply" {
        return export_result(value);
    }
    if invocation.command == "session.export.preview" {
        return export_preview(value);
    }
    if invocation.command == "session.cleanup.preview" {
        return cleanup_preview(value);
    }
    if invocation.command != "session.list" {
        if matches!(
            invocation.command,
            "session.show" | "session.pin" | "session.unpin"
        ) {
            row(value)?;
        }
        return Ok(());
    }
    let fields = value.as_object().ok_or_else(failure)?;
    let keys = [
        "schemaVersion",
        "pageKind",
        "items",
        "order",
        "snapshotRevision",
        "hasMore",
        "nextCursor",
    ];
    if fields.len() != keys.len()
        || keys.iter().any(|key| !fields.contains_key(*key))
        || value["schemaVersion"] != "arkdeck.cli.page/1"
        || value["pageKind"] != "snapshot"
        || value["order"] != "completedAtDescSessionIdAsc"
    {
        return Err(failure());
    }
    let revision = value["snapshotRevision"]
        .as_str()
        .filter(|value| uuid(value))
        .ok_or_else(failure)?;
    let items = value["items"].as_array().ok_or_else(failure)?;
    let size = invocation
        .params
        .as_ref()
        .and_then(|fields| fields.get("pageSize"))
        .and_then(Value::as_u64)
        .unwrap_or(100);
    if items.len() as u64 > size {
        return Err(failure());
    }
    match value["hasMore"].as_bool() {
        Some(true) => {
            let cursor = value["nextCursor"]
                .as_str()
                .filter(|value| value.len() <= 2048)
                .ok_or_else(failure)?;
            let (prefix, token) = cursor.split_once('.').ok_or_else(failure)?;
            if items.is_empty() || prefix != revision || !uuid(token) {
                return Err(failure());
            }
        }
        Some(false) if value["nextCursor"].is_null() => (),
        _ => return Err(failure()),
    }
    let mut prior = None;
    let mut ids = BTreeSet::new();
    for item in items {
        let current = row(item)?;
        if !ids.insert(current.0)
            || prior.is_some_and(|(id, generation, completed)| {
                generation != current.1
                    || completed < current.2
                    || (completed == current.2 && id >= current.0)
            })
        {
            return Err(failure());
        }
        prior = Some(current);
    }
    Ok(())
}

fn exact(value: &Value, keys: &[&str]) -> bool {
    value.as_object().is_some_and(|fields| {
        fields.len() == keys.len() && keys.iter().all(|key| fields.contains_key(*key))
    })
}
pub(super) fn digest(value: &Value) -> bool {
    value.as_str().is_some_and(|s| {
        s.len() == 64
            && s.bytes()
                .all(|b| b.is_ascii_digit() || (b'a'..=b'f').contains(&b))
    })
}
fn cleanup_preview(value: &Value) -> Result<(), CliError> {
    use arkdeck_contract::{canonical_json, sha256_hex};
    if !exact(
        value,
        &[
            "schemaVersion",
            "previewId",
            "previewDigest",
            "digestAlgorithm",
            "generation",
            "policyGeneration",
            "createdAtUtc",
            "expiresAtUtc",
            "confirmationRequired",
            "currentBytes",
            "projectedBytes",
            "safetyTargetBytes",
            "reclaimBytes",
            "blocksNewHeavyWriters",
            "sessions",
            "newDispatchCount",
        ],
    ) || value["schemaVersion"] != "arkdeck.session-cleanup-preview/1"
        || value["digestAlgorithm"] != "sha256-jcs"
        || value["confirmationRequired"] != true
        || value["newDispatchCount"] != 0
        || !value["previewId"].as_str().is_some_and(uuid)
        || !digest(&value["previewDigest"])
        || decimal(&value["generation"]).is_none()
        || decimal(&value["policyGeneration"]).is_none_or(|n| n == 0)
    {
        return Err(failure());
    }
    let created = value["createdAtUtc"]
        .as_str()
        .filter(|s| plain_date(s))
        .ok_or_else(failure)?;
    let expires = value["expiresAtUtc"]
        .as_str()
        .filter(|s| plain_date(s))
        .ok_or_else(failure)?;
    let current = decimal(&value["currentBytes"]).ok_or_else(failure)?;
    let projected = decimal(&value["projectedBytes"]).ok_or_else(failure)?;
    let target = decimal(&value["safetyTargetBytes"]).ok_or_else(failure)?;
    let reclaim = decimal(&value["reclaimBytes"]).ok_or_else(failure)?;
    if expires <= created
        || current.checked_sub(reclaim) != Some(projected)
        || value["blocksNewHeavyWriters"] != (projected > target)
    {
        return Err(failure());
    }
    let rows = value["sessions"].as_array().ok_or_else(failure)?;
    let mut prior = None;
    let mut reclaimed = 0_u64;
    for row in rows {
        if !exact(
            row,
            &[
                "sessionId",
                "disposition",
                "reason",
                "sizeBytes",
                "expiresAtUtc",
                "pinned",
                "activeLease",
                "artifacts",
            ],
        ) {
            return Err(failure());
        }
        let id = row["sessionId"]
            .as_str()
            .filter(|s| valid_correlation(s))
            .ok_or_else(failure)?;
        let disposition = row["disposition"].as_str().ok_or_else(failure)?;
        let reason = row["reason"].as_str().ok_or_else(failure)?;
        let size = decimal(&row["sizeBytes"]).ok_or_else(failure)?;
        let pinned = row["pinned"].as_bool().ok_or_else(failure)?;
        let active = row["activeLease"].as_bool().ok_or_else(failure)?;
        if prior.is_some_and(|prior| prior >= id)
            || !["reclaim", "retain"].contains(&disposition)
            || ![
                "activeLease",
                "pinned",
                "expiredQuotaPressure",
                "quotaPressure",
                "withinSafetyTarget",
            ]
            .contains(&reason)
            || !row["expiresAtUtc"].as_str().is_some_and(plain_date)
            || (disposition == "reclaim" && (pinned || active))
            || (reason == "activeLease" && !active)
            || (reason == "pinned" && (!pinned || active))
            || (["expiredQuotaPressure", "quotaPressure"].contains(&reason)
                && disposition != "reclaim")
        {
            return Err(failure());
        }
        prior = Some(id);
        if disposition == "reclaim" {
            reclaimed = reclaimed.checked_add(size).ok_or_else(failure)?;
        }
        let mut prior_artifact = None;
        for artifact in row["artifacts"].as_array().ok_or_else(failure)? {
            if !exact(
                artifact,
                &[
                    "artifactId",
                    "artifactDigest",
                    "byteCount",
                    "role",
                    "privacy",
                ],
            ) {
                return Err(failure());
            }
            let id = artifact["artifactId"]
                .as_str()
                .filter(|s| valid_correlation(s))
                .ok_or_else(failure)?;
            let role = artifact["role"].as_str().ok_or_else(failure)?;
            let privacy = artifact["privacy"].as_str().ok_or_else(failure)?;
            if prior_artifact.is_some_and(|prior| prior >= id)
                || !digest(&artifact["artifactDigest"])
                || decimal(&artifact["byteCount"]).is_none()
                || !["raw", "derived", "log", "plan", "diagnostic", "partial"].contains(&role)
                || !["sensitive", "unknown"].contains(&privacy)
                || (["raw", "partial"].contains(&role) && privacy != "sensitive")
            {
                return Err(failure());
            }
            prior_artifact = Some(id);
        }
    }
    let mut unsigned = value.clone();
    unsigned
        .as_object_mut()
        .ok_or_else(failure)?
        .remove("previewDigest");
    if reclaimed != reclaim
        || value["previewDigest"] != sha256_hex(&canonical_json(&unsigned).map_err(|_| failure())?)
    {
        return Err(failure());
    }
    Ok(())
}

#[cfg(test)]
mod cleanup_tests {
    use super::*;
    use arkdeck_contract::{canonical_json, sha256_hex};
    use serde_json::json;
    fn sign(mut value: Value) -> Value {
        value.as_object_mut().unwrap().remove("previewDigest");
        value["previewDigest"] = json!(sha256_hex(&canonical_json(&value).unwrap()));
        value
    }
    fn preview() -> Value {
        sign(
            json!({"schemaVersion":"arkdeck.session-cleanup-preview/1","previewId":"00000000-0000-0000-0000-000000000001",
            "digestAlgorithm":"sha256-jcs","generation":"0","policyGeneration":"1",
            "createdAtUtc":"2026-09-11T00:00:00Z","expiresAtUtc":"2026-09-11T00:10:00Z","confirmationRequired":true,
            "currentBytes":"10","projectedBytes":"0","safetyTargetBytes":"1","reclaimBytes":"10","blocksNewHeavyWriters":false,
            "sessions":[{"sessionId":"s1","disposition":"reclaim","reason":"quotaPressure","sizeBytes":"10",
                "expiresAtUtc":"2026-09-12T00:00:00Z","pinned":false,"activeLease":false,
                "artifacts":[{"artifactId":"a1","artifactDigest":"a".repeat(64),"byteCount":"1","role":"raw","privacy":"sensitive"}]}],"newDispatchCount":0}),
        )
    }
    #[test]
    fn checks_digest_even_when_the_wire_shape_is_valid() {
        let mut value = preview();
        assert!(cleanup_preview(&value).is_ok());
        value["sessions"][0]["artifacts"][0]["artifactDigest"] = json!("b".repeat(64));
        assert_eq!(
            cleanup_preview(&value).unwrap_err().code,
            "recordUnreadable"
        );
    }
    #[test]
    fn signed_but_inconsistent_or_unsafe_previews_are_refused() {
        let mut pinned = preview();
        pinned["sessions"][0]["pinned"] = json!(true);
        let mut active = preview();
        active["sessions"][0]["activeLease"] = json!(true);
        let mut privacy = preview();
        privacy["sessions"][0]["artifacts"][0]["privacy"] = json!("unknown");
        let mut totals = preview();
        totals["reclaimBytes"] = json!("11");
        let mut duplicate = preview();
        let row = duplicate["sessions"][0].clone();
        duplicate["sessions"].as_array_mut().unwrap().push(row);
        let mut dates = preview();
        dates["expiresAtUtc"] = json!("2026-09-11T00:00:00Z");
        for value in [pinned, active, privacy, totals, duplicate, dates] {
            assert_eq!(
                cleanup_preview(&sign(value)).unwrap_err().code,
                "recordUnreadable"
            );
        }
    }
}

fn export_preview(value: &Value) -> Result<(), CliError> {
    use arkdeck_contract::{canonical_json, sha256_hex};
    if !exact(
        value,
        &[
            "schemaVersion",
            "previewId",
            "previewDigest",
            "digestAlgorithm",
            "sessionId",
            "generation",
            "policyGeneration",
            "createdAtUtc",
            "expiresAtUtc",
            "confirmationRequired",
            "allowSensitive",
            "sensitiveDefaultExcluded",
            "deviceIdentifierPolicy",
            "estimatedBytes",
            "destination",
            "source",
            "catalogStatus",
            "artifacts",
            "newDispatchCount",
        ],
    ) || value["schemaVersion"] != "arkdeck.session-export-preview/1"
        || value["digestAlgorithm"] != "sha256-jcs"
        || value["confirmationRequired"] != true
        || value["sensitiveDefaultExcluded"] != true
        || value["deviceIdentifierPolicy"] != "redact"
        || value["newDispatchCount"] != 0
        || !value["previewId"].as_str().is_some_and(uuid)
        || !digest(&value["previewDigest"])
        || !value["sessionId"].as_str().is_some_and(valid_correlation)
        || decimal(&value["generation"]).is_none()
        || decimal(&value["policyGeneration"]).is_none_or(|n| n == 0)
    {
        return Err(failure());
    }
    let created = value["createdAtUtc"]
        .as_str()
        .filter(|s| plain_date(s))
        .ok_or_else(failure)?;
    let expires = value["expiresAtUtc"]
        .as_str()
        .filter(|s| plain_date(s))
        .ok_or_else(failure)?;
    let allow = value["allowSensitive"].as_bool().ok_or_else(failure)?;
    let estimated = decimal(&value["estimatedBytes"]).ok_or_else(failure)?;
    let dest = &value["destination"];
    if expires <= created
        || !exact(
            dest,
            &[
                "path",
                "parentDevice",
                "parentInode",
                "volumeIdentity",
                "expectedState",
            ],
        )
        || !dest["path"].as_str().is_some_and(|s| s.starts_with('/'))
        || decimal(&dest["parentDevice"]).is_none()
        || decimal(&dest["parentInode"]).is_none()
        || !dest["volumeIdentity"]
            .as_str()
            .is_some_and(|s| !s.is_empty())
        || dest["expectedState"] != "absent"
    {
        return Err(failure());
    }
    export_source(&value["source"])?;
    export_catalog(&value["catalogStatus"])?;
    let mut prior = None;
    let mut included = 0_u64;
    for artifact in value["artifacts"].as_array().ok_or_else(failure)? {
        if !exact(
            artifact,
            &[
                "artifactId",
                "artifactDigest",
                "byteCount",
                "role",
                "privacy",
                "disposition",
                "transformation",
            ],
        ) {
            return Err(failure());
        }
        let id = artifact["artifactId"]
            .as_str()
            .filter(|s| valid_correlation(s))
            .ok_or_else(failure)?;
        let bytes = decimal(&artifact["byteCount"]).ok_or_else(failure)?;
        let role = artifact["role"].as_str().ok_or_else(failure)?;
        let privacy = artifact["privacy"].as_str().ok_or_else(failure)?;
        let disposition = artifact["disposition"].as_str().ok_or_else(failure)?;
        if prior.is_some_and(|p| p >= id)
            || !digest(&artifact["artifactDigest"])
            || !["raw", "derived", "log", "plan", "diagnostic", "partial"].contains(&role)
            || !["sensitive", "unknown"].contains(&privacy)
            || (["raw", "partial"].contains(&role) != (privacy == "sensitive"))
            || !["include", "excludeByDefault"].contains(&disposition)
            || ((disposition == "include")
                != (artifact["transformation"] == "redactDeviceIdentifiers"))
            || ((disposition == "excludeByDefault") != (artifact["transformation"] == "excluded"))
            || ((disposition == "include") != (allow || privacy != "sensitive"))
        {
            return Err(failure());
        }
        prior = Some(id);
        if disposition == "include" {
            included = included.checked_add(bytes).ok_or_else(failure)?;
        }
    }
    let mut unsigned = value.clone();
    unsigned
        .as_object_mut()
        .ok_or_else(failure)?
        .remove("previewDigest");
    if included > estimated
        || value["previewDigest"] != sha256_hex(&canonical_json(&unsigned).map_err(|_| failure())?)
    {
        return Err(failure());
    }
    Ok(())
}

#[cfg(test)]
mod export_tests {
    use super::*;
    use arkdeck_contract::{canonical_json, sha256_hex};
    use serde_json::json;
    fn preview() -> Value {
        let record: Value = serde_json::from_str(include_str!(
            "../../../tests/fixtures/session-export/rust-export-ready.json"
        ))
        .unwrap();
        record["preview"].clone()
    }
    fn sign(mut value: Value) -> Value {
        value.as_object_mut().unwrap().remove("previewDigest");
        value["previewDigest"] = json!(sha256_hex(&canonical_json(&value).unwrap()));
        value
    }
    #[test]
    fn accepts_actual_owner_record_and_rejects_tampering() {
        let mut value = preview();
        assert!(export_preview(&value).is_ok());
        value["source"]["manifestSha256"] = json!("f".repeat(64));
        assert!(export_preview(&value).is_err());
    }
    #[test]
    fn rejects_signed_invalid_source_accounting_and_privacy() {
        for (pointer, replacement) in [
            ("/source/journalSha256", json!("bad")),
            ("/source/rootInode", json!("01")),
            ("/catalogStatus/complete", json!(false)),
            ("/catalogStatus/unaccountedSessionCount", json!("1")),
            ("/destination/expectedState", json!("present")),
            ("/allowSensitive", json!(true)),
            ("/artifacts/0/privacy", json!("unknown")),
            (
                "/artifacts/0/transformation",
                json!("redactDeviceIdentifiers"),
            ),
            ("/expiresAtUtc", json!("2000-01-01T00:00:00Z")),
        ] {
            let mut value = preview();
            *value.pointer_mut(pointer).unwrap() = replacement;
            assert!(export_preview(&sign(value)).is_err(), "{pointer}");
        }
        let mut value = preview();
        let duplicate = value["artifacts"][0].clone();
        value["artifacts"].as_array_mut().unwrap().push(duplicate);
        assert!(export_preview(&sign(value)).is_err());
    }
}

fn export_source(source: &Value) -> Result<(), CliError> {
    if !exact(
        source,
        &[
            "jobId",
            "manifestSha256",
            "journalSha256",
            "rootDevice",
            "rootInode",
            "volumeIdentity",
            "sessionDevice",
            "sessionInode",
        ],
    ) || !source["jobId"].as_str().is_some_and(valid_correlation)
        || !digest(&source["manifestSha256"])
        || !(source["journalSha256"].is_null() || digest(&source["journalSha256"]))
        || ["rootDevice", "rootInode", "sessionDevice", "sessionInode"]
            .iter()
            .any(|key| decimal(&source[*key]).is_none())
        || !source["volumeIdentity"]
            .as_str()
            .is_some_and(|s| !s.is_empty())
    {
        return Err(failure());
    }
    Ok(())
}

fn export_catalog(status: &Value) -> Result<(), CliError> {
    if !exact(
        status,
        &[
            "complete",
            "unaccountedSessionCount",
            "measurementIncomplete",
            "usedBytes",
            "blocker",
        ],
    ) || decimal(&status["usedBytes"]).is_none()
    {
        return Err(failure());
    }
    let complete = status["complete"].as_bool().ok_or_else(failure)?;
    let incomplete = status["measurementIncomplete"]
        .as_bool()
        .ok_or_else(failure)?;
    let unaccounted = decimal(&status["unaccountedSessionCount"]).ok_or_else(failure)?;
    if complete == incomplete
        || if complete {
            unaccounted != 0 || !status["blocker"].is_null()
        } else {
            unaccounted == 0 || status["blocker"] != "unaccountedSessionContent"
        }
    {
        return Err(failure());
    }
    Ok(())
}

fn export_result(value: &Value) -> Result<(), CliError> {
    if !exact(
        value,
        &[
            "schemaVersion",
            "previewId",
            "previewDigest",
            "sessionId",
            "generation",
            "resultGeneration",
            "publishedAtUtc",
            "exportedPath",
            "source",
            "catalogStatus",
            "sourceArtifactIds",
            "excludedArtifactIds",
            "deviceIdentifierPolicy",
            "evidenceClass",
            "newDispatchCount",
        ],
    ) || value["schemaVersion"] != "arkdeck.session-export-result/1"
        || !value["previewId"].as_str().is_some_and(uuid)
        || !digest(&value["previewDigest"])
        || !value["sessionId"].as_str().is_some_and(valid_correlation)
        || !value["publishedAtUtc"].as_str().is_some_and(plain_date)
        || !value["exportedPath"]
            .as_str()
            .is_some_and(|s| s.starts_with('/'))
        || value["deviceIdentifierPolicy"] != "redact"
        || value["evidenceClass"] != "derivedExport"
        || value["newDispatchCount"] != 0
    {
        return Err(failure());
    }
    let generation = decimal(&value["generation"]).ok_or_else(failure)?;
    if decimal(&value["resultGeneration"]).is_none_or(|n| n < generation) {
        return Err(failure());
    }
    export_source(&value["source"])?;
    export_catalog(&value["catalogStatus"])?;
    let mut all = BTreeSet::new();
    for key in ["sourceArtifactIds", "excludedArtifactIds"] {
        let mut prior = None;
        for id in value[key].as_array().ok_or_else(failure)? {
            let id = id
                .as_str()
                .filter(|s| valid_correlation(s))
                .ok_or_else(failure)?;
            if prior.is_some_and(|p| p >= id) || !all.insert(id) {
                return Err(failure());
            }
            prior = Some(id);
        }
    }
    Ok(())
}

#[cfg(test)]
mod export_result_tests {
    use super::*;
    use serde_json::json;
    fn actual() -> Value {
        let record: Value = serde_json::from_str(include_str!(
            "../../../tests/fixtures/session-export/rust-export-applied.json"
        ))
        .unwrap();
        record["result"].clone()
    }
    #[test]
    fn actual_result_is_accepted_but_inconsistent_context_is_refused() {
        assert!(export_result(&actual()).is_ok());
        for (pointer, replacement) in [
            ("/generation", json!("2")),
            ("/publishedAtUtc", json!("2026-02-30T00:00:00Z")),
            ("/source/jobId", json!("../invalid")),
            ("/source/journalSha256", json!("bad")),
            ("/catalogStatus/complete", json!(true)),
            ("/exportedPath", json!("relative")),
            ("/sourceArtifactIds", json!(["z", "a"])),
            ("/newDispatchCount", json!(1)),
        ] {
            let mut value = actual();
            *value.pointer_mut(pointer).unwrap() = replacement;
            assert!(export_result(&value).is_err(), "{pointer}");
        }
    }
    #[test]
    fn included_excluded_overlap_is_never_emitted_as_a_valid_result() {
        let mut value = actual();
        value["sourceArtifactIds"] = json!(["artifact-raw"]);
        assert!(export_result(&value).is_err());
    }
}
