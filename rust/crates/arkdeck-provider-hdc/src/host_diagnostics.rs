//! Swift `RockchipHostProcessDiagnostics`: the host-side process failure
//! vocabulary shared by every identity-bound spawn. A child that dies on a
//! signal is a *host* fault, not a device outcome, and the four campaigns lost
//! on 2026-08-04 proved how expensive it is to report it as a bare number: the
//! real cause (the App Sandbox aborting the child inside
//! `_libsecinit_appsandbox`) was only recoverable from macOS crash reports
//! afterwards. The message is composed here so the dispatch and the Loader
//! transition say the same thing, and so a caller can read the signal back
//! out of a failure it caught instead of opening a spawn face of its own.

/// Where macOS writes the crash report of a signalled child.
pub const DIAGNOSTIC_REPORTS_DIRECTORY: &str = "~/Library/Logs/DiagnosticReports/";

const SIGNAL_PREFIX: &str = "process died on signal ";

/// Swift `signalDeath(_:)`.
pub fn signal_death(signal: i32) -> String {
    format!(
        "{SIGNAL_PREFIX}{signal}; the child never reached its own semantic boundary. \
         Its crash report is in {DIAGNOSTIC_REPORTS_DIRECTORY} (look for a same-second entry \
         named after the executable)."
    )
}

/// Swift `signalNumber(inFailureDescription:)`: the signal carried by a
/// message [`signal_death`] composed, or `None` for any other failure text.
pub fn signal_number(description: &str) -> Option<i32> {
    let (_, after) = description.split_once(SIGNAL_PREFIX)?;
    let digits: String = after.chars().take_while(char::is_ascii_digit).collect();
    digits.parse().ok()
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn a_signal_death_names_the_signal_and_points_at_its_crash_report() {
        let message = signal_death(9);
        assert_eq!(
            message,
            "process died on signal 9; the child never reached its own semantic boundary. Its \
             crash report is in ~/Library/Logs/DiagnosticReports/ (look for a same-second entry \
             named after the executable)."
        );
        assert_eq!(signal_number(&message), Some(9));
        assert_eq!(signal_number(&signal_death(15)), Some(15));
        assert_eq!(
            signal_number(&format!(
                "dispatch outcome unobservable: {}",
                signal_death(6)
            )),
            Some(6)
        );
    }

    #[test]
    fn any_other_failure_carries_no_signal() {
        assert_eq!(signal_number("process timed out before completion"), None);
        assert_eq!(signal_number("process died on signal abc"), None);
        assert_eq!(signal_number(""), None);
    }
}
