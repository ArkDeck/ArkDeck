import Foundation

/// The bounded local product contract shared by the App and CLI for support exports.
///
/// Callers receive only the exact preview they must approve and a receipt for the
/// resulting directory. They never receive the storage exporter, source paths, raw
/// Session data, or a way to turn device bytes back on.
public struct RuntimeSupportBundlePreview: Codable, Equatable, Sendable {
  public let schemaVersion: String
  public let scopeSHA256: String
  public let includedEntries: [String]
  public let estimatedBytes: UInt64
  public let deviceRawExcluded: Bool
  public let sensitiveDataWarning: String

  public init(
    scopeSHA256: String,
    includedEntries: [String],
    estimatedBytes: UInt64,
    deviceRawExcluded: Bool,
    sensitiveDataWarning: String
  ) {
    schemaVersion = "arkdeck.runtime-support-bundle-preview/1"
    self.scopeSHA256 = scopeSHA256
    self.includedEntries = includedEntries
    self.estimatedBytes = estimatedBytes
    self.deviceRawExcluded = deviceRawExcluded
    self.sensitiveDataWarning = sensitiveDataWarning
  }
}

public struct RuntimeSupportBundleExportReceipt: Codable, Equatable, Sendable {
  public let schemaVersion: String
  public let status: String
  public let destination: String
  public let scopeSHA256: String
  public let exportedBytes: UInt64
  public let deviceRawExcluded: Bool

  public init(destination: String, preview: RuntimeSupportBundlePreview) {
    schemaVersion = "arkdeck.runtime-support-bundle-export/1"
    status = "exported"
    self.destination = destination
    scopeSHA256 = preview.scopeSHA256
    exportedBytes = preview.estimatedBytes
    deviceRawExcluded = preview.deviceRawExcluded
  }
}

public enum RuntimeSupportBundleServiceError: Error, Equatable, Sendable {
  case unavailable
  case invalidDestination
  case previewMismatch
  case destinationAlreadyExists
  case quotaExceeded
  case outcomeUnknown
  case ioFailure
}

public protocol RuntimeSupportBundleProviding: Sendable {
  func preview(at destination: URL) async throws -> RuntimeSupportBundlePreview
  func export(to destination: URL, approvedScopeSHA256: String) async throws
    -> RuntimeSupportBundleExportReceipt
}
