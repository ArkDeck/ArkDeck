//! The typed HDC actions of `observe.device@1`, as Swift's HDC provider
//! (`HDCObservationProviderAdapter`) chooses, lowers and verifies them: a
//! closed vocabulary with no caller-supplied argv, each action lowered to the
//! exact arguments the executor runs, and each receipt judged by the
//! observation parsers. What runs a lowered plan is an [`HdcDispatch`]; this
//! module starts nothing itself.
use crate::{ParseError, parse_client_version, parse_server_check, parse_target_list};
use arkdeck_platform::{ProcessLimits, VerifiedTool};
use sha2::{Digest, Sha256};
use std::collections::BTreeMap;
use std::ffi::OsString;
use std::io;
use std::time::{Duration, Instant};
use unicode_segmentation::UnicodeSegmentation;

/// Swift `HDCObservationProviderAdapter.lower`: every observe action has 15 s.
const TIMEOUT: Duration = Duration::from_secs(15);
/// Swift `DescriptorBoundProcessDispatcher`'s default capture.
const CAPTURE_BYTES: usize = 8 * 1024 * 1024;
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
#[derive(Clone, Copy, Debug, Eq, PartialEq)]
pub enum Action {
    ObserveTool,
    ObserveServer,
    /// The one target row the binding's connect key names.
    ObserveDevice,
    QueryProperty(Property),
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

    /// Swift `TypedProviderAction.effect`.
    pub fn effect(self) -> &'static str {
        match self {
            Self::ObserveTool | Self::ObserveServer => "hostOnly",
            Self::ObserveDevice | Self::QueryProperty(_) => "readOnly",
        }
    }

    /// Swift `PersistedTypedProviderAction`: the kind and arguments a Job
    /// record keeps before the action's intent can be dispatched.
    pub fn persisted(self) -> (&'static str, Vec<(&'static str, &'static str)>) {
        match self {
            Self::ObserveTool => ("hdc.observeTool", Vec::new()),
            Self::ObserveServer => ("hdc.observeServer", Vec::new()),
            Self::ObserveDevice => (
                "hdc.observeDevice",
                vec![("connectKey", "resolved-by-binding")],
            ),
            Self::QueryProperty(property) => {
                ("hdc.queryProperty", vec![("property", property.key())])
            }
        }
    }

    /// Swift `lower`: the arguments the executor runs. A property read names
    /// its target by the binding's connect key, and has none without one.
    pub fn lower(self, step_id: &str, connect_key: Option<&str>) -> Result<ProcessPlan, String> {
        let arguments: Vec<String> = match self {
            Self::ObserveTool => vec!["-v".into()],
            Self::ObserveServer => vec!["checkserver".into()],
            Self::ObserveDevice => vec!["list".into(), "targets".into(), "-v".into()],
            Self::QueryProperty(property) => {
                let Some(key) = connect_key.filter(|key| !key.is_empty()) else {
                    return Err(format!(
                        "factsUnavailable(\"{step_id} has no descriptor-bound target connect key\")"
                    ));
                };
                ["-t", key, "shell", "param", "get", property.key()]
                    .map(String::from)
                    .to_vec()
            }
        };
        Ok(ProcessPlan {
            arguments,
            timeout: TIMEOUT,
            capture_bytes: CAPTURE_BYTES,
        })
    }

    /// Swift `verify` for these actions, which never read the exit status.
    pub fn verify(self, receipt: &Receipt, expected: Expected<'_>) -> Outcome {
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
            Self::QueryProperty(property) => query_property(receipt, property),
        }
    }
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

/// The dispatch of the isolated development owner's fixture tool: the pinned
/// executable, launched through its inode with no environment of its own and
/// within the plan's budget. A registered HDC is never run through it: that
/// needs the existing-server identity proof, which macOS does not have yet.
pub struct FixtureDispatch {
    tool: VerifiedTool,
}

impl FixtureDispatch {
    pub fn new(tool: VerifiedTool) -> Self {
        Self { tool }
    }

    pub fn tool_sha256(&self) -> &str {
        self.tool.sha256()
    }
}

impl HdcDispatch for FixtureDispatch {
    fn dispatch(&self, plan: &ProcessPlan) -> Result<Receipt, DispatchFailure> {
        let arguments: Vec<OsString> = plan.arguments.iter().map(OsString::from).collect();
        let limits = ProcessLimits {
            timeout: plan.timeout,
            max_output_bytes: plan.capture_bytes,
        };
        let started = Instant::now();
        match self.tool.run_read_only(&arguments, limits) {
            Ok(output) => match output.status.code() {
                Some(exit_status) => Ok(Receipt {
                    exit_status,
                    stdout: output.stdout,
                    stderr: output.stderr,
                    truncated: false,
                    duration: started.elapsed(),
                }),
                None => Err(DispatchFailure::Unobservable(
                    "process ended without an exit status".into(),
                )),
            },
            Err(error) => classify(&error, started.elapsed()),
        }
    }
}

/// How a read-only run that returned no output maps onto Swift's classes: a
/// deadline leaves the outcome unknown, output beyond the budget is a
/// truncated receipt (the process itself is not reported), and a refusal of
/// the executable's identity means nothing ran.
fn classify(error: &io::Error, duration: Duration) -> Result<Receipt, DispatchFailure> {
    match error.kind() {
        io::ErrorKind::TimedOut => Err(DispatchFailure::Unobservable(
            "process timed out before completion".into(),
        )),
        io::ErrorKind::FileTooLarge => Ok(Receipt {
            exit_status: -1,
            stdout: Vec::new(),
            stderr: Vec::new(),
            truncated: true,
            duration,
        }),
        io::ErrorKind::NotFound | io::ErrorKind::PermissionDenied | io::ErrorKind::InvalidInput => {
            Err(DispatchFailure::Refused(format!(
                "dispatch refused: {error}"
            )))
        }
        _ => Err(DispatchFailure::Unobservable(format!(
            "dispatch outcome unobservable: {error}"
        ))),
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
}
