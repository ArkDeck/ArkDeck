// Engine crash-window fixture (CHG-2026-047, T08).
//
// A real separate process that drives the real RuntimeJobEngine over the
// real durable journal, then SIGSTOPs inside one of two dispatch windows so
// the parent test can SIGKILL it and assert recovery semantics:
//   afterIntentBeforeDispatch  - intent durable, zero external effect
//   afterDispatchBeforeOutcome - intent durable, external effect happened,
//                                outcome never recorded
// The synthetic "external effect" is a marker file; no device is involved.

import ArkDeckCore
import ArkDeckOpenHarmony
import ArkDeckStorage
import ArkDeckWorkflows
import Darwin
import Foundation

enum Window: String {
  case afterIntentBeforeDispatch
  case afterDispatchBeforeOutcome
}

guard CommandLine.arguments.count == 3,
  let window = Window(rawValue: CommandLine.arguments[1])
else {
  FileHandle.standardError.write(
    Data("usage: ArkDeckEngineCrashFixture <window> <directory>\n".utf8))
  exit(64)
}

let directory = URL(fileURLWithPath: CommandLine.arguments[2], isDirectory: true)
try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)

struct FixtureFactsPort: HDCObservationFactsPort {
  func currentFacts(targetID: String) async throws -> ProviderFacts {
    ProviderFacts(
      providerID: "hdc", toolVersion: "3.2.0f",
      toolSHA256: String(repeating: "a", count: 64), serverFacts: [:],
      deviceIdentitySHA256: nil, deviceMode: nil, buildFingerprint: nil,
      profileID: "openharmony-standard@1", collectedAtUTC: "2026-07-29T00:00:00Z")
  }
}

/// Stops the whole process inside the dispatch call. `ready` is written
/// immediately before SIGSTOP, so by the time the parent sees it the
/// journal already holds the durable intent (the WAL gate ran first).
struct StoppingDispatcher: RuntimeProcessDispatching {
  let window: Window
  let directory: URL

  func dispatch(_ plan: TypedProcessPlan) async throws -> ProviderProcessReceipt {
    switch plan.action {
    case .hdc(.observeTool):
      // Earlier host probes complete normally so the crash lands on the
      // device-probe step.
      return ProviderProcessReceipt(
        exitStatus: 0, stdout: Data("Ver: 3.2.0f\n".utf8), stderr: Data(),
        stdoutTruncated: false, durationSeconds: 0.01)
    case .hdc(.observeServer):
      return ProviderProcessReceipt(
        exitStatus: 0,
        stdout: Data("Client version:Ver: 3.2.0f, server version:Ver: 3.2.0f\n".utf8),
        stderr: Data(), stdoutTruncated: false, durationSeconds: 0.01)
    default:
      break
    }
    if window == .afterDispatchBeforeOutcome {
      let marker = directory.appendingPathComponent("external-effect-marker")
      try Data("synthetic".utf8).write(to: marker, options: [])
      let handle = try FileHandle(forWritingTo: marker)
      try handle.synchronize()
      try handle.close()
    }
    let ready = directory.appendingPathComponent("ready")
    try Data(window.rawValue.utf8).write(to: ready, options: [])
    let readyHandle = try FileHandle(forWritingTo: ready)
    try readyHandle.synchronize()
    try readyHandle.close()
    Darwin.raise(SIGSTOP)
    while true { Darwin.pause() }
  }
}

let engineState = directory.appendingPathComponent("engine-state", isDirectory: true)
let capabilityStore = try RuntimeCapabilityStore(
  directoryURL: directory.appendingPathComponent("capabilities", isDirectory: true))
let engine = try RuntimeJobEngine(
  configuration: .init(stateDirectory: engineState),
  providers: DeviceProviderRegistry(providers: [
    HDCObservationProviderAdapter(factsPort: FixtureFactsPort())
  ]),
  dispatcher: StoppingDispatcher(window: window, directory: directory),
  capabilityStore: capabilityStore,
  nowUTC: { "2026-07-29T00:30:00Z" })

let request = Data(
  """
  {
    "documentType": "runtime-operation-request",
    "schemaVersion": "2.0.0",
    "requestId": "req-crash",
    "idempotencyKey": "idem-crash-0001",
    "target": { "targetId": "TGT-CRASH-01" },
    "operation": { "id": "observe.device", "version": 1 }
  }
  """.utf8)

let acceptance = try await engine.submit(request)
_ = try await engine.run(jobID: acceptance.jobID)
// Unreachable: the dispatcher stops the process inside run().
exit(70)
