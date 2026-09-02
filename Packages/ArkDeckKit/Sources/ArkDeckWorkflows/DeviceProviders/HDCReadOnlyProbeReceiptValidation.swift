import ArkDeckOpenHarmony
import ArkDeckProcess
import Foundation

/// HDC may report a transport or authorization failure in stdout while still
/// exiting zero. Read-only capability probes must classify those markers
/// before treating stdout as device facts.
enum HDCReadOnlyProbeReceiptValidation {
  static func requireNoSemanticFailure(
    _ receipt: ProviderSubprocessReceipt,
    context: String
  ) throws {
    if let reason = semanticFailureReason(stdout: receipt.stdout, stderr: receipt.stderr) {
      throw DeviceProviderError.factsUnavailable("\(context): \(reason)")
    }
  }

  /// The same marker classification for a receipt that has already been
  /// captured by another path (`debug.template@1` verifies the engine's
  /// process receipt rather than a subprocess receipt).
  static func semanticFailureReason(stdout: Data, stderr: Data) -> String? {
    var parser = HDCSemanticOutputParser()
    parser.consume(ProcessOutputChunk(stream: .stdout, bytes: stdout))
    parser.consume(ProcessOutputChunk(stream: .stderr, bytes: stderr))

    guard case .failure(let failure) = parser.finish(exitCode: 0) else { return nil }
    let reason: String
    switch failure {
    case .unauthorized:
      reason = "target authorization is unavailable"
    case .offline:
      reason = "target is offline"
    case .explicitFailureMarker:
      reason = "HDC reported an explicit failure"
    case .nonZeroExit(let status):
      reason = "HDC exited \(status)"
    }
    return reason
  }
}
