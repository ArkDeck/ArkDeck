import Foundation
import Testing

@testable import ArkDeckClientKit

struct RemoteBuildSourceContractTests {
  @Test func keychainCredentialRoundTripAndRemoval() throws {
    let store = KeychainRemoteBuildCredentialStore()
    let account = UUID()
    let secret = Data("ephemeral-remote-source-contract".utf8)
    defer { _ = try? store.remove(account: account) }

    #expect(!store.contains(account: account))
    try store.set(secret, account: account)
    #expect(store.contains(account: account))
    #expect(try store.read(account: account) == secret)
    #expect(try store.remove(account: account))
    #expect(!store.contains(account: account))
  }

  @Test func boundsRejectRootTraversalAndSiblingPrefixes() throws {
    let normalized = try RemoteBuildSourceBounds.validate(
      RemoteBuildSourceDraft(
        name: "  Builder  ", host: "BUILDER.EXAMPLE", port: 22,
        username: "build-user", rootPath: "/srv/build/out",
        authentication: .privateKey))
    #expect(normalized.name == "Builder")
    #expect(normalized.host == "builder.example")
    #expect(normalized.rootPath == "/srv/build/out")
    #expect(RemoteBuildSourceBounds.isContained("/srv/build/out/lib.so", in: "/srv/build/out"))
    #expect(!RemoteBuildSourceBounds.isContained("/srv/build/outside/lib.so", in: "/srv/build/out"))

    for invalidRoot in ["/", "relative", "/srv/../etc", "/srv//out", "/srv/./out"] {
      #expect(throws: (any Error).self, "\(invalidRoot)") {
        try RemoteBuildSourceBounds.absoluteRoot(invalidRoot)
      }
    }
    for invalidRelative in ["../secret", "/absolute", "nested/../../secret", "nested//lib.so"] {
      #expect(throws: (any Error).self, "\(invalidRelative)") {
        try RemoteBuildSourceBounds.relativePath(invalidRelative, allowEmpty: false)
      }
    }
  }

  @Test func profileAndAuditFilesArePrivateAndContainNoSecretOrRawPath() async throws {
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
    #expect(reloaded == [record])

    let rawPath = "release/private/libfeature_debug.so"
    let audit = FileRemoteBuildSourceAuditStore(fileURL: auditURL)
    try await audit.append(
      RemoteBuildAuditEvent(
        eventID: UUID(), correlationID: UUID(), phase: "intent",
        action: "readNativeLibrary", sourceID: sourceID,
        relativePathSHA256: String(repeating: "a", count: 64),
        outcome: nil, observedAt: Date()))

    for fileURL in [profileURL, auditURL] {
      let permissions = try #require(
        (try FileManager.default.attributesOfItem(atPath: fileURL.path)[.posixPermissions]
          as? NSNumber)?.intValue)
      #expect(permissions & 0o777 == 0o600)
      let contents = try String(contentsOf: fileURL, encoding: .utf8)
      #expect(!contents.contains("secret-value"))
      #expect(!contents.contains(rawPath))
      #expect(!contents.lowercased().contains("passphrase"))
    }
  }

  @Test func targetBindingIsExplicitPrivateAndRejectsAnUnknownSource() async throws {
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
    #expect(initialBinding == nil)
    try await provider.bind(sourceID: sourceID, toTargetID: "target-a")
    let loadedBinding = try await provider.binding(forTargetID: "target-a")
    let binding = try #require(loadedBinding)
    #expect(binding.targetID == "target-a")
    #expect(binding.sourceID == sourceID)
    await #expect(
      throws: RemoteBuildSourceError.sourceNotFound,
      "an unknown source must not become a target binding"
    ) {
      try await provider.bind(sourceID: UUID(), toTargetID: "target-a")
    }

    let permissions = try #require(
      (try FileManager.default.attributesOfItem(atPath: bindingURL.path)[.posixPermissions]
        as? NSNumber)?.intValue)
    #expect(permissions & 0o777 == 0o600)
    let contents = try String(contentsOf: bindingURL, encoding: .utf8)
    #expect(contents.contains("target-a"))
    #expect(!contents.contains("builder.example"))

    try await provider.unbind(targetID: "target-a")
    let removedBinding = try await provider.binding(forTargetID: "target-a")
    #expect(removedBinding == nil)
  }

  @Test func systemSSHIdentityResolverUsesOnlyFixedOwnerPrivateRegularFiles() throws {
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

    #expect(
      SystemSSHIdentityResolver.candidateRelativePaths
        == [".ssh/id_rsa", ".ssh/id_ed25519"])
    #expect(
      SystemSSHIdentityResolver.loadCandidateData(homeDirectory: home)
        == [Data("rsa-candidate".utf8), Data("ed25519-candidate".utf8)])

    try FileManager.default.setAttributes([.posixPermissions: 0o644], ofItemAtPath: rsa.path)
    #expect(
      SystemSSHIdentityResolver.loadCandidateData(homeDirectory: home)
        == [Data("ed25519-candidate".utf8)],
      "a group/world-readable private key must not be offered")

    try FileManager.default.removeItem(at: rsa)
    try FileManager.default.createSymbolicLink(at: rsa, withDestinationURL: ed25519)
    #expect(
      SystemSSHIdentityResolver.loadCandidateData(homeDirectory: home)
        == [Data("ed25519-candidate".utf8)],
      "a default identity symlink must not be followed")
  }

  @Test func appSandboxScopesSystemSSHAccessToExactReadOnlyIdentityFiles() throws {
    let root = URL(filePath: #filePath)
      .deletingLastPathComponent().deletingLastPathComponent()
      .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
    let entitlements = try String(
      contentsOf: root.appending(path: "ArkDeckApp/ArkDeckApp.entitlements"), encoding: .utf8)
    #expect(
      entitlements.contains(
        "com.apple.security.temporary-exception.files.home-relative-path.read-only"))
    #expect(entitlements.contains("<string>/.ssh/id_rsa</string>"))
    #expect(entitlements.contains("<string>/.ssh/id_ed25519</string>"))
    #expect(
      !entitlements.contains("<string>/.ssh/</string>"),
      "the App must not receive directory-wide access to SSH config or host metadata")
  }
}
