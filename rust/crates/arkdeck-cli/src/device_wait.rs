//! `device wait` — Swift `RuntimeCLI.emitDeviceWait`.
//!
//! Unary polling is deliberately not an event stream: every read asks the
//! Runtime to prove the original observation lifecycle again, even when the
//! requested state already matched the caller's earlier discovery snapshot. The
//! wait never adopts, never follows a replacement, and never cancels anything.
use crate::CliError;
use serde_json::{Map, Value, json};

/// The three authorization states this leaf waits for, spelled as the caller
/// spells them and as the Runtime's provider answers them.
const STATES: &[(&str, &str)] = &[
    ("connected", "Connected"),
    ("unauthorized", "Unauthorized"),
    ("offline", "Offline"),
];

const SNAPSHOT_KEYS: &[&str] = &[
    "health",
    "observations",
    "observedAtUtc",
    "schemaVersion",
    "snapshotGeneration",
];

const ROW_KEYS: &[&str] = &[
    "adoptedTargetId",
    "authorizationState",
    "bindingRevision",
    "candidateKey",
    "deviceInformation",
    "displayName",
    "displayNameGeneration",
    "observationContinuity",
    "observationId",
    "observedFacts",
];

/// The registry's grammar for this leaf, then the wire shape Swift sends: the
/// exact observation to follow, as strings, and the client's own bound.
///
/// Swift's handler re-checks all of it in one guard
/// (`device wait requires an exact observation, state and bounded timeout`);
/// through the registry that guard is unreachable, because the same four
/// options are required there and carry these grammars.
pub(super) fn configure(fields: &mut Map<String, Value>) -> Result<Option<u64>, CliError> {
    let refused = || {
        CliError::new(
            "invalidOption",
            "device wait requires an exact observation, state and bounded timeout",
        )
    };
    let text = |fields: &Map<String, Value>, key: &str| {
        fields
            .get(key)
            .and_then(Value::as_str)
            .map(str::to_owned)
            .ok_or_else(refused)
    };
    let candidate = text(fields, "candidate")?;
    let observation = text(fields, "observationId")?;
    let generation = text(fields, "observationGeneration")?;
    // The generation is sent as the caller wrote it and read back as a number.
    generation
        .parse::<i64>()
        .ok()
        .filter(|number| *number > 0 && number.to_string() == generation)
        .ok_or_else(refused)?;
    let state = text(fields, "state")?;
    if !STATES.iter().any(|(caller, _)| *caller == state) {
        return Err(refused());
    }
    let timeout = fields
        .remove("timeout")
        .unwrap_or_else(|| json!("30s"))
        .as_str()
        .and_then(crate::read_only_resources::duration)
        .ok_or_else(refused)?;
    fields.clear();
    fields.insert(
        "following".to_owned(),
        json!({"candidate": candidate, "observationId": observation,
            "observationGeneration": generation}),
    );
    fields.insert("state".to_owned(), json!(state));
    Ok(Some(timeout))
}

/// The request this leaf repeats, and the state it waits for: the parse keeps
/// the caller's state beside the wire parameters, which the request never
/// carries.
pub fn wait_request(params: &Map<String, Value>) -> (Map<String, Value>, String, String) {
    let mut request = params.clone();
    let state = request
        .remove("state")
        .and_then(|value| value.as_str().map(str::to_owned))
        .unwrap_or_default();
    let provider = STATES
        .iter()
        .find(|(caller, _)| *caller == state)
        .map_or(String::new(), |(_, provider)| (*provider).to_owned());
    (request, state, provider)
}

fn malformed(message: &str) -> CliError {
    CliError::new("protocolMalformed", message)
}

/// One snapshot, checked as Swift checks it before anything is read from it.
/// `last` is the generation the previous read proved, or the caller's own.
///
/// Answers the proved row and the snapshot's generation and timestamp.
pub fn proved_row(
    snapshot: &Value,
    following: &Value,
    last: i64,
) -> Result<(Map<String, Value>, i64, String), CliError> {
    let reference = || {
        let mut error = CliError::new(
            "resourceConflict",
            "the Runtime did not prove the original device observation lifecycle",
        );
        for (key, value) in following.as_object().cloned().unwrap_or_default() {
            error.details.insert(key, value);
        }
        error
    };
    let fields = snapshot
        .as_object()
        .filter(|fields| {
            fields.len() == SNAPSHOT_KEYS.len()
                && SNAPSHOT_KEYS.iter().all(|key| fields.contains_key(*key))
        })
        .ok_or_else(|| malformed("the Runtime returned an invalid device observation snapshot"))?;
    let observed_at = fields["observedAtUtc"].as_str().unwrap_or_default();
    let generation = fields["snapshotGeneration"]
        .as_str()
        .and_then(|text| text.parse::<i64>().ok().filter(|n| n.to_string() == text));
    let rows = fields["observations"].as_array();
    let Some(generation) = generation.filter(|number| *number >= last) else {
        return Err(malformed(
            "the Runtime returned an invalid device observation snapshot",
        ));
    };
    if fields["schemaVersion"] != "arkdeck.device-observations/1"
        || fields["health"] != "current"
        || observed_at.is_empty()
        || !rows.is_some_and(|rows| rows.len() <= 1000)
    {
        return Err(malformed(
            "the Runtime returned an invalid device observation snapshot",
        ));
    }
    let candidate = &following["candidate"];
    let observation = &following["observationId"];
    let mut matches = rows
        .unwrap_or(&Vec::new())
        .iter()
        .filter(|row| row["candidateKey"] == *candidate && row["observationId"] == *observation)
        .cloned()
        .collect::<Vec<_>>();
    if matches.len() != 1 {
        return Err(reference());
    }
    let row = matches
        .pop()
        .and_then(|row| row.as_object().cloned())
        .ok_or_else(reference)?;
    if row.len() != ROW_KEYS.len()
        || !ROW_KEYS.iter().all(|key| row.contains_key(*key))
        || row["observationContinuity"] != "relationProven"
        || row["displayNameGeneration"] != json!(generation.to_string())
    {
        return Err(reference());
    }
    if !row["authorizationState"]
        .as_str()
        .is_some_and(|state| STATES.iter().any(|(_, provider)| *provider == state))
    {
        return Err(malformed(
            "the observation has no supported authorization state",
        ));
    }
    let adopted = (&row["adoptedTargetId"], &row["bindingRevision"]);
    let linked = match adopted {
        (Value::Null, Value::Null) => true,
        (target, revision) => {
            target.as_str().is_some_and(|text| !text.is_empty())
                && revision.as_i64().is_some_and(|number| number > 0)
        }
    };
    if !linked {
        return Err(malformed(
            "the observation has an invalid adopted-target link",
        ));
    }
    let named = match &row["displayName"] {
        Value::Null => true,
        Value::String(name) => canonical_name(name),
        _ => false,
    };
    if !named {
        return Err(malformed(
            "the observation has an invalid candidate display name",
        ));
    }
    Ok((row, generation, observed_at.to_owned()))
}

/// A candidate display name as the Runtime must publish it: precomposed,
/// trimmed, 1…256 UTF-8 bytes and free of control characters.
fn canonical_name(name: &str) -> bool {
    #[cfg(target_os = "macos")]
    let precomposed =
        arkdeck_platform::host_canonical_text(name).is_some_and(|canonical| canonical == name);
    // The precomposition is the host's own: off macOS this build has no
    // canonical mapping, and the remaining three checks stand alone.
    #[cfg(not(target_os = "macos"))]
    let precomposed = true;
    precomposed && crate::target_resources::display_name(name)
}

/// The one document this leaf emits, once the state it waited for is proved.
pub fn wait_document(
    row: Map<String, Value>,
    generation: i64,
    observed_at: &str,
    state: &str,
) -> Value {
    json!({"schemaVersion":"arkdeck.device-wait/1","snapshotGeneration":generation.to_string(),
        "observedAtUtc":observed_at,"state":state,"observation":row})
}

/// Swift `deviceWaitTimeout`: the client stopped waiting, and says plainly
/// that nothing was adopted and nothing was cancelled.
pub fn wait_timeout(following: &Value, state: &str, last: Option<i64>) -> CliError {
    let mut error = CliError::new(
        "clientTimeout",
        "stopped waiting for the exact device observation; no adoption or cancellation was requested",
    );
    for (key, value) in following.as_object().cloned().unwrap_or_default() {
        error.details.insert(key, value);
    }
    error.details.insert("requestedState".into(), json!(state));
    if let Some(last) = last {
        error
            .details
            .insert("lastObservedGeneration".into(), json!(last.to_string()));
    }
    error.details.insert("newDispatchCount".into(), json!(0));
    error
}

#[cfg(test)]
mod tests {
    use super::*;

    fn following() -> Value {
        json!({"candidate":"c","observationId":"o","observationGeneration":"1"})
    }

    fn row() -> Value {
        json!({"candidateKey":"c","observationId":"o","authorizationState":"Connected",
            "observationContinuity":"relationProven","adoptedTargetId":null,"bindingRevision":null,
            "displayName":null,"displayNameGeneration":"3","deviceInformation":null,
            "observedFacts":null})
    }

    fn snapshot(rows: Value) -> Value {
        json!({"schemaVersion":"arkdeck.device-observations/1","snapshotGeneration":"3",
            "observedAtUtc":"2026-09-20T00:00:00Z","health":"current","observations":rows})
    }

    fn refusal(snapshot: &Value) -> (&'static str, String) {
        let error = proved_row(snapshot, &following(), 1).unwrap_err();
        (error.code, error.message)
    }

    #[test]
    fn a_proved_snapshot_answers_its_row_generation_and_timestamp() {
        let (proved, generation, observed_at) =
            proved_row(&snapshot(json!([row()])), &following(), 1).unwrap();
        assert_eq!(Value::Object(proved.clone()), row());
        assert_eq!(
            (generation, observed_at.as_str()),
            (3, "2026-09-20T00:00:00Z")
        );
        // The next read may not move the generation backwards.
        assert_eq!(
            proved_row(&snapshot(json!([row()])), &following(), 4)
                .unwrap_err()
                .code,
            "protocolMalformed"
        );
        assert_eq!(
            wait_document(proved, generation, &observed_at, "connected"),
            json!({"schemaVersion":"arkdeck.device-wait/1","snapshotGeneration":"3",
                "observedAtUtc":"2026-09-20T00:00:00Z","state":"connected","observation":row()})
        );
    }

    #[test]
    fn a_snapshot_off_its_shape_or_its_health_is_malformed() {
        let mut stale = snapshot(json!([row()]));
        stale["health"] = json!("stale");
        let mut undated = snapshot(json!([row()]));
        undated["observedAtUtc"] = json!("");
        let mut padded = snapshot(json!([row()]));
        padded["snapshotGeneration"] = json!("03");
        let mut extra = snapshot(json!([row()]));
        extra["extra"] = json!(true);
        let crowded = snapshot(Value::Array(vec![row(); 1001]));
        for value in [stale, undated, padded, extra, crowded, json!([])] {
            assert_eq!(
                refusal(&value),
                (
                    "protocolMalformed",
                    "the Runtime returned an invalid device observation snapshot".to_owned()
                ),
                "{value}"
            );
        }
    }

    #[test]
    fn a_row_that_is_not_the_original_observation_is_a_conflict() {
        let mut replaced = row();
        replaced["observationContinuity"] = json!("relationReplaced");
        let mut renamed = row();
        renamed["displayNameGeneration"] = json!("2");
        let mut shortened = row();
        shortened.as_object_mut().unwrap().remove("observedFacts");
        for rows in [
            json!([]),
            json!([replaced]),
            json!([renamed]),
            json!([shortened]),
            json!([row(), row()]),
        ] {
            let error = proved_row(&snapshot(rows.clone()), &following(), 1).unwrap_err();
            assert_eq!(error.code, "resourceConflict", "{rows}");
            assert_eq!(Value::Object(error.details.clone()), following());
        }
    }

    #[test]
    fn a_row_the_contract_admits_but_the_lifecycle_refuses_is_malformed() {
        let cases: [(Value, &str); 6] = [
            (
                "Waiting".into(),
                "the observation has no supported authorization state",
            ),
            (
                json!("t"),
                "the observation has an invalid adopted-target link",
            ),
            (
                json!(0),
                "the observation has an invalid adopted-target link",
            ),
            (
                json!(""),
                "the observation has an invalid adopted-target link",
            ),
            (
                json!(" a"),
                "the observation has an invalid candidate display name",
            ),
            (
                json!("a".repeat(257)),
                "the observation has an invalid candidate display name",
            ),
        ];
        for (index, (value, message)) in cases.into_iter().enumerate() {
            let mut broken = row();
            match index {
                0 => broken["authorizationState"] = value,
                1 => broken["adoptedTargetId"] = value,
                2 => {
                    broken["adoptedTargetId"] = json!("t");
                    broken["bindingRevision"] = value;
                }
                3 => {
                    broken["adoptedTargetId"] = value;
                    broken["bindingRevision"] = json!(1);
                }
                _ => broken["displayName"] = value,
            }
            assert_eq!(
                refusal(&snapshot(json!([broken.clone()]))),
                ("protocolMalformed", message.to_owned()),
                "{broken}"
            );
        }
        // An adopted link is either absent on both sides or exact on both.
        let mut adopted = row();
        adopted["adoptedTargetId"] = json!("target-a");
        adopted["bindingRevision"] = json!(2);
        assert!(proved_row(&snapshot(json!([adopted])), &following(), 1).is_ok());
    }

    #[test]
    fn the_timeout_names_the_observation_and_says_nothing_was_dispatched() {
        let error = wait_timeout(&following(), "connected", Some(3));
        assert_eq!((error.code, error.exit_code()), ("clientTimeout", 75));
        assert_eq!(
            Value::Object(error.details.clone()),
            json!({"candidate":"c","observationId":"o","observationGeneration":"1",
                "requestedState":"connected","lastObservedGeneration":"3","newDispatchCount":0})
        );
        // Before any snapshot is proved there is no observed generation.
        let unproved = wait_timeout(&following(), "connected", None);
        assert!(!unproved.details.contains_key("lastObservedGeneration"));
    }

    #[test]
    fn the_parse_keeps_the_state_beside_the_wire_parameters() {
        let mut fields = Map::from_iter([
            ("candidate".to_owned(), json!("c")),
            ("observationId".to_owned(), json!("o")),
            ("observationGeneration".to_owned(), json!("1")),
            ("state".to_owned(), json!("connected")),
        ]);
        assert_eq!(configure(&mut fields).unwrap(), Some(30_000));
        assert_eq!(
            Value::Object(fields.clone()),
            json!({"following":{"candidate":"c","observationId":"o","observationGeneration":"1"},
                "state":"connected"})
        );
        let (request, state, provider) = wait_request(&fields);
        assert_eq!(Value::Object(request), json!({"following": following()}));
        assert_eq!(
            (state.as_str(), provider.as_str()),
            ("connected", "Connected")
        );
        for (key, value) in [
            ("observationGeneration", json!("0")),
            ("observationGeneration", json!("01")),
            ("state", json!("Connected")),
            ("timeout", json!("0s")),
            ("timeout", json!("25h")),
        ] {
            let mut broken = Map::from_iter([
                ("candidate".to_owned(), json!("c")),
                ("observationId".to_owned(), json!("o")),
                ("observationGeneration".to_owned(), json!("1")),
                ("state".to_owned(), json!("connected")),
            ]);
            broken.insert(key.to_owned(), value.clone());
            let error = configure(&mut broken).unwrap_err();
            assert_eq!(
                (error.code, error.exit_code()),
                ("invalidOption", 64),
                "{key} {value}"
            );
        }
    }
}
