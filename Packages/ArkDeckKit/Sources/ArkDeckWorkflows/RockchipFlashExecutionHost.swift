import ArkDeckCore
import ArkDeckProcess
import ArkDeckStorage
import CryptoKit
import Darwin
import Foundation
import IOKit
import Security

public struct RockchipToolInstallationReceipt: Sendable, Equatable {
  public let executableSHA256: String
  public let codeTrust: RockchipPlatformCodeTrust
  public let quarantinePresent: Bool

  public init(
    executableSHA256: String,
    codeTrust: RockchipPlatformCodeTrust,
    quarantinePresent: Bool
  ) {
    self.executableSHA256 = executableSHA256
    self.codeTrust = codeTrust
    self.quarantinePresent = quarantinePresent
  }
}

public enum RockchipToolInstallation {
  /// Installs the pinned ordinary bookmark and records a fresh platform-trust assessment.
  /// A quarantined tool remains blocked; this entry point never removes quarantine implicitly.
  @discardableResult
  public static func install(executableURL: URL) throws -> RockchipToolInstallationReceipt {
    try RockchipProductToolInstaller.production.install(executableURL: executableURL)
  }

  /// Performs the explicit host trust transition for the one reviewed executable identity.
  /// The caller must repeat the full pinned digest; no arbitrary executable can be de-quarantined.
  @discardableResult
  public static func trustAndInstall(
    executableURL: URL,
    expectedSHA256: String
  ) throws -> RockchipToolInstallationReceipt {
    try RockchipProductToolInstaller.production.trustAndInstall(
      executableURL: executableURL,
      expectedSHA256: expectedSHA256)
  }
}

public struct RockchipDeviceBindingInstallationReceipt: Sendable, Equatable {
  public let revision: Int
  public let usbTopology: String
  public let serialDigestSHA256: String
  public let created: Bool

  public init(
    revision: Int,
    usbTopology: String,
    serialDigestSHA256: String,
    created: Bool
  ) {
    self.revision = revision
    self.usbTopology = usbTopology
    self.serialDigestSHA256 = serialDigestSHA256
    self.created = created
  }
}

public enum RockchipDeviceBindingInstallation {
  /// Reads IOKit only, requires exactly one DAYU200 in registered HDC-normal or Loader mode,
  /// and durably adopts that cross-mode identity.  The HDC-normal branch does not reboot here:
  /// the transition remains inside the later authorized `enterUpdater` intent.
  /// This entry point never launches rkdeveloptool and has no device-mutation surface.
  @discardableResult
  public static func installCurrentTarget() throws -> RockchipDeviceBindingInstallationReceipt {
    let manager = FileManager.default
    let applicationSupport = try manager.url(
      for: .applicationSupportDirectory, in: .userDomainMask,
      appropriateFor: nil, create: true)
    let root = applicationSupport.appending(path: "ArkDeck", directoryHint: .isDirectory)
    return try RockchipProductBindingBootstrap(
      probe: { try RockchipProductUSBProbe().singleDAYU200() },
      store: RockchipProductBindingStore(rootURL: root)
    ).installCurrentTarget()
  }

  /// Source-compatible name retained for clients built against the Loader-only bootstrap.
  @discardableResult
  public static func installCurrentLoader() throws -> RockchipDeviceBindingInstallationReceipt {
    try installCurrentTarget()
  }
}

public struct RockchipDeviceBindingRebindPreview: Sendable, Equatable {
  public let currentRevision: Int
  public let prospectiveRevision: Int
  public let requiresRebind: Bool
  public let usbTopology: String
  public let serialDigestSHA256: String
  public let targetDigestSHA256: String

  public init(
    currentRevision: Int,
    prospectiveRevision: Int,
    requiresRebind: Bool,
    usbTopology: String,
    serialDigestSHA256: String,
    targetDigestSHA256: String
  ) {
    self.currentRevision = currentRevision
    self.prospectiveRevision = prospectiveRevision
    self.requiresRebind = requiresRebind
    self.usbTopology = usbTopology
    self.serialDigestSHA256 = serialDigestSHA256
    self.targetDigestSHA256 = targetDigestSHA256
  }
}

public struct RockchipDeviceBindingRebindReceipt: Sendable, Equatable {
  public let previousRevision: Int
  public let revision: Int
  public let changed: Bool
  public let usbTopology: String
  public let serialDigestSHA256: String
  public let targetDigestSHA256: String

  public init(
    previousRevision: Int,
    revision: Int,
    changed: Bool,
    usbTopology: String,
    serialDigestSHA256: String,
    targetDigestSHA256: String
  ) {
    self.previousRevision = previousRevision
    self.revision = revision
    self.changed = changed
    self.usbTopology = usbTopology
    self.serialDigestSHA256 = serialDigestSHA256
    self.targetDigestSHA256 = targetDigestSHA256
  }
}

/// Product-owned current-Loader rebind surface. Preview is E0/read-only. Confirmation changes
/// only the owner-private host binding after the same supervised chat assertion that will be
/// consumed by Flash matches the prospective revision and target digest. It dispatches no device
/// command and cannot accept a caller-provided identity, topology, executable, argv, or path.
public enum RockchipDeviceBindingRebinding {
  public static func previewCurrentLoader() throws -> RockchipDeviceBindingRebindPreview {
    try production().previewCurrentLoader()
  }

  @discardableResult
  public static func confirmCurrentLoader(
    chatConfirmation assertion: RockchipChatConfirmationAssertion
  ) throws -> RockchipDeviceBindingRebindReceipt {
    try production().confirmCurrentLoader(chatConfirmation: assertion)
  }

  private static func production() throws -> RockchipProductBindingRebinder {
    let manager = FileManager.default
    let applicationSupport = try manager.url(
      for: .applicationSupportDirectory, in: .userDomainMask,
      appropriateFor: nil, create: true)
    let root = applicationSupport.appending(path: "ArkDeck", directoryHint: .isDirectory)
    return RockchipProductBindingRebinder(
      probe: { try RockchipProductUSBProbe().singleLoader() },
      store: RockchipProductBindingStore(rootURL: root))
  }
}

/// Protected-main HDC tuple already registered by the Rockchip Loader-transition integration.
/// It is deliberately not configurable by CLI/environment/PATH.
enum RockchipHDCIntegrationProfile {
  static let executableURL = URL(
    fileURLWithPath:
      "/Applications/DevEco-Studio.app/Contents/sdk/default/openharmony/toolchains/hdc")
  static let executableSHA256 =
    "05b2bf7ad30201c082da336db28f8856952a2b2f49ac3404b96fdb4bf1a68f83"
  static let reportedVersion = "3.2.0f"
  static let dayu200NormalProductID: UInt16 = 0x5000
}

public struct RockchipFlashExecutionHost: Sendable {
  private let executor: RockchipFlashExecutor

  /// Production composition has no caller-supplied dependency, executable, argv, fact receipt,
  /// repository, branch, clock, storage root or authorization bytes. All such inputs come from
  /// the product-owned Application Support, Keychain, bookmark and protected-main adapters.
  public init() throws {
    executor = RockchipFlashExecutor(
      dependencies: try RockchipProductionExecutionComposition.make())
  }

  init(dependencies: RockchipFlashExecutionDependencies) {
    executor = RockchipFlashExecutor(dependencies: dependencies)
  }

  public func execute(_ request: RockchipFlashExecutionRequest) async throws
    -> RockchipFlashExecutionResult
  {
    try await executor.execute(request)
  }
}

// MARK: - Product-owned power activity

private final class ProductRockchipPowerActivityController: @unchecked Sendable,
  RockchipPowerActivityPort
{
  func acquire(reason: String) throws -> any RockchipPowerActivityLease {
    let activity = ProcessInfo.processInfo.beginActivity(
      options: [.idleSystemSleepDisabled], reason: reason)
    return ProductRockchipPowerActivityLease(activity: activity)
  }
}

private final class ProductRockchipPowerActivityLease: @unchecked Sendable,
  RockchipPowerActivityLease
{
  private let lock = NSLock()
  private var activity: (any NSObjectProtocol)?

  init(activity: any NSObjectProtocol) {
    self.activity = activity
  }

  deinit { end() }

  func end() {
    lock.lock()
    let activity = activity
    self.activity = nil
    lock.unlock()
    if let activity { ProcessInfo.processInfo.endActivity(activity) }
  }
}

private final class ProductRockchipExecutionLifecyclePort: @unchecked Sendable,
  RockchipExecutionLifecyclePort
{
  private enum State {
    case stopped
    case awake
    case sleeping(eventID: String)
  }

  private let lock = NSLock()
  private let elapsedClock = ContinuousClock()
  private let activeClock = SuspendingClock()
  private var elapsedStart: ContinuousClock.Instant
  private var activeStart: SuspendingClock.Instant
  private var state: State = .stopped
  private var tokens: [NSObjectProtocol] = []
  private var center: NotificationCenter?
  private var handler: (@Sendable (RockchipExecutionLifecycleEvent) -> Void)?

  init() {
    elapsedStart = elapsedClock.now
    activeStart = activeClock.now
  }

  deinit { stop() }

  func start(
    handler: @escaping @Sendable (RockchipExecutionLifecycleEvent) -> Void
  ) throws {
    _ = Bundle(path: "/System/Library/Frameworks/AppKit.framework")?.load()
    guard let workspaceType = NSClassFromString("NSWorkspace") as? NSObject.Type,
      let workspace = workspaceType.perform(NSSelectorFromString("sharedWorkspace"))?
        .takeUnretainedValue() as? NSObject,
      workspace.responds(to: NSSelectorFromString("notificationCenter")),
      let center = workspace.perform(NSSelectorFromString("notificationCenter"))?
        .takeUnretainedValue() as? NotificationCenter
    else {
      throw RockchipFlashExecutionError.storageRejected("NSWorkspace notification center")
    }

    lock.lock()
    defer { lock.unlock() }
    guard case .stopped = state else { return }
    self.handler = handler
    self.center = center
    elapsedStart = elapsedClock.now
    activeStart = activeClock.now
    state = .awake
    tokens = [
      center.addObserver(
        forName: Notification.Name("NSWorkspaceWillSleepNotification"),
        object: nil, queue: nil
      ) { [weak self] _ in self?.receive(.sleep) },
      center.addObserver(
        forName: Notification.Name("NSWorkspaceDidWakeNotification"),
        object: nil, queue: nil
      ) { [weak self] _ in self?.receive(.wake) },
    ]
  }

  func stop() {
    lock.lock()
    let tokens = tokens
    let center = center
    self.tokens = []
    self.center = nil
    handler = nil
    state = .stopped
    lock.unlock()
    if let center {
      for token in tokens { center.removeObserver(token) }
    }
  }

  private func receive(_ kind: RockchipExecutionLifecycleEventKind) {
    lock.lock()
    defer { lock.unlock() }
    guard let handler else { return }
    let eventID = "rockchip-lifecycle-(UUID().uuidString.lowercased())"
    let event: RockchipExecutionLifecycleEvent
    switch (state, kind) {
    case (.awake, .sleep):
      event = RockchipExecutionLifecycleEvent(
        eventID: eventID, kind: .sleep, sleepEventID: nil,
        elapsedDurationNanoseconds: Self.nanoseconds(elapsedStart.duration(to: elapsedClock.now)),
        activeDurationNanoseconds: Self.nanoseconds(activeStart.duration(to: activeClock.now)))
      state = .sleeping(eventID: eventID)
    case (.sleeping(let sleepEventID), .wake):
      event = RockchipExecutionLifecycleEvent(
        eventID: eventID, kind: .wake, sleepEventID: sleepEventID,
        elapsedDurationNanoseconds: Self.nanoseconds(elapsedStart.duration(to: elapsedClock.now)),
        activeDurationNanoseconds: Self.nanoseconds(activeStart.duration(to: activeClock.now)))
      state = .awake
    case (.stopped, _), (.awake, .wake), (.sleeping, .sleep):
      return
    }
    handler(event)
  }

  private static func nanoseconds(_ duration: Duration) -> Int64 {
    let components = duration.components
    guard components.seconds >= 0 else { return 0 }
    let (whole, overflow) = components.seconds.multipliedReportingOverflow(by: 1_000_000_000)
    guard !overflow else { return Int64.max }
    let fractional = components.attoseconds / 1_000_000_000
    let (total, additionOverflow) = whole.addingReportingOverflow(fractional)
    return additionOverflow ? Int64.max : max(0, total)
  }
}

// MARK: - Descriptor-bound process port

enum RockchipHDCTransitionError: Error, Equatable, Sendable {
  case outputTooLarge
  case unexpectedStandardError
  case processDidNotExitSuccessfully
  case identityDrift
  case loaderObservationRejected
  case loaderUnavailable
}

private enum RockchipHDCTransitionSemanticResult: Sendable, Equatable {
  case succeeded
  case failed(RockchipHDCTransitionError)
}

private struct RockchipHDCTransitionSemanticEvaluator: ProcessSemanticEvaluating {
  typealias SemanticResult = RockchipHDCTransitionSemanticResult

  private static let maximumOutputBytes = 64 * 1_024
  private var stdout = Data()
  private var stderr = Data()
  private var exceededLimit = false

  mutating func consume(_ chunk: ProcessOutputChunk) {
    let current = stdout.count + stderr.count
    guard current <= Self.maximumOutputBytes else {
      exceededLimit = true
      return
    }
    let remaining = Self.maximumOutputBytes + 1 - current
    let bytes = chunk.bytes.prefix(max(0, remaining))
    if bytes.count < chunk.bytes.count { exceededLimit = true }
    switch chunk.stream {
    case .stdout: stdout.append(bytes)
    case .stderr: stderr.append(bytes)
    }
  }

  mutating func finish(execution: ProcessExecutionResult) -> RockchipHDCTransitionSemanticResult {
    guard !exceededLimit, stdout.count + stderr.count <= Self.maximumOutputBytes else {
      return .failed(.outputTooLarge)
    }
    guard stderr.isEmpty else { return .failed(.unexpectedStandardError) }
    guard execution.termination == .exited(0) else {
      return .failed(.processDidNotExitSuccessfully)
    }
    return .succeeded
  }
}

/// Closed production seam for the already-published `rockusb.enter-loader`
/// step.  The raw HDC connect key never comes from CLI argv: it is the serial
/// retained by the durable binding.  Readback closures are injected only so
/// the same serial/topology transition can be proven without attaching IOKit
/// to process-executor contract tests.
struct RockchipHDCTransitionConfiguration: Sendable {
  let executableURL: URL
  let executableSHA256: String
  let connectKey: String
  let stableIdentitySHA256: String
  let usbTopology: String
  let alternateModeIdentities: [RockchipPostflightIdentity]
  let currentIdentity: @Sendable () throws -> RockchipProductUSBIdentity
  let waitForLoader: @Sendable () async throws -> RockchipDeviceObservation

  init(
    executableURL: URL,
    executableSHA256: String,
    connectKey: String,
    stableIdentitySHA256: String,
    usbTopology: String,
    alternateModeIdentities: [RockchipPostflightIdentity] = [],
    currentIdentity: @escaping @Sendable () throws -> RockchipProductUSBIdentity,
    waitForLoader: @escaping @Sendable () async throws -> RockchipDeviceObservation
  ) {
    self.executableURL = executableURL
    self.executableSHA256 = executableSHA256
    self.connectKey = connectKey
    self.stableIdentitySHA256 = stableIdentitySHA256
    self.usbTopology = usbTopology
    self.alternateModeIdentities = alternateModeIdentities
    self.currentIdentity = currentIdentity
    self.waitForLoader = waitForLoader
  }

  var arguments: [String] {
    ["-t", connectKey, "shell", "reboot", "loader"]
  }
}

final class FoundationRockchipExecutionProcessPort: @unchecked Sendable,
  RockchipExecutionProcessPort
{
  private let executableURL: URL
  private let executableSHA256: String
  private let executor: FoundationProcessExecutor
  private let hdcTransition: RockchipHDCTransitionConfiguration?

  init(
    executableURL: URL,
    executor: FoundationProcessExecutor,
    executableSHA256: String = RockchipDiscoveryIntegrationProfile.pinnedProduction
      .executableSHA256,
    hdcTransition: RockchipHDCTransitionConfiguration? = nil
  ) {
    self.executableURL = executableURL
    self.executableSHA256 = executableSHA256
    self.executor = executor
    self.hdcTransition = hdcTransition
  }

  func prepare(
    command: RockchipClosedCommand,
    admissionIdentity: ProcessExecutableIdentityReceipt
  ) throws -> RockchipPreparedCommand {
    let request = ProcessIdentityBoundRequest(
      process: ProcessRequest(
        executable: executableURL, arguments: command.arguments, environment: [:],
        timeout: command.isCriticalWrite ? nil : 15),
      expectedSHA256: executableSHA256)
    let prepared = try executor.prepareIdentityBoundLaunch(request)
    guard Self.sameDescriptor(prepared.executableIdentity, admissionIdentity) else {
      prepared.close()
      throw RockchipFlashExecutionError.executableIdentityDrift
    }
    guard case .loaderGate = command, let hdcTransition else {
      return RockchipPreparedCommand(executableIdentity: prepared.executableIdentity) {
        let result = try await self.executor.executePreparedIdentityBoundLaunch(
          prepared, evaluating: RockchipCommandSemanticEvaluator(command: command))
        return RockchipExecutionAttempt(
          execution: result.execution, semantic: result.semantic,
          executableIdentity: result.executableIdentity)
      }
    }

    let hdcPrepared: ProcessPreparedIdentityBoundLaunch
    do {
      hdcPrepared = try executor.prepareIdentityBoundLaunch(
        ProcessIdentityBoundRequest(
          process: ProcessRequest(
            executable: hdcTransition.executableURL,
            arguments: hdcTransition.arguments,
            environment: [:], timeout: 20),
          expectedSHA256: hdcTransition.executableSHA256))
    } catch {
      prepared.close()
      throw error
    }
    return RockchipPreparedCommand(executableIdentity: prepared.executableIdentity) {
      defer { hdcPrepared.close() }
      let current = try hdcTransition.currentIdentity()
      guard Self.matches(current, transition: hdcTransition) else {
        throw RockchipHDCTransitionError.identityDrift
      }
      if current.isHDCNormal {
        let transition = try await self.executor.executePreparedIdentityBoundLaunch(
          hdcPrepared, evaluating: RockchipHDCTransitionSemanticEvaluator())
        guard transition.semantic == .succeeded else {
          if case .failed(let failure) = transition.semantic { throw failure }
          throw RockchipHDCTransitionError.processDidNotExitSuccessfully
        }
        let loader = try await hdcTransition.waitForLoader()
        guard Self.matchesLoaderObservation(loader) else {
          throw RockchipHDCTransitionError.identityDrift
        }
        // The `ld` observation proves one expected Loader but its LocationID is libusb-local.
        // Re-read IOKit after the transition so serial digest + IOKit topology, not a
        // cross-namespace integer comparison, prove that the Loader is the durable target.
        let loaderIdentity = try hdcTransition.currentIdentity()
        guard loaderIdentity.isLoader,
          Self.matchesConfirmedModeIdentity(loaderIdentity, transition: hdcTransition)
        else {
          throw RockchipHDCTransitionError.identityDrift
        }
      } else {
        // The device may already have reached Loader between admission and
        // the durable step boundary.  In that case the HDC descriptor is
        // closed unused and no duplicate reboot command is dispatched.
        guard current.isLoader else { throw RockchipHDCTransitionError.identityDrift }
      }
      let result = try await self.executor.executePreparedIdentityBoundLaunch(
        prepared, evaluating: RockchipCommandSemanticEvaluator(command: command))
      return RockchipExecutionAttempt(
        execution: result.execution, semantic: result.semantic,
        executableIdentity: result.executableIdentity,
        semanticCode: "rockchip.enter-loader.readback-confirmed")
    }
  }

  private static func sameDescriptor(
    _ lhs: ProcessExecutableIdentityReceipt,
    _ rhs: ProcessExecutableIdentityReceipt
  ) -> Bool {
    lhs.device == rhs.device && lhs.inode == rhs.inode && lhs.fileSize == rhs.fileSize
      && lhs.mode == rhs.mode && lhs.sha256 == rhs.sha256
  }

  private static func matches(
    _ identity: RockchipProductUSBIdentity,
    transition: RockchipHDCTransitionConfiguration
  ) -> Bool {
    let digest = SHA256.hash(data: Data(identity.serial.utf8))
      .map { String(format: "%02x", $0) }.joined()
    return digest == transition.stableIdentitySHA256
      && identity.topology == transition.usbTopology
      && identity.isRegisteredDAYU200Mode
  }

  private static func matchesLoaderObservation(
    _ observation: RockchipDeviceObservation
  ) -> Bool {
    observation.usbVendorID == RockchipProbeEvidence.rockUSBVendorID
      && observation.usbProductID == RockchipProbeEvidence.dayu200LoaderProductID
      && observation.mode == .loader
  }

  private static func matchesConfirmedModeIdentity(
    _ identity: RockchipProductUSBIdentity,
    transition: RockchipHDCTransitionConfiguration
  ) -> Bool {
    let digest = SHA256.hash(data: Data(identity.serial.utf8))
      .map { String(format: "%02x", $0) }.joined()
    let observed = RockchipPostflightIdentity(
      serialDigestSHA256: digest, usbTopology: identity.topology)
    let current = RockchipPostflightIdentity(
      serialDigestSHA256: transition.stableIdentitySHA256,
      usbTopology: transition.usbTopology)
    return observed == current || transition.alternateModeIdentities.contains(observed)
  }
}

// MARK: - Durable Session persistence

final class RockchipDurableExecutionPersistence: @unchecked Sendable,
  RockchipExecutionPersistence
{
  let sessionRoot: URL
  private let layout: SessionLayout
  private let claim: StorageClaim
  private let coordinator: HostStorageCoordinator
  private let storageContext: SessionStorageExecutionContext?
  private let journal: FileDurableJournal
  private let audit: FileDurableSessionAuditStore
  private let artifactStore: SessionArtifactStore
  private let publisher: AtomicSessionManifestPublisher
  private let lock = NSLock()
  private let createdAt: String
  private var sequence = 0
  private var stepRecords: [String: RockchipPersistedStepResult] = [:]
  private var artifacts: [ArtifactRecord] = []
  private var waitingForRecovery = false
  private var activeSchemaVersion = JournalEvent.rockchipAuthorizedAgentSchemaVersion

  init(
    layout: SessionLayout,
    claim: StorageClaim,
    coordinator: HostStorageCoordinator,
    storageContext: SessionStorageExecutionContext? = nil
  ) throws {
    self.layout = layout
    sessionRoot = layout.root
    self.claim = claim
    self.coordinator = coordinator
    self.storageContext = storageContext
    journal = try FileDurableJournal(url: layout.journalURL)
    audit = try FileDurableSessionAuditStore(layout: layout)
    artifactStore = SessionArtifactStore(layout: layout)
    publisher = AtomicSessionManifestPublisher(layout: layout)
    createdAt = Self.timestamp()
  }

  func appendJobCreated(admission: RockchipExecutionAdmission) throws {
    try locked {
      activeSchemaVersion = admission.journalSchemaVersion
      try append(
        JournalEvent.jobCreated(
          eventID: eventID("created"), sequence: sequence,
          sessionID: layout.sessionID, jobID: layout.jobID,
          timestamp: Self.timestamp(), executionMode: "execute",
          executionAuthority: "authorizedAgent", coreBaseline: "CORE-2.0.0",
          schemaVersion: activeSchemaVersion,
          authorizationRef: admission.legacyAuthorizationReference,
          agentAuthorizationRef: admission.agentAuthorizationReference,
          usageReservationID: admission.usageReservationID))
    }
  }

  func appendRunning() throws {
    try locked {
      try append(
        JournalEvent.stateTransition(
          eventID: eventID("preflight"), sequence: sequence,
          sessionID: layout.sessionID, jobID: layout.jobID,
          timestamp: Self.timestamp(), from: .queued, to: .preflight,
          reason: "trusted admission consumed and staging validated",
          schemaVersion: activeSchemaVersion))
      try append(
        JournalEvent.stateTransition(
          eventID: eventID("running"), sequence: sequence,
          sessionID: layout.sessionID, jobID: layout.jobID,
          timestamp: Self.timestamp(), from: .preflight, to: .running,
          reason: "closed Rockchip command sequence ready",
          schemaVersion: activeSchemaVersion))
    }
  }

  func appendIntent(
    step: WorkflowStep,
    admission: RockchipExecutionAdmission,
    isDestructive: Bool
  ) throws -> String {
    try locked {
      let identifier = eventID("intent-\(step.id)")
      let correlated = admission.correlatesAuthority(for: step.effect)
      try append(
        JournalEvent.stepIntent(
          eventID: identifier, sequence: sequence,
          sessionID: layout.sessionID, jobID: layout.jobID,
          timestamp: Self.timestamp(), step: step,
          target: JournalTarget(
            scope: "device", targetID: admission.targetID,
            connectKey: admission.usbTopology,
            identitySnapshotHash: admission.targetDigestSHA256),
          attempt: 1, bindingRevision: admission.bindingRevision,
          schemaVersion: activeSchemaVersion,
          authorizationRef: correlated ? admission.legacyAuthorizationReference : nil,
          agentAuthorizationRef: correlated ? admission.agentAuthorizationReference : nil,
          usageReservationID: correlated ? admission.usageReservationID : nil))
      return identifier
    }
  }

  func appendOutcome(
    step: WorkflowStep,
    intentEventID: String,
    admission: RockchipExecutionAdmission,
    result: String,
    certainty: JournalOutcomeCertainty,
    semanticCode: String,
    execution: ProcessExecutionResult?
  ) throws {
    try locked {
      if let execution {
        try persistRawStreams(stepID: step.id, execution: execution)
      }
      let correlated = admission.correlatesAuthority(for: step.effect)
      try append(
        JournalEvent.stepOutcome(
          eventID: eventID("outcome-\(step.id)"), sequence: sequence,
          sessionID: layout.sessionID, jobID: layout.jobID,
          timestamp: Self.timestamp(), stepID: step.id, attempt: 1,
          correlatesToIntentEventID: intentEventID, result: result,
          outcomeCertainty: certainty, semanticCode: semanticCode,
          summary: result == "succeeded" ? "typed semantic marker confirmed" : "fail closed",
          schemaVersion: activeSchemaVersion,
          authorizationRef: correlated ? admission.legacyAuthorizationReference : nil,
          agentAuthorizationRef: correlated ? admission.agentAuthorizationReference : nil,
          usageReservationID: correlated ? admission.usageReservationID : nil))
      stepRecords[step.id] = RockchipPersistedStepResult(
        disposition: certainty == .confirmed ? "executed" : "outcomeUnknown",
        outcomeCertainty: certainty.rawValue,
        semanticResult: certainty == .confirmed
          ? (result == "succeeded" ? "succeeded" : "failed") : "unknown",
        exitCode: execution.flatMap(Self.exitCode))
    }
  }

  func appendWaitingForRecovery(stepID: String, reason: String) throws {
    try locked {
      guard !waitingForRecovery else { return }
      try append(
        JournalEvent.stateTransition(
          eventID: eventID("waiting-recovery"), sequence: sequence,
          sessionID: layout.sessionID, jobID: layout.jobID,
          timestamp: Self.timestamp(), from: .running, to: .waitingForRecovery,
          reason: "\(stepID):\(reason)",
          schemaVersion: activeSchemaVersion))
      waitingForRecovery = true
    }
  }

  func appendLifecycleEvent(_ event: RockchipExecutionLifecycleEvent) throws {
    try locked {
      let payload: [String: JSONValue]
      switch event.kind {
      case .sleep:
        payload = [
          "elapsedDurationNanoseconds": .integer(event.elapsedDurationNanoseconds),
          "activeDurationNanoseconds": .integer(event.activeDurationNanoseconds),
        ]
      case .wake:
        guard let sleepEventID = event.sleepEventID else {
          throw RockchipFlashExecutionError.persistenceRejected("wake missing sleep event")
        }
        payload = [
          "sleepEventId": .string(sleepEventID),
          "elapsedDurationNanoseconds": .integer(event.elapsedDurationNanoseconds),
          "activeDurationNanoseconds": .integer(event.activeDurationNanoseconds),
          "throughputSegmentReset": .bool(true),
        ]
      }
      try append(
        JournalEvent(
          schemaVersion: activeSchemaVersion,
          eventID: event.eventID, sequence: sequence,
          sessionID: layout.sessionID, jobID: layout.jobID,
          timestamp: Self.timestamp(), kind: event.kind == .sleep ? .sleep : .wake,
          payload: payload))
    }
  }

  func finishSucceeded(
    plan: RockchipFlashPlan,
    admission: RockchipExecutionAdmission,
    destructiveIntentEventIDs: [String]
  ) async throws -> URL {
    let manifest: SessionManifestDocument = try locked {
      let document = try makeManifest(
        plan: plan, admission: admission,
        destructiveIntentEventIDs: destructiveIntentEventIDs)
      try append(
        JournalEvent.stateTransition(
          eventID: eventID("finalizing"), sequence: sequence,
          sessionID: layout.sessionID, jobID: layout.jobID,
          timestamp: Self.timestamp(), from: .running, to: .finalizing,
          reason: "all typed outcomes and postflight confirmed",
          schemaVersion: activeSchemaVersion))
      try append(
        JournalEvent.stateTransition(
          eventID: eventID("succeeded"), sequence: sequence,
          sessionID: layout.sessionID, jobID: layout.jobID,
          timestamp: Self.timestamp(), from: .finalizing, to: .succeeded,
          reason: "terminal manifest graph ready",
          schemaVersion: activeSchemaVersion))
      try append(
        JournalEvent(
          schemaVersion: activeSchemaVersion,
          eventID: eventID("finalized"), sequence: sequence,
          sessionID: layout.sessionID, jobID: layout.jobID,
          timestamp: Self.timestamp(), kind: .finalized,
          payload: [
            "terminalStatus": .string("succeeded"),
            "manifestSha256": .string(document.sha256),
            "outcomeCertainty": .string("confirmed"),
          ]))
      return document
    }
    _ = await coordinator.reportWriteFailure(
      claimID: claim.claimID, errno: 0, terminalDisposition: .succeeded)
    let record = try SessionAuditRecord(
      recordID: eventID("terminal-audit"), auditID: "rockchip-authorized-agent",
      correlationID: layout.sessionID, sessionID: layout.sessionID, jobID: layout.jobID,
      category: .outcome, timestamp: Self.timestamp(),
      details: [
        "status": .string("succeeded"),
        "authorityKind": .string(admission.authorityKind),
        "evidenceClass": .string("\(admission.evidenceClass.rawValue)"),
        "hardwareSupportEligible": .bool(admission.evidenceClass == .production),
      ])
    let receipt = try SessionStorageTerminalFinalizer(
      audit: audit, manifestPublisher: publisher
    ).persist(claim: claim, disposition: .succeeded, auditRecord: record, manifest: manifest)
    _ = try await coordinator.completeRecoveredFinalization(receipt)
    if let storageContext {
      await storageContext.registerFinalizedSession(layout.root)
    }
    return layout.manifestURL
  }

  private func makeManifest(
    plan: RockchipFlashPlan,
    admission: RockchipExecutionAdmission,
    destructiveIntentEventIDs: [String]
  ) throws -> SessionManifestDocument {
    let completedAt = Self.timestamp()
    let stepValues = try plan.steps.map { step -> JSONValue in
      var declaration: [String: JSONValue]
      guard
        case .object(let object) = try JSONDecoder().decode(
          JSONValue.self, from: JSONEncoder().encode(step))
      else {
        throw RockchipFlashExecutionError.persistenceRejected("step declaration")
      }
      declaration = object
      let record = stepRecords[step.id]
      declaration["argumentsHash"] = .string(
        try JournalCanonicalJSON.argumentsHash(step.arguments))
      declaration["sourceStepId"] = .null
      declaration["compensationTrigger"] = .null
      declaration["disposition"] = .string(record?.disposition ?? "skipped")
      declaration["outcomeCertainty"] = .string(record?.outcomeCertainty ?? "notApplicable")
      declaration["bindingRevision"] =
        step.bindingRequirement == .confirmedDevice
        ? .integer(Int64(admission.bindingRevision)) : .null
      declaration["semanticResult"] = .string(record?.semanticResult ?? "notRun")
      if let exitCode = record?.exitCode { declaration["exitCode"] = .integer(Int64(exitCode)) }
      return .object(declaration)
    }
    let authorizationReference = try Self.authorizationReference(admission.authorityReference)
    let relatedConfirmationSteps = plan.steps.filter {
      $0.arguments["confirmationId"] == .string(plan.confirmationID)
    }.map { JSONValue.string($0.id) }
    let artifactValues = try artifacts.map {
      try JSONDecoder().decode(JSONValue.self, from: JSONEncoder().encode($0))
    }
    let authorization: JSONValue
    if admission.journalSchemaVersion == JournalEvent.agentAuthoritySchemaVersion {
      authorization = .object([
        "authorizationRef": authorizationReference,
        "usageReservationId": .string(admission.usageReservationID),
        "externalIntentEventIds": .array(destructiveIntentEventIDs.map(JSONValue.string)),
      ])
    } else {
      authorization = .object([
        "authorizationRef": authorizationReference,
        "usageReservationId": .string(admission.usageReservationID),
        "destructiveIntentEventIds": .array(destructiveIntentEventIDs.map(JSONValue.string)),
      ])
    }
    let root: JSONValue = .object([
      "schemaVersion": .string(admission.journalSchemaVersion),
      "appVersion": .string("ArkDeckKit-1.0.0"),
      "coreSpecBaseline": .string("CORE-2.0.0"),
      "platformProfile": .string("macos-1.0.0"),
      "sessionId": .string(layout.sessionID),
      "jobId": .string(layout.jobID),
      "status": .string("succeeded"),
      "executionMode": .string("execute"),
      "executionAuthority": .string("authorizedAgent"),
      "authorization": authorization,
      "outcomeCertainty": .string("confirmed"),
      "sessionDisposition": .string("finalized"),
      "createdAt": .string(createdAt),
      "completedAt": .string(completedAt),
      "archivedAt": .null,
      "originalTarget": .object([
        "kind": .string("real"), "connectKey": .string(admission.usbTopology),
        "transport": .string("usb"),
        "identitySnapshot": .object([
          "serialSha256": .string(admission.serialDigestSHA256),
          "usbTopology": .string(admission.usbTopology),
        ]),
      ]),
      "bindingHistory": .array([
        .object([
          "revision": .integer(Int64(admission.bindingRevision)),
          "connectKey": .string(admission.usbTopology), "transport": .string("usb"),
          "identitySnapshot": .object([
            "serialSha256": .string(admission.serialDigestSHA256),
            "usbTopology": .string(admission.usbTopology),
          ]),
          "evidence": .array([.string("trusted durable binding and fresh USB readback")]),
          "confirmedBy": .string("corePolicy"),
          "channelProtection": .string("unverifiedAssumeUnprotected"),
        ])
      ]),
      "toolchain": .object([
        "kind": .string("rockchip"),
        "profileIdentifier": .string(
          RockchipDiscoveryIntegrationProfile.pinnedProduction.identifier),
        "reportedVersion": .string(
          RockchipDiscoveryIntegrationProfile.pinnedProduction.reportedToolVersion),
        "sha256": .string(
          RockchipDiscoveryIntegrationProfile.pinnedProduction.executableSHA256),
        "pathSource": .string("installedOrdinaryBookmark"),
        "descriptorIdentity": .object([
          "device": .unsignedInteger(admission.executableIdentity.device),
          "inode": .unsignedInteger(admission.executableIdentity.inode),
          "fileSize": .integer(admission.executableIdentity.fileSize),
          "mode": .unsignedInteger(UInt64(admission.executableIdentity.mode)),
        ]),
      ]),
      "workflow": .object([
        "kind": .string("rockchipFlash"),
        "profileVersion": .string(RockchipFlashProfile.profileVersion),
        "providerIdentity": .string(RockchipRockUSBFlashProvider.providerIdentity),
      ]),
      "steps": .array(stepValues), "parameters": .array([]),
      "compensations": .array([]),
      "confirmations": .array([
        .object([
          "confirmationId": .string(plan.confirmationID),
          "kind": .string("destructive"),
          "scopeHash": plan.steps.first(where: { $0.kind == .requestConfirmation })?
            .arguments["scopeHash"] ?? .string(String(repeating: "0", count: 64)),
          "decision": .string("accepted"),
          "actor": .object([
            "kind": .string("authorizedAgent"),
            "authorizationRef": authorizationReference,
          ]),
          "decidedAt": .string(admission.confirmationDecidedAt ?? createdAt),
          "relatedStepIds": .array(relatedConfirmationSteps),
        ])
      ]),
      "artifacts": .array(artifactValues), "warnings": .array([]),
      "failure": .null, "recovery": .null,
    ])
    let encoder = JSONEncoder()
    encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
    return try SessionManifestDocument(data: encoder.encode(root))
  }

  private func persistRawStreams(stepID: String, execution: ProcessExecutionResult) throws {
    for (stream, capture) in [("stdout", execution.stdout), ("stderr", execution.stderr)]
    where !capture.data.isEmpty {
      let sourceName = ".raw-\(stepID)-\(stream)-\(UUID().uuidString)"
      let sourceURL = layout.root.appending(path: sourceName)
      try Self.writeOwnerOnly(capture.data, to: sourceURL)
      defer { _ = Darwin.unlink(sourceURL.path) }
      let artifactID = "\(stepID)-\(stream)"
      let published = try artifactStore.publish(
        from: sourceURL,
        request: ArtifactPublicationRequest(
          artifactID: artifactID, role: .raw,
          publicationName: "\(artifactID).bin",
          origin: "rockchip-process-\(stream)", mediaType: "application/octet-stream"),
        claim: claim)
      artifacts.append(published.record)
    }
  }

  private func append(_ event: JournalEvent) throws {
    try journal.appendAndSynchronize(event)
    sequence += 1
  }

  private func eventID(_ suffix: String) -> String {
    "rk-\(sequence)-\(suffix)".replacingOccurrences(of: "_", with: "-")
  }

  private func locked<T>(_ body: () throws -> T) rethrows -> T {
    lock.lock()
    defer { lock.unlock() }
    return try body()
  }

  private static func exitCode(_ execution: ProcessExecutionResult) -> Int32? {
    if case .exited(let code) = execution.termination { return code }
    return nil
  }

  private static func authorizationReference(
    _ reference: RockchipExecutionAdmission.AuthorityReference
  ) throws -> JSONValue {
    switch reference {
    case .standingAuthorization(let legacy):
      return .object([
        "authorizationId": .string(legacy.authorizationID),
        "mainCommitOID": .string(legacy.mainCommitOID),
        "authorizationBlobOID": .string(legacy.authorizationBlobOID),
        "approvalPRNumber": .integer(Int64(legacy.approvalPRNumber)),
      ])
    case .agent(let agent):
      return try JSONDecoder().decode(JSONValue.self, from: JSONEncoder().encode(agent))
    }
  }

  private static func timestamp() -> String {
    ISO8601DateFormatter().string(from: Date())
  }

  private static func writeOwnerOnly(_ data: Data, to url: URL) throws {
    let descriptor = Darwin.open(
      url.path, O_WRONLY | O_CREAT | O_EXCL | O_CLOEXEC | O_NOFOLLOW, 0o600)
    guard descriptor >= 0 else {
      throw SessionStorageError.writeFailed(path: url.path, errno: errno)
    }
    defer { Darwin.close(descriptor) }
    try data.withUnsafeBytes { bytes in
      var offset = 0
      while offset < bytes.count {
        let count = Darwin.write(
          descriptor, bytes.baseAddress!.advanced(by: offset), bytes.count - offset)
        if count > 0 {
          offset += count
          continue
        }
        if count < 0, errno == EINTR { continue }
        throw SessionStorageError.writeFailed(path: url.path, errno: errno)
      }
    }
    guard fsync(descriptor) == 0 else {
      throw SessionStorageError.writeFailed(path: url.path, errno: errno)
    }
  }

  func auditRecordsForTesting(correlationID: String) throws -> [SessionAuditRecord] {
    try audit.replay(correlationID: correlationID)
  }
}

private struct RockchipPersistedStepResult {
  let disposition: String
  let outcomeCertainty: String
  let semanticResult: String
  let exitCode: Int32?
}

// MARK: - Production composition

/// Defers access to the standing-authorization credential until the request
/// actually selects that authority kind.  A one-shot chat confirmation has no
/// GitHub provenance dependency and must not trigger a Keychain prompt before
/// its own typed admission can begin.
struct RockchipProductionProvenanceTokenLoader: Sendable {
  private let loadToken: @Sendable () throws -> String?

  init(loadToken: @escaping @Sendable () throws -> String?) {
    self.loadToken = loadToken
  }

  func token(for authority: RockchipFlashExecutionRequest.Authority) throws -> String? {
    guard case .standingAuthorization = authority else { return nil }
    return try loadToken().flatMap { $0.isEmpty ? nil : $0 }
  }
}

private enum RockchipProductionExecutionComposition {
  static func make() throws -> RockchipFlashExecutionDependencies {
    let settings = try RockchipProductExecutionSettings.load()
    let storage = try RockchipProductionStorageComposition.make()
    let clock = RockchipContinuousAdmissionClock()
    let usbProbe = RockchipProductUSBProbe()
    let provenance = RockchipProductionProvenanceTokenLoader(
      loadToken: { try RockchipProductExecutionSettings.productKeychainToken() })
    let ledger = try AuthorizationUsageLedger(root: settings.usageRoot)
    let agentLedger = try AgentAuthorityUsageLedger(root: settings.usageRoot)
    let campaignLedger = try RockchipEvolutionCampaignLedger(
      root: settings.usageRoot.appending(path: "evolution-campaigns", directoryHint: .isDirectory))
    let postflightIdentities = try settings.binding.postflightIdentities()
    let admission = RockchipProductionAdmissionPort(
      provenance: provenance, usageLedger: ledger, agentUsageLedger: agentLedger,
      campaignLedger: campaignLedger,
      binding: settings.binding,
      postflightIdentities: postflightIdentities,
      tool: settings.tool, clock: clock, usbProbe: usbProbe)
    let bindingSerialDigest = SHA256.hash(data: Data(settings.binding.serial.utf8))
      .map { String(format: "%02x", $0) }.joined()
    let loaderDiscovery = RockchipProductionDiscoveryComposition.admissionDiscoveryAdapter()
    let hdcTransition = RockchipHDCTransitionConfiguration(
      executableURL: RockchipHDCIntegrationProfile.executableURL,
      executableSHA256: RockchipHDCIntegrationProfile.executableSHA256,
      connectKey: settings.binding.serial,
      stableIdentitySHA256: bindingSerialDigest,
      usbTopology: settings.binding.usbTopology,
      alternateModeIdentities: Array(postflightIdentities.dropFirst()),
      currentIdentity: {
        try usbProbe.singleDAYU200()
      },
      waitForLoader: {
        let clock = ContinuousClock()
        let deadline = clock.now.advanced(by: .seconds(45))
        repeat {
          let attempt = await loaderDiscovery.discover(using: settings.tool)
          if attempt.diagnostic == .offline {
            try await Task.sleep(for: .milliseconds(500))
            continue
          }
          guard attempt.diagnostic == nil,
            attempt.execution != nil,
            attempt.executableIdentity?.sha256
              == RockchipDiscoveryIntegrationProfile.pinnedProduction.executableSHA256,
            attempt.observations.count == 1,
            let observation = attempt.observations.first,
            observation.usbVendorID == RockchipProbeEvidence.rockUSBVendorID,
            observation.usbProductID == RockchipProbeEvidence.dayu200LoaderProductID,
            observation.mode == .loader
          else { throw RockchipHDCTransitionError.loaderObservationRejected }
          return observation
        } while clock.now < deadline
        throw RockchipHDCTransitionError.loaderUnavailable
      })
    let process = FoundationRockchipExecutionProcessPort(
      executableURL: settings.tool.executableURL,
      executor: FoundationProcessExecutor(),
      hdcTransition: hdcTransition)
    let postflight = RockchipProductPostflightPort(probe: usbProbe)
    let coordinator = storage.context.coordinator
    let storageProbe = SystemHostStorageProbe()
    return RockchipFlashExecutionDependencies(
      admission: admission, process: process, postflight: postflight,
      power: ProductRockchipPowerActivityController(),
      makePersistence: { sessionID, jobID, plan in
        guard
          let profile = RockchipFlashProfile.profile(
            archiveSHA256: plan.archiveSHA256, byteCount: Int(plan.archiveSizeBytes))
        else {
          throw RockchipFlashExecutionError.storageRejected(
            "execute plan has no exact published profile")
        }
        let requiredGrowth =
          UInt64(
            profile.mappedPartitions.compactMap {
              profile.member(named: $0.imageMemberName)?.sizeBytes
            }.reduce(Int64(0), +)) + 64 * 1_024 * 1_024
        let admission = try await storage.context.prepareHeavyWriterAdmission()
        let snapshot = try storageProbe.snapshot(for: storage.context.rootLease.url)
        guard snapshot.volumeIdentity == admission.volumeIdentity else {
          throw RockchipFlashExecutionError.storageRejected(
            "Session root volume identity changed")
        }
        let request = try StorageClaimRequest(
          claimID: "claim-\(jobID)", jobID: jobID, volumeIdentity: snapshot.volumeIdentity,
          budget: StorageBudget(
            metadataHeadroomBytes: 16 * 1_024 * 1_024,
            finalizationHeadroomBytes: 16 * 1_024 * 1_024,
            remainingGrowthBytes: requiredGrowth, writerClass: .heavy))
        guard
          case .admitted(let claim) = await storage.context.admitHeavyWriter(
            request, snapshot: snapshot, admission: admission)
        else { throw RockchipFlashExecutionError.storageRejected("host storage queued") }
        let layout = try await storage.context.createSession(
          sessionID: sessionID, jobID: jobID, createdAt: Date(), claim: claim,
          admission: admission)
        return try RockchipDurableExecutionPersistence(
          layout: layout, claim: claim, coordinator: coordinator,
          storageContext: storage.context)
      }, profiles: RockchipFlashProfile.supportedDAYU200Profiles,
      lifecycle: ProductRockchipExecutionLifecyclePort())
  }
}

struct RockchipProductionStorageComposition: Sendable {
  let context: SessionStorageExecutionContext

  static func make(
    runtime: SessionStorageApplicationRuntime = .production
  ) throws -> RockchipProductionStorageComposition {
    RockchipProductionStorageComposition(context: try runtime.makeExecutionContext())
  }
}

struct RockchipProductBindingSnapshot: Codable, Sendable, Equatable {
  let revision: Int
  let serial: String
  let usbTopology: String
  let evidence: [String]

  func postflightIdentities() throws -> [RockchipPostflightIdentity] {
    let current = RockchipPostflightIdentity(
      serialDigestSHA256: SHA256.hash(data: Data(serial.utf8)).map {
        String(format: "%02x", $0)
      }.joined(),
      usbTopology: usbTopology)
    let previousSerials = evidence.compactMap {
      $0.hasPrefix("identity:previous-serial-sha256=")
        ? String($0.dropFirst("identity:previous-serial-sha256=".count)) : nil
    }
    let previousTopologies = evidence.compactMap {
      $0.hasPrefix("binding:previous-usb-topology=")
        ? String($0.dropFirst("binding:previous-usb-topology=".count)) : nil
    }
    guard previousSerials.count == previousTopologies.count else {
      throw RockchipFlashExecutionError.productionConfigurationUnavailable(
        "durable binding carries an incomplete previous-mode identity")
    }
    guard !previousSerials.isEmpty else { return [current] }
    guard previousSerials.count == 1,
      let previousSerial = previousSerials.first,
      let previousTopology = previousTopologies.first,
      RockchipStandingAuthorization.isCanonicalSHA256(previousSerial),
      !previousTopology.isEmpty,
      previousTopology.utf8.allSatisfy({ (48...57).contains($0) }),
      previousTopology == "0" || previousTopology.first != "0"
    else {
      throw RockchipFlashExecutionError.productionConfigurationUnavailable(
        "durable binding previous-mode identity is invalid or ambiguous")
    }
    let previous = RockchipPostflightIdentity(
      serialDigestSHA256: previousSerial, usbTopology: previousTopology)
    return previous == current ? [current] : [current, previous]
  }
}

struct RockchipProductBindingStore: Sendable {
  static let bindingFileName = "rockchip-binding.json"
  static let lockFileName = ".rockchip-binding.lock"
  static let maximumDocumentBytes = 64 * 1_024

  let rootURL: URL

  func loadExisting() throws -> RockchipProductBindingSnapshot {
    try prepareRoot()
    let rootDescriptor = Darwin.open(
      rootURL.path, O_RDONLY | O_DIRECTORY | O_CLOEXEC | O_NOFOLLOW)
    guard rootDescriptor >= 0 else { throw configurationError("binding root cannot be opened") }
    defer { Darwin.close(rootDescriptor) }
    guard let snapshot = try load(rootDescriptor: rootDescriptor) else {
      throw configurationError("durable Rockchip binding is not installed")
    }
    return snapshot
  }

  func install(_ candidate: RockchipProductBindingSnapshot)
    throws -> (snapshot: RockchipProductBindingSnapshot, created: Bool)
  {
    try validate(candidate)
    try prepareRoot()
    let rootDescriptor = Darwin.open(
      rootURL.path, O_RDONLY | O_DIRECTORY | O_CLOEXEC | O_NOFOLLOW)
    guard rootDescriptor >= 0 else { throw configurationError("binding root cannot be opened") }
    defer { Darwin.close(rootDescriptor) }

    let lockDescriptor = Darwin.openat(
      rootDescriptor, Self.lockFileName,
      O_CREAT | O_RDWR | O_CLOEXEC | O_NOFOLLOW, S_IRUSR | S_IWUSR)
    guard lockDescriptor >= 0 else { throw configurationError("binding lock cannot be opened") }
    defer { Darwin.close(lockDescriptor) }
    try validateOwnedRegularFile(lockDescriptor, permissions: 0o600, label: "binding lock")
    guard flock(lockDescriptor, LOCK_EX) == 0 else {
      throw configurationError("binding lock cannot be acquired")
    }
    defer { _ = flock(lockDescriptor, LOCK_UN) }

    if let existing = try load(rootDescriptor: rootDescriptor) {
      guard existing.serial == candidate.serial,
        existing.usbTopology == candidate.usbTopology
      else {
        throw configurationError(
          "durable binding differs from the only connected Loader; explicit rebind is required")
      }
      return (existing, false)
    }

    let encoder = JSONEncoder()
    encoder.outputFormatting = [.sortedKeys]
    var document = try encoder.encode(candidate)
    document.append(0x0A)
    guard document.count <= Self.maximumDocumentBytes else {
      throw configurationError("binding document exceeds its product limit")
    }

    let temporaryName = ".rockchip-binding.\(UUID().uuidString.lowercased()).part"
    let temporaryDescriptor = Darwin.openat(
      rootDescriptor, temporaryName,
      O_WRONLY | O_CREAT | O_EXCL | O_CLOEXEC | O_NOFOLLOW, S_IRUSR | S_IWUSR)
    guard temporaryDescriptor >= 0 else {
      throw configurationError("binding temporary file cannot be created")
    }
    var temporaryOpen = true
    defer {
      if temporaryOpen { Darwin.close(temporaryDescriptor) }
      _ = unlinkat(rootDescriptor, temporaryName, 0)
    }
    do {
      try writeAll(document, descriptor: temporaryDescriptor)
      guard fchmod(temporaryDescriptor, S_IRUSR | S_IWUSR) == 0,
        Darwin.fsync(temporaryDescriptor) == 0,
        Darwin.fcntl(temporaryDescriptor, F_FULLFSYNC) == 0
      else { throw configurationError("binding temporary file cannot be synchronized") }
      guard Darwin.close(temporaryDescriptor) == 0 else {
        throw configurationError("binding temporary file cannot be closed")
      }
      temporaryOpen = false
      guard
        renameatx_np(
          rootDescriptor, temporaryName, rootDescriptor, Self.bindingFileName,
          UInt32(RENAME_EXCL)) == 0
      else { throw configurationError("binding publication cannot be committed") }
      guard Darwin.fsync(rootDescriptor) == 0 else {
        throw configurationError("binding directory cannot be synchronized")
      }
    } catch let error as RockchipFlashExecutionError {
      throw error
    } catch {
      throw configurationError("binding publication failed")
    }

    guard let readback = try load(rootDescriptor: rootDescriptor), readback == candidate else {
      throw configurationError("binding write-readback failed")
    }
    return (readback, true)
  }

  func rebind(
    expectedCurrent: RockchipProductBindingSnapshot,
    candidate: RockchipProductBindingSnapshot
  ) throws -> RockchipProductBindingSnapshot {
    try validate(expectedCurrent)
    try validate(candidate)
    guard candidate.revision == expectedCurrent.revision + 1 else {
      throw configurationError("rebind revision must advance exactly once")
    }
    try prepareRoot()
    let rootDescriptor = Darwin.open(
      rootURL.path, O_RDONLY | O_DIRECTORY | O_CLOEXEC | O_NOFOLLOW)
    guard rootDescriptor >= 0 else { throw configurationError("binding root cannot be opened") }
    defer { Darwin.close(rootDescriptor) }

    let lockDescriptor = Darwin.openat(
      rootDescriptor, Self.lockFileName,
      O_CREAT | O_RDWR | O_CLOEXEC | O_NOFOLLOW, S_IRUSR | S_IWUSR)
    guard lockDescriptor >= 0 else { throw configurationError("binding lock cannot be opened") }
    defer { Darwin.close(lockDescriptor) }
    try validateOwnedRegularFile(lockDescriptor, permissions: 0o600, label: "binding lock")
    guard flock(lockDescriptor, LOCK_EX) == 0 else {
      throw configurationError("binding lock cannot be acquired")
    }
    defer { _ = flock(lockDescriptor, LOCK_UN) }

    guard let liveCurrent = try load(rootDescriptor: rootDescriptor),
      liveCurrent == expectedCurrent
    else { throw configurationError("durable binding changed before rebind persistence") }

    let encoder = JSONEncoder()
    encoder.outputFormatting = [.sortedKeys]
    var document = try encoder.encode(candidate)
    document.append(0x0A)
    guard document.count <= Self.maximumDocumentBytes else {
      throw configurationError("binding document exceeds its product limit")
    }

    let temporaryName = ".rockchip-binding.\(UUID().uuidString.lowercased()).part"
    let temporaryDescriptor = Darwin.openat(
      rootDescriptor, temporaryName,
      O_WRONLY | O_CREAT | O_EXCL | O_CLOEXEC | O_NOFOLLOW, S_IRUSR | S_IWUSR)
    guard temporaryDescriptor >= 0 else {
      throw configurationError("binding temporary file cannot be created")
    }
    var temporaryOpen = true
    defer {
      if temporaryOpen { Darwin.close(temporaryDescriptor) }
      _ = unlinkat(rootDescriptor, temporaryName, 0)
    }
    do {
      try writeAll(document, descriptor: temporaryDescriptor)
      guard fchmod(temporaryDescriptor, S_IRUSR | S_IWUSR) == 0,
        Darwin.fsync(temporaryDescriptor) == 0,
        Darwin.fcntl(temporaryDescriptor, F_FULLFSYNC) == 0
      else { throw configurationError("binding temporary file cannot be synchronized") }
      guard Darwin.close(temporaryDescriptor) == 0 else {
        throw configurationError("binding temporary file cannot be closed")
      }
      temporaryOpen = false
      guard
        renameatx_np(
          rootDescriptor, temporaryName, rootDescriptor, Self.bindingFileName,
          UInt32(RENAME_SWAP)) == 0
      else { throw configurationError("binding rebind publication cannot be committed") }
      // After RENAME_SWAP the temporary name contains the prior durable binding. Removing that
      // name only happens after the new bytes occupy the canonical binding path atomically.
      guard unlinkat(rootDescriptor, temporaryName, 0) == 0,
        Darwin.fsync(rootDescriptor) == 0
      else { throw configurationError("binding rebind directory cannot be synchronized") }
    } catch let error as RockchipFlashExecutionError {
      throw error
    } catch {
      throw configurationError("binding rebind publication failed")
    }

    guard let readback = try load(rootDescriptor: rootDescriptor), readback == candidate else {
      throw configurationError("binding rebind write-readback failed")
    }
    return readback
  }

  private func prepareRoot() throws {
    guard rootURL.isFileURL, rootURL.path.hasPrefix("/") else {
      throw configurationError("binding root must be an absolute file URL")
    }
    var existing = stat()
    if lstat(rootURL.path, &existing) == 0, existing.st_mode & S_IFMT == S_IFLNK {
      throw configurationError("binding root cannot be a symbolic link")
    }
    do {
      try FileManager.default.createDirectory(
        at: rootURL, withIntermediateDirectories: true,
        attributes: [.posixPermissions: 0o700])
    } catch {
      throw configurationError("binding root cannot be created")
    }
    guard chmod(rootURL.path, 0o700) == 0 else {
      throw configurationError("binding root must be owner-only")
    }
  }

  private func load(rootDescriptor: Int32) throws -> RockchipProductBindingSnapshot? {
    let descriptor = Darwin.openat(
      rootDescriptor, Self.bindingFileName, O_RDONLY | O_CLOEXEC | O_NOFOLLOW)
    if descriptor < 0 {
      if errno == ENOENT { return nil }
      throw configurationError("durable binding cannot be opened")
    }
    defer { Darwin.close(descriptor) }
    try validateOwnedRegularFile(descriptor, permissions: 0o600, label: "durable binding")
    var metadata = stat()
    guard fstat(descriptor, &metadata) == 0,
      metadata.st_size > 0,
      metadata.st_size <= Self.maximumDocumentBytes
    else { throw configurationError("durable binding size is invalid") }
    let document = try readAll(descriptor: descriptor, byteCount: Int(metadata.st_size))
    guard
      let object = try JSONSerialization.jsonObject(with: document) as? [String: Any],
      Set(object.keys) == ["revision", "serial", "usbTopology", "evidence"]
    else { throw configurationError("durable binding schema is invalid") }
    let snapshot: RockchipProductBindingSnapshot
    do {
      snapshot = try JSONDecoder().decode(RockchipProductBindingSnapshot.self, from: document)
    } catch {
      throw configurationError("durable binding cannot be decoded")
    }
    try validate(snapshot)
    return snapshot
  }

  private func validate(_ snapshot: RockchipProductBindingSnapshot) throws {
    guard snapshot.revision > 0,
      !snapshot.serial.isEmpty,
      !snapshot.usbTopology.isEmpty,
      snapshot.usbTopology.utf8.allSatisfy({ (48...57).contains($0) }),
      !snapshot.evidence.isEmpty,
      snapshot.evidence.allSatisfy({ !$0.isEmpty && !$0.contains(snapshot.serial) })
    else { throw configurationError("durable binding snapshot is invalid") }
  }

  private func validateOwnedRegularFile(
    _ descriptor: Int32,
    permissions: mode_t,
    label: String
  ) throws {
    var metadata = stat()
    guard fstat(descriptor, &metadata) == 0,
      metadata.st_mode & S_IFMT == S_IFREG,
      metadata.st_nlink == 1,
      metadata.st_uid == getuid(),
      metadata.st_mode & 0o777 == permissions
    else { throw configurationError("\(label) must be an owner-only regular file") }
  }

  private func readAll(descriptor: Int32, byteCount: Int) throws -> Data {
    var result = Data()
    result.reserveCapacity(byteCount)
    var buffer = [UInt8](repeating: 0, count: min(4_096, byteCount))
    while result.count < byteCount {
      let count = Darwin.read(descriptor, &buffer, min(buffer.count, byteCount - result.count))
      if count < 0 {
        if errno == EINTR { continue }
        throw configurationError("durable binding cannot be read")
      }
      guard count > 0 else { throw configurationError("durable binding was truncated") }
      result.append(contentsOf: buffer.prefix(count))
    }
    return result
  }

  private func writeAll(_ data: Data, descriptor: Int32) throws {
    try data.withUnsafeBytes { bytes in
      guard let base = bytes.baseAddress else { return }
      var offset = 0
      while offset < bytes.count {
        let written = Darwin.write(descriptor, base.advanced(by: offset), bytes.count - offset)
        if written < 0 {
          if errno == EINTR { continue }
          throw configurationError("binding temporary file cannot be written")
        }
        guard written > 0 else {
          throw configurationError("binding temporary file cannot be written")
        }
        offset += written
      }
    }
  }

  private func configurationError(_ detail: String) -> RockchipFlashExecutionError {
    .productionConfigurationUnavailable(detail)
  }
}

struct RockchipProductBindingBootstrap: Sendable {
  let probe: @Sendable () throws -> RockchipProductUSBIdentity
  let store: RockchipProductBindingStore

  func installCurrentTarget() throws -> RockchipDeviceBindingInstallationReceipt {
    let identity = try probe()
    guard identity.isRegisteredDAYU200Mode,
      !identity.serial.isEmpty,
      !identity.topology.isEmpty,
      identity.topology.utf8.allSatisfy({ (48...57).contains($0) })
    else {
      throw RockchipFlashExecutionError.admissionRejected(
        "the single USB identity is not a registered DAYU200 mode")
    }
    let serialDigest = SHA256.hash(data: Data(identity.serial.utf8))
      .map { String(format: "%02x", $0) }.joined()
    let candidate = RockchipProductBindingSnapshot(
      revision: 1,
      serial: identity.serial,
      usbTopology: identity.topology,
      evidence: [
        "product:e0-iokit-single-dayu200-readback",
        "usb:vendor=\(RockchipProbeEvidence.rockUSBVendorID),profile=dayu200-cross-mode",
        "identity:serial-sha256=\(serialDigest)",
      ])
    let result = try store.install(candidate)
    let storedDigest = SHA256.hash(data: Data(result.snapshot.serial.utf8))
      .map { String(format: "%02x", $0) }.joined()
    return RockchipDeviceBindingInstallationReceipt(
      revision: result.snapshot.revision,
      usbTopology: result.snapshot.usbTopology,
      serialDigestSHA256: storedDigest,
      created: result.created)
  }

  /// Compatibility seam retained for existing contracts and callers.  It now
  /// has the same cross-mode behavior as the product entry point.
  func installCurrentLoader() throws -> RockchipDeviceBindingInstallationReceipt {
    try installCurrentTarget()
  }
}

struct RockchipProductBindingRebinder: Sendable {
  private struct Facts {
    let existing: RockchipProductBindingSnapshot
    let identity: RockchipProductUSBIdentity
    let serialDigestSHA256: String
    let prospectiveRevision: Int
    let requiresRebind: Bool
    let targetDigestSHA256: String
  }

  let probe: @Sendable () throws -> RockchipProductUSBIdentity
  let store: RockchipProductBindingStore

  func previewCurrentLoader() throws -> RockchipDeviceBindingRebindPreview {
    let facts = try currentFacts()
    return RockchipDeviceBindingRebindPreview(
      currentRevision: facts.existing.revision,
      prospectiveRevision: facts.prospectiveRevision,
      requiresRebind: facts.requiresRebind,
      usbTopology: facts.identity.topology,
      serialDigestSHA256: facts.serialDigestSHA256,
      targetDigestSHA256: facts.targetDigestSHA256)
  }

  func confirmCurrentLoader(
    chatConfirmation assertion: RockchipChatConfirmationAssertion
  ) throws -> RockchipDeviceBindingRebindReceipt {
    let facts = try currentFacts()
    try validate(assertion: assertion, facts: facts)
    guard facts.requiresRebind else {
      return receipt(facts: facts, stored: facts.existing, changed: false)
    }

    let candidateID = Self.sha256Hex(
      Data(
        ["dayu200-loader", facts.serialDigestSHA256, facts.identity.topology]
          .joined(separator: "|").utf8))
    let identitySnapshot = try DeviceIdentitySnapshot(attributes: [
      "mode": .string(RockchipDeviceMode.loader.rawValue),
      "serial": .string(facts.identity.serial),
      "usbProductID": .unsignedInteger(UInt64(facts.identity.productID)),
      "usbTopology": .string(facts.identity.topology),
      "usbVendorID": .unsignedInteger(UInt64(facts.identity.vendorID)),
    ])
    let candidateEvidence = [
      "product:e0-iokit-single-loader-readback",
      "usb:vendor=\(facts.identity.vendorID),product=\(facts.identity.productID)",
      "identity:serial-sha256=\(facts.serialDigestSHA256)",
      "rebind:chat-confirmation-sha256=\(assertion.confirmationDigestSHA256)",
    ]
    let candidate = try DeviceRebindCandidate(
      candidateID: candidateID, connectKey: facts.identity.topology, transport: .usb,
      identitySnapshot: identitySnapshot, evidence: candidateEvidence,
      usbEvidence: USBRebindEvidence(
        serialMatches: facts.existing.serial == facts.identity.serial,
        daemonFingerprintMatches: false,
        topologyMatches: facts.existing.usbTopology == facts.identity.topology,
        expectedModeMatches: true, modelBuildMatches: true))
    let context = DeviceRebindContext(
      transport: .usb, disconnected: true, endpointExplicitlyAdded: false,
      expectedModeTransition: true, candidates: [candidate],
      profile: DeviceRebindProfilePolicy(
        requiresManualConfirmation: true, additionalEvidenceSatisfied: true),
      userConfirmedCandidateID: candidateID)
    try DeviceRebindPolicy.authorizePersistence(
      context: context, selectedCandidate: candidate, confirmedBy: .user)

    let candidateSnapshot = RockchipProductBindingSnapshot(
      revision: facts.prospectiveRevision, serial: facts.identity.serial,
      usbTopology: facts.identity.topology,
      evidence: candidateEvidence + [
        "identity:previous-serial-sha256=\(Self.serialDigest(facts.existing.serial))",
        "binding:previous-revision=\(facts.existing.revision)",
        "binding:previous-usb-topology=\(facts.existing.usbTopology)",
      ])
    let stored = try store.rebind(expectedCurrent: facts.existing, candidate: candidateSnapshot)
    return receipt(facts: facts, stored: stored, changed: true)
  }

  private func currentFacts() throws -> Facts {
    let existing = try store.loadExisting()
    let identity = try probe()
    guard identity.isLoader, !identity.serial.isEmpty,
      !identity.topology.isEmpty,
      identity.topology.utf8.allSatisfy({ (48...57).contains($0) })
    else {
      throw RockchipFlashExecutionError.admissionRejected(
        "current-Loader rebind requires exactly one IOKit 0x2207:0x350a Loader identity")
    }
    let requiresRebind = existing.serial != identity.serial
      || existing.usbTopology != identity.topology
    guard !requiresRebind || existing.revision < Int.max else {
      throw RockchipFlashExecutionError.productionConfigurationUnavailable(
        "durable binding revision cannot advance")
    }
    let prospectiveRevision = requiresRebind ? existing.revision + 1 : existing.revision
    let serialDigestSHA256 = Self.serialDigest(identity.serial)
    return Facts(
      existing: existing, identity: identity, serialDigestSHA256: serialDigestSHA256,
      prospectiveRevision: prospectiveRevision, requiresRebind: requiresRebind,
      targetDigestSHA256: Self.targetDigest(
        serialDigestSHA256: serialDigestSHA256, revision: prospectiveRevision,
        topology: identity.topology))
  }

  private func validate(
    assertion: RockchipChatConfirmationAssertion,
    facts: Facts
  ) throws {
    let plan = try RockchipRockUSBFlashProvider(profile: .dayu200OpenHarmony70035)
      .makePlan(mode: .execute, archiveValidation: .valid)
    guard assertion.planDigestSHA256 == plan.planDigestSHA256,
      assertion.archiveDigestSHA256 == plan.archiveSHA256,
      assertion.stepSetDigestSHA256 == plan.stepSetDigestSHA256,
      assertion.bindingRevision == facts.prospectiveRevision,
      assertion.targetDigestSHA256 == facts.targetDigestSHA256
    else {
      throw RockchipFlashExecutionError.invalidRequest(
        "chatConfirmation does not match the prospective Loader binding and exact plan")
    }
  }

  private func receipt(
    facts: Facts,
    stored: RockchipProductBindingSnapshot,
    changed: Bool
  ) -> RockchipDeviceBindingRebindReceipt {
    RockchipDeviceBindingRebindReceipt(
      previousRevision: facts.existing.revision, revision: stored.revision, changed: changed,
      usbTopology: stored.usbTopology,
      serialDigestSHA256: Self.serialDigest(stored.serial),
      targetDigestSHA256: Self.targetDigest(
        serialDigestSHA256: Self.serialDigest(stored.serial), revision: stored.revision,
        topology: stored.usbTopology))
  }

  private static func serialDigest(_ serial: String) -> String {
    sha256Hex(Data(serial.utf8))
  }

  private static func targetDigest(
    serialDigestSHA256: String,
    revision: Int,
    topology: String
  ) -> String {
    sha256Hex(
      Data(
        [
          RockchipFlashProfile.targetDeviceModel, serialDigestSHA256, String(revision), topology,
          String(RockchipProbeEvidence.rockUSBVendorID),
          String(RockchipProbeEvidence.dayu200LoaderProductID),
        ].joined(separator: "|").utf8))
  }

  private static func sha256Hex(_ data: Data) -> String {
    SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
  }
}

struct RockchipToolBookmarkPreferences {
  let object: (String) -> Any?
  let setObject: (Any, String) throws -> Void
  let removeObject: (String) throws -> Void

  static func userDefaults(_ defaults: UserDefaults) -> RockchipToolBookmarkPreferences {
    RockchipToolBookmarkPreferences(
      object: { defaults.object(forKey: $0) },
      setObject: { value, key in defaults.set(value, forKey: key) },
      removeObject: { defaults.removeObject(forKey: $0) })
  }
}

struct RockchipOrdinaryBookmarkCodec: Sendable {
  let create: @Sendable (URL) throws -> Data
  let resolve: @Sendable (Data) throws -> RockchipBookmarkResolution

  static let foundation = RockchipOrdinaryBookmarkCodec(
    create: {
      try $0.bookmarkData(
        options: [],
        includingResourceValuesForKeys: nil,
        relativeTo: nil)
    },
    resolve: {
      var isStale = false
      let url = try URL(
        resolvingBookmarkData: $0,
        options: [.withoutUI],
        relativeTo: nil,
        bookmarkDataIsStale: &isStale)
      return RockchipBookmarkResolution(url: url, isStale: isStale)
    })
}

struct RockchipPinnedExecutableVerifier: Sendable {
  let verify: @Sendable (URL) throws -> Void

  static let production = RockchipPinnedExecutableVerifier { executableURL in
    let request = ProcessIdentityBoundRequest(
      process: ProcessRequest(executable: executableURL),
      expectedSHA256: RockchipDiscoveryIntegrationProfile.pinnedProduction.executableSHA256)
    let prepared = try FoundationProcessExecutor().prepareIdentityBoundLaunch(request)
    prepared.close()
  }
}

struct RockchipProductToolTrustInspector: Sendable {
  let assess: @Sendable (URL) throws -> RockchipPlatformTrustReceipt
  let clearQuarantine: @Sendable (URL) throws -> Void

  static let production = RockchipProductToolTrustInspector(
    assess: { executableURL in
      let quarantinePresent: Bool
      errno = 0
      let size = getxattr(
        executableURL.path, "com.apple.quarantine", nil, 0, 0, XATTR_NOFOLLOW)
      if size >= 0 {
        quarantinePresent = true
      } else if errno == ENOATTR {
        quarantinePresent = false
      } else {
        throw RockchipFlashExecutionError.productionConfigurationUnavailable(
          "rkdeveloptool quarantine cannot be assessed")
      }

      var staticCode: SecStaticCode?
      var status = SecStaticCodeCreateWithPath(
        executableURL as CFURL, SecCSFlags(), &staticCode)
      guard status == errSecSuccess, let staticCode else {
        return RockchipPlatformTrustReceipt(
          codeTrust: .unsigned, quarantinePresent: quarantinePresent)
      }
      status = SecStaticCodeCheckValidity(
        staticCode,
        SecCSFlags(rawValue: kSecCSStrictValidate | kSecCSCheckAllArchitectures),
        nil)
      guard status == errSecSuccess else {
        return RockchipPlatformTrustReceipt(
          codeTrust: .rejected, quarantinePresent: quarantinePresent)
      }
      var rawInformation: CFDictionary?
      status = SecCodeCopySigningInformation(
        staticCode, SecCSFlags(rawValue: kSecCSSigningInformation), &rawInformation)
      guard status == errSecSuccess,
        let information = rawInformation as? [CFString: Any],
        let flags = information[kSecCodeInfoFlags] as? NSNumber
      else {
        return RockchipPlatformTrustReceipt(
          codeTrust: .unknown, quarantinePresent: quarantinePresent)
      }
      let codeTrust: RockchipPlatformCodeTrust
      if flags.uint32Value & 0x0000_0002 != 0 {
        codeTrust = .adHoc
      } else if let team = information[kSecCodeInfoTeamIdentifier] as? String,
        !team.isEmpty
      {
        codeTrust = .developerID
      } else {
        codeTrust = .unknown
      }
      return RockchipPlatformTrustReceipt(
        codeTrust: codeTrust, quarantinePresent: quarantinePresent)
    },
    clearQuarantine: { executableURL in
      guard
        removexattr(
          executableURL.path, "com.apple.quarantine", XATTR_NOFOLLOW) == 0
          || errno == ENOATTR
      else {
        throw RockchipFlashExecutionError.productionConfigurationUnavailable(
          "rkdeveloptool quarantine could not be removed")
      }
    })
}

struct RockchipToolTrustFactStore {
  static let codeTrustKey = "ArkDeck.Rockchip.ToolCodeTrust"
  static let quarantineKey = "ArkDeck.Rockchip.ToolQuarantinePresent"

  let preferences: RockchipToolBookmarkPreferences

  func persist(_ receipt: RockchipPlatformTrustReceipt) throws {
    guard receipt.permitsPinnedDiscovery,
      let quarantinePresent = receipt.quarantinePresent
    else {
      throw configurationError("rkdeveloptool platform trust is not permitted")
    }
    let previousCodeTrust = preferences.object(Self.codeTrustKey)
    let previousQuarantine = preferences.object(Self.quarantineKey)
    do {
      try preferences.setObject(receipt.codeTrust.rawValue, Self.codeTrustKey)
      try preferences.setObject(quarantinePresent, Self.quarantineKey)
      guard preferences.object(Self.codeTrustKey) as? String == receipt.codeTrust.rawValue,
        preferences.object(Self.quarantineKey) as? Bool == quarantinePresent
      else { throw configurationError("tool trust facts failed write-readback") }
    } catch {
      restore(previousCodeTrust, key: Self.codeTrustKey)
      restore(previousQuarantine, key: Self.quarantineKey)
      if let error = error as? RockchipFlashExecutionError { throw error }
      throw configurationError("tool trust facts could not be persisted")
    }
  }

  private func restore(_ value: Any?, key: String) {
    if let value {
      try? preferences.setObject(value, key)
    } else {
      try? preferences.removeObject(key)
    }
  }

  private func configurationError(_ detail: String) -> RockchipFlashExecutionError {
    .productionConfigurationUnavailable(detail)
  }
}

struct RockchipInstalledToolLocator {
  let executableURL: URL
  let bookmarkData: Data
}

struct RockchipProductToolBookmarkStore {
  static let legacyKey = "ArkDeck.Rockchip.ToolBookmark"
  static let ordinaryKey = "ArkDeck.Rockchip.ToolOrdinaryBookmarkV1"

  let preferences: RockchipToolBookmarkPreferences
  let codec: RockchipOrdinaryBookmarkCodec
  let verifier: RockchipPinnedExecutableVerifier

  static var production: RockchipProductToolBookmarkStore {
    RockchipProductToolBookmarkStore(
      preferences: .userDefaults(.standard),
      codec: .foundation,
      verifier: .production)
  }

  func install(executableURL: URL) throws {
    let canonicalURL = try canonicalInstallURL(executableURL)
    do {
      try verifier.verify(canonicalURL)
    } catch {
      throw configurationError("pinned rkdeveloptool executable validation failed")
    }

    let bookmark: Data
    do {
      bookmark = try codec.create(canonicalURL)
      _ = try resolve(bookmark, expectedURL: canonicalURL)
    } catch let error as RockchipFlashExecutionError {
      throw error
    } catch {
      throw configurationError("ordinary rkdeveloptool bookmark self-check failed")
    }

    let previousNewValue = preferences.object(Self.ordinaryKey)
    do {
      try preferences.setObject(bookmark, Self.ordinaryKey)
      guard let readback = preferences.object(Self.ordinaryKey) as? Data,
        readback == bookmark
      else {
        throw configurationError("ordinary rkdeveloptool bookmark write-readback failed")
      }
      _ = try resolve(readback, expectedURL: canonicalURL)
    } catch {
      restoreOrdinaryValue(previousNewValue)
      if let error = error as? RockchipFlashExecutionError { throw error }
      throw configurationError("ordinary rkdeveloptool bookmark persistence failed")
    }

    guard preferences.object(Self.legacyKey) != nil else { return }
    do {
      try preferences.removeObject(Self.legacyKey)
      guard preferences.object(Self.legacyKey) == nil else {
        throw configurationError("legacy rkdeveloptool bookmark deletion failed")
      }
    } catch let error as RockchipFlashExecutionError {
      // A dual-key crash/fault state is intentionally retained. `load()` rejects it,
      // and rerunning this installer can finish the migration.
      throw error
    } catch {
      throw configurationError("legacy rkdeveloptool bookmark deletion failed")
    }
  }

  func load() throws -> RockchipInstalledToolLocator {
    let legacyPresent = preferences.object(Self.legacyKey) != nil
    let newValue = preferences.object(Self.ordinaryKey)
    if legacyPresent {
      let detail =
        newValue == nil
        ? "legacy pinned rkdeveloptool bookmark requires product reinstall"
        : "conflicting legacy and ordinary rkdeveloptool bookmarks require product reinstall"
      throw configurationError(detail)
    }
    guard let newValue else {
      throw configurationError("pinned rkdeveloptool ordinary bookmark is not installed")
    }
    guard let bookmark = newValue as? Data else {
      throw configurationError("pinned rkdeveloptool ordinary bookmark has the wrong type")
    }
    let executableURL = try resolve(bookmark, expectedURL: nil)
    return RockchipInstalledToolLocator(executableURL: executableURL, bookmarkData: bookmark)
  }

  private func canonicalInstallURL(_ url: URL) throws -> URL {
    guard url.isFileURL, url.path.hasPrefix("/") else {
      throw configurationError("rkdeveloptool install path must be an absolute file URL")
    }
    let standardized = url.standardizedFileURL
    let canonical = standardized.resolvingSymlinksInPath().standardizedFileURL
    guard url.path == standardized.path, standardized.path == canonical.path else {
      throw configurationError("rkdeveloptool install path must be canonical and non-symlinked")
    }
    return canonical
  }

  private func resolve(_ bookmark: Data, expectedURL: URL?) throws -> URL {
    let resolution: RockchipBookmarkResolution
    do {
      resolution = try codec.resolve(bookmark)
    } catch {
      throw configurationError("pinned rkdeveloptool ordinary bookmark is corrupt or inaccessible")
    }
    let standardized = resolution.url.standardizedFileURL
    let canonical = standardized.resolvingSymlinksInPath().standardizedFileURL
    guard !resolution.isStale, resolution.url.isFileURL, resolution.url.path.hasPrefix("/"),
      standardized.path == canonical.path
    else {
      throw configurationError("pinned rkdeveloptool ordinary bookmark is stale or non-canonical")
    }
    if let expectedURL {
      guard canonical == expectedURL.resolvingSymlinksInPath().standardizedFileURL else {
        throw configurationError("pinned rkdeveloptool ordinary bookmark path mismatched")
      }
    }
    return canonical
  }

  private func restoreOrdinaryValue(_ previousValue: Any?) {
    if let previousValue {
      try? preferences.setObject(previousValue, Self.ordinaryKey)
    } else {
      try? preferences.removeObject(Self.ordinaryKey)
    }
  }

  private func configurationError(_ detail: String) -> RockchipFlashExecutionError {
    .productionConfigurationUnavailable(detail)
  }
}

struct RockchipProductToolInstaller {
  let bookmarks: RockchipProductToolBookmarkStore
  let trustInspector: RockchipProductToolTrustInspector
  let trustFacts: RockchipToolTrustFactStore

  static var production: RockchipProductToolInstaller {
    let preferences = RockchipToolBookmarkPreferences.userDefaults(.standard)
    return RockchipProductToolInstaller(
      bookmarks: RockchipProductToolBookmarkStore(
        preferences: preferences,
        codec: .foundation,
        verifier: .production),
      trustInspector: .production,
      trustFacts: RockchipToolTrustFactStore(preferences: preferences))
  }

  func install(executableURL: URL) throws -> RockchipToolInstallationReceipt {
    try bookmarks.install(executableURL: executableURL)
    let assessment = try trustInspector.assess(executableURL)
    guard assessment.quarantinePresent == false else {
      throw configurationError(
        "rkdeveloptool is quarantined; use the exact-digest trust-tool entry after explicit trust")
    }
    try trustFacts.persist(assessment)
    return receipt(assessment)
  }

  func trustAndInstall(
    executableURL: URL,
    expectedSHA256: String
  ) throws -> RockchipToolInstallationReceipt {
    let pinned = RockchipDiscoveryIntegrationProfile.pinnedProduction.executableSHA256
    guard expectedSHA256 == pinned else {
      throw configurationError("trust-tool digest does not equal the product pin")
    }
    // The first install is an identity-bound, prepared-only hash check. Quarantine removal is
    // unreachable until that exact descriptor identity has passed the product pin.
    try bookmarks.install(executableURL: executableURL)
    let before = try trustInspector.assess(executableURL)
    if before.quarantinePresent == true {
      try trustInspector.clearQuarantine(executableURL)
    }
    // Re-verify the post-transition file and assess the platform facts from live metadata.
    try bookmarks.install(executableURL: executableURL)
    let after = try trustInspector.assess(executableURL)
    guard after.quarantinePresent == false else {
      throw configurationError("rkdeveloptool remains quarantined after trust transition")
    }
    try trustFacts.persist(after)
    return receipt(after)
  }

  private func receipt(_ assessment: RockchipPlatformTrustReceipt)
    -> RockchipToolInstallationReceipt
  {
    RockchipToolInstallationReceipt(
      executableSHA256: RockchipDiscoveryIntegrationProfile.pinnedProduction.executableSHA256,
      codeTrust: assessment.codeTrust,
      quarantinePresent: assessment.quarantinePresent ?? true)
  }

  private func configurationError(_ detail: String) -> RockchipFlashExecutionError {
    .productionConfigurationUnavailable(detail)
  }
}

private final class RockchipProductExecutionSettings: @unchecked Sendable {
  let usageRoot: URL
  let tool: RockchipSelectedDiscoveryTool
  let binding: RockchipProductBindingSnapshot

  private init(
    usageRoot: URL,
    tool: RockchipSelectedDiscoveryTool,
    binding: RockchipProductBindingSnapshot
  ) {
    self.usageRoot = usageRoot
    self.tool = tool
    self.binding = binding
  }

  static func load() throws -> RockchipProductExecutionSettings {
    let manager = FileManager.default
    let applicationSupport = try manager.url(
      for: .applicationSupportDirectory, in: .userDomainMask,
      appropriateFor: nil, create: true)
    let root = applicationSupport.appending(path: "ArkDeck", directoryHint: .isDirectory)
    let usage = root.appending(path: "AuthorizationUsage", directoryHint: .isDirectory)
    for directory in [root, usage] {
      try manager.createDirectory(
        at: directory, withIntermediateDirectories: true,
        attributes: [.posixPermissions: 0o700])
      guard chmod(directory.path, 0o700) == 0 else {
        throw RockchipFlashExecutionError.productionConfigurationUnavailable(
          "owner-only Application Support directory")
      }
    }

    let defaults = UserDefaults.standard
    let locator = try RockchipProductToolBookmarkStore(
      preferences: .userDefaults(defaults),
      codec: .foundation,
      verifier: .production
    ).load()
    let executableURL = locator.executableURL
    let trustRaw = defaults.string(forKey: RockchipToolTrustFactStore.codeTrustKey)
    let trust = trustRaw.flatMap(RockchipPlatformCodeTrust.init(rawValue:)) ?? .unknown
    guard defaults.object(forKey: RockchipToolTrustFactStore.quarantineKey) != nil else {
      throw RockchipFlashExecutionError.productionConfigurationUnavailable(
        "tool quarantine assessment is absent")
    }
    let quarantine = defaults.bool(forKey: RockchipToolTrustFactStore.quarantineKey)
    let liveTrust = try RockchipProductToolTrustInspector.production.assess(executableURL)
    guard liveTrust.codeTrust == trust,
      liveTrust.quarantinePresent == quarantine,
      liveTrust.permitsPinnedDiscovery
    else {
      throw RockchipFlashExecutionError.productionConfigurationUnavailable(
        "live rkdeveloptool platform trust differs from its installed facts")
    }
    let selectedTool = RockchipSelectedDiscoveryTool(
      executableURL: executableURL, pathSource: .installedOrdinaryBookmark,
      bookmarkData: locator.bookmarkData,
      reportedVersion: RockchipDiscoveryIntegrationProfile.pinnedProduction.reportedToolVersion,
      sha256: RockchipDiscoveryIntegrationProfile.pinnedProduction.executableSHA256,
      platformTrust: RockchipPlatformTrustReceipt(
        codeTrust: trust, quarantinePresent: quarantine))
    let binding = try RockchipProductBindingStore(rootURL: root).loadExisting()
    return RockchipProductExecutionSettings(
      usageRoot: usage, tool: selectedTool, binding: binding)
  }

  fileprivate static func productKeychainToken() throws -> String? {
    let query: [CFString: Any] = [
      kSecClass: kSecClassGenericPassword,
      kSecAttrService: "dev.arkdeck.github-provenance",
      kSecAttrAccount: "protected-main-reader",
      kSecReturnData: true,
      kSecMatchLimit: kSecMatchLimitOne,
    ]
    var item: CFTypeRef?
    let status = SecItemCopyMatching(query as CFDictionary, &item)
    if status == errSecItemNotFound { return nil }
    guard status == errSecSuccess, let data = item as? Data else {
      throw RockchipFlashExecutionError.productionConfigurationUnavailable(
        "Keychain provenance credential cannot be read")
    }
    return String(data: data, encoding: .utf8)
  }
}

struct RockchipProductUSBIdentity: Sendable, Equatable {
  let serial: String
  let vendorID: UInt16
  let productID: UInt16
  let topology: String
  let productName: String?

  init(
    serial: String,
    vendorID: UInt16,
    productID: UInt16,
    topology: String,
    productName: String? = nil
  ) {
    self.serial = serial
    self.vendorID = vendorID
    self.productID = productID
    self.topology = topology
    self.productName = productName
  }

  var isLoader: Bool {
    vendorID == RockchipProbeEvidence.rockUSBVendorID
      && productID == RockchipProbeEvidence.dayu200LoaderProductID
  }

  var isHDCNormal: Bool {
    guard vendorID == RockchipProbeEvidence.rockUSBVendorID,
      productID == RockchipHDCIntegrationProfile.dayu200NormalProductID,
      let productName
    else { return false }
    return productName.trimmingCharacters(in: CharacterSet(charactersIn: "\" ")) == "HDC Device"
  }

  var isRegisteredDAYU200Mode: Bool { isLoader || isHDCNormal }
}

struct RockchipProductUSBProbe: Sendable {
  private enum Requirement {
    case loader
    case hdcNormal
    case registeredDAYU200
  }

  func singleLoader(selector: String? = nil) throws -> RockchipProductUSBIdentity {
    try single(selector: selector, serialDigestSHA256: nil, requirement: .loader)
  }

  func singleLoader(
    stableIdentitySHA256: String
  ) throws -> RockchipProductUSBIdentity {
    try single(
      selector: nil, serialDigestSHA256: stableIdentitySHA256,
      requirement: .loader)
  }

  func singleLoader(
    selector: String,
    stableIdentitySHA256: String
  ) throws -> RockchipProductUSBIdentity {
    try single(
      selector: selector, serialDigestSHA256: stableIdentitySHA256,
      requirement: .loader)
  }

  func singleDAYU200(
    selector: String? = nil,
    stableIdentitySHA256: String? = nil
  ) throws -> RockchipProductUSBIdentity {
    try single(
      selector: selector, serialDigestSHA256: stableIdentitySHA256,
      requirement: .registeredDAYU200)
  }

  func singleConnected(selector: String? = nil) throws -> RockchipProductUSBIdentity {
    try single(
      selector: selector, serialDigestSHA256: nil,
      requirement: .hdcNormal)
  }

  private func single(
    selector: String?,
    serialDigestSHA256: String?,
    requirement: Requirement
  ) throws
    -> RockchipProductUSBIdentity
  {
    var iterator: io_iterator_t = 0
    guard
      IOServiceGetMatchingServices(
        kIOMainPortDefault, IOServiceMatching("IOUSBHostDevice"), &iterator) == KERN_SUCCESS
    else { throw RockchipFlashExecutionError.admissionRejected("USB registry unavailable") }
    defer { IOObjectRelease(iterator) }
    var matches: [RockchipProductUSBIdentity] = []
    while true {
      let service = IOIteratorNext(iterator)
      if service == 0 { break }
      defer { IOObjectRelease(service) }
      guard let vendor = number(service, "idVendor"),
        let product = number(service, "idProduct"),
        let location = number(service, "locationID"),
        let serial = string(service, "USB Serial Number")
          ?? string(service, "kUSBSerialNumberString")
      else { continue }
      let identity = RockchipProductUSBIdentity(
        serial: serial, vendorID: vendor.uint16Value,
        productID: product.uint16Value, topology: String(location.uint64Value),
        productName: string(service, "USB Product Name"))
      let modeMatches: Bool
      switch requirement {
      case .loader: modeMatches = identity.isLoader
      case .hdcNormal: modeMatches = identity.isHDCNormal
      case .registeredDAYU200: modeMatches = identity.isRegisteredDAYU200Mode
      }
      guard modeMatches else { continue }
      let digest = SHA256.hash(data: Data(serial.utf8))
        .map { String(format: "%02x", $0) }.joined()
      if (selector == nil || selector == identity.topology)
        && (serialDigestSHA256 == nil || serialDigestSHA256 == digest)
      {
        matches.append(identity)
      }
    }
    guard matches.count == 1, let match = matches.first else {
      throw RockchipFlashExecutionError.admissionRejected(
        matches.isEmpty ? "DAYU200 target unavailable" : "DAYU200 target ambiguous")
    }
    return match
  }

  private func number(_ service: io_registry_entry_t, _ key: String) -> NSNumber? {
    IORegistryEntryCreateCFProperty(service, key as CFString, kCFAllocatorDefault, 0)?
      .takeRetainedValue() as? NSNumber
  }

  private func string(_ service: io_registry_entry_t, _ key: String) -> String? {
    IORegistryEntryCreateCFProperty(service, key as CFString, kCFAllocatorDefault, 0)?
      .takeRetainedValue() as? String
  }
}

private struct RockchipProductBindingPort: RockchipDurableBindingFactPort {
  let sessionID: String
  let jobID: String
  let targetID: String
  let snapshot: RockchipProductBindingSnapshot

  func currentDurableBinding() async throws -> RockchipTrustedDurableBindingFact {
    let identity = try DeviceIdentitySnapshot(attributes: [
      "serial": .string(snapshot.serial), "usbTopology": .string(snapshot.usbTopology),
    ])
    let binding = try CurrentDeviceBinding(
      revision: snapshot.revision, connectKey: snapshot.usbTopology, transport: .usb,
      identitySnapshot: identity, evidence: snapshot.evidence, confirmedBy: .corePolicy,
      channelProtection: .unverifiedAssumeUnprotected)
    return RockchipTrustedDurableBindingFact(
      sessionID: sessionID, jobID: jobID, targetID: targetID,
      receipt: try DurableCurrentDeviceBinding(
        reference: DeviceBindingReference(targetID: targetID, revision: snapshot.revision),
        binding: binding))
  }
}

private struct RockchipProductPrerequisitePort: RockchipPrerequisiteFactPort {
  let sessionID: String
  let jobID: String
  let targetID: String
  let selector: String
  let probe: RockchipProductUSBProbe

  func probePrerequisites() async throws -> RockchipTrustedPrerequisiteFact {
    _ = try probe.singleLoader(selector: selector)
    return RockchipTrustedPrerequisiteFact(
      sessionID: sessionID, jobID: jobID, targetID: targetID,
      observations: [
        RockchipPrerequisiteObservation(identifier: .loader, status: .satisfied),
        RockchipPrerequisiteObservation(identifier: .recoveryPath, status: .satisfied),
        RockchipPrerequisiteObservation(identifier: .unlocked, status: .satisfied),
      ])
  }
}

private struct RockchipProductIdentityReadbackPort: RockchipIdentityReadbackFactPort {
  let sessionID: String
  let jobID: String
  let targetID: String
  let selector: String
  let observationSequence: UInt64
  let probe: RockchipProductUSBProbe
  let clock: any RockchipAdmissionClock

  func readIdentity() async throws -> RockchipTrustedIdentityReadbackFact {
    let identity = try probe.singleLoader(selector: selector)
    let reading = clock.now()
    return RockchipTrustedIdentityReadbackFact(
      sessionID: sessionID, jobID: jobID, targetID: targetID,
      observationSequence: observationSequence,
      observedAtMonotonicNanoseconds: reading.monotonicNanoseconds,
      deadlineMonotonicNanoseconds: reading.monotonicNanoseconds
        + RockchipAuthorizationFactCollector.maximumReadbackLifetimeNanoseconds,
      observedAtTimestamp: reading.auditTimestamp,
      serialDigestSHA256: SHA256.hash(data: Data(identity.serial.utf8)).map {
        String(format: "%02x", $0)
      }.joined(),
      usbVendorID: identity.vendorID, usbProductID: identity.productID,
      usbTopology: identity.topology)
  }
}

/// Admission collector for the normal HDC USB personality.  No mutation is
/// performed here: it proves the durable serial/topology, the exact external
/// Rockchip and HDC executable descriptors, and that the already-published
/// execute plan contains the closed `rockusb.enter-loader` intent.  The
/// reboot itself happens only after the one-shot E2 token is consumed and the
/// step intent is durable.
private struct RockchipProductHDCNormalAuthorizationFactCollector:
  RockchipAuthorizationFactCollecting
{
  let planPort: RockchipProductExecutePlanFactPort
  let bindingPort: RockchipProductBindingPort
  let tool: RockchipSelectedDiscoveryTool
  let selector: String
  let usbProbe: RockchipProductUSBProbe
  let clock: any RockchipAdmissionClock

  func collect(
    request: RockchipAuthorizationFactRequest,
    grant: VerifiedAuthorizationGrant
  ) async throws -> RockchipTrustedAuthorizationFacts {
    try await collect(
      request: request,
      expectation: RockchipAuthorizationFactExpectation(
        standingAuthorization: grant.authorization))
  }

  func collect(
    request: RockchipAuthorizationFactRequest,
    expectation: RockchipAuthorizationFactExpectation
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
    do { plan = try await planPort.makeValidatedExecutePlan(archiveURL: request.archiveURL) } catch
    {
      throw RockchipAuthorizationFactError.factPortFailed(name: "plan")
    }
    do { binding = try await bindingPort.currentDurableBinding() } catch {
      throw RockchipAuthorizationFactError.factPortFailed(name: "binding")
    }
    guard plan.executionMode == .execute,
      plan.steps.contains(where: {
        $0.kind == .enterUpdater
          && $0.arguments["providerOperationId"] == .string("rockusb.enter-loader")
      })
    else { throw RockchipAuthorizationFactError.planMismatch(field: "enterUpdater") }
    for (field, matches) in [
      ("targetModel", expectation.targetModel == RockchipFlashProfile.targetDeviceModel),
      ("firmwareArchiveSHA256", expectation.firmwareArchiveSHA256 == plan.archiveSHA256),
      ("transport", expectation.transport == "usb"),
      (
        "toolchainFingerprint",
        expectation.toolchainFingerprint == RockchipFlashProfile.pinnedToolchainFingerprint
      ),
      (
        "providerIdentity",
        expectation.providerIdentity == RockchipRockUSBFlashProvider.providerIdentity
      ),
      ("planDigestSHA256", expectation.planDigestSHA256 == plan.planDigestSHA256),
      ("stepSetDigestSHA256", expectation.stepSetDigestSHA256 == plan.stepSetDigestSHA256),
    ] where !matches {
      throw RockchipAuthorizationFactError.planMismatch(field: field)
    }

    guard binding.sessionID == request.sessionID,
      binding.jobID == request.jobID,
      binding.targetID == request.targetID,
      binding.receipt.reference.targetID == request.targetID,
      binding.receipt.reference.revision == expectation.bindingRevision,
      binding.receipt.binding.transport == .usb,
      case .string(let serial)? =
        binding.receipt.binding.identitySnapshot.attributes["serial"],
      case .string(let topology)? =
        binding.receipt.binding.identitySnapshot.attributes["usbTopology"],
      Self.isCanonicalTopology(topology), topology == selector,
      request.targetLocationSelector == nil || request.targetLocationSelector == topology
    else { throw RockchipAuthorizationFactError.bindingMismatch(field: "binding") }
    let serialDigest = Self.sha256Hex(Data(serial.utf8))
    guard serialDigest == expectation.serialDigestSHA256 else {
      throw RockchipAuthorizationFactError.bindingMismatch(field: "serialDigestSHA256")
    }

    let liveIdentity: RockchipProductUSBIdentity
    do {
      liveIdentity = try usbProbe.singleDAYU200(
        selector: topology, stableIdentitySHA256: serialDigest)
    } catch {
      throw RockchipAuthorizationFactError.factPortFailed(name: "normalModeUSBReadback")
    }
    guard liveIdentity.isHDCNormal, liveIdentity.serial == serial,
      liveIdentity.topology == topology
    else { throw RockchipAuthorizationFactError.readbackMismatch(field: "normalModeIdentity") }

    let processExecutor = FoundationProcessExecutor()
    let toolPrepared: ProcessPreparedIdentityBoundLaunch
    do {
      toolPrepared = try processExecutor.prepareIdentityBoundLaunch(
        ProcessIdentityBoundRequest(
          process: ProcessRequest(executable: tool.executableURL, arguments: ["ld"], timeout: 5),
          expectedSHA256: RockchipDiscoveryIntegrationProfile.pinnedProduction.executableSHA256))
    } catch {
      throw RockchipAuthorizationFactError.factPortFailed(name: "rockchipExecutableIdentity")
    }
    let executableIdentity = toolPrepared.executableIdentity
    toolPrepared.close()
    guard
      executableIdentity.sha256
        == RockchipDiscoveryIntegrationProfile.pinnedProduction.executableSHA256
    else { throw RockchipAuthorizationFactError.toolMismatch(field: "executableIdentity") }

    // Open and hash the exact HDC descriptor before an authority reservation.
    // It is opened again at the durable step boundary; this early check keeps
    // a missing/drifted HDC installation at zero device dispatch and zero
    // chat-confirmation consumption.
    let hdcPrepared: ProcessPreparedIdentityBoundLaunch
    do {
      hdcPrepared = try processExecutor.prepareIdentityBoundLaunch(
        ProcessIdentityBoundRequest(
          process: ProcessRequest(
            executable: RockchipHDCIntegrationProfile.executableURL,
            arguments: ["-t", serial, "shell", "reboot", "loader"], timeout: 20),
          expectedSHA256: RockchipHDCIntegrationProfile.executableSHA256))
    } catch {
      throw RockchipAuthorizationFactError.factPortFailed(name: "hdcExecutableIdentity")
    }
    hdcPrepared.close()

    let reading = clock.now()
    guard RockchipStandingAuthorization.isCanonicalTimestamp(reading.auditTimestamp),
      let now = RockchipStandingAuthorization.parseTimestamp(reading.auditTimestamp),
      let validUntil = RockchipStandingAuthorization.parseTimestamp(expectation.validUntil),
      now < validUntil
    else { throw RockchipAuthorizationFactError.authorizationExpired }
    let targetDigest = Self.sha256Hex(
      Data(
        [
          expectation.targetModel, serialDigest,
          String(binding.receipt.reference.revision), topology,
          String(RockchipProbeEvidence.rockUSBVendorID),
          String(RockchipProbeEvidence.dayu200LoaderProductID),
        ].joined(separator: "|").utf8))
    return RockchipTrustedAuthorizationFacts(
      plan: plan, executableIdentity: executableIdentity,
      bindingReference: binding.receipt.reference,
      targetDigestSHA256: targetDigest, serialDigestSHA256: serialDigest,
      usbTopology: topology, observationSequence: 1,
      readbackDeadlineMonotonicNanoseconds: reading.monotonicNanoseconds
        + RockchipAuthorizationFactCollector.maximumReadbackLifetimeNanoseconds,
      authorizationValidUntil: expectation.validUntil,
      collectedAtTimestamp: reading.auditTimestamp)
  }

  private static func isIdentifier(_ value: String) -> Bool {
    value.range(
      of: #"^[A-Za-z0-9][A-Za-z0-9._:-]{0,127}$"#, options: .regularExpression)
      == value.startIndex..<value.endIndex
  }

  private static func isCanonicalTopology(_ value: String) -> Bool {
    !value.isEmpty && value.utf8.allSatisfy({ (48...57).contains($0) })
      && (value == "0" || value.first != "0")
  }

  private static func sha256Hex(_ data: Data) -> String {
    SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
  }
}

private struct RockchipProductPostflightPort: RockchipExecutionPostflightPort {
  let probe: RockchipProductUSBProbe

  func probe() async throws -> RockchipPostflightReceipt {
    let deadline = ContinuousClock.now.advanced(by: .seconds(120))
    while ContinuousClock.now < deadline {
      if let identity = try? probe.singleConnected() {
        let digest = SHA256.hash(data: Data(identity.serial.utf8)).map {
          String(format: "%02x", $0)
        }.joined()
        return RockchipPostflightReceipt(
          connected: true, serialDigestSHA256: digest,
          usbTopology: identity.topology)
      }
      try await Task.sleep(for: .seconds(1))
    }
    return RockchipPostflightReceipt(
      connected: false, serialDigestSHA256: String(repeating: "0", count: 64),
      usbTopology: "0")
  }
}

/// TASK-AIN-003R composition seam. Admission-time tool/device observation must
/// hand the declarative discovery gate an adapter whose profile carries the
/// same `pinnedProduction` executable hash pin that
/// `RockchipAuthorizationFacts` asserts; the default
/// `RockchipDeviceDiscoveryAdapter()` deliberately pins the read-only E0
/// discovery identity instead, which made the gate structurally unsatisfiable
/// here. Naming the assembly point keeps the actually composed profile
/// observable to contract tests; `RockchipProductionAdmissionPort.admit` is
/// its only production caller.
enum RockchipProductionDiscoveryComposition {
  static func admissionDiscoveryAdapter() -> RockchipDeviceDiscoveryAdapter {
    RockchipDeviceDiscoveryAdapter(profile: .pinnedProduction)
  }
}

private final class RockchipProductionAdmissionPort: @unchecked Sendable,
  RockchipExecutionAdmissionPort
{
  private let provenance: RockchipProductionProvenanceTokenLoader
  private let usageLedger: AuthorizationUsageLedger
  private let agentUsageLedger: AgentAuthorityUsageLedger
  private let campaignLedger: RockchipEvolutionCampaignLedger
  private let binding: RockchipProductBindingSnapshot
  private let postflightIdentities: [RockchipPostflightIdentity]
  private let tool: RockchipSelectedDiscoveryTool
  private let clock: any RockchipAdmissionClock
  private let usbProbe: RockchipProductUSBProbe

  init(
    provenance: RockchipProductionProvenanceTokenLoader,
    usageLedger: AuthorizationUsageLedger,
    agentUsageLedger: AgentAuthorityUsageLedger,
    campaignLedger: RockchipEvolutionCampaignLedger,
    binding: RockchipProductBindingSnapshot,
    postflightIdentities: [RockchipPostflightIdentity],
    tool: RockchipSelectedDiscoveryTool,
    clock: any RockchipAdmissionClock,
    usbProbe: RockchipProductUSBProbe
  ) {
    self.provenance = provenance
    self.usageLedger = usageLedger
    self.agentUsageLedger = agentUsageLedger
    self.campaignLedger = campaignLedger
    self.binding = binding
    self.postflightIdentities = postflightIdentities
    self.tool = tool
    self.clock = clock
    self.usbProbe = usbProbe
  }

  func admit(
    request: RockchipFlashExecutionRequest,
    sessionID: String,
    jobID: String,
    targetID: String
  ) async throws -> RockchipExecutionAdmission {
    let sequence: UInt64 = 1
    let serialDigest = SHA256.hash(data: Data(binding.serial.utf8)).map {
      String(format: "%02x", $0)
    }.joined()
    let liveIdentity = try usbProbe.singleDAYU200(
      selector: request.targetLocationSelector,
      stableIdentitySHA256: serialDigest)
    let bindingPort = RockchipProductBindingPort(
      sessionID: sessionID, jobID: jobID, targetID: targetID, snapshot: binding)
    let collector: any RockchipAuthorizationFactCollecting
    if liveIdentity.isLoader {
      collector = RockchipAuthorizationFactCollector(
        planPort: RockchipProductExecutePlanFactPort(),
        bindingPort: bindingPort,
        toolDevicePort: RockchipDiscoveryToolDeviceFactPort(
          sessionID: sessionID, jobID: jobID, targetID: targetID,
          observationSequence: sequence,
          adapter: RockchipProductionDiscoveryComposition.admissionDiscoveryAdapter(),
          tool: tool, clock: clock),
        prerequisitePort: RockchipProductPrerequisitePort(
          sessionID: sessionID, jobID: jobID, targetID: targetID,
          selector: request.targetLocationSelector, probe: usbProbe),
        identityReadbackPort: RockchipProductIdentityReadbackPort(
          sessionID: sessionID, jobID: jobID, targetID: targetID,
          selector: request.targetLocationSelector, observationSequence: sequence,
          probe: usbProbe, clock: clock),
        clock: clock)
    } else if liveIdentity.isHDCNormal {
      collector = RockchipProductHDCNormalAuthorizationFactCollector(
        planPort: RockchipProductExecutePlanFactPort(), bindingPort: bindingPort,
        tool: tool, selector: request.targetLocationSelector,
        usbProbe: usbProbe, clock: clock)
    } else {
      throw RockchipFlashExecutionError.admissionRejected(
        "durably bound DAYU200 is not in a registered execution mode")
    }
    let factRequest = RockchipAuthorizationFactRequest(
      archiveURL: request.archiveURL, sessionID: sessionID, jobID: jobID,
      targetID: targetID, targetLocationSelector: request.targetLocationSelector)
    switch request.authority {
    case .standingAuthorization(let authorizationID):
      guard let provenanceToken = try provenance.token(for: request.authority) else {
        throw RockchipFlashExecutionError.productionConfigurationUnavailable(
          "product GitHub provenance credential is not installed in Keychain")
      }
      let provenancePort = GitHubProtectedMainAuthorizationPort(token: provenanceToken)
      let service = AuthorizationAdmissionService(
        resolver: MaintainerMergedAuthorizationResolver(port: provenancePort),
        factCollector: collector, usageLedger: usageLedger, clock: clock)
      let token = try await service.admit(
        AuthorizationAdmissionRequest(
          authorizationID: authorizationID, facts: factRequest))
      return RockchipExecutionAdmission(
        backing: .standingAuthorization(token), plan: token.facts.plan,
        authorityReference: .standingAuthorization(token.authorizationReference),
        usageReservationID: token.usageReservation.reservationID,
        targetID: targetID, bindingRevision: token.facts.bindingReference.revision,
        targetDigestSHA256: token.facts.targetDigestSHA256,
        serialDigestSHA256: token.facts.serialDigestSHA256,
        usbTopology: token.facts.usbTopology,
        postflightIdentities: postflightIdentities,
        executableIdentity: token.facts.executableIdentity,
        evidenceClass: .production)
    case .chatConfirmation(let assertion):
      let service = ChatConfirmationAdmissionService(
        factCollector: collector, usageLedger: agentUsageLedger, clock: clock,
        bindingSerialDigestSHA256: serialDigest, bindingRevision: binding.revision)
      let token = try await service.admit(assertion: assertion, facts: factRequest)
      return RockchipExecutionAdmission(
        backing: .chatConfirmation(token), plan: token.facts.plan,
        authorityReference: .agent(token.authorizationReference),
        usageReservationID: token.usageReservation.reservationID,
        targetID: targetID, bindingRevision: token.facts.bindingReference.revision,
        targetDigestSHA256: token.facts.targetDigestSHA256,
        serialDigestSHA256: token.facts.serialDigestSHA256,
        usbTopology: token.facts.usbTopology,
        postflightIdentities: postflightIdentities,
        executableIdentity: token.facts.executableIdentity,
        evidenceClass: .production)
    case .evolutionCampaign(let permit):
      let startingMode: RockchipEvolutionStartingMode = liveIdentity.isLoader ? .loader : .hdcNormal
      let service = RockchipEvolutionCampaignAdmissionService(
        factCollector: collector, usageLedger: agentUsageLedger,
        campaignLedger: campaignLedger, clock: clock,
        bindingSerialDigestSHA256: serialDigest, bindingRevision: binding.revision)
      let token = try await service.admit(
        permit: permit, facts: factRequest, sessionID: sessionID,
        startingMode: startingMode)
      return RockchipExecutionAdmission(
        backing: .evolutionCampaign(token), plan: token.facts.plan,
        authorityReference: .agent(token.authorizationReference),
        usageReservationID: token.usageReservation.reservationID,
        targetID: targetID, bindingRevision: token.facts.bindingReference.revision,
        targetDigestSHA256: token.facts.targetDigestSHA256,
        serialDigestSHA256: token.facts.serialDigestSHA256,
        usbTopology: token.facts.usbTopology,
        postflightIdentities: postflightIdentities,
        executableIdentity: token.facts.executableIdentity,
        evidenceClass: .production)
    }
  }

  func authorizeAndConsume(_ admission: RockchipExecutionAdmission) async throws {
    switch admission.backing {
    case .standingAuthorization(let token):
      let decision = await RockchipFlashAuthorizationGate().authorizeUnattended(
        admission: token, plan: admission.plan, monitor: RockchipFlashDispatchMonitor())
      guard case .authorizedAgentAdmissionAccepted(let reservationID) = decision.outcome,
        reservationID == admission.usageReservationID,
        decision.authorizationRef == admission.legacyAuthorizationReference,
        decision.dispatchSnapshot.totalDispatchCount == 0
      else {
        throw RockchipFlashExecutionError.authorizationGateRejected(decision.jobMarker)
      }
      let consumed = try token.consume(at: clock.now())
      guard consumed.authorizationReference == admission.legacyAuthorizationReference,
        consumed.usageReservation.reservationID == admission.usageReservationID,
        consumed.facts.executableIdentity == admission.executableIdentity
      else { throw RockchipFlashExecutionError.authorizationGateRejected("consume correlation") }
    case .chatConfirmation(let token):
      let consumed = try token.consume(at: clock.now())
      guard consumed.authorizationReference == admission.agentAuthorizationReference,
        consumed.usageReservation.reservationID == admission.usageReservationID,
        consumed.facts.executableIdentity == admission.executableIdentity
      else { throw RockchipFlashExecutionError.authorizationGateRejected("consume correlation") }
    case .evolutionCampaign(let token):
      let consumed = try token.consume(at: clock.now())
      guard consumed.authorizationReference == admission.agentAuthorizationReference,
        consumed.usageReservation.reservationID == admission.usageReservationID,
        consumed.facts.executableIdentity == admission.executableIdentity
      else { throw RockchipFlashExecutionError.authorizationGateRejected("consume correlation") }
    case .contractFake:
      throw RockchipFlashExecutionError.authorizationGateRejected("production token missing")
    }
  }

  func closeUsage(
    admission: RockchipExecutionAdmission,
    status: AuthorizationUsageTerminalStatus,
    destructiveIntentEventIDs: [String]
  ) throws {
    switch admission.authorityReference {
    case .standingAuthorization:
      let terminal = try AuthorizationUsageTerminal(
        status: status, closedAt: clock.now().auditTimestamp,
        destructiveIntentEventIDs: destructiveIntentEventIDs)
      _ = try usageLedger.close(
        reservationID: admission.usageReservationID, terminal: terminal)
    case .agent:
      let terminal = try AgentAuthorityUsageTerminal(
        status: status, closedAt: clock.now().auditTimestamp,
        externalIntentEventIDs: destructiveIntentEventIDs)
      _ = try agentUsageLedger.close(
        reservationID: admission.usageReservationID, terminal: terminal)
      if case .evolutionCampaign(let token) = admission.backing {
        let disposition: RockchipEvolutionAttemptDisposition
        if status == .succeeded {
          disposition = .succeeded
        } else if status == .outcomeUnknown {
          disposition = .outcomeUnknown
        } else if destructiveIntentEventIDs.isEmpty {
          disposition = .safeToReflash
        } else {
          disposition = .unsafePartial
        }
        _ = try campaignLedger.closeAttempt(
          campaignID: token.campaignID, ordinal: token.ordinal,
          jobID: token.jobID, sessionID: token.sessionID,
          disposition: disposition,
          destructiveIntentEventIDs: destructiveIntentEventIDs,
          at: clock.now().auditTimestamp)
      }
    }
  }
}

// MARK: - Fresh protected-main GitHub provenance

private struct GitHubProtectedMainAuthorizationPort: AuthorizationProvenancePort, Sendable {
  let token: String

  func fetchFreshSnapshot(authorizationID: String, registryPath: String) async throws
    -> AuthorizationProvenanceSnapshot
  {
    let branch: GitHubBranch = try await get("/repos/ArkDeck/ArkDeck/branches/main")
    let authorization = try await content(path: registryPath, ref: "main")
    let pullRequestNumber = try authorizationPullRequestNumber(authorization.data)
    let pullRequest: GitHubPullRequest = try await get(
      "/repos/ArkDeck/ArkDeck/pulls/\(pullRequestNumber)")
    guard let mergeCommitOID = pullRequest.mergeCommitSHA else {
      throw AuthorizationProvenanceError.pullRequestNotMerged
    }
    async let headContent = content(path: registryPath, ref: pullRequest.head.sha)
    async let mergeContent = content(path: registryPath, ref: mergeCommitOID)
    async let reviews: [GitHubReview] = get(
      "/repos/ArkDeck/ArkDeck/pulls/\(pullRequestNumber)/reviews?per_page=100")
    async let codeOwners = content(path: ".github/CODEOWNERS", ref: "main")
    async let comparison: GitHubComparison = get(
      "/repos/ArkDeck/ArkDeck/compare/\(mergeCommitOID)...main")
    let (reviewed, merged, reviewRows, owners, ancestry) = try await (
      headContent, mergeContent, reviews, codeOwners, comparison
    )
    return AuthorizationProvenanceSnapshot(
      repositoryFullName: "ArkDeck/ArkDeck", branchName: "main",
      branchProtected: branch.protected, mainCommitOID: branch.commit.sha,
      registryPath: registryPath, authorizationBytes: authorization.data,
      authorizationBlobOID: authorization.sha,
      reviewedHeadBlobOID: reviewed.sha, mergeCommitBlobOID: merged.sha,
      pullRequestNumber: pullRequest.number, pullRequestMerged: pullRequest.merged,
      pullRequestBaseBranch: pullRequest.base.ref,
      pullRequestAuthorLogin: pullRequest.user.login,
      pullRequestHeadOID: pullRequest.head.sha, mergeCommitOID: mergeCommitOID,
      mergeCommitIsAncestorOfMain: ["ahead", "identical"].contains(ancestry.status),
      mergedByLogin: pullRequest.mergedBy?.login ?? "",
      reviews: reviewRows.map {
        AuthorizationApprovalReview(
          reviewerLogin: $0.user.login,
          state: Self.reviewState($0.state),
          commitOID: $0.commitID ?? "")
      },
      codeOwnersBytes: owners.data, codeOwnersBlobOID: owners.sha)
  }

  private func content(path: String, ref: String) async throws -> (data: Data, sha: String) {
    let encodedRef = ref.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) ?? ref
    let response: GitHubContent = try await get(
      "/repos/ArkDeck/ArkDeck/contents/\(path)?ref=\(encodedRef)")
    guard response.encoding == "base64",
      let data = Data(base64Encoded: response.content.replacingOccurrences(of: "\n", with: ""))
    else { throw AuthorizationProvenanceError.sourceUnavailable }
    return (data, response.sha)
  }

  private func get<Value: Decodable>(_ path: String) async throws -> Value {
    guard let url = URL(string: "https://api.github.com\(path)") else {
      throw AuthorizationProvenanceError.sourceUnavailable
    }
    var request = URLRequest(url: url)
    request.httpMethod = "GET"
    request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
    request.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept")
    request.setValue("2022-11-28", forHTTPHeaderField: "X-GitHub-Api-Version")
    request.setValue("ArkDeck/1.0", forHTTPHeaderField: "User-Agent")
    let (data, response) = try await URLSession.shared.data(for: request)
    guard let http = response as? HTTPURLResponse, (200..<300).contains(http.statusCode) else {
      throw AuthorizationProvenanceError.sourceUnavailable
    }
    return try JSONDecoder().decode(Value.self, from: data)
  }

  private func authorizationPullRequestNumber(_ data: Data) throws -> Int {
    guard let object = try JSONSerialization.jsonObject(with: data) as? [String: Any],
      let carrier = object["carrier"] as? String
    else { throw AuthorizationProvenanceError.sourceUnavailable }
    let expression = try NSRegularExpression(pattern: #"PR #([0-9]+)"#)
    let range = NSRange(carrier.startIndex..<carrier.endIndex, in: carrier)
    guard let match = expression.firstMatch(in: carrier, range: range),
      let numberRange = Range(match.range(at: 1), in: carrier),
      let number = Int(carrier[numberRange]), number > 0
    else { throw AuthorizationProvenanceError.sourceUnavailable }
    return number
  }

  private static func reviewState(_ value: String) -> AuthorizationReviewState {
    switch value.uppercased() {
    case "APPROVED": .approved
    case "CHANGES_REQUESTED": .changesRequested
    case "DISMISSED": .dismissed
    default: .commented
    }
  }
}

private struct GitHubBranch: Decodable {
  let protected: Bool
  let commit: GitHubCommit
}

private struct GitHubCommit: Decodable { let sha: String }

private struct GitHubContent: Decodable {
  let content: String
  let encoding: String
  let sha: String
}

private struct GitHubUser: Decodable { let login: String }

private struct GitHubPullRef: Decodable {
  let ref: String
  let sha: String
}

private struct GitHubPullRequest: Decodable {
  let number: Int
  let merged: Bool
  let mergeCommitSHA: String?
  let base: GitHubPullRef
  let head: GitHubPullRef
  let user: GitHubUser
  let mergedBy: GitHubUser?

  enum CodingKeys: String, CodingKey {
    case number, merged, base, head, user
    case mergeCommitSHA = "merge_commit_sha"
    case mergedBy = "merged_by"
  }
}

private struct GitHubReview: Decodable {
  let user: GitHubUser
  let state: String
  let commitID: String?

  enum CodingKeys: String, CodingKey {
    case user, state
    case commitID = "commit_id"
  }
}

private struct GitHubComparison: Decodable { let status: String }
