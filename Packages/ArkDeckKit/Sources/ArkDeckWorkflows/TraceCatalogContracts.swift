import Foundation

/// Host-side bindings for the two versioned catalogs consumed by the Trace workflow.
/// The hashes are drift guards from TASK-TR-002 readiness; this type does not parse or
/// claim support for any real hitrace/bytrace output family.
public enum TraceCatalogContract {
  public static let presetCatalogID = "trace-presets"
  public static let presetCatalogVersion = "1.0.0"
  public static let presetCatalogSHA256 =
    "12c0f0502cb17832f66223670a124b6fe48e903883a01c44a9cc4340fc2628cf"

  public static let debugParameterCatalogID = "attachment-debug-profile"
  public static let debugParameterCatalogVersion = "1.0.0"
  public static let debugParameterCatalogSHA256 =
    "10ee4c38c4728a344a39b98b56759adae50323c260ad52345eaf4d5e4f978acc"
}

public enum TracePresetID: String, CaseIterable, Codable, Equatable, Sendable {
  case attachmentPanorama
  case arkuiDeep
  case renderAnimation
  case schedulingIpc
  case io
  case custom
}

public struct TracePresetDefinition: Equatable, Sendable {
  public let id: TracePresetID
  public let logicalTags: [String]
  public let historicalBufferValue: Int?
  public let bufferUnitRequiresAdapterConfirmation: Bool
  public let displaysResourceWarning: Bool

  public init(
    id: TracePresetID,
    logicalTags: [String],
    historicalBufferValue: Int? = nil,
    bufferUnitRequiresAdapterConfirmation: Bool = false,
    displaysResourceWarning: Bool = false
  ) {
    self.id = id
    self.logicalTags = logicalTags
    self.historicalBufferValue = historicalBufferValue
    self.bufferUnitRequiresAdapterConfirmation = bufferUnitRequiresAdapterConfirmation
    self.displaysResourceWarning = displaysResourceWarning
  }
}

public enum TracePresetCatalog {
  public static let definitions: [TracePresetDefinition] = [
    TracePresetDefinition(
      id: .attachmentPanorama,
      logicalTags: [
        "sched", "freq", "ace", "app", "binder", "disk", "ohos", "graphic", "sync",
        "workq", "ability",
      ],
      historicalBufferValue: 327_680,
      bufferUnitRequiresAdapterConfirmation: true,
      displaysResourceWarning: true),
    TracePresetDefinition(
      id: .arkuiDeep,
      logicalTags: ["ace", "app", "ability", "graphic", "ohos", "sched", "freq", "sync"]),
    TracePresetDefinition(
      id: .renderAnimation,
      logicalTags: ["graphic", "ace", "app", "sched", "freq", "sync"]),
    TracePresetDefinition(
      id: .schedulingIpc,
      logicalTags: ["sched", "freq", "workq", "binder", "sync"]),
    TracePresetDefinition(id: .io, logicalTags: ["disk", "sched", "workq", "binder"]),
    TracePresetDefinition(id: .custom, logicalTags: []),
  ]

  public static func definition(for id: TracePresetID) -> TracePresetDefinition {
    // CaseIterable and the catalog table are both closed. A missing row is a programming
    // invariant, not a reason to guess a preset at runtime.
    definitions.first { $0.id == id }!
  }
}

public enum TraceConfigurationValidationError: Error, Equatable, Sendable {
  case durationMustBePositive
  case bufferValueMustBePositive
  case customPresetRequiresTags
  case invalidTag(String)
  case duplicateTag(String)
  case emptySupportedAlternative
  case explicitAcceptanceRequired
}

public struct TraceConfigurationRequest: Equatable, Sendable {
  public let presetID: TracePresetID
  public let customTags: [String]
  public let durationMilliseconds: Int
  public let requestedBufferValue: Int?

  public init(
    presetID: TracePresetID,
    customTags: [String] = [],
    durationMilliseconds: Int,
    requestedBufferValue: Int? = nil
  ) throws {
    guard durationMilliseconds > 0 else {
      throw TraceConfigurationValidationError.durationMustBePositive
    }
    if let requestedBufferValue, requestedBufferValue <= 0 {
      throw TraceConfigurationValidationError.bufferValueMustBePositive
    }
    let tags =
      presetID == .custom
      ? customTags
      : TracePresetCatalog.definition(for: presetID).logicalTags
    guard !tags.isEmpty else {
      throw TraceConfigurationValidationError.customPresetRequiresTags
    }
    var seenTags: Set<String> = []
    for tag in tags {
      guard Self.isValidTag(tag) else {
        throw TraceConfigurationValidationError.invalidTag(tag)
      }
      guard seenTags.insert(tag).inserted else {
        throw TraceConfigurationValidationError.duplicateTag(tag)
      }
    }
    self.presetID = presetID
    self.customTags = customTags
    self.durationMilliseconds = durationMilliseconds
    self.requestedBufferValue = requestedBufferValue
  }

  public var requestedTags: [String] {
    presetID == .custom ? customTags : TracePresetCatalog.definition(for: presetID).logicalTags
  }

  private static func isValidTag(_ tag: String) -> Bool {
    !tag.isEmpty && tag.utf8.count <= 128
      && tag.unicodeScalars.allSatisfy {
        CharacterSet.alphanumerics.contains($0) || $0 == "_" || $0 == "-"
      }
  }
}

/// Capabilities must come from a registered adapter. TASK-TR-002 only consumes this typed
/// observation and deliberately contains no help parser or command argv.
public struct TraceAdapterCapabilities: Equatable, Sendable {
  public let supportedTags: Set<String>
  public let confirmedBufferUnit: String?
  public let reliableByteTotalAvailable: Bool
  public let supportsTypedStop: Bool
  public let parameterChangesRequireReboot: Bool

  public init(
    supportedTags: Set<String>,
    confirmedBufferUnit: String? = nil,
    reliableByteTotalAvailable: Bool = false,
    supportsTypedStop: Bool = false,
    parameterChangesRequireReboot: Bool = false
  ) {
    self.supportedTags = supportedTags
    self.confirmedBufferUnit = confirmedBufferUnit.flatMap {
      let normalized = $0.trimmingCharacters(in: .whitespacesAndNewlines)
      return normalized.isEmpty ? nil : normalized
    }
    self.reliableByteTotalAvailable = reliableByteTotalAvailable
    self.supportsTypedStop = supportsTypedStop
    self.parameterChangesRequireReboot = parameterChangesRequireReboot
  }
}

/// Authority for determinate byte progress. The initializer is intentionally not public:
/// callers can report an observed total, but only a capability observation that explicitly
/// permits reliable byte totals can turn that observation into progress authority.
public struct TraceReliableByteTotalReceipt: Equatable, Sendable {
  public let totalBytes: UInt64
  fileprivate let adapterCapabilities: TraceAdapterCapabilities

  public func matches(_ currentCapabilities: TraceAdapterCapabilities) -> Bool {
    adapterCapabilities == currentCapabilities
      && currentCapabilities.reliableByteTotalAvailable
  }
}

public enum TraceReliableByteTotalFactory {
  public static func make(
    observedTotalBytes: UInt64,
    capabilities: TraceAdapterCapabilities
  ) -> TraceReliableByteTotalReceipt? {
    guard observedTotalBytes > 0, capabilities.reliableByteTotalAvailable else { return nil }
    return TraceReliableByteTotalReceipt(
      totalBytes: observedTotalBytes,
      adapterCapabilities: capabilities)
  }
}

public enum TraceConfigurationBlockReason: Equatable, Sendable {
  case bufferUnitUnconfirmed(requestedValue: Int)
}

/// A configuration value that may be handed to the capture gate. Its initializer is not public:
/// unsupported tags can reach this type only through explicit acceptance of the exact diff.
public struct TraceExecutableConfiguration: Equatable, Sendable {
  public let presetID: TracePresetID
  public let tags: [String]
  public let durationMilliseconds: Int
  public let bufferValue: Int?
  public let confirmedBufferUnit: String?
  public let acceptedAlternativeConfirmationID: String?
  public let displaysResourceWarning: Bool

  fileprivate init(
    request: TraceConfigurationRequest,
    tags: [String],
    confirmedBufferUnit: String?,
    acceptedAlternativeConfirmationID: String?
  ) {
    presetID = request.presetID
    self.tags = tags
    durationMilliseconds = request.durationMilliseconds
    bufferValue = request.requestedBufferValue
    self.confirmedBufferUnit = confirmedBufferUnit
    self.acceptedAlternativeConfirmationID = acceptedAlternativeConfirmationID
    displaysResourceWarning =
      TracePresetCatalog.definition(for: request.presetID)
      .displaysResourceWarning
  }
}

public struct TraceConfigurationReview: Equatable, Sendable {
  public let presetID: TracePresetID
  public let requestedTags: [String]
  public let supportedAlternativeTags: [String]
  public let unsupportedTags: [String]
  public let originalConfigurationIsExecutable: Bool
  public let displaysResourceWarning: Bool

  fileprivate let request: TraceConfigurationRequest
  fileprivate let confirmedBufferUnit: String?

  public func acceptSupportedAlternative(
    confirmationID: String
  ) throws -> TraceExecutableConfiguration {
    guard !confirmationID.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
      throw TraceConfigurationValidationError.explicitAcceptanceRequired
    }
    guard !supportedAlternativeTags.isEmpty else {
      throw TraceConfigurationValidationError.emptySupportedAlternative
    }
    return TraceExecutableConfiguration(
      request: request,
      tags: supportedAlternativeTags,
      confirmedBufferUnit: confirmedBufferUnit,
      acceptedAlternativeConfirmationID: confirmationID)
  }
}

public enum TraceConfigurationPreflightDecision: Equatable, Sendable {
  case executable(TraceExecutableConfiguration)
  case requiresExplicitAcceptance(TraceConfigurationReview)
  case blocked(TraceConfigurationBlockReason)

  /// Preflight never dispatches a device command, including every rejected branch.
  public var deviceDispatchCount: Int { 0 }
}

public enum TraceConfigurationGate {
  public static func evaluate(
    request: TraceConfigurationRequest,
    capabilities: TraceAdapterCapabilities
  ) -> TraceConfigurationPreflightDecision {
    if let buffer = request.requestedBufferValue, capabilities.confirmedBufferUnit == nil {
      return .blocked(.bufferUnitUnconfirmed(requestedValue: buffer))
    }

    let supported = request.requestedTags.filter { capabilities.supportedTags.contains($0) }
    let unsupported = request.requestedTags.filter { !capabilities.supportedTags.contains($0) }
    if !unsupported.isEmpty {
      return .requiresExplicitAcceptance(
        TraceConfigurationReview(
          presetID: request.presetID,
          requestedTags: request.requestedTags,
          supportedAlternativeTags: supported,
          unsupportedTags: unsupported,
          originalConfigurationIsExecutable: false,
          displaysResourceWarning: TracePresetCatalog.definition(for: request.presetID)
            .displaysResourceWarning,
          request: request,
          confirmedBufferUnit: capabilities.confirmedBufferUnit))
    }

    return .executable(
      TraceExecutableConfiguration(
        request: request,
        tags: request.requestedTags,
        confirmedBufferUnit: capabilities.confirmedBufferUnit,
        acceptedAlternativeConfirmationID: nil))
  }
}
