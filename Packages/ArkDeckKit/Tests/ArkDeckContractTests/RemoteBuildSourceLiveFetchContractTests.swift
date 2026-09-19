import Foundation
import XCTest

@testable import ArkDeckClientKit
@testable import ArkDeckWorkflows

/// The Remote build source against a live SSH endpoint, with the fetched
/// library checked by the Debug workspace's native-library validator. It stays
/// in ArkDeckContractTests because that validator and the ELF fixture are not
/// ClientKit's; the source's own contract tests are in ArkDeckClientKitTests.
final class RemoteBuildSourceLiveFetchContractTests: XCTestCase {
  func testLiveSSHReadOnlyBrowserAndBoundedFetch() async throws {
    let environment = ProcessInfo.processInfo.environment
    guard let host = environment["ARKDECK_TEST_SSH_HOST"],
      let portText = environment["ARKDECK_TEST_SSH_PORT"], let port = Int(portText),
      let username = environment["ARKDECK_TEST_SSH_USER"],
      let rootPath = environment["ARKDECK_TEST_SSH_ROOT"],
      let keyPath = environment["ARKDECK_TEST_SSH_PRIVATE_KEY"]
    else {
      throw XCTSkip("Set ARKDECK_TEST_SSH_* to run the live SFTP contract")
    }

    let directory = FileManager.default.temporaryDirectory.appending(
      path: "arkdeck-remote-source-live-\(UUID().uuidString)",
      directoryHint: .isDirectory)
    defer { try? FileManager.default.removeItem(at: directory) }
    if environment["ARKDECK_TEST_SSH_PROVISION_LOCAL_FIXTURE"] == "1" {
      let allowedRoot = FileManager.default.temporaryDirectory.standardizedFileURL.path
      guard rootPath.hasPrefix(allowedRoot + "/") || rootPath.hasPrefix("/private/tmp/") else {
        return XCTFail("local live-fixture provisioning is restricted to the temporary directory")
      }
      try NativeLibraryTestFixture.arm64ELF().write(
        to: URL(filePath: rootPath).appending(path: "release/libfixture.so"),
        options: .atomic)
    }
    let systemHome = directory.appending(path: "system-home", directoryHint: .isDirectory)
    let systemSSH = systemHome.appending(path: ".ssh", directoryHint: .isDirectory)
    try FileManager.default.createDirectory(at: systemSSH, withIntermediateDirectories: true)
    let systemIdentity = systemSSH.appending(path: "id_ed25519")
    try Data(contentsOf: URL(filePath: keyPath)).write(to: systemIdentity, options: .atomic)
    try FileManager.default.setAttributes(
      [.posixPermissions: 0o600], ofItemAtPath: systemIdentity.path)
    let provider = ProductionRemoteBuildSourceProvider(
      records: FileRemoteBuildSourceRecordStore(
        fileURL: directory.appending(path: "sources.json")),
      credentials: MemoryRemoteCredentialStore(),
      audit: FileRemoteBuildSourceAuditStore(
        fileURL: directory.appending(path: "audit.jsonl")),
      systemSSHHomeDirectory: systemHome)
    let draft = RemoteBuildSourceDraft(
      name: "Live fixture", host: host, port: port, username: username,
      rootPath: rootPath, authentication: .privateKey)
    let probe = try await provider.probe(
      draft: draft, credential: nil)
    XCTAssertTrue(probe.requiresNewHostTrust)
    let source = try await provider.save(probe: probe)
    XCTAssertTrue(source.credentialStored)
    XCTAssertTrue(source.usesSystemDefaultCredential)
    XCTAssertTrue(source.hostKeyFingerprint.hasPrefix("SHA256:"))

    let root = try await provider.listDirectory(sourceID: source.id, relativePath: "")
    XCTAssertTrue(root.entries.contains { $0.name == "release" && $0.kind == .directory })
    let release = try await provider.listDirectory(
      sourceID: source.id, relativePath: "release")
    let library = try XCTUnwrap(
      release.entries.first { $0.name == "libfixture.so" && $0.kind == .nativeLibrary })
    let artifact = try await provider.fetchNativeLibrary(
      sourceID: source.id, relativePath: library.relativePath)
    XCTAssertEqual(artifact.fileName, "libfixture.so")
    XCTAssertEqual(artifact.byteCount, artifact.contents.count)
    XCTAssertGreaterThanOrEqual(artifact.byteCount, 64)
    let signedFacts = try NativeLibraryArtifactValidator.validate(
      artifact.contents, requireOpenHarmonyCodeSignature: true)
    XCTAssertEqual(signedFacts.abi, .arm64)

    do {
      _ = try await provider.listDirectory(sourceID: source.id, relativePath: "escape")
      XCTFail("a symlink outside the canonical root must be rejected")
    } catch {
      XCTAssertEqual(error as? RemoteBuildSourceError, .pathOutsideRoot)
    }

    let reprobe = try await provider.probe(
      draft: RemoteBuildSourceDraft(
        id: source.id, name: draft.name, host: draft.host, port: draft.port,
        username: draft.username, rootPath: draft.rootPath,
        authentication: draft.authentication),
      credential: nil)
    XCTAssertFalse(reprobe.requiresNewHostTrust)
    XCTAssertEqual(reprobe.hostKeyFingerprint, source.hostKeyFingerprint)
  }
}

private final class MemoryRemoteCredentialStore: RemoteBuildCredentialStoring,
  @unchecked Sendable
{
  private let lock = NSLock()
  private var values: [UUID: Data] = [:]

  func set(_ data: Data, account: UUID) throws {
    lock.withLock { values[account] = data }
  }

  func read(account: UUID) throws -> Data {
    try lock.withLock {
      guard let value = values[account] else {
        throw RemoteBuildSourceError.credentialUnavailable
      }
      return value
    }
  }

  func contains(account: UUID) -> Bool {
    lock.withLock { values[account] != nil }
  }

  func remove(account: UUID) throws -> Bool {
    lock.withLock { values.removeValue(forKey: account) != nil }
  }
}
