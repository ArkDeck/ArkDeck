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

  /// S7's timeline, through the same fixture reads the App makes: a wait times
  /// out on the Unauthorized device, the owner then trusts it and the live
  /// observation reads Connected, and later the device reads Unauthorized
  /// again. The Connected read ends the verdict. The later Unauthorized read
  /// alone could not tell — it matches the state the verdict was drawn from —
  /// which is why the App applies the rule to every read it publishes.
  func testALaterReadInAnotherStateEndsATimedOutVerdict() async throws {
    try FileManager.default.createDirectory(
      at: stateDirectory, withIntermediateDirectories: true)
    let state = stateDirectory.appending(path: "device-authorization-state.txt")
    try Data().write(to: state)
    let provider = DeviceListApplicationFacade.make(arguments: [
      "ArkDeck", "--ui-test-devices", "--ui-test-device-poll-fast",
      "--ui-test-fixture-state", state.path,
    ])
    let device = "7f2c091a445e21"

    let timedOut = await provider.waitForAuthorization(connectKey: device)
    XCTAssertEqual(timedOut.authorization, .timedOut)
    let unchanged = await provider.refreshCandidates()
    XCTAssertFalse(
      unchanged.endsTrustWaitVerdict(on: device, concludedFrom: timedOut.presentation),
      "a read that still shows the device Unauthorized keeps the verdict it describes")

    try Data("--ui-test-device-authorized".utf8).write(to: state)
    let trusted = await provider.refreshCandidates()
    XCTAssertTrue(
      trusted.endsTrustWaitVerdict(on: device, concludedFrom: timedOut.presentation),
      "the device read Connected after the wait timed out; that episode is over")

    try Data().write(to: state)
    let unauthorizedAgain = await provider.refreshCandidates()
    XCTAssertFalse(
      unauthorizedAgain.endsTrustWaitVerdict(on: device, concludedFrom: timedOut.presentation),
      "the Unauthorized read alone matches the verdict's own; only the read in between ends it")

    // The App's device model applies the rule to every read it publishes —
    // startup, the live ticks and Re-check all finish through one place —
    // against the observation the verdict was drawn from.
    var repository = URL(filePath: #filePath)
    for _ in 0..<5 { repository.deleteLastPathComponent() }
    let app = try String(
      contentsOf: repository.appending(path: "ArkDeckApp/Features/Devices/DeviceWorkspace.swift"),
      encoding: .utf8)
    XCTAssertTrue(app.contains("    presentation = current\n    endVerdictIfTheDeviceMoved(current)\n"))
    XCTAssertTrue(
      app.contains("current.endsTrustWaitVerdict(on: waited, concludedFrom: concluded)"))
    XCTAssertEqual(app.components(separatedBy: "presentation = current").count - 1, 1)
  }

  func testOnlyASuccessfulReadInAnotherStateEndsAWaitVerdict() {
    func observation(
      _ states: [String: String],
      health: DeviceCandidatePresentation.StateObservationHealth = .current
    ) -> DeviceListPresentation {
      DeviceListPresentation(
        availability: .available,
        candidates: states.sorted(by: { $0.key < $1.key }).map {
          DeviceCandidatePresentation(
            connectKey: $0.key, state: $0.value, adoptedTargetID: nil, bindingRevision: nil,
            stateObservationHealth: health)
        })
    }
    let device = "7f2c091a445e21"
    let other = "150100469346864"
    let unreadable = DeviceListPresentation(
      availability: .unavailable(reason: "Runtime unreachable"), candidates: [])
    let waitedOnUnauthorized = observation([device: "Unauthorized", other: "Connected"])

    let later: [(String, DeviceListPresentation, Bool)] = [
      ("same state", observation([device: "Unauthorized", other: "Connected"]), false),
      ("same state, stale", observation([device: "Unauthorized"], health: .stale), false),
      ("another device moved", observation([device: "Unauthorized", other: "Offline"]), false),
      ("authorized", observation([device: "Connected"]), true),
      ("authorized, stale", observation([device: "Connected"], health: .stale), true),
      ("offline", observation([device: "Offline"]), true),
      ("gone", observation([other: "Connected"]), true),
      ("unreadable", unreadable, false),
      ("checking", .loading, false),
    ]
    for (name, read, ends) in later {
      XCTAssertEqual(
        read.endsTrustWaitVerdict(on: device, concludedFrom: waitedOnUnauthorized), ends, name)
    }

    // A verdict drawn while the device was out of sight, or while the
    // observation could not be read, ends at the first successful read that
    // shows something else.
    let waitedOnGone = observation([other: "Connected"])
    XCTAssertTrue(
      observation([device: "Unauthorized"]).endsTrustWaitVerdict(
        on: device, concludedFrom: waitedOnGone))
    XCTAssertFalse(
      observation([other: "Offline"]).endsTrustWaitVerdict(
        on: device, concludedFrom: waitedOnGone))
    XCTAssertTrue(
      observation([device: "Unauthorized"]).endsTrustWaitVerdict(
        on: device, concludedFrom: unreadable))
    XCTAssertFalse(unreadable.endsTrustWaitVerdict(on: device, concludedFrom: unreadable))
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
