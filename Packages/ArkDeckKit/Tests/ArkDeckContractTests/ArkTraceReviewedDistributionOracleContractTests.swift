// Host acceptance oracle for the Rust ArkTrace loader over a reviewed
// distribution (CHG-2026-074, TASK-XPA-015).

import Darwin
import XCTest

@testable import ArkDeckAgentDaemon
@testable import ArkDeckCore
@testable import ArkDeckRuntime
@testable import ArkDeckStorage
@testable import ArkDeckWorkflows

/// Swift's production loading of a reviewed, signed and notarized ArkTrace
/// distribution — `ProductionArkTraceDistributionTrustChecker`, the doctor
/// probe run against the real CLI, a private snapshot generation — at one
/// fixed root, recorded for the Rust loader's host acceptance
/// (`rust/crates/arkdeck-hoststore/tests/arktrace_reviewed.rs`). A reviewed
/// distribution is a host's, not the repository's, so nothing is checked in:
/// this runs only when `ARKDECK_REVIEWED_ARKTRACE_DESCRIPTOR` names one and
/// `ARKDECK_REVIEWED_ARKTRACE_RECORD` names the new file to record into.
final class ArkTraceReviewedDistributionOracleContractTests: XCTestCase {
  static let root = "/private/tmp/arkdeck-arktrace-reviewed"

  func testSwiftLoadsTheReviewedDistribution() async throws {
    let environment = ProcessInfo.processInfo.environment
    guard let descriptor = environment["ARKDECK_REVIEWED_ARKTRACE_DESCRIPTOR"],
      let record = environment["ARKDECK_REVIEWED_ARKTRACE_RECORD"]
    else {
      throw XCTSkip(
        "set ARKDECK_REVIEWED_ARKTRACE_DESCRIPTOR and ARKDECK_REVIEWED_ARKTRACE_RECORD")
    }
    let lock = try ArkTraceProfileLoaderOracleContractTests.lock()
    defer { close(lock) }
    let manager = FileManager.default
    try? manager.removeItem(atPath: Self.root)
    defer { try? manager.removeItem(atPath: Self.root) }
    try ArkTraceProfileLoaderOracleContractTests.directory(Self.root, mode: 0o700)
    let outcome: JSONValue
    do {
      let profiles = try await ArkTraceSummaryAnalyzerProfileLoader(
        doctor: ProductionArkTraceDoctorProbe(homeURL: URL(filePath: "\(Self.root)/home")),
        snapshotRootURL: URL(filePath: "\(Self.root)/snapshots", directoryHint: .isDirectory))
        .loadProfiles(descriptorURL: URL(filePath: descriptor))
      outcome = .object([
        "profiles": .array(profiles.map(ArkTraceProfileLoaderOracleContractTests.projection))
      ])
    } catch let error as ArkTraceSummaryProfileError {
      outcome = .object(["error": .string(error.reason)])
    }
    let encoder = JSONEncoder()
    encoder.outputFormatting = [.sortedKeys, .prettyPrinted, .withoutEscapingSlashes]
    guard !manager.fileExists(atPath: record) else { throw CocoaError(.fileWriteFileExists) }
    try (encoder.encode(outcome) + Data("\n".utf8)).write(to: URL(filePath: record))
  }

  private static let nowUTC = "2026-09-14T00:00:00Z"
  private static let nowPreciseUTC = "2026-09-14T00:00:00.000Z"
  private static let target = "TGT-REVIEWED"
  private static let repository: URL = {
    var url = URL(filePath: #filePath)
    for _ in 0..<5 { url.deleteLastPathComponent() }
    return url
  }()

  /// Host acceptance of `analyzer.summarize-trace@1` with the reviewed
  /// distribution: its two profiles loaded as the daemon loads them, then the
  /// repository's `zlib.htrace` published as a source Artifact and planned,
  /// admitted, run through the real descriptor-bound dispatcher (the real CLI
  /// at its canonical path) and read, over one store at the same fixed root.
  /// Every answer, the Job's files and every Artifact file are recorded for
  /// the Rust replay (`arktrace_reviewed.rs`), when
  /// `ARKDECK_REVIEWED_ARKTRACE_DESCRIPTOR` names the distribution and
  /// `ARKDECK_REVIEWED_ARKTRACE_JOB_RECORD` the new directory to record into.
  func testSwiftSummarizesTheFixtureTraceWithTheReviewedDistribution() async throws {
    let environment = ProcessInfo.processInfo.environment
    guard let descriptor = environment["ARKDECK_REVIEWED_ARKTRACE_DESCRIPTOR"],
      let record = environment["ARKDECK_REVIEWED_ARKTRACE_JOB_RECORD"]
    else {
      throw XCTSkip(
        "set ARKDECK_REVIEWED_ARKTRACE_DESCRIPTOR and ARKDECK_REVIEWED_ARKTRACE_JOB_RECORD")
    }
    let output = URL(filePath: record, directoryHint: .isDirectory)
    guard output.path.hasPrefix("/private/tmp/"),
      !FileManager.default.fileExists(atPath: output.path)
    else { throw CocoaError(.fileWriteFileExists) }
    let lock = try ArkTraceProfileLoaderOracleContractTests.lock()
    defer { close(lock) }
    let manager = FileManager.default
    try? manager.removeItem(atPath: Self.root)
    defer { try? manager.removeItem(atPath: Self.root) }
    try ArkTraceProfileLoaderOracleContractTests.directory(Self.root, mode: 0o700)
    let profiles = try await ArkTraceSummaryAnalyzerProfileLoader(
      doctor: ProductionArkTraceDoctorProbe(homeURL: URL(filePath: "\(Self.root)/home")),
      snapshotRootURL: URL(filePath: "\(Self.root)/snapshots", directoryHint: .isDirectory))
      .loadProfiles(descriptorURL: URL(filePath: descriptor))
    let artifacts = URL(filePath: "\(Self.root)/artifacts", directoryHint: .isDirectory)
    let store = try RuntimeArtifactStore(
      rootURL: artifacts, quota: ArtifactQuota(totalBytes: 64 * 1024 * 1024),
      redaction: ArtifactRedactionPolicy(homeDirectory: "\(Self.root)/home"),
      nowUTC: { Self.nowUTC })
    let jobsState = URL(filePath: "\(Self.root)/jobs-state", directoryHint: .isDirectory)
    let capabilities = try RuntimeCapabilityStore(
      directoryURL: jobsState.appending(path: "capabilities", directoryHint: .isDirectory))
    let provider = try AnalyzerProvider(profiles: profiles)
    let engine = try RuntimeJobEngine(
      configuration: .init(stateDirectory: jobsState),
      providers: DeviceProviderRegistry(providers: [provider]),
      dispatcher: DescriptorBoundProcessDispatcher(
        resolver: try AnalyzerExecutableResolver(profiles: profiles)),
      capabilityStore: capabilities, artifactStore: store,
      nowUTC: { Self.nowUTC }, nowPreciseUTC: { Self.nowPreciseUTC })
    let handler = RuntimeControlPlaneHandler(
      engine: engine, capabilityStore: capabilities, providerIDs: [provider.providerID],
      nowUTC: { Self.nowUTC }, targetStore: nil, bootstrap: nil, artifactStore: store,
      flashBundleImportDirectory: nil, flashBundleImportPolicy: .production,
      methodObserver: nil)
    let trace = try Data(
      contentsOf: Self.repository.appending(path: "Packages/ArkDeckKit/Fixtures/traces/zlib.htrace"))
    let source = try await store.publish(
      RuntimeArtifactPublicationRequest(
        jobID: "job-reviewed-source", sessionID: "HTASK-REVIEWEDTRACE", stepID: "capture-trace",
        name: "zlib.htrace", mediaType: "application/octet-stream", privacy: .standard,
        retentionClass: .default, sourceOperation: "capture.diagnostics@1", providerID: "hdc",
        bindingSnapshot: ArtifactBindingSnapshot(
          targetID: Self.target, bindingRevision: 3,
          stableIdentitySHA256: String(repeating: "c", count: 64)),
        contents: trace))
    let lease = try await store.leaseReference(jobID: source.jobID, artifactID: source.artifactID)
    let fields: [String: JSONValue] = [
      "documentType": .string("runtime-operation-request"),
      "schemaVersion": .string("1.0.0"),
      "requestId": .string("req-reviewed-trace-summary"),
      "idempotencyKey": .string("idem-reviewed-trace-summary-0001"),
      "target": .object(["targetId": .string(Self.target)]),
      "operation": .object([
        "id": .string("analyzer.summarize-trace"), "version": .integer(1),
      ]),
      "inputs": .object(["sourceArtifactRef": .string(lease)]),
    ]
    let request = try CanonicalJSONEncoders.canonical().encode(JSONValue.object(fields))
    let params: [String: JSONValue] = [
      "requestJson": .string(String(decoding: request, as: UTF8.self))
    ]
    var answers: [String: JSONValue] = [
      "job.plan": try await Self.send(handler, "job.plan", params)
    ]
    let accepted = try await Self.send(handler, "job.submit", params)
    answers["job.submit"] = accepted
    guard case .object(let fields) = accepted, case .object(let result)? = fields["result"],
      case .string(let jobID)? = result["jobId"]
    else { throw CocoaError(.coderInvalidValue) }
    let run = try await Self.send(handler, "job.run", ["jobId": .string(jobID)])
    answers["job.run"] = run
    guard case .object(let ran) = run, case .object(let state)? = ran["result"] else {
      throw CocoaError(.coderInvalidValue)
    }
    XCTAssertEqual(state["state"], .string("succeeded"))
    for method in ["job.status", "job.show", "job.result", "job.evidence"] {
      answers[method] = try await Self.send(handler, method, ["jobId": .string(jobID)])
    }
    let encoder = JSONEncoder()
    encoder.outputFormatting = [.sortedKeys, .prettyPrinted, .withoutEscapingSlashes]
    var files: [String: Data] = [
      "requests.json": try encoder.encode(JSONValue.object(["job.plan": .object(params)]))
        + Data("\n".utf8),
      "answers.json": try encoder.encode(JSONValue.object(answers)) + Data("\n".utf8),
      "profiles.json": try encoder.encode(
        JSONValue.array(profiles.map(ArkTraceProfileLoaderOracleContractTests.projection)))
        + Data("\n".utf8),
    ]
    for job in try manager.contentsOfDirectory(atPath: artifacts.path).sorted()
    where !job.hasPrefix(".") {
      let directory = artifacts.appending(path: job, directoryHint: .isDirectory)
      for name in try manager.contentsOfDirectory(atPath: directory.path).sorted()
      where !name.hasPrefix(".") {
        files["artifacts/\(job)/\(name)"] = try Data(contentsOf: directory.appending(path: name))
      }
    }
    let jobs = jobsState.appending(path: "jobs", directoryHint: .isDirectory)
    for job in try manager.contentsOfDirectory(atPath: jobs.path).sorted() {
      let directory = jobs.appending(path: job, directoryHint: .isDirectory)
      for name in try manager.contentsOfDirectory(atPath: directory.path).sorted() {
        files["store/jobs/\(job)/\(name)"] = try Data(contentsOf: directory.appending(path: name))
      }
    }
    for (path, data) in files {
      let url = output.appending(path: path)
      try manager.createDirectory(
        at: url.deletingLastPathComponent(), withIntermediateDirectories: true,
        attributes: [.posixPermissions: 0o700])
      try data.write(to: url)
    }
  }

  /// Host acceptance of `analyzer.analyze-trace@1` with the reviewed
  /// distribution: the repository's `zlib.htrace` published as a source, then
  /// a context window and a long-slice analysis of it planned, admitted, run
  /// with the real CLI and read, over one store at the same fixed root. The
  /// answers, the Jobs' files and every Artifact file are recorded for the
  /// Rust replay (`arktrace_reviewed.rs`), when
  /// `ARKDECK_REVIEWED_ARKTRACE_DESCRIPTOR` names the distribution and
  /// `ARKDECK_REVIEWED_ARKTRACE_ANALYSIS_RECORD` the new directory to record
  /// into.
  func testSwiftAnalyzesTheFixtureTraceWithTheReviewedDistribution() async throws {
    let environment = ProcessInfo.processInfo.environment
    guard let descriptor = environment["ARKDECK_REVIEWED_ARKTRACE_DESCRIPTOR"],
      let record = environment["ARKDECK_REVIEWED_ARKTRACE_ANALYSIS_RECORD"]
    else {
      throw XCTSkip(
        "set ARKDECK_REVIEWED_ARKTRACE_DESCRIPTOR and ARKDECK_REVIEWED_ARKTRACE_ANALYSIS_RECORD")
    }
    let output = URL(filePath: record, directoryHint: .isDirectory)
    guard output.path.hasPrefix("/private/tmp/"),
      !FileManager.default.fileExists(atPath: output.path)
    else { throw CocoaError(.fileWriteFileExists) }
    let lock = try ArkTraceProfileLoaderOracleContractTests.lock()
    defer { close(lock) }
    let manager = FileManager.default
    try? manager.removeItem(atPath: Self.root)
    defer { try? manager.removeItem(atPath: Self.root) }
    try ArkTraceProfileLoaderOracleContractTests.directory(Self.root, mode: 0o700)
    let profiles = try await ArkTraceSummaryAnalyzerProfileLoader(
      doctor: ProductionArkTraceDoctorProbe(homeURL: URL(filePath: "\(Self.root)/home")),
      snapshotRootURL: URL(filePath: "\(Self.root)/snapshots", directoryHint: .isDirectory))
      .loadProfiles(descriptorURL: URL(filePath: descriptor))
    let artifacts = URL(filePath: "\(Self.root)/artifacts", directoryHint: .isDirectory)
    let store = try RuntimeArtifactStore(
      rootURL: artifacts, quota: ArtifactQuota(totalBytes: 64 * 1024 * 1024),
      redaction: ArtifactRedactionPolicy(homeDirectory: "\(Self.root)/home"),
      nowUTC: { Self.nowUTC })
    let jobsState = URL(filePath: "\(Self.root)/jobs-state", directoryHint: .isDirectory)
    let capabilities = try RuntimeCapabilityStore(
      directoryURL: jobsState.appending(path: "capabilities", directoryHint: .isDirectory))
    let provider = try AnalyzerProvider(profiles: profiles)
    let engine = try RuntimeJobEngine(
      configuration: .init(stateDirectory: jobsState),
      providers: DeviceProviderRegistry(providers: [provider]),
      dispatcher: DescriptorBoundProcessDispatcher(
        resolver: try AnalyzerExecutableResolver(profiles: profiles)),
      capabilityStore: capabilities, artifactStore: store,
      nowUTC: { Self.nowUTC }, nowPreciseUTC: { Self.nowPreciseUTC })
    let handler = RuntimeControlPlaneHandler(
      engine: engine, capabilityStore: capabilities, providerIDs: [provider.providerID],
      nowUTC: { Self.nowUTC }, targetStore: nil, bootstrap: nil, artifactStore: store,
      flashBundleImportDirectory: nil, flashBundleImportPolicy: .production,
      methodObserver: nil)
    let trace = try Data(
      contentsOf: Self.repository.appending(path: "Packages/ArkDeckKit/Fixtures/traces/zlib.htrace"))
    let source = try await store.publish(
      RuntimeArtifactPublicationRequest(
        jobID: "job-reviewed-source", sessionID: "HTASK-REVIEWEDTRACE", stepID: "capture-trace",
        name: "zlib.htrace", mediaType: "application/octet-stream", privacy: .standard,
        retentionClass: .default, sourceOperation: "capture.diagnostics@1", providerID: "hdc",
        bindingSnapshot: ArtifactBindingSnapshot(
          targetID: Self.target, bindingRevision: 3,
          stableIdentitySHA256: String(repeating: "c", count: 64)),
        contents: trace))
    let lease = try await store.leaseReference(jobID: source.jobID, artifactID: source.artifactID)
    let analyses: [(name: String, inputs: [String: JSONValue])] = [
      ("context", [
        "kind": .string("context"), "timestampNs": .integer(16_000_000_000),
        "timeoutMs": .integer(30_000), "maxRows": .integer(100), "maxEvents": .integer(1_000),
        "maxOutputBytes": .integer(1_048_576),
      ]),
      ("slices", [
        "kind": .string("slices"), "startNs": .integer(0), "endNs": .integer(32_210_627_000),
        "thresholdNs": .integer(1_000_000), "limit": .integer(10),
        "timeoutMs": .integer(30_000), "maxRows": .integer(100), "maxEvents": .integer(10_000),
        "maxOutputBytes": .integer(1_048_576),
      ]),
    ]
    var requests: [String: JSONValue] = [:]
    var answers: [String: JSONValue] = [:]
    for analysis in analyses {
      var inputs = analysis.inputs
      inputs["sourceArtifactRef"] = .string(lease)
      let fields: [String: JSONValue] = [
        "documentType": .string("runtime-operation-request"),
        "schemaVersion": .string("1.0.0"),
        "requestId": .string("req-reviewed-trace-\(analysis.name)"),
        "idempotencyKey": .string("idem-reviewed-trace-\(analysis.name)-0001"),
        "target": .object(["targetId": .string(Self.target)]),
        "operation": .object([
          "id": .string("analyzer.analyze-trace"), "version": .integer(1),
        ]),
        "inputs": .object(inputs),
      ]
      let request = try CanonicalJSONEncoders.canonical().encode(JSONValue.object(fields))
      let params: [String: JSONValue] = [
        "requestJson": .string(String(decoding: request, as: UTF8.self))
      ]
      requests[analysis.name] = .object(params)
      var answered: [String: JSONValue] = [
        "job.plan": try await Self.send(handler, "job.plan", params)
      ]
      let accepted = try await Self.send(handler, "job.submit", params)
      answered["job.submit"] = accepted
      guard case .object(let fields) = accepted, case .object(let result)? = fields["result"],
        case .string(let jobID)? = result["jobId"]
      else { throw CocoaError(.coderInvalidValue) }
      let run = try await Self.send(handler, "job.run", ["jobId": .string(jobID)])
      answered["job.run"] = run
      guard case .object(let ran) = run, case .object(let state)? = ran["result"] else {
        throw CocoaError(.coderInvalidValue)
      }
      XCTAssertEqual(state["state"], .string("succeeded"), analysis.name)
      for method in ["job.status", "job.show", "job.result", "job.evidence"] {
        answered[method] = try await Self.send(handler, method, ["jobId": .string(jobID)])
      }
      answers[analysis.name] = .object(answered)
    }
    let encoder = JSONEncoder()
    encoder.outputFormatting = [.sortedKeys, .prettyPrinted, .withoutEscapingSlashes]
    var files: [String: Data] = [
      "requests.json": try encoder.encode(JSONValue.object(requests)) + Data("\n".utf8),
      "answers.json": try encoder.encode(JSONValue.object(answers)) + Data("\n".utf8),
      "profiles.json": try encoder.encode(
        JSONValue.array(profiles.map(ArkTraceProfileLoaderOracleContractTests.projection)))
        + Data("\n".utf8),
    ]
    for job in try manager.contentsOfDirectory(atPath: artifacts.path).sorted()
    where !job.hasPrefix(".") {
      let directory = artifacts.appending(path: job, directoryHint: .isDirectory)
      for name in try manager.contentsOfDirectory(atPath: directory.path).sorted()
      where !name.hasPrefix(".") {
        files["artifacts/\(job)/\(name)"] = try Data(contentsOf: directory.appending(path: name))
      }
    }
    let jobs = jobsState.appending(path: "jobs", directoryHint: .isDirectory)
    for job in try manager.contentsOfDirectory(atPath: jobs.path).sorted() {
      let directory = jobs.appending(path: job, directoryHint: .isDirectory)
      for name in try manager.contentsOfDirectory(atPath: directory.path).sorted() {
        files["store/jobs/\(job)/\(name)"] = try Data(contentsOf: directory.appending(path: name))
      }
    }
    for (path, data) in files {
      let url = output.appending(path: path)
      try manager.createDirectory(
        at: url.deletingLastPathComponent(), withIntermediateDirectories: true,
        attributes: [.posixPermissions: 0o700])
      try data.write(to: url)
    }
  }

  /// One control frame through the handler, answered as the Job oracles
  /// record it.
  private static func send(
    _ handler: RuntimeControlPlaneHandler, _ method: String, _ params: [String: JSONValue]
  ) async throws -> JSONValue {
    let frame = try CanonicalJSONEncoders.canonical().encode(
      JSONValue.object([
        "protocolVersion": .string(ArkDeckControlProtocol.currentVersion),
        "contractIdentity": .string(ArkDeckControlProtocol.contractIdentity),
        "id": .string("arktrace-reviewed"), "method": .string(method),
        "params": .object(params),
      ]))
    let response = await handler.handleFrame(frame)
    var fields: [String: JSONValue] = ["ok": .bool(response.ok)]
    if let result = response.result { fields["result"] = result }
    if let error = response.error {
      var body: [String: JSONValue] = [
        "code": .string(error.code), "message": .string(error.message),
      ]
      if let details = error.details { body["details"] = .object(details) }
      fields["error"] = .object(body)
    }
    return .object(fields)
  }
}
