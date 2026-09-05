import ArkDeckCore
import ArkDeckWorkflows
import XCTest

/// The Storage pane renders nothing until the Runtime-owned storage owner has
/// answered. Developer machines run the daemon and hosted runners do not, so
/// without a fixture the UI sweep was green locally and red nightly. These
/// tests hold the fixture to the daemon's own contract and to the rule that
/// nothing reaches it without the launch argument.
final class SettingsStorageUIFixtureContractTests: XCTestCase {
  func testOrdinaryLaunchNeverReachesTheFixture() {
    XCTAssertFalse(SettingsStorageUIFixture.isSelected(arguments: ["/Applications/ArkDeck.app"]))
    XCTAssertFalse(
      SettingsStorageUIFixture.isSelected(arguments: ["--ui-test-devices", "--ui-test-flash"]))
    XCTAssertNil(SettingsStorageUIFixture.owner(arguments: ["--ui-test-viewer"]))

    XCTAssertTrue(SettingsStorageUIFixture.isSelected(arguments: ["--ui-test-runtime-history"]))
    XCTAssertNotNil(
      SettingsStorageUIFixture.owner(
        arguments: ["/Applications/ArkDeck.app", "--ui-test-runtime-history"]))
  }

  /// The fixture launch goes through the production facade: the same request
  /// framing, the same exact-shape validation, the same presentation mapping.
  /// Only the transport is the fixture, and no daemon is needed for any of it.
  func testFixtureLaunchAnswersTheOwnerContractThroughTheProductionFacade() async throws {
    // Each test roots its own owner: the suite runs its methods in parallel
    // processes, and two owners on the App's one fixed path would race.
    let root = uniqueRoot("facade")
    defer { try? FileManager.default.removeItem(at: root) }
    let provider = SettingsApplicationFacade.make(
      arguments: ["--ui-test-runtime-history"], fixtureRoot: root)
    let initial = try await provider.refresh().storage

    XCTAssertTrue(
      initial.rootPath.hasSuffix("/\(SettingsStorageUIFixture.sessionRootName)"), initial.rootPath)
    XCTAssertTrue(initial.rootPath.hasPrefix(root.resolvingSymlinksInPath().path), initial.rootPath)
    XCTAssertFalse(initial.usesCustomRoot)
    // One write over the untouched owner, and a policy no product default
    // matches: the pane cannot pass by showing a real owner's figures.
    XCTAssertEqual(initial.generation, 2)
    let published = SettingsStorageUIFixture.publishedPolicy
    XCTAssertEqual(initial.totalQuotaBytes, published.totalQuotaBytes)
    XCTAssertEqual(initial.safetyMarginBytes, published.safetyMarginBytes)
    XCTAssertEqual(initial.retentionDays, published.retentionDays)
    XCTAssertNotEqual(published, RuntimeSessionStorageStore.defaultPolicy)

    // Both domains are present and distinct, as the pane expects of a Runtime
    // that answered.
    let artifacts = try XCTUnwrap(initial.runtimeArtifacts)
    XCTAssertEqual(artifacts.totalBytes, SettingsStorageUIFixture.artifactTotalBytes)
    XCTAssertEqual(artifacts.usedBytes, SettingsStorageUIFixture.artifactUsedBytes)
    XCTAssertEqual(artifacts.remainingBytes, artifacts.totalBytes - artifacts.usedBytes)
    let sessionRoot = try XCTUnwrap(initial.sessionRoot)
    XCTAssertEqual(sessionRoot.measuredBytes, 0)
    XCTAssertEqual(sessionRoot.unaccountedSessionCount, 0)
    XCTAssertFalse(sessionRoot.measurementIncomplete)

    // Mutations are generation-bound and persist in the fixture owner.
    let updated = try await provider.updateStoragePolicy(
      totalQuotaBytes: 9 * 1_024 * 1_024 * 1_024,
      safetyMarginBytes: 1_024 * 1_024 * 1_024,
      retentionDays: 30
    ).storage
    XCTAssertEqual(updated.generation, 3)
    XCTAssertEqual(updated.totalQuotaBytes, 9 * 1_024 * 1_024 * 1_024)
    XCTAssertEqual(updated.safetyMarginBytes, 1_024 * 1_024 * 1_024)
    XCTAssertEqual(updated.retentionDays, 30)
    let reread = try await provider.refresh().storage
    XCTAssertEqual(reread, updated)

    // A custom root the owner accepts, then the default root again.
    let custom = FileManager.default.temporaryDirectory.appending(
      path: "arkdeck-settings-ui-fixture-root-\(UUID().uuidString)",
      directoryHint: .isDirectory)
    try FileManager.default.createDirectory(
      at: custom, withIntermediateDirectories: true,
      attributes: [.posixPermissions: 0o700])
    defer { try? FileManager.default.removeItem(at: custom) }
    let selected = try await provider.selectStorageRoot(custom).storage
    XCTAssertTrue(selected.usesCustomRoot)
    XCTAssertEqual(selected.generation, 4)
    XCTAssertEqual(
      selected.rootPath, custom.resolvingSymlinksInPath().standardizedFileURL.path)
    let restored = try await provider.resetStorageRoot().storage
    XCTAssertFalse(restored.usesCustomRoot)
    XCTAssertEqual(restored.generation, 5)
    XCTAssertEqual(restored.rootPath, initial.rootPath)
    XCTAssertEqual(restored.totalQuotaBytes, updated.totalQuotaBytes)
  }

  /// The owner refuses what the daemon refuses, with the daemon's codes, and a
  /// refused request never moves the generation.
  func testFixtureOwnerRefusesStaleGenerationsAndUnpublishedMethods() async throws {
    let base = FileManager.default.temporaryDirectory.appending(
      path: "arkdeck-settings-ui-fixture-owner-\(UUID().uuidString)",
      directoryHint: .isDirectory)
    defer { try? FileManager.default.removeItem(at: base) }
    let owner = SettingsStorageUIFixture.Owner(base: base)

    let status = try decode(await owner.reply("runtime.storage.status", nil))
    XCTAssertEqual(status["ok"] as? Bool, true)
    XCTAssertEqual(try generation(of: status), "2")

    let policy: [String: JSONValue] = [
      "expectedGeneration": .string("2"),
      "totalQuotaBytes": .string("9663676416"),
      "safetyMarginBytes": .string("1073741824"),
      "retentionDays": .string("30"),
    ]
    let accepted = try decode(await owner.reply("runtime.storage.policy", policy))
    XCTAssertEqual(accepted["ok"] as? Bool, true)
    XCTAssertEqual(try generation(of: accepted), "3")

    let stale = try decode(await owner.reply("runtime.storage.policy", policy))
    XCTAssertEqual(stale["ok"] as? Bool, false)
    XCTAssertEqual(try code(of: stale), "resourceConflict")

    let stray = try decode(await owner.reply("runtime.storage.status", ["extra": .bool(true)]))
    XCTAssertEqual(try code(of: stray), "invalidInput")

    let twoSelections = try decode(
      await owner.reply(
        "runtime.storage.root",
        [
          "expectedGeneration": .string("3"),
          "rootPath": .string("/nonexistent"),
          "resetToDefault": .bool(true),
        ]))
    XCTAssertEqual(try code(of: twoSelections), "invalidInput")

    let unpublished = try decode(await owner.reply("runtime.storage.sessions", nil))
    XCTAssertEqual(try code(of: unpublished), "unknownMethod")

    // Every refusal above left the owner where the accepted write put it.
    let settled = try decode(await owner.reply("runtime.storage.status", nil))
    XCTAssertEqual(try generation(of: settled), "3")
  }

  /// The History fixture's unreachable switch reaches this owner too, at launch
  /// or through the shared state file, so the App can be walked from an
  /// unavailable Storage pane to a recovered one without a relaunch.
  func testUnreachableSwitchFailsEveryRequestUntilItIsCleared() async throws {
    let root = uniqueRoot("unreachable")
    let stateFile = FileManager.default.temporaryDirectory.appending(
      path: "arkdeck-settings-ui-fixture-state-\(UUID().uuidString).txt")
    try SettingsStorageUIFixture.unreachableArgument.write(
      to: stateFile, atomically: true, encoding: .utf8)
    defer {
      try? FileManager.default.removeItem(at: stateFile)
      try? FileManager.default.removeItem(at: root)
    }
    let provider = SettingsApplicationFacade.make(
      arguments: ["--ui-test-runtime-history", "--ui-test-fixture-state", stateFile.path],
      fixtureRoot: root)
    do {
      _ = try await provider.refresh()
      XCTFail("an unreachable Runtime must not produce a presentation")
    } catch SettingsApplicationError.runtimeStorageUnavailable {
      // The same error the production transport produces when no daemon answers.
    }

    // Cleared in the file, the same provider recovers on its next request.
    try "".write(to: stateFile, atomically: true, encoding: .utf8)
    let recovered = try await provider.refresh().storage
    XCTAssertEqual(recovered.generation, 2)
    XCTAssertEqual(
      recovered.totalQuotaBytes, SettingsStorageUIFixture.publishedPolicy.totalQuotaBytes)

    // At launch, with no state file, the argument alone is the switch. The
    // owner is never composed, so this root is never created.
    let atLaunch = SettingsApplicationFacade.make(
      arguments: ["--ui-test-runtime-history", SettingsStorageUIFixture.unreachableArgument],
      fixtureRoot: uniqueRoot("at-launch"))
    do {
      _ = try await atLaunch.refresh()
      XCTFail("the launch argument alone must make the Runtime unreachable")
    } catch SettingsApplicationError.runtimeStorageUnavailable {
    }
  }

  private func uniqueRoot(_ label: String) -> URL {
    FileManager.default.temporaryDirectory.appending(
      path: "arkdeck-settings-ui-fixture-\(label)-\(UUID().uuidString)",
      directoryHint: .isDirectory)
  }

  private func decode(_ data: Data) throws -> [String: Any] {
    try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
  }

  private func generation(of envelope: [String: Any]) throws -> String {
    let result = try XCTUnwrap(envelope["result"] as? [String: Any])
    let sessions = try XCTUnwrap(result["sessionDomain"] as? [String: Any])
    return try XCTUnwrap(sessions["generation"] as? String)
  }

  private func code(of envelope: [String: Any]) throws -> String {
    let error = try XCTUnwrap(envelope["error"] as? [String: Any])
    return try XCTUnwrap(error["code"] as? String)
  }
}
