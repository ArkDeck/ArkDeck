//! Strict presentation-only Target and observation-name consumers.
use crate::{CliError, Invocation};
use arkdeck_client::ClientError;
use serde_json::{Map, Value};
pub(crate) fn is_mutation(method: &str) -> bool {
    matches!(
        method,
        "target.display-name.set"
            | "target.display-name.clear"
            | "device.display-name.set"
            | "device.display-name.clear"
    )
}
fn identifier(s: &str) -> bool {
    crate::valid_correlation(s) && !s.contains(':')
}
fn positive(v: &Value) -> Option<u64> {
    let s = v.as_str()?;
    s.parse::<u64>()
        .ok()
        .filter(|n| (1..=i64::MAX as u64).contains(n) && n.to_string() == s)
}
fn text(s: &str) -> bool {
    #[cfg(target_os = "macos")]
    {
        (1..=256).contains(&s.len())
            && s.chars()
                .next()
                .is_some_and(|c| !arkdeck_platform::host_whitespace_or_newline(c))
            && s.chars()
                .next_back()
                .is_some_and(|c| !arkdeck_platform::host_whitespace_or_newline(c))
            && !s.chars().any(arkdeck_platform::host_control_character)
    }
    #[cfg(not(target_os = "macos"))]
    {
        (1..=256).contains(&s.len()) && s.trim() == s && !s.chars().any(char::is_control)
    }
}
pub(crate) fn configure(
    command: &str,
    fields: &mut Map<String, Value>,
    help: bool,
) -> Result<Option<u64>, CliError> {
    if help || !(command.starts_with("target.") || command.starts_with("device.display-name.")) {
        return Ok(None);
    }
    let timeout = fields
        .remove("timeout")
        .map(|v| {
            v.as_str()
                .and_then(crate::read_only_resources::duration)
                .ok_or_else(|| {
                    CliError::new("invalidOption", "Target timeout must be a bounded duration")
                })
        })
        .transpose()?;
    let required: &[&str] = match command {
        "target.list" => &[],
        "target.show" => &["targetId"],
        "target.display-name.set" => &["targetId", "expectedGeneration", "name"],
        "target.display-name.clear" => &["targetId", "expectedGeneration"],
        "device.display-name.set" => &[
            "candidate",
            "observationId",
            "observationGeneration",
            "name",
        ],
        "device.display-name.clear" => &["candidate", "observationId", "observationGeneration"],
        _ => {
            return Err(CliError::new(
                "invalidCommand",
                "Unsupported Target presentation command",
            ));
        }
    };
    if required.iter().any(|k| !fields.contains_key(*k)) {
        return Err(CliError::new(
            "invalidOption",
            "Target command requires its exact identity, generation and name options",
        ));
    }
    if fields
        .get("targetId")
        .is_some_and(|v| !v.as_str().is_some_and(identifier))
        || ["expectedGeneration", "observationGeneration"]
            .iter()
            .any(|k| fields.get(*k).is_some_and(|v| positive(v).is_none()))
        || fields
            .get("name")
            .is_some_and(|v| !v.as_str().is_some_and(text))
        || [("candidate", 1024), ("observationId", 128)]
            .iter()
            .any(|(k, max)| {
                fields
                    .get(*k)
                    .is_some_and(|v| !v.as_str().is_some_and(|s| (1..=*max).contains(&s.len())))
            })
    {
        return Err(CliError::new(
            "invalidInput",
            "Target command contains an invalid identity, generation or display name",
        ));
    }
    Ok(timeout)
}
pub(crate) fn client_error(error: ClientError, method: &str) -> CliError {
    if matches!(
        error,
        ClientError::Transport(_) | ClientError::ConnectionUnusable | ClientError::Contract(_)
    ) {
        return CliError::new(
            "outcomeUnknown",
            "Display-name response is unconfirmed; read current state before another update; no request was replayed",
        );
    }
    let ClientError::Remote(error) = error else {
        unreachable!()
    };
    let phase = if method.starts_with("target.") {
        "targetDisplayNameOwner"
    } else {
        "candidateDisplayNameOwner"
    };
    let proof = error.details.as_ref().is_some_and(|d| {
        d.get("phase").and_then(Value::as_str) == Some(phase)
            && d.get("newDispatchCount") == Some(&Value::from(0))
    });
    let code = match error.code.as_str() {
        "invalidParams" => "invalidInput",
        "notFound" => "resourceNotFound",
        "conflict" => "resourceConflict",
        "recordUnreadable" => "recordUnreadable",
        "resourceConflict" if proof => "resourceConflict",
        "resourceNotFound" if proof => "resourceNotFound",
        "invalidInput" if proof => "invalidInput",
        "quotaExceeded" if proof => "quotaExceeded",
        "ioFailure" if proof => "ioFailure",
        "outcomeUnknown" if proof => "outcomeUnknown",
        "operationUnavailable" if proof => "operationUnavailable",
        _ => "internalError",
    };
    let mut result = CliError::new(code, error.message);
    if let Some(details) = error.details {
        result.details = details;
    }
    result
}
fn exact(v: &Value, keys: &[&str]) -> bool {
    v.as_object()
        .is_some_and(|m| m.len() == keys.len() && keys.iter().all(|k| m.contains_key(*k)))
}
fn name(v: &Value) -> bool {
    v.is_null() || v.as_str().is_some_and(text)
}
fn timestamp(v: &Value) -> bool {
    v.as_str().is_some_and(|s| {
        s.len() >= 20 && s.len() <= 40 && s.contains('T') && (s.ends_with('Z') || s.contains('+'))
    })
}
fn row(v: &Value) -> bool {
    v["targetId"].as_str().is_some_and(identifier)
        && v["bindingRevision"].as_i64().is_some_and(|n| n > 0)
        && v["toolVersion"].as_str().is_some_and(|s| s.len() <= 4096)
        && timestamp(&v["adoptedAtUtc"])
        && positive(&v["displayNameGeneration"]).is_some()
        && name(&v["displayName"])
}
pub fn validate_target_response(invocation: &Invocation, value: &Value) -> Result<(), CliError> {
    let method = invocation.method;
    if !(method.starts_with("target.") || method.starts_with("device.display-name.")) {
        return Ok(());
    }
    let invalid = || {
        CliError::new(
            if is_mutation(method) {
                "outcomeUnknown"
            } else {
                "recordUnreadable"
            },
            "Runtime returned an invalid Target presentation resource; no request was replayed",
        )
    };
    let params = invocation.params.as_ref().ok_or_else(invalid)?;
    let valid = if method == "target.list" {
        value.as_array().is_some_and(|rows| {
            rows.len() <= 4096
                && rows.iter().all(|v| {
                    exact(
                        v,
                        &[
                            "targetId",
                            "bindingRevision",
                            "toolVersion",
                            "adoptedAtUtc",
                            "displayName",
                            "displayNameGeneration",
                        ],
                    ) && row(v)
                })
                && rows
                    .iter()
                    .filter_map(|v| v["targetId"].as_str())
                    .collect::<std::collections::BTreeSet<_>>()
                    .len()
                    == rows.len()
        })
    } else if method == "target.show" {
        exact(
            value,
            &[
                "schemaVersion",
                "targetId",
                "stablePhysicalIdentitySha256",
                "bindingRevision",
                "connectKey",
                "toolVersion",
                "adoptedAtUtc",
                "displayName",
                "displayNameGeneration",
                "live",
                "observedFacts",
            ],
        ) && value["schemaVersion"] == "arkdeck.target/1"
            && value["targetId"] == params["targetId"]
            && row(value)
            && crate::session_resources::digest(&value["stablePhysicalIdentitySha256"])
            && value["connectKey"]
                .as_str()
                .is_some_and(|s| (1..=1024).contains(&s.len()))
            && (value["live"].is_null()
                || exact(
                    &value["live"],
                    &["state", "observedAtUtc", "observationHealth"],
                ) && value["live"]["state"].is_string()
                    && timestamp(&value["live"]["observedAtUtc"])
                    && value["live"]["observationHealth"].is_string())
            && (value["observedFacts"].is_null()
                || exact(
                    &value["observedFacts"],
                    &[
                        "targetId",
                        "model",
                        "firmware",
                        "transport",
                        "confirmedAtUtc",
                    ],
                ) && value["observedFacts"]["targetId"] == params["targetId"]
                    && ["model", "firmware", "transport"].iter().all(|k| {
                        value["observedFacts"][*k].is_null()
                            || value["observedFacts"][*k].is_string()
                    })
                    && (value["observedFacts"]["confirmedAtUtc"].is_null()
                        || timestamp(&value["observedFacts"]["confirmedAtUtc"])))
    } else {
        let target = method.starts_with("target.");
        let generation_key = if target {
            "expectedGeneration"
        } else {
            "observationGeneration"
        };
        let keys: &[&str] = if target {
            &[
                "schemaVersion",
                "targetId",
                "generation",
                "name",
                "updatedAtUtc",
            ]
        } else {
            &[
                "schemaVersion",
                "candidateKey",
                "observationId",
                "generation",
                "name",
                "updatedAtUtc",
            ]
        };
        exact(value, keys)
            && value["schemaVersion"]
                == if target {
                    "arkdeck.target-display-name/1"
                } else {
                    "arkdeck.candidate-display-name/1"
                }
            && positive(&params[generation_key]).and_then(|n| n.checked_add(1))
                == positive(&value["generation"])
            && timestamp(&value["updatedAtUtc"])
            && name(&value["name"])
            && if target {
                value["targetId"] == params["targetId"]
            } else {
                value["candidateKey"] == params["candidate"]
                    && value["observationId"] == params["observationId"]
            }
            && if method.ends_with(".set") {
                value["name"] == params["name"]
            } else {
                value["name"].is_null()
            }
    };
    if valid { Ok(()) } else { Err(invalid()) }
}

#[cfg(test)]
mod tests {
    use super::*;
    use serde_json::json;
    fn invocation(args: &[&str]) -> Invocation {
        crate::parse(&args.iter().map(|s| s.to_string()).collect::<Vec<_>>()).unwrap()
    }
    #[test]
    fn exact_target_and_candidate_options_map_to_current_methods() {
        for (args, method) in [
            (vec!["target", "list"], "target.list"),
            (
                vec!["target", "show", "--target", "target-a"],
                "target.show",
            ),
            (
                vec![
                    "target",
                    "display-name",
                    "set",
                    "--target",
                    "target-a",
                    "--expected-generation",
                    "1",
                    "--name",
                    "Bench",
                ],
                "target.display-name.set",
            ),
            (
                vec![
                    "device",
                    "display-name",
                    "clear",
                    "--candidate",
                    "serial",
                    "--observation",
                    "obs-a",
                    "--observation-generation",
                    "4",
                ],
                "device.display-name.clear",
            ),
        ] {
            assert_eq!(invocation(&args).method, method);
        }
        let parsed = invocation(&[
            "device",
            "display-name",
            "set",
            "--candidate",
            "serial",
            "--observation",
            "obs-a",
            "--observation-generation",
            "4",
            "--name",
            "Bench",
            "--timeout",
            "2s",
        ]);
        assert_eq!(parsed.params.unwrap(),json!({"candidate":"serial","observationId":"obs-a","observationGeneration":"4","name":"Bench"}).as_object().unwrap().clone());
        assert_eq!(parsed.timeout_ms, Some(2000));
    }
    #[test]
    fn stale_generation_missing_identity_extra_facts_and_bad_names_are_rejected_locally() {
        for args in [
            vec!["target", "show"],
            vec![
                "target",
                "display-name",
                "set",
                "--target",
                "target-a",
                "--expected-generation",
                "01",
                "--name",
                "Bench",
            ],
            vec![
                "device",
                "display-name",
                "clear",
                "--candidate",
                "serial",
                "--observation",
                "obs-a",
            ],
            vec![
                "target",
                "display-name",
                "set",
                "--target",
                "target-a",
                "--expected-generation",
                "1",
                "--name",
                " bad",
            ],
            vec!["target", "list", "--name", "fake"],
        ] {
            assert!(crate::parse(&args.iter().map(|s| s.to_string()).collect::<Vec<_>>()).is_err());
        }
    }
    #[test]
    fn name_receipts_must_match_exact_resource_tuple_and_next_generation() {
        let invocation = invocation(&[
            "target",
            "display-name",
            "set",
            "--target",
            "target-a",
            "--expected-generation",
            "1",
            "--name",
            "Bench",
        ]);
        let value = json!({"schemaVersion":"arkdeck.target-display-name/1","targetId":"target-a","generation":"2","name":"Bench","updatedAtUtc":"2026-09-12T00:00:00Z"});
        assert!(validate_target_response(&invocation, &value).is_ok());
        for (key, replacement) in [
            ("targetId", json!("target-b")),
            ("generation", json!("3")),
            ("name", Value::Null),
            ("updatedAtUtc", json!("not-a-date")),
        ] {
            let mut bad = value.clone();
            bad[key] = replacement;
            assert_eq!(
                validate_target_response(&invocation, &bad)
                    .unwrap_err()
                    .code,
                "outcomeUnknown"
            );
        }
    }
    #[test]
    fn candidate_clear_receipt_is_bound_and_lost_reply_is_never_retryable() {
        let invocation = invocation(&[
            "device",
            "display-name",
            "clear",
            "--candidate",
            "serial",
            "--observation",
            "obs-a",
            "--observation-generation",
            "4",
        ]);
        let value = json!({"schemaVersion":"arkdeck.candidate-display-name/1","candidateKey":"serial","observationId":"obs-a","generation":"5","name":null,"updatedAtUtc":"2026-09-12T00:00:00Z"});
        assert!(validate_target_response(&invocation, &value).is_ok());
        let error = CliError::from_client(
            ClientError::Transport(std::io::Error::from(std::io::ErrorKind::TimedOut)),
            invocation.method,
        );
        assert_eq!(error.code, "outcomeUnknown");
        let envelope = crate::failure_envelope(invocation.command, &error, "ctl-a", true);
        assert_eq!(envelope["error"]["controlRequestRetryable"], false);
        let mut bad = value;
        bad["observationId"] = json!("obs-b");
        assert_eq!(
            validate_target_response(&invocation, &bad)
                .unwrap_err()
                .code,
            "outcomeUnknown"
        );
    }
}
