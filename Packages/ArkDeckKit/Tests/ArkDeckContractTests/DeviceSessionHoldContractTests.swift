import Foundation
import XCTest

@testable import ArkDeckCore
@testable import ArkDeckRuntime
@testable import ArkDeckStorage
@testable import ArkDeckWorkflows

/// One device, one pair of hands (TASK-IDC-003).
///
/// The mutation lane already serialises contending work, which makes it safe
/// and invisible. Measured on the device before this existed: two captures
/// submitted 0.05s apart both succeeded, the second taking 2713ms against the
/// first's 1473ms. It queued, nothing refused it, and nothing told anyone -
/// so a gesture could land in the middle of somebody's capture and both
/// people would read a clean result.
///
/// These pin when the refusal fires, because a refusal that fires too widely
/// is worse than none: it would block ordinary work on a device nobody is
/// sitting at.
final class DeviceSessionHoldContractTests: XCTestCase {
  private var stateDirectory: URL!

  override func setUpWithError() throws {
    stateDirectory = FileManager.default.temporaryDirectory
      .appending(path: "arkdeck-hold-\(UUID().uuidString)", directoryHint: .isDirectory)
  }

  override func tearDownWithError() throws {
    if let stateDirectory { try? FileManager.default.removeItem(at: stateDirectory) }
  }

  private func engine(now: @escaping @Sendable () -> String) throws -> RuntimeJobEngine {
    try RuntimeJobEngine(
      configuration: .init(stateDirectory: stateDirectory),
      providers: DeviceProviderRegistry(providers: []),
      dispatcher: HoldDispatcher(),
      capabilityStore: try RuntimeCapabilityStore(
        directoryURL: stateDirectory.appending(path: "capabilities", directoryHint: .isDirectory)),
      nowUTC: now)
  }

  private func request(
    client: String, screenshotOnly: Bool
  ) throws -> RuntimeOperationRequest {
    var inputs: [String: JSONValue] = [
      "durationSeconds": .integer(1),
      "captureHilog": .bool(!screenshotOnly),
      "uiDump": .bool(false), "crashLogs": .bool(false),
      "uiScreenshot": .bool(true), "uiComponentTree": .bool(false),
    ]
    if !screenshotOnly { inputs["captureHilog"] = .bool(true) }
    return try RuntimeOperationRequest(
      requestID: "req-hold", idempotencyKey: "idem-\(UUID().uuidString)",
      target: DurableTargetReference(targetID: "TGT-1", expectedBindingRevision: 1),
      operation: RuntimeOperationReference(id: "capture.diagnostics", version: 1),
      inputs: inputs,
      clientContext: RuntimeClientContext(clientName: client))
  }

  private let identity = String(repeating: "a", count: 64)

  /// A session's own client keeps working. Every screenshot after the first
  /// refreshes the hold rather than colliding with it.
  func testTheClientHoldingTheDeviceIsNotRefusedByItsOwnHold() async throws {
    let engine = try engine(now: { "2026-08-26T10:00:00Z" })
    let descriptor = try XCTUnwrap(
      RuntimeOperationCatalog.descriptor(reference: "capture.diagnostics@1"))
    for _ in 0..<3 {
      try await engine.admitAgainstDeviceHold(
        request: try request(client: "ArkDeckApp.Diagnostics", screenshotOnly: true),
        descriptor: descriptor, effect: .deviceMutation, deviceIdentity: identity)
    }
  }

  /// Somebody else's mutation is refused with a typed reason that names who
  /// holds the device and since when, so the person reading it can go and ask.
  func testAnotherClientIsRefusedWithATypedReason() async throws {
    let engine = try engine(now: { "2026-08-26T10:00:00Z" })
    let descriptor = try XCTUnwrap(
      RuntimeOperationCatalog.descriptor(reference: "capture.diagnostics@1"))
    try await engine.admitAgainstDeviceHold(
      request: try request(client: "ArkDeckApp.Diagnostics", screenshotOnly: true),
      descriptor: descriptor, effect: .deviceMutation, deviceIdentity: identity)
    do {
      try await engine.admitAgainstDeviceHold(
        request: try request(client: "arkdeck-cli", screenshotOnly: false),
        descriptor: descriptor, effect: .deviceMutation, deviceIdentity: identity)
      XCTFail("a second pair of hands on one device must be refused, not queued")
    } catch let error as RuntimeJobEngineError {
      guard case .rejected(let code, let message) = error, code == .deviceBusyBySession else {
        return XCTFail("expected deviceBusyBySession, got \(error)")
      }
      XCTAssertTrue(message.contains("ArkDeckApp.Diagnostics"), message)
      XCTAssertTrue(
        message.contains("not queued"),
        "the refusal has to say it was refused rather than delayed: \(message)")
    }
  }

  /// A hold is interactive, and two minutes without an act is somebody having
  /// walked away. The device then belongs to whoever asks next.
  func testAHoldNobodyHasActedOnExpires() async throws {
    let clock = HoldClock(value: "2026-08-26T10:00:00Z")
    let engine = try engine(now: { clock.value })
    let descriptor = try XCTUnwrap(
      RuntimeOperationCatalog.descriptor(reference: "capture.diagnostics@1"))
    try await engine.admitAgainstDeviceHold(
      request: try request(client: "ArkDeckApp.Diagnostics", screenshotOnly: true),
      descriptor: descriptor, effect: .deviceMutation, deviceIdentity: identity)
    clock.value = "2026-08-26T10:03:00Z"
    try await engine.admitAgainstDeviceHold(
      request: try request(client: "arkdeck-cli", screenshotOnly: false),
      descriptor: descriptor, effect: .deviceMutation, deviceIdentity: identity)
  }

  /// Ordinary work neither claims a device nor is blocked for lack of a claim.
  /// A refusal that fired on every capture would be worse than none.
  func testOrdinaryWorkTakesNoHoldAndBlocksNobody() async throws {
    let engine = try engine(now: { "2026-08-26T10:00:00Z" })
    let descriptor = try XCTUnwrap(
      RuntimeOperationCatalog.descriptor(reference: "capture.diagnostics@1"))
    try await engine.admitAgainstDeviceHold(
      request: try request(client: "arkdeck-cli", screenshotOnly: false),
      descriptor: descriptor, effect: .deviceMutation, deviceIdentity: identity)
    try await engine.admitAgainstDeviceHold(
      request: try request(client: "someone-else", screenshotOnly: false),
      descriptor: descriptor, effect: .deviceMutation, deviceIdentity: identity)
  }

  /// A read touches nobody's device, so it is never refused for this.
  func testAReadIsNeverRefusedByAHold() async throws {
    let engine = try engine(now: { "2026-08-26T10:00:00Z" })
    let descriptor = try XCTUnwrap(
      RuntimeOperationCatalog.descriptor(reference: "capture.diagnostics@1"))
    try await engine.admitAgainstDeviceHold(
      request: try request(client: "ArkDeckApp.Diagnostics", screenshotOnly: true),
      descriptor: descriptor, effect: .deviceMutation, deviceIdentity: identity)
    try await engine.admitAgainstDeviceHold(
      request: try request(client: "arkdeck-cli", screenshotOnly: false),
      descriptor: descriptor, effect: .readOnly, deviceIdentity: identity)
  }

  /// Two devices are two sessions. Holding one says nothing about the other.
  func testAHoldOnOneDeviceDoesNotReachAnother() async throws {
    let engine = try engine(now: { "2026-08-26T10:00:00Z" })
    let descriptor = try XCTUnwrap(
      RuntimeOperationCatalog.descriptor(reference: "capture.diagnostics@1"))
    try await engine.admitAgainstDeviceHold(
      request: try request(client: "ArkDeckApp.Diagnostics", screenshotOnly: true),
      descriptor: descriptor, effect: .deviceMutation, deviceIdentity: identity)
    try await engine.admitAgainstDeviceHold(
      request: try request(client: "arkdeck-cli", screenshotOnly: false),
      descriptor: descriptor, effect: .deviceMutation,
      deviceIdentity: String(repeating: "b", count: 64))
  }

  /// A host-only plan has no device to be busy on.
  func testAPlanWithNoDeviceIsNeverRefused() async throws {
    let engine = try engine(now: { "2026-08-26T10:00:00Z" })
    let descriptor = try XCTUnwrap(
      RuntimeOperationCatalog.descriptor(reference: "capture.diagnostics@1"))
    try await engine.admitAgainstDeviceHold(
      request: try request(client: "ArkDeckApp.Diagnostics", screenshotOnly: true),
      descriptor: descriptor, effect: .deviceMutation, deviceIdentity: identity)
    try await engine.admitAgainstDeviceHold(
      request: try request(client: "arkdeck-cli", screenshotOnly: false),
      descriptor: descriptor, effect: .deviceMutation, deviceIdentity: nil)
  }
}

private final class HoldClock: @unchecked Sendable {
  var value: String
  init(value: String) { self.value = value }
}

private struct HoldDispatcher: RuntimeProcessDispatching {
  func dispatch(_ plan: TypedProcessPlan) async throws -> ProviderProcessReceipt {
    ProviderProcessReceipt(
      exitStatus: 0, stdout: Data(), stderr: Data(), stdoutTruncated: false,
      durationSeconds: 0)
  }
}
