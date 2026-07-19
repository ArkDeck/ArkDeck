import CryptoKit
import Foundation

public enum DeviceTargetingValidationError: Error, Equatable, Sendable {
  case emptyField(String)
  case emptyIdentitySnapshot
  case nonFiniteIdentityNumber
  case invalidTargetShape
  case invalidBindingShape
  case invalidInitialRevision(Int)
  case nonMonotonicRevision(expected: Int, actual: Int)
  case bindingDoesNotMatchOriginalTarget
  case duplicateMutationRequest(String)
  case stablePhysicalIdentityMissing
}

public enum DeviceTargetKind: String, Codable, Sendable {
  case real
  case synthetic
}

public enum DeviceTransport: String, Codable, Sendable {
  case usb
  case tcp
  case uart
  case synthetic
}

public enum DeviceBindingConfirmation: String, Codable, Sendable {
  case corePolicy
  case user
  case simulation
}

public enum DeviceChannelProtection: String, Codable, Sendable {
  case encryptedVerified
  case unverifiedAssumeUnprotected
  case notApplicable
}

public struct DeviceIdentitySnapshot: Codable, Equatable, Sendable {
  public let attributes: [String: JSONValue]

  private enum CodingKeys: String, CodingKey {
    case attributes
  }

  public init(attributes: [String: JSONValue]) throws {
    guard !attributes.isEmpty else {
      throw DeviceTargetingValidationError.emptyIdentitySnapshot
    }
    guard attributes.keys.allSatisfy({ !$0.isEmpty }) else {
      throw DeviceTargetingValidationError.emptyField("identitySnapshot key")
    }
    guard attributes.values.allSatisfy(Self.isCanonicalJSON) else {
      throw DeviceTargetingValidationError.nonFiniteIdentityNumber
    }
    self.attributes = attributes
  }

  public init(from decoder: any Decoder) throws {
    let container = try decoder.container(keyedBy: CodingKeys.self)
    try self.init(attributes: container.decode([String: JSONValue].self, forKey: .attributes))
  }

  public func sha256() throws -> String {
    let encoder = JSONEncoder()
    encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
    let bytes = try encoder.encode(attributes)
    return SHA256.hash(data: bytes).map { String(format: "%02x", $0) }.joined()
  }

  /// Returns a lane key derived from the stable physical-device identity rather than the complete
  /// observation snapshot. Attributes such as mode and endpoint may legitimately change while an
  /// exclusive Job still owns the same device. A serialless snapshot remains valid identity data,
  /// but cannot authorize a mutation lane and must fail before a side-effect intent is persisted.
  public func stablePhysicalIdentitySha256() throws -> String {
    guard case .string(let serial)? = attributes["serial"],
      !serial.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    else { throw DeviceTargetingValidationError.stablePhysicalIdentityMissing }
    let normalizedSerial = serial.trimmingCharacters(in: .whitespacesAndNewlines)
      .precomposedStringWithCanonicalMapping
    let encoder = JSONEncoder()
    encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
    let bytes = try encoder.encode(["serial": JSONValue.string(normalizedSerial)])
    return SHA256.hash(data: bytes).map { String(format: "%02x", $0) }.joined()
  }

  private static func isCanonicalJSON(_ value: JSONValue) -> Bool {
    switch value {
    case .number(let number):
      number.isFinite
    case .array(let values):
      values.allSatisfy(isCanonicalJSON)
    case .object(let object):
      object.values.allSatisfy(isCanonicalJSON)
    default:
      true
    }
  }
}

public struct OriginalTargetSnapshot: Codable, Equatable, Sendable {
  public let kind: DeviceTargetKind
  public let connectKey: String?
  public let transport: DeviceTransport
  public let identitySnapshot: DeviceIdentitySnapshot

  public init(
    kind: DeviceTargetKind,
    connectKey: String?,
    transport: DeviceTransport,
    identitySnapshot: DeviceIdentitySnapshot
  ) throws {
    switch (kind, transport, Self.nonempty(connectKey)) {
    case (.real, .usb, .some), (.real, .tcp, .some), (.real, .uart, .some),
      (.synthetic, .synthetic, .none):
      break
    default:
      throw DeviceTargetingValidationError.invalidTargetShape
    }
    self.kind = kind
    self.connectKey = connectKey
    self.transport = transport
    self.identitySnapshot = identitySnapshot
  }

  public init(from decoder: any Decoder) throws {
    let container = try decoder.container(keyedBy: CodingKeys.self)
    try self.init(
      kind: container.decode(DeviceTargetKind.self, forKey: .kind),
      connectKey: container.decodeIfPresent(String.self, forKey: .connectKey),
      transport: container.decode(DeviceTransport.self, forKey: .transport),
      identitySnapshot: container.decode(DeviceIdentitySnapshot.self, forKey: .identitySnapshot)
    )
  }

  private static func nonempty(_ value: String?) -> String? {
    guard let value, !value.isEmpty else { return nil }
    return value
  }
}

public struct CurrentDeviceBinding: Codable, Equatable, Sendable {
  public let revision: Int
  public let connectKey: String?
  public let transport: DeviceTransport
  public let identitySnapshot: DeviceIdentitySnapshot
  public let evidence: [String]
  public let confirmedBy: DeviceBindingConfirmation
  public let channelProtection: DeviceChannelProtection

  public init(
    revision: Int,
    connectKey: String?,
    transport: DeviceTransport,
    identitySnapshot: DeviceIdentitySnapshot,
    evidence: [String],
    confirmedBy: DeviceBindingConfirmation,
    channelProtection: DeviceChannelProtection
  ) throws {
    guard revision >= 1, !evidence.isEmpty, evidence.allSatisfy({ !$0.isEmpty }) else {
      throw DeviceTargetingValidationError.invalidBindingShape
    }
    switch (transport, Self.nonempty(connectKey), confirmedBy, channelProtection) {
    case (.synthetic, .none, .simulation, .notApplicable):
      break
    case (.usb, .some, .corePolicy, .encryptedVerified),
      (.usb, .some, .corePolicy, .unverifiedAssumeUnprotected),
      (.usb, .some, .user, .encryptedVerified),
      (.usb, .some, .user, .unverifiedAssumeUnprotected),
      (.tcp, .some, .user, .encryptedVerified),
      (.tcp, .some, .user, .unverifiedAssumeUnprotected),
      (.uart, .some, .user, .encryptedVerified),
      (.uart, .some, .user, .unverifiedAssumeUnprotected):
      break
    default:
      throw DeviceTargetingValidationError.invalidBindingShape
    }
    self.revision = revision
    self.connectKey = connectKey
    self.transport = transport
    self.identitySnapshot = identitySnapshot
    self.evidence = evidence
    self.confirmedBy = confirmedBy
    self.channelProtection = channelProtection
  }

  public init(from decoder: any Decoder) throws {
    let container = try decoder.container(keyedBy: CodingKeys.self)
    try self.init(
      revision: container.decode(Int.self, forKey: .revision),
      connectKey: container.decodeIfPresent(String.self, forKey: .connectKey),
      transport: container.decode(DeviceTransport.self, forKey: .transport),
      identitySnapshot: container.decode(DeviceIdentitySnapshot.self, forKey: .identitySnapshot),
      evidence: container.decode([String].self, forKey: .evidence),
      confirmedBy: container.decode(DeviceBindingConfirmation.self, forKey: .confirmedBy),
      channelProtection: container.decode(DeviceChannelProtection.self, forKey: .channelProtection)
    )
  }

  private static func nonempty(_ value: String?) -> String? {
    guard let value, !value.isEmpty else { return nil }
    return value
  }
}

public struct DeviceBindingHistory: Codable, Equatable, Sendable {
  public let targetID: String
  public let originalTarget: OriginalTargetSnapshot
  public private(set) var bindings: [CurrentDeviceBinding]

  public init(
    targetID: String,
    originalTarget: OriginalTargetSnapshot,
    initialBinding: CurrentDeviceBinding
  ) throws {
    guard !targetID.isEmpty else {
      throw DeviceTargetingValidationError.emptyField("targetID")
    }
    guard initialBinding.revision == 1 else {
      throw DeviceTargetingValidationError.invalidInitialRevision(initialBinding.revision)
    }
    guard Self.matches(originalTarget, initialBinding) else {
      throw DeviceTargetingValidationError.bindingDoesNotMatchOriginalTarget
    }
    self.targetID = targetID
    self.originalTarget = originalTarget
    bindings = [initialBinding]
  }

  public init(from decoder: any Decoder) throws {
    let container = try decoder.container(keyedBy: CodingKeys.self)
    let targetID = try container.decode(String.self, forKey: .targetID)
    let originalTarget = try container.decode(OriginalTargetSnapshot.self, forKey: .originalTarget)
    let bindings = try container.decode([CurrentDeviceBinding].self, forKey: .bindings)
    guard let initial = bindings.first else {
      throw DeviceTargetingValidationError.invalidInitialRevision(0)
    }
    try self.init(targetID: targetID, originalTarget: originalTarget, initialBinding: initial)
    for binding in bindings.dropFirst() {
      try append(binding)
    }
  }

  public var current: CurrentDeviceBinding { bindings[bindings.count - 1] }

  public func binding(revision: Int) -> CurrentDeviceBinding? {
    bindings.first { $0.revision == revision }
  }

  public mutating func append(_ binding: CurrentDeviceBinding) throws {
    let expected = current.revision + 1
    guard binding.revision == expected else {
      throw DeviceTargetingValidationError.nonMonotonicRevision(
        expected: expected, actual: binding.revision)
    }
    bindings.append(binding)
  }

  private static func matches(
    _ target: OriginalTargetSnapshot,
    _ binding: CurrentDeviceBinding
  ) -> Bool {
    target.connectKey == binding.connectKey && target.transport == binding.transport
      && target.identitySnapshot == binding.identitySnapshot
  }
}

public struct DeviceBindingReference: Codable, Equatable, Hashable, Sendable {
  public let targetID: String
  public let revision: Int

  public init(targetID: String, revision: Int) throws {
    guard !targetID.isEmpty else {
      throw DeviceTargetingValidationError.emptyField("targetID")
    }
    guard revision >= 1 else {
      throw DeviceTargetingValidationError.invalidInitialRevision(revision)
    }
    self.targetID = targetID
    self.revision = revision
  }
}

/// This receipt can only be minted by another target in ArkDeckKit after the
/// locked journal append has returned successfully.
public struct DurableCurrentDeviceBinding: Equatable, Sendable {
  public let reference: DeviceBindingReference
  public let binding: CurrentDeviceBinding

  package init(reference: DeviceBindingReference, binding: CurrentDeviceBinding) throws {
    guard reference.revision == binding.revision else {
      throw DeviceTargetingValidationError.nonMonotonicRevision(
        expected: reference.revision, actual: binding.revision)
    }
    self.reference = reference
    self.binding = binding
  }
}

public enum DeviceIdentityDisposition: Equatable, Sendable {
  case confirmed
  case unconfirmed
  case ambiguous(candidateIDs: [String])
}

public enum DeviceEffectGateRejection: Error, Equatable, Sendable {
  case identityUnconfirmed
  case identityAmbiguous
  case bindingNotDurable
  case bindingMismatch
}

public enum DeviceEffectGateDecision: Equatable, Sendable {
  case permitted
  case rejected(DeviceEffectGateRejection)
}

public enum DeviceEffectGate {
  public static func evaluate(
    effect: WorkflowEffect,
    intendedBinding: DeviceBindingReference?,
    durableBinding: DurableCurrentDeviceBinding?,
    identity: DeviceIdentityDisposition
  ) -> DeviceEffectGateDecision {
    guard effect >= .deviceMutation else { return .permitted }
    switch identity {
    case .unconfirmed:
      return .rejected(.identityUnconfirmed)
    case .ambiguous:
      return .rejected(.identityAmbiguous)
    case .confirmed:
      break
    }
    guard let intendedBinding, let durableBinding else {
      return .rejected(.bindingNotDurable)
    }
    guard intendedBinding == durableBinding.reference else {
      return .rejected(.bindingMismatch)
    }
    return .permitted
  }
}

public struct USBRebindEvidence: Codable, Equatable, Sendable {
  public let serialMatches: Bool
  public let daemonFingerprintMatches: Bool
  public let topologyMatches: Bool
  public let expectedModeMatches: Bool
  public let modelBuildMatches: Bool

  public init(
    serialMatches: Bool,
    daemonFingerprintMatches: Bool,
    topologyMatches: Bool,
    expectedModeMatches: Bool,
    modelBuildMatches: Bool
  ) {
    self.serialMatches = serialMatches
    self.daemonFingerprintMatches = daemonFingerprintMatches
    self.topologyMatches = topologyMatches
    self.expectedModeMatches = expectedModeMatches
    self.modelBuildMatches = modelBuildMatches
  }

  public var satisfiesCoreMinimum: Bool {
    serialMatches && daemonFingerprintMatches && topologyMatches && expectedModeMatches
  }
}

public struct DeviceRebindCandidate: Codable, Equatable, Sendable {
  public let candidateID: String
  public let connectKey: String
  public let transport: DeviceTransport
  public let identitySnapshot: DeviceIdentitySnapshot
  public let evidence: [String]
  public let usbEvidence: USBRebindEvidence?

  public init(
    candidateID: String,
    connectKey: String,
    transport: DeviceTransport,
    identitySnapshot: DeviceIdentitySnapshot,
    evidence: [String],
    usbEvidence: USBRebindEvidence? = nil
  ) throws {
    guard !candidateID.isEmpty, !connectKey.isEmpty else {
      throw DeviceTargetingValidationError.emptyField("candidateID/connectKey")
    }
    guard transport != .synthetic else {
      throw DeviceTargetingValidationError.invalidTargetShape
    }
    self.candidateID = candidateID
    self.connectKey = connectKey
    self.transport = transport
    self.identitySnapshot = identitySnapshot
    self.evidence = evidence
    self.usbEvidence = usbEvidence
  }
}

public struct DeviceRebindProfilePolicy: Codable, Equatable, Sendable {
  public let requiresManualConfirmation: Bool
  public let additionalEvidenceSatisfied: Bool

  public init(
    requiresManualConfirmation: Bool = false,
    additionalEvidenceSatisfied: Bool = true
  ) {
    self.requiresManualConfirmation = requiresManualConfirmation
    self.additionalEvidenceSatisfied = additionalEvidenceSatisfied
  }
}

public struct DeviceRebindContext: Equatable, Sendable {
  public let transport: DeviceTransport
  public let disconnected: Bool
  public let endpointExplicitlyAdded: Bool
  public let expectedModeTransition: Bool
  public let candidates: [DeviceRebindCandidate]
  public let profile: DeviceRebindProfilePolicy
  public let userConfirmedCandidateID: String?

  public init(
    transport: DeviceTransport,
    disconnected: Bool,
    endpointExplicitlyAdded: Bool,
    expectedModeTransition: Bool,
    candidates: [DeviceRebindCandidate],
    profile: DeviceRebindProfilePolicy = DeviceRebindProfilePolicy(),
    userConfirmedCandidateID: String? = nil
  ) {
    self.transport = transport
    self.disconnected = disconnected
    self.endpointExplicitlyAdded = endpointExplicitlyAdded
    self.expectedModeTransition = expectedModeTransition
    self.candidates = candidates
    self.profile = profile
    self.userConfirmedCandidateID = userConfirmedCandidateID
  }
}

public enum DeviceRebindAwaitingReason: String, Codable, Equatable, Sendable {
  case noCandidate
  case ambiguousCandidates
  case coreEvidenceInsufficient
  case profileRequiresConfirmation
  case tcpEndpointNotExplicitlyAdded
  case tcpReconnectRequiresConfirmation
  case uartReconnectRequiresConfirmation
  case unsupportedTransport
}

public enum DeviceRebindDecision: Equatable, Sendable {
  case autoRebindEligible(DeviceRebindCandidate)
  case awaitingRebindConfirmation(
    reason: DeviceRebindAwaitingReason,
    candidates: [DeviceRebindCandidate]
  )
}

public enum DeviceRebindAuthorizationError: Error, Equatable, Sendable {
  case selectedCandidateNotPresent
  case candidateTransportMismatch
  case corePolicyNotEligible(DeviceRebindAwaitingReason)
  case userConfirmationMissing
  case profileEvidenceInsufficient
  case explicitEndpointRequired
  case unsupportedTransport
}

public enum DeviceRebindPolicy {
  public static func evaluate(
    transport: DeviceTransport,
    disconnected: Bool,
    endpointExplicitlyAdded: Bool,
    expectedModeTransition: Bool,
    candidates: [DeviceRebindCandidate],
    profile: DeviceRebindProfilePolicy = DeviceRebindProfilePolicy()
  ) -> DeviceRebindDecision {
    switch transport {
    case .usb:
      guard candidates.count == 1 else {
        return .awaitingRebindConfirmation(
          reason: candidates.isEmpty ? .noCandidate : .ambiguousCandidates,
          candidates: candidates)
      }
      let candidate = candidates[0]
      guard candidate.transport == .usb, expectedModeTransition,
        candidate.usbEvidence?.satisfiesCoreMinimum == true
      else {
        return .awaitingRebindConfirmation(
          reason: .coreEvidenceInsufficient, candidates: candidates)
      }
      guard !profile.requiresManualConfirmation, profile.additionalEvidenceSatisfied else {
        return .awaitingRebindConfirmation(
          reason: .profileRequiresConfirmation, candidates: candidates)
      }
      return .autoRebindEligible(candidate)
    case .tcp:
      guard endpointExplicitlyAdded else {
        return .awaitingRebindConfirmation(
          reason: .tcpEndpointNotExplicitlyAdded, candidates: candidates)
      }
      return .awaitingRebindConfirmation(
        reason: disconnected ? .tcpReconnectRequiresConfirmation : .profileRequiresConfirmation,
        candidates: candidates)
    case .uart:
      return .awaitingRebindConfirmation(
        reason: .uartReconnectRequiresConfirmation, candidates: candidates)
    case .synthetic:
      return .awaitingRebindConfirmation(reason: .unsupportedTransport, candidates: candidates)
    }
  }

  public static func authorizePersistence(
    context: DeviceRebindContext,
    selectedCandidate: DeviceRebindCandidate,
    confirmedBy: DeviceBindingConfirmation
  ) throws {
    let selectedMatches = context.candidates.filter {
      $0.candidateID == selectedCandidate.candidateID && $0 == selectedCandidate
    }
    guard selectedMatches.count == 1 else {
      throw DeviceRebindAuthorizationError.selectedCandidateNotPresent
    }
    guard selectedCandidate.transport == context.transport else {
      throw DeviceRebindAuthorizationError.candidateTransportMismatch
    }
    guard context.transport != .synthetic else {
      throw DeviceRebindAuthorizationError.unsupportedTransport
    }

    let decision = evaluate(
      transport: context.transport,
      disconnected: context.disconnected,
      endpointExplicitlyAdded: context.endpointExplicitlyAdded,
      expectedModeTransition: context.expectedModeTransition,
      candidates: context.candidates,
      profile: context.profile)

    switch confirmedBy {
    case .corePolicy:
      guard case .autoRebindEligible(let eligible) = decision, eligible == selectedCandidate else {
        let reason: DeviceRebindAwaitingReason
        if case .awaitingRebindConfirmation(let awaitingReason, _) = decision {
          reason = awaitingReason
        } else {
          reason = .coreEvidenceInsufficient
        }
        throw DeviceRebindAuthorizationError.corePolicyNotEligible(reason)
      }
    case .user:
      guard context.userConfirmedCandidateID == selectedCandidate.candidateID else {
        throw DeviceRebindAuthorizationError.userConfirmationMissing
      }
      guard context.profile.additionalEvidenceSatisfied else {
        throw DeviceRebindAuthorizationError.profileEvidenceInsufficient
      }
      if case .awaitingRebindConfirmation(let reason, _) = decision {
        switch reason {
        case .tcpEndpointNotExplicitlyAdded:
          throw DeviceRebindAuthorizationError.explicitEndpointRequired
        case .noCandidate, .unsupportedTransport:
          throw DeviceRebindAuthorizationError.unsupportedTransport
        case .ambiguousCandidates, .coreEvidenceInsufficient, .profileRequiresConfirmation,
          .tcpReconnectRequiresConfirmation, .uartReconnectRequiresConfirmation:
          break
        }
      }
    case .simulation:
      throw DeviceRebindAuthorizationError.unsupportedTransport
    }
  }
}

public enum DeviceMutationLaneReason: String, Codable, Equatable, Sendable {
  case deviceLaneBusy
}

public enum DeviceMutationLaneRequestState: Equatable, Sendable {
  case active
  case queued(reason: DeviceMutationLaneReason)
}

public enum DeviceMutationLaneError: Error, Equatable, Sendable {
  case cancelled
  case duplicateRequest(String)
  case leaseInUse(String)
  case staleLease(String)
}

package enum DeviceMutationLaneRequestIdentity: Hashable, Sendable {
  case opaque(String)
  case job(sessionID: String, jobID: String)

  fileprivate var isValid: Bool {
    switch self {
    case .opaque(let requestID):
      !requestID.isEmpty
    case .job(let sessionID, let jobID):
      !sessionID.isEmpty && !jobID.isEmpty
    }
  }

  fileprivate var requiresGlobalUniqueness: Bool {
    if case .job = self { return true }
    return false
  }

  package var diagnosticID: String {
    switch self {
    case .opaque(let requestID):
      requestID
    case .job(let sessionID, let jobID):
      "job[\(sessionID.utf8.count):\(sessionID)|\(jobID.utf8.count):\(jobID)]"
    }
  }
}

package struct DeviceMutationLaneLease: Equatable, Sendable {
  package let deviceID: String
  package let requestIdentity: DeviceMutationLaneRequestIdentity
  package let ownerID: String
}

public struct DeviceMutationLaneSnapshot: Equatable, Sendable {
  public let activeRequestIDs: [String: String]
  public let queuedRequestIDs: [String: [String]]
  public let maximumConcurrentByDevice: [String: Int]

  public init(
    activeRequestIDs: [String: String],
    queuedRequestIDs: [String: [String]],
    maximumConcurrentByDevice: [String: Int]
  ) {
    self.activeRequestIDs = activeRequestIDs
    self.queuedRequestIDs = queuedRequestIDs
    self.maximumConcurrentByDevice = maximumConcurrentByDevice
  }
}

public actor DeviceMutationLaneCoordinator {
  private struct ActiveLease {
    let requestIdentity: DeviceMutationLaneRequestIdentity
    var ownerID: String
    var dispatchInProgress: Bool
  }

  private struct Waiter {
    let requestIdentity: DeviceMutationLaneRequestIdentity
    let ownerID: String
    let continuation: CheckedContinuation<Void, any Error>
  }

  private struct StateObserver {
    let deviceID: String
    let requestIdentity: DeviceMutationLaneRequestIdentity
    let expectedState: DeviceMutationLaneRequestState
    let continuation: CheckedContinuation<Void, Never>
  }

  private var activeLeases: [String: ActiveLease] = [:]
  private var queued: [String: [Waiter]] = [:]
  private var maximumConcurrentByDevice: [String: Int] = [:]
  private var stateObservers: [StateObserver] = []

  public init() {}

  public func withMutationLane<Value: Sendable>(
    deviceID: String,
    requestID: String,
    operation: @escaping @Sendable () async throws -> Value
  ) async throws -> Value {
    let lease = try await acquireLease(
      deviceID: deviceID,
      requestIdentity: .opaque(requestID),
      ownerID: UUID().uuidString)
    try beginDispatch(lease)
    do {
      let result = try await operation()
      try endDispatch(lease)
      try releaseLease(lease)
      return result
    } catch {
      try? endDispatch(lease)
      try? releaseLease(lease)
      if error is CancellationError { throw DeviceMutationLaneError.cancelled }
      throw error
    }
  }

  package func acquireLease(
    deviceID: String,
    requestIdentity: DeviceMutationLaneRequestIdentity,
    ownerID: String
  ) async throws -> DeviceMutationLaneLease {
    guard !deviceID.isEmpty, requestIdentity.isValid, !ownerID.isEmpty else {
      throw DeviceTargetingValidationError.emptyField("deviceID/requestIdentity/ownerID")
    }
    try await acquire(
      deviceID: deviceID,
      requestIdentity: requestIdentity,
      ownerID: ownerID)
    let lease = DeviceMutationLaneLease(
      deviceID: deviceID,
      requestIdentity: requestIdentity,
      ownerID: ownerID)
    do {
      try Task.checkCancellation()
      return lease
    } catch {
      try? releaseLease(lease)
      if error is CancellationError { throw DeviceMutationLaneError.cancelled }
      throw error
    }
  }

  package func adoptActiveLease(
    requestIdentity: DeviceMutationLaneRequestIdentity,
    ownerID: String
  ) throws -> DeviceMutationLaneLease? {
    guard requestIdentity.isValid, !ownerID.isEmpty else {
      throw DeviceTargetingValidationError.emptyField("requestIdentity/ownerID")
    }
    let matchingDeviceIDs = activeLeases.compactMap { element in
      element.value.requestIdentity == requestIdentity ? element.key : nil
    }
    guard matchingDeviceIDs.count <= 1 else {
      throw DeviceMutationLaneError.duplicateRequest(requestIdentity.diagnosticID)
    }
    guard let deviceID = matchingDeviceIDs.first else { return nil }
    return try adoptActiveLease(
      deviceID: deviceID,
      requestIdentity: requestIdentity,
      ownerID: ownerID)
  }

  package func adoptActiveLease(
    deviceID: String,
    requestIdentity: DeviceMutationLaneRequestIdentity,
    ownerID: String
  ) throws -> DeviceMutationLaneLease? {
    guard !deviceID.isEmpty, requestIdentity.isValid, !ownerID.isEmpty else {
      throw DeviceTargetingValidationError.emptyField("deviceID/requestIdentity/ownerID")
    }
    guard var active = activeLeases[deviceID], active.requestIdentity == requestIdentity else {
      return nil
    }
    guard !active.dispatchInProgress else {
      throw DeviceMutationLaneError.leaseInUse(requestIdentity.diagnosticID)
    }
    active.ownerID = ownerID
    activeLeases[deviceID] = active
    return DeviceMutationLaneLease(
      deviceID: deviceID,
      requestIdentity: requestIdentity,
      ownerID: ownerID)
  }

  package func beginDispatch(_ lease: DeviceMutationLaneLease) throws {
    guard var active = activeLeases[lease.deviceID],
      active.requestIdentity == lease.requestIdentity,
      active.ownerID == lease.ownerID
    else { throw DeviceMutationLaneError.staleLease(lease.requestIdentity.diagnosticID) }
    guard !active.dispatchInProgress else {
      throw DeviceMutationLaneError.leaseInUse(lease.requestIdentity.diagnosticID)
    }
    active.dispatchInProgress = true
    activeLeases[lease.deviceID] = active
  }

  package func endDispatch(_ lease: DeviceMutationLaneLease) throws {
    guard var active = activeLeases[lease.deviceID],
      active.requestIdentity == lease.requestIdentity,
      active.ownerID == lease.ownerID
    else { throw DeviceMutationLaneError.staleLease(lease.requestIdentity.diagnosticID) }
    active.dispatchInProgress = false
    activeLeases[lease.deviceID] = active
  }

  package func releaseLease(_ lease: DeviceMutationLaneLease) throws {
    guard let active = activeLeases[lease.deviceID],
      active.requestIdentity == lease.requestIdentity,
      active.ownerID == lease.ownerID
    else { throw DeviceMutationLaneError.staleLease(lease.requestIdentity.diagnosticID) }
    guard !active.dispatchInProgress else {
      throw DeviceMutationLaneError.leaseInUse(lease.requestIdentity.diagnosticID)
    }
    release(deviceID: lease.deviceID, requestIdentity: lease.requestIdentity)
  }

  public func state(
    deviceID: String,
    requestID: String
  ) -> DeviceMutationLaneRequestState? {
    state(deviceID: deviceID, requestIdentity: .opaque(requestID))
  }

  package func state(
    deviceID: String,
    requestIdentity: DeviceMutationLaneRequestIdentity
  ) -> DeviceMutationLaneRequestState? {
    if activeLeases[deviceID]?.requestIdentity == requestIdentity { return .active }
    if queued[deviceID]?.contains(where: { $0.requestIdentity == requestIdentity }) == true {
      return .queued(reason: .deviceLaneBusy)
    }
    return nil
  }

  package func waitUntilState(
    deviceID: String,
    requestIdentity: DeviceMutationLaneRequestIdentity,
    equals expectedState: DeviceMutationLaneRequestState
  ) async {
    if state(deviceID: deviceID, requestIdentity: requestIdentity) == expectedState { return }
    await withCheckedContinuation { continuation in
      stateObservers.append(
        StateObserver(
          deviceID: deviceID,
          requestIdentity: requestIdentity,
          expectedState: expectedState,
          continuation: continuation))
    }
  }

  public func snapshot() -> DeviceMutationLaneSnapshot {
    DeviceMutationLaneSnapshot(
      activeRequestIDs: activeLeases.mapValues { $0.requestIdentity.diagnosticID },
      queuedRequestIDs: queued.mapValues { $0.map { $0.requestIdentity.diagnosticID } },
      maximumConcurrentByDevice: maximumConcurrentByDevice)
  }

  private func acquire(
    deviceID: String,
    requestIdentity: DeviceMutationLaneRequestIdentity,
    ownerID: String
  ) async throws {
    if var active = activeLeases[deviceID], active.requestIdentity == requestIdentity {
      guard !active.dispatchInProgress else {
        throw DeviceMutationLaneError.leaseInUse(requestIdentity.diagnosticID)
      }
      active.ownerID = ownerID
      activeLeases[deviceID] = active
      return
    }
    if requestIdentity.requiresGlobalUniqueness {
      let isActiveElsewhere = activeLeases.contains { element in
        element.key != deviceID && element.value.requestIdentity == requestIdentity
      }
      let isQueuedAnywhere = queued.values.contains { waiters in
        waiters.contains { $0.requestIdentity == requestIdentity }
      }
      guard !isActiveElsewhere, !isQueuedAnywhere else {
        throw DeviceMutationLaneError.duplicateRequest(requestIdentity.diagnosticID)
      }
    }
    guard
      queued[deviceID]?.contains(where: { $0.requestIdentity == requestIdentity }) != true
    else {
      throw DeviceMutationLaneError.duplicateRequest(requestIdentity.diagnosticID)
    }

    guard activeLeases[deviceID] != nil else {
      activeLeases[deviceID] = ActiveLease(
        requestIdentity: requestIdentity,
        ownerID: ownerID,
        dispatchInProgress: false)
      maximumConcurrentByDevice[deviceID] = max(maximumConcurrentByDevice[deviceID] ?? 0, 1)
      notifyStateObservers()
      return
    }

    try await withTaskCancellationHandler {
      try await withCheckedThrowingContinuation { continuation in
        queued[deviceID, default: []].append(
          Waiter(
            requestIdentity: requestIdentity,
            ownerID: ownerID,
            continuation: continuation))
        notifyStateObservers()
      }
    } onCancel: {
      Task {
        await self.cancelQueued(deviceID: deviceID, requestIdentity: requestIdentity)
      }
    }
  }

  private func cancelQueued(
    deviceID: String,
    requestIdentity: DeviceMutationLaneRequestIdentity
  ) {
    guard var waiters = queued[deviceID],
      let index = waiters.firstIndex(where: { $0.requestIdentity == requestIdentity })
    else { return }
    let waiter = waiters.remove(at: index)
    queued[deviceID] = waiters.isEmpty ? nil : waiters
    notifyStateObservers()
    waiter.continuation.resume(throwing: DeviceMutationLaneError.cancelled)
  }

  private func release(
    deviceID: String,
    requestIdentity: DeviceMutationLaneRequestIdentity
  ) {
    guard activeLeases[deviceID]?.requestIdentity == requestIdentity else { return }
    guard var waiters = queued[deviceID], !waiters.isEmpty else {
      activeLeases[deviceID] = nil
      queued[deviceID] = nil
      notifyStateObservers()
      return
    }
    let next = waiters.removeFirst()
    queued[deviceID] = waiters.isEmpty ? nil : waiters
    activeLeases[deviceID] = ActiveLease(
      requestIdentity: next.requestIdentity,
      ownerID: next.ownerID,
      dispatchInProgress: false)
    maximumConcurrentByDevice[deviceID] = max(maximumConcurrentByDevice[deviceID] ?? 0, 1)
    notifyStateObservers()
    next.continuation.resume()
  }

  private func notifyStateObservers() {
    var pending: [StateObserver] = []
    var satisfied: [CheckedContinuation<Void, Never>] = []
    for observer in stateObservers {
      if state(deviceID: observer.deviceID, requestIdentity: observer.requestIdentity)
        == observer.expectedState
      {
        satisfied.append(observer.continuation)
      } else {
        pending.append(observer)
      }
    }
    stateObservers = pending
    for continuation in satisfied { continuation.resume() }
  }
}
