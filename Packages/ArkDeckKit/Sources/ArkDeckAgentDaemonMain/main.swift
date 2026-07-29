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

/// Facts resolved from the adopted target record plus a live tool probe.
/// Full provider-side fact collection lands with the device window's
/// evidence; what the daemon needs today is the target's own identity.
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
      deviceIdentitySHA256: record.stablePhysicalIdentitySHA256,
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

do {
  let capabilityStore = try RuntimeCapabilityStore(
    directoryURL: stateDirectory.appendingPathComponent("capabilities", isDirectory: true))
  let targetStore = try RuntimeTargetStore(
    directoryURL: stateDirectory.appendingPathComponent("targets", isDirectory: true))

  // The HDC executable is supplied explicitly (no PATH search, no guess):
  // absent configuration means dispatch stays refused, never degraded.
  let configuredHDC = ProcessInfo.processInfo.environment["ARKDECK_HDC_PATH"]
  var dispatcher: any RuntimeProcessDispatching = RefusingDispatcher(
    reason: "no HDC executable configured (set ARKDECK_HDC_PATH); dispatch stays fail-closed")
  var executableSHA = ""
  if let configuredHDC {
    let resolver = try FixedExecutableResolver.hashing(path: configuredHDC, providerID: "hdc")
    executableSHA = try resolver.resolveExecutable(providerID: "hdc").sha256
    dispatcher = DescriptorBoundProcessDispatcher(resolver: resolver)
  }

  let provider = HDCObservationProviderAdapter(
    factsPort: TargetStoreFactsPort(
      targetStore: targetStore, executablePath: configuredHDC ?? "-",
      executableSHA256: executableSHA))
  let providers = DeviceProviderRegistry(providers: [provider])
  let engine = try RuntimeJobEngine(
    configuration: .init(stateDirectory: stateDirectory),
    providers: providers,
    dispatcher: dispatcher,
    capabilityStore: capabilityStore,
    nowUTC: utcNow)
  let bootstrap = DeviceBootstrapMachine(
    observation: ProviderBootstrapObservation(provider: provider, dispatcher: dispatcher),
    targetStore: targetStore,
    nowUTC: utcNow)
  let recovered = try await engine.recoverPersistedJobs()
  if !recovered.isEmpty {
    print("recovered \(recovered.count) persisted job(s); unknown outcomes parked")
    fflush(stdout)
  }
  let handler = RuntimeControlPlaneHandler(
    engine: engine,
    capabilityStore: capabilityStore,
    providerIDs: providers.registeredProviderIDs,
    nowUTC: utcNow,
    targetStore: targetStore,
    bootstrap: bootstrap)
  let server = AgentDaemonServer(
    stateDirectory: stateDirectory, handler: handler, nowUTC: utcNow)
  switch try server.start() {
  case .started:
    print("arkdeck-agentd listening on \(server.socketURL.path)")
    // Redirected stdout is block-buffered: without this flush an operator
    // tailing the log sees nothing until the daemon exits.
    fflush(stdout)
    signal(SIGINT, SIG_IGN)
    signal(SIGTERM, SIG_IGN)
    let signalSource = DispatchSource.makeSignalSource(signal: SIGTERM, queue: .global())
    signalSource.setEventHandler {
      server.stop()
      exit(0)
    }
    signalSource.resume()
    let interruptSource = DispatchSource.makeSignalSource(signal: SIGINT, queue: .global())
    interruptSource.setEventHandler {
      server.stop()
      exit(0)
    }
    interruptSource.resume()
    // Park the async main task forever. `dispatchMain()` cannot be used
    // here: this is an async top level, and dispatch_main() pthread_exits
    // the main thread out from under the Swift concurrency executor, so
    // the daemon printed "listening" and then died immediately. A parked
    // continuation would work but reports a leak on exit; sleeping keeps
    // the log clean. The signal handlers above are the only exit path.
    while true {
      try? await Task.sleep(nanoseconds: 3_600 * 1_000_000_000)
    }
  case .alreadyRunning(let instance):
    print(
      "arkdeck-agentd already running: pid \(instance.pid), socket \(instance.socketPath), "
        + "protocol \(instance.protocolVersion)")
    fflush(stdout)
    exit(0)
  }
} catch {
  FileHandle.standardError.write(Data("arkdeck-agentd failed to start: \(error)\n".utf8))
  exit(1)
}
