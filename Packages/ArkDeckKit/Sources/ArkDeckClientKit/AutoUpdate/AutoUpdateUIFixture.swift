import Foundation

/// Deterministic update states for UI automation.
///
/// The update surface was the only one in the App with no fixture, so the
/// Settings scene had never been rendered by a test and the suite ran the real
/// updater — including whatever `checkAutomaticallyIfDue` decides to do — which
/// is neither deterministic nor free of network effects.
///
/// This supplies a *domain state* and nothing else. The App's own state to
/// presentation mapping still runs over it, so a test asserts the product's
/// real mapping rather than a second copy of it that could drift. Nothing here
/// reaches a network, a keychain or the artifact store, and a launch without
/// one of these arguments selects none of it.
public enum AutoUpdateUIFixture {
  private static let prefix = "--ui-test-auto-update"

  /// Whether this launch drives the update surface from a fixture at all. A
  /// launch without one of these arguments never reaches any of it.
  public static func isSelected(arguments: [String] = CommandLine.arguments) -> Bool {
    arguments.contains { $0.hasPrefix(prefix) }
  }

  /// The state to render now. Like the HDC and Runtime history fixtures this
  /// prefers the shared state file when one is named, so a single launched
  /// instance can walk every state instead of spending a launch on each.
  public static func state(arguments: [String] = CommandLine.arguments) -> AutoUpdateState? {
    guard isSelected(arguments: arguments) else { return nil }
    return state(declaredBy: requested(in: arguments))
  }

  private static func requested(in arguments: [String]) -> String {
    if let index = arguments.firstIndex(of: "--ui-test-fixture-state"),
      arguments.indices.contains(index + 1),
      let text = try? String(contentsOfFile: arguments[index + 1], encoding: .utf8),
      let declared = text.split(separator: "\n").map(String.init)
        .first(where: { $0.hasPrefix(prefix) })
    {
      return declared
    }
    return arguments.first(where: { $0.hasPrefix(prefix) }) ?? ""
  }

  private static func state(declaredBy flag: String) -> AutoUpdateState? {
    switch flag {
    case "--ui-test-auto-update-available": .available(feed)
    case "--ui-test-auto-update-awaiting-consent": .awaitingConsent(feed: feed, artifact: artifact)
    case "--ui-test-auto-update-failed": .failed(.feed)
    default: .idle
    }
  }

  private static var feed: VerifiedUpdateFeed {
    let payload = UpdateFeedPayload(
      sequence: 1,
      version: "9.9.9",
      minimumSystemVersion: "14.0.0",
      architectures: ["arm64"],
      issuedAt: "2026-07-23T00:00:00Z",
      expiresAt: "2036-07-23T00:00:00Z",
      artifact: UpdateArtifactDescriptor(
        url: "https://updates.invalid/arkdeck-fixture.dmg",
        byteLength: 4,
        sha256: fixtureSHA256),
      releaseNotesSummary: "UI fixture release notes.")
    return VerifiedUpdateFeed(
      payload: payload, canonicalPayload: Data("ui-fixture".utf8), payloadSHA256: fixtureSHA256)
  }

  private static var artifact: ValidatedUpdateArtifact {
    ValidatedUpdateArtifact(
      downloaded: DownloadedUpdateArtifact(
        url: URL(filePath: "/dev/null"),
        byteLength: 4,
        sha256: fixtureSHA256,
        identity: UpdateFileIdentity(
          device: 0, inode: 0, byteLength: 4, mode: 0, modifiedSeconds: 0,
          modifiedNanoseconds: 0, changedSeconds: 0, changedNanoseconds: 0)),
      teamIdentifier: "UIFIXTURE")
  }

  private static let fixtureSHA256 =
    "0000000000000000000000000000000000000000000000000000000000000000"
}
