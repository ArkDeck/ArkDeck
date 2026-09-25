//! `arkdeck maintainer contracts export|check` (Swift
//! `RuntimeCLI.runMaintainerContracts`): the machine-contract bundle this
//! build renders (`machine_contracts`), written out, or held to one.
//!
//! Neither leaf connects to a Runtime, and each answers one document: the
//! export's report or the check's. A check that finds the bundle drifted
//! still answers its report, then fails as Swift's session does once a result
//! is out: with the failure's code and exit status, and a diagnostic on
//! stderr instead of a second document.
use crate::{CliError, Invocation, machine_contracts};
use serde_json::{Map, Value, json};
use std::panic::{self, AssertUnwindSafe};
use std::path::{Component, Path, PathBuf};

/// One invocation's answer: the document it emits, if any, and the failure it
/// ends with, if any. A failure with a document is reported after it.
#[derive(Debug)]
pub struct Answer {
    pub document: Option<Value>,
    pub failure: Option<CliError>,
}

impl Answer {
    fn failed(command: &'static str, code: &'static str, message: String) -> Self {
        let mut error = CliError::new(code, message);
        error.command = Some(command);
        Self {
            document: None,
            failure: Some(error),
        }
    }
}

/// Swift `URL(fileURLWithPath:).standardizedFileURL.path`: a relative path
/// against the working directory, `.` and `..` resolved by name, and on
/// macOS a leading `/private` dropped where what remains exists.
pub fn standardized(raw: &str) -> PathBuf {
    let path = Path::new(raw);
    let absolute = if path.is_absolute() {
        path.to_path_buf()
    } else {
        std::env::current_dir()
            .map(|directory| directory.join(path))
            .unwrap_or_else(|_| path.to_path_buf())
    };
    let mut resolved = PathBuf::new();
    for component in absolute.components() {
        match component {
            Component::CurDir => {}
            Component::ParentDir => {
                resolved.pop();
            }
            other => resolved.push(other),
        }
    }
    #[cfg(target_os = "macos")]
    if let Ok(rest) = resolved.strip_prefix("/private") {
        let rest = Path::new("/").join(rest);
        if rest != Path::new("/") && rest.exists() {
            return rest;
        }
    }
    resolved
}

/// The generator's own refusal (Swift `CLIMachineContracts.Failure`): this
/// port asserts its invariants, so a broken one unwinds, and is answered here
/// as Swift answers the failure, without the unwinding's own report.
fn generated<T>(work: impl FnOnce() -> T) -> Result<T, String> {
    let quiet = panic::take_hook();
    panic::set_hook(Box::new(|_| {}));
    let outcome = panic::catch_unwind(AssertUnwindSafe(work));
    panic::set_hook(quiet);
    outcome.map_err(|payload| {
        payload
            .downcast_ref::<String>()
            .cloned()
            .or_else(|| {
                payload
                    .downcast_ref::<&str>()
                    .map(|text| (*text).to_owned())
            })
            .unwrap_or_else(|| "the machine contracts could not be generated".into())
    })
}

/// Swift `runMaintainerContracts`.
pub fn run(invocation: &Invocation) -> Answer {
    let command = invocation.command;
    let text = |key: &str| {
        invocation
            .params
            .as_ref()
            .and_then(|params| params.get(key))
            .and_then(Value::as_str)
    };
    let (Some(contracts), Some(fixtures)) = (text("contractsDirectory"), text("fixturesDirectory"))
    else {
        return Answer::failed(
            command,
            "invalidOption",
            "--contracts-directory and --fixtures-directory are both required".into(),
        );
    };
    let contracts = standardized(contracts);
    let fixtures = standardized(fixtures);
    let mut fields = Map::from_iter([
        (
            "bundleVersion".to_owned(),
            json!(machine_contracts::BUNDLE_VERSION),
        ),
        (
            "contractsDirectory".to_owned(),
            json!(contracts.to_string_lossy()),
        ),
        (
            "fixturesDirectory".to_owned(),
            json!(fixtures.to_string_lossy()),
        ),
    ]);
    let io_failure = |error: std::io::Error| {
        Answer::failed(
            command,
            "ioFailure",
            format!("the contract bundle could not be written or read: {error}"),
        )
    };
    if command == "maintainer.contracts.export" {
        match generated(|| machine_contracts::export(&contracts, &fixtures)) {
            Err(message) => Answer::failed(command, "internalError", message),
            Ok(Err(error)) => io_failure(error),
            Ok(Ok(report)) => {
                fields.insert("written".into(), json!(report.written));
                fields.insert("removed".into(), json!(report.removed));
                Answer {
                    document: Some(Value::Object(fields)),
                    failure: None,
                }
            }
        }
    } else {
        match generated(|| machine_contracts::check(&contracts, &fixtures)) {
            Err(message) => Answer::failed(command, "internalError", message),
            Ok(Err(error)) => io_failure(error),
            Ok(Ok(report)) => {
                if let Value::Object(document) = report.document() {
                    fields.extend(document);
                }
                let failure = (!report.is_clean()).then(|| {
                    let mut error = CliError::new(
                        "operationFailed",
                        "the published machine contracts drifted from this build; run `arkdeck maintainer contracts export`",
                    );
                    error.details = Map::from_iter([
                        ("drifted".to_owned(), json!(report.drifted)),
                        ("missing".to_owned(), json!(report.missing)),
                        ("unexpected".to_owned(), json!(report.unexpected)),
                    ]);
                    error.command = Some(command);
                    error
                });
                Answer {
                    document: Some(Value::Object(fields)),
                    failure,
                }
            }
        }
    }
}

#[cfg(test)]
mod tests {
    use super::generated;

    /// A broken invariant of the generator is its failure, with its words,
    /// as Swift's `CLIMachineContracts.Failure` is.
    #[test]
    fn a_generator_failure_is_answered_with_its_words() {
        assert_eq!(generated(|| 7), Ok(7));
        assert_eq!(
            generated(|| -> u8 { panic!("no sample for the grammar {{}}") }),
            Err("no sample for the grammar {}".to_owned())
        );
        assert_eq!(
            generated(|| -> u8 { panic!("static words") }),
            Err("static words".to_owned())
        );
    }
}
