import Foundation
import XCTest

@testable import ArkDeckClientKit
@testable import ArkDeckCore

/// The Settings facade in ClientKit: its Runtime storage reads, and the two
/// composed support-bundle exporter and in-memory UI presentation fixture.
final class SettingsApplicationFacadeContractTests: XCTestCase {
  /// Stands in for the support-bundle exporter the App composes: one fixed
  /// preview, and a record of every scope an export was approved for.
  private actor DiagnosticBundles: SettingsDiagnosticBundleExporting {
    static let preview = SettingsDiagnosticBundlePreview(
      scopeSHA256: String(repeating: "a", count: 64),
      includedEntries: ["bundle.json", "metadata.json"],
      estimatedBytes: 2_048,
      deviceRawExcluded: true,
      sensitiveDataWarning: "fixture warning")
    private var approvals: [String] = []

    func preview(at destination: URL) -> SettingsDiagnosticBundlePreview { Self.preview }

    func export(to destination: URL, approvedScopeSHA256: String) -> URL {
      approvals.append(approvedScopeSHA256)
      return destination
    }

    func recordedApprovals() -> [String] { approvals }
  }

  /// Stands in for the storage owner the App composes for a UI-automation
  /// launch: it records each request and answers one status reply, or nothing
  /// while it is unreachable.
  private actor StorageFixture: SettingsRuntimeStorageFixture {
    private var reachable: Bool
    private var calls: [String] = []

    init(reachable: Bool) { self.reachable = reachable }

    func runtimeStorageReply(_ method: String, _ params: [String: JSONValue]?) -> Data? {
      calls.append(method)
      return reachable ? Data(Self.status.utf8) : nil
    }

    func setReachable(_ value: Bool) { reachable = value }

    func recordedCalls() -> [String] { calls }

    static let status = """
      {"id":"fixture","ok":true,"result":{"schemaVersion":"arkdeck.runtime-storage/1",\
      "sessionDomain":{"schemaVersion":"arkdeck.session-storage-status/1","generation":"4",\
      "rootPath":"/fixture/Sessions","rootKind":"default",\
      "policy":{"totalQuotaBytes":"12884901888","safetyMarginBytes":"3221225472",\
      "retentionDays":"45"},"usage":{"usedBytes":"4096",\
      "pinnedBytes":"0","sessionCount":"1","pinnedSessionCount":"0","unaccountedSessionCount":"1",\
      "measurementIncomplete":true},"catalogGeneration":null},"artifactDomain":{"schemaVersion":\
      "arkdeck.artifact-storage-status/1","rootReference":"arkdeck-runtime://artifacts",\
      "policy":"refuseNewWorkNeverEvict","totalBytes":"8589934592","usedBytes":"2684354560",\
      "remainingBytes":"5905580032"}}}
      """
  }

  /// A composed fixture answers in the Runtime's place, through the same
  /// validation and mapping, and a fixture that does not answer reads exactly
  /// as a Runtime that does not.
  func testAComposedStorageFixtureAnswersInPlaceOfTheRuntime() async throws {
    let fixture = StorageFixture(reachable: false)
    let provider = SettingsApplicationFacade.make(
      diagnosticBundles: DiagnosticBundles(), storageFixture: fixture)
    do {
      _ = try await provider.refresh()
      XCTFail("a fixture that does not answer must read as an unreachable Runtime")
    } catch SettingsApplicationError.runtimeStorageUnavailable {
    }

    await fixture.setReachable(true)
    let storage = try await provider.refresh().storage

    XCTAssertEqual(
      storage,
      SettingsStoragePresentation(
        generation: 4,
        rootPath: "/fixture/Sessions",
        usesCustomRoot: false,
        totalQuotaBytes: 12_884_901_888,
        safetyMarginBytes: 3_221_225_472,
        retentionDays: 45,
        runtimeArtifacts: SettingsRuntimeArtifactUsage(
          usedBytes: 2_684_354_560, totalBytes: 8_589_934_592, remainingBytes: 5_905_580_032),
        sessionRoot: SettingsSessionRootUsage(
          measuredBytes: 4_096, pinnedBytes: 0, pinnedSessionCount: 0,
          unaccountedSessionCount: 1, measurementIncomplete: true)))
    let calls = await fixture.recordedCalls()
    XCTAssertEqual(calls, ["runtime.storage.status", "runtime.storage.status"])
  }

  /// The pane's diagnostic bundle is previewed and exported by the composed
  /// exporter alone, and an export carries exactly the approved scope.
  func testTheDiagnosticBundleGoesThroughTheComposedExporter() async throws {
    let exporter = DiagnosticBundles()
    let provider = SettingsApplicationFacade.make(diagnosticBundles: exporter) { _, _ in nil }
    let destination = URL(filePath: "/fixture/ArkDeck-Diagnostics", directoryHint: .isDirectory)

    let preview = try await provider.previewDiagnosticBundle(at: destination)
    XCTAssertEqual(preview, DiagnosticBundles.preview)
    let exported = try await provider.exportDiagnosticBundle(
      to: destination, approvedPreview: preview)

    XCTAssertEqual(exported, destination)
    let approvals = await exporter.recordedApprovals()
    XCTAssertEqual(approvals, [preview.scopeSHA256])
  }

  /// A reply the reader cannot account for is refused, not rendered. Both
  /// failure surfaces exist so the pane can say "no answer" instead of
  /// showing a number that describes nothing.
  func testAnUnusableReplyIsRefusedRatherThanRendered() async throws {
    let unavailable = SettingsApplicationFacade.make(diagnosticBundles: DiagnosticBundles()) {
      _, _ in nil
    }
    do {
      _ = try await unavailable.refresh()
      XCTFail("a transport that did not answer must not produce a presentation")
    } catch SettingsApplicationError.runtimeStorageUnavailable {
    }

    // A well-formed envelope whose result is missing the artifact domain: the
    // exact shape a partially-updated daemon would send.
    let partial = SettingsApplicationFacade.make(diagnosticBundles: DiagnosticBundles()) { _, _ in
      Data(
        """
        {"id":"x","ok":true,"result":{"schemaVersion":"arkdeck.runtime-storage/1"}}
        """.utf8)
    }
    do {
      _ = try await partial.refresh()
      XCTFail("a reply missing a storage domain must not be rendered as zero")
    } catch SettingsApplicationError.runtimeStorageResponseInvalid {
    }

    let refused = SettingsApplicationFacade.make(diagnosticBundles: DiagnosticBundles()) { _, _ in
      Data(
        """
        {"id":"x","ok":false,"error":{"code":"recordUnreadable","message":"m"}}
        """.utf8)
    }
    do {
      _ = try await refused.refresh()
      XCTFail("a refusal must not produce a presentation")
    } catch SettingsApplicationError.runtimeStorageRejected(let code) {
      XCTAssertEqual(code, "recordUnreadable")
    }
  }

  func testInvalidSuccessAndMeasurementFlagsNeverPublishStorageFacts() async throws {
    let original = try XCTUnwrap(
      JSONSerialization.jsonObject(with: Data(StorageFixture.status.utf8)) as? [String: Any])
    for value: Any in [false, 1, "true", NSNull()] {
      var response = original
      response["ok"] = value
      let bytes = try JSONSerialization.data(withJSONObject: response)
      let provider = SettingsApplicationFacade.make(diagnosticBundles: DiagnosticBundles()) {
        _, _ in bytes
      }
      do {
        _ = try await provider.refresh()
        XCTFail("invalid success flag must not publish a valid-looking result")
      } catch SettingsApplicationError.runtimeStorageResponseInvalid {}
    }
    for value: Any in [0, 1, "false", NSNull()] {
      var response = original
      var result = try XCTUnwrap(response["result"] as? [String: Any])
      var session = try XCTUnwrap(result["sessionDomain"] as? [String: Any])
      var usage = try XCTUnwrap(session["usage"] as? [String: Any])
      usage["measurementIncomplete"] = value
      session["usage"] = usage
      result["sessionDomain"] = session
      response["result"] = result
      let bytes = try JSONSerialization.data(withJSONObject: response)
      let provider = SettingsApplicationFacade.make(diagnosticBundles: DiagnosticBundles()) {
        _, _ in bytes
      }
      do {
        _ = try await provider.refresh()
        XCTFail("malformed measurement state must not be rendered")
      } catch SettingsApplicationError.runtimeStorageResponseInvalid {}
    }
  }

  private actor ScriptedStorage {
    private var replies: [Data?]
    private(set) var calls: [(String, [String: JSONValue]?)] = []
    init(_ replies: [Data?]) { self.replies = replies }
    func reply(_ method: String, _ params: [String: JSONValue]?) -> Data? {
      calls.append((method, params))
      return replies.isEmpty ? nil : replies.removeFirst()
    }
  }

  /// The three generation-bound mutations, each with the one closed request
  /// shape the Runtime's App ingress admits, bound to the fixture status's
  /// generation 4. The selected root is not under a symlinked system
  /// directory, so the request path cannot depend on what exists on the host.
  private enum Mutation: CaseIterable {
    case policy, selectRoot, resetRoot

    var method: String {
      self == .policy ? "runtime.storage.policy" : "runtime.storage.root"
    }

    var params: [String: JSONValue] {
      switch self {
      case .policy:
        return [
          "expectedGeneration": .string("4"), "totalQuotaBytes": .string("20000"),
          "safetyMarginBytes": .string("1000"), "retentionDays": .string("30"),
        ]
      case .selectRoot:
        return [
          "expectedGeneration": .string("4"), "rootPath": .string("/fixture/selected-sessions"),
        ]
      case .resetRoot:
        return ["expectedGeneration": .string("4"), "resetToDefault": .bool(true)]
      }
    }

    func run(_ provider: any SettingsApplicationProviding) async throws
      -> SettingsStoragePresentation
    {
      switch self {
      case .policy:
        return try await provider.updateStoragePolicy(
          totalQuotaBytes: 20_000, safetyMarginBytes: 1_000, retentionDays: 30
        ).storage
      case .selectRoot:
        return try await provider.selectStorageRoot(
          URL(filePath: "/fixture/selected-sessions")
        ).storage
      case .resetRoot:
        return try await provider.resetStorageRoot().storage
      }
    }
  }

  /// A mutation that lost its generation race publishes the winner's state by
  /// reading it back. The mutation itself is sent exactly once.
  func testAConflictedStorageMutationReadsBackWithoutRepeatingIt() async throws {
    let refreshed = StorageFixture.status.replacingOccurrences(
      of: #""generation":"4""#, with: #""generation":"5""#)
    for mutation in Mutation.allCases {
      let script = ScriptedStorage([
        Data(StorageFixture.status.utf8),
        Data(#"{"ok":false,"error":{"code":"resourceConflict","message":"m"}}"#.utf8),
        Data(refreshed.utf8),
      ])
      let provider = SettingsApplicationFacade.make(diagnosticBundles: DiagnosticBundles()) {
        await script.reply($0, $1)
      }
      let storage = try await mutation.run(provider)
      XCTAssertEqual(storage.generation, 5, "\(mutation)")
      let calls = await script.calls
      XCTAssertEqual(
        calls.map(\.0),
        ["runtime.storage.status", mutation.method, "runtime.storage.status"], "\(mutation)")
      XCTAssertEqual(calls[1].1, mutation.params, "\(mutation)")
      XCTAssertNil(calls[2].1, "\(mutation)")
    }
  }

  /// Only a conflict is reconciled. A lost reply or one the reader cannot
  /// account for leaves the outcome unknown — the Runtime may have committed —
  /// and a refusal is final, so each is reported after exactly one send: never
  /// retried, never read back, never shown as a success.
  func testALostUnreadableOrRefusedStorageMutationIsSentOnceAndNeverRetried() async throws {
    let outcomes: [(reply: Data?, error: SettingsApplicationError)] = [
      (nil, .runtimeStorageUnavailable),
      (
        Data(#"{"ok":true,"result":{"schemaVersion":"arkdeck.runtime-storage/1"}}"#.utf8),
        .runtimeStorageResponseInvalid
      ),
      (
        Data(#"{"ok":false,"error":{"code":"invalidInput","message":"m"}}"#.utf8),
        .runtimeStorageRejected("invalidInput")
      ),
    ]
    for mutation in Mutation.allCases {
      for outcome in outcomes {
        let script = ScriptedStorage([Data(StorageFixture.status.utf8), outcome.reply])
        let provider = SettingsApplicationFacade.make(diagnosticBundles: DiagnosticBundles()) {
          await script.reply($0, $1)
        }
        do {
          _ = try await mutation.run(provider)
          XCTFail("\(mutation): an unconfirmed mutation must not publish a presentation")
        } catch let error as SettingsApplicationError {
          XCTAssertEqual(error, outcome.error, "\(mutation)")
        }
        let calls = await script.calls
        XCTAssertEqual(
          calls.map(\.0), ["runtime.storage.status", mutation.method], "\(mutation)")
        XCTAssertEqual(calls[1].1, mutation.params, "\(mutation)")
      }
    }
  }

  func testPresentationFixtureRequiresExplicitLaunchAndNeverCreatesStorage() async throws {
    XCTAssertNil(SettingsStoragePresentationFixture.make(arguments: ["ArkDeck"]))
    let fixture = try XCTUnwrap(
      SettingsStoragePresentationFixture.make(
        arguments: ["ArkDeck", "--ui-test-runtime-history"]))
    let provider = SettingsApplicationFacade.make(
      diagnosticBundles: DiagnosticBundles(), storageFixture: fixture)
    let initial = try await provider.refresh().storage
    XCTAssertEqual(initial.generation, 2)
    XCTAssertEqual(initial.totalQuotaBytes, 12_884_901_888)
    let selected = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
    XCTAssertFalse(FileManager.default.fileExists(atPath: selected.path))
    let updated = try await provider.updateStoragePolicy(
      totalQuotaBytes: 9_663_676_416, safetyMarginBytes: 1_073_741_824, retentionDays: 30
    ).storage
    XCTAssertEqual(updated.generation, 3)
    XCTAssertEqual(updated.retentionDays, 30)
    let custom = try await provider.selectStorageRoot(selected).storage
    XCTAssertTrue(custom.usesCustomRoot)
    XCTAssertEqual(custom.rootPath, selected.standardizedFileURL.path)
    XCTAssertFalse(FileManager.default.fileExists(atPath: selected.path))
    let reset = try await provider.resetStorageRoot().storage
    XCTAssertFalse(reset.usesCustomRoot)
    XCTAssertEqual(reset.rootPath, initial.rootPath)
    XCTAssertEqual(reset.generation, 5)
  }

  func testPresentationFixtureCanLoseAndRecoverItsReplyWithoutAStorageOwner() async throws {
    let state = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: state) }
    try "--ui-test-runtime-history-unreachable".write(to: state, atomically: true, encoding: .utf8)
    let fixture = try XCTUnwrap(
      SettingsStoragePresentationFixture.make(arguments: [
        "ArkDeck", "--ui-test-runtime-history", "--ui-test-fixture-state", state.path,
      ]))
    let provider = SettingsApplicationFacade.make(
      diagnosticBundles: DiagnosticBundles(), storageFixture: fixture)
    do {
      _ = try await provider.refresh()
      XCTFail("unreachable presentation must not publish storage values")
    } catch SettingsApplicationError.runtimeStorageUnavailable {}
    try "".write(to: state, atomically: true, encoding: .utf8)
    let recovered = try await provider.refresh().storage
    XCTAssertEqual(recovered.generation, 2)
    XCTAssertFalse(try XCTUnwrap(recovered.sessionRoot).measurementIncomplete)
  }

  /// The production figure must keep coming from the Runtime. Recomputing it in
  /// process is the defect, not an optimisation: the App Sandbox places the
  /// daemon's state directory outside this container.
  func testProductionUsageIsReadFromRuntimeAndRenderedPerDomain() throws {
    let facade = try source(
      "Packages/ArkDeckKit/Sources/ArkDeckClientKit/SettingsApplicationFacade.swift")
    let view = try source("ArkDeckApp/Features/Settings/SettingsRootView.swift")

    XCTAssertTrue(facade.contains("method: \"runtime.storage.status\""))
    XCTAssertTrue(facade.contains("ArkDeckControlProtocol.currentVersion"))
    XCTAssertFalse(facade.contains("method: \"artifact.quota\""))
    XCTAssertTrue(view.contains("storage.runtimeArtifacts"))
    XCTAssertTrue(view.contains("sessionRoot.measuredBytes"))
    XCTAssertTrue(view.contains("settings.storage.runtimeUnavailable"))
    XCTAssertTrue(view.contains("settings.storage.sessionUsage"))
    // ClientKit reads and maps without importing the Runtime storage owner.
    for forbiddenImport in ["ArkDeckWorkflows", "ArkDeckStorage", "ArkDeckRuntime"] {
      XCTAssertFalse(facade.contains("import \(forbiddenImport)"), forbiddenImport)
    }
  }

  private func source(_ path: String) throws -> String {
    var repository = URL(filePath: #filePath)
    for _ in 0..<5 { repository.deleteLastPathComponent() }
    return try String(contentsOf: repository.appending(path: path), encoding: .utf8)
  }
}
