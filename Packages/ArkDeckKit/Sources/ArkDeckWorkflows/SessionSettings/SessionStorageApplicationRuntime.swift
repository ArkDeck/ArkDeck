import ArkDeckStorage
import Foundation

public enum SessionRetentionRuntimeError: Error, Equatable, Sendable {
  case retentionBlocked
  case catalogGenerationUnavailable
  case stalePreview
  case confirmationRequired
}

public struct SessionRetentionPreview: Equatable, Sendable {
  public let settings: SessionSettingsSnapshot
  public let catalogGeneration: UInt64?
  public let rootIdentity: SessionCatalogRootIdentity
  public let volumeIdentity: VolumeIdentity
  public let currentBytes: UInt64
  public let projectedBytes: UInt64
  public let safetyTargetBytes: UInt64
  public let pinnedBytes: UInt64
  public let unknownPressure: Bool
  public let unknownSessionIDs: [String]
  public let deletionSessionIDs: [String]
  public let entries: [SessionRetentionCatalogEntry]
  public let blocksNewHeavyWriters: Bool

  fileprivate let plan: SessionRetentionPlan
}

public struct SessionCleanupConfirmation: Equatable, Sendable {
  public let confirmationID: UUID
  public let settingsGeneration: UInt64
  public let catalogGeneration: UInt64
  public let standardizedRootPath: String
  public let rootIdentity: SessionCatalogRootIdentity
  public let volumeIdentity: VolumeIdentity
  public let deletionSessionIDs: [String]
  public let projectedBytes: UInt64

  fileprivate init(preview: SessionRetentionPreview, catalogGeneration: UInt64) {
    confirmationID = UUID()
    settingsGeneration = preview.settings.generation
    self.catalogGeneration = catalogGeneration
    standardizedRootPath = preview.settings.sessionsRoot.path
    rootIdentity = preview.rootIdentity
    volumeIdentity = preview.volumeIdentity
    deletionSessionIDs = preview.deletionSessionIDs
    projectedBytes = preview.projectedBytes
  }

  fileprivate func matches(_ preview: SessionRetentionPreview) -> Bool {
    settingsGeneration == preview.settings.generation
      && catalogGeneration == preview.catalogGeneration
      && standardizedRootPath == preview.settings.sessionsRoot.path
      && rootIdentity == preview.rootIdentity
      && volumeIdentity == preview.volumeIdentity
      && deletionSessionIDs == preview.deletionSessionIDs
      && projectedBytes == preview.projectedBytes
  }
}

public struct SessionRetentionApplyResult: Equatable, Sendable {
  public let previewAfterRescan: SessionRetentionPreview
}

public struct SessionHeavyWriterAdmission: Equatable, Sendable {
  public let catalog: SessionRetentionCatalogSnapshot
  fileprivate let configurationToken: StorageConfigurationToken

  public var volumeIdentity: VolumeIdentity { catalog.volumeIdentity }
  public var rootIdentity: SessionCatalogRootIdentity { catalog.rootIdentity }
  public var catalogGeneration: UInt64? { catalog.catalogGeneration }
}

public struct SessionStorageExecutionContext: Sendable {
  public let settings: SessionSettingsSnapshot
  public let rootLease: SessionRootAccessLease
  public let sessionStore: SessionStore
  public let coordinator: HostStorageCoordinator
  public let catalog: SessionRetentionCatalog

  private let settingsStore: SessionSettingsStore
  private let retentionController: SessionRetentionController

  fileprivate init(
    access: SessionRootAccessContext,
    settingsStore: SessionSettingsStore,
    coordinator: HostStorageCoordinator,
    catalog: SessionRetentionCatalog,
    retentionController: SessionRetentionController
  ) throws {
    settings = access.settings
    rootLease = access.lease
    sessionStore = try SessionStore(sessionsRoot: access.lease.url)
    self.settingsStore = settingsStore
    self.coordinator = coordinator
    self.catalog = catalog
    self.retentionController = retentionController
  }

  public func requireCurrentSettings() throws {
    try settingsStore.requireCurrent(settings)
  }

  @discardableResult
  public func prepareHeavyWriterAdmission() async throws
    -> SessionHeavyWriterAdmission
  {
    try requireCurrentSettings()
    let snapshot = try catalog.scan(
      retentionDays: settings.retentionDays,
      policyGeneration: settings.generation)
    let configurationToken = settingsStore.configurationEpoch.snapshot()
    let active = await coordinator.activeSessions(on: snapshot.volumeIdentity)
    try requireCurrentSettings()
    try settingsStore.configurationEpoch.performIfCurrent(configurationToken) {}
    let planning = try makeRetentionPlanning(
      catalog: snapshot, settings: settings, active: active,
      controller: retentionController)
    let updated = await coordinator.setRetentionAdmission(
      blocked: planning.mustBlockBeforeCleanup, on: snapshot.volumeIdentity,
      configurationToken: configurationToken)
    guard updated else { throw SessionRetentionRuntimeError.stalePreview }
    guard !planning.mustBlockBeforeCleanup else {
      throw SessionRetentionRuntimeError.retentionBlocked
    }
    return SessionHeavyWriterAdmission(
      catalog: snapshot, configurationToken: configurationToken)
  }

  public func admitHeavyWriter(
    _ request: StorageClaimRequest,
    snapshot: HostStorageSnapshot,
    admission: SessionHeavyWriterAdmission
  ) async -> StorageAdmission {
    guard request.volumeIdentity == admission.volumeIdentity,
      snapshot.volumeIdentity == admission.volumeIdentity
    else { return .queued(.waitingForStorage) }
    do {
      try catalog.requireCurrentRoot(
        identity: admission.rootIdentity,
        volumeIdentity: admission.volumeIdentity)
    } catch {
      return .queued(.waitingForStorage)
    }
    return await coordinator.admit(
      request, snapshot: snapshot,
      configurationToken: admission.configurationToken)
  }

  public func createSession(
    sessionID: String,
    jobID: String,
    createdAt: Date,
    claim: StorageClaim,
    admission: SessionHeavyWriterAdmission
  ) async throws -> SessionLayout {
    do {
      try catalog.requireCurrentRoot(
        identity: admission.rootIdentity,
        volumeIdentity: admission.volumeIdentity)
      return try sessionStore.createSession(
        sessionID: sessionID, jobID: jobID, createdAt: createdAt, claim: claim)
    } catch {
      await coordinator.cancelUnboundAdmission(claim)
      throw error
    }
  }

  public func registerFinalizedSession(_ sessionRoot: URL) async {
    do {
      try requireCurrentSettings()
      try catalog.registerFinalizedSession(
        sessionRoot: sessionRoot, retentionDays: settings.retentionDays,
        policyGeneration: settings.generation)
      let snapshot = try catalog.scan(
        retentionDays: settings.retentionDays,
        policyGeneration: settings.generation)
      let configurationToken = settingsStore.configurationEpoch.snapshot()
      let active = await coordinator.activeSessions(on: snapshot.volumeIdentity)
      try requireCurrentSettings()
      try settingsStore.configurationEpoch.performIfCurrent(configurationToken) {}
      let planning = try makeRetentionPlanning(
        catalog: snapshot, settings: settings, active: active,
        controller: retentionController)
      _ = await coordinator.setRetentionAdmission(
        blocked: planning.mustBlockBeforeCleanup, on: snapshot.volumeIdentity,
        configurationToken: configurationToken)
    } catch {
      if let snapshot = try? catalog.scan(
        retentionDays: settings.retentionDays,
        policyGeneration: settings.generation)
      {
        await coordinator.setRetentionAdmission(
          blocked: true, on: snapshot.volumeIdentity)
      }
    }
  }
}

public actor SessionStorageApplicationRuntime {
  public nonisolated let settingsStore: SessionSettingsStore
  public nonisolated let coordinator: HostStorageCoordinator

  private nonisolated let volumeIdentityResolver: any VolumeIdentityResolving
  private nonisolated let catalogFaultInjector: SessionRetentionCatalogFaultInjector
  private nonisolated let retentionController: SessionRetentionController
  private var confirmation: SessionCleanupConfirmation?
  private var pendingRescanVolumes: Set<VolumeIdentity> = []

  public static let production = SessionStorageApplicationRuntime()

  public init(
    settingsStore: SessionSettingsStore? = nil,
    coordinator: HostStorageCoordinator? = nil,
    volumeIdentityResolver: any VolumeIdentityResolving = SystemVolumeIdentityResolver(),
    catalogFaultInjector: SessionRetentionCatalogFaultInjector = .none,
    retentionController: SessionRetentionController = SessionRetentionController()
  ) {
    let configurationEpoch =
      settingsStore?.configurationEpoch ?? StorageConfigurationEpoch()
    self.settingsStore =
      settingsStore ?? SessionSettingsStore(configurationEpoch: configurationEpoch)
    self.coordinator =
      coordinator ?? HostStorageCoordinator(configurationEpoch: configurationEpoch)
    self.volumeIdentityResolver = volumeIdentityResolver
    self.catalogFaultInjector = catalogFaultInjector
    self.retentionController = retentionController
  }

  public nonisolated func makeExecutionContext() throws -> SessionStorageExecutionContext {
    let settings = try settingsStore.load()
    let access = try settingsStore.acquireRoot(for: settings)
    let catalog = try SessionRetentionCatalog(
      sessionsRoot: access.lease.url,
      volumeIdentityResolver: volumeIdentityResolver,
      faultInjector: catalogFaultInjector,
      configurationEpoch: settingsStore.configurationEpoch)
    return try SessionStorageExecutionContext(
      access: access, settingsStore: settingsStore, coordinator: coordinator,
      catalog: catalog, retentionController: retentionController)
  }

  public func refresh() async throws -> SessionRetentionPreview {
    let context = try makeExecutionContext()
    return try await refresh(context)
  }

  public func confirm(
    _ preview: SessionRetentionPreview
  ) async throws -> SessionCleanupConfirmation {
    let current = try await refresh()
    guard current == preview else { throw SessionRetentionRuntimeError.stalePreview }
    guard let generation = current.catalogGeneration else {
      throw SessionRetentionRuntimeError.catalogGenerationUnavailable
    }
    let confirmation = SessionCleanupConfirmation(
      preview: current, catalogGeneration: generation)
    self.confirmation = confirmation
    return confirmation
  }

  public func cancelCleanup() {
    confirmation = nil
  }

  public func apply(
    _ supplied: SessionCleanupConfirmation
  ) async throws -> SessionRetentionApplyResult {
    guard confirmation == supplied else {
      throw SessionRetentionRuntimeError.confirmationRequired
    }
    confirmation = nil
    pendingRescanVolumes.insert(supplied.volumeIdentity)
    await coordinator.requireConservativeRetentionBlock(on: supplied.volumeIdentity)
    let context = try makeExecutionContext()
    let currentState = try await scanState(context)
    let current = preview(
      context: context, state: currentState,
      blocksNewHeavyWriters: currentState.planning.mustBlockBeforeCleanup)
    guard supplied.matches(current) else {
      throw SessionRetentionRuntimeError.stalePreview
    }

    do {
      try retentionController.apply(
        current.plan, sessions: currentState.catalog.sessions,
        sessionsRoot: context.rootLease.url)
    } catch {
      _ = try? context.catalog.scan(
        retentionDays: context.settings.retentionDays,
        policyGeneration: context.settings.generation)
      await coordinator.setRetentionAdmission(blocked: true, on: current.volumeIdentity)
      throw error
    }

    do {
      let afterState = try await scanState(context)
      pendingRescanVolumes.remove(current.volumeIdentity)
      let shouldBlock = afterState.planning.mustBlockBeforeCleanup
      let updated = await coordinator.setRetentionAdmission(
        blocked: shouldBlock, on: afterState.catalog.volumeIdentity,
        configurationToken: afterState.configurationToken)
      let cleared = await coordinator.clearConservativeRetentionBlockAfterSuccessfulRescan(
        on: afterState.catalog.volumeIdentity,
        configurationToken: afterState.configurationToken)
      guard cleared, updated else {
        throw SessionRetentionRuntimeError.stalePreview
      }
      let after = preview(
        context: context, state: afterState,
        blocksNewHeavyWriters: shouldBlock)
      return SessionRetentionApplyResult(previewAfterRescan: after)
    } catch {
      await coordinator.setRetentionAdmission(blocked: true, on: current.volumeIdentity)
      throw error
    }
  }

  public func updatePin(
    sessionID: String,
    isPinned: Bool,
    expectedCatalogGeneration: UInt64
  ) async throws -> SessionRetentionPreview {
    let context = try makeExecutionContext()
    let current = try await refresh(context)
    guard current.catalogGeneration == expectedCatalogGeneration,
      current.entries.contains(where: { $0.sessionID == sessionID })
    else { throw SessionRetentionRuntimeError.stalePreview }
    _ = try context.catalog.updatePin(
      sessionID: sessionID, isPinned: isPinned,
      expectedGeneration: expectedCatalogGeneration)
    confirmation = nil
    return try await refresh(context)
  }

  private func refresh(
    _ context: SessionStorageExecutionContext
  ) async throws -> SessionRetentionPreview {
    let state = try await scanState(context)
    let mustBlock =
      state.planning.mustBlockBeforeCleanup
      || pendingRescanVolumes.contains(state.catalog.volumeIdentity)
    let updated = await coordinator.setRetentionAdmission(
      blocked: mustBlock, on: state.catalog.volumeIdentity,
      configurationToken: state.configurationToken)
    guard updated else { throw SessionRetentionRuntimeError.stalePreview }
    return preview(
      context: context, state: state, blocksNewHeavyWriters: mustBlock)
  }

  private func scanState(
    _ context: SessionStorageExecutionContext
  ) async throws -> RuntimeScanState {
    try context.requireCurrentSettings()
    let snapshot = try context.catalog.scan(
      retentionDays: context.settings.retentionDays,
      policyGeneration: context.settings.generation)
    let configurationToken = settingsStore.configurationEpoch.snapshot()
    let active = await coordinator.activeSessions(on: snapshot.volumeIdentity)
    try context.requireCurrentSettings()
    try settingsStore.configurationEpoch.performIfCurrent(configurationToken) {}
    let planning = try makeRetentionPlanning(
      catalog: snapshot, settings: context.settings, active: active,
      controller: retentionController)
    return RuntimeScanState(
      catalog: snapshot, planning: planning,
      configurationToken: configurationToken)
  }

  private func preview(
    context: SessionStorageExecutionContext,
    state: RuntimeScanState,
    blocksNewHeavyWriters: Bool
  ) -> SessionRetentionPreview {
    return SessionRetentionPreview(
      settings: context.settings,
      catalogGeneration: state.catalog.catalogGeneration,
      rootIdentity: state.catalog.rootIdentity,
      volumeIdentity: state.catalog.volumeIdentity,
      currentBytes: state.catalog.currentBytes,
      projectedBytes: state.planning.plan.projectedBytes,
      safetyTargetBytes: state.planning.plan.safetyTargetBytes,
      pinnedBytes: state.catalog.pinnedBytes,
      unknownPressure: state.catalog.unknownPressure,
      unknownSessionIDs: state.catalog.unknownSessionIDs,
      deletionSessionIDs: state.planning.plan.deletionSessionIDs,
      entries: state.catalog.entries,
      blocksNewHeavyWriters: blocksNewHeavyWriters,
      plan: state.planning.plan)
  }
}

private struct RuntimeScanState {
  let catalog: SessionRetentionCatalogSnapshot
  let planning: RetentionPlanningState
  let configurationToken: StorageConfigurationToken
}

private struct RetentionPlanningState {
  let plan: SessionRetentionPlan
  let mustBlockBeforeCleanup: Bool
}

private func makeRetentionPlanning(
  catalog: SessionRetentionCatalogSnapshot,
  settings: SessionSettingsSnapshot,
  active: [ActiveStorageSessionSnapshot],
  controller: SessionRetentionController
) throws -> RetentionPlanningState {
  let activeRoots = Set(active.map { $0.sessionRoot.standardizedFileURL.path })
  var planningSessions = try catalog.sessions.map { session in
    guard activeRoots.contains(session.root.standardizedFileURL.path) else { return session }
    return try RetainedSession(
      sessionID: session.sessionID, root: session.root,
      sizeBytes: session.sizeBytes, completedAt: session.completedAt,
      expiresAt: session.expiresAt, isPinned: true)
  }
  let candidateBytes = catalog.sessions.reduce(UInt64(0)) {
    let sum = $0.addingReportingOverflow($1.sizeBytes)
    return sum.overflow ? UInt64.max : sum.partialValue
  }
  if catalog.currentBytes > candidateBytes {
    planningSessions.append(
      try RetainedSession(
        sessionID: "arkdeck-preserved-unknown",
        root: settings.sessionsRoot,
        sizeBytes: catalog.currentBytes - candidateBytes,
        completedAt: Date.distantPast, expiresAt: nil, isPinned: true))
  }
  let plan = controller.plan(
    sessions: planningSessions,
    totalQuotaBytes: settings.totalQuotaBytes,
    safetyMarginBytes: settings.safetyMarginBytes,
    now: Date())
  let currentPressure = catalog.currentBytes > plan.safetyTargetBytes
  return RetentionPlanningState(
    plan: plan,
    mustBlockBeforeCleanup:
      currentPressure || catalog.unknownPressure || !active.isEmpty)
}
