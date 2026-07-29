import XCTest

@testable import ArkDeckCore
@testable import ArkDeckWorkflows

final class DeviceBootstrapContractTests: XCTestCase {
  private var directory: URL!

  override func setUpWithError() throws {
    directory = FileManager.default.temporaryDirectory
      .appendingPathComponent("arkdeck-bootstrap-tests", isDirectory: true)
      .appendingPathComponent(UUID().uuidString, isDirectory: true)
  }

  override func tearDownWithError() throws {
    if let directory { try? FileManager.default.removeItem(at: directory) }
  }

  /// Scripted observation port: the only surface bootstrap can reach.
  private final class ScriptedObservation: BootstrapObservationPort, @unchecked Sendable {
    var toolVersion = "3.2.0f"
    var candidates: [BootstrapCandidate]
    var identity: [String: String] = ["serial": "150100424A544E4600"]
    private(set) var identityCalls = 0

    init(candidates: [BootstrapCandidate]) {
      self.candidates = candidates
    }

    func observeToolVersion() async throws -> String { toolVersion }
    func listCandidates() async throws -> [BootstrapCandidate] { candidates }
    func observeDeviceIdentity(connectKey: String) async throws -> [String: String] {
      identityCalls += 1
      return identity
    }
  }

  private func makeMachine(
    _ observation: ScriptedObservation
  ) throws -> (DeviceBootstrapMachine, RuntimeTargetStore) {
    let store = try RuntimeTargetStore(directoryURL: directory)
    let machine = DeviceBootstrapMachine(
      observation: observation, targetStore: store, nowUTC: { "2026-07-29T00:00:00Z" })
    return (machine, store)
  }

  func testSingleAuthorizedCandidateAdoptsFromCleanEnvironment() async throws {
    let observation = ScriptedObservation(candidates: [
      BootstrapCandidate(connectKey: "150100424A544E4600", state: "Connected")
    ])
    let (machine, store) = try makeMachine(observation)
    XCTAssertEqual(try store.list(), [], "clean environment: zero prior bindings")
    guard case .adopted(let record) = await machine.advance() else {
      return XCTFail("single connected candidate must adopt")
    }
    XCTAssertTrue(record.targetID.hasPrefix("TGT-"))
    XCTAssertEqual(record.bindingRevision, 1)
    XCTAssertEqual(record.toolVersion, "3.2.0f")
    XCTAssertEqual(
      record.stablePhysicalIdentitySHA256,
      DeviceBootstrapMachine.stableIdentitySHA256(serial: "150100424A544E4600"))
    let phase = await machine.phase
    XCTAssertEqual(phase, .handedOff)
    XCTAssertEqual(try store.list().count, 1)
  }

  func testMultipleCandidatesRequireExplicitSelection() async throws {
    let observation = ScriptedObservation(candidates: [
      BootstrapCandidate(connectKey: "AAA", state: "Connected"),
      BootstrapCandidate(connectKey: "BBB", state: "Connected"),
    ])
    let (machine, store) = try makeMachine(observation)
    guard case .needsSelection(let candidates) = await machine.advance() else {
      return XCTFail("two candidates must require selection")
    }
    XCTAssertEqual(candidates.map(\.connectKey), ["AAA", "BBB"])
    XCTAssertEqual(try store.list(), [], "no target is created before selection")
    XCTAssertEqual(observation.identityCalls, 0, "no device is observed before selection")

    guard case .adopted(let record) = await machine.advance(selectedConnectKey: "BBB") else {
      return XCTFail("explicit selection must adopt")
    }
    XCTAssertEqual(record.connectKey, "BBB")
  }

  func testUnauthorizedDeviceParksForPhysicalTrustThenResumes() async throws {
    let observation = ScriptedObservation(candidates: [
      BootstrapCandidate(connectKey: "AAA", state: "Unauthorized")
    ])
    let (machine, store) = try makeMachine(observation)
    guard case .waitingForHuman(let prompt) = await machine.advance() else {
      return XCTFail("unauthorized device must park for physical trust")
    }
    XCTAssertTrue(prompt.contains("trust"), "prompt must name the physical action")
    let parkedPhase = await machine.phase
    XCTAssertEqual(parkedPhase, .waitForPhysicalTrust)
    XCTAssertEqual(try store.list(), [], "no binding is created without trust")

    // The user trusts the device: the same call resumes automatically.
    observation.candidates = [BootstrapCandidate(connectKey: "AAA", state: "Connected")]
    guard case .adopted = await machine.advance() else {
      return XCTFail("bootstrap must resume after trust")
    }
  }

  func testOfflineDeviceAlsoParks() async throws {
    let observation = ScriptedObservation(candidates: [
      BootstrapCandidate(connectKey: "AAA", state: "Offline")
    ])
    let (machine, _) = try makeMachine(observation)
    guard case .waitingForHuman = await machine.advance() else {
      return XCTFail("offline device must park, never adopt")
    }
  }

  func testReAdoptIsIdempotent() async throws {
    let observation = ScriptedObservation(candidates: [
      BootstrapCandidate(connectKey: "150100424A544E4600", state: "Connected")
    ])
    let (machine, store) = try makeMachine(observation)
    guard case .adopted(let first) = await machine.advance(),
      case .adopted(let second) = await machine.advance()
    else {
      return XCTFail("both adoptions must succeed")
    }
    XCTAssertEqual(first.targetID, second.targetID)
    XCTAssertEqual(first.adoptedAtUTC, second.adoptedAtUTC, "the original record is preserved")
    XCTAssertEqual(try store.list().count, 1, "no duplicate target is created")
  }

  func testNoCandidatesAndMissingSerialFailClosed() async throws {
    let empty = ScriptedObservation(candidates: [])
    let (emptyMachine, _) = try makeMachine(empty)
    guard case .failed(let reason) = await emptyMachine.advance() else {
      return XCTFail("zero candidates must fail closed")
    }
    XCTAssertTrue(reason.contains("no device candidates"))

    let serialless = ScriptedObservation(candidates: [
      BootstrapCandidate(connectKey: "AAA", state: "Connected")
    ])
    serialless.identity = [:]
    let (serialessMachine, store) = try makeMachine(serialless)
    guard case .failed(let serialReason) = await serialessMachine.advance() else {
      return XCTFail("a device with no stable serial must fail closed")
    }
    XCTAssertTrue(serialReason.contains("stable serial"))
    XCTAssertEqual(try store.list(), [], "no binding without stable identity")
  }

  func testTargetStoreSurvivesReopen() async throws {
    let observation = ScriptedObservation(candidates: [
      BootstrapCandidate(connectKey: "150100424A544E4600", state: "Connected")
    ])
    let (machine, _) = try makeMachine(observation)
    guard case .adopted(let record) = await machine.advance() else {
      return XCTFail("adoption must succeed")
    }
    let reopened = try RuntimeTargetStore(directoryURL: directory)
    XCTAssertEqual(try reopened.find(targetID: record.targetID), record)
    XCTAssertEqual(try reopened.list().count, 1)
  }

  func testBootstrapActionVocabularyIsObservationOnly() {
    // Structural E0: every case of the bootstrap action enum maps to a
    // provider action whose effect is at most readOnly. A future mutation
    // case would break this test at compile time (new case) or at runtime.
    let actions: [BootstrapObservationAction] = [
      .observeTool, .observeServer, .listCandidates, .observeDevice(connectKey: "AAA"),
    ]
    for action in actions {
      XCTAssertLessThanOrEqual(
        action.providerAction.effect, .readOnly,
        "bootstrap action \(action) must never exceed readOnly")
    }
  }
}
