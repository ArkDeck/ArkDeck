//! The typed HDC actions of `observe.device@1` and of the default legs of
//! `capture.diagnostics@1`, as Swift's HDC provider
//! (`HDCObservationProviderAdapter`) chooses, lowers and verifies them: a
//! closed vocabulary with no caller-supplied argv, each action lowered to the
//! exact arguments the executor runs, and each receipt judged by the
//! observation parsers or Swift's capture verdicts. What runs a lowered plan
//! is an [`HdcDispatch`]; this module starts nothing itself.
use crate::{ParseError, parse_client_version, parse_server_check, parse_target_list};
use sha2::{Digest, Sha256};
use std::collections::BTreeMap;
use std::fmt;
use std::time::Duration;
use unicode_segmentation::UnicodeSegmentation;

/// Swift `HDCObservationProviderAdapter.lower`: every observe action has 15 s.
const TIMEOUT: Duration = Duration::from_secs(15);
/// Swift's storage readback and window inventory have 30 s.
const CAPTURE_TIMEOUT: Duration = Duration::from_secs(30);
/// Swift `DescriptorBoundProcessDispatcher`'s default capture.
const CAPTURE_BYTES: usize = 8 * 1024 * 1024;
/// Swift `HDCStoragePreflightRequest.remotePath`: the one root a storage
/// preflight reads; no caller names it.
pub const STORAGE_ROOT: &str = "/data/local/tmp";
const MAXIMUM_REQUIRED_BYTES: i64 = 8 * 1024 * 1024 * 1024;
/// Swift `HDCHilogCaptureRequest`'s bounds and default budget.
const MAXIMUM_HILOG_SECONDS: i64 = 600;
const MAXIMUM_HILOG_FILTERS: usize = 16;
const MAXIMUM_HILOG_BUDGET: i64 = 128 * 1024 * 1024;
pub const DEFAULT_HILOG_BUDGET: i64 = 16 * 1024 * 1024;
/// `hilog -x` drains the device's current buffers and exits; the requested
/// duration bounds only its timeout, which never drops below 45 s.
const MINIMUM_HILOG_TIMEOUT_SECONDS: u64 = 45;
const HILOG_GRACE_SECONDS: u64 = 15;
/// Swift `HDCUIDumpRequest`'s default budget, which its persisted form names.
const UI_DUMP_BUDGET: i64 = 8 * 1024 * 1024;
/// Swift `queryProperty` verification: a longer value is not a fact.
const MAXIMUM_PROPERTY_CHARACTERS: usize = 400;
/// The highest registered HDC version, which Swift parses a target list with
/// when the facts name no tool version.
const HIGHEST_REGISTERED_VERSION: &str = "3.2.0f";

/// Swift `HDCPropertyKey`: the device properties an approved read queries.
#[derive(Clone, Copy, Debug, Eq, PartialEq)]
pub enum Property {
    ProductName,
    FullBuildVersion,
}

impl Property {
    pub fn key(self) -> &'static str {
        match self {
            Self::ProductName => "const.product.name",
            Self::FullBuildVersion => "const.ohos.fullname",
        }
    }
}

/// Swift `TypedProviderAction.hdc` for the actions this Runtime dispatches.
#[derive(Clone, Debug, Eq, PartialEq)]
pub enum Action {
    ObserveTool,
    ObserveServer,
    /// The one target row the binding's connect key names.
    ObserveDevice,
    QueryProperty(Property),
    /// Swift `.observeStorage`: the free space under [`STORAGE_ROOT`],
    /// judged against the bytes the capture may need.
    ObserveStorage {
        required_bytes: i64,
    },
    /// Swift `.captureHilog`: the bounded HiLog drain.
    CaptureHilog {
        duration_seconds: i64,
        filters: Vec<String>,
        byte_budget: i64,
    },
    /// Swift `.captureUIDump` of scope `windowList`: the window inventory.
    CaptureWindowList,
}

/// Swift `HDCE0RequestError`, spelled as Swift interpolates it.
#[derive(Clone, Debug, Eq, PartialEq)]
pub enum RequestError {
    OutOfBounds {
        field: &'static str,
        detail: String,
    },
    Malformed {
        field: &'static str,
        detail: &'static str,
    },
}

impl fmt::Display for RequestError {
    fn fmt(&self, formatter: &mut fmt::Formatter<'_>) -> fmt::Result {
        match self {
            Self::OutOfBounds { field, detail } => {
                write!(
                    formatter,
                    "outOfBounds(field: \"{field}\", detail: \"{detail}\")"
                )
            }
            Self::Malformed { field, detail } => {
                write!(
                    formatter,
                    "malformed(field: \"{field}\", detail: \"{detail}\")"
                )
            }
        }
    }
}

/// One argument of a persisted action, as Swift's `JSONValue` holds it.
#[derive(Clone, Debug, Eq, PartialEq)]
pub enum Persisted {
    Text(String),
    Integer(i64),
    Texts(Vec<String>),
}

/// The facts a device-bound action is judged against, as Swift's
/// `ProviderExecutionContext` carries them.
#[derive(Clone, Copy, Debug, Default)]
pub struct Expected<'a> {
    pub connect_key: Option<&'a str>,
    pub identity_sha256: Option<&'a str>,
    pub tool_version: Option<&'a str>,
}

/// One lowered HDC process: the exact arguments after argv0, and its budget.
#[derive(Clone, Debug, Eq, PartialEq)]
pub struct ProcessPlan {
    pub arguments: Vec<String>,
    pub timeout: Duration,
    pub capture_bytes: usize,
}

/// What one HDC process returned (Swift `ProviderProcessReceipt`).
#[derive(Clone, Debug, Eq, PartialEq)]
pub struct Receipt {
    pub exit_status: i32,
    pub stdout: Vec<u8>,
    pub stderr: Vec<u8>,
    /// Either stream went past the plan's capture (Swift's
    /// `stdoutTruncated` covers both streams).
    pub truncated: bool,
    pub duration: Duration,
}

/// Swift `RuntimeDispatchFailure` before any receipt exists.
#[derive(Clone, Debug, Eq, PartialEq)]
pub enum DispatchFailure {
    /// The child never launched (an identity or authorization refusal), so
    /// nothing external happened: the step fails.
    Refused(String),
    /// The child launched but its outcome cannot be observed (a timeout, a
    /// signal, an I/O failure): the Job parks and is never replayed.
    Unobservable(String),
}

/// Runs one lowered plan. The implementation owns the executable, and any
/// server endpoint and environment it may name; the plan never carries them.
pub trait HdcDispatch {
    fn dispatch(&self, plan: &ProcessPlan) -> Result<Receipt, DispatchFailure>;
}

/// Swift `ProviderSemanticOutcome`.
#[derive(Clone, Debug, Eq, PartialEq)]
pub enum Outcome {
    Verified(BTreeMap<String, String>),
    Failed { code: &'static str, detail: String },
    Unknown(String),
    Unsupported(String),
}

impl Action {
    /// Swift `HDCObservationProviderAdapter.action` for an observe step: its
    /// kind, and for an approved remote read its catalog action.
    pub fn for_step(kind: &str, action_id: Option<&str>) -> Option<Self> {
        match (kind, action_id) {
            ("probeHostTool", _) => Some(Self::ObserveTool),
            ("probeHDCServer", _) => Some(Self::ObserveServer),
            ("probeDevice", _) => Some(Self::ObserveDevice),
            ("runApprovedRemoteRead", Some("deviceModel")) => {
                Some(Self::QueryProperty(Property::ProductName))
            }
            ("runApprovedRemoteRead", Some("firmwareBuild")) => {
                Some(Self::QueryProperty(Property::FullBuildVersion))
            }
            _ => None,
        }
    }

    /// Swift `HDCStoragePreflightRequest(requiredBytes:)`: 1 byte to 8 GiB.
    pub fn observe_storage(required_bytes: i64) -> Result<Self, RequestError> {
        if !(1..=MAXIMUM_REQUIRED_BYTES).contains(&required_bytes) {
            return Err(RequestError::OutOfBounds {
                field: "requiredBytes",
                detail: format!("1...{MAXIMUM_REQUIRED_BYTES}"),
            });
        }
        Ok(Self::ObserveStorage { required_bytes })
    }

    /// Swift `HDCHilogCaptureRequest(durationSeconds:filters:byteBudget:)`:
    /// a window of 1 to 600 s, at most 16 bounded ASCII filter tokens (never
    /// a shell fragment) and a budget of 1 KiB to 128 MiB.
    pub fn capture_hilog(
        duration_seconds: i64,
        filters: Vec<String>,
        byte_budget: i64,
    ) -> Result<Self, RequestError> {
        if !(1..=MAXIMUM_HILOG_SECONDS).contains(&duration_seconds) {
            return Err(RequestError::OutOfBounds {
                field: "durationSeconds",
                detail: format!("1...{MAXIMUM_HILOG_SECONDS}"),
            });
        }
        if filters.len() > MAXIMUM_HILOG_FILTERS {
            return Err(RequestError::OutOfBounds {
                field: "filters",
                detail: format!("at most {MAXIMUM_HILOG_FILTERS}"),
            });
        }
        if !filters.iter().all(|filter| hilog_filter(filter)) {
            return Err(RequestError::Malformed {
                field: "filters",
                detail: "filter tokens are bounded ASCII, no shell fragments",
            });
        }
        if !(1024..=MAXIMUM_HILOG_BUDGET).contains(&byte_budget) {
            return Err(RequestError::OutOfBounds {
                field: "byteBudget",
                detail: format!("1024...{MAXIMUM_HILOG_BUDGET}"),
            });
        }
        Ok(Self::CaptureHilog {
            duration_seconds,
            filters,
            byte_budget,
        })
    }

    /// Swift `TypedProviderAction.effect`.
    pub fn effect(&self) -> &'static str {
        match self {
            Self::ObserveTool | Self::ObserveServer => "hostOnly",
            Self::ObserveDevice
            | Self::QueryProperty(_)
            | Self::ObserveStorage { .. }
            | Self::CaptureHilog { .. }
            | Self::CaptureWindowList => "readOnly",
        }
    }

    /// Swift `PersistedTypedProviderAction`: the kind and arguments a Job
    /// record keeps before the action's intent can be dispatched.
    pub fn persisted(&self) -> (&'static str, Vec<(&'static str, Persisted)>) {
        let text = |value: &str| Persisted::Text(value.into());
        match self {
            Self::ObserveTool => ("hdc.observeTool", Vec::new()),
            Self::ObserveServer => ("hdc.observeServer", Vec::new()),
            Self::ObserveDevice => (
                "hdc.observeDevice",
                vec![("connectKey", text("resolved-by-binding"))],
            ),
            Self::QueryProperty(property) => (
                "hdc.queryProperty",
                vec![("property", text(property.key()))],
            ),
            Self::ObserveStorage { required_bytes } => (
                "hdc.observeStorage",
                vec![("requiredBytes", Persisted::Integer(*required_bytes))],
            ),
            Self::CaptureHilog {
                duration_seconds,
                filters,
                byte_budget,
            } => (
                "hdc.captureHilog",
                vec![
                    ("durationSeconds", Persisted::Integer(*duration_seconds)),
                    ("filters", Persisted::Texts(filters.clone())),
                    ("byteBudget", Persisted::Integer(*byte_budget)),
                ],
            ),
            Self::CaptureWindowList => (
                "hdc.captureUIDump",
                vec![
                    ("scope", text("windowList")),
                    ("byteBudget", Persisted::Integer(UI_DUMP_BUDGET)),
                ],
            ),
        }
    }

    /// Swift `lower`: the arguments the executor runs and their budget. A
    /// device action names its target by the binding's connect key, and has
    /// none without one.
    pub fn lower(&self, step_id: &str, connect_key: Option<&str>) -> Result<ProcessPlan, String> {
        let device = |tail: &[&str]| -> Result<Vec<String>, String> {
            let Some(key) = connect_key.filter(|key| !key.is_empty()) else {
                return Err(format!(
                    "factsUnavailable(\"{step_id} has no descriptor-bound target connect key\")"
                ));
            };
            Ok(["-t", key]
                .iter()
                .chain(tail)
                .map(|argument| (*argument).to_owned())
                .collect())
        };
        let (arguments, timeout, capture_bytes) = match self {
            Self::ObserveTool => (vec!["-v".into()], TIMEOUT, CAPTURE_BYTES),
            Self::ObserveServer => (vec!["checkserver".into()], TIMEOUT, CAPTURE_BYTES),
            Self::ObserveDevice => (
                vec!["list".into(), "targets".into(), "-v".into()],
                TIMEOUT,
                CAPTURE_BYTES,
            ),
            Self::QueryProperty(property) => (
                device(&["shell", "param", "get", property.key()])?,
                TIMEOUT,
                CAPTURE_BYTES,
            ),
            Self::ObserveStorage { .. } => (
                device(&["shell", "df", "-k", STORAGE_ROOT])?,
                CAPTURE_TIMEOUT,
                CAPTURE_BYTES,
            ),
            // The budget travels with the plan: the request's is 16 MiB where
            // the dispatcher's own default is 8 MiB.
            Self::CaptureHilog {
                duration_seconds,
                filters,
                byte_budget,
            } => {
                let mut tail = vec!["shell", "hilog", "-x"];
                tail.extend(filters.iter().map(String::as_str));
                let seconds = (duration_seconds.unsigned_abs() + HILOG_GRACE_SECONDS)
                    .max(MINIMUM_HILOG_TIMEOUT_SECONDS);
                (
                    device(&tail)?,
                    Duration::from_secs(seconds),
                    usize::try_from(*byte_budget).unwrap_or(CAPTURE_BYTES),
                )
            }
            Self::CaptureWindowList => (
                device(&[
                    "shell",
                    "hidumper",
                    "-s",
                    "WindowManagerService",
                    "-a",
                    "-a",
                ])?,
                CAPTURE_TIMEOUT,
                CAPTURE_BYTES,
            ),
        };
        Ok(ProcessPlan {
            arguments,
            timeout,
            capture_bytes,
        })
    }

    /// Swift `verify` for these actions, which never read the exit status.
    pub fn verify(&self, receipt: &Receipt, expected: Expected<'_>) -> Outcome {
        match self {
            Self::ObserveTool => match parse_client_version(&receipt.stdout, receipt.truncated) {
                Ok(version) => verified([("toolVersion", version)]),
                Err(error) => parse_outcome(error, "empty observation output"),
            },
            Self::ObserveServer => match parse_server_check(&receipt.stdout, receipt.truncated) {
                Ok(check) if check.versions_agree() => verified([
                    ("clientVersion", check.client_version),
                    ("serverVersion", check.server_version),
                ]),
                Ok(check) => Outcome::Failed {
                    code: "serverVersionMismatch",
                    detail: format!(
                        "client {} vs server {}",
                        check.client_version, check.server_version
                    ),
                },
                Err(error) => parse_outcome(error, "empty server check output"),
            },
            Self::ObserveDevice => observe_device(receipt, expected),
            Self::QueryProperty(property) => query_property(receipt, *property),
            Self::ObserveStorage { required_bytes } => observe_storage(receipt, *required_bytes),
            // HiLog is raw sensitive output: bytes that are not UTF-8 are
            // kept, never refused.
            Self::CaptureHilog { .. } => {
                if receipt.truncated {
                    Outcome::Failed {
                        code: "truncated",
                        detail: "capture exceeded its byte budget".into(),
                    }
                } else if receipt.stdout.is_empty() {
                    Outcome::Unknown("empty capture output".into())
                } else {
                    verified([("byteCount", receipt.stdout.len().to_string())])
                }
            }
            Self::CaptureWindowList => {
                if receipt.truncated {
                    Outcome::Failed {
                        code: "truncated",
                        detail: "capture exceeded its byte budget".into(),
                    }
                } else if std::str::from_utf8(&receipt.stdout).is_err() {
                    Outcome::Failed {
                        code: "invalidEncoding",
                        detail: "UI dump is not UTF-8".into(),
                    }
                } else if receipt.stdout.is_empty() {
                    Outcome::Unknown("empty capture output".into())
                } else {
                    verified([("byteCount", receipt.stdout.len().to_string())])
                }
            }
        }
    }
}

/// Swift's HiLog filter token: 1 to 200 characters, each an ASCII letter or
/// digit or one of `:*./_-`.
fn hilog_filter(filter: &str) -> bool {
    !filter.is_empty()
        && filter.chars().count() <= 200
        && filter
            .chars()
            .all(|character| character.is_ascii_alphanumeric() || ":*./_-".contains(character))
}

/// Swift `Character.isNewline`.
fn swift_newline(character: char) -> bool {
    matches!(
        character,
        '\n' | '\u{0B}' | '\u{0C}' | '\r' | '\u{85}' | '\u{2028}' | '\u{2029}'
    )
}

/// Swift `UInt64(_:)`: an optional sign, then decimal digits; a negative
/// value parses only as zero.
fn swift_unsigned(text: &str) -> Option<u64> {
    let (negative, digits) = match text.as_bytes().first() {
        Some(b'+') => (false, &text[1..]),
        Some(b'-') => (true, &text[1..]),
        _ => (false, text),
    };
    if digits.is_empty() || !digits.bytes().all(|byte| byte.is_ascii_digit()) {
        return None;
    }
    let value: u64 = digits.parse().ok()?;
    (!negative || value == 0).then_some(value)
}

/// Swift's `observeStorage` verdict: the fourth column of the last data line
/// of `df -k`, in KiB, against the bytes required.
fn observe_storage(receipt: &Receipt, required_bytes: i64) -> Outcome {
    if receipt.truncated {
        return Outcome::Failed {
            code: "truncated",
            detail: "storage output exceeded budget".into(),
        };
    }
    let Ok(text) = std::str::from_utf8(&receipt.stdout) else {
        return Outcome::Failed {
            code: "invalidEncoding",
            detail: "storage output is not UTF-8".into(),
        };
    };
    let available = text
        .split(swift_newline)
        .filter(|line| !line.is_empty())
        .skip(1)
        .filter_map(|line| {
            let fields: Vec<&str> = line
                .split(char::is_whitespace)
                .filter(|field| !field.is_empty())
                .collect();
            fields.get(3).and_then(|field| swift_unsigned(field))
        })
        .last();
    let Some(kilobytes) = available.filter(|kilobytes| *kilobytes <= u64::MAX / 1024) else {
        return Outcome::Unknown("storage output has no bounded available-byte observation".into());
    };
    let available = kilobytes * 1024;
    if available < required_bytes.unsigned_abs() {
        return Outcome::Failed {
            code: "insufficientDeviceStorage",
            detail: format!("requires {required_bytes} bytes; {available} available"),
        };
    }
    verified([("availableBytes", available.to_string())])
}

/// Swift `stableIdentitySHA256(connectKey:)`: the HDC identity a connect key
/// names, which confirmation checks against the adopted binding.
pub fn stable_identity_sha256(connect_key: &str) -> String {
    hex(&Sha256::digest(connect_key.to_lowercase().as_bytes()))
}

fn hex(bytes: &[u8]) -> String {
    bytes.iter().map(|byte| format!("{byte:02x}")).collect()
}

fn verified<const N: usize>(facts: [(&str, String); N]) -> Outcome {
    Outcome::Verified(
        facts
            .into_iter()
            .map(|(key, value)| (key.to_owned(), value))
            .collect(),
    )
}

/// The classes Swift gives each parser result that is not a fact.
fn parse_outcome(error: ParseError, empty: &str) -> Outcome {
    match error {
        ParseError::UnsupportedVersion(version) => {
            Outcome::Unsupported(format!("unregistered HDC version {version}"))
        }
        ParseError::InvalidEncoding => Outcome::Failed {
            code: "invalidEncoding",
            detail: "stdout is not valid UTF-8".into(),
        },
        ParseError::Truncated => Outcome::Failed {
            code: "truncated",
            detail: "stdout exceeded its byte budget".into(),
        },
        ParseError::Empty => Outcome::Unknown(empty.into()),
        ParseError::Malformed(reason) => Outcome::Unknown(reason.into()),
    }
}

fn observe_device(receipt: &Receipt, expected: Expected<'_>) -> Outcome {
    let version = expected.tool_version.unwrap_or(HIGHEST_REGISTERED_VERSION);
    let rows = match parse_target_list(&receipt.stdout, version, receipt.truncated) {
        Ok(rows) => rows,
        Err(error) => return parse_outcome(error, "empty observation output"),
    };
    let Some(key) = expected.connect_key.filter(|key| !key.is_empty()) else {
        return Outcome::Failed {
            code: "targetFactsUnavailable",
            detail: "descriptor-bound connect key is absent".into(),
        };
    };
    let matches: Vec<_> = rows.iter().filter(|row| row.connect_key == key).collect();
    let [row] = matches.as_slice() else {
        return Outcome::Failed {
            code: "targetConfirmationMismatch",
            detail: format!(
                "expected exactly one matching target row, saw {}",
                matches.len()
            ),
        };
    };
    if row.state != "Connected" {
        return Outcome::Failed {
            code: "targetNotConnected",
            detail: format!("matching target state is {}", row.state),
        };
    }
    let identity = stable_identity_sha256(key);
    if expected
        .identity_sha256
        .is_some_and(|adopted| identity != adopted.to_lowercase())
    {
        return Outcome::Failed {
            code: "targetIdentityMismatch",
            detail: "matching target row does not match the adopted stable identity".into(),
        };
    }
    verified([
        ("deviceIdentitySHA256", identity),
        ("transport", row.transport.clone()),
        ("state", row.state.clone()),
    ])
}

fn query_property(receipt: &Receipt, property: Property) -> Outcome {
    if receipt.truncated {
        return Outcome::Failed {
            code: "truncated",
            detail: "property output exceeded budget".into(),
        };
    }
    let Ok(text) = std::str::from_utf8(&receipt.stdout) else {
        return Outcome::Failed {
            code: "invalidEncoding",
            detail: "property output is not UTF-8".into(),
        };
    };
    let value = property_value(text, property.key());
    if value.is_empty() || value.graphemes(true).count() > MAXIMUM_PROPERTY_CHARACTERS {
        return Outcome::Unknown("property value empty or oversized".into());
    }
    verified([("value", value.to_owned())])
}

/// Swift `propertyValue(fromParamGetOutput:requestedKey:)`: `param get` may
/// echo `<key> = <value>`; the echo is removed only when the output starts
/// with the key asked for, so a value holding `=` is never cut.
pub fn property_value<'a>(output: &'a str, requested_key: &str) -> &'a str {
    let trimmed = output.trim();
    let Some(remainder) = trimmed.strip_prefix(requested_key) else {
        return trimmed;
    };
    match remainder.trim_start_matches([' ', '\t']).strip_prefix('=') {
        Some(value) => value.trim(),
        None => trimmed,
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    fn receipt(stdout: &str) -> Receipt {
        Receipt {
            exit_status: 0,
            stdout: stdout.as_bytes().to_vec(),
            stderr: Vec::new(),
            truncated: false,
            duration: Duration::ZERO,
        }
    }

    const KEY: &str = "aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa";

    #[test]
    fn observe_actions_lower_to_the_fixture_argv() {
        let lowered = |action: Action| action.lower("step", Some(KEY)).unwrap().arguments;
        assert_eq!(lowered(Action::ObserveTool), ["-v"]);
        assert_eq!(lowered(Action::ObserveServer), ["checkserver"]);
        assert_eq!(lowered(Action::ObserveDevice), ["list", "targets", "-v"]);
        assert_eq!(
            lowered(Action::QueryProperty(Property::ProductName)),
            ["-t", KEY, "shell", "param", "get", "const.product.name"]
        );
        assert!(
            Action::QueryProperty(Property::FullBuildVersion)
                .lower("read-evidence-firmware", None)
                .unwrap_err()
                .contains("read-evidence-firmware has no descriptor-bound target connect key")
        );
    }

    #[test]
    fn a_target_row_is_confirmed_only_by_the_bound_key_and_identity() {
        let identity = stable_identity_sha256(KEY);
        let expected = Expected {
            connect_key: Some(KEY),
            identity_sha256: Some(&identity),
            tool_version: Some("3.2.0d"),
        };
        let row = format!("{KEY}\t\tUSB\tConnected\tlocalhost\n");
        assert_eq!(
            Action::ObserveDevice.verify(&receipt(&row), expected),
            verified([
                ("deviceIdentitySHA256", identity.clone()),
                ("transport", "usb".into()),
                ("state", "Connected".into()),
            ])
        );
        let other = "bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb\t\tUSB\tConnected\tlocalhost\n";
        assert!(matches!(
            Action::ObserveDevice.verify(&receipt(other), expected),
            Outcome::Failed {
                code: "targetConfirmationMismatch",
                ..
            }
        ));
        let offline = format!("{KEY}\t\tUSB\tOffline\tlocalhost\n");
        assert!(matches!(
            Action::ObserveDevice.verify(&receipt(&offline), expected),
            Outcome::Failed {
                code: "targetNotConnected",
                ..
            }
        ));
        let foreign = Expected {
            identity_sha256: Some(
                "0000000000000000000000000000000000000000000000000000000000000000",
            ),
            ..expected
        };
        assert!(matches!(
            Action::ObserveDevice.verify(&receipt(&row), foreign),
            Outcome::Failed {
                code: "targetIdentityMismatch",
                ..
            }
        ));
    }

    #[test]
    fn versions_and_properties_are_classified_as_swift_classifies_them() {
        assert_eq!(
            Action::ObserveTool.verify(&receipt("Ver: 3.2.0d\n"), Expected::default()),
            verified([("toolVersion", "3.2.0d".into())])
        );
        assert_eq!(
            Action::ObserveTool.verify(&receipt(""), Expected::default()),
            Outcome::Unknown("empty observation output".into())
        );
        assert!(matches!(
            Action::ObserveServer.verify(
                &receipt("Client version:Ver: 3.2.0d, server version:Ver: 3.2.0f\n"),
                Expected::default()
            ),
            Outcome::Failed {
                code: "serverVersionMismatch",
                ..
            }
        ));
        let model = Action::QueryProperty(Property::ProductName);
        assert_eq!(
            model.verify(
                &receipt("const.product.name = DAYU200\n"),
                Expected::default()
            ),
            verified([("value", "DAYU200".into())])
        );
        assert_eq!(
            model.verify(&receipt("a=b\n"), Expected::default()),
            verified([("value", "a=b".into())])
        );
        assert_eq!(
            model.verify(&receipt(" \n"), Expected::default()),
            Outcome::Unknown("property value empty or oversized".into())
        );
    }

    #[test]
    fn capture_actions_lower_and_persist_as_swift_does() {
        let storage = Action::observe_storage(134_217_728).unwrap();
        let plan = storage
            .lower("preflight-device-storage", Some(KEY))
            .unwrap();
        assert_eq!(
            plan.arguments,
            ["-t", KEY, "shell", "df", "-k", "/data/local/tmp"]
        );
        assert_eq!(
            (plan.timeout, plan.capture_bytes),
            (Duration::from_secs(30), 8 * 1024 * 1024)
        );
        assert_eq!(
            storage.persisted(),
            (
                "hdc.observeStorage",
                vec![("requiredBytes", Persisted::Integer(134_217_728))]
            )
        );
        let hilog = Action::capture_hilog(5, Vec::new(), DEFAULT_HILOG_BUDGET).unwrap();
        let plan = hilog.lower("capture-hilog", Some(KEY)).unwrap();
        assert_eq!(plan.arguments, ["-t", KEY, "shell", "hilog", "-x"]);
        // The window bounds only the timeout, which never drops below 45 s;
        // the request's budget travels with the plan.
        assert_eq!(
            (plan.timeout, plan.capture_bytes),
            (Duration::from_secs(45), 16 * 1024 * 1024)
        );
        assert_eq!(
            hilog.persisted(),
            (
                "hdc.captureHilog",
                vec![
                    ("durationSeconds", Persisted::Integer(5)),
                    ("filters", Persisted::Texts(Vec::new())),
                    ("byteBudget", Persisted::Integer(16 * 1024 * 1024)),
                ]
            )
        );
        let filtered =
            Action::capture_hilog(600, vec!["A:*".into(), "app.x_y-z/".into()], 1024).unwrap();
        let plan = filtered.lower("capture-hilog", Some(KEY)).unwrap();
        assert_eq!(
            plan.arguments,
            ["-t", KEY, "shell", "hilog", "-x", "A:*", "app.x_y-z/"]
        );
        assert_eq!(
            (plan.timeout, plan.capture_bytes),
            (Duration::from_secs(615), 1024)
        );
        let window = Action::CaptureWindowList;
        let plan = window.lower("capture-ui-dump", Some(KEY)).unwrap();
        assert_eq!(
            plan.arguments,
            [
                "-t",
                KEY,
                "shell",
                "hidumper",
                "-s",
                "WindowManagerService",
                "-a",
                "-a"
            ]
        );
        assert_eq!(
            (plan.timeout, plan.capture_bytes),
            (Duration::from_secs(30), 8 * 1024 * 1024)
        );
        assert_eq!(
            window.persisted(),
            (
                "hdc.captureUIDump",
                vec![
                    ("scope", Persisted::Text("windowList".into())),
                    ("byteBudget", Persisted::Integer(8 * 1024 * 1024)),
                ]
            )
        );
        for action in [&storage, &hilog, &window] {
            assert_eq!(action.effect(), "readOnly");
            assert!(
                action
                    .lower("capture-step", None)
                    .unwrap_err()
                    .contains("capture-step has no descriptor-bound target connect key")
            );
        }
    }

    #[test]
    fn capture_requests_are_bounded_as_swift_bounds_them() {
        assert_eq!(
            Action::observe_storage(0).unwrap_err().to_string(),
            "outOfBounds(field: \"requiredBytes\", detail: \"1...8589934592\")"
        );
        assert!(Action::observe_storage(8 * 1024 * 1024 * 1024).is_ok());
        assert!(Action::observe_storage(8 * 1024 * 1024 * 1024 + 1).is_err());
        assert_eq!(
            Action::capture_hilog(601, Vec::new(), 1024)
                .unwrap_err()
                .to_string(),
            "outOfBounds(field: \"durationSeconds\", detail: \"1...600\")"
        );
        assert_eq!(
            Action::capture_hilog(5, vec!["a".into(); 17], 1024)
                .unwrap_err()
                .to_string(),
            "outOfBounds(field: \"filters\", detail: \"at most 16\")"
        );
        let long = "a".repeat(201);
        for filter in ["", "a b", "a;b", "$(x)", "\u{e9}", long.as_str()] {
            assert_eq!(
                Action::capture_hilog(5, vec![filter.into()], 1024)
                    .unwrap_err()
                    .to_string(),
                "malformed(field: \"filters\", detail: \"filter tokens are bounded ASCII, no shell fragments\")",
                "{filter:?}"
            );
        }
        assert!(Action::capture_hilog(5, vec!["a".repeat(200); 16], 1024).is_ok());
        assert_eq!(
            Action::capture_hilog(5, Vec::new(), 1023)
                .unwrap_err()
                .to_string(),
            "outOfBounds(field: \"byteBudget\", detail: \"1024...134217728\")"
        );
    }

    #[test]
    fn capture_receipts_are_judged_as_swift_judges_them() {
        let storage = Action::observe_storage(134_217_728).unwrap();
        let judge =
            |action: &Action, receipt: &Receipt| action.verify(receipt, Expected::default());
        let df = |available: &str| {
            format!(
                "Filesystem 1K-blocks Used Available Use% Mounted on\n\
                 /dev/block/data 1048576 1024 {available} 1% /data\n"
            )
        };
        assert_eq!(
            judge(&storage, &receipt(&df("1047552"))),
            verified([("availableBytes", "1072693248".into())])
        );
        assert_eq!(
            judge(&storage, &receipt(&df("16"))),
            Outcome::Failed {
                code: "insufficientDeviceStorage",
                detail: "requires 134217728 bytes; 16384 available".into(),
            }
        );
        // The last line with a count is read, whatever ends the lines; the
        // header, a column that is no count and an unbounded one read nothing.
        assert_eq!(
            judge(
                &storage,
                &receipt("h\r\na b c 999999999\r\nd e f +131072\r\n")
            ),
            verified([("availableBytes", "134217728".into())])
        );
        let nothing =
            Outcome::Unknown("storage output has no bounded available-byte observation".into());
        for output in [
            "Filesystem 1K-blocks Used Available\n".to_owned(),
            df("lots"),
            df("-1"),
            format!("h\nx y z {}\n", u64::MAX / 1024 + 1),
        ] {
            assert_eq!(judge(&storage, &receipt(&output)), nothing, "{output:?}");
        }
        let truncated = Receipt {
            truncated: true,
            ..receipt("x")
        };
        let raw = Receipt {
            stdout: vec![0xff, 0xfe],
            ..receipt("")
        };
        assert_eq!(
            judge(&storage, &raw),
            Outcome::Failed {
                code: "invalidEncoding",
                detail: "storage output is not UTF-8".into(),
            }
        );
        let hilog = Action::capture_hilog(5, Vec::new(), DEFAULT_HILOG_BUDGET).unwrap();
        assert_eq!(
            judge(&hilog, &receipt("01-01 00:00:00 I app: hello\n")),
            verified([("byteCount", "28".into())])
        );
        // HiLog keeps bytes that are not UTF-8; an empty drain is no fact.
        assert_eq!(judge(&hilog, &raw), verified([("byteCount", "2".into())]));
        let empty = Outcome::Unknown("empty capture output".into());
        assert_eq!(judge(&hilog, &receipt("")), empty);
        let over = Outcome::Failed {
            code: "truncated",
            detail: "capture exceeded its byte budget".into(),
        };
        assert_eq!(judge(&hilog, &truncated), over);
        let window = Action::CaptureWindowList;
        assert_eq!(
            judge(&window, &receipt("{\"windows\":[]}\n")),
            verified([("byteCount", "15".into())])
        );
        assert_eq!(
            judge(&window, &raw),
            Outcome::Failed {
                code: "invalidEncoding",
                detail: "UI dump is not UTF-8".into(),
            }
        );
        assert_eq!(judge(&window, &receipt("")), empty);
        assert_eq!(judge(&window, &truncated), over);
    }
}
