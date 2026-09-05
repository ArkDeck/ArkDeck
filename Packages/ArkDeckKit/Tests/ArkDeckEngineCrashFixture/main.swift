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

if CommandLine.arguments.count == 3, CommandLine.arguments[1].hasPrefix("artifact-export-") {
  try await runArtifactExportCrashFixture(window: CommandLine.arguments[1], directory: URL(filePath: CommandLine.arguments[2]))
  exit(0)
}

if CommandLine.arguments.count == 3, CommandLine.arguments[1].hasPrefix("import-") {
  try await runImportCrashFixture(window: CommandLine.arguments[1], directory: URL(filePath: CommandLine.arguments[2]))
  exit(70)
}

if CommandLine.arguments.count == 3, CommandLine.arguments[1].hasPrefix("bootstrap-tool-") {
  try runBootstrapToolCrashFixture(window: CommandLine.arguments[1], directory: URL(filePath: CommandLine.arguments[2]))
  exit(70)
}

if CommandLine.arguments.count == 3, CommandLine.arguments[1].hasPrefix("bootstrap-bundle-") {
  try runBootstrapBundleCrashFixture(window: CommandLine.arguments[1], directory: URL(filePath: CommandLine.arguments[2]))
  exit(70)
}

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

let directory = URL(filePath: CommandLine.arguments[2], directoryHint: .isDirectory)
try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)

struct FixtureFactsPort: HDCObservationFactsPort {
  func currentFacts(targetID: String) async throws -> ProviderFacts {
    ProviderFacts(
      providerID: "hdc", toolVersion: "3.2.0f",
      toolSHA256: String(repeating: "a", count: 64), serverFacts: [:],
      targetID: targetID, bindingRevision: 7,
      deviceIdentitySHA256: "3ba3f5f43b92602683c19aee62a20342b084dd5971ddd33808d81a328879a547",
      executionConnectKey: String(repeating: "a", count: 32),
      deviceModel: nil, deviceMode: "hdc", buildFingerprint: nil, transport: nil,
      profileID: "openharmony-standard@1", collectedAtUTC: "2026-07-29T00:00:00Z",
      sourceObservedAtUTC: "2026-07-29T00:00:00Z")
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
      let marker = directory.appending(path: "external-effect-marker")
      try Data("synthetic".utf8).write(to: marker, options: [])
      let handle = try FileHandle(forWritingTo: marker)
      try handle.synchronize()
      try handle.close()
    }
    let ready = directory.appending(path: "ready")
    try Data(window.rawValue.utf8).write(to: ready, options: [])
    let readyHandle = try FileHandle(forWritingTo: ready)
    try readyHandle.synchronize()
    try readyHandle.close()
    Darwin.raise(SIGSTOP)
    while true { Darwin.pause() }
  }
}

let engineState = directory.appending(path: "engine-state", directoryHint: .isDirectory)
let capabilityStore = try RuntimeCapabilityStore(
  directoryURL: directory.appending(path: "capabilities", directoryHint: .isDirectory))
let artifactStore = try RuntimeArtifactStore(
  rootURL: directory.appending(path: "artifacts", directoryHint: .isDirectory),
  nowUTC: { "2026-07-29T00:30:00Z" })
let engine = try RuntimeJobEngine(
  configuration: .init(stateDirectory: engineState),
  providers: DeviceProviderRegistry(providers: [
    HDCObservationProviderAdapter(factsPort: FixtureFactsPort())
  ]),
  dispatcher: StoppingDispatcher(window: window, directory: directory),
  capabilityStore: capabilityStore,
  artifactStore: artifactStore,
  nowUTC: { "2026-07-29T00:30:00Z" })

let request = Data(
  """
  {
    "documentType": "runtime-operation-request",
    "schemaVersion": "1.0.0",
    "requestId": "req-crash",
    "idempotencyKey": "idem-crash-0001",
    "target": { "targetId": "TGT-CRASH-01", "expectedBindingRevision": 7 },
    "operation": { "id": "observe.device", "version": 1 }
  }
  """.utf8)

let acceptance = try await engine.submit(request)
_ = try await engine.run(jobID: acceptance.jobID)
// Unreachable: the dispatcher stops the process inside run().
exit(70)
