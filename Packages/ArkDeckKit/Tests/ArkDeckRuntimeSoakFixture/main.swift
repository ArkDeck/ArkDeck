// macOS Runtime long-run simulation fixture.
//
// This executable intentionally uses the production RuntimeJobEngine, SQLite
// repository, durable journals and Artifact store.  Its provider dispatcher is
// a fake HDC implementation: it creates no child process, opens no device
// transport and is not evidence of a real-device run.
//
// A normal invocation runs for 24 hours.  It regularly recreates the engine
// from the same state directory, completes previously active jobs, creates a
// mix of successful, cancelled and restart-recovered observations, and writes
// an atomically replaced metrics snapshot after every cycle.

import ArkDeckAgentClient
import ArkDeckAgentDaemon
import ArkDeckCore
import ArkDeckOpenHarmony
import ArkDeckStorage
import ArkDeckWorkflows
import Darwin
import Foundation

private struct SoakConfiguration {
  let stateDirectory: URL
  let durationSeconds: Int
  let restartIntervalSeconds: Int
  let jobsPerCycle: Int

  init(arguments: [String]) throws {
    var stateDirectory: URL?
    var durationSeconds = 24 * 60 * 60
    var restartIntervalSeconds = 300
    var jobsPerCycle = 10
    var index = 1

    while index < arguments.count {
      let flag = arguments[index]
      index += 1
      guard index < arguments.count else {
        throw SoakFixtureError.invalidArguments("missing value for \(flag)")
      }
      let value = arguments[index]
      index += 1
      switch flag {
      case "--state-directory":
        guard value.hasPrefix("/") else {
          throw SoakFixtureError.invalidArguments("--state-directory must be absolute")
        }
        let url = URL(filePath: value).standardizedFileURL
        stateDirectory = url
      case "--duration-seconds":
        durationSeconds = try Self.positiveInteger(value, flag: flag)
      case "--restart-interval-seconds":
        restartIntervalSeconds = try Self.positiveInteger(value, flag: flag)
      case "--jobs-per-cycle":
        jobsPerCycle = try Self.positiveInteger(value, flag: flag)
      default:
        throw SoakFixtureError.invalidArguments("unknown option \(flag)")
      }
    }

    guard let stateDirectory else {
      throw SoakFixtureError.invalidArguments("--state-directory is required")
    }
    self.stateDirectory = stateDirectory
    self.durationSeconds = durationSeconds
    self.restartIntervalSeconds = restartIntervalSeconds
    self.jobsPerCycle = jobsPerCycle
  }

  private static func positiveInteger(_ value: String, flag: String) throws -> Int {
    guard let parsed = Int(value), parsed > 0 else {
      throw SoakFixtureError.invalidArguments("\(flag) must be a positive integer")
    }
    return parsed
  }
}

private enum SoakFixtureError: Error, LocalizedError {
  case invalidArguments(String)
  case unexpectedState(jobID: String, state: String)
  case nonTerminalJobs([String])
  case failedJobs([String])
  case tornJournal(String)
  case missingArtifactEvidence(String)
  case outstandingCleanupDebt(Int)
  case protocolFailure(String)
  case residentSetGrowthExceeded(actual: Int64, limit: Int64)
  case fileDescriptorGrowthExceeded(actual: Int, limit: Int)

  var errorDescription: String? {
    switch self {
    case .invalidArguments(let message): return message
    case .unexpectedState(let jobID, let state):
      return "job \(jobID) recovered to unsupported state \(state)"
    case .nonTerminalJobs(let jobIDs): return "non-terminal jobs remain: \(jobIDs)"
    case .failedJobs(let jobIDs): return "unexpected failed or interrupted jobs: \(jobIDs)"
    case .tornJournal(let path): return "durable journal has a torn tail: \(path)"
    case .missingArtifactEvidence(let jobID):
      return "successful job \(jobID) has no verified Artifact evidence"
    case .outstandingCleanupDebt(let count):
      return "\(count) cleanup-debt records remain after final recovery"
    case .protocolFailure(let message): return message
    case .residentSetGrowthExceeded(let actual, let limit):
      return "resident-set growth \(actual) bytes exceeds soak limit \(limit)"
    case .fileDescriptorGrowthExceeded(let actual, let limit):
      return "open-file-descriptor growth \(actual) exceeds soak limit \(limit)"
    }
  }
}

private struct FixtureFactsPort: HDCObservationFactsPort {
  func currentFacts(targetID: String) async throws -> ProviderFacts {
    ProviderFacts(
      providerID: "hdc", toolVersion: "3.2.0f",
      toolSHA256: String(repeating: "a", count: 64), serverFacts: [:],
      targetID: targetID, bindingRevision: 7,
      deviceIdentitySHA256: "3ba3f5f43b92602683c19aee62a20342b084dd5971ddd33808d81a328879a547",
      executionConnectKey: String(repeating: "a", count: 32),
      deviceModel: nil, deviceMode: "hdc", buildFingerprint: nil, transport: nil,
      profileID: "openharmony-standard@1", collectedAtUTC: currentUTC(),
      sourceObservedAtUTC: currentUTC())
  }
}

/// A deterministic, in-process provider.  `childProcessCount` is deliberately
/// zero: the fixture measures Runtime lifecycle behaviour without creating a
/// hidden host-child workload.
private actor SimulatedHDCDispatcher: RuntimeProcessDispatching {
  private var dispatchedCommandCount = 0

  func dispatch(_ plan: TypedProcessPlan) async throws -> ProviderProcessReceipt {
    dispatchedCommandCount += 1
    switch plan.action {
    case .hdc(.observeTool):
      return ProviderProcessReceipt(
        exitStatus: 0, stdout: Data("Ver: 3.2.0f\n".utf8), stderr: Data(),
        stdoutTruncated: false, durationSeconds: 0.01)
    case .hdc(.observeServer):
      return ProviderProcessReceipt(
        exitStatus: 0,
        stdout: Data("Client version:Ver: 3.2.0f, server version:Ver: 3.2.0f\n".utf8),
        stderr: Data(), stdoutTruncated: false, durationSeconds: 0.01)
    case .hdc(.observeDevice), .hdc(.listDeviceCandidates):
      return ProviderProcessReceipt(
        exitStatus: 0,
        stdout: Data("aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa\t\tUSB\tConnected\tlocalhost\n".utf8),
        stderr: Data(), stdoutTruncated: false, durationSeconds: 0.01)
    case .hdc(.queryProperty(.productName)):
      return ProviderProcessReceipt(
        exitStatus: 0, stdout: Data("OpenHarmony Reference Device\n".utf8), stderr: Data(),
        stdoutTruncated: false, durationSeconds: 0.01)
    case .hdc(.queryProperty(.fullBuildVersion)):
      return ProviderProcessReceipt(
        exitStatus: 0, stdout: Data("OpenHarmony-4.1-release\n".utf8), stderr: Data(),
        stdoutTruncated: false, durationSeconds: 0.01)
    default:
      throw RuntimeDispatchFailure.failed("unscripted action in Runtime soak fixture")
    }
  }

  func commandCount() -> Int { dispatchedCommandCount }
}

private struct FileTreeUsage {
  var fileCount = 0
  var byteCount: Int64 = 0
  var journalCount = 0
  var journalByteCount: Int64 = 0
}

private struct SoakMetrics: Codable {
  let schemaVersion: String
  let runID: String
  let phase: String
  let cycle: Int
  let generatedAtUTC: String
  let elapsedSeconds: Int
  let configuredDurationSeconds: Int
  let jobsPerCycle: Int
  let recoveredThisCycle: Int
  let fakeProviderCommandsThisCycle: Int
  let fakeProviderChildProcessCount: Int
  let processID: Int32
  let openFileDescriptorCount: Int?
  let maxResidentSetBytes: Int64?
  let baselineOpenFileDescriptorCount: Int?
  let openFileDescriptorGrowth: Int?
  let baselineResidentSetBytes: Int64?
  let residentSetGrowthBytes: Int64?
  let jobStates: [String: Int]
  let activeJobCount: Int
  let terminalJobCount: Int
  let stateFileCount: Int
  let stateByteCount: Int64
  let journalCount: Int
  let journalByteCount: Int64
  let artifactFileCount: Int
  let artifactByteCount: Int64
  let outstandingCleanupDebtCount: Int
  let verifiedArtifactEvidenceJobCount: Int?
}

// A steady-state cycle creates the same ten jobs, then drains the daemon
// before metrics are read.  The first cycle loads SQLite/Swift runtime state;
// subsequent cycles must not retain another workload's worth of memory or
// file descriptors.  These limits are intentionally far below the 128 MiB
// artifact input used by the slow lane, while leaving headroom for allocator
// and system-library variation on macOS runners.
private let maximumResidentSetGrowthBytes: Int64 = 32 * 1024 * 1024
private let maximumOpenFileDescriptorGrowth = 16

private func currentUTC() -> String {
  ISO8601Timestamps.string(from: Date())
}

private func makeEngine(
  configuration: SoakConfiguration
) throws -> (RuntimeJobEngine, SimulatedHDCDispatcher, RuntimeArtifactStore, RuntimeCapabilityStore)
{
  let dispatcher = SimulatedHDCDispatcher()
  let capabilities = try RuntimeCapabilityStore(
    directoryURL: configuration.stateDirectory.appending(
      path:
        "capabilities", directoryHint: .isDirectory))
  let artifacts = try RuntimeArtifactStore(
    rootURL: configuration.stateDirectory.appending(path: "artifacts", directoryHint: .isDirectory),
    nowUTC: currentUTC)
  let engine = try RuntimeJobEngine(
    configuration: .init(stateDirectory: configuration.stateDirectory),
    providers: DeviceProviderRegistry(providers: [
      HDCObservationProviderAdapter(factsPort: FixtureFactsPort())
    ]),
    dispatcher: dispatcher,
    capabilityStore: capabilities,
    artifactStore: artifacts,
    nowUTC: currentUTC)
  return (engine, dispatcher, artifacts, capabilities)
}

private func startDaemon(
  configuration: SoakConfiguration,
  engine: RuntimeJobEngine,
  capabilities: RuntimeCapabilityStore,
  artifacts: RuntimeArtifactStore
) throws -> AgentDaemonServer {
  let handler = RuntimeControlPlaneHandler(
    engine: engine,
    capabilityStore: capabilities,
    providerIDs: ["hdc"],
    nowUTC: currentUTC,
    artifactStore: artifacts)
  // Keep the Unix-domain socket path short enough for Darwin's 104-byte
  // `sun_path` limit even when the caller chooses a descriptive temporary
  // soak directory.  The server owns only transport state; the engine state
  // remains at the parent directory and therefore survives this restart.
  let server = AgentDaemonServer(
    stateDirectory: configuration.stateDirectory.appending(path: "d", directoryHint: .isDirectory),
    handler: handler,
    nowUTC: currentUTC)
  guard try server.start() == .started else {
    throw SoakFixtureError.protocolFailure("soak daemon did not acquire its instance lock")
  }
  return server
}

private func submittedJobID(_ client: AgentClient, request: Data) throws -> String {
  guard
    case .object(let fields) = try client.request(
      method: "job.submit",
      params: ["requestJson": .string(String(decoding: request, as: UTF8.self))]),
    case .string(let jobID)? = fields["jobId"]
  else {
    throw SoakFixtureError.protocolFailure("daemon returned no job id for submitted soak request")
  }
  return jobID
}

private func runJob(_ client: AgentClient, jobID: String) throws -> String {
  guard
    case .object(let fields) = try client.request(
      method: "job.run", params: ["jobId": .string(jobID)]),
    case .string(let state)? = fields["state"]
  else {
    throw SoakFixtureError.protocolFailure("daemon returned no job state for \(jobID)")
  }
  return state
}

private func observationRequest(runID: String, cycle: Int, offset: Int) -> Data {
  Data(
    """
    {
      "documentType": "runtime-operation-request",
      "schemaVersion": "2.0.0",
      "requestId": "soak-\(runID)-\(cycle)-\(offset)",
      "idempotencyKey": "soak-\(runID)-\(cycle)-\(offset)",
      "target": { "targetId": "TGT-SOAK-01", "expectedBindingRevision": 7 },
      "operation": { "id": "observe.device", "version": 1 }
    }
    """.utf8)
}

private func runRecoveredJobs(_ engine: RuntimeJobEngine) async throws -> Int {
  let recovered = try await engine.recoverActiveJobs()
  for status in recovered {
    guard let state = JobState(rawValue: status.state) else {
      throw SoakFixtureError.unexpectedState(jobID: status.jobID, state: status.state)
    }
    guard !state.isTerminal else { continue }
    switch state {
    case .preflight, .running, .resumeAtConfirmedSafeBoundary:
      let completed = try await engine.run(jobID: status.jobID)
      guard JobState(rawValue: completed.state)?.isTerminal == true else {
        throw SoakFixtureError.unexpectedState(jobID: completed.jobID, state: completed.state)
      }
    default:
      throw SoakFixtureError.unexpectedState(jobID: status.jobID, state: status.state)
    }
  }
  return recovered.count
}

private func executeCycle(
  configuration: SoakConfiguration,
  runID: String,
  cycle: Int,
  createNewJobs: Bool
) async throws -> (recovered: Int, dispatches: Int) {
  let (engine, dispatcher, artifacts, capabilities) = try makeEngine(configuration: configuration)
  let daemon = try startDaemon(
    configuration: configuration, engine: engine, capabilities: capabilities, artifacts: artifacts)
  defer { daemon.drainAndStop(deadline: 5) }
  let client = AgentClient(socketPath: daemon.socketURL.path)
  let recovered = try await runRecoveredJobs(engine)
  guard createNewJobs else {
    return (recovered, await dispatcher.commandCount())
  }

  for offset in 0..<configuration.jobsPerCycle {
    let jobID = try submittedJobID(
      client, request: observationRequest(runID: runID, cycle: cycle, offset: offset))
    // Cancel one deterministic job per eleven.  The following run persists
    // the cancellation outcome; other cycles leave a deterministic job in
    // preflight so the next fresh Runtime has to recover it from disk.
    if offset % 11 == 0 {
      _ = try client.request(method: "job.cancel", params: ["jobId": .string(jobID)])
      let state = try runJob(client, jobID: jobID)
      guard state == JobState.cancelled.rawValue else {
        throw SoakFixtureError.unexpectedState(jobID: jobID, state: state)
      }
    } else if offset % 7 != 0 {
      let state = try runJob(client, jobID: jobID)
      guard state == JobState.succeeded.rawValue else {
        throw SoakFixtureError.unexpectedState(jobID: jobID, state: state)
      }
    }
  }
  return (recovered, await dispatcher.commandCount())
}

private func treeUsage(at root: URL) -> FileTreeUsage {
  guard
    let enumerator = FileManager.default.enumerator(
      at: root,
      includingPropertiesForKeys: [.isRegularFileKey, .fileSizeKey],
      options: [.skipsHiddenFiles])
  else { return FileTreeUsage() }

  var usage = FileTreeUsage()
  for case let url as URL in enumerator {
    guard let values = try? url.resourceValues(forKeys: [.isRegularFileKey, .fileSizeKey]),
      values.isRegularFile == true
    else { continue }
    let byteCount = Int64(values.fileSize ?? 0)
    usage.fileCount += 1
    usage.byteCount += byteCount
    if url.lastPathComponent == "journal.jsonl" {
      usage.journalCount += 1
      usage.journalByteCount += byteCount
    }
  }
  return usage
}

private func maximumResidentSetBytes() -> Int64? {
  var usage = rusage()
  guard getrusage(RUSAGE_SELF, &usage) == 0 else { return nil }
  // Darwin reports ru_maxrss in bytes (the fixture is macOS-only).
  return Int64(usage.ru_maxrss)
}

private func openFileDescriptorCount() -> Int? {
  try? FileManager.default.contentsOfDirectory(atPath: "/dev/fd").count
}

private func jobStateCounts(_ engine: RuntimeJobEngine) async throws -> [String: Int] {
  var counts: [String: Int] = [:]
  var cursor: String?
  repeat {
    let page = try await engine.listJobs(pageSize: 250, cursor: cursor)
    for job in page.jobs {
      counts[job.state, default: 0] += 1
    }
    cursor = page.nextCursor
  } while cursor != nil
  return counts
}

private func verifyTerminalState(
  configuration: SoakConfiguration
) async throws -> (states: [String: Int], verifiedArtifactJobs: Int) {
  let (engine, _, artifacts, _) = try makeEngine(configuration: configuration)
  _ = try await runRecoveredJobs(engine)
  let states = try await jobStateCounts(engine)
  let cleanupDebt = try await engine.listCleanupDebt()
  var cursor: String?
  var nonTerminal: [String] = []
  var failed: [String] = []
  var verifiedArtifactJobs = 0
  repeat {
    let page = try await engine.listJobs(pageSize: 250, cursor: cursor)
    for job in page.jobs {
      guard let state = JobState(rawValue: job.state) else {
        throw SoakFixtureError.unexpectedState(jobID: job.jobID, state: job.state)
      }
      if !state.isTerminal { nonTerminal.append(job.jobID) }
      if state == .failed || state == .interrupted { failed.append(job.jobID) }
      if state == .succeeded {
        let evidence = try await artifacts.verifiedEvidenceArtifacts(jobID: job.jobID)
        guard !evidence.isEmpty else {
          throw SoakFixtureError.missingArtifactEvidence(job.jobID)
        }
        verifiedArtifactJobs += 1
      }
    }
    cursor = page.nextCursor
  } while cursor != nil
  guard nonTerminal.isEmpty else { throw SoakFixtureError.nonTerminalJobs(nonTerminal) }
  guard failed.isEmpty else { throw SoakFixtureError.failedJobs(failed) }
  guard cleanupDebt.isEmpty else {
    throw SoakFixtureError.outstandingCleanupDebt(cleanupDebt.count)
  }
  return (states, verifiedArtifactJobs)
}

private func verifyJournalIntegrity(at root: URL) throws {
  guard
    let enumerator = FileManager.default.enumerator(
      at: root,
      includingPropertiesForKeys: [.isRegularFileKey],
      options: [.skipsHiddenFiles])
  else { return }
  for case let url as URL in enumerator where url.lastPathComponent == "journal.jsonl" {
    let inspection = try DurableJournalRecovery.inspect(url: url)
    if inspection.hasTornTail { throw SoakFixtureError.tornJournal(url.path) }
  }
}

private func collectMetrics(
  configuration: SoakConfiguration,
  runID: String,
  phase: String,
  cycle: Int,
  startedAt: Date,
  recovered: Int,
  dispatches: Int,
  verifiedArtifactJobs: Int? = nil,
  baselineResidentSetBytes: Int64? = nil,
  baselineOpenFileDescriptorCount: Int? = nil
) async throws -> SoakMetrics {
  let (engine, _, _, _) = try makeEngine(configuration: configuration)
  let states = try await jobStateCounts(engine)
  let cleanupDebt = try await engine.listCleanupDebt()
  let active = states.reduce(into: 0) { count, entry in
    if JobState(rawValue: entry.key)?.isTerminal == false { count += entry.value }
  }
  let terminal = states.values.reduce(0, +) - active
  let state = treeUsage(at: configuration.stateDirectory)
  let artifacts = treeUsage(
    at: configuration.stateDirectory.appending(path: "artifacts", directoryHint: .isDirectory))
  let openDescriptors = openFileDescriptorCount()
  let residentSet = maximumResidentSetBytes()
  let residentBaseline = baselineResidentSetBytes ?? residentSet
  let descriptorBaseline = baselineOpenFileDescriptorCount ?? openDescriptors
  let descriptorGrowth = openDescriptors.flatMap { current in
    descriptorBaseline.map { current - $0 }
  }
  let residentGrowth = residentSet.flatMap { current in
    residentBaseline.map { current - $0 }
  }
  return SoakMetrics(
    schemaVersion: "arkdeck-runtime-soak/v1", runID: runID, phase: phase, cycle: cycle,
    generatedAtUTC: currentUTC(), elapsedSeconds: Int(Date().timeIntervalSince(startedAt)),
    configuredDurationSeconds: configuration.durationSeconds,
    jobsPerCycle: configuration.jobsPerCycle,
    recoveredThisCycle: recovered, fakeProviderCommandsThisCycle: dispatches,
    fakeProviderChildProcessCount: 0, processID: getpid(),
    openFileDescriptorCount: openDescriptors, maxResidentSetBytes: residentSet,
    baselineOpenFileDescriptorCount: descriptorBaseline,
    openFileDescriptorGrowth: descriptorGrowth,
    baselineResidentSetBytes: residentBaseline,
    residentSetGrowthBytes: residentGrowth,
    jobStates: states, activeJobCount: active, terminalJobCount: terminal,
    stateFileCount: state.fileCount, stateByteCount: state.byteCount,
    journalCount: state.journalCount, journalByteCount: state.journalByteCount,
    artifactFileCount: artifacts.fileCount, artifactByteCount: artifacts.byteCount,
    outstandingCleanupDebtCount: cleanupDebt.count,
    verifiedArtifactEvidenceJobCount: verifiedArtifactJobs)
}

private func verifySteadyStateResources(_ metrics: SoakMetrics) throws {
  if let growth = metrics.residentSetGrowthBytes, growth > maximumResidentSetGrowthBytes {
    throw SoakFixtureError.residentSetGrowthExceeded(
      actual: growth, limit: maximumResidentSetGrowthBytes)
  }
  if let growth = metrics.openFileDescriptorGrowth, growth > maximumOpenFileDescriptorGrowth {
    throw SoakFixtureError.fileDescriptorGrowthExceeded(
      actual: growth, limit: maximumOpenFileDescriptorGrowth)
  }
}

private func persistMetrics(_ metrics: SoakMetrics, to stateDirectory: URL) throws {
  let encoder = JSONEncoder()
  encoder.outputFormatting = [.sortedKeys, .prettyPrinted, .withoutEscapingSlashes]
  try DurableFileWriter.createOrReplaceAtomically(
    destination: stateDirectory.appending(path: "runtime-soak-metrics.json"),
    data: try encoder.encode(metrics))
}

private func usage() {
  FileHandle.standardError.write(
    Data(
      ("usage: ArkDeckRuntimeSoakFixture --state-directory <absolute-directory> "
        + "[--duration-seconds <positive-int>] "
        + "[--restart-interval-seconds <positive-int>] "
        + "[--jobs-per-cycle <positive-int>]\n").utf8))
}

do {
  let configuration = try SoakConfiguration(arguments: CommandLine.arguments)
  try FileManager.default.createDirectory(
    at: configuration.stateDirectory, withIntermediateDirectories: true,
    attributes: [.posixPermissions: 0o700])
  let startedAt = Date()
  let deadline = startedAt.addingTimeInterval(TimeInterval(configuration.durationSeconds))
  let runID = UUID().uuidString.lowercased()
  var cycle = 0
  var baselineResidentSetBytes: Int64?
  var baselineOpenFileDescriptorCount: Int?

  print(
    "ArkDeck Runtime soak started runID=\(runID) durationSeconds=\(configuration.durationSeconds) "
      + "stateDirectory=\(configuration.stateDirectory.path) simulatedProvider=true")
  while Date() < deadline {
    cycle += 1
    let result = try await executeCycle(
      configuration: configuration, runID: runID, cycle: cycle, createNewJobs: true)
    let metrics = try await collectMetrics(
      configuration: configuration, runID: runID, phase: "running", cycle: cycle,
      startedAt: startedAt, recovered: result.recovered, dispatches: result.dispatches,
      baselineResidentSetBytes: baselineResidentSetBytes,
      baselineOpenFileDescriptorCount: baselineOpenFileDescriptorCount)
    try persistMetrics(metrics, to: configuration.stateDirectory)
    try verifySteadyStateResources(metrics)
    baselineResidentSetBytes = metrics.baselineResidentSetBytes
    baselineOpenFileDescriptorCount = metrics.baselineOpenFileDescriptorCount
    print(
      "ArkDeck Runtime soak cycle=\(cycle) jobs=\(metrics.terminalJobCount + metrics.activeJobCount) "
        + "active=\(metrics.activeJobCount) recovered=\(result.recovered) "
        + "rssBytes=\(metrics.maxResidentSetBytes.map(String.init) ?? "unavailable")")

    let remaining = deadline.timeIntervalSinceNow
    guard remaining > 0 else { break }
    let pause = min(TimeInterval(configuration.restartIntervalSeconds), remaining)
    try await Task.sleep(for: .seconds(pause))
  }

  // One final fresh Runtime drains clean preflight jobs left deliberately by
  // the prior cycle, then validates every durable journal and every successful
  // job's Artifact evidence before publishing the terminal metrics snapshot.
  let drained = try await executeCycle(
    configuration: configuration, runID: runID, cycle: cycle + 1, createNewJobs: false)
  let verified = try await verifyTerminalState(configuration: configuration)
  try verifyJournalIntegrity(at: configuration.stateDirectory)
  let finalMetrics = try await collectMetrics(
    configuration: configuration, runID: runID, phase: "completed", cycle: cycle,
    startedAt: startedAt, recovered: drained.recovered, dispatches: drained.dispatches,
    verifiedArtifactJobs: verified.verifiedArtifactJobs,
    baselineResidentSetBytes: baselineResidentSetBytes,
    baselineOpenFileDescriptorCount: baselineOpenFileDescriptorCount)
  try verifySteadyStateResources(finalMetrics)
  try persistMetrics(finalMetrics, to: configuration.stateDirectory)
  print(
    "ArkDeck Runtime soak completed runID=\(runID) terminalJobs=\(finalMetrics.terminalJobCount) "
      + "verifiedArtifactJobs=\(verified.verifiedArtifactJobs) simulatedProvider=true")
} catch let error as SoakFixtureError {
  usage()
  FileHandle.standardError.write(
    Data("ArkDeck Runtime soak failed: \(error.localizedDescription)\n".utf8))
  exit(1)
} catch {
  FileHandle.standardError.write(Data("ArkDeck Runtime soak failed: \(error)\n".utf8))
  exit(1)
}
