import Foundation
import XCTest

@testable import ArkDeckClientKit
@testable import ArkDeckCore

/// The Settings facade in ClientKit: its Runtime storage reads, and the two
/// seams the App composes from ArkDeckWorkflows — the support-bundle exporter
/// and, for a UI-automation launch, the storage fixture.
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
    // ClientKit reads and maps; the exporter and the fixture owner it is
    // composed with stay in ArkDeckWorkflows.
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
