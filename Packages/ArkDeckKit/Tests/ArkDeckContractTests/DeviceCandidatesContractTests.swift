import XCTest

@testable import ArkDeckAgentDaemon
@testable import ArkDeckCore
@testable import ArkDeckStorage
@testable import ArkDeckWorkflows

/// The read-only device discovery plane behind the App's device list.
///
/// The load-bearing fact on both sides: listing candidates can never adopt.
/// The daemon method calls the bootstrap's enumeration only (`advance` is the
/// path that adopts a single Connected candidate), and the App-facing decode
/// reports incomplete facts as a failure instead of a silently empty list.
final class DeviceCandidatesContractTests: XCTestCase {
  private var stateDirectory: URL!

  override func setUpWithError() throws {
    stateDirectory = FileManager.default.temporaryDirectory
      .appendingPathComponent("arkdeck-device-candidates-tests", isDirectory: true)
      .appendingPathComponent(UUID().uuidString.prefix(8).lowercased(), isDirectory: true)
  }

  override func tearDownWithError() throws {
    if let stateDirectory { try? FileManager.default.removeItem(at: stateDirectory) }
  }

  private struct ScriptedCandidates: BootstrapObservationPort {
    let candidates: [BootstrapCandidate]
    func observeToolVersion() async throws -> String { "3.2.0f" }
    func listCandidates() async throws -> [BootstrapCandidate] { candidates }
    func observeDeviceIdentity(connectKey: String) async throws -> [String: String] {
      ["serial": connectKey]
    }
  }

  private func makeHandler(
    candidates: [BootstrapCandidate],
    bootstrapConfigured: Bool = true
  ) throws -> (RuntimeControlPlaneHandler, RuntimeTargetStore) {
    let capabilityStore = try RuntimeCapabilityStore(
      directoryURL: stateDirectory.appendingPathComponent("capabilities", isDirectory: true))
    let targetStore = try RuntimeTargetStore(
      directoryURL: stateDirectory.appendingPathComponent("targets", isDirectory: true))
    let resolver = try FixedExecutableResolver.hashing(path: "/bin/ls", providerID: "hdc")
    let engine = try RuntimeJobEngine(
      configuration: .init(
        stateDirectory: stateDirectory.appendingPathComponent("engine", isDirectory: true)),
      providers: DeviceProviderRegistry(providers: []),
      dispatcher: DescriptorBoundProcessDispatcher(resolver: resolver),
      capabilityStore: capabilityStore,
      nowUTC: { "2026-08-07T00:00:00Z" })
    let bootstrap =
      bootstrapConfigured
      ? DeviceBootstrapMachine(
        observation: ScriptedCandidates(candidates: candidates),
        targetStore: targetStore,
        nowUTC: { "2026-08-07T00:00:00Z" })
      : nil
    let handler = RuntimeControlPlaneHandler(
      engine: engine, capabilityStore: capabilityStore,
      providerIDs: [], nowUTC: { "2026-08-07T00:00:00Z" },
      targetStore: targetStore, bootstrap: bootstrap)
    return (handler, targetStore)
  }

  private func frame(_ method: String) -> Data {
    Data("{\"protocolVersion\":\"1.0.0\",\"id\":\"t\",\"method\":\"\(method)\"}".utf8)
  }

  // Listing candidates adopts nothing — even when exactly one Connected
  // candidate is present, which is precisely the input `advance` would adopt.
  func testEnumerationNeverAdoptsEvenForASingleConnectedCandidate() async throws {
    let (handler, targetStore) = try makeHandler(candidates: [
      BootstrapCandidate(connectKey: String(repeating: "a", count: 32), state: "Connected")
    ])

    let response = await handler.handleFrame(frame("device.candidates"))
    XCTAssertTrue(response.ok, String(describing: response.error))
    guard case .array(let rows)? = response.result else {
      return XCTFail("device.candidates must return an array")
    }
    XCTAssertEqual(rows.count, 1)
    guard case .object(let row) = rows[0] else { return XCTFail("row must be an object") }
    XCTAssertEqual(row["state"], .string("Connected"))
    XCTAssertEqual(row["adoptedTargetId"], .null)
    XCTAssertEqual(row["bindingRevision"], .null)

    XCTAssertEqual(
      try targetStore.list().count, 0,
      "the discovery read must not create a binding")
  }

  // An adopted device joins its durable record; an unauthorized one carries
  // its raw reported state with no invented identity.
  func testAdoptedCandidateJoinsItsTargetRecord() async throws {
    let connected = String(repeating: "b", count: 32)
    let (handler, targetStore) = try makeHandler(candidates: [
      BootstrapCandidate(connectKey: connected, state: "Connected"),
      BootstrapCandidate(connectKey: "7f2c091a445e21", state: "Unauthorized"),
    ])

    // Adopt the connected one through the real bootstrap path.
    let adopt = await handler.handleFrame(
      Data(
        """
        {"protocolVersion":"1.0.0","id":"a","method":"target.adopt",\
        "params":{"candidate":"\(connected)"}}
        """.utf8))
    XCTAssertTrue(adopt.ok, String(describing: adopt.error))
    let adoptedID = try XCTUnwrap(try targetStore.list().first?.targetID)

    let response = await handler.handleFrame(frame("device.candidates"))
    guard case .array(let rows)? = response.result else {
      return XCTFail("device.candidates must return an array")
    }
    XCTAssertEqual(rows.count, 2)
    var adoptedRow: [String: JSONValue]?
    var unauthorizedRow: [String: JSONValue]?
    for case .object(let row) in rows {
      if row["connectKey"] == .string(connected) { adoptedRow = row }
      if row["state"] == .string("Unauthorized") { unauthorizedRow = row }
    }
    XCTAssertEqual(try XCTUnwrap(adoptedRow)["adoptedTargetId"], .string(adoptedID))
    XCTAssertEqual(try XCTUnwrap(adoptedRow)["bindingRevision"], .integer(1))
    XCTAssertEqual(try XCTUnwrap(unauthorizedRow)["adoptedTargetId"], .null)
  }

  func testMissingBootstrapFailsLoudInsteadOfReturningAnEmptyList() async throws {
    let (handler, _) = try makeHandler(candidates: [], bootstrapConfigured: false)
    let response = await handler.handleFrame(frame("device.candidates"))
    XCTAssertFalse(response.ok, "an unconfigured bootstrap must be an error, not an empty list")
  }

  // MARK: - App-facing decode

  func testDecodeReportsIncompleteFactsInsteadOfAnEmptyList() throws {
    let unreadable = DeviceCandidatesResponseDecoding.presentation(Data("not json".utf8))
    guard case .unavailable = unreadable.availability else {
      return XCTFail("unreadable bytes must be unavailable, not empty")
    }

    let missingKey = DeviceCandidatesResponseDecoding.presentation(
      Data(#"{"id":"t","ok":true,"result":[{"state":"Connected"}]}"#.utf8))
    guard case .unavailable = missingKey.availability else {
      return XCTFail("a candidate without a connect key must be unavailable, not dropped")
    }

    let error = DeviceCandidatesResponseDecoding.presentation(
      Data(#"{"id":"t","ok":false,"error":{"message":"boom"}}"#.utf8))
    guard case .unavailable(let reason) = error.availability else {
      return XCTFail("a runtime error must surface its message")
    }
    XCTAssertEqual(reason, "boom")

    let empty = DeviceCandidatesResponseDecoding.presentation(
      Data(#"{"id":"t","ok":true,"result":[]}"#.utf8))
    XCTAssertEqual(empty.availability, .available)
    XCTAssertTrue(empty.candidates.isEmpty, "a genuinely empty list stays an empty list")

    let full = DeviceCandidatesResponseDecoding.presentation(
      Data(
        #"""
        {"id":"t","ok":true,"result":[
          {"connectKey":"abc","state":"Connected","adoptedTargetId":"t-1","bindingRevision":3},
          {"connectKey":"def","state":"Unauthorized","adoptedTargetId":null,"bindingRevision":null}
        ]}
        """#.utf8))
    XCTAssertEqual(full.availability, .available)
    XCTAssertEqual(full.candidates.count, 2)
    XCTAssertEqual(full.candidates[0].adoptedTargetID, "t-1")
    XCTAssertEqual(full.candidates[0].bindingRevision, 3)
    XCTAssertTrue(full.candidates[0].isAdopted)
    XCTAssertTrue(full.candidates[1].needsPhysicalTrust)
    XCTAssertNil(full.candidates[1].adoptedTargetID)
  }

  // Observed facts join only via a succeeded observe.device@1 job whose
  // evidence names the same target: identity mismatch, wrong operation and
  // non-terminal states all decorate nothing.
  func testObservedFactsJoinRequiresMatchingSucceededObservation() throws {
    let jobList = Data(
      #"""
      {"id":"t","ok":true,"result":[
        {"jobId":"job-old","operation":"observe.device@1","targetId":"t-1",
         "state":"succeeded","finishedAtUtc":"2026-08-01T00:00:00Z"},
        {"jobId":"job-new","operation":"observe.device@1","targetId":"t-1",
         "state":"succeeded","finishedAtUtc":"2026-08-06T00:00:00Z"},
        {"jobId":"job-running","operation":"observe.device@1","targetId":"t-1",
         "state":"running","finishedAtUtc":"2026-08-07T00:00:00Z"},
        {"jobId":"job-flash","operation":"flash.dayu200@1","targetId":"t-1",
         "state":"succeeded","finishedAtUtc":"2026-08-07T00:00:00Z"},
        {"jobId":"job-other","operation":"observe.device@1","targetId":"t-2",
         "state":"succeeded","finishedAtUtc":"2026-08-05T00:00:00Z"}
      ]}
      """#.utf8)
    let latest = DeviceCandidatesResponseDecoding.latestSucceededObservationJobIDs(
      jobList, adoptedTargetIDs: ["t-1"])
    XCTAssertEqual(latest, ["t-1": "job-new"], "newest succeeded observation wins; t-2 is not adopted")

    let evidence = Data(
      #"""
      {"id":"t","ok":true,"result":{"jobId":"job-new","observation":{
        "targetId":"t-1","model":"DAYU200","firmware":"OpenHarmony 5.0.0.71",
        "transport":"USB","confirmedAtUtc":"2026-08-06T00:00:00Z"}}}
      """#.utf8)
    let facts = try XCTUnwrap(
      DeviceCandidatesResponseDecoding.observedFacts(evidence, targetID: "t-1"))
    XCTAssertEqual(facts.model, "DAYU200")
    XCTAssertEqual(facts.firmware, "OpenHarmony 5.0.0.71")
    XCTAssertEqual(facts.transport, "USB")

    XCTAssertNil(
      DeviceCandidatesResponseDecoding.observedFacts(evidence, targetID: "t-2"),
      "evidence observed on one device must never decorate another")

    let base = DeviceListPresentation(
      availability: .available,
      candidates: [
        DeviceCandidatePresentation(
          connectKey: "abc", state: "Connected", adoptedTargetID: "t-1", bindingRevision: 1),
        DeviceCandidatePresentation(
          connectKey: "def", state: "Unauthorized", adoptedTargetID: nil, bindingRevision: nil),
      ])
    let decorated = DeviceCandidatesResponseDecoding.decorated(
      base, observedFactsByTargetID: ["t-1": facts])
    XCTAssertEqual(decorated.candidates[0].observedFacts, facts)
    XCTAssertNil(
      decorated.candidates[1].observedFacts,
      "an unadopted candidate carries no observation")
  }

  // The facade's provider protocol carries exactly one read and no writes.
  func testApplicationSurfaceCannotNameAWriteMethod() throws {
    let source = try String(
      contentsOf: URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent().deletingLastPathComponent()
        .deletingLastPathComponent()
        .appending(path: "Sources/ArkDeckWorkflows/DeviceListApplicationFacade.swift"),
      encoding: .utf8)
    let protocolBody = try XCTUnwrap(
      source.range(of: "public protocol DeviceListApplicationProviding: Sendable {")
        .map { source[$0.upperBound...] }
        .flatMap { rest in rest.range(of: "}").map { String(rest[..<$0.lowerBound]) } })
    XCTAssertEqual(
      protocolBody.split(separator: "\n").filter { $0.contains("func ") }.count, 1)
    XCTAssertTrue(protocolBody.contains("func refreshCandidates()"))
    XCTAssertTrue(source.contains("method: \"device.candidates\""))
    for forbidden in [
      "method: \"target.adopt\"", "method: \"job.submit\"", "method: \"job.cancel\"",
    ] {
      XCTAssertFalse(source.contains(forbidden), forbidden)
    }
  }
}
