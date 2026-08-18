import Foundation

/// Closed, non-sensitive diagnoses emitted by the current Runtime when the
/// HDC-to-Loader transition cannot be proven. They contain no campaign,
/// process-output or historical authority surface.
public enum RockchipFlashRuntimeDiagnostic: String, Sendable, Equatable, CaseIterable {
  case enterLoaderHDCNoCleanReceipt
  case enterLoaderCommandCleanLoaderNotObserved
}

/// Errors still shared by the current binding, bootloader-status and native
/// ArkForge execution-support paths.
public enum RockchipFlashExecutionError: Error, Sendable, Equatable, LocalizedError {
  case productionConfigurationUnavailable(String)
  case admissionRejected(String)

  public var errorDescription: String? {
    switch self {
    case .productionConfigurationUnavailable(let detail):
      "product execution configuration unavailable: \(detail)"
    case .admissionRejected(let detail):
      "trusted admission rejected: \(detail)"
    }
  }
}
