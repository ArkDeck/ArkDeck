// Every Import view of a DAYU200 flash bundle through Swift's daemon handler,
// the control frames the Rust Runtime's contract is derived from
// (CHG-2026-074, TASK-XPA-017, milestone M4).

import Foundation
import XCTest

@testable import ArkDeckAgentDaemon
@testable import ArkDeckCore
@testable import ArkDeckRuntime
@testable import ArkDeckStorage
@testable import ArkDeckWorkflows

/// A flash bundle's Import, as Swift's daemon answers it with its production
/// policy (`FlashBundleImportPolicy.production`), through every view:
///
/// - `artifact.import.begin` and `append`;
/// - `inspect`, by Import and by request, before and after the commit;
/// - `list`, `commit` and `inspection`;
/// - `abort` of a second bundle;
/// - a third bundle that does not fit the board, refused at its commit.
///
/// Run with `ARKDECK_CONTROL_FRAME_LOG` set, it leaves the frames the Rust
/// contract takes its Import schemas from. The bundles are the synthetic
/// archives of the Swift archive oracle (`rust/tests/fixtures/flash-archive`).
/// No device or Flash is involved.
final class FlashBundleImportViewsContractTests: XCTestCase {
  private var root: URL!
  private var artifacts: RuntimeArtifactStore!
  private var targets: RuntimeTargetStore!
  private var target: RuntimeTargetRecord!
  private var handler: RuntimeControlPlaneHandler!
  private var engine: RuntimeJobEngine!
  private let now = "2026-09-25T00:00:00Z"

  private static let archives: URL = {
    var url = URL(filePath: #filePath)
    for _ in 0..<5 { url.deleteLastPathComponent() }
    return url.appending(
      path: "rust/tests/fixtures/flash-archive/archives", directoryHint: .isDirectory)
  }()

  override func setUpWithError() throws {
    root = FileManager.default.temporaryDirectory.appending(path: "fbi-\(UUID().uuidString.prefix(8))")
    artifacts = try RuntimeArtifactStore(
      rootURL: root.appending(path: "artifacts"), nowUTC: { [now] in now })
    targets = try RuntimeTargetStore(directoryURL: root.appending(path: "targets"))
    let key = "150100424a544e4600"
    target = try targets.adopt(
      stableIdentitySHA256: HDCObservationProviderAdapter.stableIdentitySHA256(connectKey: key),
      connectKey: key, toolVersion: "3.2.0f", nowUTC: now
    ).record
    let capabilities = try RuntimeCapabilityStore(
      directoryURL: root.appending(path: "capabilities"))
    engine = try RuntimeJobEngine(
      configuration: .init(stateDirectory: root.appending(path: "engine")),
      providers: DeviceProviderRegistry(providers: [
        HDCObservationProviderAdapter(
          factsPort: RuntimeAgentExecutionContractTests.Facts(targets: targets, clock: .init()))
      ]),
      dispatcher: RuntimeAgentExecutionContractTests.Dispatcher(),
      capabilityStore: capabilities, artifactStore: artifacts, nowUTC: { [now] in now })
    handler = RuntimeControlPlaneHandler(
      engine: engine, capabilityStore: capabilities, providerIDs: ["hdc"],
      nowUTC: { [now] in now }, targetStore: targets, bootstrap: nil, artifactStore: artifacts,
      flashBundleImportDirectory: nil, flashBundleImportPolicy: .production, methodObserver: nil)
  }

  override func tearDownWithError() throws {
    handler = nil; engine = nil; artifacts = nil; targets = nil
    try? FileManager.default.removeItem(at: root)
  }

  private func send(
    _ method: String, _ params: [String: JSONValue], code: String? = nil,
    file: StaticString = #filePath, line: UInt = #line
  ) async throws -> [String: JSONValue] {
    let request = try ArkDeckAgentXPC.requestFrame(
      method: method, params: params, requestID: "flash-bundle-import")
    let response = try JSONDecoder().decode(
      AgentWireProtocol.Response.self, from: await handler.handleLine(request))
    XCTAssertEqual(response.error?.code, code, "\(method)", file: file, line: line)
    guard code == nil, case .object(let result)? = response.result else { return [:] }
    return result
  }

  private func intent(_ request: String, _ bytes: Data) -> [String: JSONValue] {
    [
      "schemaVersion": .string(ArtifactImportIntent.schemaVersion),
      "importRequestId": .string(request), "kind": .string("flash-bundle"),
      "targetId": .string(target.targetID),
      "bindingRevision": .string(String(target.bindingRevision)),
      "deviceProfile": .string("dayu200"), "name": .string("images.tar.gz"),
      "byteCount": .string(String(bytes.count)), "sha256": .string(SHA256Hex.string(of: bytes)),
    ]
  }

  private func upload(_ request: String, _ bytes: Data) async throws -> String {
    let began = try await send("artifact.import.begin", intent(request, bytes))
    guard case .string(let id)? = began["importId"] else {
      XCTFail("no Import")
      return ""
    }
    _ = try await send(
      "artifact.import.append",
      [
        "importId": .string(id), "generation": .string("1"), "offset": .string("0"),
        "byteCount": .string(String(bytes.count)),
        "sha256": .string(SHA256Hex.string(of: bytes)),
        "base64": .string(bytes.base64EncodedString()),
      ])
    return id
  }

  func testEveryImportViewOfAFlashBundleIsAnsweredAsTheRustContractRecordsIt() async throws {
    let complete = try Data(contentsOf: Self.archives.appending(path: "complete.tar.gz"))
    let unfit = try Data(contentsOf: Self.archives.appending(path: "nonconforming.tar.gz"))

    let id = try await upload("flash-views", complete)
    let pending = try await send("artifact.import.inspect", ["importId": .string(id)])
    XCTAssertEqual(pending["state"], .string("inProgress"))
    _ = try await send("artifact.import.inspect", ["importRequestId": .string("flash-views")])
    _ = try await send("artifact.import.list", [:])
    _ = try await send(
      "artifact.import.list",
      ["target": .string(target.targetID), "state": .string("inProgress")])
    let committed = try await send(
      "artifact.import.commit", ["importId": .string(id), "generation": .string("1")])
    guard case .object(let receipt)? = committed["receipt"] else {
      return XCTFail("no receipt")
    }
    XCTAssertEqual(
      receipt["validation"],
      .object(["kind": .string("flash-bundle"), "deviceProfile": .string("dayu200")]))
    _ = try await send("artifact.import.inspect", ["importId": .string(id)])
    _ = try await send("artifact.import.inspection", ["importId": .string(id)])
    _ = try await send("artifact.import.list", ["state": .string("committed")])

    _ = try await upload("flash-abort", complete)
    let aborted = try await send(
      "artifact.import.abort",
      ["importRequestId": .string("flash-abort"), "generation": .string("1")])
    XCTAssertEqual(aborted["state"], .string("aborted"))

    let unfitID = try await upload("flash-unfit", unfit)
    _ = try await send(
      "artifact.import.commit", ["importId": .string(unfitID), "generation": .string("1")],
      code: "invalidInput")
    let refused = try await send("artifact.import.inspect", ["importId": .string(unfitID)])
    XCTAssertEqual(refused["state"], .string("inProgress"))
    XCTAssertEqual(refused["receipt"], .null)
  }
}
