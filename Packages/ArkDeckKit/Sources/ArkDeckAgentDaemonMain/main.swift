// arkdeck-agentd executable entry point (CHG-2026-047, T07).
//
// Production composition root: state under the user's Application Support,
// production providers registered, zero network. `--state-dir` exists for
// tests and never widens permissions.

import ArkDeckAgentComposition
import ArkDeckAgentDaemon
import ArkDeckBootstrap
import ArkDeckCore
import ArkDeckLaunchAgent
import ArkDeckRuntime
import ArkDeckStorage
import ArkDeckTraceAdapter
import ArkDeckWorkflows
import Darwin
import Foundation

private final class BootstrapToolSelectionRegistryAdapter:
  RuntimeToolSelectionRegistryControlling, @unchecked Sendable
{
  let registry: BootstrapToolRegistry

  init(registry: BootstrapToolRegistry) { self.registry = registry }

  func candidate(
    newToolRef: String, expectedActiveGeneration: UInt64,
    pendingActionID: String?
  ) throws -> RuntimeToolSelectionRegistryCandidate {
    let value = try registry.selectionCandidate(
      newToolRef: newToolRef,
      expectedActiveGeneration: String(expectedActiveGeneration),
      pendingActionID: pendingActionID)
    return RuntimeToolSelectionRegistryCandidate(
      activeTool: try RuntimeToolSelectionToolFacts(
        registryProjection: value.selection.activeTool),
      newTool: try RuntimeToolSelectionToolFacts(
        registryProjection: value.newTool),
      activeGeneration: value.selection.activeGeneration)
  }

  func prepare(
    actionID: String, newToolRef: String, expectedActiveGeneration: UInt64
  ) throws -> ResolvedExecutable {
    _ = try registry.prepareSelection(
      actionID: actionID, newToolRef: newToolRef,
      expectedActiveGeneration: String(expectedActiveGeneration))
    guard let startup = try registry.startupSelection(),
      startup.pendingActionID == actionID,
      startup.toolRef == newToolRef,
      startup.activeGeneration == expectedActiveGeneration
    else {
      throw HDCControlValue.failure(
        "recordUnreadable", "prepared tool selection lost its exact durable executable")
    }
    return try Self.resolved(startup.resolved)
  }

  func failPending(actionID: String, reasonCode: String) throws {
    _ = try registry.failPendingSelection(
      actionID: actionID, reasonCode: reasonCode)
  }

  func outcome(actionID: String) throws -> RuntimeToolSelectionDurableOutcome {
    switch try registry.selectionOutcome(actionID: actionID) {
    case .pending: return .pending
    case .succeeded(let reference, let generation):
      return .succeeded(activeToolRef: reference, activeGeneration: generation)
    case .failed(let reference, let generation, let reason):
      return .failed(
        activeToolRef: reference, activeGeneration: generation,
        reasonCode: reason)
    case .absent: return .absent
    }
  }

  func acknowledge(actionID: String) throws {
    try registry.acknowledgeSelectionOutcome(actionID: actionID)
  }

  static func resolved(
    _ value: BootstrapToolRegistry.ResolvedHDC
  ) throws -> ResolvedExecutable {
    let parent = value.executableURL.deletingLastPathComponent()
    let resources = try value.dependencies.map { dependency in
      guard let byteCount = Int(exactly: dependency.byteCount) else {
        throw HDCControlValue.failure(
          "recordUnreadable", "registered HDC dependency size is not representable")
      }
      return ResolvedExecutableResource(
        path: parent.appending(path: dependency.name).path,
        sha256: dependency.sha256, byteCount: byteCount,
        requireExecutable: false)
    }
    return ResolvedExecutable(
      path: value.executableURL.path,
      sha256: value.executableSHA256,
      verifiedResources: resources,
      canonicalNamespaceRoot: parent.path)
  }
}

/// Closed host-only HiLog analyzer mode. Never enters daemon startup, touches
/// transport, or prints an input path/body in an error.
if CommandLine.arguments.dropFirst().first == "--summarize-hilog" {
  let values = Array(CommandLine.arguments.dropFirst(2))
  guard values.count == 1, values[0].hasPrefix("/") else {
    FileHandle.standardError.write(Data("analyzer.hilogInvalidArguments\n".utf8))
    exit(64)
  }
  do {
    FileHandle.standardOutput.write(try HilogSummaryDerivedAnalyzer.analyzeFile(at: values[0]))
    exit(0)
  } catch {
    FileHandle.standardError.write(Data("analyzer.hilogReadFailed\n".utf8))
    exit(1)
  }
}

/// The analyzer is the same signed executable in a closed, one-shot mode.
/// It accepts exactly one engine-resolved artifact path and writes exactly
/// one deterministic JSON document to stdout; normal daemon startup is never
/// entered on this path.
if CommandLine.arguments.dropFirst().first == "--analyze-crash-ledger" {
  let values = Array(CommandLine.arguments.dropFirst(2))
  guard values.count == 1, values[0].hasPrefix("/") else {
    FileHandle.standardError.write(
      Data("--analyze-crash-ledger requires one absolute artifact path\n".utf8))
    exit(64)
  }
  do {
    let source = try Data(contentsOf: URL(filePath: values[0]))
    FileHandle.standardOutput.write(try HarnessCrashLedgerDerivedAnalyzer.analyze(source))
    exit(0)
  } catch {
    FileHandle.standardError.write(Data("crash-ledger analysis failed: \(error)\n".utf8))
    exit(1)
  }
}

/// One-shot ArkTS crash symbolization, the same shape as the crash-ledger mode
/// above: two engine-resolved absolute paths in, one deterministic report out,
/// and normal daemon startup never entered.
///
/// The source map path arrives through the symbol preset's fixed arguments and
/// the dump path is appended by the operation, which is why the order is
/// map-then-dump rather than the other way round.
if CommandLine.arguments.dropFirst().first == "--symbolize-crash" {
  let values = Array(CommandLine.arguments.dropFirst(2))
  guard values.count == 2, values.allSatisfy({ $0.hasPrefix("/") }) else {
    FileHandle.standardError.write(
      Data("--symbolize-crash requires an absolute source map path and dump path\n".utf8))
    exit(64)
  }
  do {
    let map = try Data(contentsOf: URL(filePath: values[0]))
    let dump = try Data(contentsOf: URL(filePath: values[1]))
    let text = String(decoding: dump, as: UTF8.self)
    FileHandle.standardOutput.write(
      Data(try JSCrashSymbolizer.symbolize(sourceMapData: map, dumpText: text).utf8))
    exit(0)
  } catch {
    FileHandle.standardError.write(Data("crash symbolization failed: \(error)\n".utf8))
    exit(1)
  }
}

func utcNow() -> String {
  ISO8601Timestamps.string(from: Date())
}

/// The same instant with its fractional part kept.
///
/// Durable records stay on the plain form, which everything downstream parses
/// and compares. This one exists for facts whose whole point is where inside a
/// second something happened - a screenshot's shutter, measured against a rule
/// written in milliseconds.
func utcNowPrecise() -> String {
  ISO8601Timestamps.string(from: Date(), includingFractionalSeconds: true)
}

let defaultStateDirectory = ArkDeckAgentFilesystemLayout.defaultStateDirectory()
var stateDirectory = defaultStateDirectory

var arguments = CommandLine.arguments.dropFirst()
while let argument = arguments.first {
  arguments = arguments.dropFirst()
  switch argument {
  case "--state-dir":
    guard let value = arguments.first else {
      FileHandle.standardError.write(Data("--state-dir requires a path\n".utf8))
      exit(64)
    }
    stateDirectory = URL(filePath: value, directoryHint: .isDirectory)
    arguments = arguments.dropFirst()
  case "--help":
    print("usage: arkdeck-agentd [--state-dir <path>]")
    exit(0)
  default:
    FileHandle.standardError.write(Data("unknown argument \(argument)\n".utf8))
    exit(64)
  }
}

/// Private execution facts resolved from the adopted target record. Model,
/// firmware and transport are intentionally absent here: the same operation
/// must establish them through its durable typed preflight outcomes.
struct TargetStoreFactsPort: HDCObservationFactsPort {
  let targetStore: RuntimeTargetStore
  let executablePath: String
  let executableSHA256: String

  func currentFacts(targetID: String) async throws -> ProviderFacts {
    guard let route = try targetStore.hdcExecutionRoute(targetID: targetID) else {
      throw DeviceProviderError.factsUnavailable("target \(targetID) has not been adopted")
    }
    // The HDC facts identity is derived from the connect key — the same
    // derivation `confirm-evidence-target` verifies. The record's
    // `stablePhysicalIdentitySHA256` is NOT usable here: after a Loader-mode
    // flash the binding lineage advances it to the Loader-mode (campaign)
    // identity while the connect key deliberately stays normal-mode, and
    // publishing the campaign identity on the HDC facts made every
    // device-bound operation fail `targetIdentityMismatch` from binding
    // revision 2 onward. The Rockchip provider keeps publishing the store
    // identity; each provider's identity closes over its own address surface.
    // A proven post-Flash alias may supply that HDC address without changing
    // the canonical target identity or revision.
    return ProviderFacts(
      providerID: "hdc",
      toolVersion: route.toolVersion,
      toolSHA256: executableSHA256,
      serverFacts: [:],
      targetID: route.targetID,
      bindingRevision: route.bindingRevision,
      deviceIdentitySHA256: HDCObservationProviderAdapter.stableIdentitySHA256(
        connectKey: route.connectKey),
      executionConnectKey: route.connectKey,
      deviceMode: "hdc",
      buildFingerprint: nil,
      profileID: "openharmony-standard@1",
      collectedAtUTC: utcNow())
  }
}

struct RefusingDispatcher: RuntimeProcessDispatching {
  // Used only when no HDC executable is configured: the daemon still
  // accepts, journals and recovers jobs, but refuses dispatch loudly
  // rather than pretending to run anything.
  let reason: String

  func unavailableReason(providerID: String) -> String? { reason }

  func dispatch(_ plan: TypedProcessPlan) async throws -> ProviderProcessReceipt {
    throw RuntimeDispatchFailure.failed(reason)
  }
}

/// Product bridge from ArkTrace's path-fixed maintenance actor into the
/// Runtime control resource. The bridge only maps value types; it cannot add a
/// path, bypass a lease or select an original trace Artifact.
struct ProductTraceCacheMaintenance: RuntimeTraceCacheMaintaining {
  let service: ArkDeckTraceCacheMaintenanceService

  func inventory() async throws -> RuntimeTraceCacheInventory {
    let value = try await service.inventory()
    return RuntimeTraceCacheInventory(
      entryCount: value.entryCount,
      totalByteCount: value.totalByteCount,
      activeEntryCount: value.activeEntryCount)
  }

  func purgeUnused() async throws -> RuntimeTraceCachePurgeReport {
    let value = try await service.purgeUnused()
    func inventory(_ source: ArkDeckTraceCacheInventory) -> RuntimeTraceCacheInventory {
      RuntimeTraceCacheInventory(
        entryCount: source.entryCount,
        totalByteCount: source.totalByteCount,
        activeEntryCount: source.activeEntryCount)
    }
    return RuntimeTraceCachePurgeReport(
      before: inventory(value.before), after: inventory(value.after),
      recoveredPrivateDirectoryCount: value.recoveredPrivateDirectoryCount,
      removedOrphanOwnerMarkerCount: value.removedOrphanOwnerMarkerCount,
      removedEntryCount: value.removedEntryCount,
      skippedActiveEntryCount: value.skippedActiveEntryCount)
  }
}

/// Product bridge from the trusted ArkTrace distribution snapshot into the
/// Runtime's path-free local inspection resource.
struct ProductTraceOfflineInspector: RuntimeTraceInspecting {
  let service: ArkDeckTraceOfflineInspectionService

  init(profile: AnalyzerProfile, workingDirectory: URL) throws {
    guard profile.analyzerRef == "trace-summary@1",
      profile.preflightAvailability == .available,
      let contract = profile.arkTraceSummaryContract,
      let bundlePath = profile.canonicalNamespaceRoot,
      profile.analyzerVersion.hasPrefix(contract.toolVersion + "+")
    else { throw ArkTraceSummaryProfileError.contractMismatch }
    let build = String(profile.analyzerVersion.dropFirst(contract.toolVersion.utf8.count + 1))
    guard !build.isEmpty, build.utf8.count <= 128,
      !build.unicodeScalars.contains(where: CharacterSet.controlCharacters.contains)
    else { throw ArkTraceSummaryProfileError.contractMismatch }
    service = try ArkDeckTraceOfflineInspectionService(
      distributionBundleURL: URL(filePath: bundlePath, directoryHint: .isDirectory),
      workingDirectory: workingDirectory,
      contract: ArkDeckTraceOfflineInspectionContract(
        engineVersion: contract.toolVersion,
        engineBuild: build,
        parserVersion: contract.parserVersion,
        parserUpstreamRevision: contract.parserUpstreamRevision,
        parserSHA256: contract.parserSHA256,
        parserAdapterVersion: contract.parserAdapterVersion,
        parserBuildRecipeVersion: contract.parserBuildRecipeVersion,
        schemaAdapterVersion: contract.schemaAdapterVersion,
        indexSchemaVersion: contract.indexSchemaVersion))
  }

  func inspect(
    source: URL,
    expectedSourceSHA256: String,
    expectedSourceByteCount: Int
  ) async throws -> RuntimeTraceInspectionReport {
    let value = try await service.inspect(
      source: source,
      expectedSourceSHA256: expectedSourceSHA256,
      expectedSourceByteCount: expectedSourceByteCount)
    return try RuntimeTraceInspectionReport(
      engineVersion: value.engineVersion,
      engineBuild: value.engineBuild,
      engineSourceRevision: value.engineSourceRevision,
      sourceSHA256: value.sourceSHA256,
      sourceByteCount: value.sourceByteCount,
      durationNs: value.durationNs,
      schemaFingerprint: value.schemaFingerprint,
      parser: RuntimeTraceInspectionParser(
        name: value.parserName,
        version: value.parserVersion,
        upstreamRevision: value.parserUpstreamRevision,
        binarySHA256: value.parserSHA256,
        adapterVersion: value.parserAdapterVersion,
        buildRecipeVersion: value.parserBuildRecipeVersion),
      schema: RuntimeTraceInspectionSchema(
        adapterVersion: value.schemaAdapterVersion,
        indexVersion: value.indexSchemaVersion,
        upstreamDatabaseSHA256: value.upstreamDatabaseSHA256,
        upstreamDatabaseByteCount: value.upstreamDatabaseByteCount),
      capabilities: RuntimeTraceInspectionCapabilities(
        cpuScheduling: value.cpuScheduling,
        threadStates: value.threadStates,
        namedSlices: value.namedSlices,
        cpuCounters: value.cpuCounters,
        processCounters: value.processCounters),
      dataQualityStatus: value.dataQualityStatus,
      dataQualityIssues: try value.dataQualityIssues.map {
        try RuntimeTraceInspectionQualityIssue(
          category: $0.category, scope: $0.scope, count: $0.count)
      })
  }
}

/// Bootstrap observation over the descriptor-bound dispatcher: every action
/// is closed, read-only and verified by the provider's semantic parser.
struct ProviderBootstrapObservation: BootstrapObservationPort {
  let provider: HDCObservationProviderAdapter
  let dispatcher: any RuntimeProcessDispatching

  private func run(
    _ action: HDCProviderAction,
    connectKey: String? = nil
  ) async throws -> ProviderSemanticOutcome {
    let context = ProviderExecutionContext(
      jobID: "bootstrap", stepID: "observe", targetID: "-", bindingRevision: nil,
      connectKey: connectKey,
      nowUTC: utcNow())
    let plan = try provider.lower(action: .hdc(action), context: context)
    let receipt = try await dispatcher.dispatch(plan)
    return try provider.verify(receipt: receipt, action: .hdc(action), context: context)
  }

  func observeToolVersion() async throws -> String {
    guard case .verified(let summary) = try await run(.observeTool),
      let version = summary["toolVersion"]
    else {
      throw BootstrapError.observationFailed("tool version could not be verified")
    }
    return version
  }

  func listCandidates() async throws -> [BootstrapCandidate] {
    // Parsing stays inside the provider: the composition root only reads
    // the verified summary it publishes.
    guard case .verified(let summary) = try await run(.listDeviceCandidates) else {
      throw BootstrapError.observationFailed("candidate list could not be verified")
    }
    guard let countText = summary["targetCount"], let count = Int(countText) else {
      throw BootstrapError.observationFailed("candidate list summary is malformed")
    }
    guard count > 0 else { return [] }
    guard let keys = summary["connectKeys"], !keys.isEmpty else {
      throw BootstrapError.observationFailed(
        "provider did not publish candidate connect keys; adoption needs the device window")
    }
    return keys.split(separator: ",").map { entry in
      let parts = entry.split(separator: "=", maxSplits: 1)
      return BootstrapCandidate(
        connectKey: String(parts[0]),
        state: parts.count == 2 ? String(parts[1]) : "Unknown")
    }
  }

  func observeDeviceInformation(connectKey: String) async throws
    -> BootstrapDeviceInformation?
  {
    async let name = property(.productName, connectKey: connectKey)
    async let systemVersion = property(.fullBuildVersion, connectKey: connectKey)
    let values = await (name, systemVersion)
    return BootstrapDeviceInformation(
      name: values.0,
      systemVersion: values.1,
      transport: connectKey.contains(":") ? "Network" : "USB")
  }

  private func property(
    _ property: HDCAllowlistedProperty,
    connectKey: String
  ) async -> String? {
    guard
      case .verified(let summary) = try? await run(
        .queryProperty(property), connectKey: connectKey)
    else { return nil }
    guard let value = summary["value"] else { return nil }
    let normalized = value.lowercased()
    guard !["default", "unknown", "none", "null", "[empty]"].contains(normalized),
      !normalized.hasPrefix("[fail]")
    else { return nil }
    return value
  }

  func observeDeviceIdentity(connectKey: String) async throws -> [String: String] {
    guard case .verified = try await run(.observeDevice(connectKey: connectKey)) else {
      throw BootstrapError.observationFailed("device observation could not be verified")
    }
    // The connect key is the device's stable serial surface for USB
    // targets; richer identity attributes arrive with the device window.
    return ["serial": connectKey]
  }
}

// Synchronous top level on purpose. With an async top level the Swift
// concurrency runtime owns the main thread, and a signal arriving while
// the main task is suspended traps the process before any handler runs
// (observed as SIGTRAP / exit 133 in the first device window, with the
// SIGTERM handler never entered). The async setup work runs inside a Task
// that the main thread waits on, then `dispatchMain()` parks the daemon
// the way a daemon is normally parked.
// Snapshot the resolved paths so the detached task holds immutable values
// instead of reaching back into main-actor-isolated top-level variables.
let resolvedStateDirectory = stateDirectory
let ready = DispatchSemaphore(value: 0)
nonisolated(unsafe) var startupFailure: (any Error)?
nonisolated(unsafe) var startedServer: AgentDaemonServer?
nonisolated(unsafe) var startedXPCListener: AgentXPCListener?
nonisolated(unsafe) var startedHDCServerHost: HeadlessHDCServerHost?
nonisolated(unsafe) var startedArkForgeDaemon: ArkForgeLaneComposition.DaemonLifecycle?

// Detached on purpose: the top level is @MainActor-isolated, so a plain
// `Task { }` would inherit the main actor and deadlock against the
// semaphore wait below.
Task.detached {
  defer { ready.signal() }
  do {
    let capabilityStore = try RuntimeCapabilityStore(
      directoryURL: resolvedStateDirectory.appending(
        path: "capabilities", directoryHint: .isDirectory)
    )
    let targetStore = try RuntimeTargetStore(
      directoryURL: resolvedStateDirectory.appending(path: "targets", directoryHint: .isDirectory))
    var startupLoaderBindingRecovery:
      (
        targetID: String,
        proof: RockchipLoaderBindingRecoveryProof
      )?

    // A Loader rebind advances the product's owner-only Rockchip binding,
    // while the adopted Runtime target deliberately keeps its normal-mode
    // connect key for post-flash HDC recovery. Reconcile that exact adjacent
    // lineage edge before the engine imports an Artifact or materializes a
    // request, so all three use one identity/revision snapshot. Custom test
    // state directories never consult the user's production binding.
    let rockchipRoot = resolvedStateDirectory.deletingLastPathComponent()
    let postFlashHDCBindingStore = RockchipPostFlashHDCBindingStore(
      rootURL: rockchipRoot)
    if resolvedStateDirectory.lastPathComponent == "Agentd",
      rockchipRoot.lastPathComponent == "ArkDeck",
      let binding = try RockchipProductBindingStore(rootURL: rockchipRoot).loadIfPresent()
    {
      do {
        if let advance = try binding.runtimeTargetLineageAdvance() {
          let result = try targetStore.advanceBindingLineage(advance)
          if let proof = try binding.loaderBindingRecoveryProof() {
            startupLoaderBindingRecovery = (result.record.targetID, proof)
          }
          if result.updated {
            print(
              "advanced runtime target \(result.record.targetID) to Rockchip binding revision "
                + "\(result.record.bindingRevision)")
          }
        }
      } catch {
        // Historical bindings may carry the retired chat-confirmation field.
        // They are deliberately unusable for admission, but the daemon must
        // stay available so the user can select a target and let Runtime
        // migrate it from a fresh, unique Loader observation.
        print("Rockchip binding requires Runtime Loader onboarding: \(error)")
      }
    }

    // A complete historical Flash may prove that an HDC address adopted as a
    // second target is actually the post-flash face of the Loader-bound
    // target. Reconcile only from owner-only terminal history. Failure keeps
    // the alias conflict gate closed and must not prevent read-only diagnosis.
    do {
      if let resolution = try ProductRockchipTargetAliasReconciler(
        targetStore: targetStore,
        applicationSupportRoot: rockchipRoot,
        stateDirectory: resolvedStateDirectory
      ).reconcileIfProven() {
        print(
          "resolved historical target alias \(resolution.aliasTargetID) to "
            + "\(resolution.canonicalTargetID) via \(resolution.resolutionID)")
      }
    } catch {
      print("Rockchip target alias remains fail-closed: \(error)")
    }

    // The HDC executable is supplied explicitly (no PATH search, no guess):
    // absent configuration means dispatch stays refused, never degraded.
    let configuredHDC = ProcessInfo.processInfo.environment[ArkDeckEnvironmentKey.hdcPath]
    var hdcDispatcher: any RuntimeProcessDispatching = RefusingDispatcher(
      reason: "no HDC executable configured (set \(ArkDeckEnvironmentKey.hdcPath)); "
        + "dispatch stays fail-closed")
    var hdcExecutableResolver: (any RuntimeExecutableResolving)?
    var traceRuntimeProbe: (any TraceRuntimeProbing)? = nil
    var debugRuntimeProbe: (any DebugRuntimeProbing)? = nil
    var executableSHA = ""
    var selectedHDCPath: String?
    var toolSelectionRegistry: BootstrapToolSelectionRegistryAdapter?
    if let configuredHDC {
      do {
        let registry = try BootstrapToolRegistry(knownIdentity: { sha256 in
          HeadlessHDCBootstrapIdentity.lookup(sha256: sha256).map {
            BootstrapToolRegistry.PublishedIdentity(
              version: $0.version, profileReferences: $0.profileReferences)
          }
        })
        let adapter = BootstrapToolSelectionRegistryAdapter(registry: registry)
        if try registry.startupSelection() == nil {
          _ = try registry.adoptInstalledHDC(file: URL(filePath: configuredHDC))
        }
        if var startup = try registry.startupSelection() {
          var resolvedHDC = try BootstrapToolSelectionRegistryAdapter.resolved(startup.resolved)
          let startHost: @Sendable (ResolvedExecutable) async throws -> HeadlessHDCServerHost = {
            executable in
            try await HeadlessHDCServerHost.start(
              executable: executable,
              onUnexpectedExit: {
                // An unexpected server death is a daemon crash boundary: launchd
                // KeepAlive restarts the service and re-establishes the complete
                // provider graph before reopening the control socket.
                Darwin.exit(70)
              })
          }
          do {
            startedHDCServerHost = try await startHost(resolvedHDC)
            if let pendingActionID = startup.pendingActionID {
              do {
                _ = try registry.publishPendingSelection(actionID: pendingActionID)
              } catch {
                switch try registry.selectionOutcome(actionID: pendingActionID) {
                case .succeeded:
                  break
                case .pending:
                  await startedHDCServerHost?.stop()
                  startedHDCServerHost = nil
                  _ = try registry.failPendingSelection(
                    actionID: pendingActionID,
                    reasonCode: "tool.selectionPublishFailed")
                  guard let old = try registry.startupSelection(),
                    old.pendingActionID == nil
                  else {
                    throw HDCControlValue.failure(
                      "recordUnreadable", "failed tool selection lost its prior active executable")
                  }
                  startup = old
                  resolvedHDC = try BootstrapToolSelectionRegistryAdapter.resolved(old.resolved)
                  startedHDCServerHost = try await startHost(resolvedHDC)
                case .failed:
                  await startedHDCServerHost?.stop()
                  startedHDCServerHost = nil
                  guard let old = try registry.startupSelection() else { throw error }
                  startup = old
                  resolvedHDC = try BootstrapToolSelectionRegistryAdapter.resolved(old.resolved)
                  startedHDCServerHost = try await startHost(resolvedHDC)
                case .absent:
                  throw error
                }
              }
            }
          } catch {
            if let pendingActionID = startup.pendingActionID {
              _ = try? registry.failPendingSelection(
                actionID: pendingActionID,
                reasonCode: "tool.selectedStartupVerificationFailed")
              if let old = try registry.startupSelection(), old.pendingActionID == nil {
                startup = old
                resolvedHDC = try BootstrapToolSelectionRegistryAdapter.resolved(old.resolved)
                startedHDCServerHost = try await startHost(resolvedHDC)
              } else {
                throw error
              }
            } else {
              throw error
            }
          }
          executableSHA = resolvedHDC.sha256
          selectedHDCPath = resolvedHDC.path
          let resolver = FixedExecutableResolver(table: ["hdc": resolvedHDC])
          // The login-session daemon owns a foreground, loopback-only server.
          // This avoids depending on a Terminal parent or HDC's client-side
          // background daemonisation, and cancellation tears down the dedicated
          // process group during LaunchAgent update/uninstall.
          hdcExecutableResolver = resolver
          // Pointer injection is the one operation with an interaction budget,
          // and it is a single device command, so a spawned client costs a
          // process launch on top of the round trip that does the work. It is
          // routed over a shell that is already open; everything else keeps the
          // spawning path it has, including pointer injection whenever a channel
          // cannot serve it.
          hdcDispatcher = PointerInputChannelDispatcher(
            fallback: DescriptorBoundProcessDispatcher.hdc(resolver: resolver),
            resolver: resolver)
          traceRuntimeProbe = FoundationTraceRuntimeProbe(
            targetStore: targetStore, hdcResolver: resolver,
            workingDirectory: resolvedStateDirectory)
          debugRuntimeProbe = FoundationDebugRuntimeProbe(
            targetStore: targetStore, hdcResolver: resolver,
            workingDirectory: resolvedStateDirectory)
          toolSelectionRegistry = adapter
        }
      } catch {
        await startedHDCServerHost?.stop()
        startedHDCServerHost = nil
        // Selection state and configured-tool adoption are part of the process
        // identity boundary. Continuing to UDS composition after either fails
        // would publish a Runtime whose HDC ownership is unknown.
        throw error
      }
    }

    let hdcProvider = HDCObservationProviderAdapter(
      factsPort: TargetStoreFactsPort(
        targetStore: targetStore, executablePath: selectedHDCPath ?? "-",
        executableSHA256: executableSHA))
    let resolvedArkForgeInputs: ArkForgeLaneComposition.Inputs?
    switch ArkForgeLaneComposition.Inputs.read(ProcessInfo.processInfo.environment) {
    case .success(let inputs): resolvedArkForgeInputs = inputs
    case .failure: resolvedArkForgeInputs = nil
    }
    let rockchipResolver = ArkForgeNativeRockUSBExecutableResolver(
      daemonPath: resolvedArkForgeInputs?.daemonPath,
      declaredSHA256: resolvedArkForgeInputs?.daemonSHA256)
    let rockchipDispatcher: ArkForgeNativeRockchipControlDispatcher
    // Facts are measured only where the same per-action tool runtime is
    // composed. Without a descriptor-bound HDC there is no read-only surface
    // to measure the target's mode on, and a mode asserted without one is
    // exactly the fabrication #992 removed — so the port stays record-only.
    var rockchipProber: (any RockchipLiveModeProbing)?
    if let hdcExecutableResolver {
      rockchipDispatcher = ArkForgeNativeRockchipControlDispatcher(
        resolver: rockchipResolver,
        hdcResolver: hdcExecutableResolver,
        stateDirectory: resolvedStateDirectory,
        stateWorkingDirectory: resolvedStateDirectory,
        postFlashHDCBindingStore: postFlashHDCBindingStore)
      rockchipProber = FoundationRockchipLiveModeProbe(
        hdcResolver: hdcExecutableResolver,
        stateDirectory: resolvedStateDirectory)
    } else {
      rockchipDispatcher = ArkForgeNativeRockchipControlDispatcher(
        resolver: rockchipResolver)
    }
    let rockchipFactsPort = TargetStoreRockchipRuntimeFactsPort(
      targetStore: targetStore, resolver: rockchipResolver,
      prober: rockchipProber,
      bindingStore: RockchipProductBindingStore(rootURL: rockchipRoot),
      postFlashHDCBindingStore: postFlashHDCBindingStore,
      nowUTC: utcNow)
    // Host-only workspace provider (CHG-2026-054 TASK-HTP-007/005). Project
    // roots and the optional inspector are explicit configuration; operation
    // presets come from the built-in ProjectProfile. Missing pieces report
    // unavailable, so nothing is admitted and no capability is consumed.
    //   ARKDECK_WORKSPACE_INSPECTOR=/usr/bin/grep
    //   ARKDECK_WORKSPACE_PROJECTS=demo-app=/abs/path,other=/abs/other
    //   ARKDECK_WORKSPACE_ACTIVE_PROJECT=demo-app
    //   ARKDECK_DEVECO_SDK_HOME=/Applications/DevEco-Studio.app/Contents/sdk
    let legacyWorkspaceRoots = Dictionary(
      uniqueKeysWithValues: (ProcessInfo.processInfo.environment["ARKDECK_WORKSPACE_PROJECTS"] ?? "")
        .split(separator: ",")
        .compactMap { entry -> (String, String)? in
          let parts = entry.split(separator: "=", maxSplits: 1).map {
            $0.trimmingCharacters(in: .whitespaces)
          }
          guard parts.count == 2, !parts[0].isEmpty, parts[1].hasPrefix("/") else { return nil }
          return (parts[0], parts[1])
        })
    let bootstrapRegistry = try BootstrapBundleRegistry()
    let devecoToolchains = BootstrapDevEcoToolchainRegistry(owner: bootstrapRegistry)
    let signingPresetStore = OpenHarmonySigningPresetStore()
    let signingCredentialOwner = OpenHarmonySigningCredentialOwner(
      store: signingPresetStore)
    let workspaceToolchainPinning = RuntimeWorkspaceToolchainPinning(
      acquire: { reference, generation, presetRef in
        do {
          let owner = try BootstrapBundleRegistry.ReferenceOwner(
            kind: .workspacePreset, id: presetRef)
          _ = try devecoToolchains.acquire(
            reference, expectedGeneration: String(generation), owner: owner)
        } catch let failure as AgentExecutionControlFailure {
          throw RuntimeWorkspaceProjectFailure(failure.code, failure.message)
        }
      },
      release: { reference, presetRef in
        do {
          let owner = try BootstrapBundleRegistry.ReferenceOwner(
            kind: .workspacePreset, id: presetRef)
          try devecoToolchains.release(reference, owner: owner)
        } catch let failure as AgentExecutionControlFailure {
          throw RuntimeWorkspaceProjectFailure(failure.code, failure.message)
        }
      })
    let workspaceCredentialPinning = RuntimeWorkspaceCredentialPinning(
      acquire: { reference, presetRef in
        do {
          try signingCredentialOwner.acquire(reference, owner: presetRef)
        } catch {
          throw RuntimeWorkspaceProjectFailure(
            "resourceConflict", "signing credential pin could not be validated")
        }
      },
      release: { reference, presetRef in
        do {
          try signingCredentialOwner.release(reference, owner: presetRef)
        } catch {
          throw RuntimeWorkspaceProjectFailure(
            "resourceConflict", "signing credential pin could not be released")
        }
      })
    let workspaceProjectStore = try RuntimeWorkspaceProjectStore(
      rootURL: resolvedStateDirectory, toolchainPinning: workspaceToolchainPinning,
      credentialPinning: workspaceCredentialPinning,
      nowUTC: utcNow)
    // The legacy daemon flags are a compatibility reader only. Import them
    // once into the same Runtime owner used by the target CLI, so service
    // restart stops depending on a raw caller path and the target projection
    // has one source of truth.
    for (projectRef, root) in legacyWorkspaceRoots {
      let kind: String
      switch projectRef {
      case "ArkDeck": kind = "arkdeck"
      case "demo-app": kind = "openharmony"
      default: continue
      }
      _ = try? workspaceProjectStore.register(
        requestID: "legacy-\(projectRef)", kind: kind, rootPath: root,
        projectRef: projectRef)
    }
    let registeredWorkspaceStartup = try workspaceProjectStore.startupRecords()
    let registeredWorkspaceProjects = registeredWorkspaceStartup.map(\.resource)
    let registeredWorkspacePresetCompositions = try workspaceProjectStore
      .presetCompositionRecords()
    let registeredWorkspaceCompositions = registeredWorkspaceStartup.compactMap(\.composition)
    let registeredWorkspaceRoots = Dictionary(
      uniqueKeysWithValues: registeredWorkspaceCompositions.map {
        ($0.resource.projectRef, $0.rootPath)
      })
    var workspaceRoots = legacyWorkspaceRoots
    for (projectRef, root) in registeredWorkspaceRoots { workspaceRoots[projectRef] = root }
    let registeredWorkspaceKinds = Dictionary(
      uniqueKeysWithValues: registeredWorkspaceProjects.map {
        ($0.projectRef, $0.kind)
      })
    let registeredWorkspaceFailures = Dictionary(
      uniqueKeysWithValues: registeredWorkspaceStartup.compactMap { startup in
        startup.failure.map {
          (startup.resource.projectRef, "workspace.projectRootUnavailable:\($0.message)")
        }
      })
    // What `workspace project list` will publish. Every configured ref lands
    // here — resolved or not — because an empty list would mean both "nothing
    // configured" and "configured but unusable", and the second is the one an
    // operator has to be able to see.
    var workspaceProjectPublications: [WorkspaceProjectPublication] = []
    let configuredInspector = ProcessInfo.processInfo.environment["ARKDECK_WORKSPACE_INSPECTOR"]
    let signingAttemptStore = try OpenHarmonySigningAttemptStore(
      rootURL: resolvedStateDirectory.appending(
        path:
          "workspace-signing-attempts", directoryHint: .isDirectory))
    var workspaceTool: WorkspaceInspectorTool?
    var inspectorExecutable: ResolvedExecutable?
    var workspaceDispatcher: any RuntimeProcessDispatching = RefusingDispatcher(
      reason: "no workspace ProjectProfile is configured")
    var workspaceChildEnvironment: [String: String] = [:]
    var workspaceChildEnvironmentByExecutablePath: [String: [String: String]] = [:]
    var resolvedPresetsByProject: [String: [RuntimeWorkspaceResolvedPreset]] = [:]
    var workspacePresetResolutionFailures: [String: String] = [:]
    for composition in registeredWorkspacePresetCompositions {
      let resource = composition.resource
      do {
        switch resource.kind {
        case "build", "test":
          guard let toolchainRef = resource.toolchainRef,
            let toolchainGeneration = resource.toolchainGeneration
          else {
            throw RuntimeWorkspaceProjectFailure(
              "recordUnreadable", "registered Hvigor preset has no toolchain pin")
          }
          let owner = try BootstrapBundleRegistry.ReferenceOwner(
            kind: .workspacePreset, id: resource.presetRef)
          let toolchain = try devecoToolchains.resolve(
            toolchainRef, expectedGeneration: String(toolchainGeneration), owner: owner)
          let resolved = RuntimeWorkspaceResolvedPreset(
            resource: resource, nodePath: toolchain.nodeExecutable.path,
            hvigorScriptPath: toolchain.hvigorScript.path,
            sdkRootPath: toolchain.sdkRoot.path,
            verifiedResources: toolchain.verifiedResources.map {
              ResolvedExecutableResource(
                path: $0.url.path, sha256: $0.sha256,
                byteCount: $0.byteCount, requireExecutable: $0.requireExecutable)
            })
          resolvedPresetsByProject[resource.projectRef, default: []].append(resolved)
          workspaceChildEnvironmentByExecutablePath[toolchain.nodeExecutable.path] = [
            "DEVECO_SDK_HOME": toolchain.sdkRoot.path
          ]
        case "symbol":
          resolvedPresetsByProject[resource.projectRef, default: []].append(
            RuntimeWorkspaceResolvedPreset(resource: resource))
        case "signing":
          guard let toolchainRef = resource.toolchainRef,
            let toolchainGeneration = resource.toolchainGeneration,
            let credentialRef = resource.credentialRef
          else {
            throw RuntimeWorkspaceProjectFailure(
              "recordUnreadable", "registered signing preset has incomplete dependencies")
          }
          let owner = try BootstrapBundleRegistry.ReferenceOwner(
            kind: .workspacePreset, id: resource.presetRef)
          _ = try devecoToolchains.resolve(
            toolchainRef, expectedGeneration: String(toolchainGeneration), owner: owner)
          let credential = try signingCredentialOwner.resolve(
            credentialRef, owner: resource.presetRef)
          guard credential.projectRef == resource.projectRef else {
            throw RuntimeWorkspaceProjectFailure(
              "resourceConflict", "signing credential project binding changed")
          }
          resolvedPresetsByProject[resource.projectRef, default: []].append(
            RuntimeWorkspaceResolvedPreset(resource: resource))
        default:
          workspacePresetResolutionFailures[resource.presetRef] =
            "workspace.presetKindUnsupported"
        }
      } catch {
        workspacePresetResolutionFailures[resource.presetRef] =
          "workspace.presetResolutionFailed:\(error)"
      }
    }
    if let configuredInspector {
      let resolver = try FixedExecutableResolver.hashing(
        path: configuredInspector, providerID: "workspace")
      let resolved = try resolver.resolveExecutable(providerID: "workspace")
      inspectorExecutable = resolved
      workspaceTool = WorkspaceInspectorTool(
        executablePath: resolved.path, executableSHA256: resolved.sha256)
    }
    let workspaceOperations: any DeviceProvider
    var workspaceOperationResolver: WorkspaceActionExecutableResolver?
    var workspaceEvolution: EvolutionWorkspaceManager?
    var resolvedWorkspaceProfiles: [WorkspaceProjectProfile] = []
    var workspaceResolutionFailures = registeredWorkspaceFailures
    // One provider registry can route every typed request by projectRef. Build
    // all registered primary profiles here so a fresh host never needs the
    // legacy ARKDECK_WORKSPACE_ACTIVE_PROJECT selector after registration.
    for projectRef in workspaceRoots.keys.sorted() {
      guard let root = workspaceRoots[projectRef] else { continue }
      do {
        let profile: WorkspaceProjectProfile
        switch registeredWorkspaceKinds[projectRef] ?? projectRef {
        case "arkdeck", "ArkDeck":
          profile = try WorkspaceProjectProfile.arkDeck(
            rootURL: URL(filePath: root, directoryHint: .isDirectory),
            projectRef: projectRef)
        case "openharmony", "demo-app":
          if legacyWorkspaceRoots[projectRef] != nil {
            let node =
              ProcessInfo.processInfo.environment["ARKDECK_DEVECO_NODE_PATH"]
              ?? "/Applications/DevEco-Studio.app/Contents/tools/node/bin/node"
            let hvigor =
              ProcessInfo.processInfo.environment["ARKDECK_DEVECO_HVIGOR_PATH"]
              ?? "/Applications/DevEco-Studio.app/Contents/tools/hvigor/bin/hvigorw.js"
            let configuredSDK =
              ProcessInfo.processInfo.environment["ARKDECK_DEVECO_SDK_HOME"]
              ?? ProcessInfo.processInfo.environment["DEVECO_SDK_HOME"]
              ?? "/Applications/DevEco-Studio.app/Contents/sdk"
            let sdk = URL(filePath: configuredSDK, directoryHint: .isDirectory)
              .resolvingSymlinksInPath().standardizedFileURL
            var sdkIsDirectory: ObjCBool = false
            let openHarmonySDK = sdk.appending(
              path: "default/openharmony", directoryHint: .isDirectory)
            guard configuredSDK.hasPrefix("/"),
              FileManager.default.fileExists(
                atPath: openHarmonySDK.path, isDirectory: &sdkIsDirectory),
              sdkIsDirectory.boolValue
            else {
              throw DeviceProviderError.factsUnavailable(
                "workspace.projectProfileUnavailable: DevEco OpenHarmony SDK is absent")
            }
            // A legacy root keeps its environment-derived presets, and it
            // also carries every preset registered against the same project:
            // the registration owner reports those as active, so a build or
            // signing preset a caller pinned through `workspace preset
            // register` must be usable here too, not only after the legacy
            // flag has been dropped. `nil` when nothing is registered keeps
            // the legacy signing fallback exactly as before.
            profile = try WorkspaceProjectProfile.waterFlowDemo(
              rootURL: URL(filePath: root, directoryHint: .isDirectory),
              projectRef: projectRef, nodePath: node, hvigorScriptPath: hvigor,
              symbolizerPath: ProcessInfo.processInfo.environment["ARKDECK_ANALYZER_PATH"],
              registeredPresets: resolvedPresetsByProject[projectRef])
            workspaceChildEnvironment = ["DEVECO_SDK_HOME": sdk.path]
          } else {
            profile = try WorkspaceProjectProfile.waterFlowDemo(
              rootURL: URL(filePath: root, directoryHint: .isDirectory),
              projectRef: projectRef,
              symbolizerPath: ProcessInfo.processInfo.environment["ARKDECK_ANALYZER_PATH"],
              registeredPresets: resolvedPresetsByProject[projectRef] ?? [])
          }
        default:
          throw DeviceProviderError.factsUnavailable(
            "workspace.projectProfileUnavailable:\(projectRef) is unsupported")
        }
        resolvedWorkspaceProfiles.append(profile)
      } catch {
        workspaceResolutionFailures[projectRef] = "workspace.projectProfileUnavailable:\(error)"
      }
    }
    if let primaryProfile = resolvedWorkspaceProfiles.first {
      let attempts = try WorkspacePatchAttemptStore(
        rootURL: resolvedStateDirectory.appending(
          path: "workspace-patch-attempts", directoryHint: .isDirectory))
      let profiles = try WorkspaceProjectProfileRegistry(profiles: resolvedWorkspaceProfiles)
      let evolution = try EvolutionWorkspaceManager(
        rootURL: resolvedStateDirectory.appending(
          path: "evolution-workspaces", directoryHint: .isDirectory),
        profileRegistry: profiles,
        patchLineage: attempts)
      let unadoptedRuntimeWorkspaces = evolution.adoptRuntimeWorkspaces()
      for workspaceID in unadoptedRuntimeWorkspaces {
        print("runtime workspace not adopted for \(workspaceID)")
      }
      if !unadoptedRuntimeWorkspaces.isEmpty { fflush(stdout) }
      workspaceEvolution = evolution
      workspaceOperations = WorkspaceOperationsProvider(
        profile: primaryProfile, profileRegistry: profiles,
        attemptStore: attempts, signingPresetStore: signingPresetStore,
        signingCredentialOwner: signingCredentialOwner,
        signingAttemptStore: signingAttemptStore,
        isolationManager: evolution,
        availabilityProfiles: resolvedWorkspaceProfiles,
        nowUTC: utcNow)
      workspaceOperationResolver = WorkspaceActionExecutableResolver(
        profiles: resolvedWorkspaceProfiles)
      // Availability is evaluated from each project's own closed profile,
      // while execution routes through the shared registry above.
      for profile in resolvedWorkspaceProfiles {
        let projectProvider = WorkspaceOperationsProvider(
          profile: profile, profileRegistry: profiles,
          attemptStore: attempts, signingPresetStore: signingPresetStore,
          signingCredentialOwner: signingCredentialOwner,
          signingAttemptStore: signingAttemptStore,
          isolationManager: evolution, nowUTC: utcNow)
        workspaceProjectPublications.append(
          WorkspaceProjectPublication.make(
            profile: profile,
            availability: { projectProvider.runtimeAvailability(for: $0) }))
      }
    } else {
      let resolutionReason = workspaceResolutionFailures.keys.sorted()
        .compactMap { workspaceResolutionFailures[$0] }
        .joined(separator: "; ")
      workspaceOperations = UnavailableWorkspaceOperationsProvider(
        reason: resolutionReason.isEmpty
          ? "workspace.projectProfileUnavailable: no registered project profile resolved"
          : resolutionReason)
    }
    if let workspaceOperationResolver {
      workspaceDispatcher = DescriptorBoundProcessDispatcher(
        resolver: CombinedWorkspaceExecutableResolver(
          inspector: inspectorExecutable, operations: workspaceOperationResolver),
        childEnvironment: workspaceChildEnvironment,
        childEnvironmentByExecutablePath: workspaceChildEnvironmentByExecutablePath)
    } else if let inspectorExecutable {
      workspaceDispatcher = DescriptorBoundProcessDispatcher(
        resolver: FixedExecutableResolver(
          table: ["workspace": inspectorExecutable]))
    }
    let configuredWorkspaceRefs = Set(workspaceRoots.keys)
      .union(registeredWorkspaceProjects.map(\.projectRef))
    for configuredRef in configuredWorkspaceRefs.sorted()
    where !workspaceProjectPublications.contains(where: { $0.projectRef == configuredRef }) {
      workspaceProjectPublications.append(
        WorkspaceProjectPublication.unresolved(
          projectRef: configuredRef,
          reason: workspaceResolutionFailures[configuredRef]
            ?? "this project profile could not be derived"))
    }
    let resolvedProjectRefs = Set(resolvedWorkspaceProfiles.map(\.projectRef))
    let appliedPresetGenerations: [String: UInt64] = Dictionary(uniqueKeysWithValues:
      registeredWorkspacePresetCompositions.compactMap { composition in
        let resource = composition.resource
        guard resolvedProjectRefs.contains(resource.projectRef),
          resolvedPresetsByProject[resource.projectRef]?.contains(where: {
            $0.resource.presetRef == resource.presetRef
          }) == true,
          workspacePresetResolutionFailures[resource.presetRef] == nil
        else { return nil }
        return (resource.presetRef, resource.generation)
      })
    workspaceProjectStore.markApplied(
      projects: Dictionary(uniqueKeysWithValues: registeredWorkspaceProjects.map {
        ($0.projectRef, $0.generation)
      }),
      presets: appliedPresetGenerations)
    let workspaceReferenceLedger = WorkspaceReferenceLedgerHandle()
    if let evolution = workspaceEvolution {
      workspaceDispatcher = RuntimeOwnedWorkspaceDispatcher(
        fallback: workspaceDispatcher, manager: evolution,
        sweeper: evolution, referenceLedger: workspaceReferenceLedger)
    }
    workspaceDispatcher = OpenHarmonySigningWorkspaceDispatcher(
      fallback: workspaceDispatcher, presetStore: signingPresetStore)
    // No analyzer is configured by default. A host declares the pinned
    // executable explicitly; an absent analyzer is unavailable, never
    // improvised.  The shipped daemon can serve the closed one-shot mode,
    // but its path still has to be named so packaging drift fails closed.
    //   ARKDECK_ANALYZER_PATH=/abs/path/to/arkdeck-agentd
    var analyzerProfiles: [AnalyzerProfile] = []
    var analyzerUnavailableReasons: [String: String] = [:]
    if let analyzerPath = ProcessInfo.processInfo.environment["ARKDECK_ANALYZER_PATH"] {
      let resolver = try FixedExecutableResolver.hashing(
        path: analyzerPath, providerID: "analyzer")
      let executable = try resolver.resolveExecutable(providerID: "analyzer")
      analyzerProfiles.append(
        AnalyzerProfile(
          analyzerRef: HarnessCrashLedgerAnalysis.analyzerRef,
          analyzerVersion: HarnessCrashLedgerAnalysis.analyzerVersion,
          executablePath: executable.path,
          executableSHA256: executable.sha256,
          fixedArguments: ["--analyze-crash-ledger"], timeoutSeconds: 30))
      if let ownURL = Bundle.main.executableURL,
        let ownResolver = try? FixedExecutableResolver.hashing(
          path: ownURL.path, providerID: "analyzer"),
        let ownExecutable = try? ownResolver.resolveExecutable(providerID: "analyzer"),
        let profile = HilogSummaryDerivedAnalyzer.profile(
          executable: executable, currentDaemon: ownExecutable)
      {
        analyzerProfiles.append(profile)
      } else {
        analyzerUnavailableReasons[HilogSummaryDerivedAnalyzer.analyzerRef] =
          HilogSummaryDerivedAnalyzer.incompatibleExecutableReason
      }
    }
    if let descriptorPath = ProcessInfo.processInfo.environment[
      "ARKDECK_ARKTRACE_DESCRIPTOR"]
    {
      do {
        let loader = ArkTraceSummaryAnalyzerProfileLoader(
          doctor: ProductionArkTraceDoctorProbe(
            homeURL: resolvedStateDirectory.appending(
              path: "arktrace-availability-home", directoryHint: .isDirectory)),
          snapshotRootURL: resolvedStateDirectory.appending(
            path: "arktrace-profile-snapshots", directoryHint: .isDirectory))
        analyzerProfiles.append(
          contentsOf: try await loader.loadProfiles(
            descriptorURL: URL(filePath: descriptorPath)))
      } catch let error as ArkTraceSummaryProfileError {
        analyzerUnavailableReasons["trace-summary@1"] = error.reason
        analyzerUnavailableReasons["trace-analysis@1"] = error.reason
      } catch {
        analyzerUnavailableReasons["trace-summary@1"] =
          ArkTraceSummaryProfileError.descriptorInvalid.reason
        analyzerUnavailableReasons["trace-analysis@1"] =
          ArkTraceSummaryProfileError.descriptorInvalid.reason
      }
    } else {
      analyzerUnavailableReasons["trace-summary@1"] =
        ArkTraceSummaryProfileError.notFound.reason
      analyzerUnavailableReasons["trace-analysis@1"] =
        ArkTraceSummaryProfileError.notFound.reason
    }
    let workspaceProvider = WorkspaceProvider(
      registry: WorkspaceProjectRegistry(roots: workspaceRoots),
      tool: workspaceTool, operations: workspaceOperations)
    if workspaceOperationResolver != nil {
      print(
        "workspace ProjectProfiles ready for "
          + resolvedWorkspaceProfiles.map(\.projectRef).joined(separator: ","))
      fflush(stdout)
    }

    // Registered with no profiles until a host declares them: the analyzer
    // operations then report UNAVAILABLE with a machine-readable reason
    // instead of being absent from `operation.list` (PRODUCT-LOOP §8,
    // CHG-2026-055 TASK-HFA-007).
    let analyzerProvider = try AnalyzerProvider(
      profiles: analyzerProfiles,
      unavailableReasons: analyzerUnavailableReasons)
    var analyzerDispatcher: DescriptorBoundProcessDispatcher?
    if !analyzerProfiles.isEmpty {
      analyzerDispatcher = DescriptorBoundProcessDispatcher(
        resolver: try AnalyzerExecutableResolver(profiles: analyzerProfiles))
    }
    let dispatcher = RuntimeProcessDispatcherRouter(
      hdc: hdcDispatcher, rockchip: rockchipDispatcher, workspace: workspaceDispatcher,
      analyzer: analyzerDispatcher)
    let artifactStore = try RuntimeArtifactStore(
      rootURL: resolvedStateDirectory.appending(path: "artifacts", directoryHint: .isDirectory),
      nowUTC: utcNow)
    // Historical authority records remain mounted read-only for versioned
    // decode/export. New admission never reserves or consumes this ledger.
    let usageRoot = try FileManager.default.url(
      for: .applicationSupportDirectory, in: .userDomainMask,
      appropriateFor: nil, create: true
    )
    .appending(path: "ArkDeck", directoryHint: .isDirectory)
    .appending(path: "AuthorizationUsage", directoryHint: .isDirectory)
    // The ArkForge lane. Absent unless an operator installed one validated
    // release bundle, and absence is written to the log with what it means for
    // the product — a daemon with no lane and a daemon that failed to build one
    // look identical from outside, and only one of them is a problem.
    let arkForgeRuntimeDirectory =
      resolvedStateDirectory
      .appending(path: "arkforge", directoryHint: .isDirectory)
    try? FileManager.default.createDirectory(
      at: arkForgeRuntimeDirectory, withIntermediateDirectories: true,
      attributes: [.posixPermissions: 0o700])
    let arkForgeLane: ArkForgeLaneHost?
    // Both or neither, from one composition. A profile id paired with a lane
    // it was not composed with is a lane that could materialize against a
    // profile this daemon never loaded.
    let arkForgeDeviceProfileID: String?
    let arkForgeAvailability: ProviderOperationAvailability
    let authorityImplementationSHA256: String
    if let executableURL = Bundle.main.executableURL,
      let resolver = try? FixedExecutableResolver.hashing(
        path: executableURL.path, providerID: "arkdeck-agentd-authority"),
      let resolved = try? resolver.resolveExecutable(providerID: "arkdeck-agentd-authority")
    {
      authorityImplementationSHA256 = resolved.sha256
    } else {
      // Composition below turns this into lane unavailability. Other providers
      // remain usable, but no ArkForge authority key is invented for an
      // executable this process could not identify and measure.
      authorityImplementationSHA256 = ""
    }
    switch await ArkForgeLaneComposition.composeFromEnvironment(
      runtimeDirectory: arkForgeRuntimeDirectory,
      rockchipDispatcher: rockchipDispatcher,
      providerIdentity: (try? rockchipResolver.resolveExecutable(providerID: "rockchip"))
        ?? ResolvedExecutable(path: "-", sha256: String(repeating: "0", count: 64)),
      authorityImplementationSHA256: authorityImplementationSHA256,
      managedControlToolSHA256: executableSHA,
      approvedPlan: { jobID, planID, planDigest, deviceBinding in
        // The plan facts this authority signs against.
        //
        // These were empty until 2026-08-17, which made the authority unable to
        // match any admission `arkforged` ever sent: the digest comparison is
        // exact, so an empty approved digest refuses every real one and no
        // permit is ever signed. Nothing had been written to a board because of
        // it. They are the materialized plan's own facts, taken from the
        // `materializePlan` reply and the binding the engine confirmed.
        //
        ArkForgeExecutionAuthority.ApprovedPlan(
          jobID: jobID, planID: planID, planSHA256: planDigest,
          admittedDeviceFactsSHA256: ArkForgeLaneHost.digestBytes(
            deviceBinding.stableIdentitySHA256) ?? [],
          binding: ArkForgeAuthorityBinding(
            authorityNamespace: "arkdeck", bindingID: deviceBinding.targetID,
            bindingRevision: UInt64(max(0, deviceBinding.bindingRevision)),
            stableIdentityDigest: ArkForgeLaneHost.digestBytes(
              deviceBinding.stableIdentitySHA256) ?? []),
          controllerSessionID: "arkdeck-agentd", usbTopology: deviceBinding.usbTopology)
      }
    ) {
    case .success(let composed):
      arkForgeLane = composed.lane
      arkForgeDeviceProfileID = composed.deviceProfileID
      arkForgeAvailability = composed.operationAvailability
      startedArkForgeDaemon = composed.daemonLifecycle
      FileHandle.standardError.write(
        Data("arkforge lane: composed for \(composed.deviceProfileID)\n".utf8))
      if case .unavailable(_, let reason) = arkForgeAvailability {
        FileHandle.standardError.write(Data("arkforge Flash: \(reason)\n".utf8))
      }
    case .failure(let absence):
      arkForgeLane = nil
      arkForgeDeviceProfileID = nil
      arkForgeAvailability = .unavailable(
        code: .providerToolUnavailable, reason: absence.description)
      startedArkForgeDaemon = nil
      FileHandle.standardError.write(Data("\(absence)\n".utf8))
    }

    // Catalog presence is not runtime availability. The native daemon and its
    // controller lane are one startup composition. Both a failed composition
    // and a connected but hardware-gated lane must refuse before admission.
    // The canonical operation and its compatibility alias use this same fact.
    let arkForgeProvider = ArkForgeFlashProviderAdapter(
      factsPort: rockchipFactsPort, availability: arkForgeAvailability)
    let providers = DeviceProviderRegistry(providers: [
      hdcProvider, arkForgeProvider, workspaceProvider, analyzerProvider,
    ])

    let engine = try RuntimeJobEngine(
      configuration: .init(
        stateDirectory: resolvedStateDirectory, arkForgeLane: arkForgeLane,
        arkForgeDeviceProfileID: arkForgeDeviceProfileID),
      providers: providers,
      dispatcher: dispatcher,
      capabilityStore: capabilityStore,
      artifactStore: artifactStore,
      workspaceProjectStore: workspaceProjectStore,
      traceRuntimeProbe: traceRuntimeProbe,
      powerActivityController: PowerActivityController(),
      agentUsageLedger: try AgentAuthorityUsageLedger(root: usageRoot),
      nowUTC: utcNow, nowPreciseUTC: utcNowPrecise)
    // The engine is the reference ledger for sweep testimony; it exists
    // only now, so the handle the dispatcher already holds is filled here.
    workspaceReferenceLedger.install(engine)
    let debugInvocationController = try RuntimeDebugInvocationController(
      stateDirectory: resolvedStateDirectory,
      driver: RuntimeJobEngineDebugAttemptDriver(engine: engine),
      nowUTC: utcNow)
    let bootstrapObservation = ProviderBootstrapObservation(
      provider: hdcProvider, dispatcher: hdcDispatcher)
    let bootstrap = DeviceBootstrapMachine(
      observation: bootstrapObservation,
      targetStore: targetStore,
      nowUTC: utcNow)
    let targetObservations = TargetObservationCoordinator(
      observation: bootstrapObservation, targetStore: targetStore,
      usbRelations: { try TargetUSBRelation.registeredDAYU200() }, nowUTC: utcNow)
    let agentExecutions = try RuntimeAgentExecutionCoordinator(
      directory: resolvedStateDirectory.appending(path: "agent-executions"), engine: engine,
      targets: targetStore, observations: targetObservations)
    let hdcImpactSource = startedHDCServerHost.map { host in
      host.controlImpactSource(
        engine: engine, targets: targetStore, observations: targetObservations)
    }
    let hdcControlActions = try startedHDCServerHost.map { host in
      try RuntimeHDCControlActionCoordinator(directory: resolvedStateDirectory.appending(path: "hdc-control-actions"),
        source: hdcImpactSource!,
        lifecycleDriver: host.controlLifecycleDriver(
          engine: engine, targets: targetStore, observations: targetObservations),
        catalogDigest: RuntimeOperationCatalog.catalogDigest)
    }
    let toolSelectionActions = try {
      guard let host = startedHDCServerHost,
        let hdcImpactSource, let toolSelectionRegistry
      else { return Optional<RuntimeToolSelectionControlActionCoordinator>.none }
      let lifecycle = host.toolSelectionLifecycleDriver(
        engine: engine, registry: toolSelectionRegistry,
        requestDaemonRecomposition: {
          DispatchQueue.global().asyncAfter(deadline: .now() + .milliseconds(250)) {
            Darwin.exit(70)
          }
        })
      return try RuntimeToolSelectionControlActionCoordinator(
        directory: resolvedStateDirectory.appending(path: "tool-selection-control-actions"),
        hdcSource: hdcImpactSource, registry: toolSelectionRegistry,
        lifecycle: lifecycle, catalogDigest: RuntimeOperationCatalog.catalogDigest)
    }()
    let controlActions = try RuntimeControlActionResourceCoordinator(
      directory: resolvedStateDirectory.appending(path: "control-action-snapshots"),
      hdc: hdcControlActions, tools: toolSelectionActions)
    let humanActionResources = try RuntimeHumanActionResourceCoordinator(
      directory: resolvedStateDirectory.appending(path: "human-action-snapshots"),
      agents: agentExecutions, controlResources: controlActions)
    // HDC 3.2 has no public target event stream. The daemon therefore owns a
    // continuous read-only observation loop and lets App launches consume its
    // last completed, timestamped snapshot without joining an HDC command.
    await bootstrap.startCandidateMonitoring()
    let recovered = try await engine.recoverActiveJobs()
    if !recovered.isEmpty {
      print("recovered \(recovered.count) active job(s); unknown outcomes parked")
      fflush(stdout)
    }
    // `collectGarbage` had no production caller at all, so expired Artifacts
    // were never reclaimed and the store grew monotonically into its quota with
    // no in-product way back. Startup is where the active set is known exactly:
    // nothing has been submitted yet, so anything outside the recovered set is
    // terminal. Recovered jobs are passed through as active, which is the
    // conservative direction — the collector keeps what it is unsure about, and
    // it already refuses to touch pinned evidence.
    //
    // A failure here must not stop the daemon from serving, but it is not
    // swallowed either: an un-reclaimable store is exactly what this call
    // exists to make visible before the quota wall is hit.
    do {
      let reclaimed = try await artifactStore.collectGarbage(
        activeJobIDs: Set(recovered.map(\.jobID)), nowUTC: utcNow())
      if !reclaimed.isEmpty {
        print("reclaimed \(reclaimed.count) expired artifact(s)")
        fflush(stdout)
      }
    } catch {
      print("artifact retention sweep failed; the store may approach its quota: \(error)")
      fflush(stdout)
    }
    // The App's first device row includes the last verified model, firmware
    // and transport. Pay the bounded SQLite history read once while the
    // long-lived daemon starts, then keep the engine's compact observation
    // cache current as new observe.device Jobs succeed.
    _ = try? await engine.latestSucceededDeviceObservations()
    if let recovery = startupLoaderBindingRecovery,
      let pendingJobID = try await engine.loaderTransitionAwaitingBinding(
        targetID: recovery.targetID,
        expectedBindingRevision: recovery.proof.previousRevision)
    {
      _ = try await engine.settleLoaderTransitionAfterBinding(
        jobID: pendingJobID,
        targetID: recovery.targetID,
        previousBindingRevision: recovery.proof.previousRevision,
        currentBindingRevision: recovery.proof.currentRevision,
        selectionEvidenceSHA256: recovery.proof.selectionEvidenceSHA256)
      print(
        "settled recovered Loader transition \(pendingJobID) without replay at binding revision "
          + "\(recovery.proof.currentRevision)")
      fflush(stdout)
    }
    // `ARKDECK_HARNESS_*` is a retired namespace, not a list of retired keys.
    // The in-process task plane went with CHG-2026-064 and the model keys went
    // with `arkdeck agent chat`; nothing in this repository reads the prefix
    // any more. Rejecting by prefix rather than by roster is what makes that
    // true rather than merely current — a host still carrying a key nobody
    // remembered to enumerate fails loud instead of starting up with a stale
    // model credential in the environment of every process the daemon spawns.
    let removedHarnessKeys = ProcessInfo.processInfo.environment.keys.filter {
      $0.hasPrefix("ARKDECK_HARNESS_")
    }
    guard removedHarnessKeys.isEmpty else {
      FileHandle.standardError.write(
        Data(
          ("arkdeck-agentd: retired configuration is still set: "
            + removedHarnessKeys.sorted().joined(separator: ",")
            + "; run `arkdeck runtime service update` to regenerate the LaunchAgent plist\n")
            .utf8))
      exit(78)  // EX_CONFIG
    }
    /// The production lane plan previewer (CHG-2026-068): resolves the bound
    /// target's confirmed HDC-normal port path from the same provider facts
    /// the engine dispatches with, then asks the composed lane for a
    /// read-only pre-materialization. Only built when a lane and its
    /// DeviceProfile id were composed together — a preview against a profile
    /// the daemon never loaded would be an answer about nothing.
    struct ComposedLanePlanPreviewer: FlashLanePlanPreviewing {
      let lane: ArkForgeLaneHost
      let profileID: String
      let providers: DeviceProviderRegistry

      func preview(
        targetID: String, profileReference _: String, archiveSHA256: String
      ) async -> ArkForgeLanePlanPreviewOutcome {
        let facts: ProviderFacts
        do {
          facts = try await providers.resolveFacts(
            providerID: CatalogProvider.arkforge.rawValue, targetID: targetID)
        } catch {
          return .deviceNotObserved("target facts could not be resolved: \(error)")
        }
        guard
          let topology = facts.serverFacts[
            TargetStoreRockchipRuntimeFactsPort.hdcAliasTopologyServerFactKey],
          !topology.isEmpty
        else {
          return .deviceNotObserved(
            "no confirmed HDC-normal USB topology for \(targetID)")
        }
        return await lane.previewPlan(
          archiveSHA256: archiveSHA256, profileID: profileID, usbTopology: topology)
      }
    }
    let lanePlanPreviewer: (any FlashLanePlanPreviewing)? = arkForgeLane.flatMap { lane in
      arkForgeDeviceProfileID.map { profileID in
        ComposedLanePlanPreviewer(lane: lane, profileID: profileID, providers: providers)
      }
    }
    let historyFilterStore = RuntimeHistoryFilterStore(rootURL: resolvedStateDirectory)
    let runtimeSessionStorage = try RuntimeSessionStorageStore(
      ownerRoot: resolvedStateDirectory,
      defaultSessionsRoot: rockchipRoot.appending(
        path: "Sessions", directoryHint: .isDirectory))
    let traceCacheDirectory =
      resolvedStateDirectory.standardizedFileURL == defaultStateDirectory.standardizedFileURL
      ? ArkDeckTraceConfiguration.appContainerCachesDirectory()
      : resolvedStateDirectory.appending(
        path: "app-container-caches", directoryHint: .isDirectory)
    let traceCacheMaintenance = ProductTraceCacheMaintenance(
      service: try ArkDeckTraceCacheMaintenanceService(
        cachesDirectory: traceCacheDirectory))
    let traceInspector = try analyzerProfiles.first(where: {
      $0.analyzerRef == "trace-summary@1"
    }).map {
      try ProductTraceOfflineInspector(
        profile: $0,
        workingDirectory: resolvedStateDirectory.appending(
          path: "trace-inspection", directoryHint: .isDirectory))
    }
    let handler = RuntimeControlPlaneHandler(
      engine: engine,
      capabilityStore: capabilityStore,
      providerIDs: providers.registeredProviderIDs,
      nowUTC: utcNow,
      targetStore: targetStore,
      bootstrap: bootstrap,
      targetObservations: targetObservations,
      agentExecutions: agentExecutions,
      humanActionResources: humanActionResources,
      hdcRuntimeDiagnostics: startedHDCServerHost?.diagnostics,
      hdcStatusObserver: startedHDCServerHost?.statusObserver(
        daemonVersion: Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String),
      hdcControlActions: hdcControlActions,
      toolSelectionActions: toolSelectionActions,
      controlActions: controlActions,
      artifactStore: artifactStore,
      historyFilterStore: historyFilterStore,
      runtimeSessionStorage: runtimeSessionStorage,
      traceCacheMaintenance: traceCacheMaintenance,
      traceInspector: traceInspector,
      flashBundleImportDirectory: resolvedStateDirectory.appending(
        path:
          "flash-bundle-imports", directoryHint: .isDirectory),
      flashPrerequisiteObserver: rockchipFactsPort,
      flashLanePlanPreviewer: lanePlanPreviewer,
      rockchipBootloaderStatusObserver: ProductRockchipBootloaderStatusObserver(
        targetStore: targetStore, applicationSupportRoot: rockchipRoot),
      rockchipDeviceAccessObserver: ProductRockchipDeviceAccessObserver(
        runtimeDirectory: arkForgeRuntimeDirectory),
      rockchipLoaderBindingCoordinator: ProductRockchipLoaderBindingCoordinator(
        targetStore: targetStore, applicationSupportRoot: rockchipRoot),
      traceRuntimeProbe: traceRuntimeProbe,
      debugRuntimeProbe: debugRuntimeProbe,
      debugInvocationController: debugInvocationController,
      workspaceProjects: workspaceProjectPublications)
    let server = AgentDaemonServer(
      stateDirectory: resolvedStateDirectory, handler: handler, nowUTC: utcNow)
    switch try server.start() {
    case .started:
      startedServer = server
      print("arkdeck-agentd listening on \(server.socketURL.path)")
      // Second transport, strictly narrower: read-only frames only, for App
      // Sandbox clients that cannot reach an AF_UNIX path at all. When this
      // daemon was not started by launchd there is no Mach service to check
      // in to, which is the normal CLI and CI configuration; the Unix socket
      // above is unaffected either way.
      let xpcListener = AgentXPCListener(handler: handler)
      xpcListener.activate()
      startedXPCListener = xpcListener
      print(
        "arkdeck-agentd read-only XPC door: \(AgentXPCListener.machServiceName) "
          + "(active only when launchd vends the Mach service)")
      // Redirected stdout is block-buffered: without this flush an operator
      // tailing the log sees nothing until the daemon exits.
      fflush(stdout)
    case .alreadyRunning(let instance):
      // This candidate may have started a foreground HDC child before the
      // instance lock proved that another daemon already owns the session.
      // Release only this candidate's process group before the process exits;
      // the serving daemon keeps ownership of its own server.
      await startedHDCServerHost?.stop()
      startedHDCServerHost = nil
      startedArkForgeDaemon?.stop()
      startedArkForgeDaemon = nil
      print(
        "arkdeck-agentd already running: pid \(instance.pid), socket \(instance.socketPath), "
          + "protocol \(instance.protocolVersion)")
      fflush(stdout)
    }
  } catch {
    // Starting HDC precedes several fallible composition and UDS steps. A
    // failed daemon startup must not orphan that foreground process group.
    await startedHDCServerHost?.stop()
    startedHDCServerHost = nil
    startedArkForgeDaemon?.stop()
    startedArkForgeDaemon = nil
    startupFailure = error
  }
}

ready.wait()

if let startupFailure {
  FileHandle.standardError.write(Data("arkdeck-agentd failed to start: \(startupFailure)\n".utf8))
  exit(1)
}
guard let server = startedServer else {
  // Second instance: the existing one keeps serving.
  exit(0)
}

signal(SIGINT, SIG_IGN)
signal(SIGTERM, SIG_IGN)
let shutdownLock = NSLock()
var shutdownStarted = false
let signalSources = [SIGTERM, SIGINT].map { signalNumber -> DispatchSourceSignal in
  let source = DispatchSource.makeSignalSource(signal: signalNumber, queue: .main)
  source.setEventHandler {
    shutdownLock.lock()
    let shouldStart = !shutdownStarted
    shutdownStarted = true
    shutdownLock.unlock()
    guard shouldStart else { return }
    Task.detached {
      // Do not release the instance lock or terminate while a request still
      // owns a Runtime durability boundary.  The 20-second cap is explicit:
      // an unresponsive client cannot block macOS service shutdown forever.
      server.drainAndStop(deadline: 20)
      startedArkForgeDaemon?.stop()
      startedArkForgeDaemon = nil
      await startedHDCServerHost?.stop()
      print("arkdeck-agentd stopped")
      fflush(stdout)
      exit(0)
    }
  }
  source.resume()
  return source
}
_ = signalSources
dispatchMain()
