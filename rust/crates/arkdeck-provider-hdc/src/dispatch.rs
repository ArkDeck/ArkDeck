//! Swift `DescriptorBoundProcessDispatcher.hdc(resolver:)`: the one process
//! dispatch every device-scoped HDC plan runs through, on the verified tool
//! runner. A plan names its arguments and its budget; this owns the
//! executable and the child's environment, and reads what came back into
//! Swift's receipt or one of its two dispatch failures. Nothing here proves
//! or watches an HDC server: that is the supervisor's lease, and Swift's
//! dispatcher does not gate a run on it either — a server that is gone is
//! the client's own error and exit status, judged by the step.
use crate::{DispatchFailure, HdcDispatch, ProcessPlan, Receipt};
use arkdeck_platform::{ToolLimits, ToolRequest, ToolRunError, ToolTermination, VerifiedTool};
use std::ffi::OsString;

/// The one variable a daemon launcher may hand to hdc children, so that they
/// address the selected server and not the default one (Swift
/// `HDCServerEndpointSelector.inheritedPortChildEnvironment`).
pub const SERVER_PORT_VARIABLE: &str = "OHOS_HDC_SERVER_PORT";

/// Swift `RockchipHostProcessDiagnostics.signalDeath`: a child that dies on
/// a signal is a host fault, reported by the same sentence everywhere so that
/// a preflight can read the signal back out of it.
const SIGNAL_PREFIX: &str = "process died on signal ";
const DIAGNOSTIC_REPORTS: &str = "~/Library/Logs/DiagnosticReports/";

/// The registered executable, dispatched through the verified tool runner
/// with the runner's clean base environment and, when the daemon inherited a
/// valid one, the server port. The plan never carries either.
pub struct ProcessDispatch {
    tool: VerifiedTool,
    environment: Vec<(OsString, OsString)>,
}

impl ProcessDispatch {
    /// The executable to dispatch and the server port the daemon inherited,
    /// if any: a valid one (1–65535) is named to every child, anything else
    /// is dropped rather than forwarded, so that a rejected value never
    /// redirects a child while the daemon itself keeps the documented
    /// default (Swift `inheritedPortChildEnvironment`).
    pub fn new(tool: VerifiedTool, inherited_server_port: Option<&str>) -> Self {
        let environment = inherited_server_port
            .and_then(valid_port)
            .map(|port| {
                vec![(
                    OsString::from(SERVER_PORT_VARIABLE),
                    OsString::from(port.to_string()),
                )]
            })
            .unwrap_or_default();
        Self { tool, environment }
    }

    /// The daemon's own inherited server port, as the composition reads it
    /// once; validated by [`ProcessDispatch::new`].
    pub fn inherited_server_port() -> Option<String> {
        std::env::var(SERVER_PORT_VARIABLE).ok()
    }

    pub fn tool_sha256(&self) -> &str {
        self.tool.sha256()
    }

    /// What every child is told beyond the runner's clean base.
    pub fn environment(&self) -> &[(OsString, OsString)] {
        &self.environment
    }
}

/// Swift `HDCServerEndpointSelector.validPort`: an integer in 1...65535,
/// nothing else.
fn valid_port(value: &str) -> Option<u16> {
    let port: u16 = value.parse().ok()?;
    (port >= 1).then_some(port)
}

fn signal_death(signal: i32) -> String {
    format!(
        "{SIGNAL_PREFIX}{signal}; the child never reached its own semantic boundary. \
         Its crash report is in {DIAGNOSTIC_REPORTS} (look for a same-second entry \
         named after the executable)."
    )
}

impl HdcDispatch for ProcessDispatch {
    /// Swift `DescriptorBoundProcessDispatcher.execute`: an exited child is a
    /// receipt with its exit status, both streams and whether either went
    /// past the plan's capture; a timeout or a signal leaves the outcome
    /// unobservable; a refusal of the budget, the environment or the
    /// executable's identity means nothing ran.
    fn dispatch(&self, plan: &ProcessPlan) -> Result<Receipt, DispatchFailure> {
        let arguments: Vec<OsString> = plan.arguments.iter().map(OsString::from).collect();
        let request = ToolRequest {
            arguments: &arguments,
            environment: &self.environment,
            working_directory: None,
            limits: ToolLimits {
                timeout: plan.timeout,
                capture_bytes: plan.capture_bytes,
            },
        };
        let execution = match self.tool.run_tool(&request, &|| false) {
            Ok(execution) => execution,
            Err(ToolRunError::Refused(error)) => {
                return Err(DispatchFailure::Refused(format!(
                    "dispatch refused: {error}"
                )));
            }
            Err(ToolRunError::Unobservable(error)) => {
                return Err(DispatchFailure::Unobservable(format!(
                    "dispatch outcome unobservable: {error}"
                )));
            }
        };
        match execution.termination {
            ToolTermination::Exited(exit_status) => Ok(Receipt {
                exit_status,
                stdout: execution.stdout,
                stderr: execution.stderr,
                truncated: execution.truncated,
                duration: execution.duration,
            }),
            ToolTermination::TimedOut => Err(DispatchFailure::Unobservable(
                "process timed out before completion".into(),
            )),
            ToolTermination::Signalled(signal) => {
                Err(DispatchFailure::Unobservable(signal_death(signal)))
            }
            ToolTermination::Cancelled { .. } => Err(DispatchFailure::Unobservable(
                "dispatch cancelled before the child ended".into(),
            )),
        }
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn only_a_port_in_range_is_valid() {
        assert_eq!(valid_port("8710"), Some(8710));
        assert_eq!(valid_port("1"), Some(1));
        assert_eq!(valid_port("65535"), Some(65535));
        assert_eq!(valid_port("+8710"), Some(8710));
        assert_eq!(valid_port("0"), None);
        assert_eq!(valid_port("65536"), None);
        assert_eq!(valid_port("-1"), None);
        assert_eq!(valid_port(" 8710"), None);
        assert_eq!(valid_port("8710.0"), None);
        assert_eq!(valid_port("port"), None);
        assert_eq!(valid_port(""), None);
    }

    #[test]
    fn a_signal_death_reads_as_swift_composes_it() {
        assert_eq!(
            signal_death(9),
            "process died on signal 9; the child never reached its own semantic boundary. \
             Its crash report is in ~/Library/Logs/DiagnosticReports/ (look for a \
             same-second entry named after the executable)."
        );
    }
}
