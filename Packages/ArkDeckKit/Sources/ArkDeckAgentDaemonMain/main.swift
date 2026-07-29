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

struct UnavailableFactsPort: HDCObservationFactsPort {
  func currentFacts(targetID: String) async throws -> ProviderFacts {
    throw DeviceProviderError.factsUnavailable(
      "production HDC facts composition arrives with the MU-3 walking skeleton")
  }
}

struct RefusingDispatcher: RuntimeProcessDispatching {
  // MU-2 production stance: the daemon accepts, journals and recovers
  // jobs, but real device dispatch is not wired until the MU-3 walking
  // skeleton binds the descriptor-verified executor. Refusing loudly is
  // fail-closed; nothing pretends to run.
  func dispatch(_ plan: TypedProcessPlan) async throws -> ProviderProcessReceipt {
    throw RuntimeDispatchFailure.failed(
      "device dispatch is not enabled in this build (arrives with MU-3)")
  }
}

do {
  let capabilityStore = try RuntimeCapabilityStore(
    directoryURL: stateDirectory.appendingPathComponent("capabilities", isDirectory: true))
  let providers = DeviceProviderRegistry(providers: [
    HDCObservationProviderAdapter(factsPort: UnavailableFactsPort())
  ])
  let engine = try RuntimeJobEngine(
    configuration: .init(stateDirectory: stateDirectory),
    providers: providers,
    dispatcher: RefusingDispatcher(),
    capabilityStore: capabilityStore,
    nowUTC: utcNow)
  let recovered = try await engine.recoverPersistedJobs()
  if !recovered.isEmpty {
    print("recovered \(recovered.count) persisted job(s); unknown outcomes parked")
  }
  let handler = RuntimeControlPlaneHandler(
    engine: engine,
    capabilityStore: capabilityStore,
    providerIDs: providers.registeredProviderIDs,
    nowUTC: utcNow)
  let server = AgentDaemonServer(
    stateDirectory: stateDirectory, handler: handler, nowUTC: utcNow)
  switch try server.start() {
  case .started:
    print("arkdeck-agentd listening on \(server.socketURL.path)")
    signal(SIGINT, SIG_IGN)
    signal(SIGTERM, SIG_IGN)
    let signalSource = DispatchSource.makeSignalSource(signal: SIGTERM, queue: .main)
    signalSource.setEventHandler {
      server.stop()
      exit(0)
    }
    signalSource.resume()
    let interruptSource = DispatchSource.makeSignalSource(signal: SIGINT, queue: .main)
    interruptSource.setEventHandler {
      server.stop()
      exit(0)
    }
    interruptSource.resume()
    dispatchMain()
  case .alreadyRunning(let instance):
    print(
      "arkdeck-agentd already running: pid \(instance.pid), socket \(instance.socketPath), "
        + "protocol \(instance.protocolVersion)")
    exit(0)
  }
} catch {
  FileHandle.standardError.write(Data("arkdeck-agentd failed to start: \(error)\n".utf8))
  exit(1)
}
