import Foundation
import XCTest

@testable import ArkDeckWorkflows

final class RemoteBuildSourceContractTests: XCTestCase {
  func testKeychainCredentialRoundTripAndRemoval() throws {
    let store = KeychainRemoteBuildCredentialStore()
    let account = UUID()
    let secret = Data("ephemeral-remote-source-contract".utf8)
    defer { _ = try? store.remove(account: account) }

    XCTAssertFalse(store.contains(account: account))
    try store.set(secret, account: account)
    XCTAssertTrue(store.contains(account: account))
    XCTAssertEqual(try store.read(account: account), secret)
    XCTAssertTrue(try store.remove(account: account))
    XCTAssertFalse(store.contains(account: account))
  }

  func testBoundsRejectRootTraversalAndSiblingPrefixes() throws {
    let normalized = try RemoteBuildSourceBounds.validate(
      RemoteBuildSourceDraft(
        name: "  Builder  ", host: "BUILDER.EXAMPLE", port: 22,
        username: "build-user", rootPath: "/srv/build/out",
        authentication: .privateKey))
    XCTAssertEqual(normalized.name, "Builder")
    XCTAssertEqual(normalized.host, "builder.example")
    XCTAssertEqual(normalized.rootPath, "/srv/build/out")
    XCTAssertTrue(RemoteBuildSourceBounds.isContained("/srv/build/out/lib.so", in: "/srv/build/out"))
    XCTAssertFalse(RemoteBuildSourceBounds.isContained("/srv/build/outside/lib.so", in: "/srv/build/out"))

    for invalidRoot in ["/", "relative", "/srv/../etc", "/srv//out", "/srv/./out"] {
      XCTAssertThrowsError(try RemoteBuildSourceBounds.absoluteRoot(invalidRoot), invalidRoot)
    }
    for invalidRelative in ["../secret", "/absolute", "nested/../../secret", "nested//lib.so"] {
      XCTAssertThrowsError(
        try RemoteBuildSourceBounds.relativePath(invalidRelative, allowEmpty: false),
        invalidRelative)
    }
  }

  func testProfileAndAuditFilesArePrivateAndContainNoSecretOrRawPath() async throws {
    let directory = FileManager.default.temporaryDirectory.appending(
      path: "arkdeck-remote-source-contract-\(UUID().uuidString)",
      directoryHint: .isDirectory)
    defer { try? FileManager.default.removeItem(at: directory) }
    let profileURL = directory.appending(path: "sources.json")
    let auditURL = directory.appending(path: "audit.jsonl")
    let sourceID = UUID()
    let record = RemoteBuildSourceRecord(
      id: sourceID, name: "Builder", host: "builder.example", port: 22,
      username: "build", rootPath: "/srv/build/out",
      canonicalRootPath: "/srv/build/out", authentication: .privateKey,
      hostPublicKey: "ssh-ed25519 AAAATEST", hostKeyFingerprint: "SHA256:test",
      lastVerifiedAt: Date(timeIntervalSince1970: 1_700_000_000))
    let profiles = FileRemoteBuildSourceRecordStore(fileURL: profileURL)
    try await profiles.replace([record])
    let reloaded = try await profiles.load()
    XCTAssertEqual(reloaded, [record])

    let rawPath = "release/private/libfeature_debug.so"
    let audit = FileRemoteBuildSourceAuditStore(fileURL: auditURL)
    try await audit.append(
      RemoteBuildAuditEvent(
        eventID: UUID(), correlationID: UUID(), phase: "intent",
        action: "readNativeLibrary", sourceID: sourceID,
        relativePathSHA256: String(repeating: "a", count: 64),
        outcome: nil, observedAt: Date()))

    for fileURL in [profileURL, auditURL] {
      let permissions = try XCTUnwrap(
        (try FileManager.default.attributesOfItem(atPath: fileURL.path)[.posixPermissions]
          as? NSNumber)?.intValue)
      XCTAssertEqual(permissions & 0o777, 0o600)
      let contents = try String(contentsOf: fileURL, encoding: .utf8)
      XCTAssertFalse(contents.contains("secret-value"))
      XCTAssertFalse(contents.contains(rawPath))
      XCTAssertFalse(contents.lowercased().contains("passphrase"))
    }
  }

  func testTargetBindingIsExplicitPrivateAndRejectsAnUnknownSource() async throws {
    let directory = FileManager.default.temporaryDirectory.appending(
      path: "arkdeck-remote-binding-contract-\(UUID().uuidString)",
      directoryHint: .isDirectory)
    defer { try? FileManager.default.removeItem(at: directory) }
    let sourceURL = directory.appending(path: "sources.json")
    let bindingURL = directory.appending(path: "bindings.json")
    let sourceID = UUID()
    let records = FileRemoteBuildSourceRecordStore(fileURL: sourceURL)
    try await records.replace([
      RemoteBuildSourceRecord(
        id: sourceID, name: "Builder", host: "builder.example", port: 22,
        username: "build", rootPath: "/srv/build/out",
        canonicalRootPath: "/srv/build/out", authentication: .privateKey,
        hostPublicKey: "ssh-ed25519 AAAATEST", hostKeyFingerprint: "SHA256:test",
        lastVerifiedAt: Date(timeIntervalSince1970: 1_700_000_000))
    ])
    let provider = ProductionRemoteBuildSourceBindingProvider(
      records: records,
      bindings: FileRemoteBuildSourceBindingStore(fileURL: bindingURL))

    let initialBinding = try await provider.binding(forTargetID: "target-a")
    XCTAssertNil(initialBinding)
    try await provider.bind(sourceID: sourceID, toTargetID: "target-a")
    let loadedBinding = try await provider.binding(forTargetID: "target-a")
    let binding = try XCTUnwrap(loadedBinding)
    XCTAssertEqual(binding.targetID, "target-a")
    XCTAssertEqual(binding.sourceID, sourceID)
    do {
      try await provider.bind(sourceID: UUID(), toTargetID: "target-a")
      XCTFail("an unknown source must not become a target binding")
    } catch {
      XCTAssertEqual(error as? RemoteBuildSourceError, .sourceNotFound)
    }

    let permissions = try XCTUnwrap(
      (try FileManager.default.attributesOfItem(atPath: bindingURL.path)[.posixPermissions]
        as? NSNumber)?.intValue)
    XCTAssertEqual(permissions & 0o777, 0o600)
    let contents = try String(contentsOf: bindingURL, encoding: .utf8)
    XCTAssertTrue(contents.contains("target-a"))
    XCTAssertFalse(contents.contains("builder.example"))

    try await provider.unbind(targetID: "target-a")
    let removedBinding = try await provider.binding(forTargetID: "target-a")
    XCTAssertNil(removedBinding)
  }

  func testSystemSSHIdentityResolverUsesOnlyFixedOwnerPrivateRegularFiles() throws {
    let home = FileManager.default.temporaryDirectory.appending(
      path: "arkdeck-system-ssh-contract-\(UUID().uuidString)",
      directoryHint: .isDirectory)
    defer { try? FileManager.default.removeItem(at: home) }
    let ssh = home.appending(path: ".ssh", directoryHint: .isDirectory)
    try FileManager.default.createDirectory(at: ssh, withIntermediateDirectories: true)
    let rsa = ssh.appending(path: "id_rsa")
    let ed25519 = ssh.appending(path: "id_ed25519")
    try Data("rsa-candidate".utf8).write(to: rsa)
    try Data("ed25519-candidate".utf8).write(to: ed25519)
    try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: rsa.path)
    try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: ed25519.path)

    XCTAssertEqual(
      SystemSSHIdentityResolver.candidateRelativePaths,
      [".ssh/id_rsa", ".ssh/id_ed25519"])
    XCTAssertEqual(
      SystemSSHIdentityResolver.loadCandidateData(homeDirectory: home),
      [Data("rsa-candidate".utf8), Data("ed25519-candidate".utf8)])

    try FileManager.default.setAttributes([.posixPermissions: 0o644], ofItemAtPath: rsa.path)
    XCTAssertEqual(
      SystemSSHIdentityResolver.loadCandidateData(homeDirectory: home),
      [Data("ed25519-candidate".utf8)],
      "a group/world-readable private key must not be offered")

    try FileManager.default.removeItem(at: rsa)
    try FileManager.default.createSymbolicLink(at: rsa, withDestinationURL: ed25519)
    XCTAssertEqual(
      SystemSSHIdentityResolver.loadCandidateData(homeDirectory: home),
      [Data("ed25519-candidate".utf8)],
      "a default identity symlink must not be followed")
  }

  func testAppSandboxScopesSystemSSHAccessToExactReadOnlyIdentityFiles() throws {
    let root = URL(filePath: #filePath)
      .deletingLastPathComponent().deletingLastPathComponent()
      .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
    let entitlements = try String(
      contentsOf: root.appending(path: "ArkDeckApp/ArkDeckApp.entitlements"), encoding: .utf8)
    XCTAssertTrue(
      entitlements.contains(
        "com.apple.security.temporary-exception.files.home-relative-path.read-only"))
    XCTAssertTrue(entitlements.contains("<string>/.ssh/id_rsa</string>"))
    XCTAssertTrue(entitlements.contains("<string>/.ssh/id_ed25519</string>"))
    XCTAssertFalse(
      entitlements.contains("<string>/.ssh/</string>"),
      "the App must not receive directory-wide access to SSH config or host metadata")
  }

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
