// Host-side process failure vocabulary shared by every identity-bound spawn
// (TASK-AIN-019).
//
// A child that dies on a signal is a *host* fault, not a device outcome, and
// the four campaigns lost on 2026-08-04 proved how expensive it is to report
// it as a bare number: the real cause (App Sandbox aborting the child inside
// `_libsecinit_appsandbox`) was only recoverable by digging through macOS
// crash reports afterwards. The message is composed here so the runner, the
// descriptor-bound dispatcher and the flash preflight all say the same thing —
// and so the preflight can read the signal back out of a failure it caught
// rather than re-implementing a spawn face of its own.
enum RockchipHostProcessDiagnostics {
  static let diagnosticReportsDirectory = "~/Library/Logs/DiagnosticReports/"

  private static let signalPrefix = "process died on signal "

  static func signalDeath(_ signal: Int32) -> String {
    "\(signalPrefix)\(signal); the child never reached its own semantic "
      + "boundary. Its crash report is in \(diagnosticReportsDirectory) "
      + "(look for a same-second entry named after the executable)."
  }

  /// The signal carried by a message `signalDeath(_:)` composed, or nil for
  /// any other failure text. Parsing our own canonical prefix keeps the
  /// preflight on the existing runner instead of opening a second spawn face.
  static func signalNumber(inFailureDescription description: String) -> Int32? {
    guard let range = description.range(of: signalPrefix) else { return nil }
    let digits = description[range.upperBound...].prefix { $0.isNumber }
    return Int32(digits)
  }
}
