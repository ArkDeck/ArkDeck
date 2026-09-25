// Shared Swift oracle for the ArkTrace analyzers on a host without ArkTrace
// (CHG-2026-074, TASK-XPA-015).

import Darwin
import XCTest

@testable import ArkDeckAgentDaemon
@testable import ArkDeckCore
@testable import ArkDeckRuntime
@testable import ArkDeckStorage
@testable import ArkDeckWorkflows

/// What Swift's daemon answers for `analyzer.summarize-trace@1` and
/// `analyzer.analyze-trace@1` when no `ARKDECK_ARKTRACE_DESCRIPTOR` is named:
/// its composition (`main.swift`, here with the crash-ledger analyzer an
/// installed daemon's `ARKDECK_ANALYZER_PATH` names) gives the analyzer
/// provider no ArkTrace profile and names both analyzers unavailable as
/// `analyzer.arktraceNotFound`. The oracle
/// `rust/tests/fixtures/arktrace-absent` records, through the control-plane
/// handler over that provider, each operation's descriptor and the plan and
/// submission of a complete request over a raw Trace Artifact collected from
/// the Target — each refused before admission by that reason, with nothing
/// admitted — and the source Artifact's index and payload.
///
/// Record a new oracle with
/// `ARKDECK_RUST_ARKTRACE_ABSENT_RECORD=/private/tmp/<new directory>`;
/// otherwise the checked-in oracle must match byte for byte.
final class ArkTraceAbsentOracleContractTests: XCTestCase {
  private static let repository: URL = {
    var url = URL(filePath: #filePath)
    for _ in 0..<5 { url.deleteLastPathComponent() }
    return url
  }()
  private static let oracle = repository.appending(
    path: "rust/tests/fixtures/arktrace-absent", directoryHint: .isDirectory)
  private static let root = URL(
    filePath: "/private/tmp/arkdeck-job-plan-oracle", directoryHint: .isDirectory)
  private static let lockPath = "/private/tmp/arkdeck-job-plan-oracle.lock"
  private static let nowUTC = "2026-09-14T00:00:00Z"
  private static let nowPreciseUTC = "2026-09-14T00:00:00.000Z"
  private static let sourceJob = "job-oracle-source"
  private static let target = "TGT-ORACLE"

  func testSwiftAnswersTheArkTraceAnalyzersWithoutArkTrace() async throws {
    let lock = open(Self.lockPath, O_RDWR | O_CREAT | O_CLOEXEC, 0o600)
    guard lock >= 0, flock(lock, LOCK_EX) == 0 else { throw POSIXError(.EBUSY) }
    defer { close(lock) }
    try HDCOracleHarness.recordOrCompare(
      try await oracleFiles(), variable: "ARKDECK_RUST_ARKTRACE_ABSENT_RECORD",
      oracle: Self.oracle)
  }

  private static func request(
    _ operation: String, _ inputs: [String: JSONValue]
  ) throws -> [String: JSONValue] {
    let fields: [String: JSONValue] = [
      "documentType": .string("runtime-operation-request"),
      "schemaVersion": .string("1.0.0"),
      "requestId": .string("req-oracle-\(operation)"),
      "idempotencyKey": .string("idem-oracle-\(operation)-0001"),
      "target": .object(["targetId": .string(Self.target)]),
      "operation": .object(["id": .string(operation), "version": .integer(1)]),
      "inputs": .object(inputs),
    ]
    let bytes = try CanonicalJSONEncoders.canonical().encode(JSONValue.object(fields))
    return ["requestJson": .string(String(decoding: bytes, as: UTF8.self))]
  }

  private func oracleFiles() async throws -> [String: Data] {
    let manager = FileManager.default
    try? manager.removeItem(at: Self.root)
    try manager.createDirectory(
      at: Self.root, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
    defer { try? manager.removeItem(at: Self.root) }
    let artifacts = Self.root.appending(path: "artifacts", directoryHint: .isDirectory)
    let store = try RuntimeArtifactStore(rootURL: artifacts, nowUTC: { Self.nowUTC })
    let jobsState = Self.root.appending(path: "jobs-state", directoryHint: .isDirectory)
    let capabilities = try RuntimeCapabilityStore(
      directoryURL: jobsState.appending(path: "capabilities", directoryHint: .isDirectory))
    // `main.swift` with `ARKDECK_ANALYZER_PATH` naming an analyzer that is
    // not the daemon, as an installed daemon names one, and without
    // `ARKDECK_ARKTRACE_DESCRIPTOR`: the crash-ledger analyzer and its
    // dispatcher, the HiLog summary unavailable by name, and both ArkTrace
    // analyzers unavailable as not found.
    let analyzerBytes = Data("#!/bin/sh\n# ArkTrace-absent oracle analyzer; never run.\nexit 64\n".utf8)
    let analyzer = Self.root.appending(path: "analyzer")
    try analyzerBytes.write(to: analyzer)
    guard chmod(analyzer.path, 0o700) == 0 else { throw POSIXError(.EPERM) }
    let crashLedger = AnalyzerProfile(
      analyzerRef: HarnessCrashLedgerAnalysis.analyzerRef,
      analyzerVersion: HarnessCrashLedgerAnalysis.analyzerVersion,
      executablePath: analyzer.path, executableSHA256: AnalyzerProvider.sha256(analyzerBytes),
      fixedArguments: ["--analyze-crash-ledger"], timeoutSeconds: 30)
    let provider = try AnalyzerProvider(
      profiles: [crashLedger],
      unavailableReasons: [
        HilogSummaryDerivedAnalyzer.analyzerRef:
          HilogSummaryDerivedAnalyzer.incompatibleExecutableReason,
        "trace-summary@1": ArkTraceSummaryProfileError.notFound.reason,
        "trace-analysis@1": ArkTraceSummaryProfileError.notFound.reason,
      ])
    let engine = try RuntimeJobEngine(
      configuration: .init(stateDirectory: jobsState),
      providers: DeviceProviderRegistry(providers: [provider]),
      dispatcher: DescriptorBoundProcessDispatcher(
        resolver: try AnalyzerExecutableResolver(profiles: [crashLedger])),
      capabilityStore: capabilities, artifactStore: store,
      nowUTC: { Self.nowUTC }, nowPreciseUTC: { Self.nowPreciseUTC })
    let handler = RuntimeControlPlaneHandler(
      engine: engine, capabilityStore: capabilities, providerIDs: [provider.providerID],
      nowUTC: { Self.nowUTC }, targetStore: nil, bootstrap: nil, artifactStore: store,
      flashBundleImportDirectory: nil, flashBundleImportPolicy: .production,
      methodObserver: nil)

    // A raw Trace, as `capture.diagnostics@1` publishes one.
    let source = try await store.publish(
      RuntimeArtifactPublicationRequest(
        jobID: Self.sourceJob, sessionID: "HTASK-ARKTRACEABSENT", stepID: "capture-trace",
        name: "trace.htrace", mediaType: "application/octet-stream", privacy: .sensitive,
        retentionClass: .default, sourceOperation: "capture.diagnostics@1", providerID: "hdc",
        bindingSnapshot: ArtifactBindingSnapshot(
          targetID: Self.target, bindingRevision: 3,
          stableIdentitySHA256: String(repeating: "c", count: 64)),
        contents: Data("ArkTrace-absent oracle trace bytes\n".utf8)))
    let lease = try await store.leaseReference(
      jobID: source.jobID, artifactID: source.artifactID)

    var exchanges: [JSONValue] = []
    for (operation, inputs) in [
      ("analyzer.summarize-trace", ["sourceArtifactRef": JSONValue.string(lease)]),
      (
        "analyzer.analyze-trace",
        [
          "sourceArtifactRef": .string(lease), "kind": .string("cpu"),
          "startNs": .integer(0), "endNs": .integer(1_000_000),
          "timeoutMs": .integer(10_000), "maxRows": .integer(100), "maxEvents": .integer(100),
          "maxOutputBytes": .integer(65_536),
        ]
      ),
    ] {
      let reference = "\(operation)@1"
      let describe: [String: JSONValue] = ["reference": .string(reference)]
      exchanges.append(
        HDCOracleHarness.exchange(
          "\(operation).describe", "operation.describe", describe,
          try await HDCOracleHarness.send(
            handler, "operation.describe", describe, frameID: "arktrace-absent-oracle")))
      let plan = try Self.request(operation, inputs)
      for method in ["job.plan", "job.submit"] {
        exchanges.append(
          HDCOracleHarness.exchange(
            "\(operation).\(method == "job.plan" ? "plan" : "submit")", method, plan,
            try await HDCOracleHarness.send(
              handler, method, plan, frameID: "arktrace-absent-oracle")))
      }
    }

    let encoder = JSONEncoder()
    encoder.outputFormatting = [.sortedKeys, .prettyPrinted, .withoutEscapingSlashes]
    var files: [String: Data] = [
      "cases.json": try encoder.encode(
        JSONValue.object([
          "source": .object([
            "jobId": .string(source.jobID), "artifactId": .string(source.artifactID),
            "lease": .string(lease),
          ]),
          "exchanges": .array(exchanges),
        ])) + Data("\n".utf8)
    ]
    for entry in try manager.contentsOfDirectory(atPath: artifacts.path).sorted()
    where !entry.hasPrefix(".") {
      let directory = artifacts.appending(path: entry)
      for name in try manager.contentsOfDirectory(atPath: directory.path).sorted()
      where !name.hasPrefix(".") {
        files["artifacts/\(entry)/\(name)"] = try Data(contentsOf: directory.appending(path: name))
      }
    }
    files["analyzer"] = analyzerBytes
    var digests: [String: JSONValue] = [:]
    for (path, data) in files { digests[path] = .string(SHA256Hex.string(of: data)) }
    files["provenance.json"] =
      try encoder.encode(
        JSONValue.object([
          "producer": .string(
            "ArkTraceAbsentOracleContractTests.testSwiftAnswersTheArkTraceAnalyzersWithoutArkTrace"),
          "root": .string(Self.root.path),
          "nowUTC": .string(Self.nowUTC),
          "files": .object(digests),
        ])) + Data("\n".utf8)
    return files
  }
}
