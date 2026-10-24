import Foundation

// The support bundle's production provider, shared by the App's Settings pane
// and the Swift CLI's `runtime support-bundle`. It writes App metadata and the
// redacted tool placeholder into the directory the user chose, through
// `LocalDiagnosticBundleExporter`, and reads no Runtime storage
// (docs/ArchitectureRules.md).

public enum RuntimeSupportBundleApplicationFacade {
  public static func make() -> any RuntimeSupportBundleProviding {
    ProductionRuntimeSupportBundleProvider(bundle: .main)
  }
}

private actor ProductionRuntimeSupportBundleProvider: RuntimeSupportBundleProviding {
  private let exporter: LocalDiagnosticBundleExporter?
  private let metadata: DiagnosticBundleMetadata?

  init(bundle: Bundle) {
    exporter = try? LocalDiagnosticBundleExporter()
    metadata = try? DiagnosticBundleMetadata(
      appName: "ArkDeck",
      appVersion: Self.bounded(
        bundle.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String,
        fallback: "development"),
      buildVersion: Self.bounded(
        bundle.object(forInfoDictionaryKey: "CFBundleVersion") as? String,
        fallback: "development"),
      platform: Self.platform,
      architecture: Self.architecture)
  }

  func preview(at destination: URL) throws -> RuntimeSupportBundlePreview {
    guard let exporter else { throw RuntimeSupportBundleServiceError.unavailable }
    do {
      return Self.presentation(try exporter.preview(try request(destination: destination)))
    } catch {
      throw Self.map(error)
    }
  }

  func export(to destination: URL, approvedScopeSHA256: String) throws
    -> RuntimeSupportBundleExportReceipt
  {
    guard let exporter else { throw RuntimeSupportBundleServiceError.unavailable }
    do {
      let request = try request(destination: destination)
      let current = try exporter.preview(request)
      guard current.scopeSHA256 == approvedScopeSHA256 else {
        throw RuntimeSupportBundleServiceError.previewMismatch
      }
      let materialized = try exporter.export(
        request, trigger: .userInitiated, approvedPreview: current)
      return RuntimeSupportBundleExportReceipt(
        destination: materialized.root.standardizedFileURL.path,
        preview: Self.presentation(materialized.preview))
    } catch let error as RuntimeSupportBundleServiceError {
      throw error
    } catch {
      throw Self.map(error)
    }
  }

  private func request(destination: URL) throws -> LocalDiagnosticBundleRequest {
    guard let metadata else { throw RuntimeSupportBundleServiceError.unavailable }
    return LocalDiagnosticBundleRequest(
      destination: destination,
      metadata: metadata,
      tool: DiagnosticToolPlaceholder(
        path: .redacted,
        version: .unverified,
        serverEndpoint: .redacted,
        serverOwnership: .unverified),
      logs: [])
  }

  private static func presentation(
    _ preview: LocalDiagnosticBundlePreview
  ) -> RuntimeSupportBundlePreview {
    RuntimeSupportBundlePreview(
      scopeSHA256: preview.scopeSHA256,
      includedEntries: preview.includedEntries,
      estimatedBytes: preview.estimatedBytes,
      deviceRawExcluded: preview.deviceRawExcluded,
      sensitiveDataWarning: preview.sensitiveDataWarning)
  }

  private static func map(_ error: any Error) -> RuntimeSupportBundleServiceError {
    guard let error = error as? LocalDiagnosticBundleError else { return .ioFailure }
    switch error {
    case .previewScopeMismatch:
      return .previewMismatch
    case .destinationAlreadyExists:
      return .destinationAlreadyExists
    case .bundleQuotaExceeded:
      return .quotaExceeded
    case .exportOutcomeUnknown:
      return .outcomeUnknown
    case .invalidInput, .explicitUserInitiationRequired:
      return .invalidDestination
    case .fileOperationFailed:
      return .ioFailure
    }
  }

  private static func bounded(_ value: String?, fallback: String) -> String {
    guard let value, !value.isEmpty else { return fallback }
    return String(value.prefix(256))
  }

  private static var platform: String {
    let version = ProcessInfo.processInfo.operatingSystemVersion
    return "macOS \(version.majorVersion).\(version.minorVersion).\(version.patchVersion)"
  }

  private static var architecture: String {
    #if arch(arm64)
      "arm64"
    #elseif arch(x86_64)
      "x86_64"
    #else
      "unknown"
    #endif
  }
}
