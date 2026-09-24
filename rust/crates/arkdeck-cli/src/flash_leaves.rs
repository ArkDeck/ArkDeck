//! The Flash leaves that read or repair what the Runtime keeps about a board
//! without reaching it: `flash reconcile-alias` and `recovery flash-invocation
//! list|status`, with `debug status`, the legacy spelling of the last. Each is
//! one request, answered as the Runtime answers it (Swift
//! `runFlashObservation` and `emitFlashInvocation`); every judgement of the
//! alias and of the invocation documents is the Runtime's.
use crate::CliError;
use serde_json::{Map, Value, json};

fn invalid(message: &str) -> CliError {
    CliError::new("invalidOption", message)
}

/// The registry's grammar of each leaf's options, judged before any request:
/// the required options present, a revision a positive integer, a page size
/// within 1…1000 (100 when none is given, as Swift sends it).
pub(crate) fn configure(
    command: &str,
    fields: &mut Map<String, Value>,
    help: bool,
) -> Result<(), CliError> {
    if help {
        return Ok(());
    }
    match command {
        "flash.reconcile-alias" => {
            if !fields.contains_key("targetId") {
                return Err(invalid("flash reconcile-alias requires --target"));
            }
            let text = fields
                .get("expectedBindingRevision")
                .and_then(Value::as_str)
                .ok_or_else(|| {
                    invalid("flash reconcile-alias requires --expected-binding-revision")
                })?;
            let revision = text
                .parse::<i64>()
                .ok()
                .filter(|revision| *revision >= 1 && revision.to_string() == text)
                .ok_or_else(|| {
                    invalid(
                        "flash reconcile-alias --expected-binding-revision must be a positive \
                         integer",
                    )
                })?;
            fields.insert("expectedBindingRevision".into(), json!(revision));
        }
        "recovery.flash-invocation.list" => {
            let size = match fields.get("pageSize") {
                None => 100,
                Some(value) => value
                    .as_str()
                    .and_then(|text| text.parse::<u64>().ok())
                    .filter(|size| (1..=1000).contains(size))
                    .ok_or_else(|| invalid("page-size must be between 1 and 1000"))?,
            };
            fields.insert("pageSize".into(), json!(size));
        }
        "recovery.flash-invocation.status" | "debug.status"
            if !fields.contains_key("invocationId") =>
        {
            return Err(invalid(
                "flash-invocation status requires --invocation <id>",
            ));
        }
        _ => {}
    }
    Ok(())
}
