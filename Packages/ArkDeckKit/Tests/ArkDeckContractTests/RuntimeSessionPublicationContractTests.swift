import ArkDeckCore
import ArkDeckRuntime
import ArkDeckStorage
import Foundation
import XCTest

@testable import ArkDeckAgentDaemon
@testable import ArkDeckWorkflows

/// `TASK-SVC-002`: a terminal Job becomes a formal Session.
///
/// Every assertion here goes through the production Engine, the configured
/// Session owner and the real storage writer. A prebuilt finalized fixture
/// would prove the reader, not the producer, so nothing in this suite hands
/// the catalog a manifest it did not publish itself.
final class RuntimeSessionPublicationContractTests: XCTestCase {
  private var root: URL!

  override func setUpWithError() throws {
    guard let physical = realpath(FileManager.default.temporaryDirectory.path, nil) else {
      throw NSError(domain: NSPOSIXErrorDomain, code: Int(errno))
    }
    defer { free(physical) }
    root = URL(filePath: String(cString: physical), directoryHint: .isDirectory)
      .appending(path: "arkdeck-session-publication", directoryHint: .isDirectory)
      .appending(path: UUID().uuidString.prefix(8).lowercased(), directoryHint: .isDirectory)
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
  }

  override func tearDownWithError() throws {
    if let root { try? FileManager.default.removeItem(at: root) }
  }

  // MARK: - The loop

  func testATerminalJobPublishesItsSessionThroughTheConfiguredOwner() async throws {
    let harness = try await Harness(root: root, publishing: true)
    let job = try await harness.runAnalyzerJob()
    XCTAssertEqual(job.state, "succeeded", "timeline: \(job.timeline)")

    let sessionRoot = harness.sessionsRoot
      .appending(path: "2026/07/session-\(job.jobID)", directoryHint: .isDirectory)
    let manifestURL = sessionRoot.appending(path: "manifest.json")
    XCTAssertTrue(
      FileManager.default.fileExists(atPath: manifestURL.path),
      "the production writer must publish a Manifest under the configured Sessions root")

    // The Session Journal is the Job's own bytes, not a summary of them.
    let jobJournal = try Data(
      contentsOf: harness.engineState.appending(path: "jobs/\(job.jobID)/journal.jsonl"))
    XCTAssertEqual(try Data(contentsOf: sessionRoot.appending(path: "journal.jsonl")), jobJournal)

    // The catalog holds the exact entry, so `session list/show/export` can
    // find it. Before this producer existed it read `{"entries":[]}`.
    let status = try harness.owner.status()
    XCTAssertEqual(status.sessionCount, 1)
    XCTAssertEqual(status.unaccountedSessionCount, 0)
    XCTAssertFalse(status.measurementIncomplete)

    // And the observable fact says so, with its exact receipt.
    let fact = job.sessionPublication
    XCTAssertEqual(fact.state, .published)
    XCTAssertNil(fact.reasonCode)
    let manifest = try SessionManifestDocument(data: try Data(contentsOf: manifestURL))
    XCTAssertEqual(fact.manifestSHA256, manifest.sha256)
    XCTAssertEqual(fact.catalogGeneration, status.catalogGeneration.map(String.init))
    XCTAssertEqual(manifest.jobID, job.jobID)
    XCTAssertEqual(manifest.status, "succeeded")

    // The projected Job object carries the same four-key contract, and the
    // strict reader accepts exactly it.
    guard case .object(let projected) = try RuntimeJobReadProjection.status(job),
      let published = projected["sessionPublication"]
    else { return XCTFail("job.status lost its Session publication") }
    XCTAssertEqual(try RuntimeSessionPublicationFact.validated(published), fact)
  }

  func testThePublishedSessionIsReadableAndExportableThroughItsOwnCommands() async throws {
    let harness = try await Harness(root: root, publishing: true)
    let job = try await harness.runAnalyzerJob()
    let sessionID = "session-\(job.jobID)"

    // `session list` no longer refuses: the catalog it scans has an entry.
    guard case .object(let page) = try harness.owner.listSessions(pageSize: 20, cursor: nil),
      case .array(let rows)? = page["items"], rows.count == 1,
      case .object(let row) = rows[0]
    else { return XCTFail("session list did not return the published Session") }
    XCTAssertEqual(row["sessionId"], .string(sessionID))

    // `session show` resolves the same Session by identity.
    guard case .object(let shown) = try harness.owner.showSession(sessionID: sessionID) else {
      return XCTFail("session show did not resolve the published Session")
    }
    XCTAssertEqual(shown["sessionId"], .string(sessionID))

    // And the exact finalized export previews and applies against it.
    // The export owner creates its own destination and refuses an existing one.
    let destination = root.appending(path: "export", directoryHint: .isDirectory)
    guard case .object(let preview) = try harness.owner.previewSessionExport(
      sessionID: sessionID, destinationPath: destination.path, allowSensitive: false),
      case .string(let previewID)? = preview["previewId"],
      case .string(let digest)? = preview["previewDigest"]
    else { return XCTFail("session export preview refused the published Session") }
    guard case .object(let applied) = try harness.owner.applySessionExport(
      previewID: previewID, previewDigest: digest)
    else { return XCTFail("session export apply refused its own durable preview") }
    XCTAssertEqual(applied["sessionId"], .string(sessionID))
  }

  func testAJobFinishedWithNoComposedWriterReportsUnavailableAndWritesNothing() async throws {
    let harness = try await Harness(root: root, publishing: false)
    let job = try await harness.runAnalyzerJob()
    XCTAssertEqual(job.state, "succeeded", "timeline: \(job.timeline)")
    XCTAssertEqual(job.sessionPublication.state, .unavailable)
    XCTAssertEqual(job.sessionPublication.reasonCode, .noCurrentPublicationRecord)
    XCTAssertNil(job.sessionPublication.manifestSHA256)
    // Absence of a writer is reported, never substituted for. Nothing under
    // the Sessions root was written by a test path.
    XCTAssertEqual(
      try FileManager.default.contentsOfDirectory(atPath: harness.sessionsRoot.path)
        .filter { !$0.hasPrefix(".") },
      [])
    XCTAssertEqual(try harness.owner.status().sessionCount, 0)
  }

  func testRepublishingAPublishedJobReturnsTheSameReceiptWithoutANewGeneration() async throws {
    let harness = try await Harness(root: root, publishing: true)
    let job = try await harness.runAnalyzerJob()
    let first = job.sessionPublication
    let generation = try XCTUnwrap(try harness.owner.status().catalogGeneration)

    // The writer is idempotent on its own: the same Job, the same Journal,
    // the same Manifest bytes. A repeat must not mint a second entry.
    let directory = harness.engineState.appending(path: "jobs/\(job.jobID)", directoryHint: .isDirectory)
    let record = try XCTUnwrap(recordState(in: directory))
    let outcome = await harness.writer.publish(
      RuntimeSessionPublicationRequest(
        record: record, journalURL: directory.appending(path: "journal.jsonl"),
        jobDirectory: directory, nowUTC: "2026-07-31T00:00:01Z"))
    XCTAssertEqual(outcome.record.receipt?.manifestSHA256, first.manifestSHA256)
    XCTAssertEqual(outcome.record.receipt?.catalogGeneration, String(generation))
    XCTAssertEqual(try harness.owner.status().catalogGeneration, generation)
    XCTAssertEqual(try harness.owner.status().sessionCount, 1)
  }

  func testAPreExistingManifestlessSessionIsPreservedAndNeverAdopted() async throws {
    let harness = try await Harness(root: root, publishing: true)
    // The shape this host actually carries: a 2026-08 Session directory with
    // its identity file and a Journal, and no manifest.
    let historical = harness.sessionsRoot
      .appending(path: "2026/08/session-historical", directoryHint: .isDirectory)
    try FileManager.default.createDirectory(
      at: historical, withIntermediateDirectories: true,
      attributes: [.posixPermissions: 0o700])
    let identity = historical.appending(path: ".session-identity.json")
    let journal = historical.appending(path: "journal.jsonl")
    try Data(#"{"jobId":"JOB-HISTORICAL","schemaVersion":"1.0.0","sessionId":"session-historical"}"#.utf8)
      .write(to: identity)
    try Data("{\"kind\":\"jobCreated\"}\n".utf8).write(to: journal)
    let before = try snapshot(of: [identity, journal])

    let job = try await harness.runAnalyzerJob()
    XCTAssertEqual(job.sessionPublication.state, .published)

    // Byte-for-byte and timestamp-for-timestamp untouched, still without a
    // manifest, and still unaccounted: the new Session did not repair, move,
    // adopt or register it.
    XCTAssertEqual(try snapshot(of: [identity, journal]), before)
    XCTAssertFalse(
      FileManager.default.fileExists(atPath: historical.appending(path: "manifest.json").path))
    let status = try harness.owner.status()
    XCTAssertEqual(status.sessionCount, 1)
    XCTAssertEqual(status.unaccountedSessionCount, 1)
    XCTAssertTrue(status.measurementIncomplete)
  }

  /// The reference host, reproduced: one Session this Runtime just produced,
  /// beside one 2026-08 directory from an earlier build that has no manifest.
  ///
  /// Before this change every read refused, because a single blanket guard
  /// asked whether the *whole* root was accounted for. `session list` still
  /// asks that question and must still refuse. An exact export asks a
  /// narrower one — is *this* Session known, complete and registered — so it
  /// answers, and says in the same breath what it is not accounting for.
  func testAnExactExportSucceedsWhileTheHistoricalUnknownIsDisclosedAndStillRefused()
    async throws
  {
    let harness = try await Harness(root: root, publishing: true)
    let historical = harness.sessionsRoot
      .appending(path: "2026/08/session-historical", directoryHint: .isDirectory)
    try FileManager.default.createDirectory(
      at: historical, withIntermediateDirectories: true,
      attributes: [.posixPermissions: 0o700])
    let identity = historical.appending(path: ".session-identity.json")
    let journal = historical.appending(path: "journal.jsonl")
    try Data(#"{"jobId":"JOB-HISTORICAL","schemaVersion":"1.0.0","sessionId":"session-historical"}"#.utf8)
      .write(to: identity)
    try Data("{\"kind\":\"jobCreated\"}\n".utf8).write(to: journal)
    let before = try snapshot(of: [identity, journal])

    let job = try await harness.runAnalyzerJob()
    let sessionID = "session-\(job.jobID)"
    XCTAssertEqual(job.sessionPublication.state, .published)

    // Answers about the whole root keep their fail-closed contract, and keep
    // naming the leaf and its reason. `listSessions` is one: a partial
    // inventory presented as the inventory would be a lie. Showing the
    // unaccounted leaf itself is refused for the separate reason that it is
    // the content nobody can account for.
    for global in [
      { _ = try harness.owner.listSessions(pageSize: 20, cursor: nil) },
      { _ = try harness.owner.showSession(sessionID: "session-historical") },
    ] as [() throws -> Void] {
      XCTAssertThrowsError(try global()) { error in
        let failure = error as? RuntimeSessionStorageFailure
        XCTAssertEqual(failure?.code, "operationUnavailable")
        XCTAssertTrue(
          (failure?.message ?? "").contains("2026/08/session-historical"),
          "the refusal must still name the leaf: \(failure?.message ?? "")")
      }
    }

    // `showSession` publishes only this Session's own facts — identity, size,
    // completion, expiry, pin — and no total over the root, so it asks the same
    // shape of question the exact export asks and is answered at the same
    // scope, under the same guard. This assertion previously required it to
    // refuse, grouped with `list` on the reasoning that it "answers about the
    // whole root"; the published `session.show` result has no root-level field,
    // so that reason did not hold for it, and the refusal only made a healthy
    // Session unreadable through every face at once.
    guard case .object(let shown) = try harness.owner.showSession(sessionID: sessionID) else {
      return XCTFail("show refused a known, complete, registered Session")
    }
    XCTAssertEqual(shown["sessionId"], .string(sessionID))
    XCTAssertNotNil(shown["sizeBytes"])
    XCTAssertNil(
      shown["unaccountedSessionCount"],
      "show answers about one Session and must not publish a root total")

    // The exact export answers, and discloses.
    let destination = root.appending(path: "disclosed-export", directoryHint: .isDirectory)
    guard case .object(let preview) = try harness.owner.previewSessionExport(
      sessionID: sessionID, destinationPath: destination.path, allowSensitive: false)
    else { return XCTFail("exact export refused a known, complete, registered Session") }
    guard case .object(let catalogStatus)? = preview["catalogStatus"] else {
      return XCTFail("the preview published no catalog status")
    }
    XCTAssertEqual(catalogStatus["complete"], .bool(false))
    XCTAssertEqual(catalogStatus["unaccountedSessionCount"], .string("1"))
    XCTAssertEqual(catalogStatus["measurementIncomplete"], .bool(true))
    XCTAssertEqual(catalogStatus["blocker"], .string("unaccountedSessionContent"))
    // `usedBytes` is measured known content, so it is strictly smaller than
    // the scan's total, which folds in what it measured for the leaf it could
    // not account for.
    guard case .string(let usedText)? = catalogStatus["usedBytes"],
      let usedBytes = UInt64(usedText)
    else { return XCTFail("the disclosed usage is not a canonical decimal") }
    XCTAssertGreaterThan(usedBytes, 0)
    XCTAssertLessThan(usedBytes, try harness.owner.status().currentBytes)

    guard case .object(let source)? = preview["source"] else {
      return XCTFail("the preview published no source facts")
    }
    XCTAssertEqual(source["jobId"], .string(job.jobID))
    XCTAssertEqual(source["manifestSha256"], job.sessionPublication.manifestSHA256.map(JSONValue.string))
    let sessionRoot = harness.sessionsRoot
      .appending(path: "2026/07/\(sessionID)", directoryHint: .isDirectory)
    XCTAssertEqual(
      source["journalSha256"],
      .string(SHA256Hex.string(of: try Data(contentsOf: sessionRoot.appending(path: "journal.jsonl")))))
    XCTAssertEqual(source["volumeIdentity"], preview["destination"].flatMap {
      guard case .object(let facts) = $0 else { return nil }
      return facts["volumeIdentity"]
    }, "the fixture root and its destination share one volume")

    // The digest still covers the whole preview minus itself, including both
    // new objects: dropping either one changes it.
    guard case .string(let digest)? = preview["previewDigest"],
      case .string(let previewID)? = preview["previewId"]
    else { return XCTFail("the preview published no digest tuple") }
    var digestFields = preview
    digestFields.removeValue(forKey: "previewDigest")
    XCTAssertEqual(
      SHA256Hex.string(of: try PortableCanonicalJSON.canonicalBytes(.object(digestFields))),
      digest)
    for dropped in ["source", "catalogStatus"] {
      var without = digestFields
      without.removeValue(forKey: dropped)
      XCTAssertNotEqual(
        SHA256Hex.string(of: try PortableCanonicalJSON.canonicalBytes(.object(without))),
        digest, "previewDigest must cover \(dropped)")
    }

    // Exporting the unaccounted leaf itself stays refused.
    XCTAssertThrowsError(
      try harness.owner.previewSessionExport(
        sessionID: "session-historical",
        destinationPath: root.appending(path: "historical-export").path,
        allowSensitive: false)
    ) { error in
      XCTAssertEqual((error as? RuntimeSessionStorageFailure)?.code, "operationUnavailable")
    }

    guard case .object(let applied) = try harness.owner.applySessionExport(
      previewID: previewID, previewDigest: digest)
    else { return XCTFail("apply refused its own durable preview") }
    XCTAssertEqual(applied["source"], preview["source"])
    XCTAssertEqual(applied["catalogStatus"], preview["catalogStatus"])
    XCTAssertTrue(
      FileManager.default.fileExists(atPath: destination.appending(path: "manifest.json").path))

    // Nothing about the historical directory moved. It was not adopted,
    // repaired, registered or rewritten to make the export possible.
    XCTAssertEqual(try snapshot(of: [identity, journal]), before)
    XCTAssertFalse(
      FileManager.default.fileExists(atPath: historical.appending(path: "manifest.json").path),
      "no manifest may be invented for a Session that never had one")
    let status = try harness.owner.status()
    XCTAssertEqual(status.sessionCount, 1)
    XCTAssertEqual(status.unaccountedSessionCount, 1)
    XCTAssertTrue(status.measurementIncomplete)
  }

  func testTheControlPlanePublishesTheReceiptOnEveryJobReadMethod() async throws {
    let harness = try await Harness(root: root, publishing: true)
    let job = try await harness.runAnalyzerJob()
    let handler = RuntimeControlPlaneHandler(
      engine: harness.engine, capabilityStore: harness.capabilities,
      providerIDs: ["analyzer"], nowUTC: { "2026-07-31T00:00:00Z" },
      artifactStore: harness.artifactStore,
      runtimeSessionStorage: harness.owner)
    // `job.run` needs a job that has not run yet, so it gets its own.
    let second = try await harness.submitAnalyzerJob()
    for method in ["job.status", "job.show", "job.result", "job.list", "job.run"] {
      let request = AgentWireProtocol.Request(
        id: "ctl-\(method)", method: method,
        params: method == "job.list"
          ? [:]
          : ["jobId": .string(method == "job.run" ? second : job.jobID)])
      let line = try CanonicalJSONEncoders.canonical().encode(request)
      let response = try JSONDecoder().decode(
        AgentWireProtocol.Response.self, from: await handler.handleLine(line))
      XCTAssertTrue(response.ok, "\(method) refused: \(String(describing: response.error))")
      // Whatever the shape of each result, the publication it carries is the
      // same receipt, validated by the same closed contract.
      let facts = Self.publications(in: try XCTUnwrap(response.result))
      XCTAssertFalse(facts.isEmpty, "\(method) published no Session publication")
      let states = try facts.map { try RuntimeSessionPublicationFact.validated($0).state }
      XCTAssertTrue(
        states.contains(.published),
        "\(method) never reported the receipt this Runtime wrote: \(states)")
    }
  }

  /// Every `sessionPublication` anywhere in one result, however it is nested.
  private static func publications(in value: JSONValue) -> [JSONValue] {
    switch value {
    case .object(let fields):
      var found: [JSONValue] = []
      for (key, nested) in fields {
        if key == "sessionPublication" { found.append(nested) } else {
          found.append(contentsOf: publications(in: nested))
        }
      }
      return found
    case .array(let items): return items.flatMap(publications(in:))
    default: return []
    }
  }

  // MARK: - Refusals

  func testASessionIsNotPublishedForFactsTheCurrentManifestCannotExpress() async throws {
    // No writer is composed for the run itself, so the record under test has
    // never been published and the writer decides on its facts alone.
    let harness = try await Harness(root: root, publishing: false)
    let job = try await harness.runAnalyzerJob()
    let directory = harness.engineState.appending(path: "jobs/\(job.jobID)", directoryHint: .isDirectory)
    var record = try XCTUnwrap(recordState(in: directory))
    // `recovered` is a Runtime terminal state the locked Manifest vocabulary
    // has no word for. The producer refuses rather than filing it as
    // `succeeded`, which would erase the distinction a recovery epoch exists
    // to preserve.
    record.state = JobState.recovered.rawValue
    let outcome = await harness.writer.publish(
      RuntimeSessionPublicationRequest(
        record: record, journalURL: directory.appending(path: "journal.jsonl"),
        jobDirectory: directory, nowUTC: "2026-07-31T00:00:02Z"))
    XCTAssertNil(outcome.record.receipt)
    XCTAssertEqual(outcome.record.fact.state, .failed)
    XCTAssertEqual(outcome.record.fact.reasonCode, .contractViolation)
  }

  func testAnUnresolvedJobIsNeverSealedAsAConfirmedSession() async throws {
    let harness = try await Harness(root: root, publishing: false)
    let job = try await harness.runAnalyzerJob()
    let directory = harness.engineState.appending(path: "jobs/\(job.jobID)", directoryHint: .isDirectory)
    var record = try XCTUnwrap(recordState(in: directory))
    record.outcomeUnknown = true
    let outcome = await harness.writer.publish(
      RuntimeSessionPublicationRequest(
        record: record, journalURL: directory.appending(path: "journal.jsonl"),
        jobDirectory: directory, nowUTC: "2026-07-31T00:00:03Z"))
    XCTAssertNil(outcome.record.receipt)
    XCTAssertEqual(outcome.record.fact.state, .failed)
    XCTAssertEqual(outcome.record.fact.reasonCode, .contractViolation)
  }

  // MARK: - The closed wire contract

  func testTheWireContractRefusesEveryShapeNoProducerCanEmit() throws {
    let published = try RuntimeSessionPublicationFact.published(
      manifestSHA256: String(repeating: "a", count: 64), catalogGeneration: "3")
    XCTAssertEqual(try RuntimeSessionPublicationFact.validated(published.json), published)
    XCTAssertEqual(
      try RuntimeSessionPublicationFact.validated(
        RuntimeSessionPublicationFact.unavailable.json),
      .unavailable)
    XCTAssertEqual(
      try RuntimeSessionPublicationFact.validated(
        RuntimeSessionPublicationFact.outcomeUnknown.json),
      .outcomeUnknown)

    func refused(_ fields: [String: JSONValue], _ message: String) {
      XCTAssertThrowsError(
        try RuntimeSessionPublicationFact.validated(.object(fields)), message)
    }
    guard case .object(let valid) = published.json else { return XCTFail("no published shape") }
    var extra = valid
    extra["retainedUntil"] = .string("2026-08-01T00:00:00Z")
    refused(extra, "an unrecorded key must not be accepted")
    var missing = valid
    missing.removeValue(forKey: "catalogGeneration")
    refused(missing, "a missing key must not be accepted")
    var omitted = valid
    omitted["reasonCode"] = .string("noCurrentPublicationRecord")
    refused(omitted, "a published receipt must not also carry a reason")
    var forged = valid
    forged["manifestSha256"] = .string("NOTAHASH")
    refused(forged, "a forged receipt digest must not be accepted")
    var decimal = valid
    decimal["catalogGeneration"] = .string("03")
    refused(decimal, "a non-canonical decimal generation must not be accepted")
    refused(
      [
        "state": .string("published"), "manifestSha256": .null,
        "catalogGeneration": .null, "reasonCode": .null,
      ], "published without a receipt must not be accepted")
    refused(
      [
        "state": .string("failed"), "manifestSha256": .null,
        "catalogGeneration": .null, "reasonCode": .string("publicationUncertain"),
      ], "an unprovable outcome must never be reported as a confirmed failure")
    refused(
      [
        "state": .string("pending"), "manifestSha256": .null,
        "catalogGeneration": .null, "reasonCode": .string("storageUnavailable"),
      ], "a failure reason must not be reported as pending")
    refused(
      [
        "state": .string("retained"), "manifestSha256": .null,
        "catalogGeneration": .null, "reasonCode": .null,
      ], "an unpublished state must not be accepted")
  }

  // MARK: - Helpers

  private func recordState(in directory: URL) throws -> RuntimeJobRecord? {
    guard case .readable(let record) = RuntimeJobRecord.state(in: directory) else { return nil }
    return record
  }

  private func snapshot(of urls: [URL]) throws -> [String] {
    try urls.map { url in
      var metadata = stat()
      guard lstat(url.path, &metadata) == 0 else { throw CocoaError(.fileNoSuchFile) }
      let digest = SHA256Hex.string(of: try Data(contentsOf: url))
      return "\(url.lastPathComponent):\(digest):\(metadata.st_mtimespec.tv_sec)"
        + ":\(metadata.st_mtimespec.tv_nsec):\(metadata.st_size)"
    }
  }
}

// MARK: - Production composition under test

private struct AnalyzerResultDispatcher: RuntimeProcessDispatching {
  let output: Data

  func unavailableReason(providerID: String) -> String? { nil }

  func dispatch(_ plan: TypedProcessPlan) async throws -> ProviderProcessReceipt {
    ProviderProcessReceipt(
      exitStatus: 0, stdout: output, stderr: Data(), stdoutTruncated: false,
      durationSeconds: 0.001)
  }
}

/// The real Engine, the real Artifact store, the real Session owner and — when
/// asked for — the real publication writer. Nothing here stands in for the
/// production composition.
private struct Harness {
  let engine: RuntimeJobEngine
  let owner: RuntimeSessionStorageStore
  let writer: RuntimeSessionPublicationWriter
  let sessionsRoot: URL
  let engineState: URL
  let artifactStore: RuntimeArtifactStore
  let capabilities: RuntimeCapabilityStore
  let lease: String

  init(root: URL, publishing: Bool) async throws {
    let state = root.appending(path: "state", directoryHint: .isDirectory)
    engineState = state.appending(path: "engine", directoryHint: .isDirectory)
    sessionsRoot = root.appending(path: "Sessions", directoryHint: .isDirectory)
    owner = try RuntimeSessionStorageStore(
      ownerRoot: state.appending(path: "session-owner", directoryHint: .isDirectory),
      defaultSessionsRoot: sessionsRoot)
    writer = RuntimeSessionPublicationWriter(owner: owner)

    artifactStore = try RuntimeArtifactStore(
      rootURL: state.appending(path: "artifacts", directoryHint: .isDirectory),
      nowUTC: { "2026-07-31T00:00:00Z" })
    let raw = Data("Fault log list:\n******\n******\n".utf8)
    let source = try await artifactStore.publish(
      RuntimeArtifactPublicationRequest(
        jobID: "JOB-CAPTURE", sessionID: "HTASK-0123456789AB",
        stepID: "capture-crash-index", name: "crash-index.txt",
        mediaType: "text/plain", privacy: .standard, retentionClass: .pinnedUntilVerified,
        sourceOperation: "capture.diagnostics@1", providerID: "hdc",
        bindingSnapshot: ArtifactBindingSnapshot(
          targetID: "TGT-1", bindingRevision: 7,
          stableIdentitySHA256: String(repeating: "c", count: 64)),
        contents: raw))
    lease = try await artifactStore.leaseReference(
      jobID: source.jobID, artifactID: source.artifactID)

    let toolBytes = try Data(contentsOf: URL(filePath: "/bin/cat"))
    let provider = try AnalyzerProvider(profiles: [
      AnalyzerProfile(
        analyzerRef: "crash-signature@1",
        analyzerVersion: HarnessCrashLedgerAnalysis.analyzerVersion,
        executablePath: "/bin/cat", executableSHA256: AnalyzerProvider.sha256(toolBytes),
        fixedArguments: ["--emit-json"])
    ])
    capabilities = try RuntimeCapabilityStore(
      directoryURL: state.appending(path: "capabilities", directoryHint: .isDirectory))
    engine = try RuntimeJobEngine(
      configuration: .init(
        stateDirectory: engineState,
        sessionPublicationWriter: publishing ? writer : nil),
      providers: DeviceProviderRegistry(providers: [provider]),
      dispatcher: AnalyzerResultDispatcher(
        output: try HarnessCrashLedgerDerivedAnalyzer.analyze(raw)),
      capabilityStore: capabilities,
      artifactStore: artifactStore,
      nowUTC: { "2026-07-31T00:00:00Z" })
  }

  /// One real host-only Job: submit, run, reach `succeeded`.
  func runAnalyzerJob() async throws -> RuntimeJobStatus {
    try await engine.run(jobID: try await submitAnalyzerJob())
  }

  func submitAnalyzerJob() async throws -> String {
    let request = try RuntimeOperationRequest(
      requestID: "req-session-publication",
      idempotencyKey: "idem-\(UUID().uuidString.lowercased())",
      target: DurableTargetReference(targetID: "TGT-1", expectedBindingRevision: nil),
      operation: RuntimeOperationReference(id: "analyzer.extract-crash-signature", version: 1),
      inputs: ["sourceArtifactRef": .string(lease)])
    return try await engine.submit(try JSONEncoder().encode(request)).jobID
  }
}
