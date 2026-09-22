import ArkDeckCore
import Foundation

/// Display values returned by Runtime, never supervisor receipts or execution
/// capabilities. Missing observations remain unknown in the App.
public struct HDCClientDiagnosticsPresentation: Sendable, Equatable {
  public enum Health: String, Sendable, Equatable { case healthy, unavailable, unknown }
  public enum Ownership: String, Sendable, Equatable { case external, arkDeckManaged, unknown }
  public enum EndpointSource: String, Sendable, Equatable { case explicit, inheritedEnvironment, `default` }
  public enum Authorization: Sendable, Equatable {
    case unauthorizedWaitingForTrust, ready, timedOut, cancelled
    case denied(reason: String), keyAccessDenied(reason: String), unavailable(reason: String)
    public var hasNonDestructiveRetry: Bool { self != .ready }
  }
  public struct ChannelEvidence: Sendable, Equatable {
    public let evidenceVersion: String
    public let source: String
    public let detail: String
  }
  public enum ChannelProtection: Sendable, Equatable {
    case encryptedVerified(ChannelEvidence), unverifiedAssumeUnprotected
  }
  public enum Subserver: Sendable, Equatable {
    case supportedReadOnly, unsupported, unknown(reason: String)
  }
  public enum OtherClients: Sendable, Equatable {
    case detected([String]), noneDetectedExternalClientsMayStillExist
    case unavailableExternalClientsMayStillExist
  }
  public struct DisplayValue: Sendable, Equatable {
    public let rawValue: String
    init(_ value: String) { rawValue = value }
  }
  public struct Impact: Sendable, Equatable {
    public let action: DisplayValue
    public let endpoint: DisplayValue
    public let generation: Int
    public let ownership: Ownership
    public let affectedDeviceCoordinators: [String]
    public let affectedJobs: [String]
    public let otherClientDetection: OtherClients
    public let expectedInterruption: String
    public let recoveryPath: String
  }
  /// A fixture can display the confirmation label without minting authority.
  /// Production never constructs this state without a Runtime projection.
  public struct Confirmation: Sendable, Equatable { public let generation: Int }
  public enum Recovery: Sendable, Equatable {
    case unavailable(reason: String), preview(Impact), confirmed(Confirmation), blocked(reason: String)
  }
  public struct OwnershipBasis: Sendable, Equatable {
    public let preExistingServerReceipt: Bool
    public let zeroAutomaticLifecycleDispatch: Bool
    public let generationMintedFromObservation: Bool
    public let noActiveOrUnreconciledManagedProvenance: Bool
  }
  public struct DeviceEvent: Sendable, Equatable {
    public enum Kind: String, Sendable, Equatable {
      case appeared, disappeared, observationUnknown, observationUnavailable
    }
    public let timestamp: String
    public let kind: Kind
    public let redactedDeviceIdentifier: String?
    init(acceptedAt: Date, kind: Kind, redactedDeviceIdentifier: String?) {
      timestamp = ISO8601Timestamps.string(from: acceptedAt, includingFractionalSeconds: true)
      self.kind = kind
      self.redactedDeviceIdentifier = redactedDeviceIdentifier
    }
  }

  public let absolutePath: String
  public let source: String
  public let hash: String
  public let platformTrust: String
  public let clientVersion: String
  public let serverVersion: String
  public let daemonVersion: String
  public let endpoint: String
  public let serverHealth: Health
  public let generation: String
  public let ownership: Ownership
  public let authorization: Authorization
  public let channelProtection: ChannelProtection
  public let tcpUnprotectedWarning: String?
  public let keyAccessError: String?
  public let subserverCapability: Subserver
  public let lifecycleRecovery: Recovery
  public let criticalGateMessage: String?
  public let automaticLifecycleDispatchCount: Int?
  public let automaticSubserverDispatchCount: Int?
  public let confirmedLifecycleDispatchCount: Int?
  public let managedStartDispatchCount: Int?
  public let endpointSource: EndpointSource?
  public let childEnvironmentInjectionKeys: [String]
  public let ownershipBasis: OwnershipBasis?
  public let deviceEvents: [DeviceEvent]
  public let deviceEventsAvailable: Bool
  public let isRuntimeManaged: Bool
  public let loadFailure: String?

  init(
    absolutePath: String = "unknown",
    source: String = "unknown",
    hash: String = "unknown",
    platformTrust: String = "unknown",
    clientVersion: String = "unknown",
    serverVersion: String = "unknown",
    daemonVersion: String = "unknown",
    endpoint: String = "unknown",
    serverHealth: Health = .unknown,
    generation: String = "unknown",
    ownership: Ownership = .unknown,
    authorization: Authorization = .unavailable(reason: "HDC status is unavailable"),
    channelProtection: ChannelProtection = .unverifiedAssumeUnprotected,
    tcpUnprotectedWarning: String? = nil,
    keyAccessError: String? = nil,
    subserverCapability: Subserver = .unknown(reason: "Not reported by Runtime"),
    lifecycleRecovery: Recovery = .unavailable(reason: "Recovery approval is not available through this Runtime connection"),
    criticalGateMessage: String? = nil,
    automaticLifecycleDispatchCount: Int? = nil,
    automaticSubserverDispatchCount: Int? = nil,
    confirmedLifecycleDispatchCount: Int? = nil,
    managedStartDispatchCount: Int? = nil,
    endpointSource: EndpointSource? = nil,
    childEnvironmentInjectionKeys: [String] = [],
    ownershipBasis: OwnershipBasis? = nil,
    deviceEvents: [DeviceEvent] = [],
    deviceEventsAvailable: Bool = false,
    isRuntimeManaged: Bool = true,
    loadFailure: String? = nil
  ) {
    self.absolutePath = absolutePath
    self.source = source
    self.hash = hash
    self.platformTrust = platformTrust
    self.clientVersion = clientVersion
    self.serverVersion = serverVersion
    self.daemonVersion = daemonVersion
    self.endpoint = endpoint
    self.serverHealth = serverHealth
    self.generation = generation
    self.ownership = ownership
    self.authorization = authorization
    self.channelProtection = channelProtection
    self.tcpUnprotectedWarning = tcpUnprotectedWarning
    self.keyAccessError = keyAccessError
    self.subserverCapability = subserverCapability
    self.lifecycleRecovery = lifecycleRecovery
    self.criticalGateMessage = criticalGateMessage
    self.automaticLifecycleDispatchCount = automaticLifecycleDispatchCount
    self.automaticSubserverDispatchCount = automaticSubserverDispatchCount
    self.confirmedLifecycleDispatchCount = confirmedLifecycleDispatchCount
    self.managedStartDispatchCount = managedStartDispatchCount
    self.endpointSource = endpointSource
    self.childEnvironmentInjectionKeys = childEnvironmentInjectionKeys
    self.ownershipBasis = ownershipBasis
    self.deviceEvents = deviceEvents
    self.deviceEventsAvailable = deviceEventsAvailable
    self.isRuntimeManaged = isRuntimeManaged
    self.loadFailure = loadFailure
  }

  public var lifecycleImpactPreview: Impact? {
    if case .preview(let impact) = lifecycleRecovery { return impact }
    return nil
  }

  public static let loading = HDCClientDiagnosticsPresentation(
    source: "ArkDeck Runtime", authorization: .unavailable(reason: "HDC diagnostics are loading"))
}
