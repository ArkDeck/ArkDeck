// arkdeck-agentd executable entry point (CHG-2026-047, T07).
//
// Production composition root: state under the user's Application Support,
// production providers registered, zero network. `--state-dir` exists for
// tests and never widens permissions.

import ArkDeckAgentComposition
import ArkDeckAgentDaemon
import ArkDeckCore
import ArkDeckRuntime
import ArkDeckStorage
import ArkDeckWorkflows
import Darwin
import Foundation

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
    if let configuredHDC {
      let resolver = try FixedExecutableResolver.hashing(path: configuredHDC, providerID: "hdc")
      let resolvedHDC = try resolver.resolveExecutable(providerID: "hdc")
      executableSHA = resolvedHDC.sha256
      // The login-session daemon owns a foreground, loopback-only server.
      // This avoids depending on a Terminal parent or HDC's client-side
      // background daemonisation, and cancellation tears down the dedicated
      // process group during LaunchAgent update/uninstall.
      startedHDCServerHost = try await HeadlessHDCServerHost.start(
        executable: resolvedHDC,
        onUnexpectedExit: {
          // An unexpected server death is a daemon crash boundary: launchd
          // KeepAlive restarts the service, Runtime recovers durable Jobs, and
          // startup must re-establish typed HDC readiness before reopening UDS.
          Darwin.exit(70)
        })
      hdcExecutableResolver = resolver
      // Pointer injection is the one operation with an interaction budget, and
      // it is a single device command, so a spawned client costs a process
      // launch on top of the round trip that does the work. It is routed over
      // a shell that is already open; everything else keeps the spawning path
      // it has, including pointer injection whenever a channel cannot serve it.
      hdcDispatcher = PointerInputChannelDispatcher(
        fallback: DescriptorBoundProcessDispatcher.hdc(resolver: resolver),
        resolver: resolver)
      traceRuntimeProbe = FoundationTraceRuntimeProbe(
        targetStore: targetStore, hdcResolver: resolver,
        workingDirectory: resolvedStateDirectory)
      debugRuntimeProbe = FoundationDebugRuntimeProbe(
        targetStore: targetStore, hdcResolver: resolver,
        workingDirectory: resolvedStateDirectory)
    }

    let hdcProvider = HDCObservationProviderAdapter(
      factsPort: TargetStoreFactsPort(
        targetStore: targetStore, executablePath: configuredHDC ?? "-",
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
    let workspaceRoots = Dictionary(
      uniqueKeysWithValues: (ProcessInfo.processInfo.environment["ARKDECK_WORKSPACE_PROJECTS"] ?? "")
        .split(separator: ",")
        .compactMap { entry -> (String, String)? in
          let parts = entry.split(separator: "=", maxSplits: 1).map {
            $0.trimmingCharacters(in: .whitespaces)
          }
          guard parts.count == 2, !parts[0].isEmpty, parts[1].hasPrefix("/") else { return nil }
          return (parts[0], parts[1])
        })
    let configuredInspector = ProcessInfo.processInfo.environment["ARKDECK_WORKSPACE_INSPECTOR"]
    let signingPresetStore = OpenHarmonySigningPresetStore()
    let signingAttemptStore = try OpenHarmonySigningAttemptStore(
      rootURL: resolvedStateDirectory.appending(
        path:
          "workspace-signing-attempts", directoryHint: .isDirectory))
    var workspaceTool: WorkspaceInspectorTool?
    var inspectorExecutable: ResolvedExecutable?
    var workspaceDispatcher: any RuntimeProcessDispatching = RefusingDispatcher(
      reason: "no workspace ProjectProfile is configured")
    var workspaceChildEnvironment: [String: String] = [:]
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
    var workspaceRepairConfiguration:
      (
        profile: WorkspaceProjectProfile,
        profiles: WorkspaceProjectProfileRegistry,
        attempts: WorkspacePatchAttemptStore,
        evolution: EvolutionWorkspaceManager
      )?
    let configuredActiveProject =
      ProcessInfo.processInfo.environment["ARKDECK_WORKSPACE_ACTIVE_PROJECT"]
    let activeProjectRef =
      configuredActiveProject
      ?? (workspaceRoots.count == 1 ? workspaceRoots.keys.first : nil)
    if let activeProjectRef, let activeRoot = workspaceRoots[activeProjectRef] {
      do {
        let profile: WorkspaceProjectProfile
        switch activeProjectRef {
        case "ArkDeck":
          profile = try WorkspaceProjectProfile.arkDeck(
            rootURL: URL(filePath: activeRoot, directoryHint: .isDirectory))
        case "demo-app":
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
            path:
              "default/openharmony", directoryHint: .isDirectory)
          guard configuredSDK.hasPrefix("/"),
            FileManager.default.fileExists(
              atPath: openHarmonySDK.path, isDirectory: &sdkIsDirectory),
            sdkIsDirectory.boolValue
          else {
            throw DeviceProviderError.factsUnavailable(
              "workspace.projectProfileUnavailable: DevEco OpenHarmony SDK is absent")
          }
          profile = try WorkspaceProjectProfile.waterFlowDemo(
            rootURL: URL(filePath: activeRoot, directoryHint: .isDirectory),
            projectRef: activeProjectRef, nodePath: node, hvigorScriptPath: hvigor,
            symbolizerPath: ProcessInfo.processInfo.environment["ARKDECK_ANALYZER_PATH"])
          // Hvigor rejects a missing or stale inherited DEVECO_SDK_HOME with
          // configuration error 00303217. Pin the validated profile SDK on
          // this child route instead of depending on the daemon launcher.
          workspaceChildEnvironment = ["DEVECO_SDK_HOME": sdk.path]
        default:
          throw DeviceProviderError.factsUnavailable(
            "workspace.projectProfileUnavailable:\(activeProjectRef) is unsupported")
        }
        let attempts = try WorkspacePatchAttemptStore(
          rootURL: resolvedStateDirectory.appending(
            path:
              "workspace-patch-attempts", directoryHint: .isDirectory))
        let profiles = WorkspaceProjectProfileRegistry(profile: profile)
        let evolution = try EvolutionWorkspaceManager(
          rootURL: resolvedStateDirectory.appending(
            path:
              "evolution-workspaces", directoryHint: .isDirectory),
          profileRegistry: profiles,
          patchLineage: attempts)
        let unadoptedRuntimeWorkspaces = evolution.adoptRuntimeWorkspaces()
        for workspaceID in unadoptedRuntimeWorkspaces {
          print("runtime workspace not adopted for \(workspaceID)")
        }
        if !unadoptedRuntimeWorkspaces.isEmpty { fflush(stdout) }
        workspaceOperations = WorkspaceOperationsProvider(
          profile: profile, profileRegistry: profiles,
          attemptStore: attempts, signingPresetStore: signingPresetStore,
          signingAttemptStore: signingAttemptStore,
          isolationManager: evolution, nowUTC: utcNow)
        workspaceOperationResolver = WorkspaceActionExecutableResolver(profile: profile)
        workspaceRepairConfiguration = (profile, profiles, attempts, evolution)
      } catch {
        workspaceOperations = UnavailableWorkspaceOperationsProvider(
          reason: "workspace.projectProfileUnavailable:\(error)")
      }
    } else {
      workspaceOperations = UnavailableWorkspaceOperationsProvider(
        reason:
          "workspace.projectProfileUnavailable: select exactly one registered active project")
    }
    if let workspaceOperationResolver {
      workspaceDispatcher = DescriptorBoundProcessDispatcher(
        resolver: CombinedWorkspaceExecutableResolver(
          inspector: inspectorExecutable, operations: workspaceOperationResolver),
        childEnvironment: workspaceChildEnvironment)
    } else if let inspectorExecutable {
      workspaceDispatcher = DescriptorBoundProcessDispatcher(
        resolver: FixedExecutableResolver(
          table: ["workspace": inspectorExecutable]))
    }
    let workspaceReferenceLedger = WorkspaceReferenceLedgerHandle()
    if let evolution = workspaceRepairConfiguration?.evolution {
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
        "workspace ProjectProfile ready for \(activeProjectRef ?? "-")")
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
    let bootstrap = DeviceBootstrapMachine(
      observation: ProviderBootstrapObservation(
        provider: hdcProvider, dispatcher: hdcDispatcher),
      targetStore: targetStore,
      nowUTC: utcNow)
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
            + "; run `arkdeck agentd update` to regenerate the LaunchAgent plist\n").utf8))
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
    let handler = RuntimeControlPlaneHandler(
      engine: engine,
      capabilityStore: capabilityStore,
      providerIDs: providers.registeredProviderIDs,
      nowUTC: utcNow,
      targetStore: targetStore,
      bootstrap: bootstrap,
      hdcRuntimeDiagnostics: startedHDCServerHost?.diagnostics,
      artifactStore: artifactStore,
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
      debugInvocationController: debugInvocationController)
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
