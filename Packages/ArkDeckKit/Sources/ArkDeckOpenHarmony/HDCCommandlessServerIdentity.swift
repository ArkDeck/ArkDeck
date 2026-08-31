import Darwin
import Foundation

/// Read-only composition of the existing published identity families. It
/// launches no HDC client (including checkserver, which may bootstrap a
/// server), and never observes health or grants managed ownership.
package enum HDCCommandlessServerIdentity {
  /// The existing managed-process predicate also verifies complete argv and
  /// listener ownership. Bracket it with the observed birth identity so PID
  /// reuse between status observation and ownership inspection fails closed.
  package static func verifiesManagedProcess(_ receipt: HDCServerProcessIdentityReceipt, arguments: [String]) -> Bool {
    func sameBirth() -> Bool {
      var info = proc_bsdinfo()
      return receipt.pid > 0 && proc_pidinfo(receipt.pid, PROC_PIDTBSDINFO, 0, &info, Int32(MemoryLayout<proc_bsdinfo>.size)) == MemoryLayout<proc_bsdinfo>.size &&
        info.pbi_start_tvsec == receipt.startSeconds && info.pbi_start_tvusec == receipt.startMicroseconds
    }
    guard let generation = receipt.stableGeneration, sameBirth() else { return false }
    let valid = SystemHDCManagedServerProcessInspector().matches(.init(endpoint: receipt.endpoint, pid: receipt.pid,
      toolPath: receipt.executablePath, arguments: arguments, generation: generation,
      version: .unknown(reason: "process identity does not prove reported server version")))
    return valid && sameBirth()
  }

  package static func clientVersion(sha256: String) -> String? {
    if sha256 == HDCReadOnlyProbeRegistry.targetExecutableSHA256 { return HDCReadOnlyProbeRegistry.targetToolVersion }
    if sha256 == HDCSupervisorObservationProbeCatalog.targetExecutableSHA256 { return HDCSupervisorObservationProbeCatalog.targetToolVersion }
    return nil
  }

  package static func observe(toolchain: HDCCandidate, endpoint: HDCServerEndpoint) async -> HDCSupervisorObservationResult {
    let observer: any HDCServerProcessIdentityObserving
    if toolchain.sha256 == HDCSupervisorObservationProbeCatalog.targetExecutableSHA256,
      endpoint.rawValue == HDCSupervisorObservationProbeCatalog.exactEndpoint {
      observer = HDCExact320FSystemIdentityObserver.supervisorObservationProduction
    } else if toolchain.sha256 == HDCReadOnlyProbeRegistry.targetExecutableSHA256 {
      observer = SystemHDCServerProcessIdentityObserver()
    } else {
      return .init(classification: .unsupported(reason: "selected executable or endpoint has no published commandless identity family"))
    }
    let result = await withTaskGroup(of: HDCServerProcessIdentityRawObservation.self) { group in
      group.addTask { await observer.observe(endpoint: endpoint, selectedToolchain: toolchain) }
      group.addTask {
        do { try await Task.sleep(for: .milliseconds(1000)); return .timedOut }
        catch { return .cancelled }
      }
      let first = await group.next() ?? .unknown(reason: "identity observation produced no result")
      group.cancelAll()
      return first
    }
    switch result {
    case .observed(let receipt):
      guard receipt.pid > 0, receipt.startMicroseconds < 1_000_000,
        receipt.endpoint == endpoint, receipt.executableSHA256 == toolchain.sha256,
        receipt.executablePath == toolchain.path.resolvingSymlinksInPath().standardizedFileURL,
        let generation = receipt.stableGeneration else {
        return .init(classification: .unknown(reason: "observed identity does not match the selected tool and endpoint"))
      }
      return .init(classification: .observed(generation: generation), identity: receipt)
    case .unavailable(let reason): return .init(classification: .unavailable(reason: reason))
    case .unknown(let reason): return .init(classification: .unknown(reason: reason))
    case .timedOut: return .init(classification: .timedOut)
    case .cancelled: return .init(classification: .cancelled)
    }
  }
}
