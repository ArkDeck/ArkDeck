import ArkDeckClientKit
import Foundation

/// The Settings pane's diagnostic bundle: the support-bundle contract the CLI
/// shares, adapted to the ClientKit Settings facade the App composes it into.
/// The exporter stays here because it reads this host's files through
/// ArkDeckStorage, which ClientKit does not import.
public struct RuntimeSupportBundleSettingsExporter: SettingsDiagnosticBundleExporting {
  private let provider: any RuntimeSupportBundleProviding

  public init() {
    self.init(provider: RuntimeSupportBundleApplicationFacade.make())
  }

  init(provider: any RuntimeSupportBundleProviding) {
    self.provider = provider
  }

  public func preview(at destination: URL) async throws -> SettingsDiagnosticBundlePreview {
    let preview = try await provider.preview(at: destination)
    return SettingsDiagnosticBundlePreview(
      scopeSHA256: preview.scopeSHA256,
      includedEntries: preview.includedEntries,
      estimatedBytes: preview.estimatedBytes,
      deviceRawExcluded: preview.deviceRawExcluded,
      sensitiveDataWarning: preview.sensitiveDataWarning)
  }

  public func export(to destination: URL, approvedScopeSHA256: String) async throws -> URL {
    let receipt = try await provider.export(
      to: destination, approvedScopeSHA256: approvedScopeSHA256)
    return URL(filePath: receipt.destination, directoryHint: .isDirectory)
  }
}
