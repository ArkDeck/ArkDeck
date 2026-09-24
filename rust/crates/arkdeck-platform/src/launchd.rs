//! launchd's control surface for the one user-domain LaunchAgent, as Swift's
//! `LaunchAgentService` drives it: the fixed argument arrays, and a runner
//! that executes one fixed executable with them. There is no shell and no
//! device command here; the service manager only ever asks launchd about, or
//! for, `com.arkdeck.agentd` in the caller's own `gui/<uid>` domain.
//!
//! The executable is `/bin/launchctl` for the account's own home. A home
//! relocated with `CFFIXED_USER_HOME` is not the account's: its plist is not
//! the one launchd loaded for `gui/<uid>`, so booting that domain's service
//! out and bootstrapping the relocated plist into it would replace the
//! account's real service with a stranger's configuration. A relocated home
//! therefore never reaches `/bin/launchctl` — only an executable its caller
//! names for exactly that home, which is how the service manager is tested
//! without touching the account's launchd domain. (Swift's service manager
//! drives the real domain whatever the home; this is a declared difference.)
use std::ffi::OsString;
use std::io;
use std::os::unix::process::ExitStatusExt;
use std::path::{Path, PathBuf};
use std::process::{Command, Stdio};

/// The one launchd control executable for the account's own home.
pub const LAUNCHCTL: &str = "/bin/launchctl";
/// Swift `ArkDeckLaunchAgent.label`: the service and its Mach service name.
pub const AGENT_LABEL: &str = "com.arkdeck.agentd";
/// The variable naming the launchd control executable for a relocated home.
pub const RELOCATED_LAUNCHCTL: &str = "ARKDECK_LAUNCHCTL_FOR_RELOCATED_HOME";

/// Swift `LaunchAgentService.launchDomain`: `gui/<uid>`.
pub fn user_domain(uid: u32) -> String {
    format!("gui/{uid}")
}

/// `gui/<uid>/com.arkdeck.agentd`.
pub fn service_target(domain: &str) -> String {
    format!("{domain}/{AGENT_LABEL}")
}

/// Swift `isLoaded()`: `launchctl print gui/<uid>/com.arkdeck.agentd`.
pub fn print_arguments(domain: &str) -> Vec<String> {
    vec!["print".into(), service_target(domain)]
}

/// `launchctl bootout gui/<uid>/com.arkdeck.agentd`.
pub fn bootout_arguments(domain: &str) -> Vec<String> {
    vec!["bootout".into(), service_target(domain)]
}

/// `launchctl bootstrap gui/<uid> <plist>`.
pub fn bootstrap_arguments(domain: &str, plist: &Path) -> Vec<String> {
    vec![
        "bootstrap".into(),
        domain.into(),
        plist.to_string_lossy().into_owned(),
    ]
}

/// `launchctl enable gui/<uid>/com.arkdeck.agentd`, the one repair Swift's
/// bootstrap makes after repeated EIO.
pub fn enable_arguments(domain: &str) -> Vec<String> {
    vec!["enable".into(), service_target(domain)]
}

/// Swift `LaunchAgentCommandResult`.
#[derive(Clone, Debug, Default, PartialEq, Eq)]
pub struct LaunchctlOutput {
    /// The exit status, or the terminating signal's number as Swift's
    /// `Process.terminationStatus` reports it.
    pub status: i32,
    pub stdout: Vec<u8>,
    pub stderr: Vec<u8>,
}

/// Swift `LaunchAgentCommandRunning`: runs the launchd control executable with
/// one argument array.
pub trait LaunchctlRunner {
    fn run(&self, arguments: &[String]) -> io::Result<LaunchctlOutput>;
}

/// A runner of one fixed executable, never through a shell.
#[derive(Clone, Debug, PartialEq, Eq)]
pub struct LaunchctlExecutable {
    executable: Option<PathBuf>,
    refusal: Option<&'static str>,
}

impl LaunchctlExecutable {
    /// `/bin/launchctl`.
    pub fn system() -> Self {
        Self {
            executable: Some(PathBuf::from(LAUNCHCTL)),
            refusal: None,
        }
    }

    /// The executable this runner runs, if it may run one.
    pub fn executable(&self) -> Option<&Path> {
        self.executable.as_deref()
    }

    /// Why this runner refuses every call, if it does.
    pub fn refusal(&self) -> Option<&'static str> {
        self.refusal
    }

    fn refusing(reason: &'static str) -> Self {
        Self {
            executable: None,
            refusal: Some(reason),
        }
    }
}

impl LaunchctlRunner for LaunchctlExecutable {
    fn run(&self, arguments: &[String]) -> io::Result<LaunchctlOutput> {
        let Some(executable) = &self.executable else {
            return Err(io::Error::new(
                io::ErrorKind::PermissionDenied,
                self.refusal.unwrap_or("launchd is not reachable here"),
            ));
        };
        let output = Command::new(executable)
            .args(arguments)
            .stdin(Stdio::null())
            .output()?;
        Ok(LaunchctlOutput {
            status: output
                .status
                .code()
                .or_else(|| output.status.signal())
                .unwrap_or(-1),
            stdout: output.stdout,
            stderr: output.stderr,
        })
    }
}

/// The launchd control executable for the home the caller resolved:
/// `/bin/launchctl` for the account's own home, and for a relocated home only
/// an absolute executable [`RELOCATED_LAUNCHCTL`] names. Every other
/// combination yields a runner that refuses each call, before anything runs.
pub fn account_launchctl(relocated_home: bool, named: Option<OsString>) -> LaunchctlExecutable {
    match (relocated_home, named) {
        (false, None) => LaunchctlExecutable::system(),
        (false, Some(_)) => LaunchctlExecutable::refusing(
            "ARKDECK_LAUNCHCTL_FOR_RELOCATED_HOME applies only to a home relocated with \
             CFFIXED_USER_HOME; the account's own service is driven by /bin/launchctl",
        ),
        (true, None) => LaunchctlExecutable::refusing(
            "a home relocated with CFFIXED_USER_HOME never drives the account's launchd \
             domain; name its launchd control executable with \
             ARKDECK_LAUNCHCTL_FOR_RELOCATED_HOME",
        ),
        (true, Some(named)) => {
            let path = PathBuf::from(named);
            if path.is_absolute() && path != Path::new(LAUNCHCTL) {
                LaunchctlExecutable {
                    executable: Some(path),
                    refusal: None,
                }
            } else {
                LaunchctlExecutable::refusing(
                    "ARKDECK_LAUNCHCTL_FOR_RELOCATED_HOME must name an absolute executable \
                     other than /bin/launchctl",
                )
            }
        }
    }
}

/// [`account_launchctl`] for this process's environment.
pub fn account_launchctl_from_environment() -> LaunchctlExecutable {
    let relocated = std::env::var_os("CFFIXED_USER_HOME").is_some_and(|value| !value.is_empty());
    account_launchctl(relocated, std::env::var_os(RELOCATED_LAUNCHCTL))
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn the_argument_arrays_are_swifts() {
        let domain = user_domain(501);
        assert_eq!(domain, "gui/501");
        assert_eq!(
            print_arguments(&domain),
            ["print", "gui/501/com.arkdeck.agentd"]
        );
        assert_eq!(
            bootout_arguments(&domain),
            ["bootout", "gui/501/com.arkdeck.agentd"]
        );
        assert_eq!(
            bootstrap_arguments(
                &domain,
                Path::new("/Users/a/Library/LaunchAgents/com.arkdeck.agentd.plist")
            ),
            [
                "bootstrap",
                "gui/501",
                "/Users/a/Library/LaunchAgents/com.arkdeck.agentd.plist"
            ]
        );
        assert_eq!(
            enable_arguments(&domain),
            ["enable", "gui/501/com.arkdeck.agentd"]
        );
    }

    #[test]
    fn a_relocated_home_never_reaches_the_system_launchctl() {
        assert_eq!(
            account_launchctl(false, None).executable(),
            Some(Path::new("/bin/launchctl"))
        );
        for (relocated, named) in [
            (true, None),
            (false, Some("/private/tmp/fake-launchctl")),
            (true, Some("relative/launchctl")),
            (true, Some("/bin/launchctl")),
        ] {
            let runner = account_launchctl(relocated, named.map(OsString::from));
            assert_eq!(runner.executable(), None, "{relocated} {named:?}");
            let error = runner.run(&print_arguments("gui/501")).unwrap_err();
            assert_eq!(error.kind(), io::ErrorKind::PermissionDenied);
        }
        let named = account_launchctl(true, Some("/private/tmp/fake-launchctl".into()));
        assert_eq!(
            named.executable(),
            Some(Path::new("/private/tmp/fake-launchctl"))
        );
    }

    #[test]
    fn the_runner_passes_its_arguments_as_an_array_and_reports_the_status() {
        let runner = LaunchctlExecutable {
            executable: Some(PathBuf::from("/bin/sh")),
            refusal: None,
        };
        let output = runner
            .run(&[
                "-c".into(),
                "printf '%s|' \"$@\"; printf err >&2; exit 5".into(),
                "sh".into(),
                "gui/501/com.arkdeck.agentd".into(),
                "a b;c".into(),
            ])
            .unwrap();
        assert_eq!(output.status, 5);
        assert_eq!(output.stdout, b"gui/501/com.arkdeck.agentd|a b;c|");
        assert_eq!(output.stderr, b"err");
    }
}
