// Shared Swift oracle for a workspace project removed after its presets
// (TASK-XPA-015, M3): every answer the production control plane gives,
// through the registration owner, once a registered project's only preset was
// removed and then the project itself — the removed preset's record (its
// tombstone) still naming a project the store no longer holds — and what a
// store damaged in any other way answers.
//
// The owner used to refuse every read of such a store, so this was recorded
// twice: once before the fix, as the defect's evidence
// (`before-fix-frames.jsonl`: every read after the removal `recordUnreadable`),
// and once after it (`frames.jsonl`), which the Rust owner replays. After the
// removal the store reads again: the preset's removal replayed answers its
// tombstone, the list is empty, the project and its presets are not found,
// the same registration registers the project again and its preset's
// registration answers its tombstone; a tombstone whose last mutation digest
// was altered in the file is refused as before, and the store reads again once
// the file is restored.
//
// Host-local only: a fabricated root, no device, no daemon process, no
// Runtime composition. Record with
// `ARKDECK_RUST_WORKSPACE_TOMBSTONE_RECORD=/private/tmp/<new directory>`.
import Darwin
import Foundation
import XCTest

@testable import ArkDeckAgentComposition
@testable import ArkDeckAgentDaemon
@testable import ArkDeckCore
@testable import ArkDeckRuntime
@testable import ArkDeckStorage
@testable import ArkDeckWorkflows

final class WorkspaceTombstoneOracleContractTests: XCTestCase {
  private static let repository: URL = {
    var url = URL(filePath: #filePath)
    for _ in 0..<5 { url.deleteLastPathComponent() }
    return url
  }()
  private static let oracle = repository.appending(
    path: "rust/tests/fixtures/workspace-tombstone-oracle", directoryHint: .isDirectory)
  private static let recordVariable = "ARKDECK_RUST_WORKSPACE_TOMBSTONE_RECORD"
  /// The recording's fixed root: the registration pins the project's root by
  /// path, and its reference and preset reference derive from the requests.
  private static let oracleRoot = URL(
    filePath: "/private/tmp/arkdeck-workspace-tombstone-oracle", directoryHint: .isDirectory)
  private static let timestamp = "2026-09-25T00:00:00Z"
  private static let sourceMap = "entry/build/default/outputs/default/mapping/sourceMaps.map"
  /// The running test's root, emptied first and removed after it.
  private var root: URL?

  override func tearDownWithError() throws {
    if let root { try? FileManager.default.removeItem(at: root) }
  }

  private func physical(_ url: URL) throws -> URL {
    guard let resolved = realpath(url.path, nil) else { throw POSIXError(.ENOENT) }
    defer { free(resolved) }
    return URL(filePath: String(cString: resolved), directoryHint: .isDirectory)
  }

  /// The production handler over the registration owner and a Job engine
  /// with no provider: nothing here plans or runs a Job.
  private func handler(state: URL) throws -> RuntimeControlPlaneHandler {
    let store = try RuntimeWorkspaceProjectStore(rootURL: state, nowUTC: { Self.timestamp })
    let capabilities = try RuntimeCapabilityStore(
      directoryURL: state.appending(path: "capabilities", directoryHint: .isDirectory))
    let providers = DeviceProviderRegistry(providers: [])
    let engine = try RuntimeJobEngine(
      configuration: .init(
        stateDirectory: state.appending(path: "engine", directoryHint: .isDirectory)),
      providers: providers, dispatcher: RefusingTombstoneOracleDispatcher(),
      capabilityStore: capabilities, artifactStore: nil,
      workspaceProjectStore: store, nowUTC: { Self.timestamp })
    return RuntimeControlPlaneHandler(
      engine: engine, capabilityStore: capabilities,
      providerIDs: providers.registeredProviderIDs, nowUTC: { Self.timestamp },
      targetStore: nil, bootstrap: nil, targetObservations: nil,
      hdcRuntimeDiagnostics: nil, artifactStore: nil, historyFilterStore: nil,
      flashBundleImportDirectory: state.appending(
        path: "flash-bundle-imports", directoryHint: .isDirectory),
      flashBundleImportPolicy: .production,
      flashPrerequisiteObserver: nil, flashLanePlanPreviewer: nil,
      rockchipBootloaderStatusObserver: nil, rockchipDeviceAccessObserver: nil,
      rockchipLoaderBindingCoordinator: nil, rockchipPostFlashAliasReconciler: nil,
      workspaceProjects: [], methodObserver: nil)
  }

  /// Every exchange, as the control-frame recorder spells it.
  private final class Frames: @unchecked Sendable {
    var lines: [Data] = []
  }

  @discardableResult
  private func send(
    _ handler: RuntimeControlPlaneHandler, _ frames: Frames, _ method: String,
    _ params: [String: JSONValue] = [:]
  ) async throws -> AgentWireProtocol.Response {
    let request = AgentWireProtocol.Request(
      id: UUID().uuidString, method: method, params: params)
    let response = await handler.handleFrame(try JSONEncoder().encode(request))
    frames.lines.append(
      try ControlFrameRecord(request: request, response: response).encodedLine())
    return response
  }

  func testAProjectRemovedAfterItsPresetsLeavesAReadableStore() async throws {
    let root = Self.oracleRoot
    self.root = root
    try? FileManager.default.removeItem(at: root)
    try FileManager.default.createDirectory(
      at: root.appending(path: "project", directoryHint: .isDirectory),
      withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
    let project = try physical(root.appending(path: "project", directoryHint: .isDirectory))
    let state = root.appending(path: "state", directoryHint: .isDirectory)
    let daemon = try handler(state: state)
    let frames = Frames()

    let registration: [String: JSONValue] = [
      "registrationRequestId": .string("tombstone-project"), "kind": .string("openharmony"),
      "root": .string(project.path),
    ]
    let registered = try await send(daemon, frames, "workspace.project.register", registration)
    guard case .object(let resource)? = registered.result,
      case .string(let projectRef)? = resource["projectRef"]
    else { return XCTFail("the project registers: \(String(describing: registered.error))") }
    let presetRegistration: [String: JSONValue] = [
      "registrationRequestId": .string("tombstone-symbol"), "projectRef": .string(projectRef),
      "kind": .string("symbol"), "templateRef": .string("openharmony.arkts-symbol@1"),
      "timeoutSeconds": .string("300"), "relativeSourceMap": .string(Self.sourceMap),
    ]
    let preset = try await send(daemon, frames, "workspace.preset.register", presetRegistration)
    guard case .object(let presetResource)? = preset.result,
      case .string(let presetRef)? = presetResource["presetRef"]
    else { return XCTFail("the preset registers: \(String(describing: preset.error))") }

    // The preset, then the project.
    let removal: [String: JSONValue] = [
      "mutationRequestId": .string("tombstone-symbol-remove"),
      "projectRef": .string(projectRef), "presetRef": .string(presetRef),
      "expectedGeneration": .string("1"),
    ]
    try await send(daemon, frames, "workspace.preset.remove", removal)
    try await send(
      daemon, frames, "workspace.project.remove",
      ["projectRef": .string(projectRef), "expectedGeneration": .string("1")])

    // What the store answers with the tombstone left behind: the removal
    // replayed, the lists and the project, the registration repeated.
    try await send(daemon, frames, "workspace.preset.remove", removal)
    try await send(daemon, frames, "workspace.project.list")
    try await send(daemon, frames, "workspace.project.show", ["projectRef": .string(projectRef)])
    try await send(daemon, frames, "workspace.preset.list", ["projectRef": .string(projectRef)])
    try await send(daemon, frames, "workspace.project.register", registration)
    try await send(daemon, frames, "workspace.project.list")
    try await send(daemon, frames, "workspace.preset.list", ["projectRef": .string(projectRef)])
    try await send(daemon, frames, "workspace.preset.register", presetRegistration)

    // A tombstone damaged in the file is refused; the restored file reads.
    let document = state.appending(path: "workspace-projects/projects.json")
    let original = try Data(contentsOf: document)
    let text = String(decoding: original, as: UTF8.self)
    guard let digest = try JSONSerialization.jsonObject(with: original) as? [String: Any],
      let presets = digest["presets"] as? [[String: Any]],
      let recorded = presets.first?["lastMutationDigest"] as? String
    else { return XCTFail("the store keeps the tombstone") }
    XCTAssertEqual(text.components(separatedBy: recorded).count, 2)
    try Data(
      text.replacingOccurrences(of: recorded, with: String(repeating: "0", count: 64)).utf8
    ).write(to: document)
    try await send(daemon, frames, "workspace.project.list")
    try await send(daemon, frames, "workspace.preset.list", ["projectRef": .string(projectRef)])
    try original.write(to: document)
    try await send(daemon, frames, "workspace.project.list")

    let answers = frames.lines.reduce(into: Data()) { $0 += $1 + Data("\n".utf8) }
    if let output = ProcessInfo.processInfo.environment[Self.recordVariable] {
      let directory = URL(filePath: output, directoryHint: .isDirectory)
      try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
      try answers.write(to: directory.appending(path: "frames.jsonl"))
      return
    }

    // The checked-in oracle is what this owner answers, frame by frame.
    let expected = try Data(contentsOf: Self.oracle.appending(path: "frames.jsonl"))
      .split(separator: UInt8(ascii: "\n"))
    let actual = answers.split(separator: UInt8(ascii: "\n"))
    XCTAssertEqual(expected.count, actual.count, "frame count")
    for (index, (lhs, rhs)) in zip(expected, actual).enumerated() {
      XCTAssertEqual(
        String(decoding: lhs, as: UTF8.self), String(decoding: rhs, as: UTF8.self),
        "frame \(index)")
    }
  }
}

/// No Job runs here; a dispatch would be a defect of the oracle.
private struct RefusingTombstoneOracleDispatcher: RuntimeProcessDispatching {
  func unavailableReason(providerID: String) -> String? { "the oracle dispatches nothing" }

  func dispatch(_ plan: TypedProcessPlan) async throws -> ProviderProcessReceipt {
    throw RuntimeDispatchFailure.failed("the oracle dispatches nothing")
  }
}
