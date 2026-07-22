import ArkDeckCore
import ArkDeckProcess
import CryptoKit
import Foundation

// TASK-AIN-006 (CHG-2026-025): trusted, same-admission facts. Every protocol and receipt in this
// file is internal to ArkDeckWorkflows. Public Process/discovery value types are observations, not
// authority; only an internally composed port can wrap an actual call as a trusted fact.

struct RockchipAuthorizationFactRequest: Sendable, Equatable {
  let archiveURL: URL
  let sessionID: String
  let jobID: String
  let targetID: String
  /// Selector only. It is compared with trusted observation and never becomes identity evidence.
  let targetLocationSelector: String?
}

struct RockchipTrustedClockReading: Sendable, Equatable {
  let monotonicNanoseconds: UInt64
  let auditTimestamp: String
}

protocol RockchipAdmissionClock: Sendable {
  func now() -> RockchipTrustedClockReading
}

final class RockchipContinuousAdmissionClock: @unchecked Sendable, RockchipAdmissionClock {
  private let clock = ContinuousClock()
  private let origin: ContinuousClock.Instant

  init() { origin = clock.now }

  func now() -> RockchipTrustedClockReading {
    let components = origin.duration(to: clock.now).components
    let seconds = max(Int64(0), components.seconds)
    let attoseconds = max(Int64(0), components.attoseconds)
    let nanoseconds = UInt64(seconds) * 1_000_000_000 + UInt64(attoseconds / 1_000_000_000)
    return RockchipTrustedClockReading(
      monotonicNanoseconds: nanoseconds,
      auditTimestamp: ISO8601DateFormatter().string(from: Date()))
  }
}

protocol RockchipExecutePlanFactPort: Sendable {
  func makeValidatedExecutePlan(archiveURL: URL) async throws -> RockchipFlashPlan
}

struct RockchipProductExecutePlanFactPort: RockchipExecutePlanFactPort {
  private let provider: RockchipRockUSBFlashProvider

  init(provider: RockchipRockUSBFlashProvider = RockchipRockUSBFlashProvider()) {
    self.provider = provider
  }

  func makeValidatedExecutePlan(archiveURL: URL) async throws -> RockchipFlashPlan {
    let summary = try GzipTarArchiveReader.summarize(fileAt: archiveURL)
    let verdict = provider.profile.validate(summary.archiveObservation())
    guard verdict == .valid else { throw RockchipAuthorizationFactError.archiveValidationFailed }
    return try provider.makePlan(mode: .execute, archiveValidation: verdict)
  }
}

struct RockchipTrustedDurableBindingFact: Sendable, Equatable {
  let sessionID: String
  let jobID: String
  let targetID: String
  let receipt: DurableCurrentDeviceBinding
}

protocol RockchipDurableBindingFactPort: Sendable {
  func currentDurableBinding() async throws -> RockchipTrustedDurableBindingFact
}

struct RockchipDeviceBindingJournalFactPort: RockchipDurableBindingFactPort {
  private let sessionID: String
  private let jobID: String
  private let targetID: String
  private let adapter: DeviceBindingJournalAdapter

  init(
    sessionID: String, jobID: String, targetID: String,
    adapter: DeviceBindingJournalAdapter
  ) {
    self.sessionID = sessionID
    self.jobID = jobID
    self.targetID = targetID
    self.adapter = adapter
  }

  func currentDurableBinding() async throws -> RockchipTrustedDurableBindingFact {
    RockchipTrustedDurableBindingFact(
      sessionID: sessionID, jobID: jobID, targetID: targetID,
      receipt: try await adapter.currentDurableBinding())
  }
}

struct RockchipTrustedToolDeviceFact: Sendable, Equatable {
  let sessionID: String
  let jobID: String
  let targetID: String
  let observationSequence: UInt64
  let observedAtMonotonicNanoseconds: UInt64
  let profileIdentifier: String
  let observation: RockchipDeviceObservation
  let executableIdentity: ProcessExecutableIdentityReceipt
}

protocol RockchipToolDeviceFactPort: Sendable {
  func observeToolAndDevice() async throws -> RockchipTrustedToolDeviceFact
}

/// Product wrapper around #301's read-only `ld` adapter. Merely constructing the public attempt,
/// observation or process receipt cannot reach this initializer or mint this internal fact.
struct RockchipDiscoveryToolDeviceFactPort: RockchipToolDeviceFactPort {
  private let sessionID: String
  private let jobID: String
  private let targetID: String
  private let observationSequence: UInt64
  private let adapter: RockchipDeviceDiscoveryAdapter
  private let tool: RockchipSelectedDiscoveryTool
  private let clock: any RockchipAdmissionClock

  init(
    sessionID: String, jobID: String, targetID: String, observationSequence: UInt64,
    adapter: RockchipDeviceDiscoveryAdapter, tool: RockchipSelectedDiscoveryTool,
    clock: any RockchipAdmissionClock
  ) {
    self.sessionID = sessionID
    self.jobID = jobID
    self.targetID = targetID
    self.observationSequence = observationSequence
    self.adapter = adapter
    self.tool = tool
    self.clock = clock
  }

  func observeToolAndDevice() async throws -> RockchipTrustedToolDeviceFact {
    let attempt = await adapter.discover(using: tool)
    guard attempt.diagnostic == nil, attempt.execution != nil,
      attempt.observations.count == 1, let observation = attempt.observations.first,
      let identity = attempt.executableIdentity
    else { throw RockchipAuthorizationFactError.toolOrDeviceObservationUnavailable }
    let observedAt = clock.now()
    return RockchipTrustedToolDeviceFact(
      sessionID: sessionID, jobID: jobID, targetID: targetID,
      observationSequence: observationSequence,
      observedAtMonotonicNanoseconds: observedAt.monotonicNanoseconds,
      profileIdentifier: RockchipDiscoveryIntegrationProfile.pinnedProduction.identifier,
      observation: observation, executableIdentity: identity)
  }
}

struct RockchipTrustedPrerequisiteFact: Sendable, Equatable {
  let sessionID: String
  let jobID: String
  let targetID: String
  let observations: [RockchipPrerequisiteObservation]
}

protocol RockchipPrerequisiteFactPort: Sendable {
  func probePrerequisites() async throws -> RockchipTrustedPrerequisiteFact
}

struct RockchipTrustedIdentityReadbackFact: Sendable, Equatable {
  let sessionID: String
  let jobID: String
  let targetID: String
  let observationSequence: UInt64
  let observedAtMonotonicNanoseconds: UInt64
  let deadlineMonotonicNanoseconds: UInt64
  let observedAtTimestamp: String
  let serialDigestSHA256: String
  let usbVendorID: UInt16
  let usbProductID: UInt16
  let usbTopology: String
}

protocol RockchipIdentityReadbackFactPort: Sendable {
  /// A production implementation must actually probe the target. A journal value or #301 `ld`
  /// observation cannot be returned as the serial readback because neither reads serial bytes.
  func readIdentity() async throws -> RockchipTrustedIdentityReadbackFact
}

enum RockchipAuthorizationFactError: Error, Sendable, Equatable {
  case invalidRequest(field: String)
  case archiveValidationFailed
  case factPortFailed(name: String)
  case authorizationExpired
  case planMismatch(field: String)
  case correlationMismatch(field: String)
  case bindingMismatch(field: String)
  case toolOrDeviceObservationUnavailable
  case toolMismatch(field: String)
  case prerequisiteMismatch
  case readbackMismatch(field: String)
  case readbackExpiredOrInvalid
}

struct RockchipTrustedAuthorizationFacts: Sendable, Equatable {
  let plan: RockchipFlashPlan
  let bindingReference: DeviceBindingReference
  let targetDigestSHA256: String
  let serialDigestSHA256: String
  let usbTopology: String
  let observationSequence: UInt64
  let readbackDeadlineMonotonicNanoseconds: UInt64
  let authorizationValidUntil: String
  let collectedAtTimestamp: String
}

struct RockchipAuthorizationFactCollector: Sendable {
  static let maximumReadbackLifetimeNanoseconds: UInt64 = 30_000_000_000

  private let planPort: any RockchipExecutePlanFactPort
  private let bindingPort: any RockchipDurableBindingFactPort
  private let toolDevicePort: any RockchipToolDeviceFactPort
  private let prerequisitePort: any RockchipPrerequisiteFactPort
  private let identityReadbackPort: any RockchipIdentityReadbackFactPort
  private let clock: any RockchipAdmissionClock
  private let provider: RockchipRockUSBFlashProvider

  init(
    planPort: any RockchipExecutePlanFactPort,
    bindingPort: any RockchipDurableBindingFactPort,
    toolDevicePort: any RockchipToolDeviceFactPort,
    prerequisitePort: any RockchipPrerequisiteFactPort,
    identityReadbackPort: any RockchipIdentityReadbackFactPort,
    clock: any RockchipAdmissionClock,
    provider: RockchipRockUSBFlashProvider = RockchipRockUSBFlashProvider()
  ) {
    self.planPort = planPort
    self.bindingPort = bindingPort
    self.toolDevicePort = toolDevicePort
    self.prerequisitePort = prerequisitePort
    self.identityReadbackPort = identityReadbackPort
    self.clock = clock
    self.provider = provider
  }

  func collect(
    request: RockchipAuthorizationFactRequest,
    grant: VerifiedAuthorizationGrant
  ) async throws -> RockchipTrustedAuthorizationFacts {
    for (field, value) in [
      ("sessionID", request.sessionID), ("jobID", request.jobID),
      ("targetID", request.targetID),
    ] where !Self.isIdentifier(value) {
      throw RockchipAuthorizationFactError.invalidRequest(field: field)
    }
    guard request.archiveURL.isFileURL, request.archiveURL.path.hasPrefix("/") else {
      throw RockchipAuthorizationFactError.invalidRequest(field: "archiveURL")
    }

    let plan: RockchipFlashPlan
    let binding: RockchipTrustedDurableBindingFact
    let toolDevice: RockchipTrustedToolDeviceFact
    let prerequisites: RockchipTrustedPrerequisiteFact
    let readback: RockchipTrustedIdentityReadbackFact
    do { plan = try await planPort.makeValidatedExecutePlan(archiveURL: request.archiveURL) } catch
    { throw RockchipAuthorizationFactError.factPortFailed(name: "plan") }
    do { binding = try await bindingPort.currentDurableBinding() } catch {
      throw RockchipAuthorizationFactError.factPortFailed(name: "binding")
    }
    do { toolDevice = try await toolDevicePort.observeToolAndDevice() } catch {
      throw RockchipAuthorizationFactError.factPortFailed(name: "toolDevice")
    }
    do { prerequisites = try await prerequisitePort.probePrerequisites() } catch {
      throw RockchipAuthorizationFactError.factPortFailed(name: "prerequisites")
    }
    do { readback = try await identityReadbackPort.readIdentity() } catch {
      throw RockchipAuthorizationFactError.factPortFailed(name: "identityReadback")
    }
    let current = clock.now()
    let authorization = grant.authorization

    guard RockchipStandingAuthorization.isCanonicalTimestamp(current.auditTimestamp),
      let nowDate = RockchipStandingAuthorization.parseTimestamp(current.auditTimestamp),
      let validUntil = RockchipStandingAuthorization.parseTimestamp(authorization.validUntil),
      nowDate < validUntil
    else { throw RockchipAuthorizationFactError.authorizationExpired }

    guard plan.executionMode == .execute else {
      throw RockchipAuthorizationFactError.planMismatch(field: "executionMode")
    }
    for (field, matches) in [
      ("targetModel", authorization.target.model == RockchipFlashProfile.targetDeviceModel),
      ("firmwareArchiveSHA256", authorization.firmwareArchiveSHA256 == plan.archiveSHA256),
      ("transport", authorization.transport == "usb"),
      (
        "toolchainFingerprint",
        authorization.toolchainFingerprint == RockchipFlashProfile.pinnedToolchainFingerprint
      ),
      (
        "providerIdentity",
        authorization.providerIdentity == RockchipRockUSBFlashProvider.providerIdentity
      ),
      ("planDigestSHA256", authorization.planDigestSHA256 == plan.planDigestSHA256),
      ("stepSetDigestSHA256", authorization.stepSetDigestSHA256 == plan.stepSetDigestSHA256),
    ] where !matches {
      throw RockchipAuthorizationFactError.planMismatch(field: field)
    }

    for (name, sessionID, jobID, targetID) in [
      ("binding", binding.sessionID, binding.jobID, binding.targetID),
      ("toolDevice", toolDevice.sessionID, toolDevice.jobID, toolDevice.targetID),
      ("prerequisites", prerequisites.sessionID, prerequisites.jobID, prerequisites.targetID),
      ("identityReadback", readback.sessionID, readback.jobID, readback.targetID),
    ] where sessionID != request.sessionID || jobID != request.jobID || targetID != request.targetID
    {
      throw RockchipAuthorizationFactError.correlationMismatch(field: name)
    }

    let durable = binding.receipt
    guard durable.reference.targetID == request.targetID else {
      throw RockchipAuthorizationFactError.bindingMismatch(field: "targetID")
    }
    guard durable.reference.revision == authorization.target.bindingRevision else {
      throw RockchipAuthorizationFactError.bindingMismatch(field: "revision")
    }
    guard durable.binding.transport == .usb else {
      throw RockchipAuthorizationFactError.bindingMismatch(field: "transport")
    }
    guard case .string(let serial)? = durable.binding.identitySnapshot.attributes["serial"],
      !serial.isEmpty
    else { throw RockchipAuthorizationFactError.bindingMismatch(field: "serial") }
    guard
      case .string(let topology)? =
        durable.binding.identitySnapshot.attributes["usbTopology"],
      Self.isCanonicalTopology(topology)
    else { throw RockchipAuthorizationFactError.bindingMismatch(field: "usbTopology") }
    let durableSerialDigest = Self.sha256Hex(Data(serial.utf8))
    guard durableSerialDigest == authorization.target.serialSHA256 else {
      throw RockchipAuthorizationFactError.bindingMismatch(field: "serialDigestSHA256")
    }

    let expectedToolSHA256 = RockchipDiscoveryIntegrationProfile.pinnedProduction.executableSHA256
    let observation = toolDevice.observation
    guard toolDevice.observationSequence > 0 else {
      throw RockchipAuthorizationFactError.toolMismatch(field: "observationSequence")
    }
    guard
      toolDevice.profileIdentifier
        == RockchipDiscoveryIntegrationProfile.pinnedProduction.identifier
    else { throw RockchipAuthorizationFactError.toolMismatch(field: "profileIdentifier") }
    guard toolDevice.executableIdentity.sha256 == expectedToolSHA256,
      !toolDevice.executableIdentity.authorizedPath.isEmpty,
      toolDevice.executableIdentity.fileSize > 0
    else { throw RockchipAuthorizationFactError.toolMismatch(field: "executableIdentity") }
    guard observation.usbVendorID == RockchipProbeEvidence.rockUSBVendorID,
      observation.usbProductID == RockchipProbeEvidence.dayu200LoaderProductID,
      observation.mode == .loader
    else { throw RockchipAuthorizationFactError.toolMismatch(field: "deviceObservation") }
    let observedTopology = String(observation.locationID)
    guard topology == observedTopology else {
      throw RockchipAuthorizationFactError.toolMismatch(field: "usbTopology")
    }
    if let selector = request.targetLocationSelector {
      guard Self.isCanonicalTopology(selector), selector == observedTopology else {
        throw RockchipAuthorizationFactError.toolMismatch(field: "targetLocationSelector")
      }
    }

    guard
      Set(prerequisites.observations.map(\.identifier)).count
        == prerequisites.observations.count,
      provider.evaluatePrerequisites(prerequisites.observations) == .cleared
    else { throw RockchipAuthorizationFactError.prerequisiteMismatch }

    guard RockchipStandingAuthorization.isCanonicalSHA256(readback.serialDigestSHA256),
      readback.serialDigestSHA256 == authorization.target.serialSHA256,
      readback.serialDigestSHA256 == durableSerialDigest
    else { throw RockchipAuthorizationFactError.readbackMismatch(field: "serialDigestSHA256") }
    guard readback.usbVendorID == observation.usbVendorID,
      readback.usbProductID == observation.usbProductID
    else { throw RockchipAuthorizationFactError.readbackMismatch(field: "usbIdentity") }
    guard readback.usbTopology == topology else {
      throw RockchipAuthorizationFactError.readbackMismatch(field: "usbTopology")
    }
    guard readback.observationSequence == toolDevice.observationSequence,
      toolDevice.observedAtMonotonicNanoseconds <= readback.observedAtMonotonicNanoseconds
    else { throw RockchipAuthorizationFactError.readbackMismatch(field: "observationSequence") }
    guard readback.deadlineMonotonicNanoseconds > readback.observedAtMonotonicNanoseconds,
      readback.deadlineMonotonicNanoseconds - readback.observedAtMonotonicNanoseconds
        <= Self.maximumReadbackLifetimeNanoseconds,
      current.monotonicNanoseconds >= readback.observedAtMonotonicNanoseconds,
      current.monotonicNanoseconds < readback.deadlineMonotonicNanoseconds,
      RockchipStandingAuthorization.isCanonicalTimestamp(readback.observedAtTimestamp)
    else { throw RockchipAuthorizationFactError.readbackExpiredOrInvalid }

    let targetDigest = Self.sha256Hex(
      Data(
        [
          authorization.target.model, authorization.target.serialSHA256,
          String(durable.reference.revision), request.targetID, topology,
          String(observation.usbVendorID), String(observation.usbProductID),
        ].joined(separator: "|").utf8))
    return RockchipTrustedAuthorizationFacts(
      plan: plan, bindingReference: durable.reference, targetDigestSHA256: targetDigest,
      serialDigestSHA256: durableSerialDigest, usbTopology: topology,
      observationSequence: readback.observationSequence,
      readbackDeadlineMonotonicNanoseconds: readback.deadlineMonotonicNanoseconds,
      authorizationValidUntil: authorization.validUntil,
      collectedAtTimestamp: current.auditTimestamp)
  }

  private static func isIdentifier(_ value: String) -> Bool {
    value.range(
      of: #"^[A-Za-z0-9][A-Za-z0-9._:-]{0,127}$"#, options: .regularExpression)
      == value.startIndex..<value.endIndex
  }

  private static func isCanonicalTopology(_ value: String) -> Bool {
    guard !value.isEmpty, value.utf8.allSatisfy({ (48...57).contains($0) }) else { return false }
    return value == "0" || value.first != "0"
  }

  private static func sha256Hex(_ data: Data) -> String {
    SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
  }
}
