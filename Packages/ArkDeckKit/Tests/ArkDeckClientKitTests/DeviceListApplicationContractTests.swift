import Foundation
import XCTest
@testable import ArkDeckClientKit

final class DeviceListApplicationContractTests: XCTestCase {
  private var stateDirectory: URL!

  override func setUpWithError() throws {
    stateDirectory = FileManager.default.temporaryDirectory
      .appending(path: "clientkit-device-list-\(UUID().uuidString)", directoryHint: .isDirectory)
  }

  override func tearDownWithError() throws {
    if let stateDirectory { try? FileManager.default.removeItem(at: stateDirectory) }
  }

  // MARK: - App-facing decode

  func testDecodeReportsIncompleteFactsInsteadOfAnEmptyList() throws {
    let unreadable = DeviceCandidatesResponseDecoding.presentation(Data("not json".utf8))
    guard case .unavailable = unreadable.availability else {
      return XCTFail("unreadable bytes must be unavailable, not empty")
    }

    let missingKey = DeviceCandidatesResponseDecoding.presentation(
      Data(#"{"id":"t","ok":true,"result":{"schemaVersion":"arkdeck.device-observations/1","snapshotGeneration":"1","observedAtUtc":"2026-08-24T00:00:00Z","health":"current","observations":[{"authorizationState":"Connected","observationId":"obs-fixture-0","observationContinuity":"relationProven","displayName":null,"displayNameGeneration":"0"}]}}"#.utf8))
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
      Data(#"{"id":"t","ok":true,"result":{"schemaVersion":"arkdeck.device-observations/1","snapshotGeneration":"1","observedAtUtc":"2026-08-24T00:00:00Z","health":"current","observations":[]}}"#.utf8))
    XCTAssertEqual(empty.availability, .available)
    XCTAssertTrue(empty.candidates.isEmpty, "a genuinely empty list stays an empty list")

    let full = DeviceCandidatesResponseDecoding.presentation(
      Data(
        #"{"id":"t","ok":true,"result":{"schemaVersion":"arkdeck.device-observations/1","snapshotGeneration":"1","observedAtUtc":"2026-08-24T00:00:00Z","health":"current","observations":[{"adoptedTargetId":"t-1","bindingRevision":3,"deviceInformation":{"name":"Phone","systemVersion":"OpenHarmony-7.0.0.39","transport":"USB","observedAtUtc":"2026-08-24T00:00:00Z"},"candidateKey":"abc","authorizationState":"Connected","observationId":"obs-fixture-0","observationContinuity":"relationProven","displayName":null,"displayNameGeneration":"0"},{"adoptedTargetId":null,"bindingRevision":null,"candidateKey":"def","authorizationState":"Unauthorized","observationId":"obs-fixture-1","observationContinuity":"relationProven","displayName":null,"displayNameGeneration":"0"}]}}"#.utf8))
    XCTAssertEqual(full.availability, .available)
    XCTAssertEqual(full.candidates.count, 2)
    XCTAssertEqual(full.candidates[0].adoptedTargetID, "t-1")
    XCTAssertEqual(full.candidates[0].bindingRevision, 3)
    XCTAssertEqual(full.candidates[0].deviceInformation?.name, "Phone")
    XCTAssertEqual(
      full.candidates[0].deviceInformation?.systemVersion, "OpenHarmony-7.0.0.39")
    XCTAssertEqual(full.candidates[0].deviceInformation?.transport, "USB")
    XCTAssertTrue(full.candidates[0].isAdopted)
    XCTAssertTrue(full.candidates[1].needsPhysicalTrust)
    XCTAssertNil(full.candidates[1].adoptedTargetID)
  }

  // The one candidate projection carries only observation facts bound to the
  // same target. A mismatched nested target is ignored rather than decorating
  // the wrong physical device.
  func testObservedFactsProjectionRequiresMatchingTarget() throws {
    let response = Data(
      #"{"id":"t","ok":true,"result":{"schemaVersion":"arkdeck.device-observations/1","snapshotGeneration":"1","observedAtUtc":"2026-08-24T00:00:00Z","health":"current","observations":[{"adoptedTargetId":"t-1","bindingRevision":3,"observedFacts":{"targetId":"t-1","model":"DAYU200","firmware":"OpenHarmony 5.0.0.71","transport":"USB","confirmedAtUtc":"2026-08-06T00:00:00Z"},"candidateKey":"abc","authorizationState":"Connected","observationId":"obs-fixture-0","observationContinuity":"relationProven","displayName":null,"displayNameGeneration":"0"},{"adoptedTargetId":"t-2","bindingRevision":1,"observedFacts":{"targetId":"t-1","model":"WRONG"},"candidateKey":"def","authorizationState":"Connected","observationId":"obs-fixture-1","observationContinuity":"relationProven","displayName":null,"displayNameGeneration":"0"}]}}"#.utf8)
    let presentation = DeviceCandidatesResponseDecoding.presentation(response)
    let facts = try XCTUnwrap(presentation.candidates[0].observedFacts)
    XCTAssertEqual(facts.model, "DAYU200")
    XCTAssertEqual(facts.firmware, "OpenHarmony 5.0.0.71")
    XCTAssertEqual(facts.transport, "USB")
    XCTAssertNil(
      presentation.candidates[1].observedFacts,
      "facts observed on one target must never decorate another")
  }

  func testStaleCandidateObservationCannotBePresentedAsAuthorized() throws {
    let response = Data(
      #"{"id":"t","ok":true,"result":{"schemaVersion":"arkdeck.device-observations/1","snapshotGeneration":"1","observedAtUtc":"2026-08-13T00:00:00Z","health":"stale","observations":[{"adoptedTargetId":"t-1","bindingRevision":1,"candidateKey":"abc","authorizationState":"Connected","observationId":"obs-fixture-0","observationContinuity":"relationProven","displayName":null,"displayNameGeneration":"0"}]}}"#
        .utf8)
    let presentation = DeviceCandidatesResponseDecoding.presentation(response)
    let candidate = try XCTUnwrap(presentation.candidates.first)
    XCTAssertEqual(candidate.state, "Connected", "the raw historical HDC state is preserved")
    XCTAssertEqual(candidate.stateObservedAtUTC, "2026-08-13T00:00:00Z")
    XCTAssertEqual(candidate.stateObservationHealth, .stale)
    XCTAssertFalse(
      candidate.isAuthorized,
      "a failed follow-up probe must not project a cached Connected state as current readiness")
  }

  func testApplicationFacadeOwnsTheBoundedAuthorizationTimeoutAndReadyVerdict() async throws {
    try FileManager.default.createDirectory(
      at: stateDirectory, withIntermediateDirectories: true)
    let state = stateDirectory.appending(path: "device-authorization-state.txt")
    try Data().write(to: state)
    let provider = DeviceListApplicationFacade.make(arguments: [
      "ArkDeck", "--ui-test-devices", "--ui-test-device-poll-fast",
      "--ui-test-fixture-state", state.path,
    ])

    let timedOut = await provider.waitForAuthorization(connectKey: "7f2c091a445e21")
    XCTAssertEqual(timedOut.authorization, .timedOut)
    XCTAssertEqual(
      timedOut.presentation.candidates.first(where: {
        $0.connectKey == "7f2c091a445e21"
      })?.state, "Unauthorized")

    try Data("--ui-test-device-authorized".utf8).write(to: state)
    // The flip is not reserved for the wait: every candidate read answers from
    // the same state file, including the refresh the App's live observation
    // makes on its own timer. The App UI sweep therefore flips it only while
    // a retried wait is already polling.
    let live = await provider.refreshCandidates()
    XCTAssertEqual(
      live.candidates.first(where: { $0.connectKey == "7f2c091a445e21" })?.state, "Connected")
    let ready = await provider.waitForAuthorization(connectKey: "7f2c091a445e21")
    XCTAssertEqual(ready.authorization, .ready)
    XCTAssertTrue(
      ready.presentation.candidates.first(where: {
        $0.connectKey == "7f2c091a445e21"
      })?.isAuthorized == true)
  }

  // The facade's provider protocol carries the joined candidate projection
  // and authorization reads only; no method can name a Runtime write.
  func testApplicationSurfaceCannotNameAWriteMethod() throws {
    let source = try String(
      contentsOf: URL(filePath: #filePath)
        .deletingLastPathComponent().deletingLastPathComponent()
        .deletingLastPathComponent()
        .appending(path: "Sources/ArkDeckClientKit/DeviceListApplicationFacade.swift"),
      encoding: .utf8)
    for forbiddenImport in ["ArkDeckWorkflows", "ArkDeckRuntime", "ArkDeckOpenHarmony", "ArkDeckStorage"] {
      XCTAssertFalse(source.contains("import \(forbiddenImport)"), forbiddenImport)
    }
    var repository = URL(filePath: #filePath)
    for _ in 0..<5 { repository.deleteLastPathComponent() }
    let app = try String(contentsOf: repository.appending(
      path: "ArkDeckApp/Features/Devices/DeviceWorkspace.swift"), encoding: .utf8)
    XCTAssertTrue(app.contains("import ArkDeckClientKit"))
    XCTAssertFalse(app.contains("import ArkDeckWorkflows"))
    let protocolStart = try XCTUnwrap(
      source.range(of: "public protocol DeviceListApplicationProviding: Sendable {")?.upperBound)
    let protocolEnd = try XCTUnwrap(
      source.range(
        of: "public enum DeviceListApplicationFacade", range: protocolStart..<source.endIndex)?
        .lowerBound)
    let protocolBody = String(source[protocolStart..<protocolEnd])
    XCTAssertEqual(
      protocolBody.split(separator: "\n").filter { $0.contains("func ") }.count, 3)
    XCTAssertTrue(protocolBody.contains("func startupCandidates()"))
    XCTAssertTrue(protocolBody.contains("func refreshCandidates()"))
    XCTAssertTrue(protocolBody.contains("func waitForAuthorization(connectKey: String)"))
    XCTAssertTrue(source.contains("method: \"device.observations\""))
    XCTAssertFalse(source.contains("method: \"job.list\""))
    XCTAssertFalse(source.contains("method: \"job.evidence\""))
    for forbidden in [
      "method: \"target.adopt\"", "method: \"job.submit\"", "method: \"job.cancel\"",
    ] {
      XCTAssertFalse(source.contains(forbidden), forbidden)
    }
  }

}
