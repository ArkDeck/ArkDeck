// Shared Swift oracle for the Rust `job.run` analyzer runner (CHG-2026-074, TASK-XPA-014).

import CryptoKit
import Darwin
import SQLite3
import XCTest

@testable import ArkDeckAgentDaemon
@testable import ArkDeckCore
@testable import ArkDeckRuntime
@testable import ArkDeckStorage
@testable import ArkDeckWorkflows

/// Swift `job.run` for `analyzer.extract-crash-signature@1`: the oracle
/// `rust/crates/arkdeck-hoststore/tests/job_run.rs` replays against the Rust
/// runner. Each case admits one Job over its own source crash log, whose first
/// line tells the oracle analyzer which answer to give, and the Jobs then run
/// in order over one store: successes publish their derived Artifact until the
/// Artifact quota refuses one, each semantic check refuses its own answer, a
/// timeout and a signal leave the outcome unknown, and runs of absent,
/// terminal and parked Jobs are refused before any dispatch. The oracle keeps
/// every answer; how `job.status`, `job.show`, `job.result` and `job.evidence`
/// then read each Job, how every Job read answers an absent Job, and how the
/// result and evidence reads refuse open options; and the store the runs leave:
/// the Job index and files and every Artifact index and payload.
///
/// The engine runs the real descriptor-bound process dispatcher and no Session
/// publication writer, the composition the Rust runner reproduces. It runs
/// under the `job.plan` oracle's fixed physical root and lock, since the plan
/// digest covers the source Artifact's absolute path. Record a new oracle with
/// `ARKDECK_RUST_JOB_RUN_RECORD=/private/tmp/<new directory>`; otherwise the
/// checked-in oracle must match byte for byte.
final class JobRunAnalyzerOracleContractTests: XCTestCase {
  private struct Case {
    let name: String
    /// Admits a Job over a source whose first line is this mode.
    var mode: String?
    /// The state a run of this case's Job ends in.
    var ends: String?
    /// Runs the Job an earlier case admitted.
    var rerun: String?
    /// An exact refused request, in a shape the corpus already publishes.
    var params: [String: JSONValue]?
    /// The source's payload is removed after admission, before the run.
    var removesSourcePayload = false
    /// The storage probe reports no free bytes while this Job runs.
    var exhaustsStorage = false
    /// A directory already holds this Job's Session path before it runs.
    var presetsSession = false
  }

  private static let repository: URL = {
    var url = URL(filePath: #filePath)
    for _ in 0..<5 { url.deleteLastPathComponent() }
    return url
  }()
  private static let oracle = repository.appending(
    path: "rust/tests/fixtures/job-run-analyzer", directoryHint: .isDirectory)
  private static let root = URL(
    filePath: "/private/tmp/arkdeck-job-plan-oracle", directoryHint: .isDirectory)
  private static let lockPath = "/private/tmp/arkdeck-job-plan-oracle.lock"
  private static let nowUTC = "2026-09-14T00:00:00Z"
  private static let nowPreciseUTC = "2026-09-14T00:00:00.000Z"
  private static let absentJob = "job-00000000000000000000000000000000"
  private static let sourceJob = "job-oracle-source"
  private static let removedSourceJob = "job-oracle-source-removed"
  private static let target = "TGT-ORACLE"
  /// Redaction replaces this home directory; the `secret` answer names it.
  private static let home = "/private/tmp/arkdeck-job-plan-oracle/home"
  /// Small enough that the `quota` answer cannot be published.
  private static let quotaBytes = 32 * 1024
  /// Short enough that the `sleep` answer times out.
  private static let timeoutSeconds = 2
  private static let analyzerBytes = Data(
    #"""
    #!/bin/sh
    # ArkDeck job.run oracle analyzer. The first line of the source it is given
    # names its answer; nothing else is read.
    [ "$#" -eq 2 ] && [ "$1" = "--analyze-crash-ledger" ] || exit 64
    IFS= read -r mode < "$2" || exit 66
    case "$mode" in
    answered)
      printf '%s\n' '{"status":"answered","schemaVersion":"1.0.0","extra":{"ignored":true},"analyzerVersion":"arkdeck-fault-log-ledger@1","analyzerRef":"crash-signature@1","entries":[{"uid":"20010045","timestamp":"20260914000000","name":"jscrash-com.example.oracle-20010045-20260914000000","kind":"jscrash","bundle":"com.example/oracle-崩溃","note":"ignored"}],"unreadableReason":null}' ;;
    unreadable)
      printf '%s' '{"analyzerRef":"crash-signature@1","analyzerVersion":"arkdeck-fault-log-ledger@1","entries":[],"schemaVersion":"1.0.0","status":"unreadable","unreadableReason":"the listing has no Fault log list header"}' ;;
    secret)
      printf '%s' '{"analyzerRef":"crash-signature@1","analyzerVersion":"arkdeck-fault-log-ledger@1","entries":[{"bundle":"password=hunter2hunter2","kind":"cppcrash","name":"/private/tmp/arkdeck-job-plan-oracle/home/Library/cppcrash-1","timestamp":"20260914000001","uid":"api_key: abcdef1234"}],"schemaVersion":"1.0.0","status":"answered"}' ;;
    empty) ;;
    exit) printf 'oracle analyzer failed\n' >&2; exit 3 ;;
    malformed) printf 'crash signature: none\n' ;;
    scalar) printf '"answered"' ;;
    mismatch)
      printf '%s' '{"analyzerRef":"crash-signature@1","analyzerVersion":"arkdeck-fault-log-ledger@2","entries":[],"schemaVersion":"1.0.0","status":"answered"}' ;;
    badentry)
      printf '%s' '{"analyzerRef":"crash-signature@1","analyzerVersion":"arkdeck-fault-log-ledger@1","entries":[{"name":"jscrash-only-a-name"}],"schemaVersion":"1.0.0","status":"answered"}' ;;
    bigstdout) /usr/bin/head -c 9437184 /dev/zero ;;
    bigstderr)
      /usr/bin/head -c 9437184 /dev/zero >&2
      printf '%s' '{"analyzerRef":"crash-signature@1","analyzerVersion":"arkdeck-fault-log-ledger@1","entries":[],"schemaVersion":"1.0.0","status":"answered"}' ;;
    sleep) /bin/sleep 5 ;;
    signal) kill -KILL "$$" ;;
    quota)
      printf '%s' '{"analyzerRef":"crash-signature@1","analyzerVersion":"arkdeck-fault-log-ledger@1","entries":['
      i=0
      while [ "$i" -lt 600 ]; do
        [ "$i" -gt 0 ] && printf ','
        printf '{"bundle":"com.example.quota","kind":"jscrash","name":"jscrash-com.example.quota-%d","timestamp":"20260914000000","uid":"%d"}' "$i" "$i"
        i=$((i + 1))
      done
      printf '%s' '],"schemaVersion":"1.0.0","status":"answered"}' ;;
    *) exit 65 ;;
    esac

    """#.utf8)

  func testSwiftRunsTheSharedAnalyzerOracle() async throws {
    let lock = try Self.lockOracleRoot()
    defer { close(lock) }
    try Self.recordOrCompare(
      try await oracleFiles(), oracle: Self.oracle, variable: "ARKDECK_RUST_JOB_RUN_RECORD")
  }

  /// The Session publication oracle `rust/crates/arkdeck-hoststore/tests/
  /// job_publication.rs` replays: the same engine composed with the
  /// standalone daemon's publication writer, over a Sessions root and storage
  /// owner of its own. Record it with
  /// `ARKDECK_RUST_JOB_PUBLICATION_RECORD=/private/tmp/<new directory>`.
  func testSwiftPublishesTheSharedAnalyzerSessions() async throws {
    let lock = try Self.lockOracleRoot()
    defer { close(lock) }
    try Self.recordOrCompare(
      try await publicationFiles(), oracle: Self.publicationOracle,
      variable: "ARKDECK_RUST_JOB_PUBLICATION_RECORD")
  }

  /// Serializes every user of the fixed root, Rust replays included.
  private static func lockOracleRoot() throws -> Int32 {
    let lock = open(lockPath, O_RDWR | O_CREAT | O_CLOEXEC, 0o600)
    guard lock >= 0 else { throw POSIXError(.EACCES) }
    guard flock(lock, LOCK_EX) == 0 else {
      close(lock)
      throw POSIXError(.EBUSY)
    }
    return lock
  }

  /// Writes a new oracle when `variable` names a new directory under
  /// `/private/tmp`; otherwise the checked-in oracle must match byte for byte.
  private static func recordOrCompare(
    _ files: [String: Data], oracle: URL, variable: String
  ) throws {
    if let output = ProcessInfo.processInfo.environment[variable] {
      let destination = URL(fileURLWithPath: output, isDirectory: true)
      guard destination.path.hasPrefix("/private/tmp/"),
        !FileManager.default.fileExists(atPath: destination.path)
      else { throw CocoaError(.fileWriteFileExists) }
      for (path, data) in files {
        let url = destination.appending(path: path)
        try FileManager.default.createDirectory(
          at: url.deletingLastPathComponent(), withIntermediateDirectories: true,
          attributes: [.posixPermissions: 0o700])
        try data.write(to: url)
      }
      return
    }
    let recorded = try FileManager.default.subpathsOfDirectory(atPath: oracle.path)
      .filter { path in
        var directory: ObjCBool = false
        FileManager.default.fileExists(
          atPath: oracle.appending(path: path).path, isDirectory: &directory)
        return !directory.boolValue
      }
    XCTAssertEqual(Set(recorded), Set(files.keys))
    for (path, data) in files {
      XCTAssertEqual(try Data(contentsOf: oracle.appending(path: path)), data, path)
    }
  }

  private static let publicationOracle = repository.appending(
    path: "rust/tests/fixtures/job-publication-analyzer", directoryHint: .isDirectory)

  /// The publication oracle's Jobs, run in order over one store: a success
  /// and a failure each published as a Session, a parked Job that publishes
  /// nothing, a full volume that leaves the publication waiting for storage,
  /// a Session path something else already holds, and a Job whose source
  /// disappears before it runs.
  private static let publicationCases: [Case] = [
    Case(name: "published", mode: "answered", ends: "succeeded"),
    Case(name: "publishedFailure", mode: "empty", ends: "failed"),
    Case(name: "parked", mode: "signal", ends: "waitingForRecovery"),
    Case(name: "waitingForStorage", mode: "answered", ends: "succeeded", exhaustsStorage: true),
    Case(name: "sessionExists", mode: "answered", ends: "succeeded", presetsSession: true),
    Case(name: "sourceRemoved", mode: "answered", ends: "failed", removesSourcePayload: true),
  ]

  private static let cases: [Case] = [
    Case(name: "answered", mode: "answered", ends: "succeeded"),
    Case(name: "unreadable", mode: "unreadable", ends: "succeeded"),
    Case(name: "redacted", mode: "secret", ends: "succeeded"),
    Case(name: "emptyResult", mode: "empty", ends: "failed"),
    Case(name: "nonZeroExit", mode: "exit", ends: "failed"),
    Case(name: "malformedResult", mode: "malformed", ends: "failed"),
    Case(name: "scalarResult", mode: "scalar", ends: "failed"),
    Case(name: "versionMismatch", mode: "mismatch", ends: "failed"),
    Case(name: "undecodableEntry", mode: "badentry", ends: "failed"),
    Case(name: "truncatedStdout", mode: "bigstdout", ends: "failed"),
    Case(name: "truncatedStderr", mode: "bigstderr", ends: "failed"),
    Case(name: "timedOut", mode: "sleep", ends: "waitingForRecovery"),
    Case(name: "signalled", mode: "signal", ends: "waitingForRecovery"),
    Case(name: "quotaExceeded", mode: "quota", ends: "failed"),
    Case(name: "rerunSucceeded", rerun: "answered"),
    Case(name: "rerunFailed", rerun: "emptyResult"),
    Case(name: "rerunParked", rerun: "timedOut"),
    Case(name: "absentJob", params: ["jobId": .string("job-00000000000000000000000000000000")]),
    Case(name: "missingJobId", params: [:]),
    // Last: a removed payload leaves its source Job's Artifact index
    // unverifiable, and a later publication would have to census it.
    Case(name: "sourceRemoved", mode: "answered", ends: "failed", removesSourcePayload: true),
  ]

  private func oracleFiles() async throws -> [String: Data] {
    let manager = FileManager.default
    try? manager.removeItem(at: Self.root)
    try manager.createDirectory(
      at: Self.root, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
    defer { try? manager.removeItem(at: Self.root) }
    let analyzer = Self.root.appending(path: "analyzer")
    try Self.analyzerBytes.write(to: analyzer)
    guard chmod(analyzer.path, 0o700) == 0 else { throw POSIXError(.EPERM) }
    let artifacts = Self.root.appending(path: "artifacts", directoryHint: .isDirectory)
    let store = try RuntimeArtifactStore(
      rootURL: artifacts, quota: ArtifactQuota(totalBytes: Self.quotaBytes),
      redaction: ArtifactRedactionPolicy(homeDirectory: Self.home), nowUTC: { Self.nowUTC })
    let profile = AnalyzerProfile(
      analyzerRef: HarnessCrashLedgerAnalysis.analyzerRef,
      analyzerVersion: HarnessCrashLedgerAnalysis.analyzerVersion,
      executablePath: analyzer.path,
      executableSHA256: AnalyzerProvider.sha256(Self.analyzerBytes),
      fixedArguments: ["--analyze-crash-ledger"], timeoutSeconds: Self.timeoutSeconds)
    let jobsState = Self.root.appending(path: "jobs-state", directoryHint: .isDirectory)
    let capabilities = try RuntimeCapabilityStore(
      directoryURL: jobsState.appending(path: "capabilities", directoryHint: .isDirectory))
    let provider = try AnalyzerProvider(profiles: [profile])
    let engine = try RuntimeJobEngine(
      configuration: .init(stateDirectory: jobsState),
      providers: DeviceProviderRegistry(providers: [provider]),
      dispatcher: DescriptorBoundProcessDispatcher(
        resolver: try AnalyzerExecutableResolver(profiles: [profile])),
      capabilityStore: capabilities, artifactStore: store,
      nowUTC: { Self.nowUTC }, nowPreciseUTC: { Self.nowPreciseUTC })
    let handler = RuntimeControlPlaneHandler(
      engine: engine, capabilityStore: capabilities, providerIDs: [provider.providerID],
      nowUTC: { Self.nowUTC }, targetStore: nil, bootstrap: nil, artifactStore: store,
      flashBundleImportDirectory: nil, flashBundleImportPolicy: .production,
      methodObserver: nil)

    // Every source first, then every admission: a run meets exactly the
    // store the Rust replay rebuilds before its first run.
    var sources: [String: (job: String, artifact: String, lease: String)] = [:]
    for item in Self.cases {
      guard let mode = item.mode else { continue }
      let job = item.removesSourcePayload ? Self.removedSourceJob : Self.sourceJob
      let source = try await store.publish(
        RuntimeArtifactPublicationRequest(
          jobID: job, sessionID: "HTASK-JOBRUNORACLE", stepID: "capture-crash-log",
          name: "crash-log-\(item.name).txt", mediaType: "text/plain", privacy: .standard,
          retentionClass: .default, sourceOperation: "capture.diagnostics@1", providerID: "hdc",
          bindingSnapshot: ArtifactBindingSnapshot(
            targetID: Self.target, bindingRevision: 3,
            stableIdentitySHA256: String(repeating: "c", count: 64)),
          contents: Data("\(mode)\nFault log list:\n******\n".utf8)))
      sources[item.name] = (
        job, source.artifactID,
        try await store.leaseReference(jobID: source.jobID, artifactID: source.artifactID)
      )
    }
    var submits: [String: [String: JSONValue]] = [:]
    var jobIDs: [String: String] = [:]
    for item in Self.cases where item.mode != nil {
      let params = try Self.submitParams(item.name, lease: sources[item.name]!.lease)
      let accepted = try await exchange(handler, "job.submit", params)
      guard case .object(let fields) = accepted, case .object(let result)? = fields["result"],
        result["deduplicated"] == .bool(false), case .string(let jobID)? = result["jobId"]
      else { throw CocoaError(.coderInvalidValue) }
      submits[item.name] = params
      jobIDs[item.name] = jobID
    }

    var recorded: [JSONValue] = []
    for item in Self.cases {
      var entry: [String: JSONValue] = ["name": .string(item.name)]
      let params: [String: JSONValue]
      if let mode = item.mode {
        let source = sources[item.name]!
        if item.removesSourcePayload {
          try manager.removeItem(
            at: artifacts.appending(path: source.job).appending(path: source.artifact))
          entry["removesSourcePayload"] = .string("\(source.job)/\(source.artifact)")
        }
        entry["mode"] = .string(mode)
        entry["submit"] = .object(submits[item.name]!)
        params = ["jobId": .string(jobIDs[item.name]!)]
      } else if let earlier = item.rerun {
        entry["rerun"] = .string(earlier)
        params = ["jobId": .string(jobIDs[earlier]!)]
      } else {
        params = item.params!
      }
      entry["params"] = .object(params)
      let response = try await exchange(handler, "job.run", params)
      check(response, item)
      entry["response"] = response
      recorded.append(.object(entry))
    }

    // How Swift then reads each Job it ran, its result and evidence included,
    // and how every Job read answers a Job that does not exist.
    var reads: [String: JSONValue] = [:]
    for item in Self.cases where item.mode != nil {
      let jobID = jobIDs[item.name]!
      var answers: [String: JSONValue] = [:]
      for method in ["job.status", "job.show", "job.result", "job.evidence"] {
        answers[method] = try await exchange(handler, method, ["jobId": .string(jobID)])
      }
      reads[jobID] = .object(answers)
    }
    var absent: [String: JSONValue] = [:]
    for method in [
      "job.status", "job.show", "job.result", "job.evidence", "job.timeline", "job.events",
    ] {
      absent[method] = try await exchange(handler, method, ["jobId": .string(Self.absentJob)])
    }
    reads[Self.absentJob] = .object(absent)
    // Closed read options, in the request shape the corpus already publishes.
    var refused: [JSONValue] = []
    for method in ["job.result", "job.evidence"] {
      refused.append(
        .object([
          "method": .string(method), "params": .object([:]),
          "response": try await exchange(handler, method, [:]),
        ]))
    }

    let encoder = JSONEncoder()
    encoder.outputFormatting = [.sortedKeys, .prettyPrinted, .withoutEscapingSlashes]
    var files: [String: Data] = [
      "analyzer": Self.analyzerBytes,
      "cases.json": try encoder.encode(JSONValue.array(recorded)) + Data("\n".utf8),
      "reads.json": try encoder.encode(JSONValue.object(reads)) + Data("\n".utf8),
      "refused-reads.json": try encoder.encode(JSONValue.array(refused)) + Data("\n".utf8),
      "store/index.json": try encoder.encode(try Self.index(of: jobsState)) + Data("\n".utf8),
    ]
    // Every Artifact index and payload; the payload-verification cache
    // records this machine's inodes and times, so it is no part of the oracle.
    for job in try manager.contentsOfDirectory(atPath: artifacts.path).sorted()
    where !job.hasPrefix(".") {
      let directory = artifacts.appending(path: job, directoryHint: .isDirectory)
      for name in try manager.contentsOfDirectory(atPath: directory.path).sorted()
      where !name.hasPrefix(".") {
        files["artifacts/\(job)/\(name)"] = try Data(contentsOf: directory.appending(path: name))
      }
    }
    // Every file each Job's directory holds.
    let jobs = jobsState.appending(path: "jobs", directoryHint: .isDirectory)
    for job in try manager.contentsOfDirectory(atPath: jobs.path).sorted() {
      let directory = jobs.appending(path: job, directoryHint: .isDirectory)
      for name in try manager.contentsOfDirectory(atPath: directory.path).sorted() {
        files["store/jobs/\(job)/\(name)"] = try Data(contentsOf: directory.appending(path: name))
      }
    }
    var digests: [String: JSONValue] = [:]
    for (path, data) in files { digests[path] = .string(Self.sha256(data)) }
    files["provenance.json"] =
      try encoder.encode(
        JSONValue.object([
          "producer": .string(
            "JobRunAnalyzerOracleContractTests/testSwiftRunsTheSharedAnalyzerOracle"),
          "root": .string(Self.root.path),
          "nowUTC": .string(Self.nowUTC),
          "nowPreciseUTC": .string(Self.nowPreciseUTC),
          "home": .string(Self.home),
          "quotaBytes": .integer(Int64(Self.quotaBytes)),
          "timeoutSeconds": .integer(Int64(Self.timeoutSeconds)),
          "files": .object(digests),
        ])) + Data("\n".utf8)
    return files
  }

  private func publicationFiles() async throws -> [String: Data] {
    let manager = FileManager.default
    try? manager.removeItem(at: Self.root)
    try manager.createDirectory(
      at: Self.root, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
    defer { try? manager.removeItem(at: Self.root) }
    let analyzer = Self.root.appending(path: "analyzer")
    try Self.analyzerBytes.write(to: analyzer)
    guard chmod(analyzer.path, 0o700) == 0 else { throw POSIXError(.EPERM) }
    let artifacts = Self.root.appending(path: "artifacts", directoryHint: .isDirectory)
    let store = try RuntimeArtifactStore(
      rootURL: artifacts, quota: ArtifactQuota(totalBytes: Self.quotaBytes),
      redaction: ArtifactRedactionPolicy(homeDirectory: Self.home), nowUTC: { Self.nowUTC })
    let profile = AnalyzerProfile(
      analyzerRef: HarnessCrashLedgerAnalysis.analyzerRef,
      analyzerVersion: HarnessCrashLedgerAnalysis.analyzerVersion,
      executablePath: analyzer.path,
      executableSHA256: AnalyzerProvider.sha256(Self.analyzerBytes),
      fixedArguments: ["--analyze-crash-ledger"], timeoutSeconds: Self.timeoutSeconds)
    let jobsState = Self.root.appending(path: "jobs-state", directoryHint: .isDirectory)
    let capabilities = try RuntimeCapabilityStore(
      directoryURL: jobsState.appending(path: "capabilities", directoryHint: .isDirectory))
    let provider = try AnalyzerProvider(profiles: [profile])
    // The standalone daemon's writer, over a storage owner and Sessions root
    // of this root's own, with a probe that can report the volume full.
    let sessions = Self.root.appending(path: "Sessions", directoryHint: .isDirectory)
    let owner = Self.root.appending(path: "session-owner", directoryHint: .isDirectory)
    let probe = OracleStorageProbe()
    let writer = RuntimeSessionPublicationWriter(
      owner: try RuntimeSessionStorageStore(ownerRoot: owner, defaultSessionsRoot: sessions),
      coordinator: HostStorageCoordinator(), probe: probe)
    let engine = try RuntimeJobEngine(
      configuration: .init(stateDirectory: jobsState, sessionPublicationWriter: writer),
      providers: DeviceProviderRegistry(providers: [provider]),
      dispatcher: DescriptorBoundProcessDispatcher(
        resolver: try AnalyzerExecutableResolver(profiles: [profile])),
      capabilityStore: capabilities, artifactStore: store,
      nowUTC: { Self.nowUTC }, nowPreciseUTC: { Self.nowPreciseUTC })
    let handler = RuntimeControlPlaneHandler(
      engine: engine, capabilityStore: capabilities, providerIDs: [provider.providerID],
      nowUTC: { Self.nowUTC }, targetStore: nil, bootstrap: nil, artifactStore: store,
      flashBundleImportDirectory: nil, flashBundleImportPolicy: .production,
      methodObserver: nil)

    var sources: [String: (job: String, artifact: String, lease: String)] = [:]
    for item in Self.publicationCases {
      let job = item.removesSourcePayload ? Self.removedSourceJob : Self.sourceJob
      let source = try await store.publish(
        RuntimeArtifactPublicationRequest(
          jobID: job, sessionID: "HTASK-JOBRUNORACLE", stepID: "capture-crash-log",
          name: "crash-log-\(item.name).txt", mediaType: "text/plain", privacy: .standard,
          retentionClass: .default, sourceOperation: "capture.diagnostics@1", providerID: "hdc",
          bindingSnapshot: ArtifactBindingSnapshot(
            targetID: Self.target, bindingRevision: 3,
            stableIdentitySHA256: String(repeating: "c", count: 64)),
          contents: Data("\(item.mode!)\nFault log list:\n******\n".utf8)))
      sources[item.name] = (
        job, source.artifactID,
        try await store.leaseReference(jobID: source.jobID, artifactID: source.artifactID)
      )
    }
    var submits: [String: [String: JSONValue]] = [:]
    var jobIDs: [String: String] = [:]
    for item in Self.publicationCases {
      let params = try Self.submitParams(item.name, lease: sources[item.name]!.lease)
      let accepted = try await exchange(handler, "job.submit", params)
      guard case .object(let fields) = accepted, case .object(let result)? = fields["result"],
        result["deduplicated"] == .bool(false), case .string(let jobID)? = result["jobId"]
      else { throw CocoaError(.coderInvalidValue) }
      submits[item.name] = params
      jobIDs[item.name] = jobID
    }

    // A Job's Session lies under the UTC month its Job was created in.
    let month = sessions.appending(
      path: Self.nowUTC.prefix(7).replacingOccurrences(of: "-", with: "/"),
      directoryHint: .isDirectory)
    var recorded: [JSONValue] = []
    for item in Self.publicationCases {
      let source = sources[item.name]!
      let jobID = jobIDs[item.name]!
      var entry: [String: JSONValue] = [
        "name": .string(item.name), "mode": .string(item.mode!),
        "submit": .object(submits[item.name]!), "params": .object(["jobId": .string(jobID)]),
      ]
      if item.removesSourcePayload {
        try manager.removeItem(
          at: artifacts.appending(path: source.job).appending(path: source.artifact))
        entry["removesSourcePayload"] = .string("\(source.job)/\(source.artifact)")
      }
      if item.presetsSession {
        try manager.createDirectory(
          at: month.appending(path: "session-\(jobID)", directoryHint: .isDirectory),
          withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        entry["presetsSession"] = .bool(true)
      }
      if item.exhaustsStorage { entry["exhaustsStorage"] = .bool(true) }
      probe.exhaust(item.exhaustsStorage)
      let response = try await exchange(handler, "job.run", ["jobId": .string(jobID)])
      probe.exhaust(false)
      check(response, item)
      entry["response"] = response
      recorded.append(.object(entry))
    }
    var reads: [String: JSONValue] = [:]
    for item in Self.publicationCases {
      let jobID = jobIDs[item.name]!
      var answers: [String: JSONValue] = [:]
      for method in ["job.status", "job.show"] {
        answers[method] = try await exchange(handler, method, ["jobId": .string(jobID)])
      }
      reads[jobID] = .object(answers)
    }

    let encoder = JSONEncoder()
    encoder.outputFormatting = [.sortedKeys, .prettyPrinted, .withoutEscapingSlashes]
    var files: [String: Data] = [
      "analyzer": Self.analyzerBytes,
      "cases.json": try encoder.encode(JSONValue.array(recorded)) + Data("\n".utf8),
      "reads.json": try encoder.encode(JSONValue.object(reads)) + Data("\n".utf8),
      "store/index.json":
        try encoder.encode(try Self.index(of: jobsState, normalizing: true)) + Data("\n".utf8),
    ]
    for job in try manager.contentsOfDirectory(atPath: artifacts.path).sorted()
    where !job.hasPrefix(".") {
      let directory = artifacts.appending(path: job, directoryHint: .isDirectory)
      for name in try manager.contentsOfDirectory(atPath: directory.path).sorted()
      where !name.hasPrefix(".") {
        files["artifacts/\(job)/\(name)"] = try Data(contentsOf: directory.appending(path: name))
      }
    }
    // Every file below the Job directories, the Sessions root and the storage
    // owner, dot entries included, and every entry's kind and mode.
    var tree: [JSONValue] = []
    for (directory, prefix) in [
      (jobsState.appending(path: "jobs", directoryHint: .isDirectory), "store/jobs"),
      (sessions, "sessions"), (owner, "session-owner"),
    ] {
      for path in try manager.subpathsOfDirectory(atPath: directory.path).sorted() {
        let url = directory.appending(path: path)
        var metadata = stat()
        guard lstat(url.path, &metadata) == 0 else { throw POSIXError(.EIO) }
        let isDirectory = metadata.st_mode & S_IFMT == S_IFDIR
        tree.append(
          .object([
            "path": .string("\(prefix)/\(path)"),
            "kind": .string(isDirectory ? "directory" : "file"),
            "mode": .string(String(metadata.st_mode & 0o777, radix: 8)),
          ]))
        guard !isDirectory else { continue }
        let data = try Data(contentsOf: url)
        files["\(prefix)/\(path)"] =
          url.lastPathComponent == "job-record.json" ? Self.machineIndependent(data) : data
      }
    }
    files["tree.json"] = try encoder.encode(JSONValue.array(tree)) + Data("\n".utf8)
    var digests: [String: JSONValue] = [:]
    for (path, data) in files { digests[path] = .string(Self.sha256(data)) }
    files["provenance.json"] =
      try encoder.encode(
        JSONValue.object([
          "producer": .string(
            "JobRunAnalyzerOracleContractTests/testSwiftPublishesTheSharedAnalyzerSessions"),
          "root": .string(Self.root.path),
          "sessionsRoot": .string(sessions.path),
          "sessionOwner": .string(owner.path),
          "availableBytes": .integer(Int64(OracleStorageProbe.roomyBytes)),
          "nowUTC": .string(Self.nowUTC),
          "nowPreciseUTC": .string(Self.nowPreciseUTC),
          "home": .string(Self.home),
          "quotaBytes": .integer(Int64(Self.quotaBytes)),
          "timeoutSeconds": .integer(Int64(Self.timeoutSeconds)),
          "files": .object(digests),
        ])) + Data("\n".utf8)
    return files
  }

  private static func submitParams(_ name: String, lease: String) throws -> [String: JSONValue] {
    let fields: [String: JSONValue] = [
      "documentType": .string("runtime-operation-request"),
      "schemaVersion": .string("1.0.0"),
      "requestId": .string("req-oracle-run-\(name)"),
      "idempotencyKey": .string("idem-oracle-run-\(name)-0001"),
      "target": .object(["targetId": .string(Self.target)]),
      "operation": .object([
        "id": .string("analyzer.extract-crash-signature"), "version": .integer(1),
      ]),
      "inputs": .object(["sourceArtifactRef": .string(lease)]),
    ]
    let bytes = try CanonicalJSONEncoders.canonical().encode(JSONValue.object(fields))
    return ["requestJson": .string(String(decoding: bytes, as: UTF8.self))]
  }

  /// A run answers the state its case names; a refusal carries the
  /// zero-dispatch proof.
  private func check(_ response: JSONValue, _ item: Case) {
    guard case .object(let fields) = response else { return XCTFail(item.name) }
    if let ends = item.ends {
      guard fields["ok"] == .bool(true), case .object(let result)? = fields["result"] else {
        return XCTFail("\(item.name): \(response)")
      }
      XCTAssertEqual(result["state"], .string(ends), item.name)
    } else {
      guard fields["ok"] == .bool(false), case .object(let error)? = fields["error"],
        case .object(let details)? = error["details"]
      else { return XCTFail("\(item.name): \(response)") }
      XCTAssertEqual(details["newDispatchCount"], .integer(0), item.name)
      XCTAssertEqual(details["phase"], .string("preAdmission"), item.name)
    }
  }

  private func exchange(
    _ handler: RuntimeControlPlaneHandler, _ method: String, _ params: [String: JSONValue]
  ) async throws -> JSONValue {
    let frame = try CanonicalJSONEncoders.canonical().encode(
      JSONValue.object([
        "protocolVersion": .string(ArkDeckControlProtocol.currentVersion),
        "contractIdentity": .string(ArkDeckControlProtocol.contractIdentity),
        "id": .string("job-run-oracle"), "method": .string(method),
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

  /// What a reader observes of the Job index without writing: layout,
  /// pragmas and every row, as `JobStoreRustWriterParityContractTests` reads it.
  private static func index(of state: URL, normalizing: Bool = false) throws -> JSONValue {
    var handle: OpaquePointer?
    let path = state.appending(path: RuntimeJobRepository.filename).path
    guard sqlite3_open_v2(path, &handle, SQLITE_OPEN_READONLY, nil) == SQLITE_OK,
      let db = handle
    else {
      if let handle { sqlite3_close_v2(handle) }
      throw CocoaError(.fileReadUnknown)
    }
    defer { sqlite3_close_v2(db) }
    func rows(_ sql: String) throws -> [[JSONValue]] {
      var prepared: OpaquePointer?
      guard sqlite3_prepare_v2(db, sql, -1, &prepared, nil) == SQLITE_OK, let statement = prepared
      else { throw CocoaError(.fileReadCorruptFile) }
      defer { sqlite3_finalize(statement) }
      var result: [[JSONValue]] = []
      while true {
        let code = sqlite3_step(statement)
        if code == SQLITE_DONE { return result }
        guard code == SQLITE_ROW else { throw CocoaError(.fileReadCorruptFile) }
        result.append(
          (0..<sqlite3_column_count(statement)).map { column -> JSONValue in
            switch sqlite3_column_type(statement, column) {
            case SQLITE_INTEGER:
              return .integer(sqlite3_column_int64(statement, column))
            case SQLITE_TEXT:
              return .string(sqlite3_column_text(statement, column).map { String(cString: $0) } ?? "")
            case SQLITE_BLOB:
              let count = Int(sqlite3_column_bytes(statement, column))
              let bytes =
                sqlite3_column_blob(statement, column).map { Data(bytes: $0, count: count) }
                ?? Data()
              return .string(sha256(normalizing ? machineIndependent(bytes) : bytes))
            default:
              return .null
            }
          })
      }
    }
    let schema = try rows("SELECT name, type, tbl_name, sql FROM sqlite_schema ORDER BY name").map {
      JSONValue.object(["name": $0[0], "type": $0[1], "tableName": $0[2], "sql": $0[3]])
    }
    let jobs = try rows(
      """
      SELECT job_id, idempotency_key, request_hash, state, admission_sequence, created_at_utc,
             created_at_order_key, updated_at_utc, version, initial_record_json
      FROM runtime_job ORDER BY admission_sequence
      """)
    return .object([
      "userVersion": try rows("PRAGMA user_version")[0][0],
      "journalMode": try rows("PRAGMA journal_mode")[0][0],
      "schema": .array(schema),
      "rows": .array(
        jobs.map { row in
          .object([
            "jobId": row[0], "idempotencyKey": row[1], "requestHash": row[2], "state": row[3],
            "admissionSequence": row[4], "createdAtUTC": row[5], "createdAtOrderKey": row[6],
            "updatedAtUTC": row[7], "version": row[8], "recordSHA256": row[9],
          ])
        }),
    ])
  }

  private static func sha256(_ data: Data) -> String {
    SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
  }

  /// A Job record's publication marker names this machine's volume, device,
  /// inode and claim generation. The oracle keeps each as a fixed label; a
  /// refused marker's blank or zero value stays as it is.
  private static let machineFact = try! NSRegularExpression(
    pattern: #""(device|inode|volumeIdentity|admissionGeneration)"( ?: ?)"([^"]*)""#)

  private static func machineIndependent(_ data: Data) -> Data {
    let source = String(decoding: data, as: UTF8.self)
    let text = NSMutableString(string: source)
    let matches = machineFact.matches(
      in: source, range: NSRange(location: 0, length: text.length))
    for match in matches.reversed() {
      let value = text.substring(with: match.range(at: 3))
      guard !value.isEmpty, value != "0" else { continue }
      text.replaceCharacters(
        in: match.range(at: 3), with: "<\(text.substring(with: match.range(at: 1)))>")
    }
    return Data((text as String).utf8)
  }
}

/// The publication oracle's storage probe: this machine's volume with room
/// for every claim, unless a case reports it full.
private final class OracleStorageProbe: HostStorageProbing, @unchecked Sendable {
  static let roomyBytes: UInt64 = 1 << 40
  private let lock = NSLock()
  private var exhausted = false

  func exhaust(_ value: Bool) {
    lock.lock()
    defer { lock.unlock() }
    exhausted = value
  }

  func snapshot(for url: URL) throws -> HostStorageSnapshot {
    lock.lock()
    let full = exhausted
    lock.unlock()
    return HostStorageSnapshot(
      volumeIdentity: try SystemVolumeIdentityResolver().resolve(url),
      totalBytes: Self.roomyBytes, availableBytes: full ? 0 : Self.roomyBytes,
      isReadOnly: false)
  }
}
