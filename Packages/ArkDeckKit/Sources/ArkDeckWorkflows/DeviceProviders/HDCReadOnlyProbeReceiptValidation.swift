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
    var parser = HDCSemanticOutputParser()
    parser.consume(ProcessOutputChunk(stream: .stdout, bytes: receipt.stdout))
    parser.consume(ProcessOutputChunk(stream: .stderr, bytes: receipt.stderr))

    guard case .failure(let failure) = parser.finish(exitCode: 0) else { return }
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
    throw DeviceProviderError.factsUnavailable("\(context): \(reason)")
  }
}
