// arkdeck-agentd executable entry point (CHG-2026-047, T07).
//
// Production composition root: state under the user's Application Support,
// production providers registered, zero network. `--state-dir` exists for
// tests and never widens permissions.

import ArkDeckAgentDaemon
import ArkDeckStorage
import ArkDeckWorkflows
import Darwin
import Foundation

func utcNow() -> String {
  let formatter = DateFormatter()
  formatter.dateFormat = "yyyy-MM-dd'T'HH:mm:ss'Z'"
  formatter.timeZone = TimeZone(identifier: "UTC")
  formatter.locale = Locale(identifier: "en_US_POSIX")
  return formatter.string(from: Date())
}

var stateDirectory = FileManager.default.urls(
  for: .applicationSupportDirectory, in: .userDomainMask
)[0].appendingPathComponent("ArkDeck/Agentd", isDirectory: true)

var arguments = CommandLine.arguments.dropFirst()
while let argument = arguments.first {
  arguments = arguments.dropFirst()
  switch argument {
  case "--state-dir":
    guard let value = arguments.first else {
      FileHandle.standardError.write(Data("--state-dir requires a path\n".utf8))
      exit(64)
    }
    stateDirectory = URL(fileURLWithPath: value, isDirectory: true)
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
    guard let record = try targetStore.find(targetID: targetID) else {
      throw DeviceProviderError.factsUnavailable("target \(targetID) has not been adopted")
    }
    return ProviderFacts(
      providerID: "hdc",
      toolVersion: record.toolVersion,
      toolSHA256: executableSHA256,
      serverFacts: [:],
      targetID: record.targetID,
      bindingRevision: record.bindingRevision,
      deviceIdentitySHA256: record.stablePhysicalIdentitySHA256,
      executionConnectKey: record.connectKey,
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

/// Bootstrap observation over the descriptor-bound dispatcher: the only
/// four actions bootstrap can express, each verified by the provider's
/// semantic parser.
struct ProviderBootstrapObservation: BootstrapObservationPort {
  let provider: HDCObservationProviderAdapter
  let dispatcher: any RuntimeProcessDispatching

  private func run(_ action: HDCProviderAction) async throws -> ProviderSemanticOutcome {
    let context = ProviderExecutionContext(
      jobID: "bootstrap", stepID: "observe", targetID: "-", bindingRevision: nil,
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

// Detached on purpose: the top level is @MainActor-isolated, so a plain
// `Task { }` would inherit the main actor and deadlock against the
// semaphore wait below.
Task.detached {
  defer { ready.signal() }
  do {
    let capabilityStore = try RuntimeCapabilityStore(
      directoryURL: resolvedStateDirectory.appendingPathComponent("capabilities", isDirectory: true)
    )
    let targetStore = try RuntimeTargetStore(
      directoryURL: resolvedStateDirectory.appendingPathComponent("targets", isDirectory: true))

    // The HDC executable is supplied explicitly (no PATH search, no guess):
    // absent configuration means dispatch stays refused, never degraded.
    let configuredHDC = ProcessInfo.processInfo.environment["ARKDECK_HDC_PATH"]
    var hdcDispatcher: any RuntimeProcessDispatching = RefusingDispatcher(
      reason: "no HDC executable configured (set ARKDECK_HDC_PATH); dispatch stays fail-closed")
    var hdcExecutableResolver: (any RuntimeExecutableResolving)?
    var executableSHA = ""
    if let configuredHDC {
      let resolver = try FixedExecutableResolver.hashing(path: configuredHDC, providerID: "hdc")
      executableSHA = try resolver.resolveExecutable(providerID: "hdc").sha256
      hdcExecutableResolver = resolver
      hdcDispatcher = DescriptorBoundProcessDispatcher(resolver: resolver)
    }

    let hdcProvider = HDCObservationProviderAdapter(
      factsPort: TargetStoreFactsPort(
        targetStore: targetStore, executablePath: configuredHDC ?? "-",
        executableSHA256: executableSHA))
    let rockchipResolver = BundledRockchipExecutableResolver()
    let rockchipDispatcher: BundledRockchipRuntimeDispatcher
    if let hdcExecutableResolver {
      rockchipDispatcher = BundledRockchipRuntimeDispatcher(
        resolver: rockchipResolver,
        hdcResolver: hdcExecutableResolver,
        stateDirectory: resolvedStateDirectory)
    } else {
      rockchipDispatcher = BundledRockchipRuntimeDispatcher(
        resolver: rockchipResolver)
    }
    let rockchipProvider = RockchipFlashProviderAdapter(
      factsPort: TargetStoreRockchipRuntimeFactsPort(
        targetStore: targetStore, resolver: rockchipResolver, nowUTC: utcNow),
      // The closed typed plan is present. Executable/HDC/state availability
      // belongs to the live dispatcher so an installed product component can
      // become visible without caching a startup-only rejection.
      availability: .available)
    // Host-only workspace provider (CHG-2026-054 TASK-HTP-007/005). Project
    // roots and the optional inspector are explicit configuration; operation
    // presets come from the built-in ProjectProfile. Missing pieces report
    // unavailable, so nothing is admitted and no capability is consumed.
    //   ARKDECK_WORKSPACE_INSPECTOR=/usr/bin/grep
    //   ARKDECK_WORKSPACE_PROJECTS=demo-app=/abs/path,other=/abs/other
    let workspaceRoots = Dictionary(
      uniqueKeysWithValues:
        (ProcessInfo.processInfo.environment["ARKDECK_WORKSPACE_PROJECTS"] ?? "")
        .split(separator: ",")
        .compactMap { entry -> (String, String)? in
          let parts = entry.split(separator: "=", maxSplits: 1).map {
            $0.trimmingCharacters(in: .whitespaces)
          }
          guard parts.count == 2, !parts[0].isEmpty, parts[1].hasPrefix("/") else { return nil }
          return (parts[0], parts[1])
        })
    let configuredInspector = ProcessInfo.processInfo.environment["ARKDECK_WORKSPACE_INSPECTOR"]
    var workspaceTool: WorkspaceInspectorTool?
    var inspectorExecutable: ResolvedExecutable?
    var workspaceDispatcher: any RuntimeProcessDispatching = RefusingDispatcher(
      reason: "no workspace ProjectProfile is configured")
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
    if let arkDeckRoot = workspaceRoots["ArkDeck"] {
      do {
        let profile = try WorkspaceProjectProfile.arkDeck(
          rootURL: URL(fileURLWithPath: arkDeckRoot, isDirectory: true))
        let attempts = try WorkspacePatchAttemptStore(
          rootURL: resolvedStateDirectory.appendingPathComponent(
            "workspace-patch-attempts", isDirectory: true))
        workspaceOperations = WorkspaceOperationsProvider(
          profile: profile, attemptStore: attempts, nowUTC: utcNow)
        workspaceOperationResolver = WorkspaceActionExecutableResolver(profile: profile)
      } catch {
        workspaceOperations = UnavailableWorkspaceOperationsProvider(
          reason: "workspace.projectProfileUnavailable:\(error)")
      }
    } else {
      workspaceOperations = UnavailableWorkspaceOperationsProvider(
        reason: "workspace.projectProfileUnavailable:ArkDeck is not registered")
    }
    if let workspaceOperationResolver {
      workspaceDispatcher = DescriptorBoundProcessDispatcher(
        resolver: CombinedWorkspaceExecutableResolver(
          inspector: inspectorExecutable, operations: workspaceOperationResolver))
    } else if let inspectorExecutable {
      workspaceDispatcher = DescriptorBoundProcessDispatcher(
        resolver: FixedExecutableResolver(
          table: ["workspace": inspectorExecutable]))
    }
    let workspaceProvider = WorkspaceProvider(
      registry: WorkspaceProjectRegistry(roots: workspaceRoots),
      tool: workspaceTool, operations: workspaceOperations)
    if workspaceOperationResolver != nil {
      print(
        "workspace ProjectProfile ready for ArkDeck")
      fflush(stdout)
    }

    let providers = DeviceProviderRegistry(providers: [
      hdcProvider, rockchipProvider, workspaceProvider,
    ])
    let dispatcher = RuntimeProcessDispatcherRouter(
      hdc: hdcDispatcher, rockchip: rockchipDispatcher, workspace: workspaceDispatcher)
    let artifactStore = try RuntimeArtifactStore(
      rootURL: resolvedStateDirectory.appendingPathComponent("artifacts", isDirectory: true),
      nowUTC: utcNow)
    let engine = try RuntimeJobEngine(
      configuration: .init(stateDirectory: resolvedStateDirectory),
      providers: providers,
      dispatcher: dispatcher,
      capabilityStore: capabilityStore,
      artifactStore: artifactStore,
      nowUTC: utcNow)
    let bootstrap = DeviceBootstrapMachine(
      observation: ProviderBootstrapObservation(
        provider: hdcProvider, dispatcher: hdcDispatcher),
      targetStore: targetStore,
      nowUTC: utcNow)
    let recovered = try await engine.recoverPersistedJobs()
    if !recovered.isEmpty {
      print("recovered \(recovered.count) persisted job(s); unknown outcomes parked")
      fflush(stdout)
    }
    // Harness task plane (CHG-2026-054): one composition root, not a second
    // daemon. It reaches execution only through the engine port below.
    let harnessStore = try HarnessTaskStore(
      rootURL: resolvedStateDirectory.appendingPathComponent("harness", isDirectory: true))
    // Model egress is opt-in per project and off unless the operator names
    // them: `ARKDECK_HARNESS_EGRESS_PROJECTS=app-a,app-b`. With none named no
    // decision context leaves this host and the loop runs on the built-in
    // deterministic handler (CHG-2026-054 HTP-INV-10).
    let egressProjects = Set(
      (ProcessInfo.processInfo.environment["ARKDECK_HARNESS_EGRESS_PROJECTS"] ?? "")
        .split(separator: ",")
        .map { $0.trimmingCharacters(in: .whitespaces) }
        .filter { !$0.isEmpty })
    let sensitiveEvidence = Set(
      (ProcessInfo.processInfo.environment["ARKDECK_HARNESS_SENSITIVE_EVIDENCE"] ?? "")
        .split(separator: ",")
        .map { $0.trimmingCharacters(in: .whitespaces) }
        .filter { !$0.isEmpty })
    if !sensitiveEvidence.isEmpty {
      print(
        "harness may measure sensitive evidence: "
          + sensitiveEvidence.sorted().joined(separator: ","))
      fflush(stdout)
    }
    if !egressProjects.isEmpty {
      print("harness decision egress enabled for \(egressProjects.sorted().joined(separator: ","))")
      fflush(stdout)
    }
    let harness = HarnessTaskCoordinator(
      store: harnessStore,
      jobPort: RuntimeJobEngineHarnessPort(engine: engine),
      // Evidence access is what makes a verdict possible at all; without it
      // the loop stops honestly instead of guessing (CHG-2026-054 TASK-HTP-002).
      artifactPort: RuntimeArtifactStoreHarnessPort(store: artifactStore),
      nowUTC: utcNow,
      policyGuard: HarnessPolicyGuard(
        availability: RuntimeEngineAvailabilityPort(engine: engine),
        capabilities: RuntimeCapabilityStoreHarnessPort(
          store: capabilityStore, nowUTC: utcNow)),
      // No adapter ships in this composition yet: the port exists, and a
      // model-backed producer is configured by whoever supplies one.
      decisionGateway: nil,
      egressPolicy: HarnessEgressPolicy(enabledProjects: egressProjects),
      // Privacy-sensitive evidence the operator allows this run to measure,
      // by artifact name: `ARKDECK_HARNESS_SENSITIVE_EVIDENCE=hilog.txt`.
      // With none named the evaluator reports every sensitive artifact as a
      // collection blocker instead of reading it, which is why a crash task
      // whose criteria require `hilog.txt` cannot be judged at all until an
      // operator says it may be (TASK-HTP-006).
      sensitiveEvidenceAllowList: sensitiveEvidence)
    // Recovery resolves dispatch intents whose outcome was lost; it starts
    // no new work, so a restart cannot become a burst of dispatches.
    let recoveredTasks = try await harness.recoverTasks()
    if !recoveredTasks.isEmpty {
      print("recovered \(recoveredTasks.count) harness task dispatch intent(s)")
      fflush(stdout)
    }
    let handler = RuntimeControlPlaneHandler(
      engine: engine,
      capabilityStore: capabilityStore,
      providerIDs: providers.registeredProviderIDs,
      nowUTC: utcNow,
      targetStore: targetStore,
      bootstrap: bootstrap,
      artifactStore: artifactStore,
      flashBundleImportDirectory: resolvedStateDirectory.appendingPathComponent(
        "flash-bundle-imports", isDirectory: true),
      harnessCoordinator: harness)
    let server = AgentDaemonServer(
      stateDirectory: resolvedStateDirectory, handler: handler, nowUTC: utcNow)
    switch try server.start() {
    case .started:
      startedServer = server
      print("arkdeck-agentd listening on \(server.socketURL.path)")
      // Redirected stdout is block-buffered: without this flush an operator
      // tailing the log sees nothing until the daemon exits.
      fflush(stdout)
      // Auto-drive turns the harness crank so a single `task.submit`
      // converges without anyone poking `task.reconcile`. Off unless the
      // operator sets an interval: a daemon that dispatches on a timer is a
      // different posture from one that only answers requests, and that is
      // the operator's call, not a default (TASK-HTP-006).
      if let interval = HarnessAutoDriveTicker.configuredIntervalSeconds(
        ProcessInfo.processInfo.environment)
      {
        print("harness auto-drive every \(interval)s")
        fflush(stdout)
        let ticker = HarnessAutoDriveTicker(
          target: harness, intervalSeconds: interval,
          log: { message in
            print(message)
            fflush(stdout)
          })
        // Started only after the socket is serving, so a failure to bind
        // cannot leave a timer dispatching against a daemon nobody can reach.
        Task.detached { await ticker.run() }
      }
    case .alreadyRunning(let instance):
      print(
        "arkdeck-agentd already running: pid \(instance.pid), socket \(instance.socketPath), "
          + "protocol \(instance.protocolVersion)")
      fflush(stdout)
    }
  } catch {
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
let signalSources = [SIGTERM, SIGINT].map { signalNumber -> DispatchSourceSignal in
  let source = DispatchSource.makeSignalSource(signal: signalNumber, queue: .main)
  source.setEventHandler {
    server.stop()
    print("arkdeck-agentd stopped")
    fflush(stdout)
    exit(0)
  }
  source.resume()
  return source
}
_ = signalSources
dispatchMain()
